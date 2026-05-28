//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CallKit
import MatrixRustSDK
import os.log
import UserNotifications

private let nseHandlerLog = OSLog(subsystem: "ru.implica.stalk.nse", category: "Handler")

/// Удобная обёртка над общим DiagLog — добавляет тег `NSE`.
/// Реализация enum DiagLog находится в InfoPlistReader.swift (общий файл всех targets).
private enum NSEDiagLog {
    static func write(_ message: String) {
        DiagLog.write("NSE", message)
    }
}

/// Cross-process атомарный dedup через файловые lock'и.
///
/// Build 61 использовал JSON cache с DispatchQueue lock — НЕ работает между
/// NSE processes. Apple запускает несколько NSE параллельно для каждого push,
/// все они видели «пустой» cache одновременно и маркировали одну запись —
/// dedup не срабатывал, пользователь получал 6 banner'ов.
///
/// Build 62 использует POSIX `O_CREAT|O_EXCL` — атомарная операция «создать
/// файл, если не существует». Две parallel попытки гарантированно дадут
/// результат «один создал, второй увидел EEXIST». TTL через mtime файла.
///
/// Два уровня дедупа:
/// 1. По `eventID` — Sygnal/APNs retry с тем же event_id
/// 2. По `roomID:type` (например `room:ring`) — Element Web Variant B шлёт
///    несколько ring events за один звонок с разными eventIDs за 5-10 сек.
private enum NSEEventDedupCache {
    private static let ttl: TimeInterval = 60

    private static var dedupDirectory: URL? {
        guard let baseURL = DiagLog.fileURL?.deletingLastPathComponent() else { return nil }
        let dir = baseURL.appending(component: "dedup", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func isDuplicateAndMark(eventID: String) -> Bool {
        isDuplicateAndMark(key: "evt-\(sanitize(eventID))")
    }

    static func isDuplicateSemanticAndMark(roomID: String, kind: String) -> Bool {
        isDuplicateAndMark(key: "sem-\(sanitize(roomID))-\(kind)")
    }

    /// Атомарная mark-or-fail операция через POSIX `O_CREAT|O_EXCL`.
    /// - returns: true если уже существует свежий lock (= duplicate, discard)
    private static func isDuplicateAndMark(key: String) -> Bool {
        guard let dir = dedupDirectory else { return false }
        let lockPath = dir.appending(component: key).path

        // Stale lock: если файл существует но mtime > TTL — удалить и продолжить
        // как будто его не было (помогает при перезапусках устройства / сбоях).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: lockPath),
           let mtime = attrs[.modificationDate] as? Date {
            let age = -mtime.timeIntervalSinceNow
            if age < ttl {
                return true // свежий lock = duplicate
            }
            try? FileManager.default.removeItem(atPath: lockPath)
        }

        // Атомарная попытка создания. Если другой процесс уже создал между
        // нашей проверкой и open() — open вернёт -1 с EEXIST, считаем duplicate.
        let fd = open(lockPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            // EEXIST или другая ошибка — race lost, считаем duplicate
            return true
        }
        close(fd)
        return false
    }

    /// Sanitize key для безопасного file name (Matrix IDs содержат `:`, `!`, `$`).
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
    }
}

class NotificationHandler {
    private let userSession: NSEUserSession
    private let settings: CommonSettingsProtocol
    private let contentHandler: (UNNotificationContent) -> Void
    private var notificationContent: UNMutableNotificationContent
    private let tag: String
    
    private let notificationContentBuilder: NotificationContentBuilder
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var roomInfoObservationToken: TaskHandle?
    
    init(userSession: NSEUserSession,
         settings: CommonSettingsProtocol,
         contentHandler: @escaping (UNNotificationContent) -> Void,
         notificationContent: UNMutableNotificationContent,
         tag: String) {
        self.userSession = userSession
        self.settings = settings
        self.contentHandler = contentHandler
        self.notificationContent = notificationContent
        self.tag = tag
        
        let eventStringBuilder = RoomMessageEventStringBuilder(attributedStringBuilder: AttributedStringBuilder(mentionBuilder: PlainMentionBuilder()),
                                                               destination: .notification)
        
        notificationContentBuilder = NotificationContentBuilder(messageEventStringBuilder: eventStringBuilder,
                                                                userSession: userSession)
    }
    
