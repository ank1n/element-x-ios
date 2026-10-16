// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import UIKit

actor DiskPhotoRequestLimiter {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

final class DiskPhotoService {
    let disk: DiskService
    private let limiter = DiskPhotoRequestLimiter()
    private let thumbnails = NSCache<NSString, UIImage>()
    init(disk: DiskService) {
        self.disk = disk; thumbnails.countLimit = 80; thumbnails.totalCostLimit = 24 * 1024 * 1024
    }

    private struct Document: Decodable {
        let blobId: String; let name: String; var mimetype: String?; let ts: Int64
        var snippet: String?; var snippetMatch: String?
        var addedTs: Int64?; var photo: DiskPhoto.EXIF?; var starred: Bool?; var canDownload: Bool?; var folderId: Int?; var owner: String?; var tags: [String]?
    }

    func photos(offset: Int, query: String, album: Int? = nil, scope: String? = nil) async throws -> (photos: [DiskPhoto], more: Bool) {
        var url = URLComponents(); url.path = "disk-docs"
        url.queryItems = [.init(name: "cat", value: "photos"), .init(name: "limit", value: "100"), .init(name: "offset", value: String(offset)), .init(name: "order", value: "id")]
        if let scope { url.queryItems?.append(.init(name: "scope", value: scope)) }
        if let album { url.queryItems?.append(.init(name: "photoAlbum", value: String(album))) }
        if !query.isEmpty { url.queryItems?.append(.init(name: "q", value: query)) }
        struct Response: Decodable { let docs: [Document]; var hasMore: Bool? }
        let response = try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: url.string!))
        return (response.docs.map { .init(reference: .init(source: "disk", blobId: $0.blobId), name: $0.name, mimetype: $0.mimetype ?? "image/jpeg",
                                          added: Date(timeIntervalSince1970: Double($0.addedTs ?? $0.ts) / 1000), exif: $0.photo, starred: $0.starred ?? false, canDownload: $0.canDownload ?? true, folderID: $0.folderId, owner: $0.owner, tags: $0.tags ?? [], modified: Date(timeIntervalSince1970: Double($0.ts) / 1000), snippet: $0.snippet, snippetMatch: $0.snippetMatch) }, response.hasMore ?? (response.docs.count == 100))
    }

    func folders() async throws -> [DiskPhotoFolder] {
        struct Response: Decodable { let folders: [DiskPhotoFolder] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "folders")).folders
    }

    func albums() async throws -> [DiskPhotoAlbum] {
        struct Response: Decodable { let albums: [DiskPhotoAlbum] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "photo-albums")).albums
    }

    func createAlbum(name: String) async throws -> DiskPhotoAlbum {
        try await JSONDecoder().decode(DiskPhotoAlbum.self, from: disk.photoRequest(path: "photo-albums", method: "POST", body: ["name": name]))
    }

    func deleteAlbum(_ id: Int) async throws {
        _ = try await disk.photoRequest(path: "photo-albums/\(id)", method: "DELETE")
    }

    func renameAlbum(_ id: Int, name: String) async throws {
        _ = try await disk.photoRequest(path: "photo-albums/\(id)", method: "PATCH", body: ["name": name])
    }

    func albumItems(_ id: Int) async throws -> [DiskPhotoReference] {
        struct Response: Decodable { let items: [DiskPhotoReference] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "photo-albums/\(id)/contents")).items
    }

    func changeAlbum(_ id: Int, items: [DiskPhotoReference], action: String) async throws {
        guard ["add", "remove", "order", "cover"].contains(action), !items.isEmpty else { return }
        _ = try await disk.photoRequest(path: "photo-albums/\(id)/contents", method: "POST", body: ["action": action, "items": items.map(\.json)])
    }

    func members(_ id: Int) async throws -> [DiskPhotoAlbumMember] {
        struct Response: Decodable { let members: [DiskPhotoAlbumMember] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "photo-albums/\(id)/members")).members
    }

    func grant(_ id: Int, user: String, role: String?) async throws {
        guard user.hasPrefix("@"), user.contains(":"), role == nil || ["read", "add", "manage"].contains(role!) else { throw DiskServiceError.invalidURL }
        _ = try await disk.photoRequest(path: "photo-albums/\(id)/members", method: role == nil ? "DELETE" : "POST", body: ["user": user, "role": role ?? "read"])
    }

    func systems() async throws -> DiskPhotoSystems {
        try await JSONDecoder().decode(DiskPhotoSystems.self, from: disk.photoRequest(path: "photo-systems"))
    }

    func systemChange(action: String, extra: [String: Any] = [:]) async throws {
        var body = extra; body["action"] = action
        _ = try await disk.photoRequest(path: "photo-systems", method: "POST", body: body)
    }

    func assignments(_ photos: [DiskPhoto]) async throws -> [DiskPhotoAssignment] {
        struct Response: Decodable { let files: [DiskPhotoAssignment] }
        var result: [DiskPhotoAssignment] = []
        for offset in stride(from: 0, to: photos.count, by: 100) {
            let items = photos[offset..<min(offset + 100, photos.count)].map(\.reference.json)
            let data = try await disk.photoRequest(path: "photo-systems", method: "POST", body: ["action": "resolve", "items": items])
            result += try JSONDecoder().decode(Response.self, from: data).files
        }
        return result
    }

    func assign(_ photos: [DiskPhotoReference], system: Int? = nil, category: String? = nil, reject: Bool = false) async throws {
        for offset in stride(from: 0, to: photos.count, by: 100) {
            var body: [String: Any] = ["action": category == nil ? "assign" : "categorize", "mode": reject ? "reject" : "add",
                                       "items": photos[offset..<min(offset + 100, photos.count)].map(\.json)]
            if let category { guard ["errors", "interfaces", "reports"].contains(category) else { throw DiskServiceError.invalidURL }; body["categories"] = [category] }
            if let system { body["systems"] = [system] }
            _ = try await disk.photoRequest(path: "photo-systems", method: "POST", body: body)
        }
    }

    func assignSystems(_ photos: [DiskPhotoReference], systems: [Int], mode: String) async throws {
        guard ["set", "add", "reject"].contains(mode), systems.allSatisfy({ $0 > 0 }) else { throw DiskServiceError.invalidURL }
        for offset in stride(from: 0, to: photos.count, by: 100) {
            _ = try await disk.photoRequest(path: "photo-systems", method: "POST", body: [
                "action": "assign", "mode": mode, "systems": systems,
                "items": photos[offset..<min(offset + 100, photos.count)].map(\.json)
            ])
        }
    }

    func filters() async throws -> [DiskPhotoSavedFilter] {
        struct Response: Decodable { let filters: [DiskPhotoSavedFilter] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "photo-filters")).filters
    }

    func saveFilter(name: String, criteria: DiskPhotoFilterConditions, id: Int? = nil, album: Bool = true) async throws {
        guard criteria.valid else { throw DiskServiceError.invalidURL }
        var criteria = criteria
        criteria.dateBasis = criteria.dateBasis ?? "taken"
        var body: [String: Any] = try ["name": name, "album": album, "criteria": JSONSerialization.jsonObject(with: JSONEncoder().encode(criteria))]
        if let id { body["id"] = id }
        _ = try await disk.photoRequest(path: "photo-filters", method: "POST", body: body)
    }

    func removeFilter(_ id: Int) async throws {
        _ = try await disk.photoRequest(path: "photo-filters/\(id)", method: "DELETE")
    }

    func thumbnail(_ photo: DiskPhoto) async throws -> UIImage {
        if let image = thumbnails.object(forKey: photo.id as NSString) { return image }
        guard let blob = photo.reference.blobId, UUID(uuidString: blob) != nil else { throw DiskServiceError.invalidURL }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        try Task.checkCancellation()
        let data = try await disk.photoRequest(path: "blob/\(blob)/thumbnail?size=320")
        guard let image = UIImage(data: data) else { throw DiskServiceError.http(415) }
        thumbnails.setObject(image, forKey: photo.id as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale) * 4)
        return image
    }

    func image(_ photo: DiskPhoto, original: Bool = false) async throws -> UIImage {
        guard photo.canDownload, let id = photo.reference.blobId, UUID(uuidString: id) != nil else { throw DiskServiceError.http(403) }
        let data = try await disk.photoRequest(path: original ? "blob/\(id)" : "blob/\(id)/preview-image")
        guard let image = UIImage(data: data) else { throw DiskServiceError.http(415) }
        return image
    }

    func star(_ photo: DiskPhoto, value: Bool) async throws {
        _ = try await disk.photoRequest(path: "star", method: "PUT", body: ["eventId": photo.reference.blobId.map { "blob:" + $0 } ?? photo.reference.eventId ?? "", "roomId": photo.reference.roomId ?? "", "starred": value])
    }

    func originalFile(_ photo: DiskPhoto) async throws -> URL {
        guard photo.canDownload, let id = photo.reference.blobId, UUID(uuidString: id) != nil else { throw DiskServiceError.http(403) }
        return try await disk.downloadBlobFile(id: id, filename: photo.name)
    }

    func canEditCopy(_ photo: DiskPhoto) async throws -> Bool {
        guard let id = photo.reference.blobId, UUID(uuidString: id) != nil, photo.canDownload else { return false }
        let data = try await disk.photoRequest(path: "photo-editor/\(id)/access")
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["canDownload"] as? Bool == true
    }
}

