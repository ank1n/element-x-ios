//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
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
    func connect(wsURL: String, token: String) async throws {
        let baseURL = extractBaseURL(from: wsURL)
        MXLog.info("sTalk LiveKit: Connecting to \(baseURL)")

        // Store for potential reconnection
        reconnectURL = baseURL
        reconnectToken = token

        // Configure iOS audio session for VoIP BEFORE connecting
        configureAudioSession()

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
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setPreferredIOBufferDuration(0.005) // 5ms — reduces crackling
            try session.setPreferredSampleRate(48000)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            MXLog.info("sTalk LiveKit: Audio session configured for VoIP")
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
