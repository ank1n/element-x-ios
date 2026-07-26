//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import os.log
import UserNotifications

private let nseLog = OSLog(subsystem: "ru.implica.stalk.nse", category: "NSE")

// The lifecycle of the NSE looks something like the following:
//  1)  App receives notification
//  2)  System creates an instance of the extension class
//      and calls `didReceive` in the background
//  3)  Extension processes messages / displays whatever
//      notifications it needs to
//  4)  Extension notifies its work is complete by calling
//      the contentHandler
//  5)  If the extension takes too long to perform its work
//      (more than 30s), it will be notified and immediately
//      terminated
//
// Note that the NSE does *not* always spawn a new process to
// handle a new notification and will also try and process notifications
// in parallel. `didReceive` could be called twice for the same process,
// but it will always be called on different threads. It may or may not be
// called on the same instance of `NotificationService` as a previous
// notification.

class NotificationServiceExtension: UNNotificationServiceExtension {
    private static var targetConfiguration: Target.ConfigurationResult?
    private let settings: CommonSettingsProtocol = AppSettings()
    private let appHooks: AppHooks

    /// Сага пустых плашек (20.07): didReceive приходит ПАРАЛЛЕЛЬНО на том же инстансе —
    /// одно поле notificationHandler затиралось вторым пушем, и expiration затёртого
    /// становился молчаливым no-op → iOS показывала СЫРОЙ eventIdOnly payload (пустая
    /// плашка). Теперь реестр по request.identifier + гарантированный фолбэк.
    private struct PendingRequest {
        let contentHandler: (UNNotificationContent) -> Void
        let fallbackContent: UNNotificationContent
        var handler: NotificationHandler?
    }

    private var pendingRequests: [String: PendingRequest] = [:]
    private let pendingLock = NSLock()

    // Кэш NSEUserSession между пушами одного процесса (ключ: userID). Полный клиент
    // (3 SQLCipher-стора + OlmMachine) на КАЖДЫЙ пуш съедал бюджет NSE и вёл к
    // системным киллам по времени → iOS переставала запускать NSE (мёртвые зоны).
    private static var cachedSessions: [String: NSEUserSession] = [:]
    private static let sessionLock = NSLock()

    private let keychainController = KeychainController(service: .sessions,
                                                        accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    
    private var cancellables: Set<AnyCancellable> = []
    
    /// We can make the whole NSE a MainActor after https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md
    /// otherwise we wouldn't be able to log the tag in the deinit.
    deinit {
        ExtensionLogger.logMemory(with: tag)
        MXLog.info("\(tag) deinit")
    }
    
    override init() {
        appHooks = AppHooks()
        appHooks.setUp()
        
        if Self.targetConfiguration == nil {
            Self.targetConfiguration = Target.nse.configure(logLevel: settings.logLevel,
                                                            traceLogPacks: settings.traceLogPacks,
                                                            sentryURL: nil,
                                                            rageshakeURL: settings.bugReportRageshakeURL,
                                                            appHooks: appHooks)
        }
        
        super.init()
    }
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let requestID = request.identifier
        registerPending(requestID,
                        contentHandler: contentHandler,
                        fallback: Self.makeFallbackContent(from: request.content))
        Task { await handle(request, requestID: requestID) }
    }

    private func handle(_ request: UNNotificationRequest, requestID: String) async {
        // Бюджет NSE ~30с от didReceive: дедлайн фетча 24с оставляет ~6с на
        // финализацию/generic вне зависимости от стоимости инита сессии.
        let fetchDeadline = Date().addingTimeInterval(24)
        // Единственная точка доставки: снимает запрос с реестра; повторная доставка
        // (expiration vs штатное завершение) невозможна.
        let contentHandler: (UNNotificationContent) -> Void = { [weak self] content in
            guard let entry = self?.unregisterPending(requestID) else { return }
            entry.contentHandler(content)
        }
        let isDeviceLocked = DataProtectionManager.isDeviceLockedAfterReboot(containerURL: URL.appGroupContainerDirectory)
        let roomID = request.content.roomID
        let eventID = request.content.eventID
        let clientID = request.content.pusherNotificationClientIdentifier
        let credentials = clientID.flatMap { id in
            keychainController.restorationTokens().first(where: { $0.restorationToken.pusherNotificationClientIdentifier == id })
        }

        let allTokens = keychainController.restorationTokens()
        os_log(.default, log: nseLog, "NSE handle: locked=%{public}d room=%{public}@ event=%{public}@ clientID=%{public}@ storedTokens=%d",
               isDeviceLocked, roomID ?? "nil", eventID ?? "nil", clientID ?? "nil", allTokens.count)
        for (idx, t) in allTokens.enumerated() {
            os_log(.default, log: nseLog, "NSE token[%d]: userID=%{public}@ pusherClientID=%{public}@",
                   idx, t.userID, t.restorationToken.pusherNotificationClientIdentifier ?? "nil")
        }
        os_log(.default, log: nseLog, "NSE payload keys: %{public}@",
               (request.content.userInfo.keys.map { String(describing: $0) }).joined(separator: ", "))

        // Badge update (room:None, event:None) — не показываем уведомление.
        // STMOB-94: используем passive helper, иначе iOS 26+ берёт alert
        // из оригинального APNS payload и показывает baseline-баннер.
        if eventID == nil {
            os_log(.default, log: nseLog, "NSE: no eventID (badge update), suppressing notification")
            return contentHandler(NotificationHandler.makePassiveContent())
        }

        // STMOB-266: «тихое» уведомление о начавшемся звонке (intent=silent).
        // Обрабатываем ДО подъёма сессии: SDK по этим типам контента не даёт
        // (contentType=nil → пустая плашка), а тут ничего расшифровывать и не надо —
        // всё нужное лежит в payload. Заодно работает на залоченном девайсе.
        // Ring сюда не попадает: его берёт VoIP-пушер → CallKit.
        if let notice = CallNoticePayload(userInfo: request.content.userInfo) {
            os_log(.default, log: nseLog, "NSE call-notice: room=%{public}@ caller=%{public}@",
                   notice.roomID, notice.callerName)
            guard CallNoticeGate.shouldShow(notice) else {
                return contentHandler(NotificationHandler.makePassiveContent())
            }
            DiagLog.write("NSE", "  call-notice → показываем баннер room=\(notice.roomID)")
            return contentHandler(notice.makeContent(receiverID: credentials?.userID))
        }

        // If we can't fully process, at least show a useful fallback notification
        guard !isDeviceLocked, let roomID, let eventID, let clientID, let credentials else {
            os_log(.error, log: nseLog, "NSE fallback: locked=%{public}d room=%{public}@ event=%{public}@ clientID=%{public}@ credentialsFound=%{public}d",
                   isDeviceLocked, roomID ?? "nil", eventID ?? "nil", clientID ?? "nil", credentials != nil ? 1 : 0)
            if let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent {
                mutableContent.title = "sTalk"
                mutableContent.body = "Новое сообщение"
                // Preserve room_id for tap navigation
                if let roomID {
                    mutableContent.roomID = roomID
                }
                // Set receiver_id from first available credentials so tap works
                if let firstCreds = keychainController.restorationTokens().first {
                    mutableContent.receiverID = firstCreds.userID
                }
                return contentHandler(mutableContent)
            }
            return contentHandler(request.content)
        }

        let homeserverURL = credentials.restorationToken.session.homeserverUrl
        await appHooks.remoteSettingsHook.loadCache(forHomeserver: homeserverURL, applyingTo: settings)

        guard let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }

