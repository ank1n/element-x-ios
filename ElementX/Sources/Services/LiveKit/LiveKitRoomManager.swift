//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import LiveKit
import os.log
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private let livekitLog = OSLog(subsystem: "ru.implica.stalk", category: "LiveKit")

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
        wasCameraEnabledBeforeBackground = room.localParticipant.videoTracks.first?.track != nil

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
        let roomOptions = RoomOptions(defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h720_169),
                                      defaultAudioCaptureOptions: AudioCaptureOptions(),
                                      defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 24),
                                                                                      simulcast: true),
                                      defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 48000),
                                                                                      dtx: true),
                                      adaptiveStream: true,
                                      dynacast: true)

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
        let roomOptions = RoomOptions(defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h720_169),
                                      defaultAudioCaptureOptions: AudioCaptureOptions(),
                                      defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 24),
                                                                                      simulcast: true),
                                      defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 48000),
                                                                                      dtx: true),
                                      adaptiveStream: true,
                                      dynacast: true,
                                      encryptionOptions: encryptionOptions)

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
        try await room.localParticipant.setCamera(enabled: enabled)
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

    /// Toggle background blur
    @Published private(set) var isBackgroundBlurEnabled = false

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

    private var blurProcessor: BackgroundBlurVideoProcessor?

    /// Toggle background blur on camera video
    func setBackgroundBlur(enabled: Bool) {
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: Background blur not available on simulator")
        #else
        guard let videoTrack = room.localParticipant.videoTracks.first?.track as? LocalVideoTrack else {
            MXLog.warning("sTalk LiveKit: No local video track for background blur")
            return
        }

        if enabled {
            let processor = BackgroundBlurVideoProcessor()
            blurProcessor = processor
            videoTrack.capturer.processor = processor
            MXLog.info("sTalk LiveKit: Background blur enabled")
        } else {
            videoTrack.capturer.processor = nil
            blurProcessor = nil
            MXLog.info("sTalk LiveKit: Background blur disabled")
        }
        isBackgroundBlurEnabled = enabled
        #endif
    }

    /// Toggle enhanced noise suppression
    func setNoiseSuppression(enabled: Bool) {
        #if targetEnvironment(simulator)
        MXLog.warning("sTalk LiveKit: Noise suppression not available on simulator")
        #else
        let audioManager = AudioManager.shared
        if enabled {
            audioManager.isVoiceProcessingBypassed = false
            MXLog.info("sTalk LiveKit: Enhanced noise suppression enabled")
        } else {
            // Voice processing is on by default on iOS — bypassing disables it
            MXLog.info("sTalk LiveKit: Standard noise suppression")
        }
        isNoiseSuppressed = enabled
        #endif
    }

    func setSpeaker(enabled: Bool) {
        // EXACT shipped 26.04.06 implementation. Do NOT touch LiveKit's isSpeakerOutputPreferred
        // here or anywhere: every attempt (builds 214-222) to drive it caused regressions up to a
        // dead audio session. The production stack: LiveKit keeps its default (speaker), the app
        // overrides the port, the route picker does system routing on top.
        let session = AVAudioSession.sharedInstance()
        do {
            if enabled {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
            MXLog.info("sTalk LiveKit: Speaker \(enabled ? "enabled" : "disabled")")
        } catch {
            MXLog.error("sTalk LiveKit: Failed to set speaker: \(error)")
        }
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
        // EXACT shipped 26.04.06 implementation — do NOT touch AudioManager.isSpeakerOutputPreferred
        // (see setSpeaker). LiveKit's engine start applies its speaker default on top of this.
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

            // Explicitly set output route
            if speakerByDefault {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none) // earpiece
            }

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
        }
    }
}
