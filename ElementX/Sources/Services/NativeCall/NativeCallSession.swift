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
@testable import LiveKit
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
    private let homeserverURL: String
    private let accessToken: String
    private let roomProxy: JoinedRoomProxyProtocol?

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
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Init

    init(widgetDriver: ElementCallWidgetDriverProtocol,
         liveKitRoomManager: LiveKitRoomManager,
         isEncrypted: Bool,
         userId: String,
         deviceId: String,
         matrixRoomId: String,
         homeserverURL: String,
         accessToken: String,
         roomProxy: JoinedRoomProxyProtocol? = nil) {
        self.widgetDriver = widgetDriver
        self.liveKitRoomManager = liveKitRoomManager
        self.isEncrypted = isEncrypted
        self.userId = userId
        self.deviceId = deviceId
        self.matrixRoomId = matrixRoomId
        self.homeserverURL = homeserverURL.hasSuffix("/") ? String(homeserverURL.dropLast()) : homeserverURL
        self.accessToken = accessToken
        self.roomProxy = roomProxy
    }

    // MARK: - Start

    func start(baseURL: URL,
               clientID: String,
               colorScheme: SwiftUI.ColorScheme) async {
        MXLog.info("sTalk NativeCall: Starting session, encrypted=\(isEncrypted), user=\(userId)")
        sessionState = .starting

        // Start WidgetDriver in background for E2EE key exchange only
        // WidgetDriver uses different state_key format, won't conflict with our REST join
        let driverResult = await widgetDriver.start(
            baseURL: baseURL,
            clientID: clientID,
            colorScheme: colorScheme,
            rageshakeURL: nil,
            analyticsConfiguration: nil
        )
        if case .success = driverResult {
            widgetDriver.messagePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.processWidgetMessage(message)
                }
                .store(in: &cancellables)

            // Step 1: Request capabilities (same as Element Call JS does)
            let capabilities = [
                "org.matrix.msc3819.send.to_device:io.element.call.encryption_keys",
                "org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys",
                "org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member",
                "org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member",
                "org.matrix.msc2762.send.state_event:org.matrix.msc4075.rtc.notification",
                "org.matrix.msc2762.receive.state_event:org.matrix.msc4075.rtc.notification",
                "org.matrix.msc2762.send.delayed_event",
                "org.matrix.msc2762.update.delayed_event",
                "requires_client"
            ]
            let capsJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let capRequest = """
            {"api":"fromWidget","action":"org.matrix.msc2974.request_capabilities","widgetId":"\(widgetDriver.widgetID)","requestId":"native-cap-\(UUID().uuidString)","data":{"capabilities":[\(capsJSON)]}}
            """
            await widgetDriver.handleMessage(capRequest)
            MXLog.info("sTalk NativeCall: WidgetDriver — capabilities requested")

            // Wait for driver to process capabilities
            try? await Task.sleep(for: .seconds(1))

            // Step 2: content_loaded
            let contentLoaded = """
            {"api":"fromWidget","action":"content_loaded","widgetId":"\(widgetDriver.widgetID)","requestId":"native-\(UUID().uuidString)","data":{}}
            """
            await widgetDriver.handleMessage(contentLoaded)
            MXLog.info("sTalk NativeCall: WidgetDriver — content_loaded sent")

            try? await Task.sleep(for: .seconds(1))

            // Step 3: io.element.join — trigger MatrixRTC
            let joinCall = """
            {"api":"fromWidget","action":"io.element.join","widgetId":"\(widgetDriver.widgetID)","requestId":"native-join-\(UUID().uuidString)","data":{}}
            """
            await widgetDriver.handleMessage(joinCall)
            MXLog.info("sTalk NativeCall: WidgetDriver — io.element.join sent")
        }

        // E2EE key exchange
        if isEncrypted {
            // Listen to room timeline for incoming encryption keys
            listenForEncryptionKeysFromTimeline()

            // Send our key
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.sendOurEncryptionKey()
            }
        }

        // Generate JWT and connect to LiveKit
        sessionState = .waitingForCredentials
        await connectWithGeneratedJWT()
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
            "expires_ts": expiresTs,
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

        // Send MatrixRTC join via REST API so remote participants see us
        await sendJoinViaREST()

        // Send call notification for incoming call ring on remote
        await sendCallNotification()

        // Debug: read current state events to compare formats
        await debugReadCallMemberState()

        await connectToLiveKit(url: sfuURL, token: jwt)
    }

    private func generateLiveKitRoomName() -> String? {
        guard !matrixRoomId.isEmpty else { return nil }
        let raw = "\(matrixRoomId)|m.call#ROOM"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - MatrixRTC Join via REST API

    private func sendJoinViaREST() async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        // State key format: _@user:server_deviceId_m.call
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        for eventType in ["org.matrix.msc3401.call.member"] {
            let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)"

            // Flat format matching Element Call web client
            let body: [String: Any] = [
                "application": "m.call",
                "call_id": "",
                "scope": "m.room",
                "device_id": deviceId,
                "expires": 7200000,
                "foci_preferred": [[
                    "type": "livekit",
                    "livekit_alias": matrixRoomId,
                    "livekit_service_url": "https://jwt.stalk.implica.ru"
                ]],
                "focus_active": [
                    "type": "livekit",
                    "focus_selection": "oldest_membership"
                ]
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { continue }

            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                MXLog.info("sTalk NativeCall: REST join \(eventType) → \(status) url=\(url) body=\(body.prefix(200))")
            } catch {
                MXLog.error("sTalk NativeCall: REST join failed: \(error)")
            }
        }
    }

    // MARK: - Raw Key Provider Access

    /// Set raw bytes key in BaseKeyProvider, bypassing UTF-8 string conversion
    /// BaseKeyProvider.rtcKeyProvider is internal, so we use KVC to access it
    /// Set key using the same raw bytes that EC JS uses
    /// Converts raw Data to a String where each byte maps 1:1 (ISO Latin-1)
    /// LiveKit SDK will .utf8 encode this — for ASCII-range bytes it's identical
    private func setRawKeyInProvider(_ provider: BaseKeyProvider, key: Data, participantId: String, index: Int32) {
        // Access rtcKeyProvider directly to pass raw bytes (not UTF-8 string)
        provider.rtcKeyProvider.setKey(key, with: index, forParticipant: participantId)
        MXLog.info("sTalk E2EE: Raw key set (\(key.count) bytes) for \(participantId)")
    }

    // MARK: - E2EE Key Exchange

    private var ourEncryptionKey: String? // base64
    private var ourEncryptionKeyRaw: Data? // raw 16 bytes

    private func sendOurEncryptionKey() async {
        // Generate random 16-byte key (base64)
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        ourEncryptionKey = key

        // Set our own key in keyProvider
        let ourIdentity = "\(userId):\(deviceId)"
        keyProvider.setKey(key: key, participantId: ourIdentity, index: 0)
        MXLog.info("sTalk NativeCall E2EE: Generated our key, identity=\(ourIdentity)")

        // Fire-and-forget — handleMessage may hang if driver can't process
        let widgetId = widgetDriver.widgetID
        let roomId = matrixRoomId
        let devId = deviceId
        let driver = widgetDriver
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        // Send via Widget API send_to_device
        Task.detached {
            let msg = """
            {"api":"fromWidget","action":"send_to_device","widgetId":"\(widgetId)","requestId":"native-key-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","encrypted":true,"messages":{"*":{"*":{"keys":{"index":0,"key":"\(key)"},"room_id":"\(roomId)","member":{"claimed_device_id":"\(devId)"},"session":{"call_id":"","application":"m.call","scope":"m.room"},"sent_ts":\(nowMs)}}}}}
            """
            let result = await driver.handleMessage(msg)
            MXLog.info("sTalk NativeCall E2EE: send_to_device result=\(result)")
        }

        // Send as room event
        Task.detached {
            let msg = """
            {"api":"fromWidget","action":"send_event","widgetId":"\(widgetId)","requestId":"native-roomkey-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","content":{"keys":[{"index":0,"key":"\(key)"}],"device_id":"\(devId)","call_id":"","sent_ts":\(nowMs)}}}
            """
            let result = await driver.handleMessage(msg)
            MXLog.info("sTalk NativeCall E2EE: room event result=\(result)")
        }

        MXLog.info("sTalk NativeCall E2EE: Key send tasks launched")
    }

    // MARK: - E2EE Key from Room Timeline

    private func listenForEncryptionKeysFromTimeline() {
        guard let roomProxy else {
            MXLog.warning("sTalk NativeCall E2EE: No roomProxy — can't listen to timeline")
            return
        }

        roomProxy.timeline.timelineItemProvider.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, _ in
                guard let self else { return }
                for item in items {
                    guard case .event(let eventItem) = item else { continue }

                    // Check if it's a custom event (encryption_keys)
                    if case .msgLike(let msgContent) = eventItem.content,
                       case .other(let eventType) = msgContent.kind {
                        if case .other(let typeStr) = eventType, typeStr.contains("encryption_keys") {
                            // Parse key from debugInfo originalJSON
                            let debugInfo = eventItem.debugInfo
                            if let json = debugInfo.originalJSON,
                               let data = json.data(using: .utf8),
                               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let content = dict["content"] as? [String: Any],
                               let sender = dict["sender"] as? String,
                               sender != self.userId {

                                let deviceId = content["device_id"] as? String ?? ""
                                let participantId = "\(sender):\(deviceId)"

                                if let keys = content["keys"] as? [[String: Any]] {
                                    for keyObj in keys {
                                        if let key = keyObj["key"] as? String,
                                           let index = keyObj["index"] as? Int,
                                           let rawKey = Data(base64Encoded: key) {
                                            self.setRawKeyInProvider(self.keyProvider, key: rawKey, participantId: participantId, index: Int32(index))
                                            self.participantKeys[participantId] = true
                                            MXLog.info("sTalk NativeCall E2EE: 🔑 KEY FROM TIMELINE! \(participantId) index=\(index)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        MXLog.info("sTalk NativeCall E2EE: Listening to room timeline for encryption_keys")
    }

    private func pollForEncryptionKeys() async {
        // Poll room messages for io.element.call.encryption_keys events
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/messages?dir=b&limit=20&filter={\"types\":[\"io.element.call.encryption_keys\"]}"

        guard let requestURL = URL(string: url) else { return }

        // Poll every 3 seconds for 60 seconds
        for _ in 0..<20 {
            guard sessionState == .connected || sessionState == .waitingForCredentials || sessionState == .connecting else { return }

            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chunk = json["chunk"] as? [[String: Any]] {
                    for event in chunk {
                        guard let content = event["content"] as? [String: Any],
                              let sender = event["sender"] as? String,
                              sender != userId, // Skip our own keys
                              let deviceId = content["device_id"] as? String else { continue }

                        // Extract keys array
                        if let keys = content["keys"] as? [[String: Any]] {
                            for keyObj in keys {
                                if let key = keyObj["key"] as? String,
                                   let index = keyObj["index"] as? Int {
                                    let participantId = "\(sender):\(deviceId)"
                                    MXLog.info("sTalk NativeCall E2EE: Got key from timeline! \(participantId) index=\(index)")
                                    keyProvider.setKey(key: key, participantId: participantId, index: Int32(index))
                                    participantKeys[participantId] = true

                                    if let participant = pendingParticipants.removeValue(forKey: participantId) {
                                        subscribeToAllTracks(of: participant)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                MXLog.error("sTalk NativeCall E2EE: Poll failed: \(error)")
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - Debug

    private func debugReadCallMemberState() async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state"

        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for event in events {
                    let type = event["type"] as? String ?? ""
                    if type.contains("call") {
                        let stateKey = event["state_key"] as? String ?? ""
                        let content = event["content"] as? [String: Any] ?? [:]
                        if let contentData = try? JSONSerialization.data(withJSONObject: content),
                           let contentStr = String(data: contentData, encoding: .utf8) {
                            MXLog.info("sTalk DEBUG: state \(type) key=\(stateKey) content=\(contentStr.prefix(500))")
                        }
                    }
                }
            }
        } catch {
            MXLog.error("sTalk DEBUG: Failed to read state: \(error)")
        }
    }

    // MARK: - Call Notification

    private func sendCallNotification() async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let txnId = UUID().uuidString
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/send/org.matrix.msc4075.rtc.notification/\(txnId)"

        let body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "m.mentions": ["user_ids": [] as [String]],
            "sender_ts": Int(Date().timeIntervalSince1970 * 1000),
            "lifetime": 90000,
            "notification_type": "ring"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            MXLog.info("sTalk NativeCall: Call notification → \(status)")
        } catch {
            MXLog.error("sTalk NativeCall: Call notification failed: \(error)")
        }
    }

    // MARK: - Stop

    func stop() async {
        MXLog.info("sTalk NativeCall: Stopping session")
        sessionState = .disconnecting

        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Leave MatrixRTC via REST API
        await sendLeaveViaREST()

        await liveKitRoomManager.disconnect()
        cancellables.removeAll()
        sessionState = .disconnected
        MXLog.info("sTalk NativeCall: Session stopped")
    }

    private func sendLeaveViaREST() async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        for eventType in ["org.matrix.msc3401.call.member"] {
            let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)"

            // Empty content = leave
            let body: [String: Any] = [:]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { continue }

            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                MXLog.info("sTalk NativeCall: REST leave \(eventType) → \(status)")
            } catch {
                MXLog.error("sTalk NativeCall: REST leave failed: \(error)")
            }
        }
    }

    // MARK: - Message Processing

    private func processWidgetMessage(_ messageString: String) {
        guard let message = WidgetAPIMessage(jsonString: messageString) else {
            MXLog.info("sTalk NativeCall: Unparseable message: \(messageString.prefix(200))")
            return
        }

        // Log all messages
        MXLog.info("sTalk NativeCall: \(message.api) action=\(message.action) type=\(message.eventType ?? "-") reqId=\(message.requestId)")

        // Process toWidget messages
        if message.api == "toWidget" {
            if message.action == "capabilities" {
                // Driver asks "what capabilities do you want?" — respond with Capabilities struct
                Task {
                    let response = """
                    {"api":"fromWidget","action":"capabilities","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","response":{"capabilities":{"read":["org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys","org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member"],"send":["org.matrix.msc3819.send.to_device:io.element.call.encryption_keys","org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member"],"requires_client":true,"update_delayed_event":true,"send_delayed_event":true}}}
                    """
                    await widgetDriver.handleMessage(response)
                    MXLog.info("sTalk NativeCall: Responded to capabilities with struct format")
                }
            } else {
                Task {
                    let ack = """
                    {"api":"fromWidget","action":"\(message.action)","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","response":{}}
                    """
                    await widgetDriver.handleMessage(ack)
                }
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

        // Decode base64 → raw bytes, set via KVC
        if let rawKey = Data(base64Encoded: keyInfo.key) {
            setRawKeyInProvider(keyProvider, key: rawKey, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
        } else {
            keyProvider.setKey(key: keyInfo.key, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
        }
        participantKeys[keyInfo.participantId] = true

        if let participant = pendingParticipants.removeValue(forKey: keyInfo.participantId) {
            subscribeToAllTracks(of: participant)
        }
    }

    private func handleWidgetAction(_ action: ElementCallWidgetDriverAction) {
        switch action {
        case .callEnded:
            // Ignore widget driver hangup — it times out because we don't do delayed_leave.
            // Native SDK manages call lifecycle independently.
            MXLog.info("sTalk NativeCall: Widget driver hangup IGNORED — native SDK manages lifecycle")
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
                // Generate our E2EE key BEFORE connect
                if ourEncryptionKey == nil {
                    // Generate 16 random bytes, BUT encode as ASCII-safe string
                    // so that .utf8 encoding gives predictable bytes
                    var keyBytes = [UInt8](repeating: 0, count: 32)
                    _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
                    // Use hex string as key — .utf8 gives same bytes, and we send hex to remote
                    ourEncryptionKey = keyBytes.map { String(format: "%02x", $0) }.joined()
                    // But EC expects base64... Send base64 to remote, use same decoded bytes locally
                    let rawData = Data(keyBytes.prefix(16))
                    ourEncryptionKey = rawData.base64EncodedString()
                    ourEncryptionKeyRaw = rawData
                }

                // Set raw key bytes via runtime access to rtcKeyProvider
                let ourIdentity = "\(userId):\(deviceId)"
                setRawKeyInProvider(keyProvider, key: ourEncryptionKeyRaw!, participantId: ourIdentity, index: 0)
                MXLog.info("sTalk NativeCall E2EE: Raw key (\(ourEncryptionKeyRaw!.count) bytes) set for \(ourIdentity)")

                // Connect WITH E2EE
                try await liveKitRoomManager.connectWithE2EE(
                    wsURL: url, token: token, keyProvider: keyProvider, speakerByDefault: false
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