    func processEvent(_ eventID: String, roomID: String) async {
        MXLog.info("\(tag) Processing event: \(eventID) in room: \(roomID)")
        NSEDiagLog.write("processEvent eventID=\(eventID) roomID=\(roomID) tag=\(tag)")

        // Главный гард: если в этой комнате CallKit активен (VoIP marker свежий),
        // НИЧЕГО не показываем. Любой push в активной call room = call signalling
        // (ratchet keys, member updates, дубль ring) — пользователь видит CallKit
        // и не должен получать поверх ещё banner-ы.
        if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
            NSEDiagLog.write("  → VoIP marker свежий — CallKit активен, DISCARD all")
            discardNotification()
            return
        }

        // Дедупликация: Sygnal/APNs иногда дублируют push с тем же event_id
        // (retry или race). Без dedup пользователь видит 2-3 одинаковых banner.
        if NSEEventDedupCache.isDuplicateAndMark(eventID: eventID) {
            NSEDiagLog.write("  → DUPLICATE event (seen <60s ago), DISCARD")
            discardNotification()
            return
        }

        // STMOB-108 build 135: НЕ устанавливаем .badge в NSE.
        // Раньше: notificationContent.badge = unreadCount → каждый push перетирал
        // системный счётчик значением unreadCount per-room на момент пуша
        // (обычно 1 для DM), затирая корректный sync из main app
        // (sum unreadNotificationsCount по всем joined-комнатам).
        // Теперь app icon badge единственно управляется setupBadgeUpdates в
        // AppCoordinator. Trade-off: если app убит — badge не растёт от push'ей,
        // но догоняется при ближайшем запуске app. Это лучше чем рассинхрон
        // (badge=1 при 3 непрочитанных в чате).
        MXLog.info("\(tag) Badge skipped — managed by main app (STMOB-108)")

        // Fast-fail timeout. Если RustSDK не успел fetch+decrypt event —
        // discard. Раньше блокировались на 19+ секунд пытаясь decrypt ratchet
        // keys, к моменту обработки следующего ring event NSE уже мёртв.
        //
        // STMOB-159 build 179: bump 3s → 10s.
        // STMOB-159 v2 build 181: bump 10s → 20s. dp.bondar лог 91 (14:14:37)
        // показал что 10s всё ещё мало — push timeout-нулся, через 3.5 сек
        // следующий push decrypted. Pattern: Synapse "холодный" через 25 мин
        // idle, первый retrieve >10s.
        //
        // 20s даёт больший margin на cold-start. Ring-event hang всё равно
        // перехватит handleTimeExpiration перед Apple kill на 30s (10s buffer).
        // Upstream Element X не имеет этого timeout вообще.
        let item: NotificationItemProxyProtocol? = await withTaskGroup(of: NotificationItemProxyProtocol?.self) { group in
            group.addTask { [weak self] in
                await self?.userSession.notificationItemProxy(roomID: roomID, eventID: eventID)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let notificationItemProxy = item else {
            MXLog.error("\(tag) Failed retrieving notification item (or timeout)")
            NSEDiagLog.write("  → failed/timeout retrieving notification item (>20s), DISCARD")
            discardNotification()
            return
        }

        let result = await preprocessNotification(notificationItemProxy)
        NSEDiagLog.write("  → result=\(result)")
        switch result {
        case .processedShouldDiscard, .unsupportedShouldDiscard:
            discardNotification()
        case .shouldDisplay:
            await notificationContentBuilder.process(notificationContent: &notificationContent,
                                                     notificationItem: notificationItemProxy,
                                                     mediaProvider: userSession.mediaProvider)

            // LAST CHANCE: пока NSE строил content (могло занять несколько секунд),
            // VoIP push мог прийти и main app запустить CallKit. Перепроверяем
            // marker перед deliver — если CallKit активен, не показываем banner.
            if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
                NSEDiagLog.write("  → VoIP marker появился перед deliver — DISCARD banner")
                discardNotification()
                return
            }

            deliverNotification()
        }
    }

