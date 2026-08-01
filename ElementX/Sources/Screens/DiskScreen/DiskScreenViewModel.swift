//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftUI

enum DiskScreenViewModelAction {
    /// Файл зашифрован — открыть его можно только в чате, где есть ключи комнаты.
    /// Это же действие и «найти в чате»: перейти к сообщению, которым файл прислали.
    case openRoom(roomID: String, eventID: String)
    /// Переслать в другой чат. Содержимого события здесь нет — только ссылка на
    /// него; достаёт его флоу, у которого есть доступ к комнатам.
    case forward(roomID: String, eventID: String)
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
    private var nextBefore: String?
    private var isLoadingMore = false

    private let actionsSubject: PassthroughSubject<DiskScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: DiskService,
         mediaProvider: MediaProviderProtocol?,
         profileResolver: ((String) async -> UserProfileProxy?)? = nil) {
        self.service = service
        self.mediaProvider = mediaProvider
        self.profileResolver = profileResolver
        let saved = UserDefaults.standard.string(forKey: Self.layoutKey)
        layout = saved.flatMap(DiskLayout.init(rawValue:)) ?? .list
    }

    // MARK: - Поиск

    /// Файлы после фильтра поиска — то, что реально видит экран.
    var displayedFiles: [DiskFile] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.filename.localizedCaseInsensitiveContains(query) }
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
                let page = try await service.fetchFiles(category: selectedCategory, before: before)
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
    func ensureSharedProfiles(_ file: DiskFile) {
        guard let ids = file.sharedWith, !ids.isEmpty, let profileResolver else { return }
        for id in ids.prefix(4) where sharedProfiles[id] == nil && !profilesInFlight.contains(id) {
            profilesInFlight.insert(id)
            Task { [weak self] in
                let profile = await profileResolver(id)
                guard let self else { return }
                if let profile { sharedProfiles[id] = profile }
                profilesInFlight.remove(id)
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

        // Счётчики и список независимы: пустая статистика не должна прятать файлы.
        async let statsTask = try? service.fetchStats()
        do {
            let page = try await service.fetchFiles(category: selectedCategory)
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
            let page = try await service.fetchFiles(category: selectedCategory, before: nextBefore)
            // Дубликаты возможны, если между страницами что-то добавилось.
            let known = Set(files.map(\.id))
            files.append(contentsOf: page.files.filter { !known.contains($0.id) })
            self.nextBefore = page.nextBefore
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
