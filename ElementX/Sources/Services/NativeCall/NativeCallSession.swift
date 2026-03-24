//
// NativeCallSession.swift
// sTalk — Native call session: WidgetDriver signaling + LiveKit native SDK
//
// Replaces WebView for calls. Uses WidgetDriver for MatrixRTC signaling,
// native LiveKit SDK for media (camera, microphone, video, audio, E2EE).
//

import Combine
import CryptoKit
import Foundation
import LiveKit
import MatrixRustSDK

private let log = MXLog.self

@MainActor
final class NativeCallSession: ObservableObject {
    // MARK: - Published State

    @Published private(set) var sessionState: NativeCallSessionState = .starting
    @Published private(set) var roomManager: LiveKitRoomManager?

    // MARK: - Dependencies

    private let widgetDriver: ElementCallWidgetDriverProtocol
    private let liveKitRoomManager: LiveKitRoomManager
    private let keyProvider = BaseKeyProvider(isSharedKey: false)
    private let isEncrypted: Bool

    // MARK: - E2EE Key Management

    private var participantKeys: [String: Bool] = [:] // identity → hasKey
    private var pendingParticipants: [String: RemoteParticipant] = [:]
    private var credentialsReceived = false

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(widgetDriver: ElementCallWidgetDriverProtocol,
         liveKitRoomManager: LiveKitRoomManager,
         isEncrypted: Bool) {
        self.widgetDriver = widgetDriver
        self.liveKitRoomManager = liveKitRoomManager
        self.isEncrypted = isEncrypted
    }

    // MARK: - Start

    func start(baseURL: URL,
               clientID: String,
               colorScheme: SwiftUI.ColorScheme) async {
        log.info("sTalk NativeCall: Starting session, encrypted=\(isEncrypted)")
        sessionState = .starting

        // Step 1: Start WidgetDriver (creates MatrixRTC session)
        let result = await widgetDriver.start(
            baseURL: baseURL,
            clientID: clientID,
            colorScheme: colorScheme,
            rageshakeURL: nil,
            analyticsConfiguration: nil
        )

        guard case .success = result else {
            log.error("sTalk NativeCall: WidgetDriver failed to start")
            sessionState = .failed(NativeCallError.widgetDriverFailed)
            return
        }

        // Step 2: Listen to widget messages
        widgetDriver.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.processWidgetMessage(message)
            }
            .store(in: &cancellables)

