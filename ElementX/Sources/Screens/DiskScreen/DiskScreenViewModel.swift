//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftUI

/// Файл для системного share sheet.
struct DiskShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Строка объединённого списка: свои файлы и расшаренные мне живут в разных
/// эндпоинтах и моделях, но dp ждёт их в ОДНОМ списке — мержим по времени.
enum DiskListEntry: Identifiable, Equatable {
    case own(DiskFile)
    case shared(DiskSharedFile)

    var id: String {
        switch self {
        case .own(let file): "o-\(file.id)"
        case .shared(let file): "s-\(file.id)"
        }
    }

    var ts: Int64 {
        switch self {
        case .own(let file): file.ts
        case .shared(let file): file.ts
        }
    }
}

enum DiskScreenViewModelAction {
    /// Файл зашифрован — открыть его можно только в чате, где есть ключи комнаты.
    /// Это же действие и «найти в чате»: перейти к сообщению, которым файл прислали.
    case openRoom(roomID: String, eventID: String)
    /// Переслать в другой чат. Содержимого события здесь нет — только ссылка на
    /// него; достаёт его флоу, у которого есть доступ к комнатам.
    case forward(roomID: String, eventID: String)
    /// Переслать СОДЕРЖИМЫМ (dp: «почему нет переслать» у расшаренных): файлы
    /// без Matrix-события уходят вложением через пикер комнат — тем же
    /// маршрутом, что и Share Extension.
    case forwardFile(url: URL, name: String)
    case dismiss
}

/// Как показывать файлы. Список плотнее и удобнее для документов, карточки — для
/// изображений, где решает превью, а не имя.
enum DiskLayout: String {
    case list
    case grid

    /// Кнопка показывает то, ВО ЧТО переключит, а не текущее состояние: иначе
    /// пользователь читает её как индикатор и жмёт не туда.
    var toggleIcon: String {
        switch self {
        case .list: "square.grid.2x2"
        case .grid: "list.bullet"
        }
    }

    var toggled: DiskLayout {
        self == .list ? .grid : .list
    }
}

@MainActor
final class DiskScreenViewModel: ObservableObject {
    @Published private(set) var files: [DiskFile] = []
    @Published private(set) var stats: DiskStats?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var selectedCategory: DiskFileCategory? {
        didSet {
            guard oldValue != selectedCategory else { return }
            Task { await reload() }
        }
    }

    /// Папки Диска (dp: «представление с разбитием по папкам» + переключатель).
    @Published private(set) var folders: [DiskFolder] = []
    /// Режим «по папкам»: экран показывает карточки папок вместо общего списка.
    /// Запоминается, как и список/карточки.
    @Published var showsFolders: Bool {
        didSet {
            guard oldValue != showsFolders else { return }
            UserDefaults.standard.set(showsFolders, forKey: Self.foldersKey)
            // Выход из режима сбрасывает открытую папку — иначе «Все» показывали
            // бы хвост последней папки.
            if showsFolders {
                prepareFoldersMode()
            } else {
                selectedFolder = nil
                showingNoFolder = false
                selectedChatRoomID = nil
            }
        }
    }

    /// Открытая папка: список показывает только её содержимое, сверху — «назад».
    @Published var selectedFolder: DiskFolder? {
        didSet {
            guard oldValue != selectedFolder else { return }
            Task { await reload() }
        }
    }

    /// Псевдо-папка «Вне папок»: файлы без folderId. Серверного фильтра под неё
    /// нет — фильтруем на клиенте поверх общего списка.
    @Published var showingNoFolder = false

    /// Открытый «чат-как-папка» (dp): показываются только файлы этой комнаты,
    /// серверным фильтром room_id. Имя — для строки «назад».
    @Published var selectedChatRoomID: String? {
        didSet {
            guard oldValue != selectedChatRoomID else { return }
            Task { await reload() }
        }
    }

