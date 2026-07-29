//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import CoreImage.CIFilterBuiltins
import LiveKit
import Metal
import os.log
import ReplayKit
import SwiftUI
import Vision
#if canImport(UIKit)
import UIKit
#endif

private let livekitLog = OSLog(subsystem: "ru.implica.stalk", category: "LiveKit")

/// Режим фона в звонке: выкл / три интенсивности размытия / обои.
/// rawValue хранится в UserDefaults (`stalk_call_background_mode`),
/// выбранные обои — индекс 1...8 в `stalk_call_wallpaper_index`.
enum CallBackgroundMode: String, CaseIterable {
    case off
    case blurLight = "blur_light"
    case blurMedium = "blur_medium"
    case blurStrong = "blur_strong"
    case wallpaper
}

/// sTalk: Manages a native LiveKit room connection using credentials intercepted from Element Call's WebSocket.
/// Provides published state for SwiftUI views to render native video tracks.
@MainActor
final class LiveKitRoomManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var connectionState: ConnectionState = .disconnected
    /// STMOB-282: съём метрик исходящего видео — что реально выдаёт кодировщик.
    private let outboundStatsLogger = OutboundVideoStatsLogger()
    /// STMOB-262: режим переподключения, в котором сейчас находится SDK (nil — не
    /// переподключается). Quick-цикл в `connectionState` не виден вообще.
    @Published private(set) var sdkReconnectMode: ReconnectMode?
    /// Оценка качества связи от SFU для СЕБЯ. Приходит только при смене значения,
    /// поэтому как самостоятельный детектор не годится — только как подтверждение.
    @Published private(set) var localConnectionQuality: ConnectionQuality = .unknown
    /// Просьба разослать E2EE-ключ заново (после переподключения SDK).
    let encryptionKeyRebroadcastSubject = PassthroughSubject<Void, Never>()
    @Published private(set) var remoteParticipants: [RemoteParticipant] = []
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var localParticipant: LocalParticipant?

    /// STMOB-163 build 180: remoteParticipants без egress / service bots.
    /// Фильтр через `participant.kind == .standard` — LiveKit protocol-level
    /// enum различает real users от bots (egress, ingress, sip, agent).
    /// Recording multichannel (Molly STALK-237) подключает egress как
    /// participants с `kind == .egress` — фильтруются автоматически.
    ///
    /// Подход согласован с Molly. Преимущества над identity-prefix filter:
    ///  - Не зависит от identity convention (`@matrix:user` или другая)
    ///  - Не зависит от publish tracks (muted user всё ещё .standard, visible)
    ///  - Future-proof: новые service kinds (agent для AI bot, etc) автоматически hide
    var displayParticipants: [RemoteParticipant] {
        let ownIdentity = room.localParticipant.identity?.stringValue
        return remoteParticipants.filter { participant in
            guard participant.kind == .standard else { return false }
            // Наш собственный идентификатор среди «чужих» — это эхо (вторая сессия,
            // сервис записи, возврат наших же дорожек). В раскладке 1:1 такой участник
            // занимал главное место вместо собеседника, а трек настоящего собеседника
            // оставался без приёмника (лог 159, 21:27).
            if let ownIdentity, participant.identity?.stringValue == ownIdentity {
                return false
            }
            return true
        }
    }

    /// STMOB-223: активен ли screen-share у любого remote-участника.
    /// Детект по `source == .screenShareVideo` (а не по имени!): web/desktop
    /// публикует share-трек с ПУСТЫМ именем (см. STMOB-204), name-детект мимо.
    /// Единый источник для авто-переключения раскладки на .speaker.
    var hasRemoteScreenShare: Bool {
        displayParticipants.contains { participant in
            participant.videoTracks.contains { pub in
                pub.isSubscribed && (pub.name == Track.screenShareVideoName || pub.source == .screenShareVideo)
            }
        }
    }

    /// STMOB-100: actively speaking participants, sorted by audioLevel desc.
    /// Maintained by LiveKit SDK via `room(_:didUpdateSpeakingParticipants:)`
    /// delegate. SwiftUI views (ActiveSpeakerMiniView) подписываются на это
    /// чтобы PiP мини-окно переключалось на текущего active speaker — без
    /// этого audioLevel changes не триггерят SwiftUI re-render и PiP залипает
    /// на первом по JOIN order участнике.
    @Published private(set) var activeSpeakers: [Participant] = []

    /// STMOB-120: множество SID'ов participants поднявших руку.
    /// Источник — `participant.metadata` JSON с полем `hand_raised: true`.
    /// Делегат `didUpdateMetadata` обновляет state, SwiftUI views рендерят
    /// overlay-иконку поверх их тайлов.
    @Published private(set) var raisedHandsSIDs: Set<String> = []

    /// LiveKit room name (used for recording-api)
    var roomName: String? {
        room.name
    }

    // MARK: - Private

    private let room: Room
    private var cancellables = Set<AnyCancellable>()
    private var reconnectToken: String?
    private var reconnectURL: String?
    private var reconnectAttempt = 0
    private let reconnectMaxAttempts = 3
    private var wasE2EE = false
    private var savedKeyProvider: BaseKeyProvider?
    private var savedSpeakerDefault = false

    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var wasCameraEnabledBeforeBackground = false
    #endif

    init() {
        // STMOB-262: мост логов SDK ставим до создания Room (setLogger сам требует
        // «до первого лога»). Иначе лестница переподключений SDK остаётся невидимой
        // в выгрузке с устройства.
        Self.installSDKLogBridgeOnce()
        room = Room()
        room.add(delegate: self)
        registerLifecycleObservers()
    }

    private static let logBridgeInstalled: Bool = {
        LiveKitSDK.setLogger(LiveKitDiagLogBridge())
        return true
    }()

    private static func installSDKLogBridgeOnce() {
        _ = logBridgeInstalled
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor [room] in
            await room.disconnect()
        }
    }

    // MARK: - Lifecycle observers (iOS background / audio interruptions)

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        #if canImport(UIKit)
        // Landscape-фикс: WebRTC RTCCameraVideoCapturer штампует rotation кадров
        // по UIDevice.orientation, но SwiftUI-приложение само НЕ генерирует
        // device-orientation уведомления (UI вращается через interfaceOrientation).
        // Без этого поворот телефона не менял rotation кадров — своё превью и
        // картинка у собеседника лежали «на боку» (репорт dp, IMG_5171).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        center.addObserver(self,
                           selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification,
                           object: nil)
        #endif
        center.addObserver(self,
                           selector: #selector(handleAudioInterruption(_:)),
                           name: AVAudioSession.interruptionNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleAudioRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification,
                           object: nil)
    }

    #if canImport(UIKit)
    @objc private func appDidEnterBackground() {
        // Remember if camera was actively publishing — need to re-enable on return.
        // Именно КАМЕРА и именно НЕ muted: setCamera(false) на устройстве только мьютит
        // publication (track остаётся != nil), а videoTracks.first может быть screen-share.
        // Старый чек «track != nil» после сворачивания сам ВКЛЮЧАЛ камеру, которую юзер
        // выключил (privacy).
        //
        // STMOB-234: считаем флаг ДО раннего guard по connectionState. Раньше уход в фон
        // в состоянии .connecting/.disconnected (реконнект — как раз то, что провоцирует
        // системная запись экрана) не обновлял флаг, в нём оставалось протухшее true с
        // прошлого цикла, и на возврате камера включалась САМА — в том числе в аудио-звонке
        // (setCamera(true) без publication не размьючивает, а публикует новый трек).
        wasCameraEnabledBeforeBackground = room.localParticipant.firstCameraPublication
            .map { $0.track != nil && !$0.isMuted } ?? false
        if isScreenSharing {
            // In-app ReplayKit-захват в фоне кадров не отдаёт — фиксируем в логе, чтобы
            // отличать «демонстрация встала от сворачивания» от перехвата системной записью.
            DiagLog.write("Call", "background во время демонстрации экрана (in-app capture кадры не отдаёт)")
        }
        guard connectionState == .connected || connectionState == .reconnecting else { return }
        // Блюр: CIContext на Metal не должен рендерить в фоне (GPU work in background
        // = command-buffer abort в момент транзишена). Отцепляем процессор; foreground
        // setCamera(true) ре-аттачит по интенту (blurIntent не трогаем).
        if blurProcessor != nil || orientationProcessor != nil,
           let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack {
            track.capturer.processor = nil
            blurProcessor = nil
            orientationProcessor = nil
            MXLog.info("sTalk LiveKit: video processor detached for backgrounding")
        }

        // Ask iOS to keep us alive while the WS is active. Without this, iOS freezes
        // the socket and LiveKit server times us out.
        if backgroundTaskID != .invalid { return }
        // КРИТИЧНО: expiration handler ДОЛЖЕН вызвать endBackgroundTask независимо от
        // состояния self. Иначе iOS kill'нёт app через SIGKILL ("Background task still
        // not ended after expiration handlers"). Capture taskID by value, не через self.
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "sTalk.LiveKit.WS") { [weak self] in
            UIApplication.shared.endBackgroundTask(taskID)
            self?.backgroundTaskID = .invalid
            os_log(.error, log: livekitLog, "Background task expired (id=%d) — endBackgroundTask called",
                   taskID.rawValue)
        }
        backgroundTaskID = taskID
        os_log(.info, log: livekitLog, "App → background, beginBackgroundTask id=%d state=%{public}@ hadCamera=%{public}@",
               backgroundTaskID.rawValue, "\(connectionState)", "\(wasCameraEnabledBeforeBackground)")
    }

    @objc private func appWillEnterForeground() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
            os_log(.info, log: livekitLog, "App → foreground, endBackgroundTask")
        }
        // Proactively re-enable camera — iOS stops AVCaptureSession in background.
        // Without this, waiting for LiveKit SDK's passive recovery takes 2-5 seconds.
        // STMOB-234: флаг одноразовый — сбрасываем сразу после чтения, иначе он
        // переживает цикл и включает камеру на следующем возврате из фона.
        let shouldRestoreCamera = wasCameraEnabledBeforeBackground
        wasCameraEnabledBeforeBackground = false
        DiagLog.write("Call", "foreground: restore camera=\(shouldRestoreCamera) state=\(connectionState) screenSharing=\(isScreenSharing)")
        // Время «в фоне» не простой кадров демонстрации: in-app ReplayKit-захват
        // там не отдаёт их в принципе, засчитывать это как перехват нельзя.
        screenShareWatchdog?.noteResumedFromBackground()
        if shouldRestoreCamera {
            Task { [weak self] in
                guard let self, self.connectionState == .connected else { return }
                do {
                    try await self.setCamera(enabled: true)
                    os_log(.info, log: livekitLog, "Camera re-enabled on foreground")
                } catch {
                    os_log(.error, log: livekitLog, "Camera re-enable FAIL: %{public}@", "\(error)")
                }
            }
        }
    }
    #endif

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            os_log(.info, log: livekitLog, "AudioSession interruption began")
        case .ended:
            var shouldResume = false
            if let optValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optValue).contains(.shouldResume)
            }
            os_log(.info, log: livekitLog, "AudioSession interruption ended shouldResume=%{public}@", "\(shouldResume)")
            if shouldResume {
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                } catch {
                    os_log(.error, log: livekitLog, "Failed to re-activate AudioSession: %{public}@", "\(error)")
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleAudioRouteChange(_ note: Notification) {
        guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
        let reasonStr: String
        switch reason {
        case .newDeviceAvailable: reasonStr = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonStr = "oldDeviceUnavailable"
        case .categoryChange: reasonStr = "categoryChange"
        case .override: reasonStr = "override"
        case .wakeFromSleep: reasonStr = "wakeFromSleep"
        case .noSuitableRouteForCategory: reasonStr = "noSuitableRouteForCategory"
        case .routeConfigurationChange: reasonStr = "routeConfigurationChange"
        case .unknown: reasonStr = "unknown"
        @unknown default: reasonStr = "other"
        }
        os_log(.info, log: livekitLog, "AudioSession route change: %{public}@", reasonStr)
    }

    // MARK: - Room options (настройки звонка из Settings)

    /// Ключи Settings-тумблеров (секция «Звонки», SettingsScreen @AppStorage).
    private static let noiseSuppressionSettingKey = "stalk_noise_suppression_enabled"
    private static let backgroundBlurSettingKey = "stalk_background_blur_enabled" // legacy-тумблер (до 26.04.08)
    private static let backgroundModeSettingKey = "stalk_call_background_mode"
    private static let wallpaperIndexSettingKey = "stalk_call_wallpaper_index"

    /// Камера 720p — единые опции для room defaults и ручного publish с pre-attached блюром.
    /// fps=24: дефолт капчера 30, а публикуем максимум 24 — лишние 20% кадров
    /// впустую грели GPU/Vision в фон-процессоре (жалоба dp на нагрев 12.07)
    private static let cameraCaptureOptions = CameraCaptureOptions(dimensions: .h720_169, fps: 24)

    /// Прочитаны ли настройки звонка для ТЕКУЩЕГО звонка. makeRoomOptions зовётся
    /// и из attemptAutoReconnect — без гарда повторное чтение UserDefaults затирало бы
    /// in-call выбор юзера (блюр из меню •••) посреди звонка.
    private var hasReadCallSettings = false

    /// STMOB-164 параметры (adaptiveStream/dynacast + 720p/24fps/2Mbps/DTX — снижение
    /// нагрева) + шумодав из настроек. WebRTC APM NS+highpass работают ПОВЕРХ Apple VPIO
    /// (VPIO всегда даёт AEC+AGC+базовый NS); EC/AGC в APM не включаем — дубль с VPIO
    /// портит звук. Mid-call смена NS требует republish трека, поэтому семантика
    /// настройки — «применяется со следующего звонка».
    /// Заодно читает blur-интент: тумблер в настройках = блюр по умолчанию для звонка.
    private func makeRoomOptions(encryptionOptions: EncryptionOptions? = nil) -> RoomOptions {
        if !hasReadCallSettings {
            hasReadCallSettings = true
            let defaults = UserDefaults.standard
            // NS строго opt-in (дефолт ВЫКЛ): дефолт «вкл» молча менял бы обработку
            // микрофона ВСЕМ юзерам против shipped 26.04.06/07 (двойной шумодав
            // APM+VPIO может «замыливать» голос) — только явный выбор в настройках.
            isNoiseSuppressed = defaults.bool(forKey: Self.noiseSuppressionSettingKey)
            // Режим фона: новый ключ, миграция со старого bool-тумблера (true → среднее размытие)
            if let mode = defaults.string(forKey: Self.backgroundModeSettingKey).flatMap(CallBackgroundMode.init(rawValue:)) {
                callBackgroundMode = mode
            } else {
                callBackgroundMode = defaults.bool(forKey: Self.backgroundBlurSettingKey) ? .blurMedium : .off
                defaults.set(callBackgroundMode.rawValue, forKey: Self.backgroundModeSettingKey)
            }
            MXLog.info("sTalk LiveKit: call settings — noiseSuppression=\(isNoiseSuppressed) background=\(callBackgroundMode.rawValue)")
            // DiagLog — MXLog не попадает в nse-events выгрузку с устройства
            DiagLog.write("Call", "settings: noiseSuppression=\(isNoiseSuppressed) background=\(callBackgroundMode.rawValue) wallpaper=\(UserDefaults.standard.integer(forKey: Self.wallpaperIndexSettingKey))")
        }
        return RoomOptions(defaultCameraCaptureOptions: Self.cameraCaptureOptions,
                           defaultAudioCaptureOptions: AudioCaptureOptions(noiseSuppression: isNoiseSuppressed,
                                                                           highpassFilter: isNoiseSuppressed),
                           defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 24),
                                                                           simulcast: true),
                           defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 48000),
                                                                           dtx: true),
                           adaptiveStream: true,
                           dynacast: true,
                           encryptionOptions: encryptionOptions)
    }

    // MARK: - Public API

    /// Connect to LiveKit SFU using intercepted credentials.
    /// - Parameters:
    ///   - wsURL: Full WebSocket URL from Element Call (wss://sfu.host/rtc?access_token=...)
    ///   - token: The extracted access_token JWT
    /// Connect to LiveKit SFU.
    /// - Parameters:
    ///   - wsURL: Full WebSocket URL from Element Call
    ///   - token: The extracted access_token JWT
    ///   - speakerByDefault: If true, start with speaker; if false, earpiece (1:1 calls)
    func connect(wsURL: String, token: String, speakerByDefault: Bool = false) async throws {
        let baseURL = extractBaseURL(from: wsURL)
        MXLog.info("sTalk LiveKit: Connecting to \(baseURL)")

        // Store for potential reconnection
        reconnectURL = baseURL
        reconnectToken = token
        wasE2EE = false
        savedKeyProvider = nil
        savedSpeakerDefault = speakerByDefault

        // Configure iOS audio session for VoIP BEFORE connecting
        configureAudioSession(speakerByDefault: speakerByDefault)

        let connectOptions = ConnectOptions(autoSubscribe: true)
        // STMOB-164: снижение нагрева. adaptiveStream — мелкие/невидимые тайлы
        // получают низкое разрешение или паузятся (меньше декода+рендера+SFrame
        // decrypt). dynacast — не слать simulcast-слои, которые никто не смотрит.
        // Камера 720p вместо 1080p, fps 24, битрейт 2 Mbps, audio DTX (не слать
        // в тишине) — меньше энкод/радио, на телефоне в сетке незаметно.
        let roomOptions = makeRoomOptions()

        try await room.connect(url: baseURL, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        MXLog.info("sTalk LiveKit: Connected to room \(room.name ?? "unknown")")
        updateState()
    }

    /// Connect with E2EE enabled (per-participant keys, manual subscribe)
    func connectWithE2EE(wsURL: String, token: String, keyProvider: BaseKeyProvider, speakerByDefault: Bool = false) async throws {
        let baseURL = extractBaseURL(from: wsURL)
        MXLog.info("sTalk LiveKit: Connecting with E2EE to \(baseURL)")

        reconnectURL = baseURL
        reconnectToken = token
        wasE2EE = true
        savedKeyProvider = keyProvider
        savedSpeakerDefault = speakerByDefault

        configureAudioSession(speakerByDefault: speakerByDefault)

        let encryptionOptions = EncryptionOptions(keyProvider: keyProvider,
                                                  encryptionType: .gcm)

        let connectOptions = ConnectOptions(autoSubscribe: true // Subscribe immediately — SFrame handles decrypt when keys arrive
        )
        // STMOB-164: см. комментарий в connect() — adaptiveStream/dynacast + 720p/24/2Mbps/DTX для снижения нагрева.
        let roomOptions = makeRoomOptions(encryptionOptions: encryptionOptions)

        try await room.connect(url: baseURL, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        MXLog.info("sTalk LiveKit: Connected with E2EE to room \(room.name ?? "unknown")")

        // STMOB-101: diagnose — Molly reports egress sees bondar's tracks без SFrame
        // header (e2eeDecryptOK=Fail=Passthrough=SIF=0 = plaintext Opus). По SDK
        // wiring должно быть encryption=GCM на publishTrack. Логируем фактическое
        // состояние e2eeManager сразу после connect, до setMicrophone/setCamera.
        // Если frameEncryptionType=.none → setup() не сработал.
        let mgr = room.e2eeManager
        let frameType = mgr?.frameEncryptionType
        DiagLog.write("E2EE_DEBUG", "post-connect: e2eeManager=\(mgr == nil ? "nil" : "present"), frameEncryptionType=\(String(describing: frameType))")

        updateState()
    }

    func disconnect() async {
        reconnectURL = nil
        reconnectToken = nil
        savedKeyProvider = nil
        reconnectAttempt = 0
        hasReadCallSettings = false
        blurProcessor = nil
        orientationProcessor = nil
        hasGatedEngineForCall = false
        stopEgressWatchdog()
        #if canImport(UIKit)
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        #endif
        await room.disconnect()
        MXLog.info("sTalk LiveKit: Disconnected")
        os_log(.info, log: livekitLog, "Disconnected (user-initiated)")
        updateState()
    }

    /// Build 45 фичефлаг — camera unpublish/publish после Quick reconnect. Упал на физе:
    /// и video, и audio встают после reset. Отключено по умолчанию, SDK с iceRestart
    /// продолжает ICE restart (build 44 behavior): audio обычно выживает, video на вебе — нет.
    private static let kResetCameraAfterQuickReconnect = false

    /// ICE restart на живых peer connections — без полного teardown как build 41/42.
    /// Используется при смене сетевого интерфейса (wifi↔cellular). SDK вызывает
    /// startReconnect(reason: .debug) → quickReconnectSequence с iceRestart на publisher.
    /// На failure SDK сам fallback на .full через retry logic (Room+Engine.swift:414).
    func attemptQuickReconnect(trigger: String) async {
        guard connectionState == .connected else {
            os_log(.info, log: livekitLog, "Quick reconnect skipped — state=%{public}@ trigger=%{public}@",
                   "\(connectionState)", trigger)
            return
        }
        os_log(.info, log: livekitLog, "Quick reconnect starting — trigger=%{public}@", trigger)
        do {
            try await room.debug_simulate(scenario: .quickReconnect)
            os_log(.info, log: livekitLog, "Quick reconnect SUCCESS — trigger=%{public}@", trigger)
            if Self.kResetCameraAfterQuickReconnect {
                await resetCameraAfterReconnect()
            }
        } catch {
            os_log(.error, log: livekitLog, "Quick reconnect FAIL — trigger=%{public}@ error=%{public}@",
                   trigger, "\(error)")
        }
    }

    /// Пересоздаёт camera publication — на физ устройстве AVCaptureSession после iceRestart
    /// продолжает получать frames локально, но они не долетают до publisher track.
    /// Симптом: веб видит только audio, video чёрное. Fix: unpublish+publish camera.
    /// Выполняется только если камера была активна и не muted до reconnect.
    private func resetCameraAfterReconnect() async {
        guard let publication = room.localParticipant.firstCameraPublication,
              publication.track != nil,
              !publication.isMuted else {
            os_log(.info, log: livekitLog, "Camera reset skipped — no active publication")
            return
        }
        os_log(.info, log: livekitLog, "Resetting camera publication after reconnect")
        do {
            try await setCamera(enabled: false)
            try await setCamera(enabled: true)
            os_log(.info, log: livekitLog, "Camera reset SUCCESS")
        } catch {
            os_log(.error, log: livekitLog, "Camera reset FAIL: %{public}@", "\(error)")
        }
    }

    func setCamera(enabled: Bool) async throws {
        #if targetEnvironment(simulator)
        if let publication = room.localParticipant.firstCameraPublication,
           let track = publication.track as? LocalVideoTrack {
            if enabled {
                try await track.unmute()
            } else {
                try await track.mute()
            }
        } else if enabled {
            try await publishSimulatorVideoTrack()
        }
        #else
        // Фон при СВЕЖЕМ publish: аттач после setCamera оставляет первые кадры
        // (~1-7 @ 24fps) необработанными в эфире — SDK начинает слать до возврата
        // publish. При активном режиме и отсутствии publication создаём трек
        // с уже привязанным процессором; unmute-путь безопасен (capturer жив).
        if enabled, publishCameraWithoutProcessor, room.localParticipant.firstCameraPublication == nil {
            // Диагностический путь после мёртвого захвата: голая камера, без нашей
            // обработки кадров. Фон при этом не применяется — это осознанный размен
            // на время звонка: видео без фона лучше, чем чёрный экран у собеседника.
            let track = LocalVideoTrack.createCameraTrack(options: Self.cameraCaptureOptions)
            _ = try await room.localParticipant.publish(videoTrack: track)
            blurProcessor = nil
            orientationProcessor = nil
            DiagLog.write("Call", "камера: публикую БЕЗ процессора (проверка мёртвого захвата)")
            verifyCaptureStarted(track: track, withoutProcessor: true)
        } else if enabled, room.localParticipant.firstCameraPublication == nil {
            // Свежий publish всегда с процессором: фон (блюр/обои) или, если фон
            // выключен, штамп ориентации (rotation-метаданные — см. DeviceOrientationTracker)
            let processor: LiveKit.VideoProcessor
            if let blur = makeBackgroundProcessor() {
                blurProcessor = blur
                processor = blur
            } else {
                let stamp = StalkOrientationProcessor()
                orientationProcessor = stamp
                processor = stamp
            }
            let track = LocalVideoTrack.createCameraTrack(options: Self.cameraCaptureOptions, processor: processor)
            _ = try await room.localParticipant.publish(videoTrack: track)
            DeviceOrientationTracker.shared.setFrontCamera(Self.cameraCaptureOptions.position != .back)
            MXLog.info("sTalk LiveKit: Camera published with pre-attached processor")
            DiagLog.write("Call", "blur: camera published with PRE-ATTACHED processor")
            verifyCaptureStarted(track: track)
        } else {
            try await room.localParticipant.setCamera(enabled: enabled)
            if enabled {
                applyBlurIfNeeded()
            }
        }
        if enabled {
            enableBackgroundCameraAccessIfPossible()
            attachOutboundStatsLogger()
        }
        #endif
        updateState()
    }

    /// STMOB-282: повесить съём метрик на опубликованный видеотрек.
    private func attachOutboundStatsLogger() {
        guard let track = room.localParticipant.firstCameraPublication?.track else { return }
        track.add(delegate: outboundStatsLogger)
    }

    /// STMOB-277: разрешить камере снимать, когда приложение свёрнуто.
    /// По умолчанию система глушит захват при уходе в фон — поэтому в системном
    /// окне звонка наше видео пропадало, и никакое окно его не вернуло бы.
    /// С iOS 18 приложение с голосовым фоновым режимом (у нас он объявлен) может
    /// продолжать снимать, но только если попросит об этом ЯВНО. Ручка есть в SDK
    /// (`CameraCapturer.isMultitaskingAccessEnabled`), мы её не трогали ни разу.
    ///
    /// Проверку поддержки делаем ПОСЛЕ проверки «уже включено»: она перенастраивает
    /// сессию захвата (beginConfiguration/commitConfiguration) и на каждом вызове
    /// setCamera обходилась бы дороже, чем сама польза.
    private func enableBackgroundCameraAccessIfPossible() {
        #if !targetEnvironment(simulator)
        guard let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }

        if capturer.isMultitaskingAccessEnabled { return }

        guard capturer.isMultitaskingAccessSupported else {
            DiagLog.write("Call", "камера в фоне: устройство не поддерживает — своё видео при сворачивании замрёт")
            return
        }

        capturer.isMultitaskingAccessEnabled = true
        DiagLog.write("Call", "камера в фоне: доступ включён")
        MXLog.info("sTalk LiveKit: multitasking camera access enabled")
        #endif
    }

    /// Switch between front and back camera
    func switchCamera() async throws {
        #if !targetEnvironment(simulator)
        guard let publication = room.localParticipant.firstCameraPublication else {
            MXLog.warning("sTalk LiveKit: switchCamera — no camera publication")
            return
        }
        guard let track = publication.track as? LocalVideoTrack else {
            MXLog.warning("sTalk LiveKit: switchCamera — track is not LocalVideoTrack")
            return
        }
        guard let source = track.capturer as? CameraCapturer else {
            MXLog.warning("sTalk LiveKit: switchCamera — capturer is not CameraCapturer, type: \(type(of: track.capturer))")
            return
        }
        let result = try await source.switchCameraPosition()
        DeviceOrientationTracker.shared.setFrontCamera(source.options.position == .front)
        MXLog.info("sTalk LiveKit: Camera switched, result=\(result)")
        #endif
    }

    func setMicrophone(enabled: Bool) async throws {
        #if targetEnvironment(simulator)
        // На симуляторе track.mute()/unmute() кидает Audio Engine Error -4010
        // (WebRTC audio engine на симе не поддерживает re-activation).
        // Вместо mute делаем полный unpublish, при enable — fresh publish.
        let existing = room.localParticipant.audioTracks.first(where: { $0.source == .microphone })
        if enabled {
            if existing == nil {
                try await publishSimulatorAudioTrack()
            }
        } else if let publication = existing as? LocalTrackPublication {
            try await room.localParticipant.unpublish(publication: publication)
        }
        #else
        try await room.localParticipant.setMicrophone(enabled: enabled)
        #endif
    }

    /// Log diagnostic info about local tracks (for debugging publish issues)
    func logTrackDiagnostics() {
        let lp = room.localParticipant
        let audioTracks = lp.audioTracks
        let videoTracks = lp.videoTracks
        MXLog.info("sTalk LiveKit diagnostics: identity=\(String(describing: lp.identity)), audioTracks=\(audioTracks.count), videoTracks=\(videoTracks.count)")
        for pub in audioTracks {
            MXLog.info("sTalk LiveKit audio track: sid=\(String(describing: pub.sid)), source=\(pub.source), track=\(pub.track != nil ? "exists" : "nil")")
        }
        for pub in videoTracks {
            MXLog.info("sTalk LiveKit video track: sid=\(String(describing: pub.sid)), source=\(pub.source), track=\(pub.track != nil ? "exists" : "nil")")
        }
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: Running on SIMULATOR — camera unavailable, audio may have WebRTC limitations")
        #endif
    }

    /// Toggle hand raise via participant metadata
    @Published private(set) var isHandRaised = false

    func setHandRaise(enabled: Bool) async throws {
        isHandRaised = enabled
        // Encode hand raise state in participant metadata as JSON
        let metadata = enabled ? "{\"hand_raised\": true}" : "{}"
        try await room.localParticipant.set(metadata: metadata)
        MXLog.info("sTalk LiveKit: Hand raise \(enabled ? "raised" : "lowered")")
        // STMOB-152 build 176: DiagLog для realtime correlation с Molly
        // hand raise bridge (STALK-302 Phase 2). iOS publishes LiveKit
        // metadata — meet-app должен видеть через ParticipantMetadataChanged.
        DiagLog.write("Call", "hand raise OUTGOING setMetadata raised=\(enabled)")
    }

    /// Toggle screen sharing
    @Published private(set) var isScreenSharing = false

    /// Текущий режим фона звонка (выкл / блюр ×3 / обои). Читается из настроек при
    /// connect, меняется вживую из меню ••• через setCallBackground(_:).
    @Published private(set) var callBackgroundMode: CallBackgroundMode = .off

    /// Toggle noise suppression (enhanced)
    @Published private(set) var isNoiseSuppressed = false

    func setScreenShare(enabled: Bool) async throws {
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: Screen sharing not available on simulator")
        #else
        try await room.localParticipant.setScreenShare(enabled: enabled)
        // STMOB-235: SDK для screen-share делает unpublish (а не mute, как у
        // камеры) — путь didUpdateIsMuted → updateState не срабатывает, и своя
        // плитка оставалась с мёртвым треком. Пересчитываем состояние явно;
        // страховка на случай, если делегат didUnpublishTrack не придёт.
        // isScreenSharing здесь НЕ присваиваем: он выводится из публикации в
        // updateState() — иначе флаг расходится с реальностью на republish SDK.
        updateState()
        if enabled {
            startScreenShareWatchdog()
        } else {
            stopScreenShareWatchdog()
        }
        DiagLog.write("Call", "screen share \(enabled ? "started" : "stopped"), localVideoTrack=\(localVideoTrack != nil)")
        MXLog.info("sTalk LiveKit: Screen share \(enabled ? "started" : "stopped")")
        #endif
    }

    // MARK: - Media egress watchdog & recovery (STMOB-262)

    /// Ватчдог доставки. Держим сильной ссылкой: SDK хранит делегатов трека слабо,
    /// и без этого поля он тихо умрёт, а «детектор обрыва» перестанет работать,
    /// никак об этом не сообщив.
    private var egressWatchdog: MediaEgressWatchdog?
    /// Идёт попытка восстановления — экран звонка не закрываем и не запускаем
    /// вторую лестницу параллельно.
    @Published private(set) var isRecovering = false
    private var lastRecoveryAt: Date?
    private var recoveryCycles = 0
    /// Задача лестницы. Храним, чтобы отменять при завершении звонка — иначе она
    /// доигрывает поверх уже закрытой сессии и держит isRecovering.
    private var recoveryTask: Task<Void, Never>?

    /// Ремонт делаем только штатными путями SDK. Ручной unpublish/publish камеры
    /// уже убивал и видео, и ЗВУК (build 45, пришлось выключать killswitch'ем).
    private static let kMaxRecoveryCycles = 2
    /// Зонды первого кадра на чужих видеотреках — держим ссылки, SDK хранит рендереры слабо.
    private var remoteFrameProbes: [FirstFrameProbe] = []
    /// Перепубликация камеры при мёртвом захвате — одна на звонок.
    private var didRestartDeadCapture = false
    /// Следующую публикацию камеры делать БЕЗ процессора. Ставится только после
    /// доказанного мёртвого захвата: если кадры пойдут — виноват процессор, если
    /// нет — дело в самом капчере, и это тоже ответ.
    private var publishCameraWithoutProcessor = false
    private static let kRecoveryCooldown: TimeInterval = 30

    func noteNetworkPath(interface: String) {
        if interface == "none" {
            egressWatchdog?.noteNetworkLost()
        } else {
            egressWatchdog?.noteNetworkRestored()
        }
    }

    private func startEgressWatchdog() {
        guard egressWatchdog == nil else { return }
        didRestartDeadCapture = false
        publishCameraWithoutProcessor = false
        remoteFrameProbes.removeAll()
        egressWatchdog = MediaEgressWatchdog { [weak self] reason in
            self?.recoverEgress(reason: reason)
        } onCaptureDead: { [weak self] kind in
            self?.restartDeadCapture(kind: kind)
        }
        DiagLog.write("Call", "egress watchdog: старт")
    }

    private func stopEgressWatchdog() {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard egressWatchdog != nil else {
            isRecovering = false
            return
        }
        egressWatchdog = nil
        recoveryCycles = 0
        isRecovering = false
        // Гасим таймеры статистики: они не только считают, но и гонят метрики в SFU
        // раз в секунду на каждый наблюдаемый трек.
        let tracks: [LocalTrackPublication] = (room.localParticipant.videoTracks + room.localParticipant.audioTracks)
            .compactMap { $0 as? LocalTrackPublication }
        Task {
            for pub in tracks {
                await pub.track?.set(reportStatistics: false)
            }
        }
        DiagLog.write("Call", "egress watchdog: стоп")
    }

    /// Вешает наблюдение на локальную публикацию (камера/демонстрация).
    /// `set(reportStatistics:)` включает у SDK таймер статистики 1 Гц на ЭТОМ треке —
    /// поэтому включаем точечно, а не через RoomOptions (там это включило бы таймер
    /// на каждом удалённом треке — прямой вклад в нагрев, с которым боролись в 241).
    private func observeEgress(for publication: LocalTrackPublication) {
        // Микрофон включаем тоже: в аудио-звонке видео-треков нет вовсе, и без него
        // детектор молчал бы ровно там, где обрыв заметнее всего.
        guard publication.source == .camera || publication.source == .screenShareVideo || publication.source == .microphone,
              let track = publication.track else { return }
        startEgressWatchdog()
        guard let watchdog = egressWatchdog else { return }
        track.add(delegate: watchdog)
        Task {
            await track.set(reportStatistics: true)
            DiagLog.write("Call", "egress: наблюдаю \(publication.source) sid=\(publication.sid.stringValue)")
        }
    }

    /// Через несколько секунд после публикации у живой камеры обязаны быть размеры:
    /// они берутся из первого кадра. Их отсутствие — это ровно тот отказ, который
    /// собеседник видит как чёрный экран, а мы раньше не видели никак (в логе он
    /// проявлялся лишь косвенно, предупреждением SDK при отписке трека).
    private func verifyCaptureStarted(track: LocalVideoTrack, withoutProcessor: Bool = false) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            guard room.localParticipant.firstCameraPublication?.track === track else { return }
            guard track.dimensions == nil else {
                if withoutProcessor {
                    DiagLog.write("Call", "камера: без процессора кадры ПОШЛИ — виноват процессор кадров")
                }
                return
            }
            if withoutProcessor {
                DiagLog.write("Call", "камера: кадров нет и БЕЗ процессора — источник мёртв, не в обработке дело")
                return
            }
            DiagLog.write("Call", "камера: за 4с НИ ОДНОГО кадра (нет размеров у трека) → перепубликую")
            restartDeadCapture(kind: "camera")
        }
    }

    /// Захват мёртв: трек включён, а камера не отдаёт кадров. ICE restart тут не
    /// поможет — отправлять нечего. Единственное честное лечение: пересоздать
    /// публикацию камеры (вместе с процессором фона, который к ней привязан).
    /// Одна попытка на звонок: если и она не помогла, проблема не в публикации,
    /// и повтор только моргал бы картинкой собеседнику.
    private func restartDeadCapture(kind: String) {
        guard kind == "camera" else { return }
        guard !didRestartDeadCapture else {
            DiagLog.write("Call", "захват мёртв повторно — перепубликация уже была, не повторяю")
            return
        }
        guard connectionState == .connected, sdkReconnectMode == nil else { return }
        guard UIApplication.shared.applicationState == .active else {
            // В фоне iOS законно останавливает камеру — это не отказ.
            DiagLog.write("Call", "захват мёртв, но приложение не активно — это фон, не чиню")
            return
        }
        guard room.localParticipant.firstCameraPublication != nil else { return }

        didRestartDeadCapture = true
        publishCameraWithoutProcessor = true
        DiagLog.write("Call", "захват мёртв → перепубликую камеру без процессора")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await setCamera(enabled: false)
                try await Task.sleep(for: .milliseconds(300))
                try await setCamera(enabled: true)
                DiagLog.write("Call", "захват мёртв: перепубликация выполнена")
            } catch {
                DiagLog.write("Call", "захват мёртв: перепубликация НЕ УДАЛАСЬ — \(error.localizedDescription)")
            }
        }
    }

    /// Лестница восстановления. Ступени — только публичные пути SDK; после каждой
    /// даём окно на проверку и рассылаем ключ заново (после переподключения на той
    /// стороне может не быть нашего ключа).
    private func recoverEgress(reason: String) {
        guard !isRecovering else { return }
        guard connectionState == .connected else {
            DiagLog.write("Call", "egress: ремонт пропущен — connState=\(connectionState)")
            return
        }
        guard sdkReconnectMode == nil else {
            DiagLog.write("Call", "egress: ремонт пропущен — SDK уже переподключается (\(sdkReconnectMode.map { "\($0)" } ?? "?"))")
            return
        }
        if let lastRecoveryAt, Date().timeIntervalSince(lastRecoveryAt) < Self.kRecoveryCooldown {
            DiagLog.write("Call", "egress: ремонт пропущен — cooldown")
            return
        }
        guard recoveryCycles < Self.kMaxRecoveryCycles else {
            DiagLog.write("Call", "egress: лимит попыток исчерпан — дальше молчу, чинить нечем")
            egressWatchdog?.noteRepairExhausted()
            return
        }

        isRecovering = true
        recoveryCycles += 1
        lastRecoveryAt = Date()
        let cycle = recoveryCycles
        DiagLog.write("Call", "egress РЕМОНТ #\(cycle) старт (\(reason))")

        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isRecovering = false
                    self.recoveryTask = nil
                    DiagLog.write("Call", "egress ремонт #\(cycle): конец")
                }
            }

            let before = egressWatchdog?.totalBytesSent() ?? 0

            // Ступень 1 — ICE restart: капчеры и публикации не трогаются вовсе.
            // Запускаем и НЕ ждём: `debug_simulate` внутри ждёт всю retry-лестницу
            // SDK (до 10 попыток с паузами — десятки секунд), а нам нужно окно 8с.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.room.debug_simulate(scenario: .quickReconnect)
                } catch {
                    DiagLog.write("Call", "egress ремонт #\(cycle): ICE restart отвергнут (\(error.localizedDescription))")
                }
            }
            DiagLog.write("Call", "egress ремонт #\(cycle): ступень 1 — ICE restart")
            encryptionKeyRebroadcastSubject.send(())

            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, egressWatchdog != nil else { return }

            // Успех определяем по РОСТУ БАЙТОВ, а не по отсутствию исключения:
            // SDK глотает ошибки своей лестницы и возвращается «без ошибки».
            let afterStage1 = egressWatchdog?.totalBytesSent() ?? 0
            if afterStage1 > before {
                DiagLog.write("Call", "egress ремонт #\(cycle): ступень 1 ПОМОГЛА (+\(afterStage1 - before) байт) — не эскалирую")
                return
            }

            // Ступень 2 — полный реконнект силами SDK. Дорогая: он делает teardown и
            // переопубликацию треков, а заодно на секунду опустошает список участников.
            // Поэтому только когда ступень 1 доказанно не помогла.
            guard connectionState == .connected || connectionState == .reconnecting else {
                DiagLog.write("Call", "egress ремонт #\(cycle): ступень 2 пропущена — connState=\(connectionState)")
                return
            }
            // Полный реконнект переопубликовывает треки, а `republishAllTracks` в SDK
            // обрывает цикл на первой неудачной публикации. В фоне демонстрация
            // экрана заново не поднимется (in-app ReplayKit-захват там мёртв), и мы
            // рискуем остаться вообще без публикаций — включая микрофон.
            #if canImport(UIKit)
            guard UIApplication.shared.applicationState == .active else {
                DiagLog.write("Call", "egress ремонт #\(cycle): ступень 2 пропущена — приложение не активно")
                return
            }
            #endif
            DiagLog.write("Call", "egress ремонт #\(cycle): ступень 2 — полный реконнект (байты так и стоят)")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.room.debug_simulate(scenario: .fullReconnect)
                } catch {
                    DiagLog.write("Call", "egress ремонт #\(cycle): полный реконнект отвергнут (\(error.localizedDescription))")
                }
            }
            encryptionKeyRebroadcastSubject.send(())

            // Жёсткий потолок: дольше держать «восстанавливаем» нельзя — на этом
            // висят и плашка в UI, и окно грации, и блокировка второго цикла.
            try? await Task.sleep(for: .seconds(12))
        }
    }

    // MARK: - Screen share watchdog (STMOB-234)

    /// Ватчдог in-app ReplayKit-захвата. Демонстрация идёт через
    /// `RPScreenRecorder.startCapture` (broadcast extension в сборку не входит),
    /// а системная запись экрана забирает тот же синглтон — поток кадров молча
    /// встаёт: SDK об этом не узнаёт (errorHandler у startCapture игнорируется,
    /// авто-unpublish есть только для BroadcastScreenCapturer). Ватчдог видит
    /// остановку кадров и потерю доступности рекордера и гасит демонстрацию
    /// честно, вместо застывшего кадра у всех участников.
    private var screenShareWatchdog: ScreenShareWatchdog?
    /// Трек, на который навешен ватчдог. Снимать рендерер надо именно по этой
    /// ссылке: к моменту `didUnpublishTrack` публикация из состояния SDK уже
    /// удалена, и найти трек через `firstScreenSharePublication` уже нельзя.
    private weak var watchedScreenShareTrack: VideoTrack?

    private func startScreenShareWatchdog() {
        stopScreenShareWatchdog()
        guard let track = room.localParticipant.firstScreenSharePublication?.track as? VideoTrack else {
            DiagLog.write("Call", "screen share watchdog: НЕТ трека — пропускаю")
            return
        }
        let watchdog = ScreenShareWatchdog { [weak self] reason in
            guard let self, self.isScreenSharing else { return }
            DiagLog.write("Call", "screen share ПЕРЕХВАЧЕН (\(reason)) → останавливаю демонстрацию")
            MXLog.warning("sTalk LiveKit: screen capture lost (\(reason)) — stopping share")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.setScreenShare(enabled: false)
                    self.screenShareInterruptedSubject.send(())
                } catch {
                    // Стоп не прошёл (например, в момент реконнекта). Ватчдог себя уже
                    // разоружил в tick — приводим состояние к реальности и, если
                    // демонстрация всё ещё опубликована, поднимаем наблюдение заново,
                    // иначе авто-стопа не будет до конца звонка.
                    DiagLog.write("Call", "screen share авто-стоп FAIL: \(error.localizedDescription)")
                    self.updateState()
                    if self.room.localParticipant.firstScreenSharePublication?.track != nil {
                        self.startScreenShareWatchdog()
                    } else {
                        self.stopScreenShareWatchdog()
                    }
                }
            }
        }
        track.add(videoRenderer: watchdog)
        watchdog.start()
        screenShareWatchdog = watchdog
        watchedScreenShareTrack = track
    }

    private func stopScreenShareWatchdog() {
        guard let watchdog = screenShareWatchdog else { return }
        watchedScreenShareTrack?.remove(videoRenderer: watchdog)
        watchedScreenShareTrack = nil
        watchdog.stop()
        screenShareWatchdog = nil
    }

    /// Демонстрацию оборвали снаружи (системная запись/ошибка ReplayKit) —
    /// экран звонка показывает пользователю, почему шаринг погас.
    let screenShareInterruptedSubject = PassthroughSubject<Void, Never>()

    /// Strong-ссылка на процессор: SDK держит `capturer.processor` weak,
    /// без неё фон молча отвалится после первого прохода autorelease.
    /// Режим-интент живёт в callBackgroundMode — он переживает пересоздание
    /// камера-трека (toggle камеры, foreground re-enable, reconnect), attach
    /// самовосстанавливается в applyBlurIfNeeded().
    private var blurProcessor: StalkBackgroundBlurProcessor?
    /// Штамп-процессор ориентации (фон выключен): правит rotation-метаданные кадров
    private var orientationProcessor: StalkOrientationProcessor?

    /// Смена режима фона (выкл / блюр ×3 / обои) — вживую из меню ••• звонка.
    /// Если камеры сейчас нет — режим сохраняется и применится при её включении.
    func setCallBackground(_ mode: CallBackgroundMode) {
        callBackgroundMode = mode
        DiagLog.write("Call", "background toggle -> \(mode.rawValue)")
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: call background is a no-op on the simulator (no camera)")
        #else
        // Смена режима = новый процессор (у него зашит background в init)
        blurProcessor = nil
        applyBlurIfNeeded()
        #endif
    }

    /// Процессор под текущий режим. Обои: индекс из настроек, ассеты call_wallpaper_1..6;
    /// при сбое загрузки — фолбэк на среднее размытие (лучше, чем молча без фона).
    private func makeBackgroundProcessor() -> StalkBackgroundBlurProcessor? {
        switch callBackgroundMode {
        case .off:
            return nil
        case .blurLight:
            return StalkBackgroundBlurProcessor(background: .blur(radius: 7))
        case .blurMedium:
            return StalkBackgroundBlurProcessor(background: .blur(radius: 12))
        case .blurStrong:
            return StalkBackgroundBlurProcessor(background: .blur(radius: 22))
        case .wallpaper:
            let stored = UserDefaults.standard.integer(forKey: Self.wallpaperIndexSettingKey)
            let index = (1...8).contains(stored) ? stored : 1
            guard let uiImage = UIImage(named: "images/call_wallpaper_\(index)"),
                  let ciImage = CIImage(image: uiImage) else {
                DiagLog.write("Call", "blur: wallpaper \(index) FAILED to load — fallback to blur")
                return StalkBackgroundBlurProcessor(background: .blur(radius: 12))
            }
            return StalkBackgroundBlurProcessor(background: .image(ciImage))
        }
    }

    /// Attach/detach фон-процессора на текущий камера-трек (self-healing).
    /// Вызывается из setCamera(true), didPublishTrack и setCallBackground —
    /// one-shot attach терялся при каждом пересоздании CameraCapturer.
    /// Только камера (firstCameraPublication) — screen-share не трогаем.
    private func applyBlurIfNeeded() {
        #if !targetEnvironment(simulator)
        guard callBackgroundMode != .off else {
            blurProcessor = nil
            // Фон выключен — но штамп ориентации нужен всегда (иначе landscape «боком»)
            if let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack {
                if let existing = orientationProcessor, track.capturer.processor === existing {
                    return
                }
                let stamp = StalkOrientationProcessor()
                orientationProcessor = stamp
                track.capturer.processor = stamp
                MXLog.info("sTalk LiveKit: call background off — orientation stamp attached")
                DiagLog.write("Call", "blur: detached (orientation stamp attached)")
            }
            return
        }
        guard let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack else {
            DiagLog.write("Call", "blur: mode=\(callBackgroundMode.rawValue), но camera publication нет — аттач отложен")
            return
        }
        if let existing = blurProcessor, track.capturer.processor === existing {
            return // уже приаттачен к этому capturer'у
        }
        // Свежий процессор на каждый новый capturer: у SDK per-capturer serial queue,
        // а процессор не потокобезопасен — шаринг одного инстанса между поколениями
        // capturer'а = гонка на CIFilter/кешах в момент пересоздания publication.
        guard let processor = makeBackgroundProcessor() else { return }
        blurProcessor = processor
        track.capturer.processor = processor
        MXLog.info("sTalk LiveKit: call background attached to camera capturer")
        DiagLog.write("Call", "blur: attached to camera capturer (self-heal, \(callBackgroundMode.rawValue))")
        #endif
    }

    func setSpeaker(enabled: Bool) {
        // Route through LiveKit's own preference. It owns the AVAudioSession during a call and
        // switches the mode on its managed session (.videoChat = speaker / .voiceChat = earpiece).
        // Do NOT also call overrideOutputAudioPort here: mixing a manual port override with LiveKit's
        // mid-call reconfigure dropped the audio entirely (the muting regression). Setting only the
        // preference lets LiveKit switch cleanly and the route sticks (it won't snap back to speaker).
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: speaker toggle is a no-op on the simulator")
        #else
        speakerRoutePreferred = enabled
        if Self.kCallKitFullLifecycle {
            applySpeakerRoute(enabled)
            MXLog.info("sTalk LiveKit: Speaker \(enabled ? "ON" : "OFF") via overrideOutputAudioPort (CallKit owns session)")
        } else {
            AudioManager.shared.isSpeakerOutputPreferred = enabled
            MXLog.info("sTalk LiveKit: Speaker \(enabled ? "ON (speaker)" : "OFF (earpiece)") via isSpeakerOutputPreferred")
        }
        #endif
    }

    // MARK: - Simulator Fake Tracks

    #if targetEnvironment(simulator)
    private var simulatorVideoTimer: Timer?
    private var simulatorBufferCapturer: BufferCapturer?

    /// Publish a generated color-cycling video track on simulator (no camera available)
    private func publishSimulatorVideoTrack() async throws {
        let track = LocalVideoTrack.createBufferTrack(name: "camera",
                                                      source: .camera,
                                                      options: BufferCaptureOptions())
        guard let capturer = track.capturer as? BufferCapturer else { return }
        simulatorBufferCapturer = capturer

        // Generate first frame before publishing (required by SDK)
        let firstFrame = createColorFrame(width: 640, height: 480, hue: 0.55)
        capturer.capture(firstFrame, timeStampNs: VideoCapturer.createTimeStampNs())

        _ = try await room.localParticipant.publish(videoTrack: track)
        MXLog.info("sTalk LiveKit: Published simulator video track (generated color)")

        // Timer to generate frames at ~15fps
        var hue: CGFloat = 0.0
        simulatorVideoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self, let capturer = self.simulatorBufferCapturer else { return }
            hue += 0.002
            if hue > 1.0 { hue = 0.0 }
            let frame = self.createColorFrame(width: 640, height: 480, hue: hue)
            capturer.capture(frame, timeStampNs: VideoCapturer.createTimeStampNs())
        }
    }

    /// Create a CVPixelBuffer with a solid color (hue-cycling gradient)
    private func createColorFrame(width: Int, height: Int, hue: CGFloat) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            fatalError("Failed to create pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let color = UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1.0)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let bVal = UInt8(b * 255)
        let gVal = UInt8(g * 255)
        let rVal = UInt8(r * 255)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = bVal // B
                row[offset + 1] = gVal // G
                row[offset + 2] = rVal // R
                row[offset + 3] = 255 // A
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Publish a real microphone audio track on simulator (Mac mic via WebRTC)
    private func publishSimulatorAudioTrack() async throws {
        let audioTrack = LocalAudioTrack.createTrack(name: "microphone")
        _ = try await room.localParticipant.publish(audioTrack: audioTrack)
        MXLog.info("sTalk LiveKit: Published simulator audio track (Mac microphone)")
    }
    #endif

    // MARK: - Audio Session

    // MARK: - Владение аудио-сессией (STMOB-261)

    /// Полный жизненный цикл CallKit: сессией владеет система, а не LiveKit.
    ///
    /// Выключатель на случай регресса звука: при `false` поведение ровно то, что
    /// шипится сегодня (LiveKit сам активирует сессию, CallKit гасится через секунду
    /// после ответа). Аудио — зона, которая уже дважды роняла звук (сага 214-224,
    /// build 45), поэтому откат должен быть в одну константу.
    /// Оба критичных дефекта ревью закрыты: состояние аудио-сессии повторяется
    /// подписчику (входящий больше не остаётся без звука) и движок гейтится один раз
    /// на звонок, а не на каждый connect (реконнект больше не глушит звук навсегда).
    /// Остаётся выключателем на случай регресса на устройстве.
    static let kCallKitFullLifecycle = true

    /// Последний запрошенный маршрут — переприменяем его при каждой активации
    /// сессии CallKit (после прерываний система возвращает маршрут по умолчанию).
    private var speakerRoutePreferred = false
    /// Движок гейтится один раз на звонок, а не на каждый connect (реконнект!).
    private var hasGatedEngineForCall = false

    /// Configure AVAudioSession for VoIP call before LiveKit connects.
    /// - Parameter speakerByDefault: If true, route audio to speaker initially (for group calls).
    ///   If false, route to earpiece (for 1:1 calls, like Telegram).
    func configureAudioSession(speakerByDefault: Bool = false) {
        speakerRoutePreferred = speakerByDefault
        #if !targetEnvironment(simulator)
        if Self.kCallKitFullLifecycle {
            // Сессию активирует CallKit — SDK не должен ни конфигурировать её, ни
            // активировать, иначе за неё схватятся оба владельца. Ровно этот класс
            // конфликта убивал звук в саге 214-224.
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
            AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
            // Движок не поднимаем, пока система не активирует сессию (didActivate).
            // Это штатный CallKit-путь SDK: «set up connections without touching the
            // audio device yet».
            // ТОЛЬКО на первом подключении звонка. На реконнекте (connect зовётся
            // повторно из attemptAutoReconnect) сессия CallKit уже активна, и система
            // НЕ пришлёт didActivate второй раз — выключенный здесь движок остался бы
            // выключенным до конца звонка. Ровно тот симптом, с которым боремся:
            // «после короткой потери сети друг друга не слышно».
            if !hasGatedEngineForCall {
                hasGatedEngineForCall = true
                do {
                    try AudioManager.shared.setEngineAvailability(.none)
                    DiagLog.write("Call", "audio: движок выключен до CallKit didActivate")
                } catch {
                    DiagLog.write("Call", "audio: setEngineAvailability(.none) FAIL \(error.localizedDescription)")
                }
            } else {
                DiagLog.write("Call", "audio: реконнект — движок не трогаем")
            }
        } else {
            // Прежняя модель: маршрут задаёт сам SDK своей ручкой (работает только
            // при включённой авто-конфигурации).
            AudioManager.shared.isSpeakerOutputPreferred = speakerByDefault
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
            if speakerByDefault {
                options.insert(.defaultToSpeaker)
            }
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: options)
            try session.setPreferredIOBufferDuration(0.005) // 5ms — reduces crackling
            try session.setPreferredSampleRate(48000)
            // При полном цикле CallKit активацию делает система: свой setActive здесь
            // — это как раз второй владелец, которого мы убираем.
            if !Self.kCallKitFullLifecycle {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            MXLog.info("sTalk LiveKit: Audio session configured — speaker=\(speakerByDefault), callKitOwned=\(Self.kCallKitFullLifecycle)")
        } catch {
            MXLog.error("sTalk LiveKit: Failed to configure audio session: \(error)")
        }
    }

    /// Аудио-сессия готова — поднимаем движок и применяем маршрут.
    /// - Parameter systemOwnsSession: `true` — сессию активировал CallKit;
    ///   `false` — система отказала в звонке, активируем сами (иначе звонок немой).
    func handleCallKitAudioActivated(systemOwnsSession: Bool) {
        #if !targetEnvironment(simulator)
        guard Self.kCallKitFullLifecycle else { return }
        if !systemOwnsSession {
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                DiagLog.write("Call", "audio: свой setActive FAIL \(error.localizedDescription)")
            }
        }
        applySpeakerRoute(speakerRoutePreferred)
        do {
            try AudioManager.shared.setEngineAvailability(.default)
            DiagLog.write("Call", "audio: сессия активна (system=\(systemOwnsSession)) → движок включён (speaker=\(speakerRoutePreferred))")
        } catch {
            DiagLog.write("Call", "audio: setEngineAvailability(.default) FAIL \(error.localizedDescription)")
        }
        #endif
    }

    /// CallKit деактивировал сессию — останавливаем движок.
    func handleCallKitAudioDeactivated() {
        #if !targetEnvironment(simulator)
        guard Self.kCallKitFullLifecycle else { return }
        do {
            try AudioManager.shared.setEngineAvailability(.none)
            DiagLog.write("Call", "audio: CallKit деактивировал сессию → движок выключен")
        } catch {
            DiagLog.write("Call", "audio: setEngineAvailability(.none) FAIL \(error.localizedDescription)")
        }
        #endif
    }

    /// Маршрут вывода. При полном цикле CallKit ручка SDK не работает (она действует
    /// только при авто-конфигурации), поэтому переключаем порт сами — и это теперь
    /// безопасно: SDK больше не переконфигурирует сессию под себя, драки нет.
    private func applySpeakerRoute(_ speaker: Bool) {
        #if !targetEnvironment(simulator)
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            MXLog.error("sTalk LiveKit: overrideOutputAudioPort failed: \(error)")
        }
        #endif
    }

    // MARK: - Helpers

    /// Extracts base URL from full WebSocket URL: wss://host/rtc?access_token=... → wss://host
    private func extractBaseURL(from wsURL: String) -> String {
        guard let url = URL(string: wsURL),
              let scheme = url.scheme,
              let host = url.host else {
            return wsURL
        }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func updateState() {
        connectionState = room.connectionState
        remoteParticipants = Array(room.remoteParticipants.values)
        localParticipant = room.localParticipant

        // STMOB-120: пересчитываем raisedHandsSIDs по текущим metadata всех
        // remote — нужно для случая когда юзер зашёл в звонок а у кого-то
        // уже рука поднята (didUpdateMetadata события не было).
        var current = Set<String>()
        for p in remoteParticipants {
            if let sid = p.sid?.stringValue, Self.parseHandRaised(p.metadata) {
                current.insert(sid)
            }
        }
        if current != raisedHandsSIDs {
            raisedHandsSIDs = current
        }

        // STMOB: get local video track, исключая muted publications.
        // setCamera(enabled: false) в LiveKit SDK НЕ unpublish'ит track —
        // только мьютит его (publication.isMuted = true). Без фильтра
        // localVideoTrack остаётся != nil, и observer в CallScreenViewModel
        // считает камеру включённой → state.isVideoEnabled возвращается в
        // true, иконка не обновляется, self-view продолжает рендериться.
        // didUpdateIsMuted уже дёргает updateState — теперь оно корректно
        // отразит mute как "track is nil".
        //
        // STMOB-234/235: и ТОЛЬКО камера. `videoTracks` — values словаря
        // публикаций, порядок недетерминирован, при демонстрации экрана сюда
        // попадал screen-share трек. Последствия были два:
        //   • своя плитка/PiP показывали экран вместо камеры, а после стопа
        //     демонстрации — застывший последний кадр (STMOB-235);
        //   • кнопка камеры «умирала» (STMOB-234): observer читает track != nil
        //     как «камера включена», тап → setCamera(false) → updateState →
        //     снова screen-share трек → isVideoEnabled откатывался в true.
        let cameraTrack = room.localParticipant.videoTracks
            .filter { $0.source == .camera }
            .compactMap { pub -> VideoTrack? in
                guard !pub.isMuted else { return nil }
                return pub.track as? VideoTrack
            }
            .first
        if (localVideoTrack == nil) != (cameraTrack == nil) {
            DiagLog.write("Call", "localVideoTrack → \(cameraTrack == nil ? "nil" : "camera") screenSharing=\(isScreenSharing)")
        }
        localVideoTrack = cameraTrack

        // STMOB-234: isScreenSharing выводим из ФАКТИЧЕСКОЙ публикации, а не из
        // намерения юзера. SDK при full reconnect / room move сам делает
        // republishAllTracks (unpublish + publish), и флаг-из-намерения после
        // такого цикла врал бы: кнопка «выключено», а экран продолжает уходить
        // участникам. Здесь же сходятся все пути: тап, внешний обрыв, republish.
        let sharing = room.localParticipant.firstScreenSharePublication?.track != nil
        if isScreenSharing != sharing {
            isScreenSharing = sharing
            DiagLog.write("Call", "isScreenSharing → \(sharing) (по публикации)")
        }
    }
}

