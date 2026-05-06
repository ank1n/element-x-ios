//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

private let presenceLog = OSLog(subsystem: "ru.implica.stalk", category: "Presence")

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
    var currentUserIDs: [String] {
        pollingUserIDs
    }

    let presenceSubject = CurrentValueSubject<[String: UserPresence], Never>([:])

    init(homeserver: String, accessToken: String, ownUserID: String) {
        // Remove trailing slash to avoid double-slash in URLs
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessToken = accessToken
        self.ownUserID = ownUserID
        os_log(.info, log: presenceLog, "PresenceService init: homeserver=%{public}@, ownUserID=%{public}@", self.homeserver, ownUserID)
    }

    deinit {
        stopPolling()
    }

    // MARK: - Own Presence

    private static func encodeUserID(_ userID: String) -> String {
        // Matrix user IDs contain @ and : which must be percent-encoded in URL paths
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "@:")
        return userID.addingPercentEncoding(withAllowedCharacters: allowed) ?? userID
    }

    func setOwnPresence(_ status: String) async {
        let encodedUserID = Self.encodeUserID(ownUserID)
        let urlString = "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status"
        os_log(.info, log: presenceLog, "setOwnPresence URL: %{public}@", urlString)
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["presence": status])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            os_log(.info, log: presenceLog, "setOwnPresence(%{public}@) url=%{public}@ → %d: %{public}@", status, urlString, statusCode, body)
        } catch {
            os_log(.error, log: presenceLog, "setOwnPresence error: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Fetch Presence

    func fetchPresence(for userIDs: [String]) async {
        var results = presenceSubject.value

        await withTaskGroup(of: (String, UserPresence?).self) { group in
            for userID in userIDs {
                group.addTask { [weak self] in
                    guard let self else { return (userID, nil) }
                    return await (userID, self.fetchSinglePresence(userID: userID))
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
        let encodedUserID = Self.encodeUserID(userID)
        guard let url = URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            os_log(.error, log: presenceLog, "fetchPresence(%{public}@): network error", userID)
            DiagLog.write("Presence", "fetchPresence(\(userID)) network error")
            return nil
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        os_log(.info, log: presenceLog, "fetchPresence(%{public}@) → %d: %{public}@", userID, httpResponse.statusCode, body)
        // STMOB-109: дублируем в DiagLog чтобы видеть HTTP коды по чужим
        // presence в `nse-events.log` (os_log на устройстве не виден).
        if httpResponse.statusCode != 200 {
            DiagLog.write("Presence", "fetchPresence(\(userID)) → HTTP \(httpResponse.statusCode)")
        }

        guard httpResponse.statusCode == 200,
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
        os_log(.info, log: presenceLog, "startPolling: %d users: %{public}@", userIDs.count, userIDs.joined(separator: ", "))
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