        // Step 3: Listen to widget actions (callEnded, mediaState)
        widgetDriver.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.handleWidgetAction(action)
            }
            .store(in: &cancellables)

        // Step 4: Send content_loaded to kick off MatrixRTC join
        let contentLoaded = """
        {"api":"fromWidget","action":"content_loaded","widgetId":"\(widgetDriver.widgetID)","requestId":"native-\(UUID().uuidString)","data":{}}
        """
        await widgetDriver.handleMessage(contentLoaded)

        sessionState = .waitingForCredentials
        log.info("sTalk NativeCall: content_loaded sent, waiting for credentials")
    }

    // MARK: - Stop

    func stop() async {
        log.info("sTalk NativeCall: Stopping session")
        sessionState = .disconnecting

        // Send hangup
        let hangup = """
        {"api":"fromWidget","action":"im.vector.hangup","widgetId":"\(widgetDriver.widgetID)","requestId":"native-\(UUID().uuidString)","data":{}}
        """
        await widgetDriver.handleMessage(hangup)

        // Disconnect LiveKit
        await liveKitRoomManager.disconnect()

        cancellables.removeAll()
        sessionState = .disconnected
    }

    // MARK: - Message Processing

    private func processWidgetMessage(_ messageString: String) {
        guard let message = WidgetAPIMessage(jsonString: messageString) else { return }

        // Only process toWidget messages
        guard message.api == "toWidget" else { return }

        switch message.action {
        case "send_event":
            handleSendEvent(message)

        case "send_to_device":
            // E2EE encryption keys via to-device
            if message.eventType == "io.element.call.encryption_keys" {
                handleEncryptionKeys(message)
            }

        default:
            // Log unknown actions for debugging
            if message.action != "capabilities" {
                log.debug("sTalk NativeCall: Unhandled toWidget action: \(message.action)")
            }
        }

        // Also check fromWidget messages for encryption_keys
        if message.api == "fromWidget" && messageString.contains("encryption_keys") {
            handleEncryptionKeys(message)
        }
    }

    // MARK: - Event Handlers

    private func handleSendEvent(_ message: WidgetAPIMessage) {
        guard let eventType = message.eventType else { return }

        switch eventType {
        case "org.matrix.msc3401.call.member",
             "m.call.member":
            handleCallMemberEvent(message)

        default:
            break
        }
    }

    private func handleCallMemberEvent(_ message: WidgetAPIMessage) {
        // Extract LiveKit focus URL from call.member event
        if let focus = message.extractLiveKitFocus() {
            log.info("sTalk NativeCall: Found LiveKit focus URL: \(focus.url)")
            // We need the JWT too — it comes through the LiveKit WS URL
            // Actually, in embedded mode, the JWT comes from a separate mechanism
            // For now, store the base URL
        }
    }

    private func handleEncryptionKeys(_ message: WidgetAPIMessage) {
        guard let keyInfo = message.extractEncryptionKeys() else { return }

        log.info("sTalk NativeCall: E2EE key from \(keyInfo.participantId) index=\(keyInfo.index)")

        // Set key in provider
        keyProvider.setKey(key: keyInfo.key, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
        participantKeys[keyInfo.participantId] = true

        // Subscribe pending participants
        if let participant = pendingParticipants.removeValue(forKey: keyInfo.participantId) {
            subscribeToAllTracks(of: participant)
        }
    }

    private func handleWidgetAction(_ action: ElementCallWidgetDriverAction) {
        switch action {
        case .callEnded:
            log.info("sTalk NativeCall: Call ended from widget")
            Task { await stop() }

        case .mediaStateChanged(let audioEnabled, let videoEnabled):
            log.info("sTalk NativeCall: Media state — audio=\(audioEnabled), video=\(videoEnabled)")

        case .encryptionKeysReceived(let keys):
            for keyData in keys {
                if let key = keyData["key"] as? String,
                   let index = keyData["index"] as? Int,
                   let pid = keyData["participantId"] as? String {
                    keyProvider.setKey(key: key, participantId: pid, index: Int32(index))
                    participantKeys[pid] = true
                    if let participant = pendingParticipants.removeValue(forKey: pid) {
                        subscribeToAllTracks(of: participant)
                    }
                }
            }
        }
    }

    // MARK: - LiveKit Connection

    /// Called when LiveKit credentials are available (from intercepted WebSocket or Widget API)
    func connectToLiveKit(url: String, token: String) async {
        guard !credentialsReceived else { return }
        credentialsReceived = true

        sessionState = .connecting
        log.info("sTalk NativeCall: Connecting to LiveKit")

        do {
            if isEncrypted {
                try await liveKitRoomManager.connectWithE2EE(
                    wsURL: url,
                    token: token,
                    keyProvider: keyProvider,
                    speakerByDefault: false
                )
            } else {
                try await liveKitRoomManager.connect(
                    wsURL: url,
                    token: token,
                    speakerByDefault: false
                )
            }

            sessionState = .connected
            roomManager = liveKitRoomManager
            log.info("sTalk NativeCall: Connected to LiveKit")

            // Publish media
            try? await liveKitRoomManager.setMicrophone(enabled: true)
            try? await liveKitRoomManager.setCamera(enabled: true)

            // Subscribe to pending participants that already have keys
            for (identity, participant) in pendingParticipants {
                if participantKeys[identity] == true {
                    subscribeToAllTracks(of: participant)
                    pendingParticipants.removeValue(forKey: identity)
                }
            }

        } catch {
            log.error("sTalk NativeCall: LiveKit connect failed: \(error)")
            sessionState = .failed(error)
        }
    }

    // MARK: - Track Subscription

    func handleRemoteParticipantConnected(_ participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""

        if !isEncrypted || participantKeys[identity] == true {
            subscribeToAllTracks(of: participant)
        } else {
            pendingParticipants[identity] = participant
            log.info("sTalk NativeCall: Queued participant \(identity) — waiting for E2EE key")
        }
    }

    private func subscribeToAllTracks(of participant: RemoteParticipant) {
        Task {
            for publication in participant.trackPublications.values {
                if let remotePub = publication as? RemoteTrackPublication, !remotePub.isSubscribed {
                    try? await remotePub.set(subscribed: true)
                    log.info("sTalk NativeCall: Subscribed to \(String(describing: remotePub.kind)) from \(participant.identity?.stringValue ?? "?")")
                }
            }
        }
    }
}

// MARK: - Errors

enum NativeCallError: Error {
    case widgetDriverFailed
    case noCredentials
    case connectionFailed
}
