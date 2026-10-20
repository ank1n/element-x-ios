// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct StalkNativeHTTPError: LocalizedError {
    let status: Int
    var code: String?
    var retryAfter: TimeInterval?
}

/// Requests stay on this account's origin. Never follow an authenticated redirect.
@MainActor
final class StalkNativeAPI {
    let client: ClientProxyProtocol
    private let session: URLSession
    private let ownsSession: Bool
    init(client: ClientProxyProtocol, session: URLSession? = nil) {
        self.client = client
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config, delegate: StalkNoRedirect(), delegateQueue: nil)
        }
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    func request(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard var url = URLComponents(string: client.homeserver), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil else { throw URLError(.badURL) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !path.contains(where: { $0 == "." || $0 == ".." }) else { throw URLError(.badURL) }
        url.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        url.queryItems = query.isEmpty ? nil : query
        url.fragment = nil
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = method
            request.httpBody = body
            try request.setValue("Bearer " + (client.matrixAccessToken()), forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { await client.forceTokenRefresh(); continue }
            guard (200..<300).contains(status) else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    ?? (json?["retry_after_ms"] as? Double).map { $0 / 1000 }
                throw StalkNativeHTTPError(status: status, code: json?["errcode"] as? String, retryAfter: retry)
            }
            return data
        }
        throw StalkNativeHTTPError(status: 401)
    }

    func object(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path, query: query, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return result
    }
}

private final class StalkNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