// MARK: - RoomDelegate

extension LiveKitRoomManager: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            self.connectionState = connectionState
            MXLog.info("sTalk LiveKit: Connection state: \(oldConnectionState) → \(connectionState)")
            os_log(.info, log: livekitLog, "WS state: %{public}@ → %{public}@",
                   "\(oldConnectionState)", "\(connectionState)")
            // STMOB-126 build 151: видим в DiagLog моменты connect/disconnect/
            // reconnect — корреллируем с didPublishTrack (E2EE_DEBUG) чтобы
            // понять race condition при первом подключении (other participants
            // don't see/hear me).
            DiagLog.write("LiveKit", "connState \(oldConnectionState) → \(connectionState)")

            switch connectionState {
            case .connected:
                self.reconnectAttempt = 0
                self.updateState()
            case .disconnected:
                // Unexpected drop: try to reconnect silently a few times before giving up.
                if oldConnectionState == .connected || oldConnectionState == .reconnecting,
                   self.reconnectURL != nil, self.reconnectToken != nil {
                    os_log(.error, log: livekitLog, "Unexpected disconnect from %{public}@ — auto-reconnect",
                           "\(oldConnectionState)")
                    self.attemptAutoReconnect()
                }
            default:
                break
            }
        }
    }

    /// Attempt silent reconnect after WS drop. Max 3 attempts with 1s / 3s / 7s backoff.
    private func attemptAutoReconnect() {
        guard reconnectAttempt < reconnectMaxAttempts,
              let url = reconnectURL,
              let token = reconnectToken else {
            os_log(.error, log: livekitLog, "Auto-reconnect skipped attempt=%d", reconnectAttempt)
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delaySeconds: UInt64 = attempt == 1 ? 1 : (attempt == 2 ? 3 : 7)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard let self else { return }
            guard self.reconnectURL != nil else { return }
            os_log(.info, log: livekitLog, "Auto-reconnect attempt %d/%d after %ds",
                   attempt, self.reconnectMaxAttempts, Int(delaySeconds))
            do {
                if self.wasE2EE, let keyProvider = self.savedKeyProvider {
                    try await self.connectWithE2EE(wsURL: url, token: token, keyProvider: keyProvider,
                                                   speakerByDefault: self.savedSpeakerDefault)
                } else {
                    try await self.connect(wsURL: url, token: token,
                                           speakerByDefault: self.savedSpeakerDefault)
                }
                os_log(.info, log: livekitLog, "Auto-reconnect SUCCESS attempt=%d", attempt)
            } catch {
                os_log(.error, log: livekitLog, "Auto-reconnect FAIL attempt=%d: %{public}@", attempt, "\(error)")
                self.attemptAutoReconnect()
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        let sid = participant.sid?.stringValue ?? "nil"
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Participant joined: \(identity), sid=\(sid), totalRemote=\(self.remoteParticipants.count)")
            // STMOB-152 build 176: DiagLog для realtime correlation с Molly
            // server-side observation. Видим момент guest JOIN на iOS — после
            // этого должен прилететь incoming encryption_keys через
            // server fan-out (STALK-303).
            DiagLog.write("Call", "participant JOIN identity=\(identity) sid=\(sid) totalRemote=\(self.remoteParticipants.count)")
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        let sid = participant.sid?.stringValue ?? "nil"
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Participant left: \(identity), sid=\(sid), remainingRemote=\(self.remoteParticipants.count)")
            DiagLog.write("Call", "participant LEAVE identity=\(identity) sid=\(sid) remainingRemote=\(self.remoteParticipants.count)")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let pubKind = "\(publication.kind)"
        let pubName = publication.name
        let pubSource = "\(publication.source)"
        let isScreenShare = publication.name == Track.screenShareVideoName || publication.source == .screenShareVideo
        let identity = participant.identity?.stringValue ?? "?"
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Subscribed to track: \(pubKind) from \(identity)")
            // STMOB-114: видим в nse-events.log реально ли пришёл screen share track.
            DiagLog.write("Call", "track subscribed kind=\(pubKind) name=\(pubName) source=\(pubSource) isScreenShare=\(isScreenShare) muted=\(publication.isMuted) from=\(identity)")
            // Разбор «не вижу чужое видео» упирался в то, что подписка есть, а
            // дошли ли кадры — неизвестно. Зонд отвечает на это одной строкой.
            if let videoTrack = publication.track as? VideoTrack {
                let probe = FirstFrameProbe(label: "\(identity) \(pubSource)") { label, frame in
                    DiagLog.write("Call", "видео от \(label): ПЕРВЫЙ кадр \(frame.dimensions.width)x\(frame.dimensions.height)")
                } onResolutionChange: { label, oldWidth, oldHeight, newWidth, newHeight in
                    DiagLog.write("Call", "видео от \(label): разрешение \(oldWidth)x\(oldHeight) → \(newWidth)x\(newHeight)")
                }
                self.remoteFrameProbes.append(probe)
                videoTrack.add(videoRenderer: probe)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        let pubName = publication.name
        let isScreenShare = publication.name == Track.screenShareVideoName || publication.source == .screenShareVideo
        let identity = participant.identity?.stringValue ?? "?"
        Task { @MainActor in
            self.updateState()
            DiagLog.write("Call", "track unsubscribed name=\(pubName) isScreenShare=\(isScreenShare) from=\(identity)")
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        // «Собеседник выключил камеру» и «камера включена, а кадров нет» снаружи
        // выглядят одинаково: публикация есть в обоих случаях. Пишем состояние —
        // без этого разбор «не вижу чужое видео» упирается в догадки.
        let identity = participant.identity?.stringValue ?? "?"
        let source = "\(trackPublication.source)"
        Task { @MainActor in
            DiagLog.write("Call", "чужой трек \(source) от \(identity): \(isMuted ? "ВЫКЛЮЧЕН" : "включён")")
            self.updateState()
        }
    }

    /// STMOB-120: hand raise через participant.metadata. Element Call (web)
    /// устанавливает `{"hand_raised": true}` когда юзер поднимает руку
    /// (и пустой JSON `{}` когда опускает). Парсим metadata всех remote
    /// participants и собираем set SID'ов с raised hand для UI overlay.
    nonisolated func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        let sid = participant.sid?.stringValue
        let identity = participant.identity?.stringValue ?? "?"
        let isRaised = Self.parseHandRaised(metadata)
        Task { @MainActor in
            guard let sid else { return }
            if isRaised {
                self.raisedHandsSIDs.insert(sid)
            } else {
                self.raisedHandsSIDs.remove(sid)
            }
            MXLog.info("sTalk LiveKit: hand raise update sid=\(sid) raised=\(isRaised) total=\(self.raisedHandsSIDs.count)")
            // STMOB-152 build 176: DiagLog для realtime correlation с Molly
            // hand raise bridge. INCOMING metadata от remote participant
            // (другой iOS native, либо guest meet-app после Molly patch).
            DiagLog.write("Call", "hand raise INCOMING identity=\(identity) sid=\(sid) raised=\(isRaised) total=\(self.raisedHandsSIDs.count)")
        }
    }

    private nonisolated static func parseHandRaised(_ metadata: String?) -> Bool {
        guard let metadata, let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["hand_raised"] as? Bool) ?? false
    }

    /// STMOB-100: SDK reports speaking participants list (sorted by audio level
    /// descending). Publish to ActiveSpeakerMiniView via @Published activeSpeakers
    /// so PiP мини-окно переключается на того кто реально говорит.
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in
            self.activeSpeakers = participants
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in
            self.updateState()
            // STMOB-101: critical diagnostic — log encryptionType ОТ SERVER на наш
            // publishTrack request. Если encryptionType=.none значит SDK отправил
            // encryption=NONE флаг в SignalRequest (или server stripped его).
            // Frame cryptor НЕ создаётся для .none — track уходит plaintext.
            let pubKind = "\(publication.kind)"
            let pubSid = publication.sid.stringValue
            let encType = "\(publication.encryptionType)"
            DiagLog.write("E2EE_DEBUG", "didPublishTrack kind=\(pubKind) sid=\(pubSid) encryptionType=\(encType)")
            MXLog.info("sTalk LiveKit: Published local track: \(publication.kind) encryption=\(publication.encryptionType)")
            // Блюр: свежий publish камеры = свежий CameraCapturer с processor=nil
            // (в т.ч. republish внутри SDK при full reconnect) — ре-аттач по интенту.
            if publication.source == .camera {
                self.applyBlurIfNeeded()
            }
            // STMOB-262: наблюдение за доставкой вешаем на каждую свежую публикацию —
            // в т.ч. после republish внутри SDK, где трек создаётся заново.
            self.observeEgress(for: publication)
            // STMOB-234: republish демонстрации внутри SDK (full reconnect / room move)
            // приносит НОВЫЙ трек — ватчдог надо перевесить на него, иначе после
            // первого же реконнекта перехват экрана системной записью останется
            // незамеченным. Для юзерского старта это тоже верный путь (idempotent).
            if publication.source == .screenShareVideo {
                self.startScreenShareWatchdog()
            }
        }
    }

    /// STMOB-234/235: парный делегат к didPublishTrack. Screen-share при стопе
    /// SDK именно UNPUBLISH'ит (у камеры/микрофона — mute), и без этого
    /// обработчика состояние не пересчитывалось вообще: localVideoTrack держал
    /// остановленный трек (застывший кадр в своей плитке), isScreenSharing
    /// оставался true. Важно, что это единственный путь для ВНЕШНЕЙ остановки
    /// (системная запись экрана, ошибка ReplayKit), а не только для тапа юзера.
    // MARK: Reconnect visibility (STMOB-262)

    /// Эти три делегата — единственный способ увидеть quick-цикл SDK: он НЕ меняет
    /// `connectionState` (тот переключается только в полном реконнекте), поэтому по
    /// логу устройства «SDK спал» и «SDK молча переподключался» были неразличимы.
    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            self.sdkReconnectMode = reconnectMode
            DiagLog.write("LiveKit", "reconnect START mode=\(reconnectMode)")
        }
    }

    nonisolated func room(_ room: Room, didUpdateReconnectMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            self.sdkReconnectMode = reconnectMode
            DiagLog.write("LiveKit", "reconnect MODE → \(reconnectMode)")
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            self.sdkReconnectMode = nil
            // Делегат приходит и на ПРОВАЛЕ лестницы — «DONE» без проверки состояния
            // был бы ложью в логе, а рассылка ключа в мёртвую комнату бессмысленна.
            guard self.room.connectionState == .connected else {
                DiagLog.write("LiveKit", "reconnect FAILED mode=\(reconnectMode) (room \(self.room.connectionState))")
                return
            }
            DiagLog.write("LiveKit", "reconnect DONE mode=\(reconnectMode)")
            // После переподключения ключи звонка надо разослать заново: на той
            // стороне мог смениться транспорт, а publish внутри SDK прошёл мимо
            // нашего обычного пути рассылки.
            self.encryptionKeyRebroadcastSubject.send(())
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        // Только про себя: в группе делегат приходит на каждого и зафлудит DiagLog.
        guard participant is LocalParticipant else { return }
        Task { @MainActor in
            guard self.localConnectionQuality != quality else { return }
            self.localConnectionQuality = quality
            DiagLog.write("LiveKit", "connection quality → \(quality)")
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in
            if publication.source == .screenShareVideo {
                // Публикации больше нет — ватчдог снимаем с мёртвого трека.
                // Если это republish внутри SDK, парный didPublishTrack сразу
                // поднимет наблюдение на новом треке, а updateState вернёт флаг.
                self.stopScreenShareWatchdog()
                DiagLog.write("Call", "screen share publication снята (стоп юзера, внешний обрыв или republish)")
            }
            self.updateState()
            MXLog.info("sTalk LiveKit: Unpublished local track: \(publication.kind) source=\(publication.source)")
        }
    }
}

