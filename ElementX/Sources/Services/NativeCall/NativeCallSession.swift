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
import Network
import os.log
import SwiftUI

private let callLog = OSLog(subsystem: "ru.implica.stalk", category: "Call")

@MainActor
final class NativeCallSession: ObservableObject {
    // MARK: - Published State

    @Published private(set) var sessionState: NativeCallSessionState = .starting
    @Published private(set) var roomManager: LiveKitRoomManager?

    // MARK: - Dependencies

    private let widgetDriver: ElementCallWidgetDriverProtocol
    private let liveKitRoomManager: LiveKitRoomManager
    /// Match EC JS parameters: ratchetWindowSize: 10, keyringSize: 256, HKDF derivation
    private let keyProvider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: false,
                                                                          ratchetWindowSize: 10,
                                                                          keyRingSize: 256,
                                                                          useHKDF: true // CRITICAL: JS uses HKDF, native default is PBKDF2
        ))
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
    private var hasSeenRemoteParticipant = false

    // MARK: - Hand Raise (STMOB-154)

    /// event_id своего org.matrix.msc3401.call.member state event. Используется как
    /// `m.relates_to.event_id` в m.reaction events для hand raise (Element Call widget
    /// в Web фильтрует reactions по этому ID для определения чьё это hand raise).
    private(set) var callMemberEventID: String?
    /// event_id текущего активного m.reaction hand raise. Сохраняется чтобы при опускании
    /// руки можно было его redact'нуть. nil если рука сейчас опущена.
    private var handReactionEventID: String?
    /// STMOB-96: tracks remote participant identities seen so far. When a new
    /// identity appears (reconnect → новый pID, или newcomer), мы триггерим
    /// rebroadcast текущего encryption key — иначе он не сможет расшифровать
    /// audio после того как ratchet ушёл вперёд изначально розданного ключа.
    private var knownRemoteIdentities: Set<String> = []
    /// STMOB-96 v2 / STMOB-101 v3: foreground observer to rebroadcast same key
    /// when app возвращается в foreground (на случай если новые participant'ы
    /// подключились пока iOS suspended app).
    private var foregroundObserver: NSObjectProtocol?
    private var livekitBaseURL: String?

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var heartbeatTask: Task<Void, Never>?

    // Network change monitoring — triggers E2EE key resend on wifi/cellular/none transitions.
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkInterface = ""

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
        os_log(.info, log: callLog, "Starting session encrypted=%{public}@ user=%{public}@", "\(isEncrypted)", userId)
        sessionState = .starting
        setupNetworkMonitor()

        // Start WidgetDriver in background for E2EE key exchange only
        // WidgetDriver uses different state_key format, won't conflict with our REST join
        let driverResult = await widgetDriver.start(baseURL: baseURL,
                                                    clientID: clientID,
                                                    colorScheme: colorScheme,
                                                    rageshakeURL: nil,
                                                    analyticsConfiguration: nil)
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

            // Wait for capabilities negotiation to complete (async)
            try? await Task.sleep(for: .seconds(5))

            // Step 3: io.element.join — trigger MatrixRTC
            let joinCall = """
            {"api":"fromWidget","action":"io.element.join","widgetId":"\(widgetDriver.widgetID)","requestId":"native-join-\(UUID().uuidString)","data":{}}
            """
            await widgetDriver.handleMessage(joinCall)
            MXLog.info("sTalk NativeCall: WidgetDriver — io.element.join sent")
        }

        // E2EE key exchange
        if isEncrypted {
            // Listen to room timeline for incoming encryption keys.
            // IMPORTANT: timeline.subscribeForUpdates must complete before we access
            // timelineItemProvider (force-unwraps innerTimelineItemProvider otherwise).
            // At VoIP cold-start the timeline isn't yet subscribed — без await => CRASH.
            Task { [weak self] in
                await self?.listenForEncryptionKeysFromTimeline()
            }

            // STMOB-101 v3: упростили rebroadcast стратегию.
            //
            // v1 (build 99/100): for-loop 12×10s regenerate + while-loop 30s
            //   rebroadcast. Каждый sendOurEncryptionKey() RE-GENERATES random
            //   key → rotate KID в SFrame у Element Call widget.
            // v2 (build 101): same loop + DiagLog + foreground observer.
            //
            // Регрессия: ВСЕ участники ratchet'ат KID на каждом нашем
            // m.room.encrypted event. Egress / Key Server / KS-Bridge
            // не успевают синхронизироваться, cipher auth fail на 99%
            // последующих frames (Molly STMOB-101: tymbay 99.7% fail в
            // recording, ms.implica decrypted OK case-by-case).
            //
            // v3 — близко к Element Call upstream + минимально необходимый
            // расход на iOS-specific scenarios:
            //
            //   - Initial: sendOurEncryptionKey ОДИН РАЗ (3s после start).
            //     Generate + setKey + broadcast — это база.
            //   - НЕ ratchet'ить KID каждые N секунд. Никакого таймера.
            //   - On member JOIN (новый remote identity в $remoteParticipants):
            //     rebroadcastCurrentEncryptionKey — ТОТ ЖЕ key, no rotation,
            //     чтобы newcomer/reconnect мог расшифровать. Это hook ниже.
            //   - On member LEAVE (identity исчезла из $remoteParticipants):
            //     sendOurEncryptionKey — RE-generate (security — leaving peer
            //     не должен decrypt'ить future frames). Hook ниже.
            //   - On foreground entry: rebroadcastCurrentEncryptionKey — same
            //     key. Покрывает случай когда iOS-side стейт мог отстать от
            //     room state пока app был в background.
            //
            // С таким набором rotations происходят только при реальных
            // membership events — egress / KS-Bridge успевают догнать.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let s = self, s.sessionState != .disconnected else {
                    DiagLog.write("E2EE", "initial sendOurEncryptionKey EXIT — self=nil or disconnected")
                    return
                }
                DiagLog.write("E2EE", "initial sendOurEncryptionKey")
                await s.sendOurEncryptionKey()
            }

            // STMOB-101 v3: foreground entry — rebroadcast same key (no rotation).
            // Iff stay long in background и iOS suspended app — на возврат
            // дёргаем rebroadcast чтобы новые participant'ы которые подключились
            // пока we were sleeping получили текущий ключ (тот же KID).
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                        object: nil,
                                                                        queue: .main) { [weak self] _ in
                guard let self, self.sessionState != .disconnected else { return }
                DiagLog.write("E2EE", "foreground entry — rebroadcast same key")
                Task { [weak self] in
                    await self?.rebroadcastCurrentEncryptionKey()
                }
            }
        }

        // Observe LiveKit disconnect → auto-end call
        liveKitRoomManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .disconnected, self.sessionState == .connected {
                    MXLog.info("sTalk NativeCall: LiveKit disconnected while connected — ending session")
                    self.sessionState = .disconnected
                }
            }
            .store(in: &cancellables)

        // Observe remote participants leaving (auto-end when last one leaves).
        // STMOB-101 v3: detect JOIN (newcomer/reconnect) и LEAVE (security
        // rotation). Реакция:
        //   - JOIN: rebroadcastCurrentEncryptionKey — same KID, иначе newcomer
        //     не сможет decrypt'ить audio.
        //   - LEAVE: sendOurEncryptionKey — regenerate KID (security: leaving
        //     peer не должен decrypt'ить future frames). Это standard E2EE
        //     behavior для media rotation.
        // Никакого периодического timer — только on-event triggers.
        liveKitRoomManager.$remoteParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self, self.sessionState == .connected else { return }
                if !participants.isEmpty {
                    self.hasSeenRemoteParticipant = true

                    let currentIdentities = Set(participants.map { $0.identity?.stringValue ?? "" })
                    let newIdentities = currentIdentities.subtracting(self.knownRemoteIdentities)
                    let leftIdentities = self.knownRemoteIdentities.subtracting(currentIdentities)

                    if !leftIdentities.isEmpty {
                        // STMOB-101: security rotation на leave. Не должны
                        // оставлять прошлого peer'а с возможностью decrypt'ить
                        // future audio (он уже не в room, но может прослушивать
                        // SFU stream если cached его old subscription).
                        MXLog.info("sTalk NativeCall E2EE: remote left \(leftIdentities) — regenerating key")
                        DiagLog.write("E2EE", "remote LEAVE \(leftIdentities) → regenerate key")
                        Task { [weak self] in
                            await self?.sendOurEncryptionKey()
                        }
                    } else if !newIdentities.isEmpty {
                        MXLog.info("sTalk NativeCall E2EE: new remote participant(s) — \(newIdentities) — rebroadcasting same key")
                        DiagLog.write("E2EE", "remote JOIN \(newIdentities) → rebroadcast same key")
                        Task { [weak self] in
                            await self?.rebroadcastCurrentEncryptionKey()
                        }
                    }
                    self.knownRemoteIdentities = currentIdentities
                } else if self.hasSeenRemoteParticipant {
                    MXLog.info("sTalk NativeCall: All remote participants left after being connected — ending session")
                    Task { await self.stop() }
                }
            }
            .store(in: &cancellables)

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
        let joinEventID = await sendJoinViaREST()
        // STMOB-154 build 178: сохраняем для использования в m.reaction events
        // (hand raise iOS → Web bridge). Web Element Call widget читает m.reaction
        // с m.relates_to.event_id равным call.member event_id для отображения hand raise.
        callMemberEventID = joinEventID

        // Send call notification for incoming call ring on remote
        await sendCallNotification(callMemberEventID: joinEventID)

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

    /// Send MatrixRTC join via REST API. Returns the event_id of the call.member state event.
    @discardableResult
    private func sendJoinViaREST() async -> String? {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        // State key format: _@user:server_deviceId_m.call
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        let eventType = "org.matrix.msc3401.call.member"
        let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)"

        // Flat format matching Element Call web client
        let body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "scope": "m.room",
            "device_id": deviceId,
            "expires": 7_200_000,
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

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            MXLog.info("sTalk NativeCall: REST join \(eventType) → \(status) url=\(url) body=\(respBody.prefix(200))")

            // Extract event_id from response: {"event_id": "$xxx"}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let eventID = json["event_id"] as? String {
                return eventID
            }
        } catch {
            MXLog.error("sTalk NativeCall: REST join failed: \(error)")
        }
        return nil
    }

    // MARK: - Hand Raise Matrix Reaction (STMOB-154)

    /// Send или redact Matrix `m.reaction` event для hand raise.
    /// Web Element Call widget слушает только Matrix m.reaction, не LiveKit metadata —
    /// без этого Web участники не видят руку iOS host. Параллельный путь к
    /// `LiveKitRoomManager.setHandRaise` (LiveKit metadata, для iOS↔iOS и iOS↔guest).
    func sendHandRaiseReaction(raised: Bool) async {
        guard let callMemberEventID, !callMemberEventID.isEmpty else {
            DiagLog.write("Call", "sendHandRaiseReaction ABORT — нет callMemberEventID (call не joined через REST?)")
            return
        }
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId

        if raised {
            // PUT /rooms/{room}/send/m.reaction/{txn}
            let body: [String: Any] = [
                "m.relates_to": [
                    "rel_type": "m.annotation",
                    "event_id": callMemberEventID,
                    "key": "🖐️"
                ]
            ]
            let txn = "hand-raise-\(UUID().uuidString)"
            let encodedTxn = txn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? txn
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/send/m.reaction/\(encodedTxn)"
            if let eventID = await sendMatrixEvent(url: url, body: body, method: "PUT") {
                handReactionEventID = eventID
                DiagLog.write("Call", "hand raise m.reaction SENT eventID=\(eventID) relates_to=\(callMemberEventID)")
            } else {
                DiagLog.write("Call", "hand raise m.reaction SEND FAILED relates_to=\(callMemberEventID)")
            }
        } else {
            guard let prevEventID = handReactionEventID, !prevEventID.isEmpty else {
                DiagLog.write("Call", "hand raise redact SKIP — нет handReactionEventID (рука уже опущена)")
                return
            }
            // PUT /rooms/{room}/redact/{eventID}/{txn}
            let encodedEventID = prevEventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prevEventID
            let txn = "hand-redact-\(UUID().uuidString)"
            let encodedTxn = txn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? txn
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/redact/\(encodedEventID)/\(encodedTxn)"
            if let eventID = await sendMatrixEvent(url: url, body: [:], method: "PUT") {
                DiagLog.write("Call", "hand raise REDACTED \(prevEventID) → \(eventID)")
            } else {
                DiagLog.write("Call", "hand raise REDACT FAILED for \(prevEventID)")
            }
            handReactionEventID = nil
        }
    }

    /// Generic helper: PUT/POST Matrix event с access token, parse event_id из response.
    private func sendMatrixEvent(url: String, body: [String: Any], method: String) async -> String? {
        guard let urlObj = URL(string: url) else { return nil }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200, status < 300,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let eventID = json["event_id"] as? String {
                return eventID
            } else {
                let respBody = String(data: data, encoding: .utf8) ?? ""
                MXLog.error("sTalk NativeCall: sendMatrixEvent \(method) \(url) → \(status) body=\(respBody.prefix(200))")
                return nil
            }
        } catch {
            MXLog.error("sTalk NativeCall: sendMatrixEvent failed: \(error)")
            return nil
        }
    }

    // MARK: - Raw Key Provider Access

    /// Set raw bytes key in BaseKeyProvider, bypassing UTF-8 string conversion
    /// BaseKeyProvider.rtcKeyProvider is internal, so we use KVC to access it
    /// Set key using the same raw bytes that EC JS uses
    /// Converts raw Data to a String where each byte maps 1:1 (ISO Latin-1)
    /// LiveKit SDK will .utf8 encode this — for ASCII-range bytes it's identical
    private func setRawKeyInProvider(_ provider: BaseKeyProvider, key: Data, participantId: String, index: Int32) {
        // webrtc 144 with useHKDF:true does HKDF internally — pass RAW bytes only
        provider.setRawKey(key, participantId: participantId, index: index)
        MXLog.info("sTalk E2EE: Raw key (\(key.count) bytes) for \(participantId) idx=\(index)")
    }

    // MARK: - E2EE Key Exchange

    private var ourEncryptionKey: String? // base64
    private var ourEncryptionKeyRaw: Data? // raw 16 bytes

    private func sendOurEncryptionKey() async {
        // Generate random 16-byte key (base64). Matches build-34 behavior: regenerate per call,
        // use setKey(string) — changing either broke web decryption (build 35 regression).
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let rawData = Data(keyBytes)
        let key = rawData.base64EncodedString()
        ourEncryptionKey = key
        ourEncryptionKeyRaw = rawData // keep in sync so connectToLiveKit has raw bytes

        // Set our own key in keyProvider
        let ourIdentity = "\(userId):\(deviceId)"
        keyProvider.setKey(key: key, participantId: ourIdentity, index: 0)
        MXLog.info("sTalk NativeCall E2EE: Generated our key, identity=\(ourIdentity)")
        os_log(.info, log: callLog, "E2EE key generated identity=%{public}@", ourIdentity)

        let widgetId = widgetDriver.widgetID
        let roomId = matrixRoomId
        let devId = deviceId
        let driver = widgetDriver
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        // Send via Widget API send_to_device — with retry on transient failures.
        let toDeviceMsg = """
        {"api":"fromWidget","action":"send_to_device","widgetId":"\(widgetId)","requestId":"native-key-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","encrypted":true,"messages":{"*":{"*":{"keys":{"index":0,"key":"\(key)"},"room_id":"\(roomId)","member":{"claimed_device_id":"\(devId)"},"session":{"call_id":"","application":"m.call","scope":"m.room"},"sent_ts":\(nowMs)}}}}}
        """
        Task.detached {
            await Self.sendWidgetMessageWithRetry(label: "send_to_device", message: toDeviceMsg, driver: driver)
        }

        // Send as room event — with retry.
        let roomEventMsg = """
        {"api":"fromWidget","action":"send_event","widgetId":"\(widgetId)","requestId":"native-roomkey-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","content":{"keys":[{"index":0,"key":"\(key)"}],"device_id":"\(devId)","call_id":"","sent_ts":\(nowMs)}}}
        """
        Task.detached {
            await Self.sendWidgetMessageWithRetry(label: "send_event", message: roomEventMsg, driver: driver)
        }

        // Publish key to key-server so recording-api can decrypt
        Task.detached { [weak self] in
            await self?.publishKeyToKeyServer(key: key)
        }

        MXLog.info("sTalk NativeCall E2EE: Key send tasks launched (with retry)")
    }

    /// STMOB-96: Re-broadcast current encryption key WITHOUT regenerating it.
    /// Используется в continuous loop после первых 2 минут жизни звонка чтобы
    /// reconnect'нувшийся web-участник (новый pID) или late newcomer мог
    /// получить актуальный ключ. Не трогает keyProvider (ключ уже выставлен)
    /// и не публикует на key-server заново — только три рассылочных канала.
    private func rebroadcastCurrentEncryptionKey() async {
        guard let key = ourEncryptionKey, !key.isEmpty else {
            MXLog.warning("sTalk NativeCall E2EE: rebroadcast skipped — no current key")
            DiagLog.write("E2EE", "rebroadcast SKIPPED — no current key (state=\(sessionState))")
            return
        }
        DiagLog.write("E2EE", "rebroadcast START key=\(key.prefix(8))… (state=\(sessionState))")

        let widgetId = widgetDriver.widgetID
        let roomId = matrixRoomId
        let devId = deviceId
        let driver = widgetDriver
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        MXLog.info("sTalk NativeCall E2EE: rebroadcast current key (no rotation)")
        os_log(.info, log: callLog, "E2EE rebroadcast current key")

        let toDeviceMsg = """
        {"api":"fromWidget","action":"send_to_device","widgetId":"\(widgetId)","requestId":"native-key-rb-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","encrypted":true,"messages":{"*":{"*":{"keys":{"index":0,"key":"\(key)"},"room_id":"\(roomId)","member":{"claimed_device_id":"\(devId)"},"session":{"call_id":"","application":"m.call","scope":"m.room"},"sent_ts":\(nowMs)}}}}}
        """
        Task.detached {
            await Self.sendWidgetMessageWithRetry(label: "send_to_device(rb)", message: toDeviceMsg, driver: driver)
        }

        let roomEventMsg = """
        {"api":"fromWidget","action":"send_event","widgetId":"\(widgetId)","requestId":"native-roomkey-rb-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","content":{"keys":[{"index":0,"key":"\(key)"}],"device_id":"\(devId)","call_id":"","sent_ts":\(nowMs)}}}
        """
        Task.detached {
            await Self.sendWidgetMessageWithRetry(label: "send_event(rb)", message: roomEventMsg, driver: driver)
        }

        // STMOB-101 v2: re-publish в KS на каждом rebroadcast — резерв против
        // KS pod restart / cache eviction. Идемпотентно (тот же ключ).
        Task.detached { [weak self] in
            await self?.publishKeyToKeyServer(key: key, label: "rebroadcast")
        }
    }

    /// Send widget driver message with exponential backoff retry and explicit result parsing.
    /// Backoff: 1s → 2s → 4s (3 attempts, ~7s total). Exits early on success.
    private static func sendWidgetMessageWithRetry(label: String,
                                                   message: String,
                                                   driver: ElementCallWidgetDriverProtocol) async {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            let result = await driver.handleMessage(message)
            switch result {
            case .success(true):
                os_log(.info, log: callLog, "%{public}@ OK attempt=%d", label, attempt)
                return
            case .success(false):
                os_log(.error, log: callLog, "%{public}@ returned false attempt=%d — retrying", label, attempt)
            case .failure(let err):
                os_log(.error, log: callLog, "%{public}@ FAIL attempt=%d: %{public}@", label, attempt, "\(err)")
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        os_log(.error, log: callLog, "%{public}@ FAILED after 3 attempts — key not delivered", label)
    }

    // MARK: - Network monitoring (iOS)

    /// Start monitoring wifi/cellular/none transitions. On change we re-send E2EE keys
    /// because a dropped long-poll can cause peers to miss previously sent to_device events.
    private func setupNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                await self.handleNetworkPathChange(path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handleNetworkPathChange(_ path: NWPath) async {
        let iface: String
        if path.status != .satisfied {
            iface = "none"
        } else if path.usesInterfaceType(.wifi) {
            iface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            iface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            iface = "ethernet"
        } else {
            iface = "other"
        }

        guard iface != lastNetworkInterface else { return }
        let previous = lastNetworkInterface
        lastNetworkInterface = iface

        os_log(.info, log: callLog, "Network change %{public}@ → %{public}@ (encrypted=%{public}@)",
               previous.isEmpty ? "initial" : previous, iface, "\(isEncrypted)")

        // Skip the very first path update (no prior state).
        guard !previous.isEmpty else { return }

        // Re-send E2EE key — to_device events may have been lost during the
        // long-poll gap. Build 41/42 did full reconnect here and created cascading loops;
        // build 44 trials .quickReconnect (ICE restart on live transports, no teardown).
        if isEncrypted, ourEncryptionKey != nil {
            os_log(.info, log: callLog, "Resending E2EE key after network change")
            await sendOurEncryptionKey()
        }

        if Self.kEnableQuickReconnectOnNetworkChange {
            await liveKitRoomManager.attemptQuickReconnect(trigger: "network:\(previous)→\(iface)")
        }
    }

    /// Build 44 experiment — toggle to fall back to previous build 43 behaviour.
    private static let kEnableQuickReconnectOnNetworkChange = true

    #if targetEnvironment(simulator)
    /// DEBUG: симулирует смену сети (wifi → cellular) без Mac WiFi toggle.
    /// Вызывается автоматически через 20s после connect в simulator-сборке.
    func debugSimulateNetworkChange() async {
        os_log(.info, log: callLog, "DEBUG: simulating network change wifi → cellular (for Quick reconnect test)")
        let previous = lastNetworkInterface
        lastNetworkInterface = "cellular"
        if isEncrypted, ourEncryptionKey != nil {
            os_log(.info, log: callLog, "Resending E2EE key after network change")
            await sendOurEncryptionKey()
        }
        if Self.kEnableQuickReconnectOnNetworkChange {
            await liveKitRoomManager.attemptQuickReconnect(trigger: "debug:\(previous)→cellular")
        }
    }
    #endif

    /// STMOB-101 v2: Publish our E2EE key to key-server so recording-api egress
    /// может расшифровывать наши audio/video frames. Молли подтвердила (2026-05-04)
    /// что её server-side KS-Bridge подход не работает — encryption_keys идут
    /// через olm-encrypted to_device (msc3819), Synapse не может прочитать
    /// содержимое. Решение возможно ТОЛЬКО на iOS.
    ///
    /// Format (per Molly):
    /// POST https://stalk.implica.ru/api/keys/pp/{lkRoom}/{userId:deviceId}
    ///   X-Service-Key: key-server-service-secret-2026   (fallback, всегда работает)
    ///   Authorization: Bearer <Matrix access token>     (предпочтительно)
    /// Body: {"key": "<base64url-no-padding>", "keyIndex": <int>}
    private func publishKeyToKeyServer(key: String, label: String = "init") async {
        guard let roomName = generateLiveKitRoomName() else {
            DiagLog.write("E2EE", "KS publish[\(label)] SKIP — no lkRoomName")
            return
        }
        let identity = "\(userId):\(deviceId)"

        // Build 110: STRICT RFC 3986 unreserved encoding (per Molly).
        // urlPathAllowed разрешает `/` `@` `:` — это ломает routing когда lkRoom
        // содержит `/` или identity содержит `@dp.bondar:stalk:device_id`.
        // Encode всё кроме alphanumerics и `-._~`.
        var pathSegmentAllowed = CharacterSet.alphanumerics
        pathSegmentAllowed.insert(charactersIn: "-._~")
        let encodedRoom = roomName.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? roomName
        let encodedIdentity = identity.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? identity

        let keyServerURL = "https://stalk.implica.ru/api/keys/pp/\(encodedRoom)/\(encodedIdentity)"
        guard let url = URL(string: keyServerURL) else { return }

        // base64 → base64url-no-padding (per Molly's spec)
        let keyBase64URL = key
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let body: [String: Any] = ["key": keyBase64URL, "keyIndex": 0]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Build 110: правильный SERVICE_SECRET — `svc` (build 108 был `service`, который default но не prod env).
        request.setValue("key-server-svc-secret-2026", forHTTPHeaderField: "X-Service-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200, status < 300 {
                DiagLog.write("E2EE", "KS publish[\(label)] OK \(status) room=\(roomName) identity=\(identity)")
                MXLog.info("sTalk NativeCall E2EE: KS publish[\(label)] → \(status)")
            } else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "?"
                DiagLog.write("E2EE", "KS publish[\(label)] FAIL \(status) body=\(bodyStr.prefix(200))")
                MXLog.error("sTalk NativeCall E2EE: KS publish[\(label)] HTTP \(status) body=\(bodyStr)")
            }
        } catch {
            DiagLog.write("E2EE", "KS publish[\(label)] ERR \(error)")
            MXLog.error("sTalk NativeCall E2EE: Key publish to key-server failed: \(error)")
        }
    }

    // MARK: - E2EE Key from Room Timeline

    private func listenForEncryptionKeysFromTimeline() async {
        guard let roomProxy else {
            MXLog.warning("sTalk NativeCall E2EE: No roomProxy — can't listen to timeline")
            return
        }

        // Ensure timelineItemProvider готов — на VoIP cold-start его ещё нет,
        // и force-unwrap в getter крашит app. subscribeForUpdates идемпотентен.
        await roomProxy.timeline.subscribeForUpdates()

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

    /// Send ring notification with proper user_ids and m.relates_to referencing our call.member event.
    /// Web client requires m.relates_to.rel_type="m.reference" + event_id of call.member to show incoming call toast.
    private func sendCallNotification(callMemberEventID: String?) async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId

        // Collect other room members for m.mentions.user_ids
        var otherUserIDs: [String] = []
        if let members = await roomProxy?.members() {
            otherUserIDs = members
                .filter { $0.isActive && $0.userID != userId }
                .map(\.userID)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)

        // Build notification body
        var body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "m.mentions": ["user_ids": otherUserIDs],
            "sender_ts": timestamp,
            "lifetime": 90000,
            "notification_type": "ring"
        ]

        // Add m.relates_to if we have the call.member event_id
        if let eventID = callMemberEventID {
            body["m.relates_to"] = [
                "rel_type": "m.reference",
                "event_id": eventID
            ]
        }

        // Send via REST API
        let txnId = UUID().uuidString
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/send/org.matrix.msc4075.rtc.notification/\(txnId)"

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            MXLog.info("sTalk NativeCall: Ring notification → \(status) users=\(otherUserIDs.count) ref=\(callMemberEventID ?? "none") resp=\(respBody.prefix(100))")
        } catch {
            MXLog.error("sTalk NativeCall: Ring notification failed: \(error)")
        }
    }

    // MARK: - Stop

    func stop() async {
        MXLog.info("sTalk NativeCall: Stopping session")
        sessionState = .disconnecting

        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopNetworkMonitor()

        // STMOB-101 v3: remove foreground observer (rebroadcast loop удалён)
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }

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
                // Driver sent toWidget capabilities request.
                // Response must be toWidget (not fromWidget!) — driver expects toWidget response.
                Task {
                    let response = """
                    {"api":"toWidget","action":"capabilities","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","data":{},"response":{"capabilities":["org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys","org.matrix.msc3819.send.to_device:io.element.call.encryption_keys","org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member","org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member","org.matrix.msc2762.send.delayed_event","org.matrix.msc2762.update.delayed_event","io.element.requires_client"]}}
                    """
                    MXLog.info("sTalk NativeCall: Sending toWidget response: \(String(response.prefix(200)))")
                    let result = await widgetDriver.handleMessage(response)
                    MXLog.info("sTalk NativeCall: toWidget response result=\(result)")
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
            MXLog.info("sTalk NativeCall E2EE RAW: \(messageString.prefix(500))")
            // STMOB-152 build 176: DiagLog для incoming E2EE keys.
            // Помогает Molly верифицировать что её server-side fan-out
            // (STALK-303) достигает iOS — каждый received key event
            // от guest должен появляться здесь.
            DiagLog.write("E2EE", "incoming widget message api=\(message.api) action=\(message.action) raw=\(messageString.prefix(300))")
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
        guard let keyInfo = message.extractEncryptionKeys(), !keyInfo.participantId.isEmpty else {
            // STMOB-152 build 176: incoming event пришёл но extract failed —
            // вероятно payload format mismatch (array vs object keys field).
            DiagLog.write("E2EE", "handleEncryptionKeys EXTRACT FAILED action=\(message.action)")
            return
        }

        MXLog.info("sTalk NativeCall: E2EE key from \(keyInfo.participantId) index=\(keyInfo.index)")
        // STMOB-152 build 176: каждый успешно parsed incoming key —
        // подтверждение что Molly fan-out (STALK-303) работает.
        DiagLog.write("E2EE", "incoming key parsed from=\(keyInfo.participantId) index=\(keyInfo.index) keyLen=\(keyInfo.key.count)")

        // STMOB-152 build 177: normalize base64url → standard padded base64.
        // Guest meet-app использует Node `crypto.randomBytes(16).toString("base64url")`
        // (meet-api-index.js:348) — это URL-safe base64 БЕЗ padding (RFC 4648 §5).
        // 16 bytes → 22 chars, '-' вместо '+', '_' вместо '/'.
        //
        // Swift Data(base64Encoded:) strict — требует standard alphabet +
        // правильное padding. Без normalization returns nil → silent fallback
        // на else branch → keyProvider.setKey с base64 STRING вместо raw bytes
        // → LiveKit SFrame decrypt fails → черный экран для guest video.
        //
        // Лог 85 dp.bondar (01:28): guest key "IV9NRa02nGPGQwxjMlAnkA" (22 chars)
        // vs iOS local "gKcCiyjfzfuOCZN76ObkVg==" (24 chars). Random key мог бы
        // содержать '-' / '_' → ещё один уровень failure.
        let paddedKey: String = {
            // base64url → standard base64
            var normalized = keyInfo.key
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            // padding до multiple of 4
            let mod = normalized.count % 4
            if mod != 0 {
                normalized += String(repeating: "=", count: 4 - mod)
            }
            return normalized
        }()

        // Decode base64 → raw bytes
        if let rawKey = Data(base64Encoded: paddedKey) {
            // Set key for the given index AND all previous indexes (in case we missed earlier keys)
            for idx in 0...Int32(keyInfo.index) {
                setRawKeyInProvider(keyProvider, key: rawKey, participantId: keyInfo.participantId, index: idx)
            }
            DiagLog.write("E2EE", "incoming key DECODED rawBytes=\(rawKey.count) for \(keyInfo.participantId)")
        } else {
            DiagLog.write("E2EE", "incoming key BASE64 DECODE FAILED (even padded keyLen=\(paddedKey.count)) for \(keyInfo.participantId)")
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

                // Race condition safety: sendOurEncryptionKey (fires 3s after start) can set
                // ourEncryptionKey without touching ourEncryptionKeyRaw. Derive raw from base64
                // to keep both in sync before force-unwrapping.
                if ourEncryptionKeyRaw == nil, let key = ourEncryptionKey {
                    ourEncryptionKeyRaw = Data(base64Encoded: key)
                }
                guard let rawKey = ourEncryptionKeyRaw else {
                    MXLog.error("sTalk NativeCall: Cannot resolve raw E2EE key — aborting connect")
                    sessionState = .failed(NativeCallError.noCredentials)
                    return
                }

                let ourIdentity = "\(userId):\(deviceId)"
                setRawKeyInProvider(keyProvider, key: rawKey, participantId: ourIdentity, index: 0)
                MXLog.info("sTalk NativeCall E2EE: Our key set for \(ourIdentity)")

                try await liveKitRoomManager.connectWithE2EE(wsURL: url, token: token, keyProvider: keyProvider, speakerByDefault: false)
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

            #if targetEnvironment(simulator)
            // DEBUG: через 20s после connect триггерим fake network switch
            // чтобы тестировать Quick reconnect на симуляторе без Mac WiFi toggle.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.debugSimulateNetworkChange()
            }
            #endif

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

        // Resend our encryption key when remote joins — they may have missed initial key
        if isEncrypted, ourEncryptionKey != nil {
            Task { await sendOurEncryptionKey() }
            MXLog.info("sTalk NativeCall: Resent our E2EE key for new participant \(identity)")
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
        // sTalk: STMOB-89 — set explicit `identity` claim alongside `sub`. Earlier
        // LiveKit servers fell back to `sub`, but newer livekit-server-sdk reads
        // the top-level `identity` claim for participant identity. If only `sub`
        // is set the server may assign a fallback identity → mismatch with
        // `/api/keys/pp/<room>/<userId:deviceId>` upload. Set both to the same
        // string so JWT identity and key-publish identity are guaranteed equal.
        let payload: [String: Any] = [
            "iss": livekitAPIKey,
            "sub": identity,
            "identity": identity,
            "name": userId,
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
