// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import UserNotifications

/// Native notifications mirror the web's five-minute venue reminder, using the
/// existing meetings refresh. The server alone records presence and releases rooms.
enum MeetingVenueReminder {
    static let prefix = "stalk.venue."
    static func userPrefix(_ userID: String) -> String {
        prefix + SHA256.hash(data: Data(userID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + "."
    }

    static func cancel(meetingID: Int, userID: String, center: UserNotificationCenterProtocol = UNUserNotificationCenter.current()) async {
        let prefix = userPrefix(userID) + String(meetingID) + "."
        let pending = await center.pendingVenueNotificationRequests()
        center.removePendingVenueNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
    }

    private static func eligible(meetings: [Meeting], userID: String, now: Date) -> [Meeting] {
        guard !userID.isEmpty else { return [] }
        return meetings.filter { meeting in
            guard meeting.status != .cancelled, let room = meeting.room, room.status == "confirmed",
                  room.checked_in_at == nil, room.checkin?.checked_in_at == nil, room.ended_early_at == nil,
                  let deadline = MeetingVenueStrings.date(room.checkin_deadline ?? room.checkin?.deadline), deadline > now else { return false }
            return meeting.creatorId == userID || meeting.participants.contains { $0.userId == userID && $0.rsvp != .declined }
        }.sorted { $0.startTime < $1.startTime }.prefix(24).map { $0 }
    }

    private static func identifier(_ meeting: Meeting, userID: String) -> String {
        userPrefix(userID) + String(meeting.id) + "." + String(Int64(meeting.startTime.timeIntervalSince1970))
    }

    static func identifiersToKeep(meetings: [Meeting], userID: String, now: Date) -> Set<String> {
        Set(eligible(meetings: meetings, userID: userID, now: now).map { identifier($0, userID: userID) })
    }

    static func requests(meetings: [Meeting], userID: String, now: Date) -> [UNNotificationRequest] {
        eligible(meetings: meetings, userID: userID, now: now).compactMap { meeting -> UNNotificationRequest? in
            guard let room = meeting.room else { return nil }
            let delay = meeting.startTime.addingTimeInterval(-300).timeIntervalSince(now)
            guard delay > 0 else { return nil }
            let content = UNMutableNotificationContent()
            content.title = MeetingVenueStrings.text("checkin") + " · " + room.displayName
            content.body = meeting.title
            content.categoryIdentifier = NotificationConstants.Category.venueCheckin
            content.sound = .default
            content.userInfo = [NotificationConstants.UserInfoKey.meetingIdentifier: meeting.id,
                                NotificationConstants.UserInfoKey.receiverIdentifier: userID]
            if let roomID = meeting.matrixRoomId { content.userInfo[NotificationConstants.UserInfoKey.roomIdentifier] = roomID }
            content.threadIdentifier = userPrefix(userID)
            return UNNotificationRequest(identifier: identifier(meeting, userID: userID), content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        }
    }
}
