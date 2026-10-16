// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct DiskPhotoReference: Codable, Hashable {
    let source: String
    var blobId: String?
    var roomId: String?
    var eventId: String?
    var addedBy: String?
    var position: Int?
    var key: String {
        source == "disk" ? "disk:\(blobId ?? "")" : "matrix:\(roomId ?? "")|\(eventId ?? "")"
    }

    var json: [String: Any] {
        var result: [String: Any] = ["source": source]
        if let blobId { result["blobId"] = blobId }; if let roomId { result["roomId"] = roomId }; if let eventId { result["eventId"] = eventId }
        return result
    }
}

struct DiskPhoto: Identifiable, Equatable {
    struct EXIF: Codable, Equatable { var takenAt: String?; var make: String?; var model: String?; var width: Int?; var height: Int?; var iso: Int? }
    let reference: DiskPhotoReference
    var name: String
    var mimetype: String
    var added: Date
    var exif: EXIF?
    var starred: Bool
    var canDownload: Bool
    var matrixFile: DiskFile?
    var folderID: Int?
    var owner: String?
    var tags: [String] = []
    var modified: Date?
    var snippet: String?
    var snippetMatch: String?
    var id: String {
        reference.key
    }

    var taken: Date {
        guard let raw = exif?.takenAt else { return added }
        let normal = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) ?? normal.date(from: raw) { return date }
        // EXIF may contain a local wall-clock value with no timezone; keep that date.
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: raw) { return date }
        }
        return added
    }
}

struct DiskPhotoAlbum: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    var description: String?
    var owner: String?
    var role: String?
    var count: Int?
    var members: Int?
    var coverBlobId: String?
    var coverMatrix: DiskPhotoReference?
    var updatedAt: Int64? = nil
    var canAdd: Bool {
        ["owner", "manage", "add"].contains(role ?? "")
    }

    var canManage: Bool {
        ["owner", "manage"].contains(role ?? "")
    }

    var isOwner: Bool {
        role == "owner"
    }
}

struct DiskPhotoSystem: Codable, Identifiable, Equatable { let id: Int; let name: String; var aliases: [String]? }
struct DiskPhotoAssignment: Decodable {
    struct Hint: Decodable { let id: String; let evidence: String }
    struct SystemHint: Decodable, Equatable { let id: Int; let evidence: String }
    let item: DiskPhotoReference
    var suggestions: [SystemHint]? = nil
    var systems: [Int]?
    var categories: [String]?
    var categorySuggestions: [Hint]?
    var organized: Bool?
}

struct DiskPhotoSystems: Decodable {
    let systems: [DiskPhotoSystem]
    var pinned: [String]?
    var hidden: [String]?
    var initialized: Bool?
    var supportsCategories: Bool?
}

struct DiskPhotoFilterConditions: Codable, Equatable {
    var query: String?
    var folder: Int?
    var excludedFolders: [Int]?
    var tag: String?
    var format: String?
    var dateBasis: String?
    var from: String?
    var to: String?
    var owner: String?
    var category: String?
    var valid: Bool {
        if let dateBasis, !["taken", "added", "modified"].contains(dateBasis) { return false }
        if let folder, folder < 0 { return false }
        if let excludedFolders, excludedFolders.count > 100 || excludedFolders.contains(where: { $0 <= 0 }) { return false }
        if (query?.count ?? 0) > 512 || (tag?.count ?? 0) > 64 || (owner?.utf8.count ?? 0) > 256 { return false }
        if let format, !["", "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "image/avif", "image/gif", "image/svg+xml", "video/"].contains(format) { return false }
        if let from, let to, !from.isEmpty, !to.isEmpty, from > to { return false }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        for text in [from, to].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return false }
        }
        if let category, !category.isEmpty, !["images", "media", "documents"].contains(category) { return false }
        return true
    }
}

struct DiskPhotoSavedFilter: Codable, Identifiable { let id: Int; let name: String; let criteria: DiskPhotoFilterConditions; var album: Bool? }
struct DiskPhotoAlbumMember: Codable, Identifiable { let user: String; let role: String; var display: String?; var id: String {
    user
} }

/// Photo-specific folder metadata also retains album timestamps and safe thumbnail covers.
struct DiskPhotoFolder: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    var parentId: Int? = nil
    var kind: String? = nil
    var trashed: Bool? = nil
    var updatedAt: Int64? = nil
    var coverBlobId: String? = nil

    static func descendants(of roots: Set<Int>, in folders: [Self]) -> Set<Int> {
        var result = roots
        var pending = Array(roots)
        let children = Dictionary(grouping: folders, by: { $0.parentId })
        while let id = pending.popLast() {
            for child in children[id] ?? [] where result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    func path(in folders: [Self]) -> String {
        var parts = [name]; var parent = parentId; var seen: Set<Int> = [id]
        while let id = parent, seen.insert(id).inserted, let folder = folders.first(where: { $0.id == id }) {
            parts.insert(folder.name, at: 0); parent = folder.parentId
        }
        return parts.joined(separator: " / ")
    }
}

extension DiskPhotoFilterConditions {
    func matchesFolder(_ id: Int?, folders: [DiskPhotoFolder]) -> Bool {
        let excluded = DiskPhotoFolder.descendants(of: Set(excludedFolders ?? []), in: folders)
        if let id, excluded.contains(id) { return false }
        guard let folder, folder != 0 else { return true }
        guard let id else { return false }
        return DiskPhotoFolder.descendants(of: [folder], in: folders).contains(id)
    }
}

extension DiskPhotoAssignment {
    func includes(system: Int) -> Bool {
        systems?.contains(system) == true || suggestions?.contains(where: { $0.id == system }) == true
    }
}

/// A slide becomes eligible for its display timer only after that exact photo loads.
struct DiskPhotoSlideshow {
    var playing = false
    private(set) var photoID: String?
    private(set) var ready = false

    mutating func beginLoading(_ id: String) {
        photoID = id; ready = false
    }

    mutating func loaded(_ id: String) {
        guard photoID == id else { return }
        ready = true
    }

    mutating func failed(_ id: String) {
        guard photoID == id else { return }
        ready = false; playing = false
    }

    func canAdvance(_ id: String) -> Bool {
        playing && ready && photoID == id
    }
}
