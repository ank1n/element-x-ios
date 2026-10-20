// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct MeetingVenue: Codable, Equatable, Identifiable {
    let id: Int
    var name: String?
    var label: String?
    var floor: String?
    var office_id: Int?
    var office_name: String?
    var photo_mxc: String?
    var status: String?
    var start: String?
    var end: String?
    var checkin_deadline: String?
    var checked_in_at: String?
    var ended_early_at: String?
    var checkin: Checkin?
    struct Checkin: Codable, Equatable {
        var opens_at: String
        var deadline: String?
        var checked_in_at: String?
        var via: String?
    }

    func canCheckIn(now: Date, meeting: Meeting) -> Bool {
        guard status == "confirmed", ended_early_at == nil,
              checkin?.checked_in_at == nil, checked_in_at == nil,
              checkin?.deadline != nil || checkin_deadline != nil else { return false }
        let start = MeetingVenueStrings.date(start) ?? meeting.startTime
        let end = MeetingVenueStrings.date(end) ?? meeting.endTime
        return now >= (MeetingVenueStrings.date(checkin?.opens_at) ?? start.addingTimeInterval(-900)) && now < end && meeting.status != .cancelled
    }

    func canRelease(now: Date, meeting: Meeting, userID: String) -> Bool {
        guard ended_early_at == nil, meeting.status != .cancelled else { return false }
        let start = MeetingVenueStrings.date(start) ?? meeting.startTime
        let end = MeetingVenueStrings.date(end) ?? meeting.endTime
        return now < end && (meeting.creatorId == userID || now >= start.addingTimeInterval(60))
    }

    var displayName: String {
        name ?? label ?? String(id)
    }

    var statusDescription: String {
        guard let status, ["pending", "confirmed"].contains(status) else { return "" }
        return " · " + MeetingVenueStrings.text(status)
    }
}

struct MeetingVenueOffice: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
}

struct MeetingVenueRoom: Decodable, Identifiable, Equatable {
    struct Busy: Decodable, Equatable {
        let start: String
        let end: String
        let mine: Bool?
        let meeting_id: Int?
    }

    let id: Int
    let name: String
    let office_id: Int?
    let office_name: String?
    let floor: String?
    let capacity: Int?
    let equipment: [String]?
    let photo_mxc: String?
    let can_book: Bool
    let busy: [Busy]
    func conflicts(excluding id: Int?) -> [Busy] {
        busy.filter { !($0.mine == true && id != nil && $0.meeting_id == id) }
    }
}

struct MeetingVenueError: LocalizedError {
    let status: Int
    let code: String
    var conflicts: [MeetingVenueRoom.Busy] = []
    var errorDescription: String? {
        let key: String
        switch code {
        case "room_busy": key = "busy_error"
        case "room_forbidden": key = "forbidden"
        case "room_needs_end": key = "needs_end"
        case "rooms_disabled": key = "disabled"
        case "forbidden": key = "participants_only"
        case "only_organizer": key = "organizer_only"
        case "no_room", "nothing_to_release": key = "no_booking"
        case "checkin_closed": key = "checkin_closed"
        default: return L10n.commonSomethingWentWrong
        }
        let intervals = conflicts.map { MeetingVenueStrings.interval(start: $0.start, end: $0.end) }.joined(separator: "\n")
        return MeetingVenueStrings.text(key) + (intervals.isEmpty ? "" : "\n" + intervals)
    }
}

struct MeetingVenueReleased: Codable, Equatable {
    let id: Int
    let label: String
    let reason: String
    let at: String
}

struct MeetingVenueActionState: Decodable {
    let room: MeetingVenue?
    let room_released: MeetingVenueReleased?
}

enum MeetingVenueStrings {
    static func photoURL(_ raw: String?) -> URL? {
        guard let raw, raw.count < 2048, raw.range(of: #"^mxc://[^/\s]+/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: raw), url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func interval(start: String, end: String) -> String {
        func local(_ raw: String) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return raw }
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return local(start) + " — " + local(end)
    }

    static func text(_ key: String) -> String {
        NSLocalizedString("stalk_venue_" + key, comment: "Meeting room")
    }
}
