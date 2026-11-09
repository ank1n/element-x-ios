//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ShareExtensionConstants {
    static let urlPath = "share"

    /// A cold launch can be triggered by several freshly shared attachments.
    /// Their count is not a signal that they are safe to delete.
    static func removeExpiredFiles(in directory: URL = .appGroupTemporaryDirectory, now: Date = Date()) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let values = try url.resourceValues(forKeys: keys)
            guard let newest = [values.creationDate, values.contentModificationDate].compactMap({ $0 }).max(),
                  now.timeIntervalSince(newest) > 24 * 60 * 60 else { continue }
            try manager.removeItem(at: url)
        }
    }
}

enum ShareExtensionPayload: Hashable, Codable {
    case mediaFiles(roomID: String?, mediaFiles: [ShareExtensionMediaFile])
    case text(roomID: String?, text: String)
    
    var roomID: String? {
        switch self {
        case .mediaFiles(let roomID, _),
             .text(let roomID, _):
            roomID
        }
    }
    
    /// Stage the whole share before deleting any originals. Attachments keep their
    /// names and relative subdirectories; a failed import leaves the share retryable.
    func withDefaultTemporaryDirectory(sourceDirectory: URL = .appGroupTemporaryDirectory,
                                       destinationDirectory: URL = .temporaryDirectory) throws -> Self {
        guard case let .mediaFiles(roomID, mediaFiles) = self else { return self }
        let manager = FileManager.default
        let sourceRoot = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let destination = destinationDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: destination) } }
        let staged = try mediaFiles.map { file -> ShareExtensionMediaFile in
            let source = file.url.standardizedFileURL.resolvingSymlinksInPath()
            guard source.isFileURL, source.path.hasPrefix(sourceRoot),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadNoPermission)
            }
            let relativePath = String(source.path.dropFirst(sourceRoot.count))
            let target = destination.appendingPathComponent(relativePath, isDirectory: false)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Some share providers repeat one attachment. Reuse its staged copy.
            if !manager.fileExists(atPath: target.path) { try manager.copyItem(at: source, to: target) }
            return file.replacingURL(with: target)
        }
        for source in Set(mediaFiles.map(\.url)) {
            try? manager.removeItem(at: source)
        }
        completed = true
        return .mediaFiles(roomID: roomID, mediaFiles: staged)
    }
}

struct ShareExtensionMediaFile: Hashable, Codable {
    let url: URL
    let suggestedName: String?
    
    fileprivate func replacingURL(with newURL: URL) -> ShareExtensionMediaFile {
        ShareExtensionMediaFile(url: newURL, suggestedName: suggestedName)
    }
}
