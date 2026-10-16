// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The private document route shared by web, messages and iOS. It never grants access by itself.
struct StalkDiskLink: Hashable {
    let host: String
    let blobID: String
    let name: String
    let isDiskDocument: Bool
    let url: URL

    init?(url: URL) {
        guard ["https", "ru.implica.stalk"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let fragment = URLComponents(string: url.fragment ?? ""), fragment.path == "/files/open" else { return nil }
        let items = fragment.queryItems ?? []
        guard items.filter({ $0.name == "blob" }).count == 1,
              let id = items.first(where: { $0.name == "blob" })?.value, UUID(uuidString: id) != nil else { return nil }
        self.host = host
        blobID = id.lowercased()
        let suppliedName = items.first(where: { $0.name == "name" })?.value ?? ""
        name = suppliedName.isEmpty ? "" : String(URL(fileURLWithPath: suppliedName).lastPathComponent.prefix(100))
        isDiskDocument = items.first(where: { $0.name == "disk" })?.value != "0"
        self.url = url
    }
}

/// Compatibility with older agent reports which explicitly label a document ID.
/// Unlabelled UUIDs (tasks, sessions, etc.) never become document actions.
extension StalkDiskLink {
    static func labelledDocumentIDs(in body: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "(?:ID документа|Document ID)\\s*:\\s*`?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`?", options: .caseInsensitive)
        let text = body as NSString
        var seen = Set<String>()
        return pattern.matches(in: body, range: NSRange(location: 0, length: text.length)).compactMap {
            let id = text.substring(with: $0.range(at: 1)).lowercased()
            return seen.insert(id).inserted ? id : nil
        }
    }
}
