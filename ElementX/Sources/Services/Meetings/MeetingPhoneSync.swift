// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import EventKit
import SwiftUI
import UserNotifications

// STMOB-333: встречи на самом телефоне.
// 1) Напоминания: сервер пуш не шлёт (веб сам опрашивает), поэтому iOS планирует локальные
//    уведомления по личной настройке напоминания каждой встречи (SMAIL-46).
// 2) Календарь iPhone: встречи копируются в отдельный календарь «sTalk», без своих будильников,
//    чтобы не было двойных напоминаний. Выключение убирает календарь целиком.

enum MeetingPhoneSettings {
    static let remindersKey = "stalk.meetings.phoneReminders"
    static let calendarKey = "stalk.meetings.calendarSync"

    static var remindersEnabled: Bool {
        UserDefaults.standard.object(forKey: remindersKey) as? Bool ?? true
    }

    static var calendarEnabled: Bool {
        UserDefaults.standard.bool(forKey: calendarKey)
    }
}

/// Действующие напоминания встречи: своя настройка, иначе — настройки календаря.
struct MeetingEffectiveReminders: Equatable {
    var minutesBefore: [Int]

    static func parse(_ json: [String: Any]) -> MeetingEffectiveReminders? {
        // Для встреч на весь день — другие правила (день и время), их на iOS не планируем.
        guard json["all_day"] as? Bool != true else { return nil }
        let source = json["custom"] as? Bool == true ? json["overrides"] : json["defaults"]
        let rows = (source as? [String: Any])?["timed_notifications"] as? [[String: Any]] ?? []
        let minutes = rows.compactMap { row -> Int? in
            guard row["channel"] as? String == "app" else { return nil }
            return (row["minutes_before"] as? NSNumber)?.intValue
        }
        return .init(minutesBefore: Array(Set(minutes)).sorted())
    }
}

@MainActor
final class MeetingPhoneSync {
    static let shared = MeetingPhoneSync()

    private static let notificationPrefix = "stalk.meetrem."
    private var cache: [Int: (value: MeetingEffectiveReminders?, at: Date)] = [:]
    private let eventStore = EKEventStore()
    private var generation = 0

    /// Сбросить кэш после смены настройки напоминания (на iOS или ради повторной сверки).
    func invalidate(meetingID: Int) {
        cache[meetingID] = nil
    }

    func sync(meetings: [Meeting], userID: String, service: MeetingsService) async {
        generation += 1
        let current = generation
        let mine = meetings.filter { meeting in
            meeting.status != .cancelled
                && (meeting.creatorId == userID || meeting.participants.contains { $0.userId == userID && $0.rsvp != .declined })
        }
        await syncReminders(mine, userID: userID, service: service, generation: current)
        await syncCalendar(mine, userID: userID)
    }

    // MARK: - Напоминания

    private static func userPrefix(_ userID: String) -> String {
        notificationPrefix + SHA256.hash(data: Data(userID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + "."
    }

    private func syncReminders(_ meetings: [Meeting], userID: String, service: MeetingsService, generation current: Int) async {
        let center = UNUserNotificationCenter.current()
        let prefix = Self.userPrefix(userID)
        let status = await center.notificationSettings().authorizationStatus
        let permitted = MeetingPhoneSettings.remindersEnabled && ServiceLocator.shared.settings.enableNotifications
            && (status == .authorized || status == .provisional)
        let now = Date()
        var requests: [UNNotificationRequest] = []
        if permitted {
            // Ближайшая неделя и не больше 24 встреч: настройки читаются по одной встрече.
            let upcoming = meetings.filter { $0.startTime > now && $0.startTime < now.addingTimeInterval(7 * 86400) }
                .sorted { $0.startTime < $1.startTime }.prefix(24)
            for meeting in upcoming {
                guard let reminders = await reminders(for: meeting.id, service: service) else { continue }
                for minutes in reminders.minutesBefore {
                    let fire = meeting.startTime.addingTimeInterval(-Double(minutes) * 60)
                    guard fire > now else { continue }
                    requests.append(request(meeting, minutes: minutes, fire: fire, now: now, userID: userID, prefix: prefix))
                }
            }
        }
        guard current == generation else { return }
        let keep = Set(requests.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !keep.contains($0) })
        let existing = Set(pending.map(\.identifier))
        for request in requests where !existing.contains(request.identifier) {
            try? await center.add(request)
        }
    }

    private func reminders(for meetingID: Int, service: MeetingsService) async -> MeetingEffectiveReminders? {
        if let cached = cache[meetingID], Date().timeIntervalSince(cached.at) < 600 { return cached.value }
        guard let json = try? await service.fetchReminderState(meetingID: meetingID) else { return cache[meetingID]?.value }
        let value = MeetingEffectiveReminders.parse(json)
        cache[meetingID] = (value, Date())
        return value
    }

    private func request(_ meeting: Meeting, minutes: Int, fire: Date, now: Date, userID: String, prefix: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = SL10n.meetingReminderNotificationTitle + ": " + meeting.title
        content.body = minutes == 0
            ? SL10n.meetingReminderNotificationNow
            : String(format: SL10n.meetingReminderNotificationAt, meeting.startTime.formatted(date: .omitted, time: .shortened))
        content.sound = SimulatorQASettings.isSilent ? nil : .default
        content.userInfo = [NotificationConstants.UserInfoKey.meetingIdentifier: meeting.id,
                            NotificationConstants.UserInfoKey.receiverIdentifier: userID]
        if let roomID = meeting.matrixRoomId { content.userInfo[NotificationConstants.UserInfoKey.roomIdentifier] = roomID }
        content.threadIdentifier = prefix
        // Время начала в идентификаторе: перенос встречи даёт новое уведомление, старое снимается.
        let identifier = prefix + "\(meeting.id).\(minutes).\(Int64(meeting.startTime.timeIntervalSince1970))"
        return UNNotificationRequest(identifier: identifier, content: content,
                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false))
    }