// MARK: - Media egress watchdog (STMOB-262)

/// Следит за тем, что исходящее медиа реально УХОДИТ в SFU.
///
/// Зачем отдельный ватчдог: `ScreenShareWatchdog` меряет захват (кадры от
/// ReplayKit), и в инциденте dp (лог 145) он честно насчитал 4271 кадр, пока
/// собеседник не видел ничего — захват жил, доставка была мертва. Единственный
/// доступный признак доставки — исходящая статистика трека (`outbound-rtp`),
/// которую SDK отдаёт раз в секунду при `reportStatistics = true`.
///
/// Вердикт выносится только по ПАРЕ признаков: «байты стоят» + подтверждение
/// (ICE в disconnected/failed, либо пропавший сетевой путь, либо растущий счётчик
/// захвата при стоящем энкодере). Одиночное «байты стоят» врёт: SDK законно гасит
/// кодировки через dynacast, а mute камеры — это не unpublish.
final class MediaEgressWatchdog: NSObject, TrackDelegate, @unchecked Sendable {
    /// Сколько секунд подряд байты не растут, прежде чем это станет уликой.
    /// 6с закрывают лифт и микропровалы.
    private static let stallThreshold = 6
    /// Мёртвый захват: трек включён, а кадров нет столько секунд подряд. Отдельно
    /// от stallThreshold — это другой отказ и другое лечение (перепубликация камеры,
    /// а не ICE restart).
    private static let captureStallThreshold = 8
    /// Телеметрия в DiagLog: раз в 30с (DiagLog при переполнении сносит файл целиком).
    private static let telemetryEvery = 30

