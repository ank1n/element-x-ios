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

struct Meeting: Identifiable, Equatable, Codable {
    let id: Int
    let title: String
    let description: String?
    let creatorId: String
    let matrixRoomId: String?
    let meetingCode: String?
    let location: String?
    let startTime: Date
    let endTime: Date?
    let isIndefinite: Bool
    let accessLevel: String
    let status: String
    let participants: [MeetingParticipant]

    enum CodingKeys: String, CodingKey {
        case id, title, description, location, status, participants
        case creatorId = "creator_id"
        case matrixRoomId = "matrix_room_id"
        case meetingCode = "meeting_code"
        case startTime = "start_time"
        case endTime = "end_time"
        case isIndefinite = "is_indefinite"
        case accessLevel = "access_level"
    }

    var isUpcoming: Bool {
        status == "scheduled" && startTime > Date()
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(startTime)
    }

    var isPast: Bool {
        if let endTime {
            return endTime < Date()
        }
        return startTime < Date()
    }
}

struct MeetingParticipant: Equatable, Codable {
    let userId: String
    let rsvp: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case rsvp
    }
}

struct MeetingsListResponse: Codable {
    let meetings: [Meeting]
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
            // Filter out cancelled, keep upcoming + today's
            let relevant = decoded.meetings.filter { $0.status != "cancelled" }
            os_log(.info, log: meetingsLog, "fetchMeetings: %d meetings (%d relevant)", decoded.meetings.count, relevant.count)
            meetingsSubject.send(relevant)
        } catch {
            os_log(.error, log: meetingsLog, "fetchMeetings error: %{public}@", error.localizedDescription)
        }
    }

    func rsvp(meetingId: Int, response rsvpResponse: String) async -> Bool {
        guard let url = URL(string: "\(homeserver)/api/meetings/\(meetingId)/rsvp") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["rsvp": rsvpResponse])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                os_log(.error, log: meetingsLog, "rsvp: HTTP %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["success"] as? Bool == true {
                os_log(.info, log: meetingsLog, "RSVP %{public}@ for meeting %d", rsvpResponse, meetingId)
                return true
            }
            return false
        } catch {
            os_log(.error, log: meetingsLog, "rsvp error: %{public}@", error.localizedDescription)
            return false
        }
    }
}
