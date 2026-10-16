// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation

@MainActor
final class DiskPhotosViewModel: ObservableObject {
    @Published private(set) var photos: [DiskPhoto] = []
    @Published private(set) var folders: [DiskPhotoFolder] = []
    @Published var activeFilterID: Int?
    @Published var albumQuery = ""
    @Published var albumSort = "recent"
    @Published private(set) var albums: [DiskPhotoAlbum] = []
    @Published private(set) var systems: [DiskPhotoSystem] = []
    @Published private(set) var savedFilters: [DiskPhotoSavedFilter] = []
    @Published private(set) var assignments: [String: DiskPhotoAssignment] = [:]
    @Published private(set) var loading = false
    @Published private(set) var complete = false
    @Published var error: String?
    @Published var query = ""
    @Published var collection = "all"
    @Published var selected = Set<String>()
    @Published var criteria = DiskPhotoFilterConditions(dateBasis: "taken")
    @Published private(set) var pinned: [String] = []
    @Published private(set) var hidden: [String] = []
    @Published private(set) var activeAlbumItems = Set<String>()
    @Published private(set) var albumLoading = false
    private var activeAlbumReferences: [DiskPhotoReference] = []
    let service: DiskPhotoService
    private var task: Task<Void, Never>?
    private var albumTask: Task<Void, Never>?
    private var revision = 0
    private var albumRevision = 0
    private let matrixPageLimit: Int

    init(service: DiskPhotoService, matrixPageLimit: Int = 500) {
        self.service = service
        self.matrixPageLimit = min(500, max(1, matrixPageLimit))
    }

    func stop() {
        task?.cancel(); albumTask?.cancel(); revision += 1; albumRevision += 1; loading = false; albumLoading = false
    }

    var activeAlbum: DiskPhotoAlbum? {
        guard collection.hasPrefix("album:"), let id = Int(collection.dropFirst(6)) else { return nil }; return albums.first { $0.id == id }
    }

    var references: [DiskPhotoReference] {
        photos.filter { selected.contains($0.id) }.map(\.reference)
    }

