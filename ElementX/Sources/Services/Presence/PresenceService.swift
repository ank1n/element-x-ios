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

@MainActor
class PresenceService {
    private let homeserver: String
    /// STMOB-109 build 138: token берём свежий через provider перед каждым
    /// запросом. Раньше держали immutable accessToken — после Matrix token
    /// rotation все GET-запросы становились HTTP 401, чужой presence
    /// «отваливался» полностью (в логе 2101 HTTP 401 за день, 0 HTTP 200
    /// на fetchPresence). OwnPresenceManager уже использует такой подход
    /// с build 121, теперь и PresenceService.
    private let tokenProvider: () -> String?
    /// STMOB-132 build 153: после 401 вызываем forceTokenRefresh чтобы SDK
    /// обновил OIDC access_token внутри (он rotated на MAS каждые 15 мин),
    /// затем retry с свежим token.
    private let tokenRefresher: () async -> Void
    private let ownUserID: String

    private var pollingTask: Task<Void, Never>?
    private var pollingUserIDs: [String] = []
    var currentUserIDs: [String] {
        pollingUserIDs
    }

    /// STMOB-110: in-flight set чтобы не запускать второй fetch для уже
    /// активного запроса (protect от 100+ duplicates за 12 мс).
    private var inFlight: Set<String> = []

    /// STMOB-110: кэш юзеров с HTTP 403 (бот без presence permissions).
    /// На N минут такого юзера не fetchим вообще — Synapse будет возвращать
    /// 403 и дальше, а каждый запрос съедает per-user rate limit.
    private var forbiddenUntil: [String: Date] = [:]
    // STMOB-193: 403 = нет общей комнаты (Synapse M_FORBIDDEN на чужой presence).
    // Этот статус в рамках сессии почти не меняется, а presence «своих» приходит
    // через sync presence EDU, а не через этот REST-поллинг. При 10-мин TTL и
    // 30-сек интервале forbidden-юзеры ре-поллились каждые 10 мин → сотни лишних 403
    // (515 за полчаса в логе тестера). Делаем TTL длинным — один 403 на сессию.
    private let forbiddenTTL: TimeInterval = 6 * 60 * 60 // 6 часов

    let presenceSubject = CurrentValueSubject<[String: UserPresence], Never>([:])

    init(homeserver: String,
         tokenProvider: @escaping () -> String?,
         tokenRefresher: @escaping () async -> Void = { },
         ownUserID: String) {
        // Remove trailing slash to avoid double-slash in URLs
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
        self.ownUserID = ownUserID
        os_log(.info, log: presenceLog, "PresenceService init: homeserver=%{public}@, ownUserID=%{public}@", self.homeserver, ownUserID)
    }

    deinit {
        pollingTask?.cancel()
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
        guard let token = tokenProvider() else {
            os_log(.error, log: presenceLog, "setOwnPresence: no token")
            DiagLog.write("Presence", "setOwnPresence(\(status)) — tokenProvider() returned nil")
            return
        }
        // STMOB-132 build 150: фиксируем длину/префикс токена и тип запроса —
        // увидим в логе если PUT и GET берут разные токены.
        DiagLog.write("Presence", "setOwnPresence(\(status)) PUT tokenLen=\(token.count) tokenPrefix=\(token.prefix(8))…")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

        // STMOB-110: дедуп. Из набора убираем 1) тех кто уже in-flight
        // (другой fetchPresence call ещё идёт для этого юзера) и 2) тех
        // кто в forbidden-кэше (бот вернул 403 < 10 мин назад).
        let now = Date()
        let dedupedIDs = userIDs.filter { userID in
            if inFlight.contains(userID) { return false }
            if let until = forbiddenUntil[userID], until > now { return false }
            return true
        }
        let skippedCount = userIDs.count - dedupedIDs.count
        if skippedCount > 0 {
            DiagLog.write("Presence", "fetchPresence batch=\(userIDs.count) → \(dedupedIDs.count) (skipped \(skippedCount): in-flight/forbidden)")
        } else {
            DiagLog.write("Presence", "fetchPresence batch=\(dedupedIDs.count)")
        }
        guard !dedupedIDs.isEmpty else {
            return
        }
        for id in dedupedIDs {
            inFlight.insert(id)
        }

        var sawUnauthorized = false
        var pendingRetry: [String] = []

        await withTaskGroup(of: (String, UserPresence?, Int?).self) { group in
            for userID in dedupedIDs {
                group.addTask { [weak self] in
                    guard let self else { return (userID, nil, nil) }
                    let (presence, statusCode) = await self.fetchSinglePresenceWithStatus(userID: userID)
                    return (userID, presence, statusCode)
                }
            }

            for await (userID, presence, statusCode) in group {
                inFlight.remove(userID)
                if statusCode == 403 {
                    forbiddenUntil[userID] = now.addingTimeInterval(forbiddenTTL)
                }
                if statusCode == 401 {
                    sawUnauthorized = true
                    pendingRetry.append(userID)
                }
                if let presence {
                    results[userID] = presence
                }
            }
        }

        // STMOB-132 build 153/155: если SDK accessToken был stale (часть
        // запросов получили 401), просим SDK обновить OIDC token. Build 155
        // добавил всегда-логируемое sawUnauthorized/pendingRetry — на 153
        // retry не запускался, нужно понять почему.
        DiagLog.write("Presence", "fetchPresence batch result: sawUnauthorized=\(sawUnauthorized) pendingRetry=\(pendingRetry.count)")
        if sawUnauthorized, !pendingRetry.isEmpty {
            DiagLog.write("Presence", "401 batch → forceTokenRefresh + retry \(pendingRetry.count)")
            await tokenRefresher()
            for id in pendingRetry {
                inFlight.insert(id)
            }
            await withTaskGroup(of: (String, UserPresence?, Int?).self) { group in
                for userID in pendingRetry {
                    group.addTask { [weak self] in
                        guard let self else { return (userID, nil, nil) }
                        let (presence, statusCode) = await self.fetchSinglePresenceWithStatus(userID: userID)
                        return (userID, presence, statusCode)
                    }
                }
                for await (userID, presence, statusCode) in group {
                    inFlight.remove(userID)
                    if statusCode == 403 {
                        forbiddenUntil[userID] = Date().addingTimeInterval(forbiddenTTL)
                    }
                    if let presence {
                        results[userID] = presence
                    }
                }
            }
        }

        presenceSubject.send(results)
    }

