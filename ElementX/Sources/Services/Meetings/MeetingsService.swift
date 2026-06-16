//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log
import SwiftUI

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
    var matrixRoomId: String?
    let meetingCode: String?
    let location: String
    let startTime: Date
    let endTime: Date
    let isIndefinite: Bool
    let accessLevel: String
    let recordingAccess: String?
    var status: MeetingStatus
    let colorLabel: String
    let createdAt: Date?
    let updatedAt: Date?
    let participants: [MeetingParticipant]
    let attachments: [MeetingAttachment]?

    /// Decode only known fields, ignore any extras from API
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        creatorId = try c.decodeIfPresent(String.self, forKey: .creatorId) ?? ""
        matrixRoomId = try c.decodeIfPresent(String.self, forKey: .matrixRoomId)
        meetingCode = try c.decodeIfPresent(String.self, forKey: .meetingCode)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        startTime = try c.decode(Date.self, forKey: .startTime)
        // STMOB-236: indefinite meetings come back with end_time = null. The model
        // keeps endTime non-optional (used in ~10 UI sites), so fall back to
        // startTime — a single null otherwise threw and broke the ENTIRE list
        // (e.g. @tymbay: 396 meetings, one indefinite → whole calendar empty).
        // Indefinite display is driven by the isIndefinite flag, not endTime.
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime) ?? startTime
        isIndefinite = try c.decodeIfPresent(Bool.self, forKey: .isIndefinite) ?? false
        accessLevel = try c.decodeIfPresent(String.self, forKey: .accessLevel) ?? "private"
        recordingAccess = try c.decodeIfPresent(String.self, forKey: .recordingAccess)
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .scheduled
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel) ?? "green"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        participants = try c.decodeIfPresent([MeetingParticipant].self, forKey: .participants) ?? []
        attachments = try c.decodeIfPresent([MeetingAttachment].self, forKey: .attachments)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, location, status, participants, attachments
        case colorLabel = "color_label"
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

    /// Color from color_label (matches web LABEL_COLORS)
    var labelColor: Color {
        switch colorLabel {
        case "green": return Color(red: 0.05, green: 0.74, blue: 0.55) // #0DBD8B
        case "blue": return Color(red: 0.15, green: 0.39, blue: 0.92) // #2563EB
        case "purple": return Color(red: 0.55, green: 0.36, blue: 0.96) // #8B5CF6
        case "orange": return Color(red: 0.96, green: 0.62, blue: 0.04) // #F59E0B
        case "red": return Color(red: 0.94, green: 0.27, blue: 0.27) // #EF4444
        default: return Color(red: 0.05, green: 0.74, blue: 0.55) // green default
        }
    }

    var labelColorBg: Color {
        labelColor.opacity(0.06)
    }
}

struct MeetingParticipant: Identifiable, Equatable, Codable {
    let userId: String
    let rsvp: RSVPStatus

    var id: String {
        userId
    }

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
    let filename: String?
    let url: String?
}

struct MeetingsListResponse: Codable {
    let meetings: [Meeting]
}

struct HolidaysResponse: Codable {
    let holidays: [String]
}

struct MeetingRequest: Encodable {
    let title: String
    var description = ""
    let startTime: Date
    let endTime: Date
    var isIndefinite = false
    var location = ""
    var participants: [String] = []
    var accessLevel = "private"
    var meetingCode: String?

    enum CodingKeys: String, CodingKey {
        case title, description, location, participants
        case startTime = "start_time"
        case endTime = "end_time"
        case isIndefinite = "is_indefinite"
        case accessLevel = "access_level"
        case meetingCode = "meeting_code"
    }
}

// MARK: - Service

class MeetingsService {
    private let homeserver: String
    private let accessTokenProvider: () throws -> String

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

    /// Closure to force SDK token refresh (triggers a lightweight SDK request)
    private var forceTokenRefresh: (() async -> Void)?

    /// Initialize with a closure that returns a fresh access token each time.
    /// OIDC tokens expire frequently; calling matrixAccessToken() each request ensures we use a valid one.
    init(homeserver: String, accessTokenProvider: @escaping () throws -> String, forceTokenRefresh: (() async -> Void)? = nil) {
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh
        os_log(.default, log: meetingsLog, "MeetingsService init: homeserver=%{public}@", self.homeserver)
    }

    /// Convenience init with a static token (for legacy/testing use).
    convenience init(homeserver: String, accessToken: String) {
        self.init(homeserver: homeserver, accessTokenProvider: { accessToken })
    }

    private func currentAccessToken() throws -> String {
        try accessTokenProvider()
    }