        MXLog.info("\(tag) #########################################")

        ExtensionLogger.logMemory(with: tag)

        os_log(.default, log: nseLog, "NSE processing: homeserver=%{public}@ room=%{public}@", homeserverURL, roomID)

        do {
            let userSession: NSEUserSession
            if let cached = Self.cachedSession(for: credentials.userID) {
                userSession = cached
                os_log(.default, log: nseLog, "NSE session cache HIT user=%{public}@", credentials.userID)
            } else {
                userSession = try await NSEUserSession(credentials: credentials,
                                                       roomID: roomID,
                                                       clientSessionDelegate: keychainController,
                                                       appHooks: appHooks,
                                                       appSettings: settings)
                Self.cacheSession(userSession, for: credentials.userID)
                os_log(.default, log: nseLog, "NSE session cache MISS — built OK")
            }

            let handler = NotificationHandler(userSession: userSession,
                                              settings: settings,
                                              contentHandler: contentHandler,
                                              notificationContent: mutableContent,
                                              tag: tag,
                                              fetchDeadline: fetchDeadline)
            setPendingHandler(requestID, handler)

            ExtensionLogger.logMemory(with: tag)
            MXLog.info("\(tag) Configured user session")

            await handler.processEvent(eventID, roomID: roomID)
        } catch {
            os_log(.error, log: nseLog, "NSE session FAILED: %{public}@", String(describing: error))
            // Fallback: show basic notification even if session fails
            mutableContent.title = "sTalk"
            mutableContent.body = "Новое сообщение"
            if mutableContent.roomID == nil { mutableContent.roomID = roomID }
            contentHandler(mutableContent)
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Для каждого незавершённого запроса: хендлер есть → его грациозный
        // expiration (сам отдаст контент, once-гард внутри); хендлера нет (инит
        // сессии не успел) → НЕМЕДЛЕННО фолбэк. Раньше nil-хендлер = молчаливый
        // no-op → сырой payload = пустая плашка.
        for (id, entry) in snapshotPending() {
            if let handler = entry.handler {
                handler.handleTimeExpiration()
            } else if let entry = unregisterPending(id) {
                os_log(.error, log: nseLog, "NSE expire with NO handler → fallback")
                entry.contentHandler(entry.fallbackContent)
            }
        }
    }

    // MARK: - Pending registry / session cache

    private func registerPending(_ id: String, contentHandler: @escaping (UNNotificationContent) -> Void, fallback: UNNotificationContent) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingRequests[id] = PendingRequest(contentHandler: contentHandler, fallbackContent: fallback, handler: nil)
    }

    private func setPendingHandler(_ id: String, _ handler: NotificationHandler) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingRequests[id]?.handler = handler
    }

    @discardableResult
    private func unregisterPending(_ id: String) -> PendingRequest? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequests.removeValue(forKey: id)
    }

    private func snapshotPending() -> [String: PendingRequest] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequests
    }

    private static func cachedSession(for userID: String) -> NSEUserSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return cachedSessions[userID]
    }

    private static func cacheSession(_ session: NSEUserSession, for userID: String) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        cachedSessions[userID] = session
    }

    /// Фолбэк «не молчим никогда»: текст вместо сырого payload, room_id сохранён для тапа.
    private static func makeFallbackContent(from original: UNNotificationContent) -> UNNotificationContent {
        guard let mutable = original.mutableCopy() as? UNMutableNotificationContent else {
            return original
        }
        let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        mutable.title = "sTalk"
        mutable.body = isRussian ? "Новое сообщение" : "New message"
        mutable.sound = .default
        return mutable
    }
    
    // MARK: - Private
    
    private var tag: String {
        "[NSE][\(Unmanaged.passUnretained(self).toOpaque())][\(Unmanaged.passUnretained(Thread.current).toOpaque())][\(ProcessInfo.processInfo.processIdentifier)]"
    }
}