    /// STMOB-110: версия fetchSinglePresence которая дополнительно отдаёт
    /// HTTP-код наверх (нужен для 403-кэша).
    private func fetchSinglePresenceWithStatus(userID: String) async -> (UserPresence?, Int?) {
        let encodedUserID = Self.encodeUserID(userID)
        guard let url = URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status") else { return (nil, nil) }
        guard let token = tokenProvider() else {
            DiagLog.write("Presence", "fetchPresence(\(userID)) — no token")
            return (nil, nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            DiagLog.write("Presence", "fetchPresence(\(userID)) network error")
            return (nil, nil)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        os_log(.info, log: presenceLog, "fetchPresence(%{public}@) → %d: %{public}@", userID, httpResponse.statusCode, body)
        if httpResponse.statusCode != 200 {
            // STMOB-132 build 150: при HTTP 401 — записываем prefix токена
            // чтобы сравнить с тем что использует setOwnPresence (PUT). Если
            // префиксы разные — tokenProvider возвращает stale токен для GET.
            if httpResponse.statusCode == 401 {
                DiagLog.write("Presence", "fetchPresence(\(userID)) → HTTP 401 tokenLen=\(token.count) tokenPrefix=\(token.prefix(8))…")
            } else {
                DiagLog.write("Presence", "fetchPresence(\(userID)) → HTTP \(httpResponse.statusCode)")
            }
            return (nil, httpResponse.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, httpResponse.statusCode)
        }
        let presenceStr = json["presence"] as? String ?? "offline"
        let currentlyActive = json["currently_active"] as? Bool ?? false
        let lastActiveAgoMs = json["last_active_ago"] as? Int
        var lastSeenDate: Date?
        if let ago = lastActiveAgoMs {
            lastSeenDate = Date().addingTimeInterval(-Double(ago) / 1000.0)
        }
        // STMOB-131 build 156: лог real-server values чтобы понять почему
        // @nh / @admin показываются "в сети" если в Contacts «23 минуты назад».
        // Гипотезы: 1) сервер реально шлёт last_active_ago<5min,
        // 2) currently_active=true без last_active_ago (мой fix даёт false),
        // 3) другой userID resolved в Header чем в Contacts.
        DiagLog.write("Presence", "fetchPresence(\(userID)) → presence=\(presenceStr) currently_active=\(currentlyActive) last_active_ago_ms=\(lastActiveAgoMs ?? -1)")
        // STMOB-133 build 154: считаем online ТОЛЬКО если последняя активность
        // < 5 мин назад. Без этого Synapse иногда отдаёт `currently_active: true`
        // для юзеров реально активных 20+ минут назад (race в Synapse
        // presence_stream) → header показывал «в сети» когда в Contacts list
        // было корректное «был 23 минуты назад». Теперь оба места дают
        // одинаковый результат.
        let recentlyActive = (lastActiveAgoMs ?? .max) < 5 * 60 * 1000
        let isOnline = (presenceStr == "online" || currentlyActive) && recentlyActive
        return (UserPresence(isOnline: isOnline, lastSeenDate: lastSeenDate), httpResponse.statusCode)
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
