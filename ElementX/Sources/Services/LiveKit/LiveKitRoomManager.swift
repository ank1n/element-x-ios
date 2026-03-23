//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import LiveKit
import SwiftUI

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
    var roomName: String? { room.name }

    // MARK: - Private

    private let room: Room
    private var cancellables = Set<AnyCancellable>()
    private var reconnectToken: String?
    private var reconnectURL: String?

    init() {
        room = Room()
        room.add(delegate: self)
    }

    deinit {
        Task { @MainActor [room] in
            await room.disconnect()
        }
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

        // Configure iOS audio session for VoIP BEFORE connecting
        configureAudioSession(speakerByDefault: speakerByDefault)

        let connectOptions = ConnectOptions(
            autoSubscribe: true
        )
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(
                dimensions: .h720_169
            ),
            defaultAudioCaptureOptions: AudioCaptureOptions(), // Platform defaults: Apple Voice Processing on device, WebRTC on simulator
            defaultVideoPublishOptions: VideoPublishOptions(
                encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
            ),
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: AudioEncoding(maxBitrate: 32_000), // 32 kbps minimum — prevents low frame rate (19→50 pps)
                dtx: false // DTX off — don't skip packets on silence, keeps consistent frame rate
            )
        )

        try await room.connect(url: baseURL, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        MXLog.info("sTalk LiveKit: Connected to room \(room.name ?? "unknown")")
        updateState()
    }

    func disconnect() async {
        reconnectURL = nil
        reconnectToken = nil
        await room.disconnect()
        MXLog.info("sTalk LiveKit: Disconnected")
        updateState()
    }

    /// Connect as subscribe-only observer with a different identity (for blur rendering)
    /// Uses a separate JWT so SFU sees two different participants
    func connectAsObserver(wsURL: String, originalToken: String) async throws {
        // Decode original JWT to get room name and identity
        guard let (roomName, identity) = decodeJWT(originalToken) else {
            MXLog.error("sTalk LiveKit: Failed to decode JWT")
            return
        }

        let observerIdentity = identity + "_observer"
        let baseURL = extractBaseURL(from: wsURL)

        // Generate new JWT with observer identity (subscribe-only)
        let apiKey = "APIe5e237fe719f"
        let apiSecret = "6b0d7fe4c5b393c004bf813ae8dd428f70aef4896957fcb9b0ad58d37c353f96"
        guard let observerToken = generateLiveKitJWT(
            apiKey: apiKey,
            apiSecret: apiSecret,
            roomName: roomName,
            identity: observerIdentity,
            canPublish: false,
            canSubscribe: true
        ) else {
            MXLog.error("sTalk LiveKit: Failed to generate observer JWT")
            return
        }

        MXLog.info("sTalk LiveKit: Connecting as observer '\(observerIdentity)' to \(baseURL)")

        let connectOptions = ConnectOptions(autoSubscribe: true)
        let roomOptions = RoomOptions()

        try await room.connect(url: baseURL, token: observerToken, connectOptions: connectOptions, roomOptions: roomOptions)
        MXLog.info("sTalk LiveKit: Observer connected to room \(room.name ?? "?")")
        updateState()
    }

    // MARK: - JWT Generation

    private func decodeJWT(_ token: String) -> (roomName: String, identity: String)? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1]).base64Padded()) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let video = json["video"] as? [String: Any],
              let room = video["room"] as? String else { return nil }
        return (room, sub)
    }

    private func generateLiveKitJWT(apiKey: String, apiSecret: String, roomName: String, identity: String, canPublish: Bool, canSubscribe: Bool) -> String? {
        let header = ["alg": "HS256", "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "nbf": now,
            "exp": now + 3600,
            "video": [
                "room": roomName,
                "roomJoin": true,
                "canPublish": canPublish,
                "canSubscribe": canSubscribe
            ]
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let headerB64 = headerData.base64EncodedString().base64URLEncoded()
        let payloadB64 = payloadData.base64EncodedString().base64URLEncoded()
        let signingInput = "\(headerB64).\(payloadB64)"

        guard let keyData = apiSecret.data(using: .utf8) else { return nil }
        let key = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let sigB64 = Data(signature).base64EncodedString().base64URLEncoded()

        return "\(headerB64).\(payloadB64).\(sigB64)"
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

    /// Toggle screen sharing
    @Published private(set) var isScreenSharing: Bool = false

    /// Toggle background blur
    @Published private(set) var isBackgroundBlurEnabled: Bool = false

    /// Toggle noise suppression (enhanced)
    @Published private(set) var isNoiseSuppressed: Bool = false

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
        let track = LocalVideoTrack.createBufferTrack(
            name: "camera",
            source: .camera,
            options: BufferCaptureOptions()
        )
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
                row[offset] = bVal     // B
                row[offset + 1] = gVal // G
                row[offset + 2] = rVal // R
                row[offset + 3] = 255  // A
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
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
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

            // Handle reconnection states
            switch connectionState {
            case .connected:
                self.updateState()
            case .disconnected:
                // If we have stored credentials and were previously connected, this is an unexpected disconnect
                if oldConnectionState == .connected || oldConnectionState == .reconnecting {
                    MXLog.warning("sTalk LiveKit: Unexpected disconnect from \(oldConnectionState)")
                }
            default:
                break
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

// MARK: - Base64 URL Encoding Helpers

private extension String {
    func base64URLEncoded() -> String {
        replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func base64Padded() -> String {
        let remainder = count % 4
        if remainder == 0 { return self }
        return self + String(repeating: "=", count: 4 - remainder)
    }
}
