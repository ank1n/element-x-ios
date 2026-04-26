//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import CallKit
import Combine
import Foundation
import MatrixRustSDK
import os.log
import PushKit
import UIKit

private let pushLog = OSLog(subsystem: "ru.implica.stalk", category: "VoIPPush")

/// Keep this class testable
struct TimeProvider {
    var clock: any Clock<Duration>
    var now: () -> Date
}

class ElementCallService: NSObject, ElementCallServiceProtocol, PKPushRegistryDelegate, CXProviderDelegate {
    private struct CallID: Equatable {
        let callKitID: UUID
        let roomID: String
        let rtcNotificationID: String?
    }

    private let pushRegistry: PKPushRegistry
    private let callController = CXCallController()
    private let callProvider: CXProviderProtocol
    private let timeProvider: TimeProvider

    /// Stored VoIP push token (received from PushKit before clientProxy may be available)
    private var voipDeviceToken: Data?

    private weak var clientProxy: ClientProxyProtocol? {
        didSet {
            // There's a race condition where a call starts when the app has been killed and the
            // observation set in `incomingCallID` occurs *before* the user session is restored.
            // So observe when the client proxy is set to fix this (the method guards for the call).
            Task { await observeIncomingCall() }
        }
    }
    
    private var incomingCallRoomInfoCancellable: AnyCancellable?
    private var incomingCallID: CallID? {
        didSet {
            Task { await observeIncomingCall() }
        }
    }
    
    private var endUnansweredCallTask: Task<Void, Never>?
    
    private var ongoingCallID: CallID? {
        didSet { ongoingCallRoomIDSubject.send(ongoingCallID?.roomID) }
    }
    
