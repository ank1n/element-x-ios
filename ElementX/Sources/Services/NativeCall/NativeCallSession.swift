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
import SwiftUI

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
    private let userId: String
    private let deviceId: String
    private let matrixRoomId: String

    // MARK: - LiveKit Config
    // TODO: Move to AppSettings or server config
    private let livekitAPIKey = "APIe5e237fe719f"
    private let livekitAPISecret = "6b0d7fe4c5b393c004bf813ae8dd428f70aef4896957fcb9b0ad58d37c353f96"

    // MARK: - E2EE Key Management

    private var participantKeys: [String: Bool] = [:]
    private var pendingParticipants: [String: RemoteParticipant] = [:]
    private var credentialsReceived = false
    private var livekitBaseURL: String?

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(widgetDriver: ElementCallWidgetDriverProtocol,
         liveKitRoomManager: LiveKitRoomManager,
         isEncrypted: Bool,
         userId: String,
         deviceId: String,
         matrixRoomId: String) {
        self.widgetDriver = widgetDriver
        self.liveKitRoomManager = liveKitRoomManager
        self.isEncrypted = isEncrypted
        self.userId = userId
        self.deviceId = deviceId
        self.matrixRoomId = matrixRoomId
    }

    // MARK: - Start

    func start(baseURL: URL,
               clientID: String,
               colorScheme: SwiftUI.ColorScheme) async {
        MXLog.info("sTalk NativeCall: Starting session, encrypted=\(isEncrypted), user=\(userId)")
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
            MXLog.error("sTalk NativeCall: WidgetDriver failed to start")
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

        // Step 3: Listen to widget actions
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
        MXLog.info("sTalk NativeCall: content_loaded sent, waiting for focus info")

        // Step 5: Wait for capabilities to complete, then send join membership
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.sendJoinMembership()
        }
    }

    // MARK: - Join Membership

    private func sendJoinMembership() async {
        let stateKey = userId
        let expiresTs = Int(Date().timeIntervalSince1970 * 1000) + 7_200_000 // 2 hours

        let membership: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "scope": "m.room",
            "device_id": deviceId,
            "expires": expiresTs,
            "foci_preferred": [
                ["type": "livekit", "livekit_service_url": "https://livekit.stalk.implica.ru"]
            ],
            "membershipID": UUID().uuidString
        ]

        let eventData: [String: Any] = [
            "type": "org.matrix.msc3401.call.member",
            "state_key": stateKey,
            "content": ["memberships": [membership]]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            MXLog.error("sTalk NativeCall: Failed to serialize join membership")
            return
        }

        let sendEvent = """
        {"api":"fromWidget","action":"send_event","widgetId":"\(widgetDriver.widgetID)","requestId":"native-join-\(UUID().uuidString)","data":\(jsonString)}
        """

        MXLog.info("sTalk NativeCall: Sending join membership via Widget API")
        await widgetDriver.handleMessage(sendEvent)

        // After join, generate JWT and connect to LiveKit
        try? await Task.sleep(for: .seconds(2))
        await connectWithGeneratedJWT()
    }

    private func connectWithGeneratedJWT() async {
        let sfuURL = "wss://livekit.stalk.implica.ru"
        let identity = "\(userId):\(deviceId)"

        // Room name = base64(SHA256(matrixRoomID + "|m.call#ROOM")) — same as lk-jwt-service
        guard let roomName = generateLiveKitRoomName() else {
            MXLog.error("sTalk NativeCall: Failed to generate room name")
            sessionState = .failed(NativeCallError.noCredentials)
            return
        }

        guard let jwt = generateLiveKitJWT(roomName: roomName, identity: identity) else {
            MXLog.error("sTalk NativeCall: Failed to generate JWT")
            sessionState = .failed(NativeCallError.noCredentials)
            return
        }

        MXLog.info("sTalk NativeCall: Generated JWT for room=\(roomName), identity=\(identity)")
        await connectToLiveKit(url: sfuURL, token: jwt)
    }

    private func generateLiveKitRoomName() -> String? {
        guard !matrixRoomId.isEmpty else { return nil }
        let raw = "\(matrixRoomId)|m.call#ROOM"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Stop

    func stop() async {
        MXLog.info("sTalk NativeCall: Stopping session")
        sessionState = .disconnecting

        let hangup = """
        {"api":"fromWidget","action":"im.vector.hangup","widgetId":"\(widgetDriver.widgetID)","requestId":"native-\(UUID().uuidString)","data":{}}
        """
        await widgetDriver.handleMessage(hangup)

        await liveKitRoomManager.disconnect()
        cancellables.removeAll()
        sessionState = .disconnected
    }

    // MARK: - Message Processing

    private func processWidgetMessage(_ messageString: String) {
        guard let message = WidgetAPIMessage(jsonString: messageString) else {
            MXLog.info("sTalk NativeCall: Unparseable message: \(messageString.prefix(200))")
            return
        }

        // Log all messages
        MXLog.info("sTalk NativeCall: \(message.api) action=\(message.action) type=\(message.eventType ?? "-") reqId=\(message.requestId)")

        // Process toWidget messages and send acknowledgments
        if message.api == "toWidget" {
            // Send acknowledgment for every toWidget message
            Task {
                let ack = """
                {"api":"fromWidget","action":"\(message.action)","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","response":{}}
                """
                await widgetDriver.handleMessage(ack)
            }

            switch message.action {
            case "send_event":
                handleSendEvent(message)
            case "send_to_device":
                if messageString.contains("encryption_keys") {
                    handleEncryptionKeys(message)
                }
            default:
                break
            }
        }

        // Also check any direction for encryption_keys
        if messageString.contains("encryption_keys") {
            handleEncryptionKeys(message)
        }
    }

    // MARK: - Event Handlers

    private func handleSendEvent(_ message: WidgetAPIMessage) {
        guard let eventType = message.eventType else { return }

        switch eventType {
        case "org.matrix.msc3401.call.member", "m.call.member":
            handleCallMemberEvent(message)
        default:
            break
        }
    }

    private func handleCallMemberEvent(_ message: WidgetAPIMessage) {
        guard let content = message.callMemberContent else { return }

        // Extract LiveKit SFU URL from focus config
        var sfuURL: String?
        var roomAlias: String?

        // Try memberships → foci_preferred
        if let memberships = content["memberships"] as? [[String: Any]] {
            for membership in memberships {
                if let foci = membership["foci_preferred"] as? [[String: Any]] {
                    for focus in foci where (focus["type"] as? String) == "livekit" {
                        sfuURL = focus["livekit_service_url"] as? String
                        roomAlias = focus["livekit_alias"] as? String
                    }
                }
                if let foci = membership["foci_active"] as? [[String: Any]] {
                    for focus in foci where (focus["type"] as? String) == "livekit" {
                        sfuURL = sfuURL ?? (focus["livekit_service_url"] as? String)
                        roomAlias = roomAlias ?? (focus["livekit_alias"] as? String)
                    }
                }
            }
        }

        // Try direct focus_active
        if sfuURL == nil, let focus = content["focus_active"] as? [String: Any],
           (focus["type"] as? String) == "livekit" {
            sfuURL = focus["livekit_service_url"] as? String
            roomAlias = focus["livekit_alias"] as? String
        }

        guard let url = sfuURL else { return }

        MXLog.info("sTalk NativeCall: LiveKit focus — URL=\(url), alias=\(roomAlias ?? "nil")")
        livekitBaseURL = url

        // Generate JWT and connect
        if !credentialsReceived, let roomName = roomAlias {
            let identity = "\(userId):\(deviceId)"
            guard let jwt = generateLiveKitJWT(roomName: roomName, identity: identity) else {
                MXLog.error("sTalk NativeCall: Failed to generate JWT")
                return
            }
            MXLog.info("sTalk NativeCall: JWT generated for \(identity), connecting...")
            Task { await connectToLiveKit(url: url, token: jwt) }
        }
    }

    private func handleEncryptionKeys(_ message: WidgetAPIMessage) {
        guard let keyInfo = message.extractEncryptionKeys(), !keyInfo.participantId.isEmpty else { return }

        MXLog.info("sTalk NativeCall: E2EE key from \(keyInfo.participantId) index=\(keyInfo.index)")

        keyProvider.setKey(key: keyInfo.key, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
        participantKeys[keyInfo.participantId] = true

        if let participant = pendingParticipants.removeValue(forKey: keyInfo.participantId) {
            subscribeToAllTracks(of: participant)
        }
    }

    private func handleWidgetAction(_ action: ElementCallWidgetDriverAction) {
        switch action {
        case .callEnded:
            MXLog.info("sTalk NativeCall: Call ended from widget")
            Task { await stop() }
        case .mediaStateChanged(let audioEnabled, let videoEnabled):
            MXLog.info("sTalk NativeCall: Media state — audio=\(audioEnabled), video=\(videoEnabled)")
        }
    }

    // MARK: - LiveKit Connection

    private func connectToLiveKit(url: String, token: String) async {
        guard !credentialsReceived else { return }
        credentialsReceived = true
        sessionState = .connecting

        do {
            if isEncrypted {
                try await liveKitRoomManager.connectWithE2EE(
                    wsURL: url,
                    token: token,
                    keyProvider: keyProvider,
                    speakerByDefault: false
                )
            } else {
                try await liveKitRoomManager.connect(wsURL: url, token: token, speakerByDefault: false)
            }

            sessionState = .connected
            roomManager = liveKitRoomManager
            MXLog.info("sTalk NativeCall: Connected to LiveKit")

            // Publish media
            try? await liveKitRoomManager.setMicrophone(enabled: true)
            try? await liveKitRoomManager.setCamera(enabled: true)
            MXLog.info("sTalk NativeCall: Camera + microphone enabled")

            // Subscribe pending participants
            for (identity, participant) in pendingParticipants where participantKeys[identity] == true || !isEncrypted {
                subscribeToAllTracks(of: participant)
                pendingParticipants.removeValue(forKey: identity)
            }
        } catch {
            MXLog.error("sTalk NativeCall: LiveKit connect failed: \(error)")
            sessionState = .failed(error)
        }
    }

    // MARK: - Participant Management

    func handleRemoteParticipantConnected(_ participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        if !isEncrypted || participantKeys[identity] == true {
            subscribeToAllTracks(of: participant)
        } else {
            pendingParticipants[identity] = participant
            MXLog.info("sTalk NativeCall: Queued \(identity) — waiting for E2EE key")
        }
    }

    private func subscribeToAllTracks(of participant: RemoteParticipant) {
        Task {
            for pub in participant.trackPublications.values {
                if let remotePub = pub as? RemoteTrackPublication, !remotePub.isSubscribed {
                    try? await remotePub.set(subscribed: true)
                    MXLog.info("sTalk NativeCall: Subscribed \(String(describing: remotePub.kind)) from \(participant.identity?.stringValue ?? "?")")
                }
            }
        }
    }

    // MARK: - JWT Generation

    private func generateLiveKitJWT(roomName: String, identity: String) -> String? {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": livekitAPIKey,
            "sub": identity,
            "nbf": now,
            "exp": now + 3600,
            "video": [
                "room": roomName,
                "roomJoin": true,
                "canPublish": true,
                "canSubscribe": true
            ]
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let headerB64 = headerData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let signingInput = "\(headerB64).\(payloadB64)"
        guard let keyData = livekitAPISecret.data(using: .utf8) else { return nil }
        let key = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let sigB64 = Data(signature).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return "\(headerB64).\(payloadB64).\(sigB64)"
    }
}

// MARK: - Errors

enum NativeCallError: Error {
    case widgetDriverFailed
    case noCredentials
    case connectionFailed
}
