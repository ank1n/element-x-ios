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
        // Без защиты: файлы пустые (значение несёт само их существование и mtime),
        // а класс по умолчанию делает каталог недоступным до первой разблокировки —
        // именно тогда, когда NSE обязан работать.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.none])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: dir.path)
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
            let err = errno // снять СРАЗУ: любой следующий вызов его затрёт
            if err == EEXIST {
                return true // гонку проиграли — это настоящий дубликат
            }
            // Иначе дедуп просто недоступен (нет прав до первой разблокировки,
            // нет места, нет каталога). Считать это дубликатом — значит молча
            // погасить уведомление ровно там, где оно нужнее всего.
            NSEDiagLog.write("  dedup недоступен key=\(key) errno=\(err) — показываю")
            return false
        }
        close(fd)
        return false
    }

    /// Снять отметку по eventID: фетч не удался и вместо контента показана
    /// заглушка. Повторная доставка того же event_id (Sygnal/APNs retry) —
    /// второй шанс скачать настоящий контент, а не «дубликат показанного».
    /// Семантические ключи (`sem-*`) не трогаем — их подавление намеренное.
    static func unmark(eventID: String) {
        guard let dir = dedupDirectory else { return }
        try? FileManager.default.removeItem(atPath: dir.appending(component: "evt-\(sanitize(eventID))").path)
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
    
    /// Дедлайн фетча: didReceive + 24с (бюджет NSE ~30с, ~6с на финализацию).
    /// С кэшем сессии инит почти бесплатный → бюджет фетча почти полный; при
    /// холодном ините остаток честно меньше — финализация не страдает.
    private let fetchDeadline: Date

    /// request.identifier текущего пуша — им же iOS ключует доставленное
    /// уведомление. Нужен, чтобы зачистка заглушек НИКОГДА не сняла доставку
    /// собственного запроса (гонка с expiration-путём).
    private let requestID: String

    init(userSession: NSEUserSession,
         settings: CommonSettingsProtocol,
         contentHandler: @escaping (UNNotificationContent) -> Void,
         notificationContent: UNMutableNotificationContent,
         tag: String,
         requestID: String,
         fetchDeadline: Date = Date().addingTimeInterval(24)) {
        self.userSession = userSession
        self.settings = settings
        self.contentHandler = contentHandler
        self.notificationContent = notificationContent
        self.tag = tag
        self.requestID = requestID
        self.fetchDeadline = fetchDeadline
        
        let eventStringBuilder = RoomMessageEventStringBuilder(attributedStringBuilder: AttributedStringBuilder(mentionBuilder: PlainMentionBuilder()),
                                                               destination: .notification)
        
        notificationContentBuilder = NotificationContentBuilder(messageEventStringBuilder: eventStringBuilder,
                                                                userSession: userSession)
    }
    
    func processEvent(_ eventID: String, roomID: String) async {
        stateLock.withLock {
            currentRoomID = roomID
            currentEventID = eventID
        }
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
        // 26.04.08: bump 20s → 27s. dp лог 120 (17:33:26): бурст из 3 сообщений
        // в одной комнате — первый fetch не уложился в 20s (второй в том же
        // процессе скачался за 2s), DISCARD-заглушка видна юзеру как пустой пуш.
        // Бюджет NSE ~30s от didReceive; 27s оставляет ~3s на финализацию,
        // ring-event hang всё равно перехватит handleTimeExpiration.
        // Upstream Element X не имеет этого timeout вообще.
        // Сага плашек (20.07): фикс 27с при бюджете 30с не учитывал стоимость инита
        // сессии до processEvent → системные киллы по времени → iOS переставала
        // запускать NSE (мёртвые зоны, сырые плашки). Теперь бюджет = остаток до
        // дедлайна (didReceive+24с), финализация всегда успевает.
        let fetchBudget = max(5.0, fetchDeadline.timeIntervalSinceNow)
        NSEDiagLog.write("  fetch budget \(Int(fetchBudget))s")

        // STMOB-277: раньше здесь была одна попытка, и «пустые пуши» списывались на
        // нехватку бюджета. Лог 212 показал обратное: неудачные попытки возвращались
        // РОВНО через 13.5 с при бюджете 23 с — то есть отваливался сам запрос SDK
        // (`requestTimeout` сессии), а девять с лишним секунд бюджета оставались
        // неиспользованными. Поэтому: замеряем фактическое время и, если бюджет ещё
        // позволяет, делаем второй заход — по прежним наблюдениям повторная попытка
        // нередко скачивает событие за пару секунд.
        var item: NotificationItemProxyProtocol?
        var attempt = 0

        // STMOB-277: статусы различимы — «не найдено» повторяем, «вычищено/
        // отфильтровано» окончательно (заглушка по такому событию — мусор).
        var suppressed = false
        while attempt < 2 {
            attempt += 1
            let remaining = max(0, fetchDeadline.timeIntervalSinceNow)
            guard remaining >= 3 else { break }

            // Кап попытки 10с, а не весь бюджет (лог dp 02.08): первый пуш после
            // многочасового простоя виснет ЦЕЛИКОМ — даже наш сон 23с просыпался
            // на 30-й секунде (системе жалко CPU задремавшему процессу). Раньше
            // зависшая попытка съедала бюджет и вторая не стартовала; с капом
            // вторая идёт на свежем состоянии и по замерам успевает за секунды.
            let attemptCap = min(remaining, 10)
            let started = Date()
            let fetch = await withTaskGroup(of: NSEUserSession.NotificationFetch?.self) { group in
                group.addTask { [weak self] in
                    await self?.userSession.notificationFetch(roomID: roomID, eventID: eventID)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(attemptCap * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            // Дрейф сна = процессу не давали CPU (троттлинг NSE после простоя).
            // Пишем в выгрузку — подтверждение/опровержение придёт само.
            let drift = Date().timeIntervalSince(started) - attemptCap
            if fetch == nil, drift > 2 {
                NSEDiagLog.write(String(format: "  ⚠️ сон дрейфанул на %.1fs — системный троттлинг процесса", drift))
            }

            let outcome: String
            switch fetch {
            case .item(let proxy):
                item = proxy
                outcome = "событие"
            case .suppressed:
                suppressed = true
                outcome = "вычищено/отфильтровано"
            case .notFound:
                outcome = "не найдено"
            case nil:
                outcome = "пусто (таймаут)"
            }

            let elapsed = Date().timeIntervalSince(started)
            NSEDiagLog.write(String(format: "  fetch attempt %d: %@ за %.1fs (осталось %.1fs)",
                                    attempt,
                                    outcome,
                                    elapsed,
                                    max(0, fetchDeadline.timeIntervalSinceNow)))
            if item != nil || suppressed { break }
        }

        if suppressed {
            NSEDiagLog.write("  → событие вычищено/отфильтровано — DISCARD, заглушке тут не место")
            discardNotification()
            return
        }

        guard let notificationItemProxy = item else {
            MXLog.error("\(tag) Failed retrieving notification item (or timeout)")
            // В звонке/грации (2 мин после) нескачавшееся событие = E2EE-хвост
            // звонка/записи — тихо гасим, НЕ показываем generic (dp лог 126:
            // «Новое сообщение» через 2.5с после hangup со включённой записью).
            if isCallOrTailForRoom(roomID) {
                NSEDiagLog.write("  → fetch failed + call-active marker, DISCARD (call tail)")
                discardNotification()
                return
            }
            NSEDiagLog.write("  → failed/timeout retrieving notification item, SHOW GENERIC")
            // Не пустышка: событие существует, но не скачалось в бюджет NSE.
            // Заглушка несёт room_id/event_id (тап открывает чат) и снимает
            // дедуп-отметку — retry-пуш этого события получит второй шанс.
            // Если ретрай тоже таймаутится — заглушки не копим: прошлую убираем.
            await removeDeliveredNotifications(for: eventID)
            showGenericMessageNotification()
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

            // Retry после fetch-таймаута: по этому событию в Центре уведомлений
            // может висеть заглушка «Новое сообщение» от прошлой попытки —
            // реальный контент её суперсидит (тот же приём, что у redaction).
            // EmptyProxy (SDK-ошибка вместо контента) не суперсидит ничего:
            // затирать информативную заглушку баннером «sTalk/Уведомление» хуже,
            // чем оставить как есть, — при висящей заглушке его гасим.
            if notificationItemProxy.event != nil {
                await removeDeliveredNotifications(for: eventID)
            } else if await hasDeliveredNotification(for: eventID) {
                NSEDiagLog.write("  → EmptyProxy при висящей заглушке этого события — DISCARD")
                discardNotification()
                return
            }

            deliverNotification()
        }
    }

    /// Убрать уже доставленные уведомления этого события — заглушку прошлой
    /// попытки или дубль. Собственный запрос исключён по request.identifier:
    /// expiration-путь мог доставить баннер ЭТОГО же пуша, пока билдер ещё
    /// работал, — снять его нельзя, once-гард молча съест повторную доставку
    /// и юзер не получит ничего.
    private func removeDeliveredNotifications(for eventID: String) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let stale = delivered
            .filter { $0.request.content.eventID == eventID && $0.request.identifier != requestID }
            .map(\.request.identifier)
        guard !stale.isEmpty else { return }
        NSEDiagLog.write("  → снимаю прежние уведомления события (\(stale.count) шт.)")
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
    }

    /// Висит ли в Центре уведомлений доставленное уведомление этого события
    /// от ДРУГОГО запроса (заглушка прошлой попытки).
    private func hasDeliveredNotification(for eventID: String) async -> Bool {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .contains { $0.request.content.eventID == eventID && $0.request.identifier != requestID }
    }

    /// Проверка cross-process marker от main app (используется и в processEvent,
    /// и в handleCallNotification).
    private func isVoIPHandledRecently(roomID: String, withinSeconds: TimeInterval) -> Bool {
        NSECallMarkers.isVoIPHandledRecently(roomID: roomID, withinSeconds: withinSeconds)
    }

    /// Cross-process marker written by the main app during an active call (heartbeat every 30s) and
    /// refreshed one final time on hang-up (see ElementCallService). The short TTL therefore means:
    /// suppress while the call runs AND for ~2 minutes after it ends — E2EE signalling tails kept
    /// arriving right after hang-up and showed as content-less banners. A crash mid-call self-heals
    /// within the same window.
    /// Подавление хвостов звонка: «идёт ИЛИ только что кончился».
    private func isCallOrTailForRoom(_ roomID: String) -> Bool {
        NSECallMarkers.isCallOrTail(roomID: roomID)
    }

    /// Звонок идёт прямо сейчас (без грации) — для решений о показе баннера о звонке.
    private func isCallActiveForRoom(_ roomID: String) -> Bool {
        NSECallMarkers.isCallActive(roomID: roomID)
    }
    
    func handleTimeExpiration() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content
        MXLog.info("\(tag) Extension time will expire")
        NSEDiagLog.write("  → NSE time expired")
        // Наш payload = eventIdOnly: если контент к этому моменту не собран,
        // сырой contentHandler даст ПУСТОЙ баннер (dp лог 124, 12:00) — отдаём
        // «Новое сообщение», как и на fetch-таймауте.
        if notificationContent.title.isEmpty, notificationContent.body.isEmpty {
            NSEDiagLog.write("  → content empty at expiration, SHOW GENERIC")
            showGenericMessageNotification()
        } else {
            deliverNotification()
        }
    }
    
    // MARK: - Private

    /// Замок состояния хендлера: processEvent пишет из своей Task, expiration
    /// читает из системного потока. Поля ниже — только под ним.
    private let stateLock = NSLock()
    /// ⚠️ iOS считает поведение неопределённым (дубль-баннер/краш) при повторном
    /// вызове contentHandler. На cold-Synapse (наш кейс: NSE-фетч 28-29с) expiration
    /// и fetch-timeout могут дёрнуть его дважды. Один-и-только-один гард.
    private var contentHandlerCalled = false
    private func callContentHandlerOnce(_ content: UNNotificationContent) {
        let alreadyCalled = stateLock.withLock {
            defer { contentHandlerCalled = true }
            return contentHandlerCalled
        }
        guard !alreadyCalled else {
            MXLog.info("\(tag) contentHandler already called — ignoring duplicate")
            return
        }
        contentHandler(content)
    }

    private func deliverNotification() {
        MXLog.info("\(tag) Delivering notification")
        callContentHandlerOnce(notificationContent)
    }

    private func discardNotification() {
        MXLog.info("\(tag) Discarding notification")
        callContentHandlerOnce(Self.makePassiveContent())
    }

    /// roomID/eventID текущего события — для generic-уведомления на
    /// fetch-таймауте и expiration-пути. Доступ только под stateLock.
    private var currentRoomID: String?
    private var currentEventID: String?

    /// Fetch-таймаут: событие есть, но не скачалось в бюджет NSE. Показываем
    /// осмысленное уведомление (имя комнаты из ЛОКАЛЬНОГО стора + «Новое
    /// сообщение») вместо пустой заглушки. Синапс после простоя отвечает NSE
    /// >27с (лог dp 129) — с именем комнаты такой пуш хотя бы информативен.
    ///
    /// STMOB-277: заглушка обязана нести room_id — notificationTapped без него
    /// no-op, тап открывал приложение «в никуда». Дедуп-отметку события снимаем:
    /// показанная заглушка ≠ показанный контент, retry должен пройти фетч заново
    /// (а успех уберёт заглушку — см. removeDeliveredNotifications).
    private func showGenericMessageNotification() {
        let (roomID, eventID) = stateLock.withLock { (currentRoomID, currentEventID) }
        let content = UNMutableNotificationContent()
        let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        if let roomID,
           let roomName = roomNameWithTimeout(roomID),
           !roomName.isEmpty {
            content.title = roomName
        }
        content.body = isRussian ? "Новое сообщение" : "New message"
        content.sound = .default
        if let roomID {
            content.roomID = roomID
            // Тот же формат, что у NotificationContentBuilder (receiver+room,
            // без «@» из-за бага iOS с кнопкой mute) — заглушка группируется
            // с реальными уведомлениями комнаты.
            content.threadIdentifier = "\(userSession.userID)\(roomID)".replacingOccurrences(of: "@", with: "")
        }
        if let eventID {
            content.eventID = eventID
            content.receiverID = userSession.userID
            NSEEventDedupCache.unmark(eventID: eventID)
        }
        callContentHandlerOnce(content)
    }

    /// displayName комнаты через синхронный FFI, но с капом: на запаузенном/занятом
    /// сторе вызов мог висеть и съедать финализацию перед системным киллом.
    private func roomNameWithTimeout(_ roomID: String, seconds: Double = 2) -> String? {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func set(_ v: String?) {
                lock.lock(); value = v; lock.unlock()
            }

            func get() -> String? {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [userSession] in
            box.set(userSession.roomForIdentifier(roomID)?.displayName())
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + seconds)
        return box.get()
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
        // STMOB-234 (dp, лог 144): userInfo обнуляем (иначе iOS берёт alert из
        // исходного aps как fallback), но оставляем маркер — по нему приложение
        // узнаёт «это наша заглушка» и не даёт ей показаться/остаться в Центре
        // уведомлений пустой строкой. Полностью подавить доставку из NSE нельзя:
        // contentHandler обязан быть вызван, а пустой контент iOS всё равно
        // кладёт в список.
        content.userInfo = [NotificationConstants.UserInfoKey.suppressed: true]
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
                // Suppress an undecryptable encrypted event when a call is active in the room: these
                // are almost always call E2EE keys / signalling (io.element.call.*), which the NSE
                // can't decrypt and would otherwise show as a content-less "New message" banner — the
                // spam seen throughout a call. On prod, Synapse push rules should keep them out of the
                // regular pusher (layer 1); this is the layer-3 safety net.
                //
                // Prefer the main-app call-active marker over hasActiveRoomCall(): the latter reads the
                // NSE's own room-state sync, which is frequently stale in the extension process (so it
                // returned false during a live call and let the banners through). The marker reflects
                // the app's authoritative state for the whole call. We deliberately do NOT blanket-drop
                // all encrypted events — outside a call an undecryptable event may be a real message
                // (this app has occasional E2EE key-desync), so it still surfaces.
                let hasActiveCall = userSession.roomForIdentifier(itemProxy.roomID)?.hasActiveRoomCall() ?? false
                let callMarker = isCallOrTailForRoom(itemProxy.roomID)
                NSEDiagLog.write("  encrypted event hasActiveRoomCall=\(hasActiveCall) callActiveMarker=\(callMarker) room=\(itemProxy.roomID)")
                if hasActiveCall || callMarker {
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
            case .rtcNotification(let notificationType, let expirationTimestamp, _):
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
            // STMOB-266: не ring = «звонок начался, но звонить не надо» (групповая
            // комната). Раньше молча гасили — юзер видел пустую плашку и не узнавал
            // о звонке вовсе. Показываем информационный баннер, но с тем же гейтом,
            // что и payload-ветка: не дублируем CallKit и не шумим по своему же звонку.
            os_log(.default, log: nseHandlerLog, "Non-ringing call → информационный баннер")
            NSEDiagLog.write("    → not a ring, показываем баннер «начался звонок»")
            if isVoIPHandledRecently(roomID: roomID, withinSeconds: 30) {
                NSEDiagLog.write("      → VoIP marker свежий — DISCARD")
                return .processedShouldDiscard
            }
            if isCallActiveForRoom(roomID) {
                NSEDiagLog.write("      → call-active marker — DISCARD")
                return .processedShouldDiscard
            }
            if expirationTimestamp > 0, Date(timeIntervalSince1970: TimeInterval(expirationTimestamp) / 1000) < Date() {
                NSEDiagLog.write("      → протух — DISCARD")
                return .processedShouldDiscard
            }
            if NSEEventDedupCache.isDuplicateSemanticAndMark(roomID: roomID, kind: "call-notice") {
                NSEDiagLog.write("      → DUPLICATE call-notice для комнаты — DISCARD")
                return .processedShouldDiscard
            }
            return .shouldDisplay
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
                        // ⚠️ CheckedContinuation одноразовый: listener шлёт апдейт на КАЖДОЕ
                        // изменение roomInfo, и два подряд с hasRoomCall=true (glare/rejoin)
                        // вызвали бы resume() дважды → фатальный краш NSE-процесса → входящий
                        // не доставлен. Гард `resumed` (локальный, захвачен замыканием).
                        var resumed = false
                        self?.roomInfoObservationToken = room.subscribeToRoomInfoUpdates(listener: SDKListener { info in
                            if info.hasRoomCall {
                                MXLog.info("Received room info update and the room has an active call now.")
                                guard !resumed else { return }
                                resumed = true
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

/// Cross-process маркеры от главного приложения, лежащие в AppGroup. Читают их
/// и `NotificationHandler` (ring), и гейт информационного баннера (STMOB-266),
/// поэтому логика одна на всех — расхождение здесь означало бы дубль к CallKit.
enum NSECallMarkers {
    /// Маркер пишет `ElementCallService` сразу после `reportNewIncomingCall`:
    /// главное приложение уже получило VoIP push и показало CallKit.
    static func isVoIPHandledRecently(roomID: String, withinSeconds: TimeInterval) -> Bool {
        freshness(directory: "voip-handled", roomID: roomID) < withinSeconds
    }

    /// Маркер живого звонка: главное приложение обновляет его каждые 30с и ещё раз
    /// на отбое. TTL 120с поэтому значит «пока звонок идёт И ~2 минуты после» —
    /// E2EE-хвосты продолжали прилетать сразу после hangup. Падение приложения
    /// посреди звонка самозалечивается в том же окне.
    static func isCallActive(roomID: String, ttlSeconds: TimeInterval = 45) -> Bool {
        freshness(directory: "call-active", roomID: roomID) < ttlSeconds
    }

    /// Звонок идёт ИЛИ только что закончился. Грация нужна подавлению E2EE-хвостов:
    /// служебные события продолжают прилетать ещё минуту-две после отбоя. Для
    /// информационного баннера о НОВОМ звонке грация, наоборот, вредна — им нужен
    /// isCallActive (лог 151: баннеры гасились через 35 и 53 секунды после отбоя).
    static func isCallOrTail(roomID: String) -> Bool {
        isCallActive(roomID: roomID) || freshness(directory: "call-tail", roomID: roomID) < 120
    }

    private static func freshness(directory: String, roomID: String) -> TimeInterval {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return .greatestFiniteMagnitude
        }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let safeKey = roomID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
        let url = container
            .appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: directory, directoryHint: .isDirectory)
            .appending(component: safeKey)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return .greatestFiniteMagnitude
        }
        return -mtime.timeIntervalSinceNow
    }
}

// MARK: - STMOB-266: «тихое» уведомление о начавшемся звонке

/// Событие звонка с `intent=silent` приходит ОБЫЧНЫМ APNs-пушем: в групповой
/// комнате звонок не должен звонить всем, но человек должен узнать, что он начался.
/// Ring-варианты обслуживает VoIP-пушер → CallKit и сюда не попадают.
///
/// SDK по этим типам контента не отдаёт (`contentType=nil` → `unsupportedShouldDiscard`),
/// поэтому баннер собираем прямо из payload, не поднимая сессию: так это работает
/// и на залоченном девайсе, и без credentials, и не тратит 24-секундный бюджет NSE.
/// Поля кладёт Sygnal (STALK-572); пока их нет — `init?` вернёт nil и всё пойдёт
/// прежним путём, регрессии не будет.
struct CallNoticePayload {
    /// Сырые типы события: легаси `call.notify`, MSC4075 `rtc.notification` и
    /// стабилизированный `m.rtc.notification` — на будущее.
    private static let supportedTypes: Set = ["org.matrix.msc4075.call.notify",
                                              "org.matrix.msc4075.rtc.notification",
                                              "m.rtc.notification"]

    let roomID: String
    let eventID: String
    let senderID: String?
    let senderDisplayName: String?
    let roomName: String?
    let isDirect: Bool
    let expirationDate: Date?

    init?(userInfo: [AnyHashable: Any]) {
        guard let eventType = userInfo["event_type"] as? String,
              Self.supportedTypes.contains(eventType) else { return nil }

        // ring не перехватываем ни при каких условиях — это территория CallKit.
        // Нет поля вовсе → тоже не перехватываем: старый сервер, пусть работает
        // существующий путь через SDK.
        guard let notifyType = (userInfo["call_notify_type"] as? String)?.lowercased(),
              notifyType == "notify" || notifyType == "notification" else { return nil }

        guard let roomID = userInfo[NotificationConstants.UserInfoKey.roomIdentifier] as? String,
              let eventID = userInfo[NotificationConstants.UserInfoKey.eventIdentifier] as? String else { return nil }

        self.roomID = roomID
        self.eventID = eventID
        senderID = userInfo["sender"] as? String
        senderDisplayName = (userInfo["sender_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        roomName = (userInfo["room_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        isDirect = (userInfo["is_direct"] as? Bool) ?? (userInfo["is_direct"] as? NSNumber)?.boolValue ?? false

        // Звонок живёт недолго: девайс был офлайн, APNs доставил через 10 минут —
        // «начался звонок» к этому моменту уже неправда. Отсечку даёт сервер
        // (expires_ts), запасная — по возрасту события.
        if let expires = userInfo["expires_ts"] as? NSNumber {
            expirationDate = Date(timeIntervalSince1970: expires.doubleValue / 1000)
        } else if let origin = userInfo["origin_server_ts"] as? NSNumber {
            expirationDate = Date(timeIntervalSince1970: origin.doubleValue / 1000).addingTimeInterval(120)
        } else {
            expirationDate = nil
        }
    }

    /// Имя звонящего: display name → localpart MXID → имя комнаты → нейтральный дефолт.
    var callerName: String {
        if let senderDisplayName { return senderDisplayName }
        if let senderID, senderID.hasPrefix("@") {
            return String(senderID.dropFirst().prefix { $0 != ":" })
        }
        return roomName ?? NSEStrings.callerUnknown
    }

    func makeContent(receiverID: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let caller = callerName

        if let roomName, !isDirect {
            // Группа: комната в заголовке, кто начал — в теле.
            content.title = "📞 \(roomName)"
            content.body = String(format: NSEStrings.callStarted, caller)
        } else {
            content.title = "📞 \(caller)"
            content.body = NSEStrings.callStartedDirect
        }

        content.sound = .default
        content.categoryIdentifier = NotificationConstants.Category.call
        content.threadIdentifier = roomID
        content.interruptionLevel = .active

        var info: [AnyHashable: Any] = [
            NotificationConstants.UserInfoKey.roomIdentifier: roomID,
            NotificationConstants.UserInfoKey.eventIdentifier: eventID,
            NotificationConstants.UserInfoKey.callNotice: true
        ]
        if let receiverID {
            info[NotificationConstants.UserInfoKey.receiverIdentifier] = receiverID
        }
        content.userInfo = info

        return content
    }
}

/// Строки баннера. `SL10n` живёт в таргете приложения и в NSE не доступен,
/// поэтому здесь прямой `NSLocalizedString` — как в остальном коде расширения.
/// Ключи заведены и в `ru.lproj`, и в `en.lproj`: сервер использует их же как
/// `loc-key` в `aps.alert`, чтобы осмысленный текст был даже если NSE не успеет
/// отработать (тогда фолбэк `value:` из кода не применяется).
enum NSEStrings {
    static var callStarted: String {
        NSLocalizedString("stalk_notification_call_started", tableName: "Localizable",
                          bundle: Bundle.app, value: "%@ начал звонок",
                          comment: "Call started banner, group room")
    }

    static var callStartedDirect: String {
        NSLocalizedString("stalk_notification_call_started_dm", tableName: "Localizable",
                          bundle: Bundle.app, value: "Начал звонок",
                          comment: "Call started banner, direct chat")
    }

    static var callerUnknown: String {
        NSLocalizedString("stalk_notification_call_caller_unknown", tableName: "Localizable",
                          bundle: Bundle.app, value: "Звонок",
                          comment: "Call started banner, unknown caller")
    }
}

/// Решение «показывать ли баннер». Порядок важен: сначала дешёвые проверки
/// «нам вообще нечего показывать», и только потом дедуп — он ПИШЕТ lock-файл,
/// не тратим его на заведомо подавляемый пуш.
enum CallNoticeGate {
    static func shouldShow(_ notice: CallNoticePayload) -> Bool {
        // 1. CallKit уже на экране: main app принял VoIP push по этому же звонку.
        if NSECallMarkers.isVoIPHandledRecently(roomID: notice.roomID, withinSeconds: 30) {
            NSEDiagLog.write("  call-notice: VoIP marker свежий — DISCARD")
            return false
        }
        // 2. Мы уже в этом звонке (heartbeat 30с) или вышли <2 мин назад.
        if NSECallMarkers.isCallActive(roomID: notice.roomID) {
            NSEDiagLog.write("  call-notice: звонок в этой комнате уже идёт — DISCARD")
            return false
        }
        // 3. Звонок протух: «начался звонок» через 10 минут — мусор.
        if let expiration = notice.expirationDate, expiration < Date() {
            NSEDiagLog.write("  call-notice: протух (\(expiration)) — DISCARD")
            return false
        }
        // 4. APNs-retry с тем же event_id.
        if NSEEventDedupCache.isDuplicateAndMark(eventID: notice.eventID) {
            NSEDiagLog.write("  call-notice: DUPLICATE event — DISCARD")
            return false
        }
        // 5. Веб шлёт 2-3 notify на один звонок с разными eventID — дедуп по комнате.
        //    Ключ отличен от "ring": пути CallKit не пересекаются.
        if NSEEventDedupCache.isDuplicateSemanticAndMark(roomID: notice.roomID, kind: "call-notice") {
            NSEDiagLog.write("  call-notice: DUPLICATE call-notice для комнаты — DISCARD")
            return false
        }
        return true
    }
}
