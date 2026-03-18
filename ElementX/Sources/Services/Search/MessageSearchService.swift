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

    init(homeserverURL: String, accessTokenProvider: @escaping () throws -> String) {
        self.homeserverURL = homeserverURL
        self.accessTokenProvider = accessTokenProvider
    }

    /// Search messages across rooms or within a specific room
    func searchMessages(query: String, roomID: String? = nil, nextBatch: String? = nil, limit: Int = 20) async throws -> MessageSearchResponse {
        guard !query.isEmpty else {
            return MessageSearchResponse(results: [], nextBatch: nil, totalCount: 0)
        }

        let accessToken = try accessTokenProvider()

        // Build request body
        var filter: [String: Any] = [:]
        if let roomID {
            filter["rooms"] = [roomID]
        }

        let roomEvents: [String: Any] = [
            "search_term": query,
            "filter": filter,
            "order_by": "recent",
            "event_context": [
                "before_limit": 0,
                "after_limit": 0,
                "include_profile": true
            ]
        ]

        var body: [String: Any] = [
            "search_categories": [
                "room_events": roomEvents
            ]
        ]

        // Build URL
        var urlString = "\(homeserverURL)/_matrix/client/v3/search"
        if let nextBatch {
            urlString += "?next_batch=\(nextBatch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? nextBatch)"
        }

        guard let url = URL(string: urlString) else {
            throw MessageSearchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            MXLog.error("sTalk: Search API returned \(code)")
            throw MessageSearchError.serverError(code)
        }

        return try parseResponse(data)
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

                results.append(MessageSearchResult(
                    eventID: eventID,
                    roomID: roomID,
                    senderID: senderID,
                    senderDisplayName: senderDisplayName ?? senderID,
                    body: body,
                    timestamp: date
                ))
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

    var id: String { eventID }
}

enum MessageSearchError: Error {
    case invalidURL
    case serverError(Int)
    case invalidResponse
}