    /// Снимок счётчиков одного трека. Держим СВОЙ — у SDK `previous` объявлен weak
    /// и к следующему тику уже пуст, поэтому его хелперы `bps` всегда дают 0.
    private struct Snapshot {
        var bytesSent: UInt64 = 0
        var packetsSent: UInt64 = 0
        var framesEncoded: UInt64 = 0
        var captureFrames: UInt64 = 0
        var flatTicks = 0
        /// Тики подряд, когда трек не на паузе, а источник не отдал ни одного кадра.
        var captureFlatTicks = 0
        var ticks = 0
    }

    private let onStalled: @MainActor (String) -> Void
    /// Источник видео молчит, хотя трек включён — байты тут ни при чём, чинить надо захват.
    private let onCaptureDead: @MainActor (String) -> Void
    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    /// Когда сетевой путь последний раз пропадал — подтверждающий признак.
    private var networkLostAt: Date?
    /// Путь сети отсутствует прямо сейчас.
    private var networkDown = false
    /// Ремонт больше не применяется (лимит исчерпан) — не спамим вердиктом в лог.
    private var repairExhausted = false

    func noteRepairExhausted() {
        lock.lock()
        repairExhausted = true
        lock.unlock()
    }

    init(onStalled: @escaping @MainActor (String) -> Void,
         onCaptureDead: @escaping @MainActor (String) -> Void) {
        self.onStalled = onStalled
        self.onCaptureDead = onCaptureDead
        super.init()
    }

