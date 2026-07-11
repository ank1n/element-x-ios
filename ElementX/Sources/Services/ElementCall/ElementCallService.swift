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
import Intents
import MatrixRustSDK
import os.log
import PushKit
import UIKit

private let pushLog = OSLog(subsystem: "ru.implica.stalk", category: "VoIPPush")

/// STMOB-99: shared App Group avatar cache. Pre-cached JPEG thumbnails
/// per Matrix userID, доступные синхронно с диска из VoIP push handler
/// без HTTP запросов (важно для CallKit reportNewIncomingCall <100ms
/// deadline).
///
/// Path: <groupContainer>/Library/Caches/avatars/<safeKey>.jpg
/// safeKey — SHA-256 хеш userID, чтобы избежать filesystem-unsafe chars
/// (@, :, etc) и одновременно ограничить длину пути.
///
/// Phase 1 (cache populate из main app — пока не реализован):
/// будет hook на mediaProvider thumbnail loads / room sync.
///
/// Phase 2 (this commit): VoIP push handler читает cache, fallback
/// на placeholder с инициалами через Avatars.generatePlaceholderAvatarImageData,
/// donate'ит INStartCallIntent с image — CallKit подхватывает аватарку
/// в fullscreen.
enum AppGroupAvatarCache {
    private static var cacheDirectory: URL? {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return nil
        }
        return container
            .appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: "avatars", directoryHint: .isDirectory)
    }

    /// Filesystem-safe key derived from arbitrary id (userID, roomID).
    private static func safeKey(for id: String) -> String {
        // Простой alphanumeric-ish заменой, без crypto зависимости — длина
        // userID/roomID ограничена Matrix-spec, base path короткий, файлы
        // не sensitive (публичные аватарки), поэтому SHA-256 не нужен.
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        return id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
    }

    static func readAvatar(for id: String) -> Data? {
        guard let cacheDirectory else { return nil }
        let url = cacheDirectory.appending(component: safeKey(for: id) + ".jpg")
        return try? Data(contentsOf: url)
    }

    static func saveAvatar(_ data: Data, for id: String) {
        guard let cacheDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let url = cacheDirectory.appending(component: safeKey(for: id) + ".jpg")
            try data.write(to: url, options: .atomic)
        } catch {
            MXLog.error("STMOB-99: failed saving avatar to App Group: \(error)")
        }
    }

    static func clearAll() {
        guard let cacheDirectory else { return }
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

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

    /// Есть ли входящий звонок в обработке (CallKit показан/отвечен, но сессия ещё
    /// не стала ongoing). В этом окне НЕЛЬЗЯ стопать sync: ответ через CallKit на
    /// убитом приложении делает app inactive → resign-хендлер гасил sync → звонку
    /// не приезжали widget-события/ключи → вечный «connecting» (лог dp 121, 17:44).
    var hasIncomingCall: Bool {
        incomingCallID != nil
    }

    private var endUnansweredCallTask: Task<Void, Never>?
    
    private var callActiveMarkerHeartbeatTask: Task<Void, Never>?

    private var ongoingCallID: CallID? {
        didSet {
            ongoingCallRoomIDSubject.send(ongoingCallID?.roomID)
            // Cross-process marker for the NSE: a call is active in this room. The NSE suppresses
            // encrypted call-signalling events (key ratchets) for rooms whose marker is FRESH
            // (short TTL, see NotificationHandler.isCallActiveForRoom), so the marker is written
            // with a heartbeat during the call and refreshed ONE FINAL TIME on hang-up instead of
            // being deleted: E2EE tails keep arriving for a minute or two after the call ended and
            // were showing as content-less banners the moment the marker vanished. The final write
            // buys exactly that grace window; a crashed call self-heals within the same short TTL.
            callActiveMarkerHeartbeatTask?.cancel()
            callActiveMarkerHeartbeatTask = nil
            if let oldRoomID = oldValue?.roomID, oldRoomID != ongoingCallID?.roomID {
                Self.writeCallActiveMarker(roomID: oldRoomID, context: "grace (call ended)")
            }
            if let roomID = ongoingCallID?.roomID {
                Self.writeCallActiveMarker(roomID: roomID, context: "call started")
                callActiveMarkerHeartbeatTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { break }
                        Self.writeCallActiveMarker(roomID: roomID, context: "heartbeat")
                    }
                }
            }
        }
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

        // sTalk: STMOB-90 — when SDK rotates Matrix device_id silently the VoIP
        // pusher in Synapse still points at the dead old device, so CallKit
        // full-screen rings regress to banner notifications. Re-register on
        // every device_id change using the cached PushKit token.
        NotificationCenter.default.addObserver(forName: .stalkMatrixDeviceIDChanged, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let oldID = (note.userInfo?["oldDeviceID"] as? String) ?? "?"
            let newID = (note.userInfo?["newDeviceID"] as? String) ?? "?"
            DiagLog.write("VoIP", "deviceID changed (\(oldID) → \(newID)) — re-registering VoIP pusher")
            guard Self.kEnableVoIPPusherRegistration, let token = self.voipDeviceToken else {
                DiagLog.write("VoIP", "  re-register skipped (token=\(self.voipDeviceToken == nil ? "nil" : "ok") flag=\(Self.kEnableVoIPPusherRegistration))")
                return
            }
            Task { await self.registerVoIPPusher(with: token) }
        }

        // sTalk: STMOB-90 — Molly observed that build 94 didn't register a
        // VoIP pusher for an already-active device because no rotation
        // happened post-install. setPusher upserts on Synapse side, so a
        // redundant re-register on every foreground entry is cheap and
        // ensures the pusher exists for the current (userId, deviceId, token)
        // tuple even when the rotation hook never fires.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            guard Self.kEnableVoIPPusherRegistration, let token = self.voipDeviceToken else { return }
            DiagLog.write("VoIP", "willEnterForeground — refreshing VoIP pusher (idempotent)")
            Task { await self.registerVoIPPusher(with: token) }
        }
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

    /// STMOB-130 build 153: native LiveKit path. Публикует roomID в
    /// ongoingCallRoomIDPublisher БЕЗ полного CallKit setup, чтобы
    /// RoomScreen знал что юзер в звонке (для скрытия «Присоединиться»
    /// плашки). nil — очистить при leave.
    func markNativeCallActive(roomID: String?) {
        DiagLog.write("Call", "markNativeCallActive(roomID=\(roomID ?? "nil"))")
        if let roomID {
            // Создаём минимальный CallID БЕЗ CallKit registration.
            ongoingCallID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil)
        } else {
            ongoingCallID = nil
        }
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

        // sTalk: STMOB-96 — Synapse fans out the same ring to multiple
        // call.member events, so iOS receives 3-4 VoIP pushes for the same
        // logical call within 2 seconds. Without dedupe each push creates a
        // fresh CallKit entry and the previous incomingCallID is overwritten,
        // which mangles the answer/reject flow downstream. If a CallKit ring
        // for this same roomID is already pending we skip the duplicate by
        // reporting+cancelling a throwaway call (CXProvider rejects the
        // payload, iOS does not stack a second ringer).
        if let pending = incomingCallID, pending.roomID == roomID {
            DiagLog.write("VoIP", "  duplicate ring for room=\(roomID), keeping existing callKitID=\(pending.callKitID)")
            MXLog.warning("Duplicate VoIP push for already-pending room \(roomID), discarding")
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
        let callerName = roomDisplayName ?? senderDisplayName ?? senderMXID ?? NSLocalizedString("stalk_incoming_call", tableName: "Localizable", value: "Входящий звонок", comment: "Fallback caller name for incoming call")
        os_log(.info, log: pushLog, "Incoming VoIP call: room=%{public}@ caller=%{public}@ rtcEventID=%{public}@",
               roomID, callerName, rtcNotificationID ?? "nil")

        // STMOB-99: donate INStartCallIntent с avatar до reportNewIncomingCall.
        // CallKit fullscreen подхватит INPerson.image для отображения аватарки.
        // Source приоритет: pre-cached в App Group (Layer A) →
        // initials placeholder через Avatars.generatePlaceholderAvatarImageData (Layer B) →
        // STMOB-253: асинхронный fetch реального аватара по sender_avatar_url из VoIP-payload
        // (Layer C — пушкин кладёт mxc, тумбнейл отдаётся публично; после fetch — re-donate
        // + кеш в App Group, чтобы следующий звонок был Layer A).
        // Hop on MainActor — Avatars helper isolated; donation выполнится
        // параллельно с reportNewIncomingCall, не блокирует CallKit deadline.
        let senderAvatarMXC = dict["sender_avatar_url"] as? String
        Task { @MainActor in
            Self.donateIncomingCallIntent(senderMXID: senderMXID,
                                          callerName: callerName,
                                          roomID: roomID,
                                          hasVideo: true,
                                          avatarMXC: senderAvatarMXC)
        }

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
                // STMOB-87 follow-up: build 100 hotfix очищал incomingCallID
                // только в tearDownCallSession. Если user не accept'ит звонок
                // и сработает unanswered timeout (90s) — incomingCallID не
                // очищается → следующий VoIP push в ту же комнату попадёт
                // в dedup ветку и будет cancel'нут как duplicate (silent push).
                // Подтверждено в логе 68: callKitID=02C762CA от unanswered call
                // 09:46 был использован как "duplicate" для нового call в 09:54.
                self.incomingCallID = nil
                self.endUnansweredCallTask = nil
            }
        }
    }

    /// Report a fake incoming call and immediately cancel it to satisfy iOS VoIP push requirement.
    /// iOS kills the app if reportNewIncomingCall is not called for every VoIP push.
    /// STMOB-99: donate INStartCallIntent so CallKit shows caller avatar
    /// in the incoming-call fullscreen UI. Без этого видно только имя.
    /// Image source приоритет:
    ///   1) Pre-cached в App Group (`AppGroupAvatarCache.readAvatar`)
    ///   2) Placeholder с инициалами (`Avatars.generatePlaceholderAvatarImageData`)
    /// Запускается ASAP — synchronously read avatar from disk + generate
    /// placeholder + donate занимает ~5-10ms. CallKit `reportNewIncomingCall`
    /// идёт параллельно, не блокируется.
    @MainActor
    private static func donateIncomingCallIntent(senderMXID: String?,
                                                 callerName: String,
                                                 roomID: String,
                                                 hasVideo: Bool,
                                                 avatarMXC: String? = nil) {
        let personID = senderMXID ?? roomID

        let avatarData: Data?
        var usedPlaceholder = false
        if let senderMXID, let cached = AppGroupAvatarCache.readAvatar(for: senderMXID) {
            avatarData = cached
            DiagLog.write("VoIP", "  intent donate: cached avatar for \(senderMXID)")
        } else {
            avatarData = Avatars.generatePlaceholderAvatarImageData(name: callerName,
                                                                    id: personID,
                                                                    size: CGSize(width: 100, height: 100))
            usedPlaceholder = true
            DiagLog.write("VoIP", "  intent donate: placeholder avatar for \(personID)")
        }

        // STMOB-253: the placeholder donation goes out immediately (CallKit deadline), then the real
        // avatar is fetched from the mxc in the VoIP payload and the intent is re-donated with it.
        // The thumbnail is served publicly from the media's own homeserver (multi-domain safe and
        // works on cold start, before any client session exists). Cached for the next call (Layer A).
        if usedPlaceholder, let senderMXID, let avatarMXC, let thumbnailURL = Self.mxcThumbnailURL(avatarMXC) {
            Task {
                guard let (data, response) = try? await URLSession.shared.data(from: thumbnailURL),
                      (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    DiagLog.write("VoIP", "  intent donate: avatar fetch failed for \(senderMXID)")
                    return
                }
                AppGroupAvatarCache.saveAvatar(data, for: senderMXID)
                DiagLog.write("VoIP", "  intent donate: fetched avatar (\(data.count)B) → re-donate for \(senderMXID)")
                await Self.donateIncomingCallIntent(senderMXID: senderMXID,
                                                    callerName: callerName,
                                                    roomID: roomID,
                                                    hasVideo: hasVideo)
            }
        }

        let image = if let data = avatarData {
            INImage(imageData: data)
        } else {
            INImage(named: "")
        }

        // STMOB-99 v2: improve INPerson construction для better CallKit avatar surface.
        // Изменения:
        //   - personHandle.type = .emailAddress (Matrix MXID @user:server email-like;
        //     раньше .unknown — iOS не surface'ит intent в Siri/Communication notifications)
        //   - nameComponents — Apple использует givenName для primary display
        //   - aliases с дополнительным handle = customIdentifier для Siri matching
        var nameComponents = PersonNameComponents()
        nameComponents.givenName = callerName
        let handle = INPersonHandle(value: personID, type: .emailAddress)
        let aliases = senderMXID.map { [INPersonHandle(value: $0, type: .emailAddress)] } ?? []
        let person = INPerson(personHandle: handle,
                              nameComponents: nameComponents,
                              displayName: callerName,
                              image: image,
                              contactIdentifier: nil,
                              customIdentifier: personID,
                              aliases: aliases,
                              suggestionType: .none)

        let intent = INStartCallIntent(callRecordFilter: nil,
                                       callRecordToCallBack: nil,
                                       audioRoute: .unknown,
                                       destinationType: .normal,
                                       contacts: [person],
                                       callCapability: hasVideo ? .videoCall : .audioCall)
        intent.setImage(image, forParameterNamed: \.contacts)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { error in
            if let error {
                MXLog.error("STMOB-99: donate INStartCallIntent failed: \(error)")
            }
        }
    }

    /// STMOB-253: mxc://server/mediaID → public thumbnail URL on the media's OWN homeserver.
    /// Using the mxc host (not the session's) is multi-domain correct and works on cold start,
    /// before any client session is restored.
    private static func mxcThumbnailURL(_ mxc: String) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let path = mxc.dropFirst("mxc://".count)
        let parts = path.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://\(parts[0])/_matrix/media/v3/thumbnail/\(parts[0])/\(parts[1])?width=192&height=192&method=crop")
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

    /// Cross-process marker directory + file URL for the "call is active in this room" flag the NSE
    /// reads to suppress encrypted call-signalling banners. Mirrors the voip-handled marker layout.
    private static func callActiveMarkerURL(roomID: String) -> URL? {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = container.appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: "call-active", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let safeKey = roomID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
        return dir.appending(component: safeKey)
    }

    private static func writeCallActiveMarker(roomID: String, context: String) {
        guard let url = callActiveMarkerURL(roomID: roomID) else { return }
        try? Data().write(to: url)
        DiagLog.write("VoIP", "  call-active marker [\(context)] room=\(roomID)")
    }

    /// Register VoIP pusher with the Matrix homeserver so Sygnal can send VoIP pushes
    private func registerVoIPPusher(with token: Data, isRetry: Bool = false) async {
        guard let clientProxy else {
            os_log(.info, log: pushLog, "VoIP pusher deferred — no clientProxy yet")
            MXLog.info("VoIP pusher registration deferred — no client proxy yet")
            return
        }

        // Multi-domain: VoIP pushes must go through the user's own server's Sygnal (STMOB-153).
        let pushGatewayURL = ServiceLocator.shared.settings.pushGatewayNotifyEndpoint(forHomeserver: clientProxy.homeserver).absoluteString
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
            // STMOB-95: cleanup stale VoIP pushers того же app_id у юзера до
            // регистрации нового. Best-effort — fail на delete не блокирует setPusher.
            let userID = clientProxy.userID
            let historicalKeys = PusherHistoryStorage.recordedPushkeys(userID: userID, appId: appID)
            let stalePushkeys = historicalKeys.filter { $0 != pushkey }
            for stalePushkey in stalePushkeys {
                do {
                    try await clientProxy.deletePusher(pushkey: stalePushkey, appId: appID)
                    PusherHistoryStorage.forgetPushkey(stalePushkey, userID: userID, appId: appID)
                    DiagLog.write("VoIP", "  cleanup deleted stale pushkey=\(stalePushkey.prefix(16))…")
                } catch {
                    DiagLog.write("VoIP", "  cleanup deletePusher FAILED for \(stalePushkey.prefix(16))…: \(error.localizedDescription)")
                }
            }

            try await clientProxy.setPusher(with: configuration)
            PusherHistoryStorage.recordPushkey(pushkey, userID: userID, appId: appID)
            os_log(.info, log: pushLog, "VoIP pusher REGISTERED successfully (appID: %{public}@)", appID)
            MXLog.info("VoIP pusher registered successfully (appID: \(appID))")
            DiagLog.write("VoIP", "registerVoIPPusher OK appID=\(appID) pushkey=\(pushkey.prefix(16))…")
        } catch {
            // STMOB-212: MAS access tokens expire every ~15 min. If registration hits
            // a stale token (M_UNKNOWN_TOKEN), force the SDK to refresh and retry once —
            // otherwise the VoIP pusher silently lapses and incoming calls stop ringing.
            if !isRetry,
               let clientError = error as? ClientError,
               case .MatrixApi(_, let code, _, _) = clientError,
               code == "M_UNKNOWN_TOKEN" {
                DiagLog.write("VoIP", "registerVoIPPusher M_UNKNOWN_TOKEN → forceTokenRefresh + retry")
                await clientProxy.forceTokenRefresh()
                await registerVoIPPusher(with: token, isRetry: true)
                return
            }
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

        // STALK-205 quick fix: clear our msc3401.call.member state events для ЛЮБОЙ
        // комнаты где был tearDown — answered, declined, ended, expired. Используем
        // ongoingCallID (если был accepted) ИЛИ incomingCallID (если только ring без
        // accept). Это уменьшает zombie state events от iOS Element X (legacy v1
        // {"memberships":[]} format) которые Sygnal v9 _room_has_active_call неправильно
        // интерпретирует.
        let roomIDForClear = ongoingCallID?.roomID ?? incomingCallID?.roomID
        DiagLog.write("Call", "tearDownCallSession: ongoing=\(ongoingCallID?.roomID ?? "nil") incoming=\(incomingCallID?.roomID ?? "nil") clearTarget=\(roomIDForClear ?? "nil")")
        if let roomIDForClear {
            Task { [weak self] in
                await self?.clearCallMemberStateEvents(roomID: roomIDForClear)
            }
        }

        // STMOB: incomingCallID должен быть nil после teardown — иначе следующий
        // VoIP push в ту же комнату через 4+ минут попадёт в STMOB-96 dedup
        // ветку (`if let pending = incomingCallID, pending.roomID == roomID`)
        // и CallKit не покажется. Раньше incomingCallID обнулялся ТОЛЬКО в
        // setupCallSession (line 178) — но setupCallSession не вызывается
        // если accept-flow не прошёл (decline сразу / NSE timeout / race).
        // Теперь любой teardown сбрасывает state — следующий звонок начнёт
        // с чистого листа.
        ongoingCallID = nil
        incomingCallID = nil

        // STMOB: cancel pending unanswered timeout — иначе при rapid hangup и
        // последующем звонке в ту же комнату он может выстрелить с reportCall
        // на старый callKitID и зашорить новый ring.
        endUnansweredCallTask?.cancel()
        endUnansweredCallTask = nil
    }

    /// Direct HTTP PUT для очистки своего msc3401.call.member state event текущего device.
    /// Workaround для отсутствия sendStateEvent в matrix-rust-sdk swift FFI.
    /// Build 70 пробовал GET /state потом PUT каждого — Synapse возвращал 403 (OIDC scope?).
    /// Build 71: один прямой PUT по вычисленному state_key = `_<userID>_<deviceID>_m.call`.
    /// Покрывает только текущий device, не все zombie. Но для текущей сессии достаточно
    /// чтобы Sygnal v9 видел leave вместо legacy v1 stuck.
    private func clearCallMemberStateEvents(roomID: String) async {
        DiagLog.write("Call", "clearCallMember START room=\(roomID)")
        guard let clientProxy else {
            DiagLog.write("Call", "  clearCallMember: clientProxy=nil — ABORT")
            return
        }
        let userID = clientProxy.userID
        guard let deviceID = clientProxy.deviceID else {
            DiagLog.write("Call", "  clearCallMember: deviceID=nil — ABORT")
            return
        }
        let homeserverString = clientProxy.homeserver
        DiagLog.write("Call", "  clearCallMember: userID=\(userID) deviceID=\(deviceID) homeserver=\(homeserverString)")
        let accessToken: String
        do {
            accessToken = try clientProxy.matrixAccessToken()
        } catch {
            DiagLog.write("Call", "  clearCallMember: no access token — \(error.localizedDescription) — ABORT")
            return
        }

        // State key formula: `_<userID>_<deviceID>_m.call` (Element Call MatrixRTC convention)
        let stateKey = "_\(userID)_\(deviceID)_m.call"
        guard let escapedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let escapedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            DiagLog.write("Call", "  clearCallMember: URL encoding failed — ABORT")
            return
        }
        let trimmedHomeserver = homeserverString.hasSuffix("/") ? String(homeserverString.dropLast()) : homeserverString
        guard let putURL = URL(string: "\(trimmedHomeserver)/_matrix/client/v3/rooms/\(escapedRoomID)/state/org.matrix.msc3401.call.member/\(escapedStateKey)") else {
            DiagLog.write("Call", "  clearCallMember: invalid PUT URL — ABORT")
            return
        }

        var putRequest = URLRequest(url: putURL)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = "{}".data(using: .utf8)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: putRequest)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyPreview = String(data: responseData, encoding: .utf8)?.prefix(200) ?? ""
            DiagLog.write("Call", "  clearCallMember PUT stateKey=\(stateKey) → HTTP \(code) body=\(bodyPreview)")
        } catch {
            DiagLog.write("Call", "  clearCallMember PUT FAILED: \(error.localizedDescription)")
        }
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