    /// Чаты, в которых есть файлы: roomID → счётчик. Собирается по ПОЛНОМУ
    /// списку (ensureAllLoaded при входе в режим папок) — иначе счётчики врут.
    var chatGroups: [(roomID: String, name: String?, count: Int)] {
        var counts: [String: Int] = [:]
        for file in files {
            guard let roomID = file.roomID else { continue }
            counts[roomID, default: 0] += 1
        }
        return counts
            .map { (roomID: $0.key, name: roomNames[$0.key], count: $0.value) }
            .sorted { ($0.name ?? $0.roomID) < ($1.name ?? $1.roomID) }
    }

    /// Имена комнат для режима папок — резолвим пачкой по загруженным файлам.
    func ensureChatNames() {
        guard let roomNameResolver else { return }
        let ids = Set(files.compactMap(\.roomID))
        for roomID in ids where roomNames[roomID] == nil && !roomNamesInFlight.contains(roomID) {
            roomNamesInFlight.insert(roomID)
            Task { [weak self] in
                let name = await roomNameResolver(roomID)
                guard let self else { return }
                if let name { roomNames[roomID] = name }
                roomNamesInFlight.remove(roomID)
            }
        }
    }

    /// Вход в режим папок: докачиваем весь список, чтобы чаты и счётчики были
    /// полными, и резолвим имена.
    func prepareFoldersMode() {
        Task { [weak self] in
            await self?.ensureAllLoaded()
            self?.ensureChatNames()
        }
    }

    /// «Доступно мне» — файлы, расшаренные пользователю. Отдельный чип и
    /// отдельный список: в /api/files их нет по построению (контракт Molly).
    @Published var showingShared = false {
        didSet {
            guard oldValue != showingShared else { return }
            if showingShared { Task { await loadShared() } }
        }
    }

    @Published private(set) var sharedFiles: [DiskSharedFile] = []
    /// Диск-нативные документы (веб-редактор, «Сохранить на Диск» из Айлока):
    /// сервер не отдаёт их в /api/files, грузим отдельно и подмешиваем в «Все».
    @Published private(set) var diskDocs: [DiskFile] = []
    @Published private(set) var isLoadingShared = false

