// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation

/// Owns only application-created download folders, until their presenting view is released.
final class StalkTemporaryFiles: ObservableObject {
    var urls: [URL] = []
    deinit {
        for url in urls {
            let directory = url.deletingLastPathComponent()
            guard directory.path.hasPrefix(URL.temporaryDirectory.path),
                  ["disk-original-", "ailock-attachment-", "stalk-document-"].contains(where: directory.lastPathComponent.hasPrefix) else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