/// Resolves Matrix attachments without exposing encryption metadata outside the SDK path.
@MainActor
enum DiskPhotoMatrixMedia {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            NSLocalizedString("Не удалось получить фото или ключи. Повторите загрузку или откройте исходное сообщение.", comment: "Matrix photo source unavailable")
        }
    }

    static func source(for file: DiskFile, resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?) async throws -> MediaSourceProxy {
        try Task.checkCancellation()
        guard let resolveMatrixSource, let source = await resolveMatrixSource(file) else {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        // Index MXC metadata is never authorization, including for unencrypted media.
        // Redaction, lost membership, missing keys or conversion rejection must fail closed.
        return source
    }

    static func image(for file: DiskFile, mediaProvider: MediaProviderProtocol?,
                      resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?, size: CGSize? = nil) async throws -> UIImage {
        guard let mediaProvider else { throw Failure.unavailable }
        let source = try await source(for: file, resolveMatrixSource: resolveMatrixSource)
        try Task.checkCancellation()
        let requested = size ?? CGSize(width: 2560, height: 2560)
        let scale = min(1, 2560 / max(1, max(requested.width, requested.height)))
        let bounded = CGSize(width: max(1, requested.width * scale), height: max(1, requested.height * scale))
        let result = await mediaProvider.loadImageFromSource(source, size: bounded)
        try Task.checkCancellation()
        return try result.get()
    }

    struct Preview {
        let image: UIImage
        let sdkSourceAvailable: Bool
    }

    /// Preview and editing share the same mandatory current room/event source resolution.
    static func preview(for file: DiskFile, mediaProvider: MediaProviderProtocol?,
                        resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?) async throws -> Preview {
        try Task.checkCancellation()
        let resolved: MediaSourceProxy?
        if let resolveMatrixSource { resolved = await resolveMatrixSource(file) } else { resolved = nil }
        try Task.checkCancellation()
        let loaded = try await image(for: file, mediaProvider: mediaProvider, resolveMatrixSource: { _ in resolved })
        return Preview(image: loaded, sdkSourceAvailable: resolved != nil)
    }

    static func supportsEditing(mimetype: String) -> Bool {
        ["image/jpeg", "image/png", "image/webp"].contains(mimetype)
    }

    static func verifySourceAccess(for file: DiskFile,
                                   resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?) async -> Bool {
        // Editing rechecks room/event access, even for unencrypted files; a raw MXC is not an access check.
        guard !Task.isCancelled, let resolveMatrixSource else { return false }
        let resolved = await resolveMatrixSource(file)
        return !Task.isCancelled && resolved != nil
    }

    static func editableOriginal(for file: DiskFile, mediaProvider: MediaProviderProtocol?,
                                 resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?) async throws -> URL {
        guard supportsEditing(mimetype: file.mimetype), let mediaProvider, let resolveMatrixSource else { throw Failure.unavailable }
        try Task.checkCancellation()
        guard let source = await resolveMatrixSource(file) else { throw Failure.unavailable }
        try Task.checkCancellation()
        let result = await mediaProvider.loadFileFromSource(source, filename: file.filename)
        try Task.checkCancellation()
        let handle = try result.get()
        guard let sdkURL = handle.url else { throw Failure.unavailable }
        let directory = URL.temporaryDirectory.appending(path: "disk-original-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileExtension = file.mimetype == "image/jpeg" ? "jpg" : file.mimetype == "image/png" ? "png" : "webp"
        let destination = directory.appending(path: "original." + fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            // The SDK handle owns sdkURL. Keep it alive through copying; clean up only our new directory.
            try withExtendedLifetime(handle) {
                try FileManager.default.copyItem(at: sdkURL, to: destination)
            }
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func original(for file: DiskFile, mediaProvider: MediaProviderProtocol?,
                         resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?) async throws -> MediaFileHandleProxy {
        guard let mediaProvider else { throw Failure.unavailable }
        let source = try await source(for: file, resolveMatrixSource: resolveMatrixSource)
        try Task.checkCancellation()
        let result = await mediaProvider.loadFileFromSource(source, filename: file.filename)
        try Task.checkCancellation()
        // The caller retains this exact SDK handle for preview; it must not copy or delete its URL.
        return try result.get()
    }
}
