// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct SystemSearchConditions: Codable, Equatable {
    var query = ""
    var topic: String?
    var mode = "basic"
    var types: [String] = []
    var period = "all"
    var rangeFrom = ""
    var rangeTo = ""
    var roomIds: [String] = []
    var expand: [String] = []
    var has: [String] = []
    var format: String?
    var sort: String?
    var sender: String?
    var senderName: String?

    static let allowedTypes = ["message", "room_name", "room_topic", "task", "comment", "page", "disk_doc", "attachment", "meeting", "transcript", "voice_transcript"]
    static let allowedFormats = ["presentation", "spreadsheet", "document", "pdf", "image", "archive", "text"]
    var valid: Bool {
        query.count <= 4096 && ["basic", "smart"].contains(mode) && types.allSatisfy(Self.allowedTypes.contains) &&
            roomIds.allSatisfy { $0.hasPrefix("!") && $0.contains(":") && !$0.contains(" ") } &&
            (format.map(Self.allowedFormats.contains) ?? true) && (sort == nil || sort == "newest") && has.allSatisfy { $0 == "email" } &&
            (sender.map { $0.hasPrefix("@") && $0.contains(":") && !$0.contains(" ") } ?? true) &&
            ["all", "week", "month", "year", "range"].contains(period) && (rangeFrom.isEmpty || rangeTo.isEmpty || rangeFrom <= rangeTo)
    }

    var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !types.isEmpty || !roomIds.isEmpty || sender != nil
    }

    func queryItems(offset: Int = 0, viewType: String? = nil, now: Date = Date()) throws -> [URLQueryItem] {
        guard valid, canSearch, offset >= 0, offset <= 10000 else { throw SystemSearchError.invalidConditions }
        var items = [URLQueryItem(name: "q", value: topic ?? query), .init(name: "mode", value: mode), .init(name: "limit", value: "20"), .init(name: "offset", value: String(offset))]
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { items.append(.init(name: key, value: value)) }
        }
        add("type", types.joined(separator: ",")); add("room", roomIds.joined(separator: ",")); add("sender", sender)
        add("format", format); add("sort", sort); add("has", has.joined(separator: ",")); add("view_type", viewType)
        let calendar = Calendar.current
        let iso = ISO8601DateFormatter()
        let day = DateFormatter(); day.calendar = calendar; day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        if period == "range" {
            if !rangeFrom.isEmpty { guard let date = day.date(from: rangeFrom), day.string(from: date) == rangeFrom else { throw SystemSearchError.invalidConditions }; add("from", iso.string(from: date)) }
            if !rangeTo.isEmpty { guard let date = day.date(from: rangeTo), day.string(from: date) == rangeTo else { throw SystemSearchError.invalidConditions }; add("to", iso.string(from: calendar.date(byAdding: .day, value: 1, to: date)!)) }
        } else if let count = ["week": 7, "month": 30, "year": 365][period] { add("from", iso.string(from: calendar.date(byAdding: .day, value: -count, to: now)!)) }
        if mode == "smart" { for phrase in expand.prefix(5) {
            add("qx", phrase)
        } }
        return items
    }
}

struct SystemSearchTarget: Codable, Hashable {
    let kind: String
    var room_id: String?
    var event_id: String?
    var file_id: String?
    var meeting_id: String?
    var egress_id: String?
    var issue_id: String?
    var project_id: String?
    var comment_id: String?
    var page_id: String?
}

struct SystemSearchHit: Decodable, Identifiable {
    struct Metadata: Decodable { var room: String?; var author: String?; var filename: String? }
    let id: String
    let entity_type: String
    var facet_type: String?
    var facetKind: String {
        facet_type ?? entity_type
    }

    let entity_id: String
    var title: String?
    var snippet: String?
    var created_at: String?
    var target: SystemSearchTarget?
    var by: String?
    var meta: Metadata?

    private enum CodingKeys: String, CodingKey {
        case id, entity_type, facet_type, entity_id, title, snippet, created_at, target, by, meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // PostgreSQL BIGSERIAL identifiers may arrive as decimal strings or JSON integers.
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = try String(container.decode(Int64.self, forKey: .id))
        }
        entity_type = try container.decode(String.self, forKey: .entity_type)
        facet_type = try container.decodeIfPresent(String.self, forKey: .facet_type)
        entity_id = try container.decode(String.self, forKey: .entity_id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        created_at = try container.decodeIfPresent(String.self, forKey: .created_at)
        target = try container.decodeIfPresent(SystemSearchTarget.self, forKey: .target)
        by = try container.decodeIfPresent(String.self, forKey: .by)
        meta = try container.decodeIfPresent(Metadata.self, forKey: .meta)
    }

    var text: String {
        (snippet ?? title ?? "").replacingOccurrences(of: "\u{0002}", with: "").replacingOccurrences(of: "\u{0003}", with: "")
    }
}

struct SystemSearchResponse: Decodable {
    struct Scope: Decodable { var rooms: Int?; var disk_docs: Int?; var plane_projects: Int?; var plane_identity: String?; var meetings: Int? }
    var scope: Scope?
    var queryTruncated: Bool?
    var wordsUsed: Int?
    struct Facet: Decodable, Identifiable { let entity_type: String; let n: Int; var n_sense: Int?; var id: String {
        entity_type
    }; var count: Int {
        n + (n_sense ?? 0)
    } }
    struct Semantic: Decodable { var tail: Int?; var error: String? }
    struct Applied: Decodable { var sender: String?; var sort: String?; var view_type: String? }
    let total: Int
    let results: [SystemSearchHit]
    var facets: [Facet]?
    var semantic: Semantic?
    var applied_filters: Applied?
}

enum SystemSearchError: Error, LocalizedError {
    case invalidConditions, unsupported, unauthorized, forbidden, failed(Int), targetUnavailable, plannerFailed, queryTooLong
    var errorDescription: String? {
        switch self {
        case .queryTooLong: NSLocalizedString("Запрос слишком длинный. Сократите его и повторите поиск.", comment: "System search error")
        case .invalidConditions: NSLocalizedString("Проверьте условия поиска. Неподдерживаемое условие не было применено.", comment: "System search error")
        case .unsupported: NSLocalizedString("Поиск по системе на этом сервере недоступен.", comment: "System search error")
        case .unauthorized: NSLocalizedString("Войдите снова, чтобы продолжить поиск.", comment: "System search error")
        case .forbidden: NSLocalizedString("Нет доступа к этому источнику.", comment: "System search error")
        case .failed(let code): String(format: NSLocalizedString("stalk_search_failed_code", comment: "Search failure with status code"), Int64(code))
        case .targetUnavailable: NSLocalizedString("Источник не предоставил доступный переход к этому объекту.", comment: "System search error")
        case .plannerFailed: NSLocalizedString("Айлок не смог уточнить условия. Исходный запрос и ваши фильтры сохранены.", comment: "System search error")
        }
    }
}