    var displayed: [DiskPhoto] {
        guard criteria.valid else { return [] }
        let now = Date(); let calendar = Calendar.current
        let included = criteria.folder.flatMap { $0 == 0 ? nil : DiskPhotoFolder.descendants(of: [$0], in: folders) }
        let excluded = DiskPhotoFolder.descendants(of: Set(criteria.excludedFolders ?? []), in: folders)
        let albumFolders = DiskPhotoFolder.descendants(of: Set(folders.filter { $0.kind == "album" && $0.trashed != true }.map(\.id)), in: folders)
        return photos.filter { photo in
            let metadata = assignments[photo.id]
            let date = criteria.dateBasis == "modified" ? photo.modified ?? photo.added : criteria.dateBasis == "added" ? photo.added : photo.taken
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            if let from = criteria.from, !from.isEmpty, let boundary = formatter.date(from: from), date < boundary { return false }
            if let to = criteria.to, !to.isEmpty, let boundary = formatter.date(from: to).flatMap({ calendar.date(byAdding: .day, value: 1, to: $0) }), date >= boundary { return false }
            if let folder = photo.folderID, excluded.contains(folder) { return false }
            if let included, photo.folderID.map({ included.contains($0) }) != true { return false }
            if let owner = criteria.owner, !owner.isEmpty, photo.owner != owner { return false }
            if let tag = criteria.tag, !tag.isEmpty, !photo.tags.contains(tag) { return false }
            if let format = criteria.format, !format.isEmpty, !(format.hasSuffix("/") ? photo.mimetype.hasPrefix(format) : photo.mimetype == format) { return false }
            if let category = criteria.category, !category.isEmpty {
                let matches = category == "images" ? photo.mimetype.hasPrefix("image/") : category == "media" ? photo.mimetype.hasPrefix("video/") || photo.mimetype.hasPrefix("audio/") : !photo.mimetype.hasPrefix("image/") && !photo.mimetype.hasPrefix("video/") && !photo.mimetype.hasPrefix("audio/")
                if !matches { return false }
            }
            if collection.hasPrefix("album:") { return activeAlbumItems.contains(photo.id) }
            if collection.hasPrefix("system:"), let id = Int(collection.dropFirst(7)) { return metadata?.includes(system: id) == true }
            if collection.hasPrefix("category:") { return metadata?.categories?.contains(String(collection.dropFirst(9))) == true }
            switch collection {
            case "week": return photo.taken >= calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
            case "last-month":
                let current = calendar.dateInterval(of: .month, for: now)!
                let previous = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .day, value: -1, to: current.start)!)!
                return previous.contains(photo.taken)
            case "recent": return photo.added >= calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
            case "favorites": return photo.starred
            case "unfiled": return metadata != nil && metadata?.organized != true && metadata?.systems?.isEmpty != false && !albumFolders.contains(photo.folderID ?? -1)
            default: return true
            }
        }.sorted { first, second in
            if activeAlbum != nil { return (activeAlbumReferences.firstIndex(where: { $0.key == first.id }) ?? Int.max) < (activeAlbumReferences.firstIndex(where: { $0.key == second.id }) ?? Int.max) }
            return (criteria.dateBasis == "modified" ? first.modified ?? first.added : criteria.dateBasis == "added" ? first.added : first.taken) > (criteria.dateBasis == "modified" ? second.modified ?? second.added : criteria.dateBasis == "added" ? second.added : second.taken)
        }
    }

    var visibleAlbums: [DiskPhotoAlbum] {
        albums.filter { albumQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.localizedCaseInsensitiveContains(albumQuery.trimmingCharacters(in: .whitespacesAndNewlines)) }.sorted {
            if albumSort == "recent", $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var monthGroups: [(date: Date, photos: [DiskPhoto])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: displayed) { photo in
            calendar.dateInterval(of: .month, for: criteria.dateBasis == "added" ? photo.added : criteria.dateBasis == "modified" ? photo.modified ?? photo.added : photo.taken)?.start ?? photo.added
        }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var activeSystemID: Int? {
        collection.hasPrefix("system:") ? Int(collection.dropFirst(7)) : nil
    }

    var suggestedPhotos: [DiskPhoto] {
        guard let id = activeSystemID else { return [] }
        return displayed.filter { assignments[$0.id]?.suggestions?.contains(where: { $0.id == id }) == true && assignments[$0.id]?.systems?.contains(id) != true }
    }

    func apply(_ filter: DiskPhotoSavedFilter) {
        criteria = filter.criteria; query = filter.criteria.query ?? ""; activeFilterID = filter.id
        choose("all"); load()
    }

    func savedFilterDidChange(_ filter: DiskPhotoSavedFilter) {
        if let index = savedFilters.firstIndex(where: { $0.id == filter.id }) { savedFilters[index] = filter }
        if activeFilterID == filter.id {
            criteria = filter.criteria
            query = filter.criteria.query ?? ""
        }
        load()
    }

    func choose(_ value: String) {
        albumTask?.cancel(); albumRevision += 1; let albumVersion = albumRevision
        activeAlbumReferences = []; activeAlbumItems = []; albumLoading = false
        collection = value; selected = []
        if let album = activeAlbum {
            albumTask?.cancel()
            albumLoading = true
            albumTask = Task {
                defer { if albumRevision == albumVersion { albumLoading = false } }
                do {
                    let items = try await service.albumItems(album.id)
                    guard !Task.isCancelled, albumRevision == albumVersion, activeAlbum?.id == album.id else { return }
                    activeAlbumReferences = items; activeAlbumItems = Set(items.map(\.key))
                    var offset = 0; var more = true
                    while more {
                        let page = try await service.photos(offset: offset, query: query, album: album.id)
                        guard !Task.isCancelled, albumRevision == albumVersion, activeAlbum?.id == album.id else { return }
                        merge(page.photos, replaceExisting: true); more = page.more; offset += 100
                    }
                    let metadata = try await service.assignments(photos.filter { activeAlbumItems.contains($0.id) })
                    guard !Task.isCancelled, albumRevision == albumVersion else { return }
                    for entry in metadata {
                        assignments[entry.item.key] = entry
                    }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }

    func load() {
        guard criteria.valid else { error = NSLocalizedString("Проверьте даты и условия фильтра. Неверные условия не были применены.", comment: "Invalid photo filter conditions"); return }
        albumTask?.cancel(); albumRevision += 1; albumLoading = false
        task?.cancel(); revision += 1; let version = revision
        loading = true; complete = false; error = nil; selected = []
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            var partialWarnings = Set<String>()
            defer { if revision == version { loading = false } }
            do {
                async let folderResult = service.folders()
                async let albumResult = service.albums()
                async let systemsResult = service.systems()
                async let filterResult = service.filters()
                let loadedFolders = try await folderResult
                let loadedAlbums = try await albumResult
                var state = try await systemsResult
                if state.initialized == false { try await service.systemChange(action: "initialize"); state = try await service.systems() }
                let loadedFilters = try await filterResult
                guard !Task.isCancelled, revision == version else { return }
                folders = loadedFolders; albums = loadedAlbums; savedFilters = loadedFilters
                systems = state.systems; pinned = state.pinned ?? []; hidden = state.hidden ?? []
                photos = []; assignments = [:]
                var offset = 0; var more = true
                while more {
                    let page = try await service.photos(offset: offset, query: search)
                    guard !Task.isCancelled, revision == version else { return }
                    merge(page.photos, replaceExisting: true); more = page.more; offset += 100
                    if offset > 50000, more { throw SystemSearchError.failed(413) }
                }
                // Matrix files retain their room/event identity and SDK encryption path.
                var before: String?; var beforeID: String?; var seen = Set<String>()
                var matrixPages = 0
                repeat {
                    guard matrixPages < matrixPageLimit else {
                        partialWarnings.insert(DiskServiceError.incompleteListing.localizedDescription); break
                    }
                    let page = try await service.disk.fetchFiles(category: .images, before: before, beforeId: beforeID, query: search)
                    guard !Task.isCancelled, revision == version else { return }
                    matrixPages += 1
                    merge(page.files.compactMap(Self.fromMatrix))
                    if let warning = page.warning { partialWarnings.insert(warning) }
                    before = page.nextBefore; beforeID = page.nextBeforeId
                    if let before, !seen.insert(before + "|" + (beforeID ?? "")).inserted {
                        partialWarnings.insert(DiskServiceError.incompleteListing.localizedDescription); break
                    }
                } while before != nil
                let shared = try await service.disk.fetchSharedWithMe(query: search)
                guard !Task.isCancelled, revision == version else {
                    return
                }
                merge(shared.compactMap { file in
                    guard file.mimetype.hasPrefix("image/"), let id = file.blobID,
                          search.isEmpty || file.contentHit ||
                          ([file.name, file.owner, file.ownerDisplay ?? "", file.viaFolderName ?? "", file.fromPath ?? ""] + file.tags)
                          .contains(where: { $0.localizedCaseInsensitiveContains(search) }) else { return nil }
                    return DiskPhoto(reference: .init(source: "disk", blobId: id), name: file.name, mimetype: file.mimetype, added: file.addedTs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? file.date, exif: file.photo, starred: false, canDownload: file.canDownload && !file.needsKeys, folderID: file.folderId, owner: file.owner, tags: file.tags, modified: file.date)
                })
                var starredIDs = Set<String>(); var starredOffset = 0; var starredMore = true
                while starredMore {
                    let page = try await service.photos(offset: starredOffset, query: search, scope: "starred")
                    guard !Task.isCancelled, revision == version else { return }
                    starredIDs.formUnion(page.photos.map(\.id)); merge(page.photos, replaceExisting: true)
                    starredMore = page.more; starredOffset += 100
                    if starredOffset > 50000, starredMore { throw SystemSearchError.failed(413) }
                }
                for index in photos.indices where photos[index].reference.source == "disk" {
                    photos[index].starred = starredIDs.contains(photos[index].id)
                }
                let metadata = try await service.assignments(photos)
                guard !Task.isCancelled, revision == version else {
                    return
                }
                assignments = Dictionary(metadata.map { ($0.item.key, $0) }, uniquingKeysWith: { _, last in last })
                complete = partialWarnings.isEmpty
                error = partialWarnings.isEmpty ? nil : partialWarnings.sorted().joined(separator: "\n")
                if activeAlbum != nil { choose(collection) }
            } catch {
                if !Task.isCancelled, revision == version {
                    partialWarnings.insert(error.localizedDescription)
                    self.error = partialWarnings.sorted().joined(separator: "\n"); complete = false
                }
            }
        }
    }

    private func merge(_ items: [DiskPhoto], replaceExisting: Bool = false) {
        var indices = Dictionary(photos.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            if let index = indices[item.id] {
                if replaceExisting { photos[index] = item }
            } else {
                indices[item.id] = photos.count; photos.append(item)
            }
        }
    }

    private static func fromMatrix(_ file: DiskFile) -> DiskPhoto? {
        if let id = file.blobID { return .init(reference: .init(source: "disk", blobId: id), name: file.filename, mimetype: file.mimetype, added: file.date, starred: file.starred, canDownload: file.canDownload, folderID: file.folderID.flatMap(Int.init), owner: file.owner ?? file.sender) }
        guard let room = file.roomID, let event = file.eventID else { return nil }
        return .init(reference: .init(source: "matrix", roomId: room, eventId: event), name: file.filename, mimetype: file.mimetype, added: file.date, starred: file.starred, canDownload: !file.isEncrypted, matrixFile: file, folderID: file.folderID.flatMap(Int.init), owner: file.sender)
    }

    func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); load() }
            catch {
                // A multi-batch operation may already have saved some changes.
                let message = error.localizedDescription
                load(); self.error = message
            }
        }
    }

    func move(_ photo: DiskPhoto, delta: Int) {
        guard let album = activeAlbum, album.canManage, let current = activeAlbumReferences.firstIndex(where: { $0.key == photo.id }),
              activeAlbumReferences.indices.contains(current + delta) else { return }
        var refs = activeAlbumReferences; refs.swapAt(current, current + delta)
        perform { try await self.service.changeAlbum(album.id, items: refs, action: "order") }
    }

    func pin(_ id: String) {
        let next = pinned.contains(id) ? pinned.filter { $0 != id } : [id] + pinned
        perform { try await self.service.systemChange(action: "preferences", extra: ["pinned": next, "hidden": self.hidden]) }
    }
}
