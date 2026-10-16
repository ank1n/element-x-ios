//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Service for searching message content via Matrix /search API
final class MessageSearchService {
    private let homeserverURL: String
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: (() async -> Void)?
    private let session: URLSession

    init(homeserverURL: String, accessTokenProvider: @escaping () throws -> String, forceTokenRefresh: (() async -> Void)? = nil, session: URLSession = .shared) {
        self.homeserverURL = homeserverURL
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh
        self.session = session
    }

    /// Same server-side message index as web; room scope is enforced by the server.
    /// Legacy Matrix search is used only when the endpoint is absent, never on auth/5xx failures.
    func searchMessages(query: String, roomID: String? = nil, nextBatch: String? = nil, limit: Int = 20) async throws -> MessageSearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .init(results: [], nextBatch: nil, totalCount: 0) }
        let limit = max(1, min(100, limit))
        let base = homeserverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if nextBatch == nil || nextBatch?.hasPrefix("stalk-offset:") == true {
            let offset = nextBatch.flatMap { Int($0.dropFirst("stalk-offset:".count)) } ?? 0
            guard offset >= 0, offset <= 10000 else { throw MessageSearchError.invalidResponse }
            var components = URLComponents(string: base + "/api/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "mode", value: "basic"),
                                      URLQueryItem(name: "type", value: "message"), URLQueryItem(name: "limit", value: String(limit)),
                                      URLQueryItem(name: "offset", value: String(offset))]
            if let roomID { components?.queryItems?.append(URLQueryItem(name: "room", value: roomID)) }
            guard let url = components?.url else { throw MessageSearchError.invalidURL }
            let (data, response) = try await request(URLRequest(url: url))
            if response.statusCode != 404 {
                guard response.statusCode == 200 else { throw MessageSearchError.serverError(response.statusCode) }
                if response.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
                    return try Self.parseSystemResponse(data, offset: offset, limit: limit)
                }
                // An unconfigured ingress may return the web app instead of JSON.
                guard nextBatch == nil else { throw MessageSearchError.invalidResponse }
            } else if nextBatch != nil { throw MessageSearchError.serverError(404) }
        }
        var filter: [String: Any] = ["limit": limit]
        if let roomID { filter["rooms"] = [roomID] }
        let body: [String: Any] = ["search_categories": ["room_events": ["search_term": query, "filter": filter,
                                                                         "order_by": "recent", "event_context": ["before_limit": 0, "after_limit": 0, "include_profile": true]]]]
        var components = URLComponents(string: base + "/_matrix/client/v3/search")
        if let nextBatch { components?.queryItems = [URLQueryItem(name: "next_batch", value: nextBatch)] }
        guard let url = components?.url else { throw MessageSearchError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await self.request(request)
        guard response.statusCode == 200 else { throw MessageSearchError.serverError(response.statusCode) }
        return try parseResponse(data)
    }

    private func request(_ original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = original
            let token = try accessTokenProvider()
            guard !token.isEmpty else { throw MessageSearchError.serverError(401) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MessageSearchError.invalidResponse }
            if response.statusCode == 401, attempt == 0, let forceTokenRefresh { await forceTokenRefresh(); continue }
            return (data, response)
        }
        throw MessageSearchError.serverError(401)
    }

    static func parseSystemResponse(_ data: Data, offset: Int, limit: Int) throws -> MessageSearchResponse {
        struct Target: Decodable { let kind: String; let room_id: String?; let event_id: String? }
        struct Metadata: Decodable { let room: String?; let author: String? }
        struct Hit: Decodable {
            let entity_type: String
            let target: Target?
            let title: String?
            let snippet: String?
            let created_at: String
            let meta: Metadata?
        }
        struct Response: Decodable { let results: [Hit]; let total: Int }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let date = ISO8601DateFormatter()
        let preciseDate = ISO8601DateFormatter()
        preciseDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let results = response.results.compactMap { hit -> MessageSearchResult? in
            guard hit.entity_type == "message", let target = hit.target, target.kind == "room",
                  let room = target.room_id, room.hasPrefix("!"), let event = target.event_id, event.hasPrefix("$") else { return nil }
            let snippet = (hit.snippet ?? hit.title ?? "").replacingOccurrences(of: "\u{0002}", with: "").replacingOccurrences(of: "\u{0003}", with: "")
            return .init(eventID: event, roomID: room, senderID: hit.meta?.author ?? "", senderDisplayName: hit.meta?.author ?? "",
                         body: snippet, timestamp: preciseDate.date(from: hit.created_at) ?? date.date(from: hit.created_at) ?? .distantPast,
                         roomName: hit.meta?.room)
        }
        let next = offset + response.results.count
        return .init(results: results, nextBatch: response.results.isEmpty || next >= response.total || next > 10000 ? nil : "stalk-offset:\(next)",
                     totalCount: response.total)
    }

    private func parseResponse(_ data: Data) throws -> MessageSearchResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["search_categories"] as? [String: Any],
              let roomEvents = categories["room_events"] as? [String: Any] else {
            throw MessageSearchError.invalidResponse
        }

        let totalCount = roomEvents["count"] as? Int ?? 0
        let nextBatch = roomEvents["next_batch"] as? String

        var results: [MessageSearchResult] = []

        if let searchResults = roomEvents["results"] as? [[String: Any]] {
            for item in searchResults {
                guard let result = item["result"] as? [String: Any],
                      let eventID = result["event_id"] as? String,
                      let roomID = result["room_id"] as? String,
                      let senderID = result["sender"] as? String,
                      let content = result["content"] as? [String: Any],
                      let body = content["body"] as? String else {
                    continue
                }

                let timestamp = result["origin_server_ts"] as? Int64 ?? 0
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)

                // Get sender display name from context profile
                var senderDisplayName: String?
                if let context = item["context"] as? [String: Any],
                   let profileInfo = context["profile_info"] as? [String: [String: Any]],
                   let senderProfile = profileInfo[senderID] {
                    senderDisplayName = senderProfile["displayname"] as? String
                }

                results.append(MessageSearchResult(eventID: eventID,
                                                   roomID: roomID,
                                                   senderID: senderID,
                                                   senderDisplayName: senderDisplayName ?? senderID,
                                                   body: body,
                                                   timestamp: date))
            }
        }

        return MessageSearchResponse(results: results, nextBatch: nextBatch, totalCount: totalCount)
    }
}

// MARK: - Models

struct MessageSearchResponse {
    let results: [MessageSearchResult]
    let nextBatch: String?
    let totalCount: Int
}

struct MessageSearchResult: Identifiable {
    let eventID: String
    let roomID: String
    let senderID: String
    let senderDisplayName: String
    let body: String
    let timestamp: Date
    var roomName: String?

    var id: String {
        eventID
    }
}

enum MessageSearchError: Error {
    case invalidURL
    case serverError(Int)
    case invalidResponse
}