    /// Проверка cross-process marker от main app (используется и в processEvent,
    /// и в handleCallNotification).
    private func isVoIPHandledRecently(roomID: String, withinSeconds: TimeInterval) -> Bool {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return false }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let safeKey = roomID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
        let url = container
            .appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: "voip-handled", directoryHint: .isDirectory)
            .appending(component: safeKey)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return -mtime.timeIntervalSinceNow < withinSeconds
    }
    
    func handleTimeExpiration() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content
        MXLog.info("\(tag) Extension time will expire")
        deliverNotification()
    }
    
    // MARK: - Private
    
    private func deliverNotification() {
        MXLog.info("\(tag) Delivering notification")
        contentHandler(notificationContent)
    }

    private func discardNotification() {
        MXLog.info("\(tag) Discarding notification")
        contentHandler(Self.makePassiveContent())
    }

    // sTalk: STMOB-94 — iOS NSE не может полностью отменить уведомление,
    // если APNs уже выделил слот баннера (mutable-content=1 + alert payload).
    // Build 97 ставил interruptionLevel=.passive, но iOS 26.3 всё равно
    // подхватывал alert из оригинального APNS payload как fallback и
    // показывал baseline-баннер ("1 уведомление" / "sTalk: Новое сообщение")
    // при первом MatrixRTC звонке (3× encryption_keys ratchet за 1-2 сек до
    // VoIP push). Для надёжного suppress нужно ВСЕ alert-поля принудительно
    // обнулить ДО выставления .passive, иначе iOS использует исходный alert.
    static func makePassiveContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.attachments = []
        content.userInfo = [:]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
            content.relevanceScore = 0
        }
        return content
    }
    
    private func preprocessNotification(_ itemProxy: NotificationItemProxyProtocol) async -> NotificationProcessingResult {
        if settings.hideQuietNotificationAlerts, !itemProxy.isNoisy {
            return .processedShouldDiscard
        }
        
        guard case let .timeline(event) = itemProxy.event else {
            return .shouldDisplay
        }
        
        let eventContent = try? event.content()
        os_log(.default, log: nseHandlerLog, "Event content type: %{public}@", String(describing: eventContent))
        NSEDiagLog.write("  preprocess: contentType=\(String(describing: eventContent)) eventID=\(event.eventId())")

        switch eventContent {
        case .messageLike(let messageContent):
            os_log(.default, log: nseHandlerLog, "MessageLike content: %{public}@", String(describing: messageContent))
            switch messageContent {
            case .roomEncrypted:
                // Suppress encrypted event в комнате с активным звонком:
                // это обычно call E2EE ключи или signalling (io.element.call.*).
                // На проде push rules на Synapse должны не слать их в regular pusher
                // (слой 1), это safety net — слой 3 защиты от banner спама.
                let hasActiveCall = userSession.roomForIdentifier(itemProxy.roomID)?.hasActiveRoomCall() ?? false
                NSEDiagLog.write("  encrypted event hasActiveRoomCall=\(hasActiveCall) room=\(itemProxy.roomID)")
                if hasActiveCall {
                    os_log(.default, log: nseHandlerLog, "Encrypted event in active-call room %{public}@ — suppressing (likely call signalling)", itemProxy.roomID)
                    return .processedShouldDiscard
                }
                return .shouldDisplay
            case .poll,
                 .sticker:
                return .shouldDisplay
            case .roomMessage(let messageType, _):
                switch messageType {
                case .emote, .image, .audio, .video, .file, .notice, .text, .location, .gallery:
                    return .shouldDisplay
                case .other:
                    return .unsupportedShouldDiscard
                }
            case .roomRedaction(let redactedEventID, _):
                guard let redactedEventID else {
                    MXLog.error("Unable to handle redact notification due to missing event ID")
                    return .processedShouldDiscard
                }
                
                let deliveredNotifications = await UNUserNotificationCenter.current().deliveredNotifications()
                
                if let targetNotification = deliveredNotifications.first(where: { $0.request.content.eventID == redactedEventID }) {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [targetNotification.request.identifier])
                }
                
                return .processedShouldDiscard
            case .rtcNotification(let notificationType, let expirationTimestamp):
                return await handleCallNotification(notificationType: notificationType,
                                                    rtcNotifyEventID: event.eventId(),
                                                    timestamp: event.timestamp(),
                                                    expirationTimestamp: expirationTimestamp,
                                                    roomID: itemProxy.roomID,
                                                    roomDisplayName: itemProxy.roomDisplayName)
            case .callAnswer,
                 .callInvite,
                 .callHangup,
                 .callCandidates,
                 .keyVerificationReady,
                 .keyVerificationStart,
                 .keyVerificationCancel,
                 .keyVerificationAccept,
                 .keyVerificationKey,
                 .keyVerificationMac,
                 .keyVerificationDone,
                 .reactionContent:
                return .unsupportedShouldDiscard
            }
        case .state:
            return .unsupportedShouldDiscard
        case .none:
            return .unsupportedShouldDiscard
        }
    }
    
    /// Handle incoming call notifications.
    /// - Returns: A boolean indicating whether the notification was handled and should now be discarded.
    private func handleCallNotification(notificationType: RtcNotificationType,
                                        rtcNotifyEventID: String,
                                        timestamp: Timestamp,
                                        expirationTimestamp: Timestamp,
                                        roomID: String,
                                        roomDisplayName: String) async -> NotificationProcessingResult {
        // Handle incoming VoIP calls, show the native OS call screen
        // https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls
        //
        // The way this works is the following:
        // - the NSE receives the notification and decrypts it
        // - checks if it's still time relevant (max 10 seconds old) and whether it should ring
        // - otherwise it goes on to show it as a normal notification
        // - if it should ring then it discards the notification but invokes `reportNewIncomingVoIPPushPayload`
        // so that the main app can handle it
        // - the main app picks this up in `PKPushRegistry.didReceiveIncomingPushWith` and
        // `CXProvider.reportNewIncomingCall` to show the system UI and handle actions on it.
        // N.B. this flow works properly only when background processing capabilities are enabled
        os_log(.default, log: nseHandlerLog, "handleCallNotification: type=%{public}@ room=%{public}@ expiration=%llu", String(describing: notificationType), roomID, expirationTimestamp)
        NSEDiagLog.write("  handleCallNotification type=\(notificationType) room=\(roomID) expiration=\(expirationTimestamp)")
        guard notificationType == .ring else {
            os_log(.default, log: nseHandlerLog, "Non-ringing call, suppressing — not a ring")
            NSEDiagLog.write("    → not a ring, DISCARD")
            return .processedShouldDiscard
        }

        // Cross-process check: main app PKPushRegistry мог уже получить VoIP push
        // и запустить CallKit. В этом случае нет смысла показывать banner —
        // CallKit full-screen уже видим пользователю. Marker file в AppGroup пишет
        // ElementCallService после reportNewIncomingCall, NSE проверяет mtime.
        if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
            NSEDiagLog.write("    → VoIP marker свежий (<30s) — CallKit уже запущен, DISCARD banner")
            return .processedShouldDiscard
        }

        // Семантический dedup: Element Web в Variant B иногда шлёт 2-3 ring events
        // за один звонок с разными eventIDs за 5-10 сек. Per-event dedup не помогает
        // (eventIDs разные), нужен dedup по комнате+типу. Если ring уже был обработан
        // в этой комнате за последние 60 сек — discard, не показываем второй banner.
        if NSEEventDedupCache.isDuplicateSemanticAndMark(roomID: roomID, kind: "ring") {
            NSEDiagLog.write("    → DUPLICATE ring for room \(roomID) (within 60s), DISCARD")
            return .processedShouldDiscard
        }
        
        // Check to see if a call is still ongoing
        if let room = userSession.roomForIdentifier(roomID) { // Try to get call details from the room info
            if !room.hasActiveRoomCall() { // If I don't have an active call wait a bit and make sure
                let expiringTask = ExpiringTaskRunner {
                    await withCheckedContinuation { [weak self] continuation in
                        self?.roomInfoObservationToken = room.subscribeToRoomInfoUpdates(listener: SDKListener { info in
                            if info.hasRoomCall {
                                MXLog.info("Received room info update and the room has an active call now.")
                                continuation.resume()
                            } else {
                                MXLog.info("Received a room info update but the room still doesn't have an ongoing call.")
                            }
                        })
                    }
                }
                
                try? await expiringTask.run(timeout: .seconds(5)) // Wait 5 seconds or just use whatever is available

                // За эти 5 сек ожидания мог прийти VoIP push в main app и запустить
                // CallKit. Перепроверяем marker — если CallKit запустился, не показываем
                // дубль banner. Это закрывает race condition когда NSE начинает
                // handleCallNotification ДО прихода VoIP push.
                if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
                    NSEDiagLog.write("    → VoIP marker появился за время wait (5s) — DISCARD banner")
                    return .processedShouldDiscard
                }

                guard room.hasActiveRoomCall() else {
                    MXLog.info("The room no longer has an ongoing call, handling as push notification")
                    return .shouldDisplay
                }
            }
        } else { // Otherwise fallback to the old timeout mechanism
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
            
            guard abs(timestamp.timeIntervalSinceNow) < ElementCallServiceNotificationDiscardDelta else {
                MXLog.info("Call notification is too old, handling as push notification")
                return .shouldDisplay
            }
        }
        
        let expirationDate = Date(timeIntervalSince1970: TimeInterval(expirationTimestamp / 1000))
        let payload = [ElementCallServiceNotificationKey.roomID.rawValue: roomID,
                       ElementCallServiceNotificationKey.roomDisplayName.rawValue: roomDisplayName,
                       ElementCallServiceNotificationKey.expirationDate.rawValue: expirationDate,
                       ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue: rtcNotifyEventID] as [String: Any]
        
        os_log(.default, log: nseHandlerLog, "Attempting CXProvider.reportNewIncomingVoIPPushPayload for room=%{public}@ display=%{public}@", roomID, roomDisplayName)
        NSEDiagLog.write("    attempting reportNewIncomingVoIPPushPayload room=\(roomID)")
        // Last chance check: ещё раз marker перед NSE shim — VoIP мог прийти
        // прямо в этот момент, отделяет от первого check секунды wait + setup.
        if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
            NSEDiagLog.write("    → VoIP marker свежий перед shim — DISCARD banner")
            return .processedShouldDiscard
        }

        do {
            try await CXProvider.reportNewIncomingVoIPPushPayload(payload)
            os_log(.default, log: nseHandlerLog, "Call notification delegated to CallKit OK")
            NSEDiagLog.write("    → CallKit OK, DISCARD push (VoIP path)")
        } catch {
            // Apple Code=2 для NSE→CallKit shim — semantic error, не retryable.
            // Эта API работает только когда исходный push был VoIP push (PKPushRegistry),
            // для regular APNs push'а превратить в CallKit невозможно. Real CallKit
            // запускается через PKPushRegistry main app, не из NSE shim.
            // Fallback на banner — единственный путь.
            os_log(.error, log: nseHandlerLog, "reportNewIncomingVoIPPushPayload FAILED: %{public}@, showing as call notification", String(describing: error))
            NSEDiagLog.write("    → CallKit FAILED: \(error) — fallback to banner (NSE shim не работает для regular APNs)")
            return .shouldDisplay
        }

        return .processedShouldDiscard
    }
    
    private enum NotificationProcessingResult {
        case shouldDisplay
        case processedShouldDiscard
        case unsupportedShouldDiscard
    }
}
