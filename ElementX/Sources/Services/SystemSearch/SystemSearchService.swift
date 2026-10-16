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

    func senders(query: String) async throws -> [(id: String, name: String)] {
        let body = try JSONSerialization.data(withJSONObject: ["search_term": query, "limit": 50])
        let data = try await request(URL(string: base + "/_matrix/client/v3/user_directory/search")!, method: "POST", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["results"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["user_id"] as? String, id.hasPrefix("@") else { return nil }
            return (id, row["display_name"] as? String ?? id)
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

    func request(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let token = try client.matrixAccessToken()
            guard !token.isEmpty else { throw SystemSearchError.unauthorized }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
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
