// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A navigation card, not a grant of access. No token or file data is fetched to render it.
struct StalkDiskCard: Hashable, Identifiable {
    enum Kind: Hashable { case document, standaloneDocument, publicShare }
    let url: URL
    let kind: Kind
    let name: String
    var id: String {
        if let document = StalkDiskLink(url: url) { return "document:" + document.host + ":" + document.blobID }
        return url.absoluteString
    }

    var host: String {
        url.host ?? ""
    }

    init?(url: URL, homeserver: URL? = nil) {
        let url = url.scheme == nil ? URL(string: url.relativeString, relativeTo: homeserver)?.absoluteURL : url
        guard let url, ["https", "ru.implica.stalk"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        self.url = url
        if let link = StalkDiskLink(url: url) {
            kind = .document; name = link.name
        } else if url.scheme == "https", let fragment = url.fragment, fragment.hasPrefix("doc/"), UUID(uuidString: String(fragment.dropFirst(4)).removingPercentEncoding ?? "") != nil {
            kind = .standaloneDocument; name = ""
        } else {
            // Public links remain browser routes, preserving password/expiry/download policy.
            let components = url.pathComponents.filter { $0 != "/" }
            guard url.scheme == "https", ["disk.implica.ru", homeserver?.host?.lowercased()].compactMap({ $0 }).contains(host),
                  components.count >= 2, components[components.count - 2] == "s",
                  components.count == 2 || (components.count == 3 && ["disk", "files"].contains(components[0])),
                  components.last?.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { return nil }
            kind = .publicShare; name = ""
        }
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let relativePattern = try! NSRegularExpression(pattern: "(?:ru\\.implica\\.stalk://|/\\#/files/open\\?)[^\\s<>\"']+")

    static func links(in body: String, formattedBody: AttributedString? = nil, homeserver: URL? = nil) -> [Self] {
        var urls = formattedBody?.runs.compactMap(\.link) ?? []
        urls += detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap(\.url)
        urls += relativePattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let range = Range(match.range, in: body) else { return nil }
            return URL(string: String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]")))
        }
        var seen = Set<String>()
        return urls.compactMap { Self(url: $0, homeserver: homeserver) }.filter { seen.insert($0.id).inserted }
    }
}

/// Public previews use the public endpoint, with neither Matrix credentials nor browser cookies.
actor StalkDiskPublicPreview {
    struct Metadata: Decodable { let kind: String; let name: String; var size: Int64?; var mimetype: String? }
    static let shared = StalkDiskPublicPreview()
    private let session: URLSession
    private var cache: [URL: (Date, Metadata?)] = [:]

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        self.session = session ?? URLSession(configuration: config, delegate: DiskPreviewNoRedirect(), delegateQueue: nil)
    }

    func metadata(for card: StalkDiskCard) async -> Metadata? {
        guard card.kind == .publicShare else { return nil }
        if let cached = cache[card.url], Date().timeIntervalSince(cached.0) < 30 { return cached.1 }
        var components = URLComponents(url: card.url, resolvingAgainstBaseURL: false)!
        let parts = card.url.pathComponents.filter { $0 != "/" }
        guard let token = parts.last else { return nil }
        components.path = "/" + (Array(parts.dropLast(2)) + ["api", "public", token]).joined(separator: "/")
        components.query = nil; components.fragment = nil
        guard let url = components.url else { return nil }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let value: Metadata?
            if let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url, data.count <= 128 * 1024,
               let decoded = try? JSONDecoder().decode(Metadata.self, from: data), decoded.kind == "file", !decoded.name.isEmpty, decoded.name.count <= 512 {
                value = decoded
            } else { value = nil } // Protected/deleted links disclose no filename or permissions.
            if cache.count >= 100 { cache.removeAll() }
            cache[card.url] = (Date(), value)
            return value
        } catch { return nil }
    }
}

private final class DiskPreviewNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
