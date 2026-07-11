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
import SwiftUI
import Vision
#if canImport(UIKit)
import UIKit
#endif

private let livekitLog = OSLog(subsystem: "ru.implica.stalk", category: "LiveKit")

/// Режим фона в звонке: выкл / три интенсивности размытия / обои.
/// rawValue хранится в UserDefaults (`stalk_call_background_mode`),
/// выбранные обои — индекс 1...6 в `stalk_call_wallpaper_index`.
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
        remoteParticipants.filter { $0.kind == .standard }
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
        room = Room()
        room.add(delegate: self)
        registerLifecycleObservers()
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
        guard connectionState == .connected || connectionState == .reconnecting else { return }
        // Remember if camera was actively publishing — need to re-enable on return.
        // Именно КАМЕРА и именно НЕ muted: setCamera(false) на устройстве только мьютит
        // publication (track остаётся != nil), а videoTracks.first может быть screen-share.
        // Старый чек «track != nil» после сворачивания сам ВКЛЮЧАЛ камеру, которую юзер
        // выключил (privacy).
        wasCameraEnabledBeforeBackground = room.localParticipant.firstCameraPublication
            .map { $0.track != nil && !$0.isMuted } ?? false
        // Блюр: CIContext на Metal не должен рендерить в фоне (GPU work in background
        // = command-buffer abort в момент транзишена). Отцепляем процессор; foreground
        // setCamera(true) ре-аттачит по интенту (blurIntent не трогаем).
        if blurProcessor != nil,
           let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack {
            track.capturer.processor = nil
            blurProcessor = nil
            MXLog.info("sTalk LiveKit: Background blur detached for backgrounding")
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
        if wasCameraEnabledBeforeBackground {
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
    private static let cameraCaptureOptions = CameraCaptureOptions(dimensions: .h720_169)

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
        if enabled, callBackgroundMode != .off, room.localParticipant.firstCameraPublication == nil,
           let processor = makeBackgroundProcessor() {
            blurProcessor = processor
            let track = LocalVideoTrack.createCameraTrack(options: Self.cameraCaptureOptions, processor: processor)
            _ = try await room.localParticipant.publish(videoTrack: track)
            MXLog.info("sTalk LiveKit: Camera published with pre-attached background processor")
            DiagLog.write("Call", "blur: camera published with PRE-ATTACHED processor")
        } else {
            try await room.localParticipant.setCamera(enabled: enabled)
            if enabled {
                applyBlurIfNeeded()
            }
        }
        #endif
        updateState()
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
        isScreenSharing = enabled
        MXLog.info("sTalk LiveKit: Screen share \(enabled ? "started" : "stopped")")
        #endif
    }

    /// Strong-ссылка на процессор: SDK держит `capturer.processor` weak,
    /// без неё фон молча отвалится после первого прохода autorelease.
    /// Режим-интент живёт в callBackgroundMode — он переживает пересоздание
    /// камера-трека (toggle камеры, foreground re-enable, reconnect), attach
    /// самовосстанавливается в applyBlurIfNeeded().
    private var blurProcessor: StalkBackgroundBlurProcessor?

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
            let index = (1...6).contains(stored) ? stored : 1
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
            if let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack,
               track.capturer.processor != nil {
                track.capturer.processor = nil
                MXLog.info("sTalk LiveKit: call background detached")
                DiagLog.write("Call", "blur: detached")
            }
            blurProcessor = nil
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
        AudioManager.shared.isSpeakerOutputPreferred = enabled
        MXLog.info("sTalk LiveKit: Speaker \(enabled ? "ON (speaker)" : "OFF (earpiece)") via isSpeakerOutputPreferred")
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

    /// Configure AVAudioSession for VoIP call before LiveKit connects.
    /// This ensures the native SDK has exclusive control over the audio hardware.
    /// - Parameter speakerByDefault: If true, route audio to speaker initially (for group calls).
    ///   If false, route to earpiece (for 1:1 calls, like Telegram).
    func configureAudioSession(speakerByDefault: Bool = false) {
        // The initial route is governed by LiveKit's isSpeakerOutputPreferred: once its audio engine
        // starts it reconfigures the session from this flag (.videoChat = speaker for group calls,
        // .voiceChat = earpiece for 1:1), overriding any category/port we set here. So set the flag —
        // that's what actually makes 1:1 default to the earpiece instead of the loudspeaker.
        #if !targetEnvironment(simulator)
        AudioManager.shared.isSpeakerOutputPreferred = speakerByDefault
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
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            MXLog.info("sTalk LiveKit: Audio session configured — speaker=\(speakerByDefault)")
        } catch {
            MXLog.error("sTalk LiveKit: Failed to configure audio session: \(error)")
        }
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
        localVideoTrack = room.localParticipant.videoTracks
            .compactMap { pub -> VideoTrack? in
                guard !pub.isMuted else { return nil }
                return pub.track as? VideoTrack
            }
            .first
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
            DiagLog.write("Call", "track subscribed kind=\(pubKind) name=\(pubName) source=\(pubSource) isScreenShare=\(isScreenShare) from=\(identity)")
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
        Task { @MainActor in
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
        }
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
    private let segmentationFrameInterval = 3 // сегментация каждый 3-й кадр (перф)

    private let segmentationRequest = VNGeneratePersonSegmentationRequest()
    private let segmentationRequestHandler = VNSequenceRequestHandler()
    private let segmentationQueue = DispatchQueue(label: "ru.implica.stalk.blur.segmentation", qos: .default, autoreleaseFrequency: .workItem)

    private let ciContext: CIContext
    private let blurFilter = CIFilter.gaussianBlur()
    private let blendFilter = CIFilter.blendWithMask()

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
        segmentationRequest.qualityLevel = .balanced
        DiagLog.write("Call", "background processor created (\(background.descriptionForLog), orientation-aware)")
    }

    // MARK: VideoProcessor

    func process(frame: VideoFrame) -> VideoFrame? {
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
            return frame
        }
        let cropRect = CGRect(x: 0, y: 0, width: Int(frame.dimensions.width), height: Int(frame.dimensions.height))
        var inputImage = CIImage(cvPixelBuffer: inputBuffer)
        if inputImage.extent != cropRect {
            inputImage = inputImage.cropped(to: cropRect)
        }
        let inputDimensions = inputImage.extent.size

        cacheMask(inputBuffer: inputBuffer, inputDimensions: inputDimensions, rotation: frame.rotation)
        guard let maskImage = cachedMaskImage else {
            statsLock.withLock { statNoMask += 1 }
            return frame
        }

        // Фон: размытый кадр или обои (в буферном пространстве)
        let backgroundImage: CIImage
        switch background {
        case .blur(let radius):
            let downscaleTransform = getDownscaleTransform(relativeTo: inputDimensions)
            let downscaledImage = inputImage.transformed(by: downscaleTransform, highQualityDownsample: false)
            blurFilter.inputImage = downscaledImage.clampedToExtent()
            blurFilter.radius = radius
            guard let blurredImage = blurFilter.outputImage else { return frame }
            backgroundImage = blurredImage.transformed(by: downscaleTransform.inverted(), highQualityDownsample: false)
        case .image:
            guard let wallpaper = wallpaperImage(for: inputDimensions, rotation: frame.rotation) else { return frame }
            backgroundImage = wallpaper
        }

        // Blend: маска = человек (белое) остаётся резким, фон подменяется
        blendFilter.inputImage = inputImage
        blendFilter.backgroundImage = backgroundImage
        blendFilter.maskImage = maskImage
        guard let outputImage = blendFilter.outputImage else { return frame }

        guard let outputBuffer = getOutputBuffer(of: inputDimensions) else { return frame }
        ciContext.render(outputImage, to: outputBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
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
            // Vision с orientation может вернуть маску в повёрнутом пространстве —
            // если аспект транспонирован относительно входа, доворачиваем обратно.
            let transposed = (maskImage.extent.width > maskImage.extent.height) != (inputDimensions.width > inputDimensions.height)
            if transposed {
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
                DiagLog.write("Call", "blur: FIRST person mask (mask=\(Int(maskImage.extent.width))x\(Int(maskImage.extent.height)) input=\(Int(inputDimensions.width))x\(Int(inputDimensions.height)) rot=\(rotation) transposed=\(transposed))")
            }
            cachedMaskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
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