    func noteNetworkLost() {
        lock.lock()
        networkLostAt = Date()
        networkDown = true
        lock.unlock()
    }

    /// Путь сети вернулся. Пока его нет, вердикт бессмысленен: чинить по мёртвой
    /// сети нечего, а лимит попыток сгорит до того, как связь появится.
    func noteNetworkRestored() {
        lock.lock()
        networkDown = false
        networkLostAt = Date()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        snapshots.removeAll()
        networkLostAt = nil
        lock.unlock()
    }

    /// Суммарно отправленные байты по всем наблюдаемым трекам. Ступени ремонта
    /// сравнивают снимок до и после: единственный честный признак «помогло».
    /// По отсутствию исключения судить нельзя — `debug_simulate` не пробрасывает
    /// ошибку даже при полном провале лестницы SDK.
    func totalBytesSent() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.values.reduce(UInt64(0)) { $0 + $1.bytesSent }
    }

    // MARK: TrackDelegate

    func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        let key = track.sid?.stringValue ?? track.name
        let kind = switch track.source {
        case .screenShareVideo: "screen"
        case .camera: "camera"
        default: "audio"
        }

        // Суммируем по всем rid (simulcast включён) и по всем кодекам.
        var streams = statistics.outboundRtpStream
        for extra in simulcastStatistics.values {
            streams.append(contentsOf: extra.outboundRtpStream)
        }
        guard !streams.isEmpty else { return }

        // Законная пауза: dynacast погасил ВСЕ кодировки, потому что на слой никто
        // не подписан. Это не отказ доставки — на таком «простое» чинить нечего.
        let anyActive = streams.contains { $0.active != false }
        let bytes = streams.reduce(UInt64(0)) { $0 + ($1.bytesSent ?? 0) }
        let packets = streams.reduce(UInt64(0)) { $0 + UInt64($1.packetsSent ?? 0) }
        let encoded = streams.reduce(UInt64(0)) { $0 + UInt64($1.framesEncoded ?? 0) }
        let captured = statistics.videoSource.reduce(UInt64(0)) { $0 + UInt64($1.frames ?? 0) }
        let iceState = statistics.transportStats?.iceState
        let iceBroken = iceState == .disconnected || iceState == .failed

        lock.lock()
        var snap = snapshots[key] ?? Snapshot()
        let grew = bytes > snap.bytesSent || packets > snap.packetsSent
        let captureGrew = captured > snap.captureFrames
        let encoderStalled = encoded == snap.framesEncoded
        snap.ticks += 1
        if grew || !anyActive || track.isMuted {
            snap.flatTicks = 0
        } else {
            snap.flatTicks += 1
        }
        let flat = snap.flatTicks
        let ticks = snap.ticks
        // Мёртвый захват: трек НЕ на паузе, а счётчик кадров источника стоит.
        // «Камеру выключили» и «камера включена, но не снимает» — разные состояния,
        // и раньше они были неразличимы: обе ветки просто уходили из проверки
        // («отправлять нечего»). Второй случай собеседник видит как чёрный экран,
        // а мы — как ничего (лог 151: captured=0 packets=0 active=true ice=connected).
        if track is LocalVideoTrack, !track.isMuted, anyActive {
            snap.captureFlatTicks = captureGrew ? 0 : snap.captureFlatTicks + 1
        } else {
            snap.captureFlatTicks = 0
        }
        let captureFlat = snap.captureFlatTicks
        snap.bytesSent = bytes
        snap.packetsSent = packets
        snap.framesEncoded = encoded
        snap.captureFrames = captured
        snapshots[key] = snap
        let networkRecentlyLost = networkLostAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        let pathDown = networkDown
        let exhausted = repairExhausted
        lock.unlock()

        if ticks % Self.telemetryEvery == 0 {
            DiagLog.write("Call", "egress \(kind): bytes=\(bytes) packets=\(packets) encoded=\(encoded) captured=\(captured) active=\(anyActive) ice=\(iceState.map { "\($0)" } ?? "n/a") flat=\(flat)с")
        }

        if captureFlat == Self.captureStallThreshold, !pathDown, !exhausted {
            DiagLog.write("Call", "egress \(kind): ЗАХВАТ МЁРТВ — кадров нет \(captureFlat)с при включённом треке (captured=\(captured) bytes=\(bytes) ice=\(iceState.map { "\($0)" } ?? "n/a"))")
            Task { @MainActor [onCaptureDead] in onCaptureDead(kind) }
        }

        guard flat >= Self.stallThreshold else { return }
        // Пока сети нет — вердикт не выносим: ремонт по мёртвому пути только сожжёт
        // лимит попыток. Вернётся путь — вернётся и вердикт, если он ещё актуален.
        guard !pathDown else {
            if flat == Self.stallThreshold { DiagLog.write("Call", "egress \(kind): байты стоят, но сети нет — жду восстановления пути") }
            return
        }
        // Нет новых кадров от источника — отправлять нечего, и «байты стоят» это не
        // отказ доставки (камера на паузе, статичный экран, приложение в фоне).
        // Для аудио-трека счётчика кадров нет, поэтому проверка только для видео.
        let isVideo = track is LocalVideoTrack
        guard !isVideo || captureGrew else { return }

        // Второй признак обязателен — иначе получим ремонт на ровном месте.
        var corroboration: String?
        if iceBroken { corroboration = "ice=\(iceState.map { "\($0)" } ?? "?")" }
        else if networkRecentlyLost { corroboration = "сеть пропадала <30с назад" }
        else if isVideo, encoderStalled { corroboration = "захват идёт, энкодер стоит" }

        guard let corroboration else {
            if flat == Self.stallThreshold {
                DiagLog.write("Call", "egress \(kind): байты стоят \(flat)с, но подтверждения нет — не чиню")
            }
            return
        }

        lock.lock()
        snapshots[key]?.flatTicks = 0 // не долбить вердиктом каждую секунду
        lock.unlock()

        let reason = "\(kind): байты стоят \(flat)с, \(corroboration)"
        guard !exhausted else { return } // лимит исчерпан — молчим, чтобы не смыть лог
        DiagLog.write("Call", "egress ВСТАЛ — \(reason)")
        Task { @MainActor [onStalled] in onStalled(reason) }
    }
}