    // MARK: - Календарь iPhone

    private static let calendarIDKey = "stalk.meetings.calendarID"
    private static let eventsKey = "stalk.meetings.calendarEvents"

    /// Запросить доступ при включении настройки; `false` — доступа нет.
    func requestCalendarAccess() async -> Bool {
        await (try? eventStore.requestFullAccessToEvents()) ?? false
    }

    /// Выключение: календарь «sTalk» удаляется вместе со всеми его событиями.
    func removeCalendar() {
        defer {
            UserDefaults.standard.removeObject(forKey: Self.calendarIDKey)
            UserDefaults.standard.removeObject(forKey: Self.eventsKey)
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let id = UserDefaults.standard.string(forKey: Self.calendarIDKey), let calendar = eventStore.calendar(withIdentifier: id) else { return }
        do { try eventStore.removeCalendar(calendar, commit: true) } catch { MXLog.error("Meetings calendar: remove failed \(error)") }
    }

    private func calendar() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: Self.calendarIDKey), let calendar = eventStore.calendar(withIdentifier: id) {
            return calendar
        }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "sTalk"
        calendar.cgColor = UIColor(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1).cgColor
        // Локальный источник, иначе — источник календаря по умолчанию (iCloud и т.п.).
        calendar.source = eventStore.sources.first { $0.sourceType == .local } ?? eventStore.defaultCalendarForNewEvents?.source
        guard calendar.source != nil else { return nil }
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.calendarIDKey)
            return calendar
        } catch {
            MXLog.error("Meetings calendar: create failed \(error)")
            return nil
        }
    }

    private func syncCalendar(_ meetings: [Meeting], userID: String) async {
        guard MeetingPhoneSettings.calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess, let calendar = calendar() else { return }
        let now = Date()
        let window = meetings.filter { $0.endTime > now.addingTimeInterval(-86400) && $0.startTime < now.addingTimeInterval(60 * 86400) }
        // Сопоставление встреча → событие календаря, по учётке.
        let storeKey = Self.eventsKey + "." + userID
        var known = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        var seen = Set<String>()
        for meeting in window {
            let key = String(meeting.id)
            seen.insert(key)
            let event = known[key].flatMap { eventStore.event(withIdentifier: $0) } ?? EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = meeting.title
            event.startDate = meeting.startTime
            event.endDate = meeting.isIndefinite || meeting.endTime <= meeting.startTime ? meeting.startTime.addingTimeInterval(3600) : meeting.endTime
            event.location = meeting.room?.displayName ?? (meeting.location.isEmpty ? nil : meeting.location)
            event.notes = meeting.description.isEmpty ? nil : meeting.description
            event.alarms = nil
            do {
                try eventStore.save(event, span: .thisEvent, commit: false)
                known[key] = event.eventIdentifier
            } catch {
                MXLog.error("Meetings calendar: save failed \(error)")
            }
        }
        // Встречи, которых больше нет (отменены, отклонены, удалены), убираем из календаря.
        for (key, id) in known where !seen.contains(key) {
            if let event = eventStore.event(withIdentifier: id) {
                // Прошедшие встречи вне окна оставляем, как было в календаре.
                if event.endDate < now.addingTimeInterval(-86400) { continue }
                try? eventStore.remove(event, span: .thisEvent, commit: false)
            }
            known[key] = nil
        }
        do { try eventStore.commit() } catch { MXLog.error("Meetings calendar: commit failed \(error)") }
        UserDefaults.standard.set(known, forKey: storeKey)
    }
}

/// Раздел «Встречи» в настройках уведомлений.
struct MeetingPhoneSettingsSection: View {
    @AppStorage(MeetingPhoneSettings.remindersKey) private var reminders = true
    @AppStorage(MeetingPhoneSettings.calendarKey) private var calendar = false
    @State private var calendarDenied = false

    var body: some View {
        Section {
            Toggle(SL10n.meetingPhoneReminders, isOn: $reminders)
            Toggle(SL10n.meetingPhoneCalendar, isOn: Binding(get: { calendar }, set: { value in
                if value {
                    Task {
                        let granted = await MeetingPhoneSync.shared.requestCalendarAccess()
                        calendar = granted
                        calendarDenied = !granted
                        if granted { NotificationCenter.default.post(name: .stalkMeetingPhoneSettingsChanged, object: nil) }
                    }
                } else {
                    calendar = false
                    MeetingPhoneSync.shared.removeCalendar()
                }
            }))
        } header: {
            Text(SL10n.meetingPhoneSection)
        } footer: {
            Text(calendarDenied ? SL10n.meetingPhoneCalendarDenied : SL10n.meetingPhoneFooter)
        }
        .onChange(of: reminders) { NotificationCenter.default.post(name: .stalkMeetingPhoneSettingsChanged, object: nil) }
    }
}

extension Notification.Name {
    /// Настройки встреч на телефоне изменились — пересинхронизировать сразу, не дожидаясь обновления списка.
    static let stalkMeetingPhoneSettingsChanged = Notification.Name("stalkMeetingPhoneSettingsChanged")
}
