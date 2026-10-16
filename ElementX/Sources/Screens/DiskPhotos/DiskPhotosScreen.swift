// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DiskPhotosScreen: View {
    @StateObject private var model: DiskPhotosViewModel
    let mediaProvider: MediaProviderProtocol?
    let callActive: Bool
    let openMatrix: (DiskFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: DiskPhoto?
    @State private var accessAlbum: DiskPhotoAlbum?
    @State private var selecting = false
    @State private var creation = false
    @State private var creationKind = "album"
    @State private var creationName = ""
    @State private var showFilters = false
    @State private var allowDuringCall = false

    init(service: DiskPhotoService, mediaProvider: MediaProviderProtocol?, callActive: Bool, openMatrix: @escaping (DiskFile) -> Void) {
        _model = StateObject(wrappedValue: DiskPhotosViewModel(service: service))
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
                    Spacer()
                    Text("\(model.displayed.count)").foregroundStyle(.secondary)
                    Button { selecting.toggle(); model.selected = [] } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle") }.accessibilityLabel("Выбрать фото")
                    Button { showFilters = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("Фильтры фото")
                }.padding(.horizontal)
                if paused {
                    HStack { Text("Загрузка фото приостановлена на время звонка.").font(.caption); Button("Продолжить") { allowDuringCall = true } }.padding(.horizontal)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal); Button(L10n.actionRetry) { model.load() } }
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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                        ForEach(model.displayed) { photo in
                            Button {
                                if selecting { if model.selected.contains(photo.id) { model.selected.remove(photo.id) } else { model.selected.insert(photo.id) } }
                                else if let matrix = photo.matrixFile { dismiss(); openMatrix(matrix) }
                                else { selectedPhoto = photo }
                            } label: {
                                VStack {
                                    DiskPhotoThumbnail(photo: photo, service: model.service, mediaProvider: mediaProvider, paused: paused)
                                        .frame(height: 100).frame(maxWidth: .infinity).clipped()
                                        .overlay(alignment: .topTrailing) { if model.selected.contains(photo.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, StalkTheme.accent) } }
                                    Text(photo.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                }
                            }.buttonStyle(.plain)
                                .contextMenu {
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
                    }.padding()
                }.refreshable { model.load() }
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
                        Button("Личная система") { creationKind = "system"; creationName = ""; creation = true }
                        Button("Сохранить условия как коллекцию") { creationKind = "filter"; creationName = ""; creation = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("Название коллекции", isPresented: $creation) {
                TextField("Название", text: $creationName)
                Button(L10n.actionCancel, role: .cancel) { }
                Button("Создать") {
                    let name = creationName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
                    model.perform {
                        if creationKind.hasPrefix("rename-system:"), let id = Int(creationKind.dropFirst(14)) {
                            try await model.service.systemChange(action: "save", extra: ["id": id, "name": name, "aliases": model.systems.first(where: { $0.id == id })?.aliases ?? []])
                        } else if creationKind.hasPrefix("rename-album:"), let id = Int(creationKind.dropFirst(13)) {
                            try await model.service.renameAlbum(id, name: name)
                        } else if creationKind == "system" { try await model.service.systemChange(action: "save", extra: ["name": name, "aliases": []]) }
                        else if creationKind == "filter" { var criteria = model.criteria; criteria.query = model.query; try await model.service.saveFilter(name: name, criteria: criteria) }
                        else { _ = try await model.service.createAlbum(name: name) }
                    }
                }
            }
            .sheet(item: $selectedPhoto) { photo in DiskPhotoDetailScreen(photo: photo, service: model.service, paused: paused) { model.load() } }
            .sheet(item: $accessAlbum) { album in DiskPhotoAlbumAccessScreen(album: album, service: model.service) { model.load() } }
            .sheet(isPresented: $showFilters) { filterSheet }
            .task { model.load() }
            .onDisappear { model.stop() }
            .onChange(of: callActive) { if !callActive { allowDuringCall = false } }
        }
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
                    Button("Переименовать") { creationKind = "rename-system:\(system.id)"; creationName = system.name; creation = true }
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
                    Button("Применить") { model.criteria = filter.criteria; model.query = filter.criteria.query ?? ""; model.choose("all"); model.load() }
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
            Menu("Система") {
                ForEach(model.systems) { system in
                    Button(system.name) { let references = model.references; model.perform { try await model.service.assign(references, system: system.id) } }
                }
            }
        }.font(.subheadline)
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
                TextField("Номер папки", text: Binding(get: { model.criteria.folder.map(String.init) ?? "" }, set: { model.criteria.folder = Int($0) })).keyboardType(.numberPad)
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
    let photo: DiskPhoto; let service: DiskPhotoService; let mediaProvider: MediaProviderProtocol?; let paused: Bool
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if paused { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            else if let matrix = photo.matrixFile, !matrix.isEncrypted, let url = URL(string: matrix.mxcURL), let source = try? MediaSourceProxy(url: url, mimeType: matrix.mimetype) {
                LoadableImage(mediaSource: source, mediaType: .generic, size: .init(width: 160, height: 160), mediaProvider: mediaProvider) { ProgressView() }
            } else { Image(systemName: photo.matrixFile?.isEncrypted == true ? "lock.fill" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: photo.id + String(paused)) {
            guard !paused, photo.reference.blobId != nil else { return }
            image = try? await service.thumbnail(photo)
        }
    }
}
