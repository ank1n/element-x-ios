//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import os.log
import UIKit
import UserNotifications

private let pushLog = OSLog(subsystem: "ru.implica.stalk", category: "Push")

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
                guard let roomID = notification.request.content.roomID,
                      let lastMessageDate = roomsToLastMessageDates[roomID] else {
                    return false
                }
                    
                return notification.date <= lastMessageDate
            }
            .map(\.request.identifier)
        
        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)
    }

    private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        let pushkey = deviceToken.base64EncodedString()
        let appId = appSettings.pusherAppID
        let gateway = appSettings.pushGatewayNotifyEndpoint.absoluteString
        os_log(.info, log: pushLog, "setPusher: pushkey=%{public}@, appId=%{public}@, gateway=%{public}@", pushkey, appId, gateway)

        do {
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
            try await clientProxy.setPusher(with: configuration)
            os_log(.info, log: pushLog, "setPusher SUCCEEDED — pusher registered with server")
            MXLog.info("Set pusher succeeded")
            DiagLog.write("APNS", "setPusher OK appId=\(appId) format=eventIdOnly")
            return true
        } catch {
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