// MARK: - LiveKit SDK log bridge (STMOB-262)

/// Мост логов LiveKit SDK в DiagLog.
///
/// Зачем: собственная лестница переподключений SDK снаружи почти невидима —
/// `connectionState = .reconnecting` выставляется ТОЛЬКО в полном реконнекте, а
/// quick-цикл живёт во внутреннем флаге. Из-за этого по логу устройства нельзя
/// отличить «SDK проспал обрыв» от «SDK молча крутил свою лестницу» (лог 145).
/// Всё, что SDK пишет, уходит в OSLog `io.livekit.sdk` и в выгрузку тестера не
/// попадает — поэтому забираем важное к себе.
///
/// Фильтр жёсткий: DiagLog при переполнении сносит файл ЦЕЛИКОМ, а болтливый SDK
/// сотрёт ровно тот лог, ради которого всё затевалось.
struct LiveKitDiagLogBridge: LiveKit.Logger {
    /// Подстроки, ради которых мы вообще читаем info-уровень.
    // STMOB-278: «[adaptivestream]» — единственное место, где видно, КАКОЙ слой мы
    // просим у сервера. SDK печатает там итоговые размеры (`sending TrackSettings…`),
    // посчитанные как максимум по всем приёмникам, участвующим в адаптивной подписке.
    // Без этой строки вопрос «почему картинка 320×180, когда отправитель публикует
    // 1920×1080» решается только гаданием: отправитель отдаёт ровно то, что попросили,
    // а что именно просим мы — до сих пор не наблюдалось ниоткуда.
    private static let allowList = ["[connect]", "ping", "pong", "transport", "reconnect", "republish", "[ice", "icestate", "ice restart", "signal", "[adaptivestream]"]
    /// Бюджет строк: не больше 20 в секунду на всё вместе, включая warning/error —
    /// иначе шторм переподключений сам вытрет лог этого шторма.
    private static let budgetLimit = 20
    private nonisolated(unsafe) static var budgetCount = 0
    private nonisolated(unsafe) static var budgetSecond = Date.distantPast

    private static func allowBudget() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(budgetSecond) >= 1 {
            budgetSecond = now
            budgetCount = 0
        }
        budgetCount += 1
        return budgetCount <= budgetLimit
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastLine = ""
    private nonisolated(unsafe) static var lastAt = Date.distantPast

    /// Тип уровня — именно из LiveKit: у приложения есть свой `LogLevel`, и без
    /// квалификации сигнатура не совпадёт с требованием протокола.
    func log(_ message: @autoclosure () -> CustomStringConvertible,
             _ level: LiveKit.LogLevel,
             source: @autoclosure () -> String?,
             file: StaticString,
             type: Any.Type,
             function: StaticString,
             line: UInt,
             metaData: ScopedMetadataContainer) {
        // Уровни квалифицируем модулем: голое `.error` уезжает в SwiftUI
        // (SensoryFeedback), а голый `LogLevel` — в одноимённый тип из Rust SDK.
        // Уровень проверяем ДО материализации autoclosure: строить строку для .debug —
        // чистая трата, а болтливый SDK смоет DiagLog (при переполнении он сносит файл
        // целиком, вместе с уликами, ради которых мост и делался).
        // STMOB-278: одно исключение из запрета на debug. Согласование качества
        // (`[adaptiveStream] sending …`) SDK печатает именно этим уровнем, а это
        // единственное место, где видно, какой слой мы просим у сервера.
        // Фильтруем по ТИПУ-ИСТОЧНИКУ, а не по тексту: иначе пришлось бы
        // материализовать сообщение у каждой debug-строки болтливого SDK — ровно та
        // трата, от которой гард и защищает. Сам текст отсеет белый список ниже.
        let isQualityNegotiation = "\(type)" == "RemoteTrackPublication"
        guard level != LiveKit.LogLevel.debug || isQualityNegotiation, Self.allowBudget() else { return }
        let isProblem = level == LiveKit.LogLevel.error || level == LiveKit.LogLevel.warning
        let text = "\(message())"
        if !isProblem {
            let lower = text.lowercased()
            guard Self.allowList.contains(where: { lower.contains($0) }) else { return }
        }
        // Дедуп: одинаковая строка не чаще раза в секунду (ping/pong идут пачками).
        Self.lock.lock()
        let now = Date()
        let isRepeat = text == Self.lastLine && now.timeIntervalSince(Self.lastAt) < 1
        if !isRepeat {
            Self.lastLine = text
            Self.lastAt = now
        }
        Self.lock.unlock()
        guard !isRepeat else { return }

        DiagLog.write("LKSDK", "\(level) \(type): \(text.prefix(300))")
    }
}

