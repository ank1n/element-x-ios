//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Ссылка на встречу в теле сообщения.
///
/// STMOB-274. У встреч, в отличие от «поделился файлом», кастомного события НЕТ:
/// это обычный `m.text`, тело которого целиком — ссылка `/meet/s/<код>`.
/// Клиент её распознаёт и рисует карточку; если ссылка лишь упомянута внутри
/// текста, карточки нет — иначе любое сообщение со ссылкой превращалось бы в плашку.
///
/// Правило и регулярное выражение сверены с вебом (Molly, #ops 31.07).
enum StalkMeetingLink {
    private static let pattern = "^(?:https?://[^\\s/]+)?/meet/s/([A-Za-z0-9_-]+)/?$"

    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: pattern)

    /// Код встречи, если тело сообщения целиком является ссылкой.
    static func code(in body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let regex else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges > 1,
              let codeRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[codeRange])
    }
}

/// Поиск встречи по коду для карточки в ленте.
///
/// Точечного маршрута у сервиса пока нет (запрошен у владельца), поэтому берём
/// общий список и кэшируем: на устройстве он весит под полмегабайта, и тянуть его
/// на каждую плашку нельзя. Кэш живёт 20 секунд — столько же, сколько в вебе.
actor MeetingLookupService {
    private let service: MeetingsService
    private var cache: [String: Meeting] = [:]
    private var cachedAt: Date?
    private var inFlight: Task<[Meeting], Error>?

    private static let ttl: TimeInterval = 20

    init(service: MeetingsService) {
        self.service = service
    }

    func meeting(code: String) async -> Meeting? {
        if let cachedAt, Date().timeIntervalSince(cachedAt) < Self.ttl, let meeting = cache[code] {
            return meeting
        }

        do {
            let meetings = try await load()
            return meetings.first { $0.meetingCode == code }
        } catch {
            MXLog.error("sTalk: не удалось найти встречу по коду: \(error)")
            return nil
        }
    }

    /// Один запрос на всех: несколько карточек на экране не должны тянуть список
    /// параллельно.
    private func load() async throws -> [Meeting] {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await service.fetchMeetingsList() }
        inFlight = task
        defer { inFlight = nil }

        let meetings = try await task.value
        cache = Dictionary(meetings.compactMap { meeting in
            meeting.meetingCode.map { ($0, meeting) }
        }, uniquingKeysWith: { _, last in last })
        cachedAt = Date()
        return meetings
    }
}