    let ongoingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)
    var ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> {
        ongoingCallRoomIDSubject.asCurrentValuePublisher()
    }
    
    private let actionsSubject: PassthroughSubject<ElementCallServiceAction, Never> = .init()
    var actions: AnyPublisher<ElementCallServiceAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var declineListenerHandle: TaskHandle?
    
    init(callProvider: CXProviderProtocol? = nil, timeProvider: TimeProvider? = nil) {
        pushRegistry = PKPushRegistry(queue: nil)
        
        self.timeProvider = timeProvider ?? TimeProvider(clock: ContinuousClock(), now: Date.init)
        
        if let callProvider {
            self.callProvider = callProvider
        } else {
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = true
            configuration.includesCallsInRecents = true
            
            if let callKitIcon = UIImage(named: "images/app-logo") {
                configuration.iconTemplateImageData = callKitIcon.pngData()
            }
            
            // https://stackoverflow.com/a/46077628/730924
            configuration.supportedHandleTypes = [.generic]
            
            self.callProvider = CXProvider(configuration: configuration)
        }
        
        super.init()
        
        // PushKit нужен для CXProvider.reportNewIncomingVoIPPushPayload из NSE.
        // VoIP пушер НЕ регистрируем в Synapse (voip pushkin удалён из Sygnal).
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]

        self.callProvider.setDelegate(self, queue: nil)
    }
    
    /// Флаг для пометки следующего звонка как входящего (когда VoIP push недоступен)
    private var nextCallIsIncoming = false

    /// Флаг регистрации VoIP pusher в Matrix (Sygnal → APNs VoIP push → PushKit → CallKit full-screen UI).
    /// ВАЖНО: перед включением убедиться что Sygnal на Misty правильно фильтрует события —
    /// VoIP push ДОЛЖЕН приходить ТОЛЬКО на incoming call events (`m.call.notify` / `m.call.member`).
    /// Иначе iOS убьёт sTalk + revoke VoIP token при первом же text message, звонки сломаются полностью.
    /// Зависимости: STALK-185 (Sygnal VoIP pusher + push rules), Apple VoIP Services Certificate.
    private static let kEnableVoIPPusherRegistration = true

    func setClientProxy(_ clientProxy: any ClientProxyProtocol) {
        self.clientProxy = clientProxy
        if Self.kEnableVoIPPusherRegistration, let token = voipDeviceToken {
            Task { await registerVoIPPusher(with: token) }
        }
    }

    func markNextCallAsIncoming() {
        nextCallIsIncoming = true
        // Также отправляем событие для CallHistoryCoordinator
        actionsSubject.send(.receivedIncomingCallRequest)
        MXLog.info("Marked next call as incoming")
    }

    func setupCallSession(roomID: String, roomDisplayName: String) async {
        // Drop any ongoing calls when starting a new one
        if ongoingCallID != nil {
            tearDownCallSession()
        }

        // Check if this is an outgoing call (not from incoming ring or explicit marking)
        let isOutgoingCall = !nextCallIsIncoming && (incomingCallID == nil || incomingCallID?.roomID != roomID)
        nextCallIsIncoming = false

        // If this starting from a ring reuse those identifiers
        // Make sure the roomID matches
        let callID = if let incomingCallID, incomingCallID.roomID == roomID {
            incomingCallID
        } else {
            CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil)
        }

        incomingCallID = nil
        ongoingCallID = callID

        // Always send startCall action for call history tracking
        // Direction is determined by pendingIncomingCall flag in CallHistoryCoordinator
        actionsSubject.send(.startCall(roomID: roomID))
        
        // Don't bother starting another CallKit session as it won't work properly
        // https://developer.apple.com/forums//thread/767949?answerId=812951022#812951022
        
        // let handle = CXHandle(type: .generic, value: roomDisplayName)
        // let startCallAction = CXStartCallAction(call: callID.callKitID, handle: handle)
        // startCallAction.isVideo = true
        
        // do {
        //     try await callController.request(CXTransaction(action: startCallAction))
        // } catch {
        //     MXLog.error("Failed requesting start call action with error: \(error)")
        // }
    }
    
    func tearDownCallSession() {
        tearDownCallSession(sendEndCallAction: true)
    }
    
    func setAudioEnabled(_ enabled: Bool, roomID: String) {
        guard let ongoingCallID else {
            MXLog.error("Failed toggling call microphone, no calls running")
            return
        }
        
        guard ongoingCallID.roomID == roomID else {
            MXLog.error("Failed toggling call microphone, rooms don't match: \(ongoingCallID.roomID) != \(roomID)")
            return
        }
        
        let transaction = CXTransaction(action: CXSetMutedCallAction(call: ongoingCallID.callKitID, muted: !enabled))
        callController.request(transaction) { error in
            if let error {
                MXLog.error("Failed toggling call microphone with error: \(error)")
            }
        }
    }

    // MARK: - PKPushRegistryDelegate
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        voipDeviceToken = pushCredentials.token
        let tokenStr = pushCredentials.token.base64EncodedString()
        os_log(.info, log: pushLog, "VoIP token received (%d bytes): %{public}@", pushCredentials.token.count, tokenStr)
        MXLog.info("sTalk: VoIP push token received (\(pushCredentials.token.count) bytes)")
        DiagLog.write("VoIP", "didUpdate token=\(tokenStr.prefix(16))…(len=\(pushCredentials.token.count)) registrationEnabled=\(Self.kEnableVoIPPusherRegistration)")
        if Self.kEnableVoIPPusherRegistration {
            Task { [weak self] in
                await self?.registerVoIPPusher(with: pushCredentials.token)
            }
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // iOS REQUIRES reportNewIncomingCall for every VoIP push, otherwise the app is killed.
        // If payload is missing required fields, report a fake call and immediately cancel it.
        os_log(.info, log: pushLog, "VoIP push received! payload keys: %{public}@", "\(payload.dictionaryPayload.keys)")
        DiagLog.write("VoIP", "didReceiveIncomingPush type=\(type.rawValue) keys=\(Array(payload.dictionaryPayload.keys))")

        // VoIP push может прийти от двух источников с разным форматом payload:
        // - NSE (reportNewIncomingVoIPPushPayload): ключи camelCase (ElementCallServiceNotificationKey)
        // - PushKit прямо от Sygnal: Matrix raw ключи (snake_case: room_id, event_id)
        let dict = payload.dictionaryPayload

        // EARLY marker — пишем сразу при получении VoIP push, до парсинга payload
        // и reportNewIncomingCall. Это даёт NSE максимально раннее знание что
        // CallKit pipeline активен — main гард в processEvent сработает на любом
        // следующем push в этой комнате (encrypted ratchet keys, member updates,
        // дубль ring и т.д.) и не покажет лишний banner.
        if let earlyRoomID = (dict[ElementCallServiceNotificationKey.roomID.rawValue] as? String)
            ?? (dict["room_id"] as? String) {
            Self.writeVoIPHandledMarker(roomID: earlyRoomID)
            DiagLog.write("VoIP", "  EARLY marker for room=\(earlyRoomID)")
        }

        guard let roomID = (dict[ElementCallServiceNotificationKey.roomID.rawValue] as? String)
            ?? (dict["room_id"] as? String) else {
            MXLog.error("Missing room identifier for incoming voip call, reporting and cancelling: \(dict)")
            reportAndCancelFakeCall(completion: completion)
            return
        }

        let rtcNotificationID = (dict[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] as? String)
            ?? (dict["event_id"] as? String)

        guard ongoingCallID?.roomID != roomID else {
            MXLog.warning("Call already ongoing for room \(roomID), reporting and cancelling")
            reportAndCancelFakeCall(completion: completion)
            return
        }

        let callID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: rtcNotificationID)
        incomingCallID = callID

        let expirationDate = payload.dictionaryPayload[ElementCallServiceNotificationKey.expirationDate.rawValue] as? Date
        let nowDate = timeProvider.now()

        if let expirationDate, nowDate >= expirationDate {
            MXLog.warning("Call expired for room \(roomID), reporting and cancelling")
            reportAndCancelFakeCall(completion: completion)
            return
        }

        let ringDuration: Duration
        if let expirationDate {
            ringDuration = .seconds(min(expirationDate.timeIntervalSince1970 - nowDate.timeIntervalSince1970, 90))
        } else {
            ringDuration = .seconds(30)
        }

        // Caller name приоритеты:
        // 1. roomDisplayName — явно от NSE path
        // 2. sender_display_name — от Sygnal raw VoIP push (e.g. "Rusty")
        // 3. sender MXID — e.g. "@rusty:stalk.implica.ru"
        // 4. fallback "Входящий звонок"
        let roomDisplayName = dict[ElementCallServiceNotificationKey.roomDisplayName.rawValue] as? String
        let senderDisplayName = dict["sender_display_name"] as? String
        let senderMXID = dict["sender"] as? String
        let callerName = roomDisplayName ?? senderDisplayName ?? senderMXID ?? "Входящий звонок"
        os_log(.info, log: pushLog, "Incoming VoIP call: room=%{public}@ caller=%{public}@ rtcEventID=%{public}@",
               roomID, callerName, rtcNotificationID ?? "nil")

        let update = CXCallUpdate()
        update.hasVideo = true
        update.localizedCallerName = callerName
        // https://stackoverflow.com/a/41230020/730924
        update.remoteHandle = .init(type: .generic, value: roomID)

        DiagLog.write("VoIP", "reportNewIncomingCall room=\(roomID) caller=\(callerName) callKitID=\(callID.callKitID)")
        callProvider.reportNewIncomingCall(with: callID.callKitID, update: update) { [weak self] error in
            if let error {
                MXLog.error("Failed reporting new incoming call with error: \(error)")
                DiagLog.write("VoIP", "  reportNewIncomingCall FAILED: \(error.localizedDescription)")
            } else {
                DiagLog.write("VoIP", "  reportNewIncomingCall OK → CallKit shown")
                // Marker для NSE: VoIP push дошёл и CallKit запущен. NSE проверяет
                // этот marker для этой комнаты — если свежий (<30 сек), не показывает
                // дубль banner от regular APNs ring.
                Self.writeVoIPHandledMarker(roomID: roomID)
            }

            self?.actionsSubject.send(.receivedIncomingCallRequest)

            completion()
        }

        endUnansweredCallTask = Task { [weak self] in
            try? await self?.timeProvider.clock.sleep(for: ringDuration)

            guard let self, !Task.isCancelled else {
                return
            }

            if let incomingCallID, incomingCallID.callKitID == callID.callKitID {
                callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .unanswered)
                // Notify about missed call
                actionsSubject.send(.missedCall(roomID: incomingCallID.roomID))
            }
        }
    }

    /// Report a fake incoming call and immediately cancel it to satisfy iOS VoIP push requirement.
    /// iOS kills the app if reportNewIncomingCall is not called for every VoIP push.
    /// We report and instantly end the call so the user sees nothing.
    private func reportAndCancelFakeCall(completion: @escaping () -> Void) {
        let fakeCallID = UUID()
        let update = CXCallUpdate()
        update.hasVideo = false
        update.localizedCallerName = ""
        update.remoteHandle = .init(type: .generic, value: "silent")

        callProvider.reportNewIncomingCall(with: fakeCallID, update: update) { [weak self] _ in
            // End immediately — before iOS has a chance to show CallKit UI
            self?.callProvider.reportCall(with: fakeCallID, endedAt: Date(), reason: .remoteEnded)
            completion()
        }
    }
    
    // MARK: - CXProviderDelegate
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did activate audio session")
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did deactivate audio session")
    }
    
    func providerDidReset(_ provider: CXProvider) {
        MXLog.info("Call provider did reset: \(provider)")
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        os_log(.info, log: pushLog, "User ACCEPTED incoming call — incomingCallID=%{public}@",
               incomingCallID.map { "\($0.roomID)" } ?? "nil")
        guard let incomingCallID else {
            MXLog.error("Failed answering incoming call, missing incomingCallID")
            os_log(.error, log: pushLog, "Accept FAILED: incomingCallID is nil")
            return
        }
        
        // Fixes broken videos on EC web when a CallKit session is established.
        //
        // Reporting an ongoing call through `reportNewIncomingCall` + `CXAnswerCallAction`
        // or `reportOutgoingCall:connectedAt:` will give exclusive access for media to the
        // ongoing process, which is different than the WKWebKit is running on, making EC
        // unable to aquire media streams.
        // Reporting the call as ended imediately after answering it works around that
        // as EC gets access to media again and EX builds the right UI in `setupCallSession`
        //
        // https://developer.apple.com/forums//thread/767949?answerId=812951022#812951022
        //
        // https://github.com/element-hq/element-x-ios/issues/3041
        // https://forums.developer.apple.com/forums/thread/685268
        // https://stackoverflow.com/questions/71483732/webrtc-running-from-wkwebview-avaudiosession-development-roadblock
        
        // First fullfill the action
        action.fulfill()
        
        // And delay ending the call so that the app has enough time
        // to get deeplinked into
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Then end the and call rely on `setupCallSession` to create a new one
            provider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)
            
            self.actionsSubject.send(.startCall(roomID: incomingCallID.roomID))
            self.endUnansweredCallTask?.cancel()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let ongoingCallID {
            actionsSubject.send(.setAudioEnabled(!action.isMuted, roomID: ongoingCallID.roomID))
        } else {
            MXLog.error("Failed muting/unmuting call, missing ongoingCallID")
        }
        
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if targetEnvironment(simulator)
        // This gets called for no reason on simulators, where CallKit
        // isn't even supported, ignore it.
        #else
        if let ongoingCallID {
            actionsSubject.send(.endCall(roomID: ongoingCallID.roomID))
        }
        
        if let incomingCallID {
            Task {
                await sendDeclineCallEvent(incomingCallID)
            }
        }
        
        tearDownCallSession(sendEndCallAction: false)
        
        action.fulfill()
        #endif
    }
    
    // MARK: - Private

    /// Cross-process marker для NSE: записать что VoIP push для этой комнаты был
    /// обработан и CallKit запущен. NSE при ring через regular APNs проверяет
    /// этот marker — если свежий, не показывает дубль banner.
    private static func writeVoIPHandledMarker(roomID: String) {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return }
        let dir = container.appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: "voip-handled", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let safeKey = roomID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
        let url = dir.appending(component: safeKey)
        try? Data().write(to: url)
        DiagLog.write("VoIP", "  marker written for room=\(roomID)")
    }

    /// Register VoIP pusher with the Matrix homeserver so Sygnal can send VoIP pushes
    private func registerVoIPPusher(with token: Data) async {
        guard let clientProxy else {
            os_log(.info, log: pushLog, "VoIP pusher deferred — no clientProxy yet")
            MXLog.info("VoIP pusher registration deferred — no client proxy yet")
            return
        }

        let pushGatewayURL = ServiceLocator.shared.settings.pushGatewayNotifyEndpoint.absoluteString
        let appID = InfoPlistReader.main.baseBundleIdentifier + ".voip"
        let pushkey = token.base64EncodedString()
        os_log(.info, log: pushLog, "registerVoIPPusher: pushkey=%{public}@, appID=%{public}@, gateway=%{public}@", pushkey, appID, pushGatewayURL)

        do {
            // VoIP pusher использует full format (format: nil) чтобы Sygnal получал
            // полный event.type для фильтрации в VoipFilterApnsPushkin. С event_id_only
            // Synapse шлёт только event_id — фильтр не может определить тип события.
            let configuration = PusherConfiguration(identifiers: .init(pushkey: pushkey, appId: appID),
                                                    kind: .http(data: .init(url: pushGatewayURL,
                                                                            format: nil,
                                                                            defaultPayload: nil)),
                                                    appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS VoIP)",
                                                    deviceDisplayName: UIDevice.current.name,
                                                    profileTag: nil,
                                                    lang: Bundle.app.preferredLocalizations.first ?? "en")
            try await clientProxy.setPusher(with: configuration)
            os_log(.info, log: pushLog, "VoIP pusher REGISTERED successfully (appID: %{public}@)", appID)
            MXLog.info("VoIP pusher registered successfully (appID: \(appID))")
            DiagLog.write("VoIP", "registerVoIPPusher OK appID=\(appID) pushkey=\(pushkey.prefix(16))…")
        } catch {
            os_log(.error, log: pushLog, "VoIP pusher FAILED: %{public}@", "\(error)")
            MXLog.error("Failed to register VoIP pusher: \(error)")
            DiagLog.write("VoIP", "registerVoIPPusher FAILED: \(error.localizedDescription)")
        }
    }

    private func tearDownCallSession(sendEndCallAction: Bool = true) {
        if let ongoingCallID {
            // Send endCall action for call history tracking
            actionsSubject.send(.endCall(roomID: ongoingCallID.roomID))

            if sendEndCallAction {
                let transaction = CXTransaction(action: CXEndCallAction(call: ongoingCallID.callKitID))
                callController.request(transaction) { error in
                    if let error {
                        MXLog.error("Failed transaction with error: \(error)")
                    }
                }
            }
        }

        ongoingCallID = nil
    }
    
    private func sendDeclineCallEvent(_ incomingCallID: CallID) async {
        guard let rtcNotificationID = incomingCallID.rtcNotificationID else {
            MXLog.info("No rtc notification event to decline.")
            return
        }
        
        guard let clientProxy else {
            MXLog.warning("A ClientProxy is needed to fetch the room.")
            return
        }
        
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(incomingCallID.roomID) else {
            MXLog.warning("Failed to fetch a joined room for the incoming call.")
            return
        }
        
        _ = await roomProxy.declineCall(notificationID: rtcNotificationID)
    }
    
    private func observeIncomingCall() async {
        incomingCallRoomInfoCancellable = nil
        
        guard let incomingCallID else {
            MXLog.info("No incoming call to observe for.")
            return
        }
        
        guard let clientProxy else {
            MXLog.warning("A ClientProxy is needed to fetch the room.")
            return
        }
        
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(incomingCallID.roomID) else {
            MXLog.warning("Failed to fetch a joined room for the incoming call.")
            return
        }
        
        roomProxy.subscribeToRoomInfoUpdates()
        
        incomingCallRoomInfoCancellable = roomProxy
            .infoPublisher
            .compactMap { ($0.hasRoomCall, $0.activeRoomCallParticipants) }
            .removeDuplicates { $0 == $1 }
            .drop { hasRoomCall, _ in
                // Filter all updates before hasRoomCall becomes `true`. Then we can correctly
                // detect its change to `false` to stop ringing when the caller hangs up.
                !hasRoomCall
            }
            .sink { [weak self] hasOngoingCall, activeRoomCallParticipants in
                guard let self else { return }
                
                let participants: [String] = activeRoomCallParticipants
                
                if !hasOngoingCall {
                    MXLog.info("Call cancelled by remote")
                    reportEndedCall(incomingCallID: incomingCallID, reason: .remoteEnded)
                } else if participants.contains(roomProxy.ownUserID) {
                    MXLog.info("Call answered elsewhere")
                    reportEndedCall(incomingCallID: incomingCallID, reason: .answeredElsewhere)
                }
            }
        
        guard let rtcNotificationID = incomingCallID.rtcNotificationID else {
            MXLog.warning("Decline: No RTC notification ID found for the incoming call.")
            return
        }
        
        MXLog.info("Observe decline events for notification \(rtcNotificationID)")
        
        let listener: CallDeclineListener = SDKListener { [weak self] senderID in
            guard let self else { return }
            
            MXLog.debug("Call declined event received from \(senderID)")
            
            if senderID == roomProxy.ownUserID {
                // Stop ringing!
                MXLog.debug("Call declined elsewhere")
                reportEndedCall(incomingCallID: incomingCallID, reason: .declinedElsewhere)
            }
        }
        
        guard case let .success(handle) = roomProxy.subscribeToCallDeclineEvents(rtcNotificationEventID: rtcNotificationID, listener: listener) else {
            MXLog.error("Unable to listen for decline events.")
            return
        }
        
        declineListenerHandle = handle
    }
    
    private func reportEndedCall(incomingCallID: CallID, reason: CXCallEndedReason) {
        declineListenerHandle?.cancel()
        declineListenerHandle = nil
        endUnansweredCallTask?.cancel()
        callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: reason)

        // Notify about missed call for unanswered scenarios
        if reason == .remoteEnded || reason == .unanswered {
            actionsSubject.send(.missedCall(roomID: incomingCallID.roomID))
        }
    }
}
