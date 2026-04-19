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

    // Watchdog for stuck .reconnecting state — forces our own reconnect attempt if
    // LiveKit SDK can't recover on its own within the timeout.
    private var reconnectingWatchdog: Task<Void, Never>?
    private let reconnectingTimeoutSec: UInt64 = 10

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
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "sTalk.LiveKit.WS") { [weak self] in
            guard let self else { return }
            if self.backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
            os_log(.error, log: livekitLog, "Background task expired — WS may be frozen next")
        }
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
        let roomOptions = RoomOptions(defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h1080_169),
                                      defaultAudioCaptureOptions: AudioCaptureOptions(),
                                      defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30),
                                                                                      simulcast: true),
                                      defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 48000),
                                                                                      dtx: false))

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
        let roomOptions = RoomOptions(defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h1080_169),
                                      defaultAudioCaptureOptions: AudioCaptureOptions(),
                                      defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30),
                                                                                      simulcast: true),
                                      defaultAudioPublishOptions: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 48000),
                                                                                      dtx: false),
                                      encryptionOptions: encryptionOptions)

        try await room.connect(url: baseURL, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        MXLog.info("sTalk LiveKit: Connected with E2EE to room \(room.name ?? "unknown")")
        updateState()
    }

    /// Force reconnect — used on network change to trigger ICE restart on new interface.
    /// Keeps saved credentials + keyProvider, so re-connection is transparent. Media will
    /// briefly drop (~1-3s) but UDP path will re-establish on the new network.
    func forceReconnect() async {
        guard reconnectURL != nil, reconnectToken != nil else {
            os_log(.error, log: livekitLog, "forceReconnect skipped — no saved credentials")
            return
        }
        os_log(.info, log: livekitLog, "forceReconnect: tearing down current WS for ICE restart")
        // Tear down current room connection but keep credentials for auto-reconnect.
        await room.disconnect()
        // Do NOT clear credentials — just re-trigger the reconnect path.
        attemptAutoReconnect()
    }

    func disconnect() async {
        reconnectURL = nil
        reconnectToken = nil
        savedKeyProvider = nil
        reconnectAttempt = 0
        reconnectingWatchdog?.cancel()
        reconnectingWatchdog = nil
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

    func setCamera(enabled: Bool) async throws {
        #if targetEnvironment(simulator)
        if enabled {
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
        if enabled {
            try await publishSimulatorAudioTrack()
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

    /// Switch between speaker and earpiece
    func setSpeaker(enabled: Bool) {
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

        // Get local video track
        localVideoTrack = room.localParticipant.videoTracks
            .compactMap { $0.track as? VideoTrack }
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

            switch connectionState {
            case .connected:
                self.reconnectAttempt = 0
                self.reconnectingWatchdog?.cancel()
                self.reconnectingWatchdog = nil
                self.updateState()
            case .reconnecting:
                // If SDK internal reconnect stalls, our watchdog forces a full reconnect
                // after timeout. Otherwise call can hang indefinitely in .reconnecting.
                self.reconnectingWatchdog?.cancel()
                self.reconnectingWatchdog = Task { [weak self] in
                    let timeout = self?.reconnectingTimeoutSec ?? 10
                    try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    guard self.connectionState == .reconnecting else { return }
                    os_log(.error, log: livekitLog,
                           "Stuck in .reconnecting for %ds — forcing full reconnect", Int(timeout))
                    await self.room.disconnect()
                    self.attemptAutoReconnect()
                }
            case .disconnected:
                self.reconnectingWatchdog?.cancel()
                self.reconnectingWatchdog = nil
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
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Participant joined: \(participant.identity?.stringValue ?? "unknown"), sid=\(participant.sid?.stringValue ?? "nil"), totalRemote=\(self.remoteParticipants.count)")
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Participant left: \(participant.identity?.stringValue ?? "unknown"), sid=\(participant.sid?.stringValue ?? "nil"), remainingRemote=\(self.remoteParticipants.count)")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Subscribed to track: \(publication.kind) from \(participant.identity?.stringValue ?? "unknown")")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            self.updateState()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in
            self.updateState()
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in
            self.updateState()
            MXLog.info("sTalk LiveKit: Published local track: \(publication.kind)")
        }
    }
}
