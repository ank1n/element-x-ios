//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

private let meetingsLog = OSLog(subsystem: "ru.implica.stalk", category: "Meetings")

// MARK: - Models

enum MeetingStatus: String, Codable, Equatable {
    case scheduled
    case active
    case completed
    case cancelled
}

enum RSVPStatus: String, Codable, Equatable {
    case accepted
    case declined
    case pending
}

struct Meeting: Identifiable, Equatable, Codable {
    let id: Int
    var title: String
    let description: String
    let creatorId: String
    let matrixRoomId: String?
    let meetingCode: String?
    let location: String
    let startTime: Date
    let endTime: Date
    let isIndefinite: Bool
    let accessLevel: String
    let recordingAccess: String?
    var status: MeetingStatus
    let createdAt: Date?
    let updatedAt: Date?
    let participants: [MeetingParticipant]
    let attachments: [MeetingAttachment]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, location, status, participants, attachments
        case creatorId = "creator_id"
        case matrixRoomId = "matrix_room_id"
        case meetingCode = "meeting_code"
        case startTime = "start_time"
        case endTime = "end_time"
        case isIndefinite = "is_indefinite"
        case accessLevel = "access_level"
        case recordingAccess = "recording_access"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isUpcoming: Bool {
        status == .scheduled && startTime > Date()
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(startTime)
    }

    var isPast: Bool {
        endTime < Date()
    }
}

struct MeetingParticipant: Identifiable, Equatable, Codable {
    let userId: String
    let rsvp: RSVPStatus

    var id: String { userId }

    var displayName: String {
        let name = userId
            .replacingOccurrences(of: "@", with: "")
            .components(separatedBy: ":").first ?? userId
        return name.replacingOccurrences(of: "__oidc_", with: "")
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case rsvp
    }
}

struct MeetingAttachment: Identifiable, Equatable, Codable {
    let id: Int
    let filename: String
    let url: String
}

struct MeetingsListResponse: Codable {
    let meetings: [Meeting]
}

struct HolidaysResponse: Codable {
    let holidays: [String]
}

struct MeetingRequest: Encodable {
    let title: String
    var description: String = ""
    let startTime: Date
    let endTime: Date
    var isIndefinite: Bool = false
    var location: String = ""
    var participants: [String] = []
    var accessLevel: String = "private"

    enum CodingKeys: String, CodingKey {
        case title, description, location, participants
        case startTime = "start_time"
        case endTime = "end_time"
        case isIndefinite = "is_indefinite"
        case accessLevel = "access_level"
    }
}

// MARK: - Service

class MeetingsService {
    private let homeserver: String
    private let accessToken: String

    let meetingsSubject = CurrentValueSubject<[Meeting], Never>([])

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = dateFormatter.date(from: str) { return date }
            if let date = dateFormatterNoFrac.date(from: str) { return date }
            // Try "yyyy-MM-dd HH:mm:ss" format
            let simple = DateFormatter()
            simple.dateFormat = "yyyy-MM-dd HH:mm:ss"
            simple.timeZone = TimeZone(identifier: "UTC")
            if let date = simple.date(from: str) { return date }
            // Try with +00 timezone
            let tz = DateFormatter()
            tz.dateFormat = "yyyy-MM-dd HH:mm:ssxxx"
            if let date = tz.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(str)")
        }
        return d
    }()

    init(homeserver: String, accessToken: String) {
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessToken = accessToken
        os_log(.info, log: meetingsLog, "MeetingsService init: homeserver=%{public}@", self.homeserver)
    }

    func fetchMeetings() async {
        guard let url = URL(string: "\(homeserver)/api/meetings") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                os_log(.error, log: meetingsLog, "fetchMeetings: HTTP %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return
            }

            let decoded = try Self.decoder.decode(MeetingsListResponse.self, from: data)
            let relevant = decoded.meetings.filter { $0.status != .cancelled }
            os_log(.info, log: meetingsLog, "fetchMeetings: %d meetings (%d relevant)", decoded.meetings.count, relevant.count)
            meetingsSubject.send(relevant)
        } catch {
            os_log(.error, log: meetingsLog, "fetchMeetings error: %{public}@", error.localizedDescription)
        }
    }

    /// Fetch meetings and return them (for calendar screen)
    func fetchMeetingsList() async throws -> [Meeting] {
        guard let url = URL(string: "\(homeserver)/api/meetings") else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(MeetingsListResponse.self, from: data).meetings
    }

    func fetchMeeting(id: Int) async throws -> Meeting {
        guard let url = URL(string: "\(homeserver)/api/meetings/\(id)") else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    func createMeeting(_ body: MeetingRequest) async throws -> Meeting {
        let data = try await apiRequest("POST", path: "/api/meetings", body: Self.encoder.encode(body))
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    func updateMeeting(id: Int, _ body: MeetingRequest) async throws -> Meeting {
        let data = try await apiRequest("PUT", path: "/api/meetings/\(id)", body: Self.encoder.encode(body))
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    func deleteMeeting(id: Int) async throws {
        _ = try await apiRequest("DELETE", path: "/api/meetings/\(id)")
    }

    func rsvp(meetingId: Int, status: RSVPStatus) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["rsvp": status.rawValue])
        _ = try await apiRequest("PUT", path: "/api/meetings/\(meetingId)/rsvp", body: body)
    }

    func fetchHolidays() async throws -> [String] {
        let data = try await apiRequest("GET", path: "/api/meetings/holidays")
        return try Self.decoder.decode(HolidaysResponse.self, from: data).holidays
    }

    // Legacy RSVP (for CallsListScreen compatibility)
    func rsvp(meetingId: Int, response rsvpResponse: String) async -> Bool {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["rsvp": rsvpResponse])
            _ = try await apiRequest("PUT", path: "/api/meetings/\(meetingId)/rsvp", body: body)
            os_log(.info, log: meetingsLog, "RSVP %{public}@ for meeting %d", rsvpResponse, meetingId)
            return true
        } catch {
            os_log(.error, log: meetingsLog, "rsvp error: %{public}@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Private

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fmt.string(from: date))
        }
        return e
    }()

    private func apiRequest(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(homeserver)\(path)") else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            os_log(.error, log: meetingsLog, "%{public}@ %{public}@ => HTTP %d", method, path, (response as? HTTPURLResponse)?.statusCode ?? -1)
            throw URLError(.badServerResponse)
        }
        return data
    }
}