// MARK: - Метрики нашего энкодера (STMOB-282)

/// Снимает статистику ИСХОДЯЩЕГО видео: что реально выдаёт кодировщик телефона.
///
/// Появился по запросу с серверной стороны: у собеседника на вебе картинка с
/// айфона рассыпается, при этом канал отдаёт нормальные килобиты и потерь почти
/// нет, а кадров мало — 8 в секунду при номинале 30. Это не сеть и не выбор слоя,
/// это источник не выдаёт кадры. Причину показывает поле `qualityLimitationReason`:
/// `cpu` означает, что кодировщик упирается в процессор — у Apple нет аппаратного
/// VP8, а при шифровании звонка мы форсируем именно его.
///
/// Пишем ТОЛЬКО при изменении картины, а не каждый тик: статистика приходит
/// секундными пачками на каждый слой, и посекундная запись смыла бы лог.
final class OutboundVideoStatsLogger: NSObject, TrackDelegate, @unchecked Sendable {
    private var lastSignature = ""
    private let lock = NSLock()

    nonisolated func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        let streams = statistics.outboundRtpStream.filter { $0.kind == "video" }
        guard !streams.isEmpty else { return }

        let parts = streams
            .sorted { ($0.rid ?? "") < ($1.rid ?? "") }
            .map { stream -> String in
                let rid = stream.rid ?? "—"
                let size = "\(stream.frameWidth.map(String.init) ?? "?")x\(stream.frameHeight.map(String.init) ?? "?")"
                let fps = stream.framesPerSecond.map { String(format: "%.0f", $0) } ?? "?"
                let limit = stream.qualityLimitationReason?.rawValue ?? "—"
                return "\(rid) \(size) fps=\(fps) предел=\(limit)"
            }

        let encoder = streams.compactMap(\.encoderImplementation).first ?? "?"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "норма"
        case .fair: thermal = "тёплый"
        case .serious: thermal = "горячий"
        case .critical: thermal = "перегрев"
        @unknown default: thermal = "?"
        }

        let signature = parts.joined(separator: " | ") + " enc=\(encoder) тепло=\(thermal)"
        lock.lock()
        let changed = signature != lastSignature
        if changed { lastSignature = signature }
        lock.unlock()
        guard changed else { return }

        DiagLog.write("Call", "энкодер: \(signature)")
    }
}

// MARK: - Screen share watchdog (STMOB-234)

/// Следит за живостью in-app ReplayKit-захвата экрана.
///
/// Демонстрация публикуется через `RPScreenRecorder.shared().startCapture` —
/// broadcast extension в сборке нет (`BroadcastBundleInfo.hasExtension == false`,
/// app group расширения не совпадает с нашим), поэтому SDK уходит в ветку
/// `createInAppScreenShareTrack`. Системная запись экрана iPhone забирает тот же
/// синглтон `RPScreenRecorder`: кадры перестают приходить, но публикация остаётся
/// живой и не muted — у всех участников висит последний кадр, и юзер об этом не
/// знает. SDK не страхует: errorHandler у `startCapture` игнорируется
/// (`InAppCapturer.swift`), а авто-unpublish при остановке капчера сделан только
/// для `BroadcastScreenCapturer`.
///
/// Признак перехвата = потеря доступности рекордера (делегат) И одновременная
/// остановка кадров. Порознь они врут: ReplayKit отдаёт кадры ПО ИЗМЕНЕНИЮ экрана
/// (на статичной картинке пауза нормальна), а `isAvailable` меняется и от нашего
/// собственного захвата. Пара признаков даёт надёжный сигнал.
/// Кадры прилетают с очереди капчера, делегат ReplayKit — со своей: состояние
/// живёт под локом, наружу (стоп демонстрации) выходим через @MainActor-колбэк.
final class ScreenShareWatchdog: NSObject, VideoRenderer, @unchecked Sendable {
    /// Кадров нет столько секунд — считаем поток вставшим (в паре с делегатом).
    /// С запасом: ReplayKit шлёт кадры по изменению экрана, статичный документ
    /// в демонстрации легально молчит несколько секунд.
    private static let stallThreshold: TimeInterval = 5
    /// Жёсткий сигнал (`didStopRecording` — «Запись прервана другой программой»)
    /// однозначен, ждать полный порог незачем: гасим почти сразу.
    private static let hardSignalThreshold: TimeInterval = 1.5
    private static let hardSignalPrefix = "рекордер остановлен"
    /// Кадры, пришедшие сразу после сигнала делегата, — «хвост в полёте» из
    /// очереди капчера, а не признак живого захвата. Взвод снимаем только
    /// потоком, который держится дольше этого окна.
    private static let inFlightFrameWindow: TimeInterval = 1.5
    /// Как часто пишем телеметрию в DiagLog. Редко: DiagLog при переполнении
    /// сносит файл целиком, а звонок с демонстрацией идёт десятки минут.
    private static let telemetryInterval: TimeInterval = 30

    private let onCaptureLost: @MainActor (String) -> Void
    private let lock = NSLock()
    private var lastFrameAt = Date()
    private var frameCount = 0
    private var pollTask: Task<Void, Never>?
    /// Делегат ReplayKit сказал, что захват отобрали/остановили: причина + когда.
    private var recorderSignalledLoss: String?
    private var lossAt: Date?

    init(onCaptureLost: @escaping @MainActor (String) -> Void) {
        self.onCaptureLost = onCaptureLost
        super.init()
    }

    @MainActor
    func start() {
        lock.lock()
        lastFrameAt = Date()
        frameCount = 0
        recorderSignalledLoss = nil
        lossAt = nil
        lock.unlock()

        let recorder = RPScreenRecorder.shared()
        recorder.delegate = self
        DiagLog.write("Call", "screen share watchdog: старт (isRecording=\(recorder.isRecording) isAvailable=\(recorder.isAvailable))")

        pollTask = Task { @MainActor [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                elapsed += 1
                self.tick(logTelemetry: elapsed.truncatingRemainder(dividingBy: Self.telemetryInterval) == 0)
            }
        }
    }

    @MainActor
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if RPScreenRecorder.shared().delegate === self {
            RPScreenRecorder.shared().delegate = nil
        }
        let (age, frames) = stats()
        DiagLog.write("Call", "screen share watchdog: стоп (кадров=\(frames), последний \(String(format: "%.1f", age))с назад)")
    }

    private func stats() -> (age: TimeInterval, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (Date().timeIntervalSince(lastFrameAt), frameCount)
    }

    @MainActor
    private func tick(logTelemetry: Bool) {
        let (age, frames) = stats()
        lock.lock()
        let loss = recorderSignalledLoss
        let signalledAt = lossAt
        lock.unlock()

        if logTelemetry {
            let recorder = RPScreenRecorder.shared()
            DiagLog.write("Call", "screen share: кадров=\(frames), последний \(String(format: "%.1f", age))с назад, isRecording=\(recorder.isRecording), isAvailable=\(recorder.isAvailable), взвод=\(loss ?? "нет")")
        }

        // Стоп только по ПАРЕ признаков: рекордер сообщил о потере И кадры встали
        // ПОСЛЕ этого сигнала. Порознь оба врут: ReplayKit отдаёт кадры по изменению
        // экрана (пауза на статичной картинке легальна), а availability дёргается и от
        // нашего же захвата. Требование «простой начался не раньше сигнала» не даёт
        // приписать перехвату чужую паузу.
        //
        // Порог зависит от жёсткости сигнала (dp, лог 145 12:05:37→12:05:43): при
        // системной записи ReplayKit прислал didStopRecording «Запись прервана другой
        // программой» — это однозначно, ждать 5с незачем; а availability=false шумит
        // (дёргается от нашего же startCapture) и требует полного порога.
        guard let loss, let signalledAt else { return }
        let threshold = loss.hasPrefix(Self.hardSignalPrefix) ? Self.hardSignalThreshold : Self.stallThreshold
        guard age > threshold, Date().timeIntervalSince(signalledAt) > threshold else { return }
        lock.lock()
        recorderSignalledLoss = nil // не дёргать повторно
        lossAt = nil
        lock.unlock()
        pollTask?.cancel()
        pollTask = nil
        onCaptureLost("\(loss), кадров нет \(String(format: "%.1f", age))с")
    }

    private func signalLoss(_ reason: String) {
        lock.lock()
        recorderSignalledLoss = reason
        lossAt = Date()
        lock.unlock()
    }

    private func clearLoss(_ why: String) {
        lock.lock()
        let had = recorderSignalledLoss != nil
        recorderSignalledLoss = nil
        lossAt = nil
        lock.unlock()
        if had {
            DiagLog.write("Call", "screen share: взвод снят (\(why))")
        }
    }

    /// Возврат из фона: время, проведённое свёрнутым, — не простой кадров
    /// (in-app ReplayKit-захват в фоне не отдаёт их в принципе).
    func noteResumedFromBackground() {
        lock.lock()
        lastFrameAt = Date()
        lock.unlock()
    }

    // MARK: VideoRenderer

    @MainActor var isAdaptiveStreamEnabled: Bool {
        false
    }

    @MainActor var adaptiveStreamSize: CGSize {
        .zero
    }

    func set(size: CGSize) { }

    func render(frame: VideoFrame) {
        lock.lock()
        let now = Date()
        lastFrameAt = now
        frameCount += 1
        // Кадры идут дольше окна «хвоста в полёте» — значит захват жив, и сигнал
        // делегата был ложной тревогой (availability дёргается и от нашего же
        // startCapture, и от появления AirPlay-приёмника). Снимаем взвод. Кадры
        // сразу после сигнала не считаем: это остатки очереди капчера.
        let staleLoss = lossAt.map { now.timeIntervalSince($0) > Self.inFlightFrameWindow } ?? false
        lock.unlock()
        if staleLoss {
            clearLoss("кадры идут")
        }
    }
}

// MARK: RPScreenRecorderDelegate

extension ScreenShareWatchdog: RPScreenRecorderDelegate {
    func screenRecorderDidChangeAvailability(_ screenRecorder: RPScreenRecorder) {
        let available = screenRecorder.isAvailable
        DiagLog.write("Call", "screen share: RPScreenRecorder availability → \(available)")
        guard !available else {
            clearLoss("рекордер снова доступен")
            return
        }
        signalLoss("рекордер недоступен")
    }

    func screenRecorder(_ screenRecorder: RPScreenRecorder,
                        didStopRecordingWith previewViewController: RPPreviewViewController?,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "без ошибки"
        DiagLog.write("Call", "screen share: RPScreenRecorder didStopRecording (\(reason))")
        signalLoss("рекордер остановлен: \(reason)")
    }
}

// MARK: - Device Orientation → Video Rotation

/// Трекер ориентации устройства для штамповки rotation кадров камеры.
/// WebRTC-капчер (m144) фактически НЕ перештамповывает rotation при повороте
/// телефона (проверено на устройстве, build 235) — свой PiP, удалённые вьюхи
/// и веб получали картинку «боком». Обновляется на main по уведомлениям,
/// читается с видео-очередей под локом.
final class DeviceOrientationTracker {
    static let shared = DeviceOrientationTracker()

    private let lock = NSLock()
    private var current: UIDeviceOrientation = .portrait
    private var frontCamera = true

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(update),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        update()
    }

    @objc private func update() {
        let orientation = UIDevice.current.orientation
        // faceUp/faceDown/unknown — держим последнюю валидную (как WebRTC)
        guard orientation == .portrait || orientation == .portraitUpsideDown
            || orientation == .landscapeLeft || orientation == .landscapeRight else { return }
        lock.lock()
        current = orientation
        lock.unlock()
    }

    /// Позиция активной камеры — важна для landscape-мэппинга
    func setFrontCamera(_ front: Bool) {
        lock.lock()
        frontCamera = front
        lock.unlock()
    }

    /// Классический мэппинг RTCCameraVideoCapturer (device orientation → rotation)
    var videoRotation: VideoRotation {
        lock.lock()
        let (orientation, front) = (current, frontCamera)
        lock.unlock()
        switch orientation {
        case .portrait: return ._90
        case .portraitUpsideDown: return ._270
        case .landscapeLeft: return front ? ._180 : ._0
        case .landscapeRight: return front ? ._0 : ._180
        default: return ._90
        }
    }
}

/// Процессор-«штамп»: правит ТОЛЬКО rotation-метаданные кадра по фактической
/// ориентации устройства, пиксели не трогает. Attach'ится когда фон (блюр/обои)
/// выключен — чтобы landscape работал и без фона.
/// Одноразовый зонд: приходят ли к нам кадры чужого видео вообще. Отвечает на
/// вопрос, который иначе не отличить — «сеть/расшифровка не дают кадров» против
/// «кадры есть, а UI их не рисует». Отцепляется сам после первого кадра.
final class FirstFrameProbe: NSObject, VideoRenderer, @unchecked Sendable {
    private let label: String
    private let onFirstFrame: @Sendable (String, VideoFrame) -> Void
    /// STMOB-274: смена разрешения по ходу звонка. Первый кадр всегда приходит
    /// самым лёгким слоем — адаптивная подписка начинает снизу и поднимается по
    /// мере того, как приёмники сообщают свой размер. Логируя ТОЛЬКО первый кадр,
    /// мы видели «320x180» и не могли отличить нормальный старт от застревания
    /// на нижнем слое. Теперь видно и то, и другое.
    private let onResolutionChange: (@Sendable (String, Int32, Int32, Int32, Int32) -> Void)?
    private var fired = false
    private var lastWidth: Int32 = 0
    private var lastHeight: Int32 = 0
    private let lock = NSLock()

