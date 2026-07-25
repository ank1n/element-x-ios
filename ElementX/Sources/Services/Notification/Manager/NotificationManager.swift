//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import os.log
import UIKit
import UserNotifications

private let pushLog = OSLog(subsystem: "ru.implica.stalk", category: "Push")

/// sTalk: STMOB-95 — локальная история pushkeys для (userID, app_id) в
/// UserDefaults. На каждом setPusher с новым pushkey мы вызываем deletePusher
/// для всех известных предыдущих pushkeys того же app_id, чтобы Synapse не
/// держал stale pushers (они дают fan-out push на каждый event и засоряют
/// sygnal). Sygnal встроенный auto-cleanup через BadDeviceToken срабатывает
/// не всегда — Apple часто возвращает success для zombie tokens.
enum PusherHistoryStorage {
    private static let userDefaultsKey = "stalk_pusher_history"

    static func recordedPushkeys(userID: String, appId: String) -> [String] {
        let dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [String: [String]]] ?? [:]
        return dict[userID]?[appId] ?? []
    }

    static func recordPushkey(_ pushkey: String, userID: String, appId: String) {
        var dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [String: [String]]] ?? [:]
        var perUser = dict[userID] ?? [:]
        var keys = perUser[appId] ?? []
        if !keys.contains(pushkey) { keys.append(pushkey) }
        perUser[appId] = keys
        dict[userID] = perUser
        UserDefaults.standard.set(dict, forKey: userDefaultsKey)
    }

    static func forgetPushkey(_ pushkey: String, userID: String, appId: String) {
        var dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [String: [String]]] ?? [:]
        guard var perUser = dict[userID] else { return }
        var keys = perUser[appId] ?? []
        keys.removeAll(where: { $0 == pushkey })
        perUser[appId] = keys
        dict[userID] = perUser
        UserDefaults.standard.set(dict, forKey: userDefaultsKey)
    }
}

final class NotificationManager: NSObject, NotificationManagerProtocol {
    private let notificationCenter: UserNotificationCenterProtocol
    private let appSettings: AppSettings
    
    private var userSession: UserSessionProtocol?
    
    private var cancellables = Set<AnyCancellable>()
    private var notificationsEnabled = false
    
    init(notificationCenter: UserNotificationCenterProtocol,
         appSettings: AppSettings) {
        self.notificationCenter = notificationCenter
        self.appSettings = appSettings
        super.init()
    }

    // MARK: NotificationManagerProtocol

    weak var delegate: NotificationManagerDelegate?
    
    func start() {
        let replyAction = UNTextInputNotificationAction(identifier: NotificationConstants.Action.inlineReply,
                                                        title: L10n.actionQuickReply,
                                                        options: [])
        let messageCategory = UNNotificationCategory(identifier: NotificationConstants.Category.message,
                                                     actions: [replyAction],
                                                     intentIdentifiers: [],
                                                     options: [])
        
        let inviteCategory = UNNotificationCategory(identifier: NotificationConstants.Category.invite,
                                                    actions: [],
                                                    intentIdentifiers: [],
                                                    options: [])
        notificationCenter.setNotificationCategories([messageCategory, inviteCategory])
        notificationCenter.delegate = self
        
        notificationsEnabled = appSettings.enableNotifications
        MXLog.info("App setting 'enableNotifications' is '\(notificationsEnabled)'")
        
        // sTalk: STMOB-90 — when SDK rotates Matrix device_id silently, the
        // regular pusher in Synapse still points at the dead old device. Ask
        // iOS for the APNS token again; UIApplication will fire the delegate
        // immediately on the cached token, which lands in register(with:) and
        // re-runs setPusher under the new device_id.
        NotificationCenter.default.addObserver(forName: .stalkMatrixDeviceIDChanged, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let newID = (note.userInfo?["newDeviceID"] as? String) ?? "?"
            DiagLog.write("APNS", "deviceID changed to \(newID) — re-registering APNS pusher")
            Task { @MainActor in
                self.delegate?.registerForRemoteNotifications()
            }
        }

        // sTalk: STMOB-90 — additional safety. Matrix setPusher is an upsert
        // on (pushkey, app_id), so re-issuing it on each foreground entry is
        // cheap. This catches the case where a device_id was already rotated
        // before build 94 was installed — no notification ever fires for that
        // historical change, but Synapse still has a stale pusher under the
        // dead old device_id.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            DiagLog.write("APNS", "willEnterForeground — refreshing APNS pusher (idempotent)")
            Task { @MainActor in
                self.delegate?.registerForRemoteNotifications()
            }
        }