    func fetchMeetings() async {
        guard let url = URL(string: "\(homeserver)/api/meetings") else { return }

        // Retry up to 2 times — first attempt may fail with 401 if token expired,
        // SDK will refresh it in background, second attempt uses fresh token.
        for attempt in 1...2 {
            guard let token = try? currentAccessToken() else { return }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

                if statusCode == 401, attempt < 2 {
                    os_log(.default, log: meetingsLog, "fetchMeetings: 401 — token expired, forcing SDK refresh...")
                    await forceTokenRefresh?()
                    continue
                }

                guard statusCode == 200 else {
                    os_log(.error, log: meetingsLog, "fetchMeetings: HTTP %d", statusCode)
                    return
                }

                let decoded = try Self.decoder.decode(MeetingsListResponse.self, from: data)
                let relevant = decoded.meetings.filter { $0.status != .cancelled }
                os_log(.default, log: meetingsLog, "fetchMeetings: %d meetings (%d relevant)", decoded.meetings.count, relevant.count)
                meetingsSubject.send(relevant)
                return
            } catch {
                os_log(.error, log: meetingsLog, "fetchMeetings error: %{public}@", error.localizedDescription)
                return
            }
        }
    }

    /// Fetch meetings and return them (for calendar screen)
    func fetchMeetingsList() async throws -> [Meeting] {
        let urlStr = "\(homeserver)/api/meetings"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }

        os_log(.default, log: meetingsLog, "fetchMeetingsList: GET %{public}@", urlStr)
        DiagLog.write("Meetings", "GET \(urlStr)")

        // Retry on 401 — token may be expired, SDK refreshes in background
        var data: Data!
        var statusCode = -1
        for attempt in 1...2 {
            let token = try currentAccessToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (respData, response) = try await URLSession.shared.data(for: request)
            data = respData
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 401, attempt < 2 {
                os_log(.default, log: meetingsLog, "fetchMeetingsList: 401 — forcing SDK token refresh...")
                DiagLog.write("Meetings", "GET /api/meetings → HTTP 401, forcing token refresh + retry")
                await forceTokenRefresh?()
                continue
            }
            break
        }
        os_log(.default, log: meetingsLog, "fetchMeetingsList: HTTP %d, %d bytes", statusCode, data.count)
        DiagLog.write("Meetings", "GET /api/meetings → HTTP \(statusCode), \(data.count)B")

        if statusCode != 200 {
            if let body = String(data: data.prefix(500), encoding: .utf8) {
                os_log(.error, log: meetingsLog, "fetchMeetingsList: body=%{public}@", body)
            }
            throw URLError(.badServerResponse)
        }
        do {
            let meetings = try Self.decoder.decode(MeetingsListResponse.self, from: data).meetings
            os_log(.default, log: meetingsLog, "fetchMeetingsList: decoded %d meetings", meetings.count)
            DiagLog.write("Meetings", "decoded \(meetings.count) meetings")
            return meetings
        } catch {
            // Try to decode first meeting individually to find exact field
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["meetings"] as? [[String: Any]],
               let first = arr.first {
                let keys = first.keys.sorted().joined(separator: ", ")
                os_log(.error, log: meetingsLog, "fetchMeetingsList: first meeting keys: %{public}@", keys)
                // Try decoding just the first one
                do {
                    let firstData = try JSONSerialization.data(withJSONObject: first)
                    _ = try Self.decoder.decode(Meeting.self, from: firstData)
                    os_log(.default, log: meetingsLog, "fetchMeetingsList: first meeting decoded OK individually")
                } catch {
                    os_log(.error, log: meetingsLog, "fetchMeetingsList: first meeting decode error: %{public}@", String(describing: error))
                }
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "binary"
            os_log(.error, log: meetingsLog, "fetchMeetingsList: decode error: %{public}@\nPreview: %{public}@", String(describing: error), preview)
            DiagLog.write("Meetings", "decode error: \(String(describing: error))")
            throw error
        }
    }

    func fetchMeeting(id: Int) async throws -> Meeting {
        guard let url = URL(string: "\(homeserver)/api/meetings/\(id)") else { throw URLError(.badURL) }

        let token = try currentAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        _ = try await apiRequest("POST", path: "/api/meetings/\(meetingId)/rsvp", body: body)
    }

    /// Ensure a Matrix room exists for a scheduled meeting (by meeting_code).
    /// Calls meet-api's /api/meet/ensure-room endpoint.
    func ensureRoom(code: String, userId: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "userId": userId])
        let data = try await apiRequest("POST", path: "/api/meet/ensure-room", body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roomId = json["roomId"] as? String, !roomId.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        os_log(.default, log: meetingsLog, "ensureRoom: code=%{public}@ → roomId=%{public}@", code, roomId)
        return roomId
    }

    func fetchHolidays() async throws -> [String] {
        let data = try await apiRequest("GET", path: "/api/meetings/holidays")
        return try Self.decoder.decode(HolidaysResponse.self, from: data).holidays
    }

    /// Legacy RSVP (for CallsListScreen compatibility)
    func rsvp(meetingId: Int, response rsvpResponse: String) async -> Bool {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["rsvp": rsvpResponse])
            _ = try await apiRequest("POST", path: "/api/meetings/\(meetingId)/rsvp", body: body)
            os_log(.default, log: meetingsLog, "RSVP %{public}@ for meeting %d", rsvpResponse, meetingId)
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

        // STMOB: retry once on 401 — OIDC access token may be stale (SDK refreshes
        // it in background for sync, but this custom endpoint can still hit an
        // expired snapshot). fetchMeetingsList already does this; create/update
        // went through here WITHOUT a refresh, so a stale token killed them
        // permanently. DiagLog so the tester diag dump shows the actual status.
        var data = Data()
        var statusCode = -1
        for attempt in 1...2 {
            let token = try currentAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            request.httpBody = body

            let (respData, response) = try await URLSession.shared.data(for: request)
            data = respData
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 401, attempt < 2 {
                DiagLog.write("Meetings", "\(method) \(path) → HTTP 401, forcing token refresh + retry")
                os_log(.default, log: meetingsLog, "%{public}@ %{public}@ => 401, refreshing token", method, path)
                await forceTokenRefresh?()
                continue
            }
            break
        }

        DiagLog.write("Meetings", "\(method) \(path) → HTTP \(statusCode), \(data.count)B")
        guard (200...299).contains(statusCode) else {
            os_log(.error, log: meetingsLog, "%{public}@ %{public}@ => HTTP %d", method, path, statusCode)
            throw URLError(.badServerResponse)
        }
        return data
    }
}
