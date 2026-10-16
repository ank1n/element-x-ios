// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct AilockAttachmentReference: Equatable {
    let conversationID: String
    let attachmentID: String

    init?(conversationID: String, attachmentID: String) {
        guard UUID(uuidString: conversationID) != nil,
              attachmentID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              !attachmentID.contains("..") else { return nil }
        self.conversationID = conversationID.lowercased()
        self.attachmentID = attachmentID
    }

    init?(path: String) {
        guard !path.contains("%"), !path.contains("?"), !path.contains("#") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0].isEmpty, parts[1] == "api", parts[2] == "v1",
              parts[3] == "conversations", parts[5] == "attachments" else { return nil }
        self.init(conversationID: String(parts[4]), attachmentID: String(parts[6]))
    }

    var path: String {
        "/api/v1/conversations/\(conversationID)/attachments/\(attachmentID)"
    }
}

final class AilockNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
