//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

struct UserPresence: Equatable {
    let isOnline: Bool
    let lastSeenDate: Date?
}

class PresenceService {
    private let homeserver: String
    private let accessToken: String
    private let ownUserID: String

    private var pollingTask: Task<Void, Never>?
    private var pollingUserIDs: [String] = []

    let presenceSubject = CurrentValueSubject<[String: UserPresence], Never>([:])

    init(homeserver: String, accessToken: String, ownUserID: String) {
        self.homeserver = homeserver
        self.accessToken = accessToken
        self.ownUserID = ownUserID
    }

    deinit {
        stopPolling()
    }

    // MARK: - Own Presence

    func setOwnPresence(_ status: String) async {
        let encodedUserID = ownUserID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ownUserID
        guard let url = URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["presence": status])

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Fetch Presence

    func fetchPresence(for userIDs: [String]) async {
        var results = presenceSubject.value

        await withTaskGroup(of: (String, UserPresence?).self) { group in
            for userID in userIDs {
                group.addTask { [weak self] in
                    guard let self else { return (userID, nil) }
                    return (userID, await self.fetchSinglePresence(userID: userID))
                }
            }

            for await (userID, presence) in group {
                if let presence {
                    results[userID] = presence
                }
            }
        }

        presenceSubject.send(results)
    }

    private func fetchSinglePresence(userID: String) async -> UserPresence? {
        let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let url = URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let presenceStr = json["presence"] as? String ?? "offline"
        let currentlyActive = json["currently_active"] as? Bool ?? false
        let isOnline = presenceStr == "online" || currentlyActive

        var lastSeenDate: Date?
        if let lastActiveAgo = json["last_active_ago"] as? Int {
            lastSeenDate = Date().addingTimeInterval(-Double(lastActiveAgo) / 1000.0)
        }

        return UserPresence(isOnline: isOnline, lastSeenDate: lastSeenDate)
    }

    // MARK: - Polling

    func startPolling(userIDs: [String], interval: TimeInterval = 30) {
        pollingUserIDs = userIDs
        stopPolling()

        pollingTask = Task { [weak self] in
            guard let self else { return }

            // Initial fetch + set own presence
            await self.setOwnPresence("online")
            await self.fetchPresence(for: userIDs)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }

                await self.setOwnPresence("online")
                await self.fetchPresence(for: self.pollingUserIDs)
            }
        }
    }

    func updatePollingUserIDs(_ userIDs: [String]) {
        pollingUserIDs = userIDs
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
