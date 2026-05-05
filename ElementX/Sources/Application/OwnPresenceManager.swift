//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// STMOB-103: Поддерживает корректную presence пользователя в Synapse независимо
/// от того, на какой вкладке он находится в приложении.
///
/// Раньше presence отправляла только PresenceService прикреплённая к ContactsListScreen.
/// Когда юзер был на Chats/Calls/Settings — Synapse считал его offline. Молли
/// нашла это: `presence_stream` для bondar = state=offline, last_user_sync_ts=35h.
///
/// Логика жизненного цикла:
/// - Foreground active   → `online`, периодический ping каждые 30 сек
/// - Background          → `unavailable` (idle, web покажет жёлтый dot + last seen)
/// - Terminate           → `offline`
///
/// Использует тот же endpoint что PresenceService:
///   PUT /_matrix/client/v3/presence/{userId}/status   {"presence":"<status>"}
@MainActor
final class OwnPresenceManager {
    private let homeserver: String
    private let accessToken: String
    private let userID: String
    private var pingTask: Task<Void, Never>?
    private let pingInterval: TimeInterval = 30

    init?(clientProxy: ClientProxyProtocol) {
        guard let token = try? clientProxy.matrixAccessToken() else { return nil }
        let raw = clientProxy.homeserver
        homeserver = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        accessToken = token
        userID = clientProxy.userID
    }

    deinit {
        pingTask?.cancel()
    }

    func startOnline() {
        pingTask?.cancel()
        let interval = pingInterval
        pingTask = Task { [weak self] in
            guard let self else { return }
            await self.setStatus("online")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.setStatus("online")
            }
        }
    }

    func setBackground() {
        pingTask?.cancel()
        pingTask = nil
        Task { [weak self] in await self?.setStatus("unavailable") }
    }

    func setOffline() {
        pingTask?.cancel()
        pingTask = nil
        Task { [weak self] in await self?.setStatus("offline") }
    }

    private func setStatus(_ status: String) async {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "@:")
        let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: allowed) ?? userID
        guard let url = URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["presence": status])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagLog.write("Presence", "setStatus(\(status)) → HTTP \(code)")
        } catch {
            DiagLog.write("Presence", "setStatus(\(status)) ERR \(error)")
        }
    }
}