    init(label: String,
         onFirstFrame: @escaping @Sendable (String, VideoFrame) -> Void,
         onResolutionChange: (@Sendable (String, Int32, Int32, Int32, Int32) -> Void)? = nil) {
        self.label = label
        self.onFirstFrame = onFirstFrame
        self.onResolutionChange = onResolutionChange
        super.init()
    }

    /// ОБЯЗАТЕЛЬНО true. SDK считает трек видимым, только если хотя бы один приёмник
    /// участвует в адаптивной подписке; иначе трек остаётся ВЫКЛЮЧЕННЫМ
    /// (`shouldReceive = false`) и кадры не идут вовсе. Так пропадало видео тех, кто
    /// был в комнате ДО нас: плитка ещё не смонтирована, «видимых» приёмников нет.
    @MainActor var isAdaptiveStreamEnabled: Bool {
        true
    }

    /// НЕ ноль. SDK берёт максимум размеров среди приёмников и по нему просит слой у
    /// сервера, а ноль означает «дай самый лёгкий». Зонд с нулём тянул качество вниз
    /// даже при полноразмерной плитке на экране: собеседник приходил кадрами 8×8,
    /// то есть чёрным прямоугольником (лог 163). Здесь скромный, но осмысленный
    /// размер — когда плитка появится, максимум возьмёт её, а пока её нет, картинка
    /// остаётся пригодной для окна «картинка в картинке».
    @MainActor var adaptiveStreamSize: CGSize {
        CGSize(width: 640, height: 360)
    }

    func set(size: CGSize) { }

    func render(frame: VideoFrame) {
        let width = frame.dimensions.width
        let height = frame.dimensions.height

        lock.lock()
        let first = !fired
        fired = true
        let previousWidth = lastWidth
        let previousHeight = lastHeight
        let changed = !first && (previousWidth != width || previousHeight != height)
        lastWidth = width
        lastHeight = height
        lock.unlock()

        if first {
            onFirstFrame(label, frame)
        } else if changed {
            onResolutionChange?(label, previousWidth, previousHeight, width, height)
        }
    }
}

final class StalkOrientationProcessor: NSObject, LiveKit.VideoProcessor {
    /// Между «капчер стартовал» и «кадр ушёл в трек» логов не было вовсе, и разбор
    /// «видео не установилось» упирался в темноту: у трека нет размеров, а почему —
    /// неизвестно. Первый кадр здесь — доказательство, что источник жив.
    private var frameCount = 0

    func process(frame: VideoFrame) -> VideoFrame? {
        frameCount += 1
        if frameCount == 1 {
            DiagLog.write("Call", "камера: ПЕРВЫЙ кадр \(frame.dimensions.width)x\(frame.dimensions.height) rotation=\(frame.rotation)")
        } else if frameCount % 900 == 0 {
            DiagLog.write("Call", "камера: кадров \(frameCount)")
        }
        let rotation = DeviceOrientationTracker.shared.videoRotation
        guard rotation != frame.rotation else { return frame }
        return VideoFrame(dimensions: frame.dimensions,
                          rotation: rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: frame.buffer)
    }
}

// MARK: - Stalk Background Blur Processor

/// Свой блюр-процессор вместо SDK'шного `BackgroundBlurVideoProcessor` — у того три
/// фатальных для нас дефекта (найдены разбором «блюр не видно» на build 225):
///  1. радиус захардкожен на 3 (~4px на 720p) — в мини-превью неотличим от обычного видео;
///  2. Vision получает кадр без ориентации — в портрете человек «на боку», маска слабая/пустая;
///  3. все ошибки глотаются молча (нет маски → кадр уходит как есть, навсегда, без логов).
/// Здесь: радиус 12, ориентация из frame.rotation, DiagLog-статистика стадий.
///
/// Не потокобезопасен — SDK зовёт process(frame:) на serial processingQueue capturer'а;
/// на каждый новый capturer менеджер создаёт свежий инстанс.
final class StalkBackgroundBlurProcessor: NSObject, LiveKit.VideoProcessor {
    /// Чем заменяем фон: размытие заданного радиуса или статичные обои.
    enum Background {
        case blur(radius: Float)
        case image(CIImage)

        var descriptionForLog: String {
            switch self {
            case .blur(let radius): "blur(radius=\(radius))"
            case .image: "wallpaper"
            }
        }
    }

    private let background: Background
    private let downscaleFactor: CGFloat = 2 // даунскейл перед блюром (перф), апскейл перед блендом
    private let relativeSize: CGFloat = 1080 // параметры калиброваны под HD, экстраполируются

    private var frameCount = 0
    /// Каждый 2-й кадр: у Apple маска трекается на каждом кадре — наше «вырезание
    /// отстаёт от изображения» (dp) было интервалом 3-4. Латентность ~83мс.
    private let segmentationFrameInterval = 2

    private let segmentationRequest = VNGeneratePersonSegmentationRequest()
    private let segmentationRequestHandler = VNSequenceRequestHandler()
    private let segmentationQueue = DispatchQueue(label: "ru.implica.stalk.blur.segmentation", qos: .default, autoreleaseFrequency: .workItem)

    private let ciContext: CIContext
    private let blurFilter = CIFilter.gaussianBlur()
    private let blendFilter = CIFilter.blendWithMask()
    /// Отдельный инстанс для растушёвки маски: живёт на segmentationQueue,
    /// blurFilter — на processingQueue, CIFilter не потокобезопасен.
    private let maskFeatherFilter = CIFilter.gaussianBlur()

    private var cachedMaskImage: CIImage?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedPixelBufferSize: CGSize?

    // Диагностика (видна в nse-events). Счётчики пишутся с двух очередей — под локом.
    private let statsLock = NSLock()
    private var statProcessed = 0
    private var statNoMask = 0
    private var statSegErrors = 0
    private var statMasks = 0
    private var loggedFirstMask = false

    init(background: Background) {
        self.background = background
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device)
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: true])
        }
        super.init()
        // .balanced (512×384): в 4 раза дешевле .accurate за прогон → можно считать
        // каждый 2-й кадр (свежая маска важнее пиксельной точности — отставание
        // выреза от движения заметнее ореола, dp 12.07). Край сглаживает
        // maskFeatherFilter; суммарная Vision-нагрузка НИЖЕ, чем accurate/3.
        segmentationRequest.qualityLevel = .balanced
        DiagLog.write("Call", "background processor created (\(background.descriptionForLog), orientation-aware, accurate)")
    }

    // MARK: VideoProcessor

    func process(frame: VideoFrame) -> VideoFrame? {
        // Ориентация из трекера: rotation от капчера может врать (см. DeviceOrientationTracker).
        // ВСЕ выходы из process — со штампованным rotation, включая ранние.
        let effectiveRotation = DeviceOrientationTracker.shared.videoRotation
        func passthrough() -> VideoFrame {
            guard effectiveRotation != frame.rotation else { return frame }
            return VideoFrame(dimensions: frame.dimensions,
                              rotation: effectiveRotation,
                              timeStampNs: frame.timeStampNs,
                              buffer: frame.buffer)
        }
        frameCount += 1
        let processed: Int = statsLock.withLock {
            statProcessed += 1
            return statProcessed
        }
        if processed % 90 == 0 {
            let (noMask, errs, masks) = statsLock.withLock { (statNoMask, statSegErrors, statMasks) }
            DiagLog.write("Call", "blur stats: frames=\(processed) masks=\(masks) noMaskFrames=\(noMask) segErrors=\(errs)")
        }

        guard let inputBuffer = frame.toCVPixelBuffer() else {
            statsLock.withLock { statNoMask += 1 }
            return passthrough()
        }
        let cropRect = CGRect(x: 0, y: 0, width: Int(frame.dimensions.width), height: Int(frame.dimensions.height))
        var inputImage = CIImage(cvPixelBuffer: inputBuffer)
        if inputImage.extent != cropRect {
            // Буфер камеры может быть крупнее frame.dimensions — центр-кроп до целевого
            // аспекта + SCALE (голый cropped(to:) вырезал бы кусок = зум в эфире)
            inputImage = inputImage.croppedAndScaled(to: cropRect)
        }
        let inputDimensions = inputImage.extent.size

        cacheMask(inputBuffer: inputBuffer, inputDimensions: inputDimensions, rotation: effectiveRotation)
        guard let maskImage = cachedMaskImage else {
            statsLock.withLock { statNoMask += 1 }
            return passthrough()
        }

        // Фон: размытый кадр или обои (в буферном пространстве)
        let backgroundImage: CIImage
        switch background {
        case .blur(let radius):
            let downscaleTransform = getDownscaleTransform(relativeTo: inputDimensions)
            let downscaledImage = inputImage.transformed(by: downscaleTransform, highQualityDownsample: false)
            blurFilter.inputImage = downscaledImage.clampedToExtent()
            blurFilter.radius = radius
            guard let blurredImage = blurFilter.outputImage else { return passthrough() }
            backgroundImage = blurredImage.transformed(by: downscaleTransform.inverted(), highQualityDownsample: false)
        case .image:
            guard let wallpaper = wallpaperImage(for: inputDimensions, rotation: effectiveRotation) else { return passthrough() }
            backgroundImage = wallpaper
        }

        // Blend: маска = человек (белое) остаётся резким, фон подменяется
        blendFilter.inputImage = inputImage
        blendFilter.backgroundImage = backgroundImage
        blendFilter.maskImage = maskImage
        guard let outputImage = blendFilter.outputImage else { return passthrough() }

        guard let outputBuffer = getOutputBuffer(of: inputDimensions) else { return passthrough() }
        ciContext.render(outputImage, to: outputBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: effectiveRotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }

    // MARK: Segmentation

    private func cacheMask(inputBuffer: CVPixelBuffer, inputDimensions: CGSize, rotation: VideoRotation) {
        guard frameCount % segmentationFrameInterval == 0 else { return }

        struct PixelBufferHolder: @unchecked Sendable {
            let buffer: CVPixelBuffer
        }
        let holder = PixelBufferHolder(buffer: inputBuffer)
        let orientation = Self.cgOrientation(for: rotation)

        segmentationQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Ориентация ОБЯЗАТЕЛЬНА: без неё в портрете Vision видит человека «на боку»
                try segmentationRequestHandler.perform([segmentationRequest], on: holder.buffer, orientation: orientation)
            } catch {
                let errs: Int = statsLock.withLock {
                    self.statSegErrors += 1
                    return self.statSegErrors
                }
                if errs <= 3 || errs % 30 == 0 {
                    DiagLog.write("Call", "blur: segmentation error #\(errs): \(error.localizedDescription)")
                }
                return
            }
            guard let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer else { return }

            var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
            // Vision с orientation возвращает маску в ПОВЁРНУТОМ (oriented) пространстве —
            // ВСЕГДА доворачиваем обратно в буферное. Прежняя эвристика по смене пропорций
            // ловила только 90°/270°; 180° в landscape проходил мимо → «вырезание
            // вверх ногами» (dp, 12.07).
            if orientation != .up {
                maskImage = maskImage.oriented(Self.inverse(of: orientation))
            }
            let scaleX = inputDimensions.width / maskImage.extent.width
            let scaleY = inputDimensions.height / maskImage.extent.height

            let shouldLogFirst: Bool = statsLock.withLock {
                self.statMasks += 1
                if !self.loggedFirstMask {
                    self.loggedFirstMask = true
                    return true
                }
                return false
            }
            if shouldLogFirst {
                DiagLog.write("Call", "blur: FIRST person mask (mask=\(Int(maskImage.extent.width))x\(Int(maskImage.extent.height)) input=\(Int(inputDimensions.width))x\(Int(inputDimensions.height)) rot=\(rotation) orient=\(orientation.rawValue))")
            }
            // Растушёвка края маски: убирает жёсткий «вырезанный» контур после апскейла
            let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            maskFeatherFilter.inputImage = scaledMask.clampedToExtent()
            maskFeatherFilter.radius = 3
            let feathered = maskFeatherFilter.outputImage?
                .cropped(to: CGRect(origin: .zero, size: inputDimensions))
            cachedMaskImage = feathered ?? scaledMask
        }
    }

    // MARK: Wallpaper

    private var cachedWallpaper: CIImage?
    private var cachedWallpaperKey: String?

    /// Обои в буферном пространстве кадра: дисплей поворачивает буфер на frame.rotation,
    /// поэтому «выпрямленные для юзера» обои кладём в буфер повернутыми в обратную
    /// сторону + aspect-fill по размеру кадра. Кешируется на (размер, поворот).
    private func wallpaperImage(for size: CGSize, rotation: VideoRotation) -> CIImage? {
        let key = "\(Int(size.width))x\(Int(size.height))@\(rotation)"
        if cachedWallpaperKey == key, let cachedWallpaper {
            return cachedWallpaper
        }
        guard case .image(let original) = background else { return nil }

        var image = original
        let orientation = Self.cgOrientation(for: rotation)
        if orientation != .up {
            image = image.oriented(Self.inverse(of: orientation))
        }
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Центрируем и кропим до размера кадра
        let dx = image.extent.origin.x + (image.extent.width - size.width) / 2
        let dy = image.extent.origin.y + (image.extent.height - size.height) / 2
        image = image.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))

        cachedWallpaper = image
        cachedWallpaperKey = key
        DiagLog.write("Call", "blur: wallpaper prepared for \(key)")
        return image
    }

    // MARK: Helpers

    private func getDownscaleTransform(relativeTo size: CGSize) -> CGAffineTransform {
        let sizeFactor = min(size.width, size.height) / relativeSize
        // Не апскейлим входы меньше эталона
        let scale = 1 / (downscaleFactor * sizeFactor)
        return scale < 1 ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    }

    private func getOutputBuffer(of size: CGSize) -> CVPixelBuffer? {
        if cachedPixelBufferSize != size {
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
            cachedPixelBuffer = pixelBuffer
            cachedPixelBufferSize = size
        }
        return cachedPixelBuffer
    }

    private static func cgOrientation(for rotation: VideoRotation) -> CGImagePropertyOrientation {
        switch rotation {
        case ._0: .up
        case ._90: .right
        case ._180: .down
        case ._270: .left
        }
    }

    private static func inverse(of orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .right: .left
        case .left: .right
        default: orientation
        }
    }
}
