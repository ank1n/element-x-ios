//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Ответ сервера на запрос присутствия — ровно то, что нужно разбору: код, тело и срок из заголовка.
struct PresenceHTTPResponse {
    let statusCode: Int
    let body: Data
    let retryAfterHeader: String?
}

/// STMOB-304: сетевой слой присутствия отделён от логики, чтобы опрос и свой статус
/// проверялись тестами без сети и без реального времени.
protocol PresenceTransport {
    func send(_ request: URLRequest) async throws -> PresenceHTTPResponse
}

struct URLSessionPresenceTransport: PresenceTransport {
    func send(_ request: URLRequest) async throws -> PresenceHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        return PresenceHTTPResponse(statusCode: httpResponse?.statusCode ?? -1,
                                    body: data,
                                    retryAfterHeader: httpResponse?.value(forHTTPHeaderField: "Retry-After"))
    }
}

enum PresenceRequest {
    /// Путь присутствия: `@` и `:` в MXID обязаны быть закодированы.
    static func url(homeserver: String, userID: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "@:")
        let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: allowed) ?? userID
        return URL(string: "\(homeserver)/_matrix/client/v3/presence/\(encodedUserID)/status")
    }

    /// Сколько ждать после 429. Synapse кладёт срок только в тело (`retry_after_ms`),
    /// заголовок `Retry-After` может поставить прокси перед сервером.
    static func retryAfter(from response: PresenceHTTPResponse) -> TimeInterval? {
        let raw: Double?
        if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let milliseconds = json["retry_after_ms"] as? Double {
            raw = milliseconds / 1000
        } else if let header = response.retryAfterHeader {
            raw = Double(header.trimmingCharacters(in: .whitespaces))
        } else {
            raw = nil
        }
        // STMOB-311: кривой прокси не должен ни ронять процесс (inf/nan/огромное число трапают
        // в Duration и Int), ни гасить присутствие на сутки.
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return min(raw, maxRetryAfter)
    }
    
    static let maxRetryAfter: TimeInterval = 300
}

/// STMOB-304: отступ после 429. Пока он действует, запросов этого вида нет вовсе.
/// Растёт 1 → 2 → 4 … с, не больше `maxBackoff`; срок сервера учитывается, но тоже не больше потолка.
/// Любой принятый ответ снимает отступ.
struct PresenceRateLimitBackoff {
    static let initialBackoff: TimeInterval = 1
    static let maxBackoff: TimeInterval = 300

    private(set) var blockedUntil: Date?
    private var currentBackoff = initialBackoff

    func isBlocked(now: Date) -> Bool {
        guard let blockedUntil else { return false }
        return now < blockedUntil
    }

    mutating func recordRateLimited(retryAfter: TimeInterval?, now: Date) {
        let delay = min(max(retryAfter ?? 0, currentBackoff), Self.maxBackoff)
        blockedUntil = now.addingTimeInterval(delay)
        currentBackoff = min(currentBackoff * 2, Self.maxBackoff)
    }

    mutating func recordAccepted() {
        blockedUntil = nil
        currentBackoff = Self.initialBackoff
    }
}
