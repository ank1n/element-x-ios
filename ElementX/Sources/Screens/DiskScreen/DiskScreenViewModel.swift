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
    @Published private(set) var isLoadingShared = false

    /// «Доступно мне» после фильтра поиска.
    var displayedSharedFiles: [DiskSharedFile] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sharedFiles }
        return sharedFiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Объединённый список для экрана (dp: расшаренное должно быть видно и в
    /// общем списке). Свои — как раньше; расшаренные подмешиваются по времени,
    /// но только в «Все» без папки: в категориях и папках их место не определено
    /// (серверной категории у них нет), а в чипе «Доступно мне» они и так одни.
    var displayedEntries: [DiskListEntry] {
        if showingShared {
            return displayedSharedFiles.map { .shared($0) }
        }
        var entries: [DiskListEntry] = displayedFiles.map { .own($0) }
        if selectedCategory == nil, selectedFolder == nil, !showingNoFolder, selectedChatRoomID == nil, !sharedFiles.isEmpty {
            let query = searchQuery.trimmingCharacters(in: .whitespaces)
            let shared = query.isEmpty ? sharedFiles : sharedFiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
            entries.append(contentsOf: shared.map { .shared($0) })
            entries.sort { $0.ts > $1.ts }
        }
        return entries
    }

    func loadShared() async {
        isLoadingShared = true
        defer { isLoadingShared = false }
        do {
            sharedFiles = try await service.fetchSharedWithMe()
        } catch {
            DiagLog.write("Disk", "shared-with-me не загрузился: \(error)")
            errorText = Self.describe(error)
        }
    }

    /// Открыть расшаренный файл. `needsKeys` — честный отказ до сети: право
    /// есть, но содержимое зашифровано ключами комнаты, которых у нас нет.
    func selectShared(_ file: DiskSharedFile) {
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
                    let data = try await service.fetchBlob(id: blobID)
                    let directory = URL.temporaryDirectory.appending(path: "stalk-disk", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appending(path: file.name.isEmpty ? blobID : file.name)
                    try data.write(to: url, options: .atomic)
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

    /// Поиск по имени. При первом непустом запросе докачиваем ВСЕ страницы
    /// пагинации: иначе поиск молча ищет только по загруженному куску и врёт.
    @Published var searchQuery = "" {
        didSet {
            guard oldValue != searchQuery, !searchQuery.isEmpty else { return }
            Task { await ensureAllLoaded() }
        }
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
    let mediaProvider: MediaProviderProtocol?
    private let profileResolver: ((String) async -> UserProfileProxy?)?
    private let roomNameResolver: ((String) async -> String?)?

    /// Имена комнат по roomID — «в какой группе запощен файл». Лениво, с кэшем.
    @Published private(set) var roomNames: [String: String] = [:]
    private var roomNamesInFlight: Set<String> = []
    private var nextBefore: String?
    private var isLoadingMore = false

    private let actionsSubject: PassthroughSubject<DiskScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: DiskService,
         mediaProvider: MediaProviderProtocol?,
         profileResolver: ((String) async -> UserProfileProxy?)? = nil,
         roomNameResolver: ((String) async -> String?)? = nil) {
        self.service = service
        self.mediaProvider = mediaProvider
        self.profileResolver = profileResolver
        self.roomNameResolver = roomNameResolver
        let saved = UserDefaults.standard.string(forKey: Self.layoutKey)
        layout = saved.flatMap(DiskLayout.init(rawValue:)) ?? .list
        showsFolders = UserDefaults.standard.bool(forKey: Self.foldersKey)
    }

    // MARK: - Поиск

    /// Файлы после фильтра поиска — то, что реально видит экран.
    var displayedFiles: [DiskFile] {
        var result = files
        // «Вне папок» — клиентский срез: серверного фильтра под него нет.
        if showingNoFolder {
            result = result.filter { $0.folderID == nil }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        return result.filter { $0.filename.localizedCaseInsensitiveContains(query) }
    }

    /// Докачать весь список для честного поиска. Кап страниц — защита от
    /// бесконечного курсора; текущие объёмы (сотни файлов) покрывает с запасом.
    private func ensureAllLoaded() async {
        guard !allLoaded, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var pages = 0
        while let before = nextBefore, pages < 25 {
            do {
                let page = try await service.fetchFiles(category: selectedCategory, before: before, folder: selectedFolder?.id, roomID: selectedChatRoomID)
                let known = Set(files.map(\.id))
                files.append(contentsOf: page.files.filter { !known.contains($0.id) })
                nextBefore = page.nextBefore
            } catch {
                DiagLog.write("Disk", "докачка для поиска оборвалась: \(error)")
                return
            }
            pages += 1
        }
        if nextBefore == nil { allLoaded = true }
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
        for id in ids where sharedProfiles[id] == nil && !profilesInFlight.contains(id) {
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
        guard !file.needsKeys else { return }
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
        guard !file.isEncrypted else { return }
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
        guard !file.needsKeys else { return }
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
        file.category == .images && !file.isEncrypted && !file.mxcURL.isEmpty
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
        guard let roomID = file.roomID, let eventID = file.eventID else { return }
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

    func reload() async {
        isLoading = true
        errorText = nil
        nextBefore = nil
        allLoaded = false

        // Счётчики, папки и список независимы: пустая статистика или упавшие
        // папки не должны прятать файлы.
        async let statsTask = try? service.fetchStats()
        async let foldersTask = try? service.fetchFolders()
        do {
            let page = try await service.fetchFiles(category: selectedCategory, folder: selectedFolder?.id, roomID: selectedChatRoomID)
            files = page.files
            nextBefore = page.nextBefore
        } catch is CancellationError {
            // Переключение фильтра отменяет предыдущий запрос. Это не сбой, и
            // показывать по нему баннер — значит давать ложную ошибку на каждом
            // втором тапе по категориям.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorText = Self.describe(error)
            files = []
        }
        stats = await statsTask
        folders = await (foldersTask) ?? []
        // Расшаренное грузим вместе со списком: dp ждёт его и в общем списке.
        sharedFiles = await (try? service.fetchSharedWithMe()) ?? sharedFiles
        isLoading = false
    }

    /// Подгрузка следующей страницы по курсору. Без него список обрывается на
    /// первой выдаче, а сервер отдаёт `nextBefore` именно для продолжения.
    func loadMoreIfNeeded(currentItem: DiskFile) async {
        guard let nextBefore, !isLoadingMore,
              currentItem.id == files.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await service.fetchFiles(category: selectedCategory, before: nextBefore, folder: selectedFolder?.id, roomID: selectedChatRoomID)
            // Дубликаты возможны, если между страницами что-то добавилось.
            let known = Set(files.map(\.id))
            let fresh = page.files.filter { !known.contains($0.id) }
            files.append(contentsOf: fresh)
            // Защита от зацикленного курсора (лог dp 214: «бесконечный лоадер,
            // список не пополняется»): страница без ЕДИНОГО нового файла или
            // с тем же курсором — это конец списка, что бы сервер ни обещал.
            // Иначе .task последней строки просит ту же страницу вечно.
            if fresh.isEmpty || page.nextBefore == nextBefore {
                DiagLog.write("Disk", "догрузка: страница без новых (курсор \(page.nextBefore ?? "nil")) — считаю список полным")
                self.nextBefore = nil
            } else {
                self.nextBefore = page.nextBefore
            }
        } catch {
            // Молча: обрыв догрузки не должен ронять уже показанный список.
            DiagLog.write("Disk", "догрузка не удалась: \(error)")
        }
    }

    /// Открыть файл.
    ///
    /// Зашифрованные вложения расшифровываются ключами КОМНАТЫ, и достать их можно
    /// только через таймлайн — сервер ключей не имеет, а по одному mxc-адресу
    /// содержимое не развернуть. Поэтому для таких файлов уводим в чат, где событие
    /// уже расшифровано, вместо того чтобы показывать заведомо битую заглушку.
    func selectFile(_ file: DiskFile) {
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
        guard !file.isEncrypted else { return }
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
