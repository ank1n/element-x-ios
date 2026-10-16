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
                                          added: Date(timeIntervalSince1970: Double($0.addedTs ?? $0.ts) / 1000), exif: $0.photo, starred: $0.starred ?? false, canDownload: $0.canDownload ?? true, folderID: $0.folderId, owner: $0.owner, tags: $0.tags ?? [], modified: Date(timeIntervalSince1970: Double($0.ts) / 1000)) }, response.hasMore ?? (response.docs.count == 100))
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

    func filters() async throws -> [DiskPhotoSavedFilter] {
        struct Response: Decodable { let filters: [DiskPhotoSavedFilter] }
        return try await JSONDecoder().decode(Response.self, from: disk.photoRequest(path: "photo-filters")).filters
    }

    func saveFilter(name: String, criteria: DiskPhotoFilterConditions) async throws {
        guard criteria.valid else { throw DiskServiceError.invalidURL }
        var criteria = criteria
        criteria.dateBasis = criteria.dateBasis ?? "taken"
        let body: [String: Any] = try ["name": name, "album": true, "criteria": JSONSerialization.jsonObject(with: JSONEncoder().encode(criteria))]
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