        // Listen for changes to AppSettings.enableNotifications
        appSettings.$enableNotifications
            .sink { [weak self] newValue in
                self?.enableNotifications(newValue)
            }
            .store(in: &cancellables)
    }
        
    func requestAuthorization() {
        guard appSettings.enableNotifications, !userSession.isNil else { return }
        Task {
            do {
                let permissionGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                MXLog.info("Permission granted: \(permissionGranted)")
                await MainActor.run {
                    if permissionGranted {
                        self.delegate?.registerForRemoteNotifications()
                    }
                }
            } catch {
                MXLog.error("Request authorization failed: \(error)")
            }
        }
    }

    func register(with deviceToken: Data) async -> Bool {
        let tokenString = deviceToken.base64EncodedString()
        os_log(.info, log: pushLog, "register(with:) called, token=%{public}@", tokenString)
        DiagLog.write("APNS", "didRegisterForRemoteNotifications token=\(tokenString.prefix(16))…(len=\(deviceToken.count))")
        guard let userSession else {
            os_log(.error, log: pushLog, "register(with:) — userSession is nil, cannot set pusher!")
            DiagLog.write("APNS", "  userSession=nil → setPusher NOT called")
            return false
        }
        os_log(.info, log: pushLog, "register(with:) — calling setPusher...")
        return await setPusher(with: deviceToken, clientProxy: userSession.clientProxy)
    }

    func setUserSession(_ userSession: UserSessionProtocol?) {
        self.userSession = userSession
        os_log(.info, log: pushLog, "setUserSession called, session is %{public}@", userSession == nil ? "nil" : "present")

        // If notification permissions were given previously then attempt re-registering
        // for remote notifications on startup. Otherwise let the onboarding flow handle it
        Task { [weak self] in
            guard let self else { return }

            let status = await notificationCenter.authorizationStatus()
            let enabled = appSettings.enableNotifications
            os_log(.info, log: pushLog, "authorizationStatus=%{public}@, enableNotifications=%{public}@", "\(status.rawValue)", "\(enabled)")

            if status == .authorized, enabled {
                os_log(.info, log: pushLog, "Calling registerForRemoteNotifications()")
                await MainActor.run { [weak self] in
                    self?.delegate?.registerForRemoteNotifications()
                }
            } else if status == .notDetermined, enabled {
                os_log(.info, log: pushLog, "Permission not determined — requesting authorization")
                do {
                    let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                    os_log(.info, log: pushLog, "Authorization result: %{public}@", "\(granted)")
                    if granted {
                        await MainActor.run { [weak self] in
                            self?.delegate?.registerForRemoteNotifications()
                        }
                    }
                } catch {
                    os_log(.error, log: pushLog, "requestAuthorization failed: %{public}@", "\(error)")
                }
            } else {
                os_log(.info, log: pushLog, "NOT registering: status=%{public}@, enabled=%{public}@", "\(status.rawValue)", "\(enabled)")
            }

            let settings = await notificationCenter.notificationSettings()
            MXLog.info("Notification sound enabled: \(settings.soundSetting == .enabled)")
        }
    }

    func registrationFailed(with error: Error) {
        MXLog.error("Device token registration failed with error: \(error)")
    }

    func showLocalNotification(with title: String, subtitle: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        let request = UNNotificationRequest(identifier: ProcessInfo.processInfo.globallyUniqueString,
                                            content: content,
                                            trigger: nil)
        do {
            try await notificationCenter.add(request)
            MXLog.info("Show local notification succeeded")
        } catch {
            MXLog.error("Show local notification failed: \(error)")
        }
    }
    
    /// STMOB-234: выметает заглушки NSE (хвост звонка) из Центра уведомлений.
    /// В фоне `willPresent` не вызывается, поэтому пустая строка висит там до
    /// первого открытия приложения — здесь она уходит.
    func removeDeliveredPlaceholderNotifications() async {
        let identifiers = await notificationCenter
            .deliveredNotifications()
            .filter { notification in
                let content = notification.request.content
                return content.userInfo[NotificationConstants.UserInfoKey.suppressed] as? Bool == true ||
                    (content.title.isEmpty && content.subtitle.isEmpty && content.body.isEmpty)
            }
            .map(\.request.identifier)
        guard !identifiers.isEmpty else { return }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        MXLog.info("sTalk: removed \(identifiers.count) placeholder notification(s)")
    }

    func removeDeliveredMessageNotifications(for roomID: String) async {
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { $0.request.content.roomID == roomID }
            .map(\.request.identifier)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }
    
    func removeDeliveredNotificationsForFullyReadRooms(_ rooms: [RoomSummary]) async {
        let roomsToLastMessageDates = rooms
            .filter { $0.hasUnreadMessages == false }
            .reduce(into: [:]) { partialResult, roomSummary in
                partialResult[roomSummary.id] = roomSummary.lastMessageDate
            }
        
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { notification in
                // STMOB-234: заодно выметаем заглушки NSE (хвост звонка). В фоне
                // willPresent не вызывается, и пустая строка остаётся висеть в
                // Центре уведомлений — здесь она уйдёт при первом же обновлении
                // списка комнат.
                let content = notification.request.content
                if content.userInfo[NotificationConstants.UserInfoKey.suppressed] as? Bool == true ||
                    (content.title.isEmpty && content.subtitle.isEmpty && content.body.isEmpty) {
                    return true
                }

                guard let roomID = content.roomID,
                      let lastMessageDate = roomsToLastMessageDates[roomID] else {
                    return false
                }

                return notification.date <= lastMessageDate
            }
            .map(\.request.identifier)

        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }

    private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol, isRetry: Bool = false) async -> Bool {
        let pushkey = deviceToken.base64EncodedString()
        let appId = appSettings.pusherAppID
        // Multi-domain: the push gateway lives on the user's own server (uz/pics run their own
        // Sygnal) — registering the misty gateway there breaks their pushes (STMOB-153).
        let gateway = appSettings.pushGatewayNotifyEndpoint(forHomeserver: clientProxy.homeserver).absoluteString
        os_log(.info, log: pushLog, "setPusher: pushkey=%{public}@, appId=%{public}@, gateway=%{public}@", pushkey, appId, gateway)

        do {
            // ВНИМАНИЕ: alert.locKey должен быть существующим ключом локализации.
            // Build 66 пробовал несуществующий «stalk_silent_default» — Apple silently
            // дропает push без valid locKey, и regular chat сообщения тоже потерялись.
            // Откат на «Notification» — push delivery работает, но возвращаются лишние
            // «sTalk Уведомление» banner при NSE timeout / discard.
            //
            // Real fix лишних banner — server-side via Sygnal v7+ heuristics
            // (Molly STALK-202) или iOS rust-sdk migration на to-device (STALK-205).
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "Notification",
                                                                          locArgs: [])),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            // format: .eventIdOnly — Sygnal шлёт минимальный payload (event_id+room_id),
            // NSE сам decrypt/populate content через MatrixRustSDK. Build 53 перешёл на
            // full format чтобы filter в Sygnal видел type, но это сломало NSE banner:
            // Sygnal в full mode добавляет aps.alert.loc-key=MSG_FROM_USER, iOS показал raw.
            // Откат: eventIdOnly, price — Sygnal не может фильтровать call events по type
            // для regular pusher (но это приемлемо, call events всё равно в VoIP).
            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: pushkey,
                                                                                 appId: appId),
                                                              kind: .http(data: .init(url: gateway,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: pusherProfileTag(),
                                                              lang: Bundle.app.preferredLocalizations.first ?? "en")
            // STMOB-95: cleanup stale pushers того же app_id у юзера до
            // регистрации нового. Best-effort — если delete упал, всё равно
            // регистрируем новый. История хранится в UserDefaults per (userID, appId).
            let userID = clientProxy.userID
            let historicalKeys = PusherHistoryStorage.recordedPushkeys(userID: userID, appId: appId)
            let stalePushkeys = historicalKeys.filter { $0 != pushkey }
            for stalePushkey in stalePushkeys {
                do {
                    try await clientProxy.deletePusher(pushkey: stalePushkey, appId: appId)
                    PusherHistoryStorage.forgetPushkey(stalePushkey, userID: userID, appId: appId)
                    DiagLog.write("APNS", "  cleanup deleted stale pushkey=\(stalePushkey.prefix(16))…")
                } catch {
                    DiagLog.write("APNS", "  cleanup deletePusher FAILED for \(stalePushkey.prefix(16))…: \(error.localizedDescription)")
                }
            }

            try await clientProxy.setPusher(with: configuration)
            PusherHistoryStorage.recordPushkey(pushkey, userID: userID, appId: appId)
            os_log(.info, log: pushLog, "setPusher SUCCEEDED — pusher registered with server")
            MXLog.info("Set pusher succeeded")
            DiagLog.write("APNS", "setPusher OK appId=\(appId) format=eventIdOnly")
            return true
        } catch {
            // STMOB-212: MAS access tokens expire every ~15 min. On a stale token
            // (M_UNKNOWN_TOKEN) force the SDK to refresh and retry once — otherwise
            // the APNS pusher silently lapses and push notifications stop arriving.
            if !isRetry,
               let clientError = error as? ClientError,
               case .MatrixApi(_, let code, _, _) = clientError,
               code == "M_UNKNOWN_TOKEN" {
                DiagLog.write("APNS", "setPusher M_UNKNOWN_TOKEN → forceTokenRefresh + retry")
                await clientProxy.forceTokenRefresh()
                return await setPusher(with: deviceToken, clientProxy: clientProxy, isRetry: true)
            }
            os_log(.error, log: pushLog, "setPusher FAILED: %{public}@", "\(error)")
            MXLog.error("Set pusher failed: \(error)")
            DiagLog.write("APNS", "setPusher FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private func pusherProfileTag() -> String {
        if let currentTag = appSettings.pusherProfileTag {
            return currentTag
        }
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let newTag = (0..<16).map { _ in
            let offset = Int.random(in: 0..<chars.count)
            return String(chars[chars.index(chars.startIndex, offsetBy: offset)])
        }.joined()

        appSettings.pusherProfileTag = newTag
        return newTag
    }
    
    private func enableNotifications(_ enable: Bool) {
        guard notificationsEnabled != enable else { return }
        notificationsEnabled = enable
        MXLog.info("App setting 'enableNotifications' changed to '\(enable)'")
        if enable {
            requestAuthorization()
        } else {
            delegate?.unregisterForRemoteNotifications()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard appSettings.enableInAppNotifications else {
            return []
        }
        guard let delegate else {
            return [.badge, .sound, .list, .banner]
        }

        // STMOB-234 (dp, лог 144): «пустая плашка» после звонка. NSE распознал
        // E2EE-хвост звонка и отдал заглушку (contentHandler вызвать обязан —
        // отменить доставку из расширения нельзя), но приложение было в
        // форграунде, а roomID у заглушки нет → shouldDisplayInAppNotification
        // возвращал true, и iOS показывала пустой баннер и пустую строку в списке.
        // Опознаём по маркеру, поставленному в makePassiveContent.
        if notification.request.content.userInfo[NotificationConstants.UserInfoKey.suppressed] as? Bool == true {
            MXLog.info("sTalk: NSE placeholder notification suppressed")
            // Заодно подметаем заглушки, накопившиеся в фоне: там willPresent не
            // вызывается вовсе, и пустые строки висят в Центре уведомлений.
            await removeDeliveredPlaceholderNotifications()
            return []
        }

        guard delegate.shouldDisplayInAppNotification(content: notification.request.content) else {
            return []
        }

        return [.badge, .sound, .list, .banner]
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case NotificationConstants.Action.inlineReply:
            guard let response = response as? UNTextInputNotificationResponse else {
                return
            }
            await delegate?.handleInlineReply(self,
                                              content: response.notification.request.content,
                                              replyText: response.userText)
        case UNNotificationDefaultActionIdentifier:
            await delegate?.notificationTapped(content: response.notification.request.content)
        default:
            break
        }
    }
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol { }
