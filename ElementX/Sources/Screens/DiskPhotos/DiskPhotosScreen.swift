// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DiskPhotosScreen: View {
    @StateObject private var model: DiskPhotosViewModel
    let mediaProvider: MediaProviderProtocol?
    let callActive: Bool
    let openMatrix: (DiskFile) -> Void
    let resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: DiskPhoto?
    @State private var accessAlbum: DiskPhotoAlbum?
    @State private var selecting = false
    @State private var creation = false
    @State private var creationKind = "album"
    @State private var creationName = ""
    @State private var creationAliases = ""
    @State private var overview = false
    @State private var editingFilter: DiskPhotoSavedFilter?
    @State private var assignmentPhotos: [DiskPhoto] = []
    @State private var assigning = false
    @State private var showFilters = false
    @State private var allowDuringCall = false

    init(service: DiskPhotoService, mediaProvider: MediaProviderProtocol?, callActive: Bool, resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)? = nil, openMatrix: @escaping (DiskFile) -> Void) {
        _model = StateObject(wrappedValue: DiskPhotosViewModel(service: service))
        self.resolveMatrixSource = resolveMatrixSource
        self.mediaProvider = mediaProvider; self.callActive = callActive; self.openMatrix = openMatrix
    }

    private var paused: Bool {
        callActive && !allowDuringCall
    }

    private let names = [
        "all": NSLocalizedString("Все фото", comment: "Built-in photo collection name"),
        "week": NSLocalizedString("Последние 7 дней", comment: "Built-in photo collection name"),
        "last-month": NSLocalizedString("Прошлый месяц", comment: "Built-in photo collection name"),
        "recent": NSLocalizedString("Недавно добавленные", comment: "Built-in photo collection name"),
        "favorites": NSLocalizedString("Избранное", comment: "Built-in photo collection name"),
        "unfiled": NSLocalizedString("Неразобранное", comment: "Built-in photo collection name"),
        "category:errors": NSLocalizedString("Ошибки", comment: "Built-in photo collection name"),
        "category:interfaces": NSLocalizedString("Интерфейсы", comment: "Built-in photo collection name"),
        "category:reports": NSLocalizedString("Отчёты", comment: "Built-in photo collection name")
    ]
    private func roleName(_ role: String) -> String {
        [
            "read": NSLocalizedString("Чтение", comment: "Photo album access role"),
            "add": NSLocalizedString("Добавление своих фото", comment: "Photo album access role"),
            "manage": NSLocalizedString("Управление альбомом", comment: "Photo album access role"),
            "owner": NSLocalizedString("Владелец", comment: "Photo album access role")
        ][role] ?? role
    }

    private func title(_ id: String) -> String {
        if let value = names[id] { return value }
        if id.hasPrefix("system:"), let system = model.systems.first(where: { id == "system:\($0.id)" }) { return system.name }
        if let album = model.albums.first(where: { id == "album:\($0.id)" }) { return album.name }
        return id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    Menu(title(model.collection)) { collectionMenu }
                    Button(overview ? NSLocalizedString("Фото", comment: "Show photos") : NSLocalizedString("Альбомы", comment: "Show albums")) { overview.toggle() }
                    Spacer()
                    Text("\(model.displayed.count)").foregroundStyle(.secondary)
                    Button { selecting.toggle(); model.selected = [] } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle") }.accessibilityLabel("Выбрать фото")
                    Button { showFilters = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("Фильтры фото")
                }.padding(.horizontal)
                if paused {
                    HStack { Text("Загрузка фото приостановлена на время звонка.").font(.caption); Button("Продолжить") { allowDuringCall = true } }.padding(.horizontal)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal); Button(L10n.actionRetry) { model.load() } }
                if let filter = model.savedFilters.first(where: { $0.id == model.activeFilterID }) {
                    HStack {
                        Text(String(format: filter.album == true ? NSLocalizedString("stalk_photos_filter_autoalbum", comment: "Auto album name") : NSLocalizedString("stalk_photos_filter_preset", comment: "Preset name"), filter.name)).font(.caption)
                        Button("Изменить") { editingFilter = filter }
                    }
                }
                if model.loading || model.albumLoading { ProgressView("Загружаем каталог…") }
                if !model.complete, !model.loading, model.error == nil { Text("Каталог загружен не полностью").font(.caption) }
                if selecting, !model.selected.isEmpty { selectionActions.padding(.horizontal) }
                if let album = model.activeAlbum {
                    HStack {
                        Text(String(format: NSLocalizedString("stalk_photos_album_members", comment: "Album access role and member count"), roleName(album.role ?? "read"), Int64(album.members ?? 0))).font(.caption)
                        if album.isOwner { Button("Доступ") { accessAlbum = album } }
                        if album.canAdd, !model.selected.isEmpty {
                            Button("Убрать из альбома") { let refs = model.references; model.perform { try await model.service.changeAlbum(album.id, items: refs, action: "remove") } }
                        }
                    }
                }
                if let system = model.activeSystemID {
                    HStack {
                        Text(String(format: NSLocalizedString("stalk_photos_suggested_count", comment: "Suggested photo count"), Int64(model.suggestedPhotos.count))).font(.caption)
                        Button("Подтвердить предложения") {
                            let refs = model.suggestedPhotos.map(\.reference)
                            model.perform { try await model.service.assignSystems(refs, systems: [system], mode: "add") }
                        }.disabled(model.suggestedPhotos.isEmpty)
                    }
                }
                if overview { albumOverview } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                            ForEach(model.activeAlbum == nil ? model.monthGroups : [(date: Date.distantPast, photos: model.displayed)], id: \.date) { group in
                                if model.activeAlbum == nil {
                                    Section(header: Text(group.date.formatted(.dateTime.year().month(.wide))).font(.headline)) {
                                        ForEach(group.photos) { photo in photoCard(photo) }
                                    }
                                } else { ForEach(group.photos) { photo in photoCard(photo) } }
                            }
                        }.padding()
                    }.refreshable { model.load() }
                }
            }
            .navigationTitle("Фото и коллекции")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "Название или текст на фото (OCR)")
            .onSubmit(of: .search) { model.load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Новый альбом") { creationKind = "album"; creationName = ""; creation = true }
                        Button("Личная система") { creationAliases = ""; creationKind = "system"; creationName = ""; creation = true }
                        Button("Сохранить пресет") { creationKind = "preset"; creationName = ""; creation = true }
                        Button("Создать автоальбом") { creationKind = "filter"; creationName = ""; creation = true }
                        if let filter = model.savedFilters.first(where: { $0.id == model.activeFilterID }) {
                            Button("Обновить сохранённые условия") { saveFilter(filter) }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("Название коллекции", isPresented: $creation) {
                TextField("Название", text: $creationName)
                if creationKind == "system" || creationKind.hasPrefix("rename-system:") { TextField("Синонимы и сайты (через запятую)", text: $creationAliases) }
                Button(L10n.actionCancel, role: .cancel) { }
                Button(creationKind.hasPrefix("rename-") ? NSLocalizedString("Сохранить", comment: "Save collection name") : NSLocalizedString("Создать", comment: "Create collection")) {
                    let name = creationName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
                    model.perform {
                        if creationKind.hasPrefix("rename-system:"), let id = Int(creationKind.dropFirst(14)) {
                            try await model.service.systemChange(action: "save", extra: ["id": id, "name": name, "aliases": aliases])
                        } else if creationKind.hasPrefix("rename-album:"), let id = Int(creationKind.dropFirst(13)) {
                            try await model.service.renameAlbum(id, name: name)
                        } else if creationKind == "system" { try await model.service.systemChange(action: "save", extra: ["name": name, "aliases": aliases]) }
                        else if creationKind == "filter" || creationKind == "preset" { var criteria = model.criteria; criteria.query = model.query; try await model.service.saveFilter(name: name, criteria: criteria, album: creationKind == "filter") }
                        else { _ = try await model.service.createAlbum(name: name) }
                    }
                }
            }
            .sheet(item: $selectedPhoto) { photo in DiskPhotoDetailScreen(photo: photo, service: model.service, paused: paused, saved: { model.load() }, sequence: model.displayed, mediaProvider: mediaProvider, openMatrix: openMatrix, resolveMatrixSource: resolveMatrixSource) }
            .sheet(isPresented: $assigning) { DiskPhotoSystemAssignmentScreen(photos: assignmentPhotos, systems: model.systems, assignments: model.assignments, service: model.service) { model.load() } }
            .sheet(item: $editingFilter) { filter in DiskPhotoSavedFilterEditor(filter: filter, folders: model.folders, service: model.service, onSave: { model.savedFilterDidChange($0) }) { model.load() } }
            .sheet(item: $accessAlbum) { album in DiskPhotoAlbumAccessScreen(album: album, service: model.service) { model.load() } }
            .sheet(isPresented: $showFilters) { filterSheet }
            .task { model.load() }
            .onDisappear { model.stop() }
            .onChange(of: callActive) { if !callActive { allowDuringCall = false } }
        }
    }

    private func photoCard(_ photo: DiskPhoto) -> some View {
        Button {
            if selecting { if model.selected.contains(photo.id) { model.selected.remove(photo.id) } else { model.selected.insert(photo.id) } }
            else { selectedPhoto = photo }
        } label: {
            VStack {
                DiskPhotoThumbnail(photo: photo, service: model.service, mediaProvider: mediaProvider, paused: paused, resolveMatrixSource: resolveMatrixSource)
                    .frame(height: 100).frame(maxWidth: .infinity).clipped()
                    .overlay(alignment: .topTrailing) { if model.selected.contains(photo.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, StalkTheme.accent) } }
                Text(photo.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                if let snippet = photo.snippet, !snippet.isEmpty { DiskPhotoSnippet(photo: photo).lineLimit(2) }
                if let hints = model.assignments[photo.id]?.suggestions {
                    ForEach(hints, id: \.id) { hint in Text(hint.evidence).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Назначения систем") { assignmentPhotos = [photo]; assigning = true }
                if let hints = model.assignments[photo.id]?.suggestions {
                    ForEach(hints, id: \.id) { hint in
                        Button(String(format: NSLocalizedString("stalk_photos_confirm_system", comment: "Confirm suggested photo system"), title("system:\(hint.id)"))) { model.perform { try await model.service.assignSystems([photo.reference], systems: [hint.id], mode: "add") } }
                        Button(String(format: NSLocalizedString("stalk_photos_reject_system", comment: "Reject suggested photo system"), title("system:\(hint.id)"))) { model.perform { try await model.service.assignSystems([photo.reference], systems: [hint.id], mode: "reject") } }
                    }
                }
                Button(photo.starred ? NSLocalizedString("Убрать из избранного", comment: "Photo favorites action") : NSLocalizedString("В избранное", comment: "Photo favorites action")) { model.perform { try await model.service.star(photo, value: !photo.starred) } }
                if let album = model.activeAlbum, album.canManage {
                    Button("На позицию выше") { model.move(photo, delta: -1) }
                    Button("На позицию ниже") { model.move(photo, delta: 1) }
                    Button("На обложку") { model.perform { try await model.service.changeAlbum(album.id, items: [photo.reference], action: "cover") } }
                }
                if let hints = model.assignments[photo.id]?.categorySuggestions {
                    ForEach(hints, id: \.id) { hint in
                        Button(String(format: NSLocalizedString("stalk_photos_confirm_category", comment: "Confirm suggested photo category"), title("category:" + hint.id))) { model.perform { try await model.service.assign([photo.reference], category: hint.id) } }
                        Button(String(format: NSLocalizedString("stalk_photos_reject_category", comment: "Reject suggested photo category"), title("category:" + hint.id))) { model.perform { try await model.service.assign([photo.reference], category: hint.id, reject: true) } }
                    }
                }
            }
    }

    private var albumOverview: some View {
        ScrollView {
            VStack {
                TextField("Найти альбом", text: $model.albumQuery).textFieldStyle(.roundedBorder)
                Picker("Порядок", selection: $model.albumSort) { Text("Недавно изменённые").tag("recent"); Text("По названию").tag("name") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))]) {
                    ForEach(model.visibleAlbums) { album in
                        Button { overview = false; model.choose("album:\(album.id)") } label: {
                            VStack {
                                if let cover = albumCover(album) {
                                    DiskPhotoThumbnail(photo: cover, service: model.service, mediaProvider: mediaProvider, paused: paused, resolveMatrixSource: resolveMatrixSource).frame(height: 110).clipped()
                                } else { Image(systemName: "photo.on.rectangle").frame(height: 110) }
                                Text(album.name); Text(String(format: NSLocalizedString("stalk_photos_photo_count", comment: "Album photo count"), Int64(album.count ?? 0))).font(.caption)
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.folders.filter { $0.kind == "album" && $0.trashed != true && (model.albumQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(model.albumQuery)) }.sorted { model.albumSort == "recent" ? ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                        Button {
                            model.criteria.folder = folder.id; model.activeFilterID = nil; overview = false; model.choose("all"); model.load()
                        } label: {
                            VStack {
                                if let blob = folder.coverBlobId { DiskPhotoThumbnail(photo: coverPhoto(blob), service: model.service, mediaProvider: mediaProvider, paused: paused, resolveMatrixSource: resolveMatrixSource).frame(height: 110).clipped() }
                                else { Image(systemName: "folder").frame(height: 110) }
                                Text(folder.name)
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.savedFilters.filter { $0.album == true && (model.albumQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(model.albumQuery)) }) { filter in
                        Button { overview = false; model.apply(filter) } label: { VStack { Image(systemName: "line.3.horizontal.decrease.circle"); Text(filter.name); Text("Автоальбом").font(.caption) } }
                    }
                }
            }.padding()
        }
    }

    private func coverPhoto(_ blob: String) -> DiskPhoto {
        DiskPhoto(reference: .init(source: "disk", blobId: blob), name: "", mimetype: "image/jpeg", added: .distantPast, starred: false, canDownload: false)
    }

    private func albumCover(_ album: DiskPhotoAlbum) -> DiskPhoto? {
        if let ref = album.coverMatrix { return model.photos.first { $0.reference.key == ref.key } }
        return album.coverBlobId.map(coverPhoto)
    }

    @ViewBuilder private var collectionMenu: some View {
        Button("Все фото") { model.choose("all") }
        Section("Закреплённые") { ForEach(model.pinned.filter { !model.hidden.contains($0) }, id: \.self) { collectionItem($0) } }
        Section("Подборки") { ForEach(["week", "last-month", "recent", "favorites", "unfiled", "category:errors", "category:interfaces", "category:reports"].filter { !model.hidden.contains($0) }, id: \.self) { collectionItem($0) } }
        Section("Личные системы") {
            ForEach(model.systems) { system in
                Menu(system.name) {
                    Button("Открыть") { model.choose("system:\(system.id)") }
                    Button("Закрепить / открепить") { model.pin("system:\(system.id)") }
                    Button("Название и синонимы") { creationAliases = (system.aliases ?? []).joined(separator: ", "); creationKind = "rename-system:\(system.id)"; creationName = system.name; creation = true }
                    Menu("Объединить с…") {
                        ForEach(model.systems.filter { $0.id != system.id }) { other in
                            Button(other.name) { model.perform { try await model.service.systemChange(action: "merge", extra: ["id": system.id, "target": other.id]) } }
                        }
                    }
                    Button("Удалить систему", role: .destructive) { model.perform { try await model.service.systemChange(action: "delete", extra: ["id": system.id]) } }
                }
            }
        }
        Section("Альбомы") {
            ForEach(model.albums) { album in
                Menu(String(format: NSLocalizedString("stalk_photos_album_count", comment: "Album name and photo count"), album.name, Int64(album.count ?? 0))) {
                    Button("Открыть") { model.choose("album:\(album.id)") }
                    if album.isOwner {
                        Button("Переименовать") { creationKind = "rename-album:\(album.id)"; creationName = album.name; creation = true }
                        Button("Участники и доступ") { accessAlbum = album }
                        Button("Удалить альбом, сохранив фото", role: .destructive) { model.perform { try await model.service.deleteAlbum(album.id) } }
                    }
                }
            }
        }
        Section("Сохранённые условия") {
            ForEach(model.savedFilters) { filter in
                Menu(filter.name) {
                    Text(filter.album == true ? NSLocalizedString("Автоальбом", comment: "Saved filter kind") : NSLocalizedString("Пресет", comment: "Saved filter kind"))
                    Button("Применить") { overview = false; model.apply(filter) }
                    Button("Изменить") { editingFilter = filter }
                    Button("Заменить текущими условиями") { saveFilter(filter) }
                    Button("Удалить", role: .destructive) { model.perform { try await model.service.removeFilter(filter.id) } }
                }
            }
        }
        if !model.hidden.isEmpty {
            Menu("Скрытые подборки") {
                ForEach(model.hidden, id: \.self) { id in
                    Button(String(format: NSLocalizedString("stalk_photos_show_collection", comment: "Show hidden photo collection"), title(id))) { model.perform { try await model.service.systemChange(action: "preferences", extra: ["pinned": model.pinned, "hidden": model.hidden.filter { $0 != id }]) } }
                }
            }
        }
    }

    private func collectionItem(_ id: String) -> some View {
        Menu(title(id)) {
            Button("Открыть") { model.choose(id) }
            Button("Закрепить / открепить") { model.pin(id) }
            Button("Скрыть") { model.perform { try await model.service.systemChange(action: "preferences", extra: ["pinned": model.pinned, "hidden": model.hidden + [id]]) } }
        }
    }

    private var selectionActions: some View {
        HStack {
            Text(String(format: NSLocalizedString("stalk_photos_selected_count", comment: "Selected photo count"), Int64(model.selected.count))).font(.caption)
            Menu("В альбом") {
                ForEach(model.albums.filter(\.canAdd)) { album in
                    Button(album.name) { let references = model.references; model.perform { try await model.service.changeAlbum(album.id, items: references, action: "add") } }
                }
            }
            Menu("Категория") {
                ForEach(["errors", "interfaces", "reports"], id: \.self) { category in
                    Button(title("category:" + category)) { let references = model.references; model.perform { try await model.service.assign(references, category: category) } }
                }
            }
            Button("Системы") { assignmentPhotos = model.photos.filter { model.selected.contains($0.id) }; assigning = true }
            Menu("Добавить систему") {
                ForEach(model.systems) { system in
                    Button(system.name) { let references = model.references; model.perform { try await model.service.assign(references, system: system.id) } }
                }
            }
        }.font(.subheadline)
    }

    private var aliases: [String] {
        creationAliases.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func saveFilter(_ filter: DiskPhotoSavedFilter) {
        var criteria = model.criteria; criteria.query = model.query
        model.perform { try await model.service.saveFilter(name: filter.name, criteria: criteria, id: filter.id, album: filter.album ?? false) }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Picker("Дата", selection: Binding(get: { model.criteria.dateBasis ?? "taken" }, set: { model.criteria.dateBasis = $0 })) { Text("Съёмки / EXIF").tag("taken"); Text("Добавления").tag("added"); Text("Изменения").tag("modified") }
                TextField("С даты (yyyy-MM-dd)", text: Binding(get: { model.criteria.from ?? "" }, set: { model.criteria.from = $0 }))
                TextField("По дату (yyyy-MM-dd)", text: Binding(get: { model.criteria.to ?? "" }, set: { model.criteria.to = $0 }))
                Picker("Формат", selection: Binding(get: { model.criteria.format ?? "" }, set: { model.criteria.format = $0 })) {
                    Text("Любой").tag(""); Text("JPEG").tag("image/jpeg"); Text("PNG").tag("image/png"); Text("HEIC").tag("image/heic"); Text("WebP").tag("image/webp")
                }
                TextField("Владелец (@пользователь:сервер)", text: Binding(get: { model.criteria.owner ?? "" }, set: { model.criteria.owner = $0 }))
                TextField("Метка", text: Binding(get: { model.criteria.tag ?? "" }, set: { model.criteria.tag = $0 }))
                DiskPhotoFolderFields(criteria: $model.criteria, folders: model.folders)
                Picker("Содержимое", selection: Binding(get: { model.criteria.category ?? "" }, set: { model.criteria.category = $0 })) {
                    Text("Любое").tag(""); Text("Изображения").tag("images"); Text("Медиа").tag("media"); Text("Документы").tag("documents")
                }
            }.navigationTitle("Фильтры фото").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Сбросить") { model.criteria = .init(dateBasis: "taken") } }
                ToolbarItem(placement: .confirmationAction) { Button("Применить") { showFilters = false; model.load() } }
            }
        }
    }
}

struct DiskPhotoThumbnail: View {
    let photo: DiskPhoto
    let service: DiskPhotoService
    let mediaProvider: MediaProviderProtocol?
    let paused: Bool
    let resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?
    @State private var image: UIImage?

    init(photo: DiskPhoto, service: DiskPhotoService, mediaProvider: MediaProviderProtocol?, paused: Bool,
         resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)? = nil) {
        self.photo = photo; self.service = service; self.mediaProvider = mediaProvider
        self.paused = paused; self.resolveMatrixSource = resolveMatrixSource
    }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if paused { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            else { Image(systemName: photo.matrixFile?.isEncrypted == true ? "lock.fill" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: photo.id + String(paused)) {
            guard !paused else { return }
            image = nil
            let target = photo
            let loaded: UIImage?
            if let file = target.matrixFile {
                loaded = try? await DiskPhotoMatrixMedia.image(for: file, mediaProvider: mediaProvider,
                                                               resolveMatrixSource: resolveMatrixSource, size: CGSize(width: 160, height: 160))
            } else { loaded = try? await service.thumbnail(target) }
            guard !Task.isCancelled, target.id == photo.id else { return }
            image = loaded
        }
    }
}

struct DiskPhotoSnippet: View {
    let photo: DiskPhoto
    private var text: AttributedString {
        var value = AttributedString(photo.snippet ?? "")
        if let match = photo.snippetMatch, !match.isEmpty, let range = value.range(of: match) {
            value[range].font = .caption.bold()
        }
        return value
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(String(format: NSLocalizedString("stalk_photos_text_match", comment: "Photo text match accessibility label"), photo.snippet ?? ""))
    }
}

struct DiskPhotoFolderFields: View {
    @Binding var criteria: DiskPhotoFilterConditions
    let folders: [DiskPhotoFolder]
    private var visible: [DiskPhotoFolder] {
        folders.filter { $0.trashed != true }.sorted { $0.path(in: folders).localizedStandardCompare($1.path(in: folders)) == .orderedAscending }
    }

    var body: some View {
        Picker("Папка и вложенные", selection: Binding(get: { criteria.folder ?? 0 }, set: { criteria.folder = $0 })) {
            Text("Все папки").tag(0)
            ForEach(visible) { folder in Text(folder.path(in: folders)).tag(folder.id) }
            if let id = criteria.folder, id != 0, !visible.contains(where: { $0.id == id }) { Text(String(format: NSLocalizedString("stalk_photos_unavailable_folder", comment: "Unavailable photo folder"), Int64(id))).tag(id) }
        }
        DisclosureGroup("Исключить папки и вложенные") {
            ForEach(visible) { folder in
                Toggle(folder.path(in: folders), isOn: Binding(get: { criteria.excludedFolders?.contains(folder.id) == true }, set: { included in
                    var ids = Set(criteria.excludedFolders ?? [])
                    if included { ids.insert(folder.id) } else { ids.remove(folder.id) }
                    criteria.excludedFolders = ids.sorted()
                }))
            }
            ForEach((criteria.excludedFolders ?? []).filter { id in !visible.contains { $0.id == id } }, id: \.self) { id in
                Button(String(format: NSLocalizedString("stalk_photos_remove_unavailable_exclusion", comment: "Remove unavailable photo folder exclusion"), Int64(id))) { criteria.excludedFolders?.removeAll { $0 == id } }
            }
        }
    }
}

struct DiskPhotoSystemAssignmentScreen: View {
    let photos: [DiskPhoto]
    let systems: [DiskPhotoSystem]
    let assignments: [String: DiskPhotoAssignment]
    let service: DiskPhotoService
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<Int>()
    @State private var busy = false
    @State private var error: String?
    private var available: Bool {
        photos.allSatisfy { assignments[$0.id] != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                if !available { Text("Назначения недоступны. Обновите подборку перед изменением.") }
                Section(photos.count == 1 ? NSLocalizedString("Системы на снимке", comment: "Photo system assignment section") : NSLocalizedString("Добавить системы выбранным фото", comment: "Photo system assignment section")) {
                    ForEach(systems) { system in
                        Toggle(isOn: Binding(get: { chosen.contains(system.id) }, set: { value in
                            if value { chosen.insert(system.id) } else { chosen.remove(system.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(system.name)
                                if photos.count == 1, let photo = photos.first, let hint = assignments[photo.id]?.suggestions?.first(where: { $0.id == system.id }) {
                                    Text(String(format: NSLocalizedString("stalk_photos_ocr_suggestion", comment: "Photo system OCR evidence"), hint.evidence)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if photos.count == 1 { Text("Сохранение заменяет назначения. Снимите все отметки, чтобы убрать ошибочные назначения.").font(.footnote) }
            }.navigationTitle("Назначения систем")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    try await service.assignSystems(photos.map(\.reference), systems: chosen.sorted(), mode: photos.count == 1 ? "set" : "add")
                                    changed(); dismiss()
                                } catch { self.error = error.localizedDescription; changed() }
                            }
                        }.disabled(busy || !available || photos.isEmpty || (photos.count > 1 && chosen.isEmpty))
                    }
                }
                .onAppear { if photos.count == 1, let photo = photos.first { chosen = Set(assignments[photo.id]?.systems ?? []) } }
        }
    }
}

struct DiskPhotoSavedFilterEditor: View {
    let filter: DiskPhotoSavedFilter
    let folders: [DiskPhotoFolder]
    let service: DiskPhotoService
    let changed: () -> Void
    let onSave: ((DiskPhotoSavedFilter) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var criteria: DiskPhotoFilterConditions
    @State private var album: Bool
    @State private var busy = false
    @State private var error: String?
    init(filter: DiskPhotoSavedFilter, folders: [DiskPhotoFolder], service: DiskPhotoService, onSave: ((DiskPhotoSavedFilter) -> Void)? = nil, changed: @escaping () -> Void) {
        self.filter = filter; self.folders = folders; self.service = service; self.changed = changed; self.onSave = onSave
        _name = State(initialValue: filter.name); _criteria = State(initialValue: filter.criteria); _album = State(initialValue: filter.album ?? false)
    }

    private func field(_ key: WritableKeyPath<DiskPhotoFilterConditions, String?>) -> Binding<String> {
        Binding(get: { criteria[keyPath: key] ?? "" }, set: { criteria[keyPath: key] = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                TextField("Название", text: $name)
                Toggle("Автоальбом", isOn: $album)
                TextField("Название или текст OCR", text: field(\.query))
                DiskPhotoFolderFields(criteria: $criteria, folders: folders)
                TextField("Метка", text: field(\.tag))
                TextField("Владелец", text: field(\.owner))
                Picker("Дата", selection: field(\.dateBasis)) { Text("Съёмки").tag("taken"); Text("Добавления").tag("added"); Text("Изменения").tag("modified") }
                TextField("С даты (yyyy-MM-dd)", text: field(\.from))
                TextField("По дату (yyyy-MM-dd)", text: field(\.to))
                Picker("Формат", selection: field(\.format)) {
                    ForEach(["", "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "image/avif", "image/gif", "image/svg+xml", "video/"], id: \.self) { Text($0.isEmpty ? NSLocalizedString("Любой", comment: "Any photo format") : $0).tag($0) }
                }
                Picker("Содержимое", selection: field(\.category)) { Text("Любое").tag(""); Text("Изображения").tag("images"); Text("Медиа").tag("media"); Text("Документы").tag("documents") }
            }.navigationTitle("Сохранённые условия")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    let savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let savedAlbum = album
                                    var savedCriteria = criteria
                                    savedCriteria.dateBasis = savedCriteria.dateBasis ?? "taken"
                                    try await service.saveFilter(name: savedName, criteria: savedCriteria, id: filter.id, album: savedAlbum)
                                    let updated = DiskPhotoSavedFilter(id: filter.id, name: savedName, criteria: savedCriteria, album: savedAlbum)
                                    if let onSave { onSave(updated) } else { changed() }
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(busy || !criteria.valid || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
