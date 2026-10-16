// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

final class SystemSearchService {
    let client: ClientProxyProtocol
    let session: URLSession
    var base: String {
        client.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    init(client: ClientProxyProtocol, session: URLSession = .shared) {
        self.client = client; self.session = session
    }

    func search(_ conditions: SystemSearchConditions, offset: Int = 0, viewType: String? = nil) async throws -> SystemSearchResponse {
        var url = URLComponents(string: base + "/api/search")!
        url.queryItems = try conditions.queryItems(offset: offset, viewType: viewType)
        let data = try await request(url.url!)
        var response = try JSONDecoder().decode(SystemSearchResponse.self, from: data)
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        response.queryTruncated = metadata?["truncated"] as? Bool
        response.wordsUsed = metadata?["words_used"] as? Int
        guard conditions.sender == nil || response.applied_filters?.sender == conditions.sender,
              conditions.sort == nil || response.applied_filters?.sort == conditions.sort,
              viewType == nil || response.applied_filters?.view_type == viewType else { throw SystemSearchError.invalidConditions }
        return response
    }

    /// Uses cached joined-room members; never synchronizes room history for a picker.
    func knownSenders() async -> [SystemSearchPerson] {
        var people: [SystemSearchPerson] = []
        for room in client.staticRoomSummaryProvider.roomListPublisher.value where room.joinRequestType == nil && !room.isTombstoned {
            guard !Task.isCancelled else { break }
            people += room.heroes.map { SystemSearchPerson(id: $0.userID, name: $0.displayName ?? $0.userID, aliases: room.isDirect && room.activeMembersCount <= 2 ? [room.name] : []) }
            if let iterator = try? await room.room.membersNoSync(), let members = iterator.nextChunk(chunkSize: iterator.len()) {
                people += members.filter { $0.membership == .join && !$0.isServiceMember }.map {
                    SystemSearchPerson(id: $0.userId, name: $0.displayName ?? $0.userId)
                }
            }
        }
        return SystemSearchPerson.merge(people)
    }

    func lookupSenders(query: String) async -> SystemSearchDirectory {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        async let local = knownSenders()
        async let organization = directoryRows(path: "/api/org-profile/directory", key: "users")
        async let directory = matrixDirectory(query: query)
        let (known, contacts, matrix) = await (local, organization, directory)
        let rows = known + matrix.people + contacts.people
        return SystemSearchDirectory(people: SystemSearchPerson.merge(rows),
                                     complete: contacts.complete && (query.count < 2 || matrix.complete),
                                     contactsAvailable: contacts.complete)
    }

    private func matrixDirectory(query: String) async -> SystemSearchDirectory {
        guard query.count >= 2 else { return .init(people: [], complete: false) }
        let body = try? JSONSerialization.data(withJSONObject: ["search_term": query, "limit": 100])
        return await directoryRows(path: "/_matrix/client/v3/user_directory/search", key: "results", body: body)
    }

    private func directoryRows(path: String, key: String, body: Data? = nil) async -> SystemSearchDirectory {
        do {
            let data = try await request(URL(string: base + path)!, method: body == nil ? "GET" : "POST", body: body, timeout: 5)
            return try Self.decodeDirectory(data, key: key)
        } catch { return .init(people: [], complete: false) }
    }

    static func decodeDirectory(_ data: Data, key: String) throws -> SystemSearchDirectory {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json[key] as? [[String: Any]] else { return .init(people: [], complete: false) }
        var valid = true
        let people: [SystemSearchPerson] = rows.compactMap { row in
            guard let id = row["user_id"] as? String, SystemSearchPerson.validID(id),
                  row["display_name"] == nil || row["display_name"] is NSNull || row["display_name"] is String else { valid = false; return nil }
            return SystemSearchPerson(id: id, name: (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
        struct Limit: Decodable { var limited: Bool? }
        let limited = (try? JSONDecoder().decode(Limit.self, from: data))?.limited
        let complete = valid && (key == "users" || limited == false)
        return .init(people: people, complete: complete, contactsAvailable: key == "users" && complete)
    }

    func people(query: String, directory: [SystemSearchPerson]) -> [SystemSearchPerson] {
        let rooms = client.staticRoomSummaryProvider.roomListPublisher.value.filter { $0.joinRequestType == nil && !$0.isTombstoned && $0.isDirect && $0.activeMembersCount <= 2 }
            .sorted { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
        return directory.filter { $0.id != client.userID && $0.matchesPeople(query) }.map { person in
            var person = person
            if case .success(let directID) = client.directRoomForUserID(person.id), let directID, rooms.contains(where: { $0.id == directID }) {
                person.dmRoomID = directID
            } else {
                person.dmRoomID = rooms.first { room in room.heroes.contains { $0.userID == person.id } }?.id
            }
            return person
        }.sorted {
            if ($0.dmRoomID != nil) != ($1.dmRoomID != nil) { return $0.dmRoomID != nil }
            if let lhs = $0.dmRoomID, let rhs = $1.dmRoomID, lhs != rhs {
                return (rooms.firstIndex { $0.id == lhs } ?? Int.max) < (rooms.firstIndex { $0.id == rhs } ?? Int.max)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func externalURL(for target: SystemSearchTarget) async throws -> URL {
        // The tracker origin is public installation configuration, never guessed from a user's token.
        let (data, _) = try await session.data(from: URL(string: base + "/config.json")!)
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stalk = config?["stalk"] as? [String: Any] ?? [:]
        let configured = (stalk["apps"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "trackit" })?["url"] as? String
        var raw = configured
        if raw == nil {
            let registry = try await request(URL(string: base + "/apps-api/apps?client=web")!)
            let json = try JSONSerialization.jsonObject(with: registry) as? [String: Any]
            raw = (json?["apps"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "trackit" && $0["enabled"] as? Bool == true })?["url"] as? String
        }
        guard let raw, let original = URL(string: raw), original.scheme == "https", original.user == nil, original.password == nil,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { throw SystemSearchError.targetUnavailable }
        let workspace = stalk["trackitWorkspace"] as? String ?? original.pathComponents.first(where: { $0 != "/" }) ?? "implica"
        guard workspace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw SystemSearchError.targetUnavailable }
        let project = target.project_id.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        if target.kind == "issue", let id = target.issue_id, UUID(uuidString: id) != nil, let project {
            components.path = "/\(workspace)/projects/\(project)/issues/\(id)"
        } else if target.kind == "page", let id = target.page_id, UUID(uuidString: id) != nil {
            components.path = project.map { "/\(workspace)/projects/\($0)/pages/\(id)" } ?? "/\(workspace)/pages/\(id)"
        } else { throw SystemSearchError.targetUnavailable }
        components.query = nil; components.fragment = nil
        return components.url!
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let token = try client.matrixAccessToken()
            guard !token.isEmpty else { throw SystemSearchError.unauthorized }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                guard http?.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true else { throw SystemSearchError.unsupported }
                return data
            case 401 where attempt == 0: await client.forceTokenRefresh()
            case 401: throw SystemSearchError.unauthorized
            case 403: throw SystemSearchError.forbidden
            case 400:
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if json?["error"] as? String == "query_too_long" { throw SystemSearchError.queryTooLong }
                throw SystemSearchError.invalidConditions
            case 404: throw SystemSearchError.unsupported
            case let status: throw SystemSearchError.failed(status)
            }
        }
        throw SystemSearchError.unauthorized
    }
}

struct SystemSearchDirectory {
    var people: [SystemSearchPerson]
    var complete: Bool
    var contactsAvailable = false
}

struct SystemSearchPerson: Identifiable, Equatable {
    let id: String
    var name: String
    var aliases: [String] = []
    var dmRoomID: String?
    var names: [String] {
        [name] + aliases
    }

    var target: SystemSearchTarget {
        if let dmRoomID { return .init(kind: "room", room_id: dmRoomID) }
        return .init(kind: "user", user_id: id)
    }

    static func validID(_ id: String) -> Bool {
        id.count <= 255 && id.range(of: "^@[a-z0-9._=/+\\-]+:[a-z0-9.\\-]+(?::[0-9]{1,5})?$", options: .regularExpression) != nil
    }

    static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func merge(_ rows: [Self]) -> [Self] {
        var merged: [String: Self] = [:]
        for var row in rows where validID(row.id) {
            if let old = merged[row.id] {
                row.aliases = Array(Set(old.names + row.names)).sorted()
                if row.name == row.id { row.name = old.name }
                row.dmRoomID = row.dmRoomID ?? old.dmRoomID
            }
            merged[row.id] = row
        }
        return merged.values.sorted {
            if $0.id.hasPrefix("@meet-") != $1.id.hasPrefix("@meet-") { return !$0.id.hasPrefix("@meet-") }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func matchesSender(_ query: String) -> Bool {
        let q = Self.fold(query)
        return q.isEmpty || Self.fold(id).contains(q) || names.contains { name in
            let parts = Self.fold(name).split(whereSeparator: \.isWhitespace)
            return q.split(whereSeparator: \.isWhitespace).allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }
    }

    private var isServiceUser: Bool {
        let local = String(id.dropFirst().split(separator: ":", maxSplits: 1).first ?? "")
        return ["meet-bridge", "session-bot", "notices", "meet"].contains(local) || local.hasPrefix("__") || local.hasPrefix("meet-") ||
            local.range(of: "^admin([._-]|$)|[._-]admin$", options: .regularExpression) != nil
    }

    /// People matching deliberately ignores the homeserver unless an MXID was explicitly typed.
    func matchesPeople(_ query: String) -> Bool {
        let query = Self.fold(query)
        guard Self.validID(id), !isServiceUser, query.count >= 2 else { return false }
        func parts(_ value: String) -> [String] {
            Self.fold(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let local = String(id.dropFirst().split(separator: ":", maxSplits: 1)[0])
        let labels = names.map { $0.replacingOccurrences(of: "@([^\\s:()]+):[^\\s()]+", with: "$1", options: .regularExpression) }
        let own = labels.flatMap(parts) + parts(local)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let mxid = word.hasPrefix("@") ? String(word) : "@" + word
                return Self.fold(id).hasPrefix(mxid)
            }
            let terms = parts(String(word))
            return !terms.isEmpty && terms.allSatisfy { term in own.contains { term.count < 4 ? $0.hasPrefix(term) : $0.contains(term) } }
        }
    }
}