    /// shared-with-me annotates content hits but does NOT filter its returned rows.
    var displayedSharedFiles: [DiskSharedFile] {
        let query = normalizedQuery
        return sharedFiles.filter { file in
            let category = DiskService.fileCategory(filename: file.name, mimetype: file.mimetype)
            guard selectedCategory == nil || category == selectedCategory,
                  selectedFolder == nil || file.folderId.map(String.init) == selectedFolder?.id,
                  !showingNoFolder || file.folderId == nil else { return false }
            return query.isEmpty || file.contentHit ||
                ([file.name, file.owner, file.ownerDisplay ?? "", file.viaFolderName ?? "", file.fromPath ?? ""] + file.tags)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var displayedEntries: [DiskListEntry] {
        if showingShared { return displayedSharedFiles.map { .shared($0) } }
        var entries: [DiskListEntry] = displayedFiles.map { .own($0) }
        if selectedChatRoomID == nil {
            let docs = diskDocs.filter { doc in
                if let category = selectedCategory, doc.category != category { return false }
                if let folder = selectedFolder, doc.folderID != folder.id { return false }
                if showingNoFolder, doc.folderID != nil { return false }
                return true
            }
            entries += docs.map { .own($0) }
            if selectedFolder == nil, !showingNoFolder, selectedCategory == nil { entries += displayedSharedFiles.map { .shared($0) } }
        }
        // Prefer shelf metadata (personal folder, real owner) while retaining the most
        // restrictive ACL from duplicate sources. Timestamp order must never grant rights.
        var merged: [String: DiskListEntry] = [:]
        for entry in entries {
            let key = Self.identity(entry)
            if let old = merged[key] {
                switch (old, entry) {
                case let (.own(previous), .own(current)):
                    var file = current
                    file.canDownload = previous.canDownload && current.canDownload
                    file.readOnly = previous.readOnly || current.readOnly
                    file.owner = current.owner ?? previous.owner
                    merged[key] = .own(file)
                case let (.own(previous), .shared(shared)), let (.shared(shared), .own(previous)):
                    var file = previous
                    file.canDownload = file.canDownload && shared.canDownload && !shared.needsKeys
                    file.readOnly = file.readOnly || !["write", "full"].contains(shared.permission)
                    file.owner = file.owner ?? shared.owner
                    merged[key] = .own(file)
                case (.shared, .shared): break
                }
            } else {
                merged[key] = entry
            }
        }
        return merged.values.sorted { $0.ts == $1.ts ? $0.id < $1.id : $0.ts > $1.ts }
    }

    private static func identity(_ entry: DiskListEntry) -> String {
        switch entry {
        case let .own(file): file.blobID.map { "blob:" + $0 } ?? "event:" + file.id
        case let .shared(file): file.blobID.map { "blob:" + $0 } ?? "event:" + file.id
        }
    }

    func loadShared() async {
        let generation = requestGeneration
        let query = normalizedQuery
        isLoadingShared = true
        defer { if requestGeneration == generation { isLoadingShared = false } }
        do {
            let result = try await service.fetchSharedWithMe(query: query)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            sharedFiles = result
        } catch { if requestGeneration == generation, !Task.isCancelled { errorText = Self.describe(error) } }
    }

    /// Открыть расшаренный файл. `needsKeys` — честный отказ до сети: право
    /// есть, но содержимое зашифровано ключами комнаты, которых у нас нет.
    func selectShared(_ file: DiskSharedFile) {
        guard file.canDownload else {
            errorText = NSLocalizedString("stalk_disk_download_forbidden", tableName: "Localizable", value: "Владелец запретил скачивание. Откройте документ в веб-просмотре Диска.", comment: "Download forbidden")
            return
        }
        guard !file.needsKeys else {
            errorText = NSLocalizedString("stalk_disk_shared_no_keys", tableName: "Localizable",
                                          value: "Файл зашифрован, а ключей от его комнаты у вас нет — попросите владельца прислать файл в чат",
                                          comment: "Shared file cannot be decrypted")
            return
        }
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self else { return }
            if file.mxcURL.isEmpty, let blobID = file.blobID {
                do {
                    let url = try await service.downloadBlobFile(id: blobID, filename: file.name)
                    temporaryFiles.urls.append(url)
                    previewItem = MediaPreviewItem(file: .unmanaged(url: url), title: file.name)
                } catch {
                    DiagLog.write("Disk", "shared-блоб \(blobID) не скачался: \(error)")
                    errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                                  value: "Не удалось загрузить файл", comment: "Disk download failed")
                }
                return
            }
            guard let mediaProvider, let url = URL(string: file.mxcURL),
                  let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return }
            switch await mediaProvider.loadFileFromSource(source, filename: file.name) {
            case .success(let handle):
                previewItem = MediaPreviewItem(file: handle, title: file.name)
            case .failure(let error):
                DiagLog.write("Disk", "shared \(file.name) не скачался: \(error)")
                errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                              value: "Не удалось загрузить файл", comment: "Disk download failed")
            }
        }
    }

    private static let foldersKey = "ru.implica.stalk.diskShowsFolders"

    /// Search is sent to every server source, with stale requests cancelled/ignored.
    @Published var searchQuery = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            queryTask?.cancel()
            requestGeneration += 1
            files = []; sharedFiles = []; diskDocs = []
            nextBefore = nil; nextBeforeId = nil
            hasMoreFiles = false; allLoaded = false; isLoadingMore = false
            isLoading = true
            queryTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); await self?.reload() }
                catch { }
            }
        }
    }

    private var queryTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Профили получателей шаринга: userID → имя + аватар. Наполняется лениво,
    /// по мере появления строк с sharedWith на экране.
    @Published private(set) var sharedProfiles: [String: UserProfileProxy] = [:]
    private var profilesInFlight: Set<String> = []

    /// Миниатюры изображений для карточек: id файла → картинка.
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    private var thumbnailsInFlight: Set<String> = []
    private var allLoaded = false

    /// Файл, скачанный для просмотра. Показывается системным просмотрщиком —
    /// тем же, что и вложения в чате.
    @Published var previewItem: MediaPreviewItem?
    /// Файл, скачанный для системного «Поделиться» (dp: файл должен уметь
    /// уходить в другие приложения, а не жить только внутри).
    @Published var shareItem: DiskShareItem?
    /// Имя файла, который сейчас качается: показываем прогресс на его строке.
    @Published private(set) var downloadingFileID: String?

    /// Режим отображения. Выбор запоминаем: переключать его при каждом заходе —
    /// раздражение, а не настройка.
    @Published var layout: DiskLayout {
        didSet {
            guard oldValue != layout else { return }
            UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        }
    }

    private static let layoutKey = "ru.implica.stalk.diskLayout"

    private let service: DiskService
    lazy var photoService = DiskPhotoService(disk: service)
    @Published private(set) var callActive = false
    private var photoCallSubscription: AnyCancellable?
    let mediaProvider: MediaProviderProtocol?
    let resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?
    private let profileResolver: ((String) async -> UserProfileProxy?)?
    private let roomNameResolver: ((String) async -> String?)?

    /// Имена комнат по roomID — «в какой группе запощен файл». Лениво, с кэшем.
    @Published private(set) var roomNames: [String: String] = [:]
    private var roomNamesInFlight: Set<String> = []
    private var nextBefore: String?
    private var nextBeforeId: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMoreFiles = false

    private let temporaryFiles = StalkTemporaryFiles()
    private let actionsSubject: PassthroughSubject<DiskScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: DiskService,
         mediaProvider: MediaProviderProtocol?,
         profileResolver: ((String) async -> UserProfileProxy?)? = nil,
         roomNameResolver: ((String) async -> String?)? = nil,
         ongoingCallRoomID: CurrentValuePublisher<String?, Never>? = nil,
         resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)? = nil) {
        self.service = service
        self.mediaProvider = mediaProvider
        self.resolveMatrixSource = resolveMatrixSource
        self.profileResolver = profileResolver
        self.roomNameResolver = roomNameResolver
        let saved = UserDefaults.standard.string(forKey: Self.layoutKey)
        layout = saved.flatMap(DiskLayout.init(rawValue:)) ?? .list
        showsFolders = UserDefaults.standard.bool(forKey: Self.foldersKey)
        photoCallSubscription = ongoingCallRoomID?.receive(on: DispatchQueue.main).sink { [weak self] in self?.callActive = $0 != nil }
    }

    func openPhotoInChat(_ file: DiskFile) {
        guard let room = file.roomID, let event = file.eventID else { return }
        actionsSubject.send(.openRoom(roomID: room, eventID: event))
    }

    // MARK: - Поиск

    /// Файлы после фильтра поиска — то, что реально видит экран.
    var displayedFiles: [DiskFile] {
        showingNoFolder ? files.filter { $0.folderID == nil } : files
    }

    /// Докачать весь список для честного поиска. Кап страниц — защита от
    /// бесконечного курсора; текущие объёмы (сотни файлов) покрывает с запасом.
    private func ensureAllLoaded() async {
        guard !allLoaded, !showingShared, !isLoading, !isLoadingMore else { return }
        var pages = 0
        while hasMoreFiles, pages < 25, !Task.isCancelled {
            await loadMore()
            if errorText != nil { return }
            pages += 1
        }
        if hasMoreFiles, !Task.isCancelled { errorText = DiskServiceError.incompleteListing.localizedDescription }
    }

    // MARK: - Аватарки шаринга и миниатюры

    /// Подтянуть профили получателей шаринга строки. Лениво и с дедупликацией:
    /// список большой, а профили нужны только видимым строкам.
    /// Сюда же — отправитель (dp: «кто запостил») и имя комнаты («в какой группе»).
    func ensureSharedProfiles(_ file: DiskFile) {
        var ids: [String] = file.sender.isEmpty ? [] : [file.sender]
        if let shared = file.sharedWith { ids.append(contentsOf: shared.prefix(4)) }
        ensureProfiles(ids)

        if let roomID = file.roomID, roomNames[roomID] == nil, !roomNamesInFlight.contains(roomID),
           let roomNameResolver {
            roomNamesInFlight.insert(roomID)
            Task { [weak self] in
                let name = await roomNameResolver(roomID)
                guard let self else { return }
                if let name { roomNames[roomID] = name }
                roomNamesInFlight.remove(roomID)
            }
        }
    }

    /// Профиль владельца расшаренного файла — для аватарки «от кого».
    func ensureOwnerProfile(_ file: DiskSharedFile) {
        guard !file.owner.isEmpty else { return }
        ensureProfiles([file.owner])
    }

    private func ensureProfiles(_ ids: [String]) {
        guard let profileResolver else { return }
        for id in ids where !id.isEmpty && sharedProfiles[id] == nil && !profilesInFlight.contains(id) {
            profilesInFlight.insert(id)
            Task { [weak self] in
                let profile = await profileResolver(id)
                guard let self else { return }
                if let profile { sharedProfiles[id] = profile }
                profilesInFlight.remove(id)
            }
        }
    }

    /// «Переслать» расшаренный файл в чат: скачиваем содержимое и отдаём во
    /// флоу с пикером комнат (маршрут Share Extension). needsKeys — пункта нет.
    func forwardShared(_ file: DiskSharedFile) {
        guard !file.needsKeys, file.canDownload else { return }
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self, let url = await sharedLocalURL(for: file) else { return }
            actionsSubject.send(.forwardFile(url: url, name: file.name))
        }
    }

    /// «Переслать» свой файл БЕЗ Matrix-события (Диск-документ, копия шаринга):
    /// пересылать нечего событием — уходит содержимым.
    func forwardAsFile(_ file: DiskFile) {
        guard !file.isEncrypted, file.canDownload else { return }
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self, let url = await localURL(for: file) else { return }
            actionsSubject.send(.forwardFile(url: url, name: file.filename))
        }
    }

    /// Содержимое расшаренного файла во временном файле (общий путь для
    /// share sheet и пересылки).
    private func sharedLocalURL(for file: DiskSharedFile) async -> URL? {
        guard file.canDownload, !file.needsKeys else { return nil }
        if file.mxcURL.isEmpty, let blobID = file.blobID {
            guard let data = try? await service.fetchBlob(id: blobID) else { return nil }
            return try? Self.writeShareTemp(data: data, filename: file.name.isEmpty ? blobID : file.name)
        }
        guard let mediaProvider, let url = URL(string: file.mxcURL),
              let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return nil }
        guard case let .success(handle) = await mediaProvider.loadFileFromSource(source, filename: file.name),
              let handleURL = handle.url,
              let data = try? Data(contentsOf: handleURL) else { return nil }
        return try? Self.writeShareTemp(data: data, filename: file.name)
    }

    /// «Поделиться» для расшаренного файла: скачиваем и отдаём в share sheet.
    /// needsKeys — не вызывается вовсе (пункта в меню нет).
    func shareShared(_ file: DiskSharedFile) {
        guard !file.needsKeys, file.canDownload else { return }
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self else { return }
            if file.mxcURL.isEmpty, let blobID = file.blobID {
                if let data = try? await service.fetchBlob(id: blobID),
                   let url = try? Self.writeShareTemp(data: data, filename: file.name.isEmpty ? blobID : file.name) {
                    shareItem = DiskShareItem(url: url)
                }
                return
            }
            guard let mediaProvider, let url = URL(string: file.mxcURL),
                  let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return }
            if case let .success(handle) = await mediaProvider.loadFileFromSource(source, filename: file.name),
               let handleURL = handle.url,
               let data = try? Data(contentsOf: handleURL),
               let tempURL = try? Self.writeShareTemp(data: data, filename: file.name) {
                shareItem = DiskShareItem(url: tempURL)
            }
        }
    }

    /// Возможна ли миниатюра: незашифрованная картинка с mxc-адресом.
    /// Зашифрованные сервер отдать не может (ключи только у комнаты) —
    /// их карточка остаётся с глифом и замком.
    func canThumbnail(_ file: DiskFile) -> Bool {
        file.canDownload && file.category == .images && !file.isEncrypted && !file.mxcURL.isEmpty
    }

    func ensureThumbnail(_ file: DiskFile) {
        guard canThumbnail(file), let mediaProvider,
              thumbnails[file.id] == nil, !thumbnailsInFlight.contains(file.id),
              let url = URL(string: file.mxcURL) else { return }
        thumbnailsInFlight.insert(file.id)
        Task { [weak self] in
            guard let self else { return }
            defer { thumbnailsInFlight.remove(file.id) }
            guard let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return }
            if case let .success(image) = await mediaProvider.loadImageFromSource(source, size: CGSize(width: 300, height: 300)) {
                thumbnails[file.id] = image
            }
        }
    }

    // MARK: - Действия над файлом

    /// Перейти к сообщению, которым файл прислали.
    ///
    /// Доступно только для файлов из чата: у Диск-документов и копий для шаринга
    /// Matrix-события нет вовсе, и переходить некуда.
    func findInChat(_ file: DiskFile) {
        guard let roomID = file.roomID, let eventID = file.eventID else { return }
        actionsSubject.send(.openRoom(roomID: roomID, eventID: eventID))
    }

    func forward(_ file: DiskFile) {
        guard file.canDownload, let roomID = file.roomID, let eventID = file.eventID else { return }
        actionsSubject.send(.forward(roomID: roomID, eventID: eventID))
    }

    /// Есть ли у файла событие в чате — от этого зависят «найти в чате» и
    /// «переслать». Мёртвых пунктов в меню быть не должно.
    func hasChatEvent(_ file: DiskFile) -> Bool {
        file.roomID != nil && file.eventID != nil
    }

    func onAppear() {
        guard files.isEmpty, !isLoading else { return }
        Task { await reload() }
    }

    func searchNow() async {
        queryTask?.cancel(); queryTask = nil
        await reload()
    }

    func reload() async {
        requestGeneration += 1
        let generation = requestGeneration
        let query = normalizedQuery
        let category = selectedCategory; let folder = selectedFolder?.id; let room = selectedChatRoomID
        isLoading = true; isLoadingMore = false; errorText = nil; nextBefore = nil; nextBeforeId = nil; allLoaded = false; hasMoreFiles = false
        defer { if requestGeneration == generation { isLoading = false } }
        async let statsTask = try? service.fetchStats()
        async let foldersTask = try? service.fetchFolders()
        async let sharedTask = try? service.fetchSharedWithMe(query: query)
        async let docsTask = try? service.fetchDiskDocs(query: query)
        do {
            let page = try await service.fetchFiles(category: category, folder: folder, roomID: room, query: query)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            files = page.files
            updateCursor(before: page.nextBefore, id: page.nextBeforeId)
            if let warning = page.warning { errorText = warning; allLoaded = false }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            errorText = Self.describe(error); files = []
        }
        let results = await (statsTask, foldersTask, sharedTask, docsTask)
        guard requestGeneration == generation, !Task.isCancelled else { return }
        stats = results.0; folders = results.1 ?? []
        sharedFiles = results.2 ?? []; diskDocs = results.3 ?? []
        if results.2 == nil || results.3 == nil {
            errorText = errorText ?? NSLocalizedString("stalk_disk_search_partial", value: "Не удалось загрузить часть результатов. Повторите поиск.", comment: "Partial Disk search failure")
        }
    }

    /// Подгрузка следующей страницы по курсору. Без него список обрывается на
    /// первой выдаче, а сервер отдаёт `nextBefore` именно для продолжения.
    func loadMoreIfNeeded(currentItem: DiskFile) async {
        await loadMoreIfNeeded(currentEntry: .own(currentItem))
    }

    func loadMoreIfNeeded(currentEntry: DiskListEntry) async {
        guard currentEntry.id == displayedEntries.last?.id, errorText == nil else { return }
        await loadMore()
    }

    private func updateCursor(before: String?, id: String?) {
        nextBefore = before; nextBeforeId = id
        hasMoreFiles = before != nil
        allLoaded = !hasMoreFiles
    }

    /// Advance through pages hidden by a query/category/folder until visible progress or
    /// a real endpoint end. A footer can call this even when there is no visible last row.
    func loadMore() async {
        guard nextBefore != nil, !showingShared, !isLoading, !isLoadingMore else { return }
        let generation = requestGeneration
        isLoadingMore = true
        defer { if requestGeneration == generation { isLoadingMore = false } }
        let originalVisible = Set(displayedEntries.map(\.id))
        var cursors = Set<String>()
        var pages = 0
        do {
            while let before = nextBefore {
                try Task.checkCancellation()
                let id = nextBeforeId
                guard pages < 25, cursors.insert(before + "\n" + (id ?? "")).inserted else { throw DiskServiceError.incompleteListing }
                let page = try await service.fetchFiles(category: selectedCategory, before: before, beforeId: id, folder: selectedFolder?.id, roomID: selectedChatRoomID, query: normalizedQuery)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                var known = Set(files.map(\.id))
                files.append(contentsOf: page.files.filter { known.insert($0.id).inserted })
                if page.nextBefore == before, page.nextBeforeId == id { throw DiskServiceError.incompleteListing }
                updateCursor(before: page.nextBefore, id: page.nextBeforeId)
                if let warning = page.warning { errorText = warning; allLoaded = false; return }
                pages += 1
                if !Set(displayedEntries.map(\.id)).subtracting(originalVisible).isEmpty { return }
            }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            errorText = Self.describe(error)
        }
    }

    /// Открыть файл.
    ///
    /// Зашифрованные вложения расшифровываются ключами КОМНАТЫ, и достать их можно
    /// только через таймлайн — сервер ключей не имеет, а по одному mxc-адресу
    /// содержимое не развернуть. Поэтому для таких файлов уводим в чат, где событие
    /// уже расшифровано, вместо того чтобы показывать заведомо битую заглушку.
    func selectFile(_ file: DiskFile) {
        guard file.canDownload else {
            errorText = NSLocalizedString("stalk_disk_download_forbidden", value: "Владелец запретил скачивание. Откройте документ в веб-просмотре Диска.", comment: "Download forbidden")
            return
        }
        // Уводим в чат только когда там ЕСТЬ что открывать: у Диск-документов и
        // копий для шаринга Matrix-события нет вовсе, и переход вёл бы в никуда.
        if file.isEncrypted, let roomID = file.roomID, let eventID = file.eventID {
            DiagLog.write("Disk", "файл \(file.filename) зашифрован → открываю в чате")
            actionsSubject.send(.openRoom(roomID: roomID, eventID: eventID))
            return
        }

        // Правило Molly: есть mxcUrl — тянем из Matrix; нет — из блоб-хранилища
        // по blobId. Раньше вторая половина показывала «нельзя открыть», хотя
        // содержимое доступно.
        if file.mxcURL.isEmpty, let blobID = file.blobID {
            downloadBlob(file, blobID: blobID)
            return
        }

        guard let mediaProvider, !file.mxcURL.isEmpty, let url = URL(string: file.mxcURL) else {
            errorText = NSLocalizedString("stalk_disk_error_open", tableName: "Localizable",
                                          value: "Этот файл пока нельзя открыть", comment: "Disk cannot open file")
            return
        }

        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return }
            let result = await mediaProvider.loadFileFromSource(source, filename: file.filename)
            switch result {
            case .success(let handle):
                self?.previewItem = MediaPreviewItem(file: handle, title: file.filename)
            case .failure(let error):
                DiagLog.write("Disk", "не скачался \(file.filename): \(error)")
                self?.errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                                    value: "Не удалось загрузить файл", comment: "Disk download failed")
            }
        }
    }

    /// Системное «Поделиться»: скачать содержимое и отдать в share sheet.
    /// Для зашифрованных не вызывается вовсе — у них и пункта меню нет
    /// (решение dp); guard — страховка на случай нового вызова.
    func share(_ file: DiskFile) {
        guard !file.isEncrypted, file.canDownload else { return }
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self, let url = await localURL(for: file) else { return }
            shareItem = DiskShareItem(url: url)
        }
    }

    /// Содержимое файла на диске, в НАШЕМ временном каталоге. Копия обязательна:
    /// хэндл медиапровайдера удаляет свой файл при освобождении, и share sheet
    /// остался бы с мёртвой ссылкой.
    private func localURL(for file: DiskFile) async -> URL? {
        guard file.canDownload else { return nil }
        if file.mxcURL.isEmpty, let blobID = file.blobID {
            do {
                let data = try await service.fetchBlob(id: blobID)
                return try Self.writeShareTemp(data: data, filename: file.filename.isEmpty ? blobID : file.filename)
            } catch {
                DiagLog.write("Disk", "блоб для шаринга не скачался: \(error)")
                errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                              value: "Не удалось загрузить файл", comment: "Disk download failed")
                return nil
            }
        }
        guard let mediaProvider, !file.mxcURL.isEmpty, let url = URL(string: file.mxcURL),
              let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return nil }
        switch await mediaProvider.loadFileFromSource(source, filename: file.filename) {
        case .success(let handle):
            guard let handleURL = handle.url,
                  let data = try? Data(contentsOf: handleURL) else { return nil }
            return try? Self.writeShareTemp(data: data, filename: file.filename)
        case .failure(let error):
            DiagLog.write("Disk", "файл для шаринга не скачался: \(error)")
            errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                          value: "Не удалось загрузить файл", comment: "Disk download failed")
            return nil
        }
    }

    private static func writeShareTemp(data: Data, filename: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "stalk-disk-share", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Скачать содержимое из блоб-хранилища и показать тем же просмотрщиком, что
    /// и вложения чата. Пишем во временный файл: просмотрщику нужен путь на диске,
    /// а не байты в памяти.
    private func downloadBlob(_ file: DiskFile, blobID: String) {
        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let self else { return }
            do {
                let data = try await service.fetchBlob(id: blobID)
                let directory = URL.temporaryDirectory.appending(path: "stalk-disk", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Имя как у файла: просмотрщик и «Поделиться» показывают именно его.
                let url = directory.appending(path: file.filename.isEmpty ? blobID : file.filename)
                try data.write(to: url, options: .atomic)
                previewItem = MediaPreviewItem(file: .unmanaged(url: url), title: file.filename)
            } catch {
                DiagLog.write("Disk", "блоб \(blobID) не скачался: \(error)")
                errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                              value: "Не удалось загрузить файл", comment: "Disk download failed")
            }
        }
    }

    func dismiss() {
        actionsSubject.send(.dismiss)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DiskServiceError.incompleteListing: error.localizedDescription
        case DiskServiceError.unauthorized:
            NSLocalizedString("stalk_disk_error_auth", tableName: "Localizable",
                              value: "Нет доступа к диску. Попробуйте войти заново.", comment: "Disk auth error")
        case DiskServiceError.http(let code):
            String(format: NSLocalizedString("stalk_disk_error_http", tableName: "Localizable",
                                             value: "Сервер ответил ошибкой (%d)", comment: "Disk HTTP error"), code)
        default:
            NSLocalizedString("stalk_disk_error_generic", tableName: "Localizable",
                              value: "Не удалось загрузить список файлов", comment: "Disk generic error")
        }
    }
}
