//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log
import UniformTypeIdentifiers

private let diskLog = OSLog(subsystem: "ru.implica.stalk", category: "Disk")

// MARK: - Модели

/// Категория, которой сервер размечает файл. Значения взяты из живого ответа
/// `/api/files` и из `/api/files/stats` — там же ключи all / documents / images / media.
enum DiskFileCategory: String, Codable, CaseIterable {
    case documents
    case images
    case media
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DiskFileCategory(rawValue: raw) ?? .other
    }

    var title: String {
        switch self {
        case .documents: NSLocalizedString("stalk_disk_category_documents", tableName: "Localizable", value: "Документы", comment: "Disk category")
        case .images: NSLocalizedString("stalk_disk_category_images", tableName: "Localizable", value: "Изображения", comment: "Disk category")
        case .media: NSLocalizedString("stalk_disk_category_media", tableName: "Localizable", value: "Медиа", comment: "Disk category")
        case .other: NSLocalizedString("stalk_disk_category_other", tableName: "Localizable", value: "Прочее", comment: "Disk category")
        }
    }

    /// Иконка берётся по категории, а не по расширению: у сервера категория уже
    /// посчитана, и она переживает незнакомые нам типы файлов.
    var systemImage: String {
        switch self {
        case .documents: "doc.text.fill"
        case .images: "photo.fill"
        case .media: "play.rectangle.fill"
        case .other: "doc.fill"
        }
    }
}

/// Файл в «Диске».
///
/// Схема снята живым запросом к `GET /api/files` на проде, а не выведена из
/// документации — её для files-api не существует вовсе.
struct DiskFile: Identifiable, Codable, Equatable {
    /// Событие Matrix, из которого файл попал в индекс. Вместе с `roomID` это
    /// единственный способ получить содержимое ЗАШИФРОВАННОГО вложения: ключи
    /// комнаты есть только у нативного клиента, сервер расшифровать не может.
    ///
    /// Необязательные: Диск-нативные документы и не-E2EE копии для шаринга живут
    /// БЕЗ Matrix-события вовсе. Пока эти поля были обязательными, одна такая
    /// запись роняла разбор всей страницы, и список не открывался целиком.
    let eventID: String?
    let roomID: String?
    /// Идентификатор блоба. У записей без `mxcURL` содержимое достаётся только
    /// по нему: `GET /api/files/blob/:id` (правило Molly — есть mxcUrl, тяни из
    /// Matrix; нет — из блоб-хранилища).
    let blobID: String?
    let sender: String
    let filename: String
    let mimetype: String
    let size: Int64
    let msgtype: String
    let category: DiskFileCategory
    let mxcURL: String
    /// Время события, миллисекунды.
    let ts: Int64
    let isEncrypted: Bool
    let folderID: String?
    let starred: Bool
    let sharedWith: [String]?
    var owner: String?
    var readOnly = false
    var canDownload = true

    /// Ключ строки. У файлов из чата это событие, у Диск-документов — блоб.
    /// Оба сразу отсутствовать не могут: тогда запись нечем открыть, и разбор
    /// её отбрасывает (см. `DiskFilesResponse`).
    var id: String {
        eventID ?? blobID ?? mxcURL
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case roomID = "roomId"
        case blobID = "blobId"
        case sender, filename, mimetype, size, msgtype, category
        case mxcURL = "mxcUrl"
        case ts
        case isEncrypted
        case folderID = "folderId"
        case starred
        case sharedWith
        case owner, canDownload
        case readOnly = "readonly"
    }

    /// Ручной конструктор для записей НЕ из /api/files (Диск-документы из
    /// /disk-docs): форма того ответа другая, декодер ниже им не подходит.
    init(eventID: String?, roomID: String?, blobID: String?, sender: String, filename: String,
         mimetype: String, size: Int64, msgtype: String, category: DiskFileCategory, mxcURL: String,
         ts: Int64, isEncrypted: Bool, folderID: String?, starred: Bool, sharedWith: [String]?,
         owner: String? = nil, readOnly: Bool = false, canDownload: Bool = true) {
        self.eventID = eventID
        self.roomID = roomID
        self.blobID = blobID
        self.sender = sender
        self.filename = filename
        self.mimetype = mimetype
        self.size = size
        self.msgtype = msgtype
        self.category = category
        self.mxcURL = mxcURL
        self.ts = ts
        self.isEncrypted = isEncrypted
        self.folderID = folderID
        self.starred = starred
        self.sharedWith = sharedWith
        self.owner = owner
        self.readOnly = readOnly
        self.canDownload = canDownload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID)
        blobID = try c.decodeIfPresent(String.self, forKey: .blobID)
        sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? ""
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        mimetype = try c.decodeIfPresent(String.self, forKey: .mimetype) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        msgtype = try c.decodeIfPresent(String.self, forKey: .msgtype) ?? ""
        category = try c.decodeIfPresent(DiskFileCategory.self, forKey: .category) ?? .other
        mxcURL = try c.decodeIfPresent(String.self, forKey: .mxcURL) ?? ""
        ts = try c.decodeIfPresent(Int64.self, forKey: .ts) ?? 0
        // Поля появились в схеме позже остальных — читаем терпимо, сервер ещё меняется.
        isEncrypted = try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        // folderId сервер шлёт ЧИСЛОМ (или null) — контракт Molly, 02.08. Прежнее
        // чтение строкой молча теряло привязку файлов к папкам у всех записей.
        if let numericFolder = try? c.decodeIfPresent(Int64.self, forKey: .folderID) {
            folderID = String(numericFolder)
        } else {
            folderID = try? c.decodeIfPresent(String.self, forKey: .folderID)
        }
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        struct Recipient: Decodable { let user: String }
        sharedWith = (try? c.decodeIfPresent([String].self, forKey: .sharedWith))
            ?? (try? c.decodeIfPresent([Recipient].self, forKey: .sharedWith))?.map(\.user)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        canDownload = try c.decodeIfPresent(Bool.self, forKey: .canDownload) ?? true
    }
}

/// Ответ списка. `nextBefore` — курсор постраничной выдачи.
///
/// Записи разбираются ПОШТУЧНО, и непонятая пропускается вместе со своей строкой,
/// а не роняет страницу. Строгий разбор массива стоил нам пустого экрана «Не
/// удалось загрузить список файлов» на аккаунте с 536 файлами: счётчики приходили
/// (они считаются на сервере), а список падал целиком из-за записей, у которых
/// нет Matrix-события. Схема files-api ещё меняется, и одно новое поле не должно
/// стирать весь Диск.
private struct DiskFilesResponse: Decodable {
    let files: [DiskFile]
    let nextBefore: String?
    let nextBeforeId: String?
    /// Сколько записей не разобралось. Ноль в норме; ненулевое пишем в лог.
    let skipped: Int

    private enum CodingKeys: String, CodingKey {
        case files, nextBefore, nextBeforeId
    }

    /// Обёртка, превращающая ошибку разбора элемента в `nil` вместо броска.
    private struct Lenient: Decodable {
        let file: DiskFile?

        init(from decoder: Decoder) throws {
            file = try? DiskFile(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextBeforeId = try c.decodeIfPresent(String.self, forKey: .nextBeforeId)
        let raw = try c.decode([Lenient].self, forKey: .files)
        let parsed = raw.compactMap(\.file)
        // Запись без единого идентификатора открыть нечем — показывать её нельзя.
        files = parsed.filter { !$0.id.isEmpty }
        skipped = raw.count - files.count
        // Курсор приходит ЧИСЛОМ — это метка времени события (1783922871243).
        // Объявленный строкой, он ронял разбор всего ответа с typeMismatch, и экран
        // уходил в «Не удалось загрузить список файлов». Заметно это было только на
        // полной странице: когда файлов мало, курсора нет вовсе и всё работало.
        // Читаем оба типа: строку сервер тоже вправе прислать, и гадать больше не хочу.
        if let number = try? c.decodeIfPresent(Int64.self, forKey: .nextBefore) {
            nextBefore = String(number)
        } else {
            nextBefore = try? c.decodeIfPresent(String.self, forKey: .nextBefore)
        }
    }
}

/// Файл, расшаренный МНЕ (контракт Molly, 02.08). Не DiskFile: другой состав
/// полей — владелец, право, источник доступа и признак «ключей нет».
struct DiskSharedFile: Identifiable, Equatable {
    let owner: String
    let ownerDisplay: String?
    let eventID: String?
    let blobID: String?
    let mxcURL: String
    let name: String
    let mimetype: String
    let size: Int64
    /// "read" | "write".
    let permission: String
    /// Диск-нативный документ: открывается ОН ЖЕ (соредактирование), не копия.
    let isDiskDoc: Bool
    /// Имя папки, от которой доступ пришёл каскадом (nil = прямая шара).
    let viaFolderName: String?
    /// Право есть, но файл зашифрован и ключей комнаты у получателя нет —
    /// открыть НЕЛЬЗЯ, UI обязан показать это заранее (правило Molly).
    let needsKeys: Bool
    let canDownload: Bool
    let ts: Int64
    /// Кому ещё доступен файл. Поле запрошено у Molly (dp: веб показывает всех
    /// в колонке «Доступ»); пока сервер его не шлёт — nil, зажжётся само.
    let recipients: [Recipient]?

    var addedTs: Int64?
    var photo: DiskPhoto.EXIF?
    var tags: [String] = []
    var folderId: Int?
    var contentHit = false
    var fromPath: String?

    struct Recipient: Decodable, Equatable {
        let user: String
        let display: String?
        let permission: String?
    }

    var id: String {
        eventID ?? blobID ?? (mxcURL.isEmpty ? "\(owner)-\(name)-\(ts)" : mxcURL)
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    }
}

extension DiskSharedFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case owner, ownerDisplay, eventId, blobId, mxc, name, mimetype, size,
             permission, isDiskDoc, viaFolderName, needsKeys, canDownload, ts, recipients, sharedWith, addedTs, photo, tags, folderId, contentHit, fromPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        ownerDisplay = try c.decodeIfPresent(String.self, forKey: .ownerDisplay)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventId)
        blobID = try c.decodeIfPresent(String.self, forKey: .blobId)
        mxcURL = try c.decodeIfPresent(String.self, forKey: .mxc) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mimetype = try c.decodeIfPresent(String.self, forKey: .mimetype) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        permission = try c.decodeIfPresent(String.self, forKey: .permission) ?? "read"
        isDiskDoc = try c.decodeIfPresent(Bool.self, forKey: .isDiskDoc) ?? false
        viaFolderName = try c.decodeIfPresent(String.self, forKey: .viaFolderName)
        needsKeys = try c.decodeIfPresent(Bool.self, forKey: .needsKeys) ?? false
        canDownload = try c.decodeIfPresent(Bool.self, forKey: .canDownload) ?? true
        addedTs = try c.decodeIfPresent(Double.self, forKey: .addedTs).map(Int64.init)
        photo = try c.decodeIfPresent(DiskPhoto.EXIF.self, forKey: .photo)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        folderId = try c.decodeIfPresent(Int.self, forKey: .folderId)
        contentHit = try c.decodeIfPresent(Bool.self, forKey: .contentHit) ?? false
        fromPath = try c.decodeIfPresent(String.self, forKey: .fromPath)
        // Сервер шлёт ts ДРОБНЫМ (1785590849703.323 — миллисекунды с хвостом);
        // целочисленное чтение роняло разбор всего ответа.
        if let doubleTS = try? c.decodeIfPresent(Double.self, forKey: .ts) {
            ts = Int64(doubleTS)
        } else {
            ts = (try? c.decodeIfPresent(Int64.self, forKey: .ts)) ?? 0
        }
        // Имя поля с сервером ещё не зафиксировано — читаем оба кандидата.
        recipients = (try? c.decodeIfPresent([Recipient].self, forKey: .recipients))
            ?? (try? c.decodeIfPresent([Recipient].self, forKey: .sharedWith))
    }
}

/// Папка Диска. `id` сервер шлёт числом — читаем терпимо, как folderId у файла.
struct DiskFolder: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    var parentID: String?
    var kind: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, count, parentId, kind
    }
}

extension DiskFolder: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let numeric = try? c.decode(Int64.self, forKey: .id) {
            id = String(numeric)
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        if let numeric = try? c.decodeIfPresent(Int64.self, forKey: .parentId) { parentID = String(numeric) }
        else { parentID = try c.decodeIfPresent(String.self, forKey: .parentId) }
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }
}

/// Счётчики по категориям: `{"all":28,"documents":12,"images":16,"media":0}`.
struct DiskStats: Decodable, Equatable {
    let all: Int
    let documents: Int
    let images: Int
    let media: Int

    func count(for category: DiskFileCategory) -> Int {
        switch category {
        case .documents: documents
        case .images: images
        case .media: media
        case .other: max(0, all - documents - images - media)
        }
    }
}

enum DiskServiceError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case http(Int)
    case incompleteListing
    var errorDescription: String? {
        switch self {
        case .invalidURL: NSLocalizedString("stalk_disk_service_invalid_url", value: "Не удалось распознать ссылку или файл.", comment: "Invalid Disk resource URL")
        case .unauthorized: NSLocalizedString("stalk_disk_service_unauthorized", value: "Войдите снова, чтобы открыть Диск.", comment: "Disk session expired")
        case .incompleteListing: NSLocalizedString("stalk_disk_service_incomplete", value: "Список загружен не полностью. Повторите загрузку оставшихся файлов.", comment: "Incomplete Disk listing")
        case .http(let status):
            switch status {
            case 403: NSLocalizedString("stalk_disk_service_forbidden", value: "Нет доступа к этому действию или оно отключено администратором.", comment: "Disk access denied")
            case 404: NSLocalizedString("stalk_disk_service_not_found", value: "Объект удалён или у вас больше нет доступа.", comment: "Disk object unavailable")
            case 409: NSLocalizedString("stalk_disk_service_conflict", value: "Данные изменились. Обновите список и повторите действие.", comment: "Disk version conflict")
            case 413: NSLocalizedString("stalk_disk_service_too_large", value: "Слишком большой объём данных. Уточните фильтр или выберите меньше файлов.", comment: "Disk request too large")
            case 429: NSLocalizedString("stalk_disk_service_rate_limited", value: "Слишком много запросов. Повторите немного позже.", comment: "Disk request throttled")
            default: String(format: NSLocalizedString("stalk_disk_service_http", value: "Диск временно недоступен (%d). Повторите попытку.", comment: "Disk failure HTTP status"), status)
            }
        }
    }
}

// MARK: - Сервис

/// Клиент files-api.
///
/// База берётся от домена сессии, а путь `/api/files` одинаков во всём семействе
/// sTalk — тот же принцип, что для встреч (см. STMOB-246: адрес из apps-api бывает
/// захардкожен на .ru, и токен другого домена получал 401).
///
/// Авторизация — Matrix-токен пользователя: проверено живым запросом, без заголовка
/// сервис отвечает 401 «Authorization required».
final class DiskService {
    static func fileCategory(filename: String, mimetype: String) -> DiskFileCategory {
        let mime = mimetype.lowercased()
        let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)
        if mime.hasPrefix("image/") || ((mime.isEmpty || mime == "application/octet-stream") && type?.conforms(to: .image) == true) { return .images }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") || ((mime.isEmpty || mime == "application/octet-stream") && (type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true)) { return .media }
        return .documents
    }

    private let baseURL: String
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: (() async -> Void)?

    private let session: URLSession

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    init(baseURL: String,
         accessTokenProvider: @escaping () throws -> String,
         forceTokenRefresh: (() async -> Void)? = nil,
         session: URLSession? = nil) {
        self.baseURL = baseURL
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh
        self.session = session ?? Self.makeSession()
    }

    /// Список файлов. `before` — курсор из `nextBefore` предыдущей страницы.
    func fetchFiles(category: DiskFileCategory? = nil, before: String? = nil, beforeId: String? = nil, folder: String? = nil, roomID: String? = nil, query search: String? = nil) async throws -> (files: [DiskFile], nextBefore: String?, nextBeforeId: String?, warning: String?) {
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if before == nil {
                return try await initialSearchFiles(query: search, category: category, folder: folder, roomID: roomID)
            }
            do { return try await fetchIndexedFiles(query: search, cursor: before, category: category, folder: folder, roomID: roomID) }
            catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                try Task.checkCancellation()
                if before?.hasPrefix("catalogue:") == true { throw error }
                // Search-index outages must not remove the existing filename search.
                let fallback = try await fetchCatalogueMatches(query: search, cursor: "catalogue:", category: category, folder: folder, roomID: roomID)
                return (fallback.files, fallback.nextBefore, nil, DiskServiceError.incompleteListing.localizedDescription)
            }
        }
        var components = URLComponents(string: "\(baseURL)/api/files")
        var query: [URLQueryItem] = []
        // These filters run AFTER the backend's bounded DB window. Traverse the
        // unfiltered keyset and retain its cursor even when no visible rows match.
        // In particular, the backend folder branch does not apply before/before_id.
        if let roomID {
            // Файлы конкретного чата (dp: чаты как папки; параметр из контракта).
            query.append(URLQueryItem(name: "room_id", value: roomID))
        }
        if let before, !before.isEmpty {
            // `nextBefore` — не непрозрачный курсор, а метка времени события
            // (например 1783922871243). Параметр `before` проверен: вторая страница
            // возвращает другие файлы, `until`/`since`/`from` игнорируются.
            query.append(URLQueryItem(name: "before", value: before))
        }
        if let before, !before.isEmpty, let beforeId, !beforeId.isEmpty {
            query.append(URLQueryItem(name: "before_id", value: beforeId))
        }
        components?.queryItems = query.isEmpty ? nil : query

        let data = try await get(components?.url)
        // Диагностика курсора для Molly (STMOB-275): точная строка запроса и сырой
        // nextBefore из ответа — по этой паре разводятся версии зацикливания.
        let queryString = components?.url?.query ?? "<без параметров>"
        if let s = String(data: data, encoding: .utf8), let r = s.range(of: "\"nextBefore\"") {
            let end = s.index(r.lowerBound, offsetBy: 48, limitedBy: s.endIndex) ?? s.endIndex
            DiagLog.write("Disk", "запрос ?\(queryString) → сырой \(s[r.lowerBound..<end])")
        } else {
            DiagLog.write("Disk", "запрос ?\(queryString) → nextBefore в ответе отсутствует")
        }
        let decoded: DiskFilesResponse
        do {
            decoded = try JSONDecoder().decode(DiskFilesResponse.self, from: data)
        } catch {
            // Раньше сюда попадала любая нераспознанная запись и экран пустел молча:
            // в выгрузке не оставалось ни строки, и причину было не установить.
            DiagLog.write("Disk", "список не разобрался (\(data.count) байт): \(error)")
            throw error
        }
        let tail = decoded.nextBefore == nil ? "" : ", есть ещё"
        let lost = decoded.skipped == 0 ? "" : ", пропущено непонятых: \(decoded.skipped)"
        DiagLog.write("Disk", "список: \(decoded.files.count) файлов\(tail)\(lost)")
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visible = decoded.files.filter { file in
            (category == nil || file.category == category) &&
                (folder == nil || file.folderID == folder) &&
                (needle.isEmpty || file.filename.localizedCaseInsensitiveContains(needle))
        }
        return (visible, decoded.nextBefore, decoded.nextBeforeId, decoded.skipped == 0 ? nil : DiskServiceError.incompleteListing.localizedDescription)
    }

    private typealias FilePage = (files: [DiskFile], nextBefore: String?, nextBeforeId: String?, warning: String?)

    /// Recent catalogue names must not wait behind many index pages or depend on index
    /// timestamp/metadata support. Both initial sources are read concurrently, with no
    /// shared cache; later index pagination can revisit the catalogue and the VM dedups.
    private func initialSearchFiles(query: String, category: DiskFileCategory?, folder: String?, roomID: String?) async throws -> FilePage {
        func capture(_ operation: () async throws -> FilePage) async -> Result<FilePage, Error> {
            do { return try await .success(operation()) } catch { return .failure(error) }
        }
        async let indexed = capture { try await fetchIndexedFiles(query: query, cursor: nil, category: category, folder: folder, roomID: roomID) }
        async let catalogue = capture { try await fetchCatalogueMatches(query: query, cursor: "catalogue:", category: category, folder: folder, roomID: roomID) }
        let (indexResult, catalogueResult) = await (indexed, catalogue)
        try Task.checkCancellation()
        for result in [indexResult, catalogueResult] {
            if case let .failure(error) = result,
               error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
        }
        let indexPage = try? indexResult.get()
        let cataloguePage = try? catalogueResult.get()
        guard indexPage != nil || cataloguePage != nil else {
            if case let .failure(error) = indexResult { throw error }
            throw DiskServiceError.incompleteListing
        }

        var merged: [String: DiskFile] = [:]
        for var file in (indexPage?.files ?? []) + (cataloguePage?.files ?? []) {
            if let old = merged[file.id] {
                file.canDownload = file.canDownload && old.canDownload
                file.readOnly = file.readOnly || old.readOnly
                file.owner = file.owner ?? old.owner
            }
            merged[file.id] = file
        }
        let warning = indexPage?.warning ?? cataloguePage?.warning ??
            (indexPage == nil || cataloguePage == nil ? DiskServiceError.incompleteListing.localizedDescription : nil)
        // Do not jump to the catalogue tail here: older index pages still need hydration.
        // When indexing is unavailable, retain the actual catalogue continuation instead.
        let next = indexPage != nil ? indexPage?.nextBefore : cataloguePage?.nextBefore
        let id = indexPage != nil ? indexPage?.nextBeforeId : cataloguePage?.nextBeforeId
        return (merged.values.sorted { $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts }, next, id, warning)
    }

    private struct CatalogueCursor: Codable {
        let before: String?
        let id: String?
    }

    /// Also traverse the unfiltered catalogue after index results: this preserves substring
    /// and E2EE-name matches which a lexical index cannot necessarily represent.
    private func fetchCatalogueMatches(query: String, cursor: String, category: DiskFileCategory?, folder: String?, roomID: String?) async throws -> (files: [DiskFile], nextBefore: String?, nextBeforeId: String?, warning: String?) {
        let payload = String(cursor.dropFirst("catalogue:".count))
        let position: CatalogueCursor
        if payload.isEmpty { position = .init(before: nil, id: nil) }
        else {
            guard let data = Data(base64Encoded: payload) else { throw DiskServiceError.incompleteListing }
            position = try JSONDecoder().decode(CatalogueCursor.self, from: data)
        }
        let page = try await fetchFiles(before: position.before, beforeId: position.id, roomID: roomID)
        var next: String?
        if let before = page.nextBefore {
            let data = try JSONEncoder().encode(CatalogueCursor(before: before, id: page.nextBeforeId))
            next = "catalogue:" + data.base64EncodedString()
        } else if let tail = page.files.last, let event = tail.eventID, tail.ts > 0,
                  position.before != String(tail.ts) || position.id != event {
            // Go may omit its continuation when a bounded DB window contains mostly
            // non-file URL events. Still advance past the actual unfiltered file tail.
            let data = try JSONEncoder().encode(CatalogueCursor(before: String(tail.ts), id: event))
            next = "catalogue:" + data.base64EncodedString()
        }
        return (page.files.filter {
            $0.filename.localizedCaseInsensitiveContains(query) &&
                (category == nil || $0.category == category) && (folder == nil || $0.folderID == folder)
        }, next, nil, page.warning ?? (next == nil ? DiskServiceError.incompleteListing.localizedDescription : nil))
    }

    /// Search the full ACL-filtered attachment index, then hydrate actual catalogue cards.
    /// A search hit alone never grants download access or invents folder membership.
    private func fetchIndexedFiles(query: String, cursor: String?, category: DiskFileCategory?, folder: String?, roomID: String?) async throws -> (files: [DiskFile], nextBefore: String?, nextBeforeId: String?, warning: String?) {
        if let cursor, cursor.hasPrefix("catalogue:") {
            return try await fetchCatalogueMatches(query: query, cursor: cursor, category: category, folder: folder, roomID: roomID)
        }
        struct Hit: Decodable {
            struct Target: Decodable { let kind: String; let room_id: String?; let event_id: String?; let file_id: String? }
            let entity_type: String
            let target: Target?
            let created_at: String?
            let snippet: String?
            let contentHit: Bool?

            var provesContentMatch: Bool {
                if contentHit == true { return true }
                guard let snippet, let start = snippet.firstIndex(of: "\u{0002}"),
                      let end = snippet[start...].firstIndex(of: "\u{0003}") else { return false }
                return snippet.index(after: start) < end
            }
        }
        struct Response: Decodable { let total: Int; let results: [Hit] }
        struct Hydrated { let order: Int; let file: DiskFile?; let incomplete: Bool }
        let offset: Int
        if let cursor {
            guard cursor.hasPrefix("search:"), let value = Int(cursor.dropFirst(7)), (0...10000).contains(value) else { throw DiskServiceError.incompleteListing }
            offset = value
        } else { offset = 0 }
        var url = URLComponents(string: "\(baseURL)/api/search")
        url?.queryItems = [.init(name: "q", value: query), .init(name: "mode", value: "basic"),
                           .init(name: "type", value: "attachment"), .init(name: "sort", value: "newest"),
                           .init(name: "limit", value: "20"), .init(name: "offset", value: String(offset))]
        if let roomID { url?.queryItems?.append(.init(name: "room", value: roomID)) }
        let data = try await get(url?.url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.total >= 0, !response.results.isEmpty || offset >= response.total else { throw DiskServiceError.incompleteListing }

        func hydrate(_ order: Int) async throws -> Hydrated {
            try Task.checkCancellation()
            let hit = response.results[order]
            // `type=attachment` selects a display facet, not a navigation entity.
            // Native file targets (including disk_doc entities in this facet) are
            // already loaded through shelf/shared with authoritative ACLs. They need
            // neither room hydration nor synthetic rights derived from index metadata.
            if ["disk_doc", "attachment"].contains(hit.entity_type),
               let target = hit.target, target.kind == "file", let id = target.file_id,
               !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               id.rangeOfCharacter(from: .controlCharacters) == nil {
                return Hydrated(order: order, file: nil, incomplete: false)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let noFraction = ISO8601DateFormatter()
            guard hit.entity_type == "attachment", let target = hit.target, target.kind == "room",
                  let room = target.room_id, let event = target.event_id, let created = hit.created_at,
                  room.hasPrefix("!"), event.hasPrefix("$"),
                  let date = iso.date(from: created) ?? noFraction.date(from: created),
                  let timestamp = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) else {
                return Hydrated(order: order, file: nil, incomplete: true)
            }
            if let roomID, room != roomID { return Hydrated(order: order, file: nil, incomplete: false) }
            do {
                // The strict (ts,eventId) cursor includes the target via a greater suffix.
                // Verify BOTH identifiers on the authoritative response; never take the
                // nearest row or use index timestamps as a substitute for file metadata.
                let page = try await fetchFiles(before: String(timestamp), beforeId: event + "~", roomID: room)
                try Task.checkCancellation()
                guard let file = page.files.first(where: { $0.eventID == event && $0.roomID == room }) else {
                    return Hydrated(order: order, file: nil, incomplete: true)
                }
                // Stopwords/one-character queries can yield an unfiltered index response.
                // Only actual filename matches or explicit lexical/content evidence qualify.
                guard file.filename.localizedCaseInsensitiveContains(query) || hit.provesContentMatch,
                      category == nil || file.category == category,
                      folder == nil || file.folderID == folder else {
                    return Hydrated(order: order, file: nil, incomplete: false)
                }
                return Hydrated(order: order, file: file, incomplete: false)
            } catch {
                try Task.checkCancellation()
                return Hydrated(order: order, file: nil, incomplete: true)
            }
        }
        // At most four HTTP hydrations; completion order never changes result order.
        let hydrated = try await withThrowingTaskGroup(of: Hydrated.self) { group in
            var next = 0
            for _ in 0..<min(4, response.results.count) {
                let order = next; next += 1
                group.addTask { try await hydrate(order) }
            }
            var rows: [Hydrated] = []
            while let row = try await group.next() {
                try Task.checkCancellation()
                rows.append(row)
                if next < response.results.count {
                    let order = next; next += 1
                    group.addTask { try await hydrate(order) }
                }
            }
            return rows
        }
        try Task.checkCancellation()
        let nextOffset = offset + response.results.count
        let capped = nextOffset > 10000 && nextOffset < response.total
        let incomplete = capped || hydrated.contains { $0.incomplete }
        let next: String? = capped ? nil : nextOffset < response.total ? "search:\(nextOffset)" : "catalogue:"
        return (hydrated.sorted { $0.order < $1.order }.compactMap(\.file), next, nil,
                incomplete ? DiskServiceError.incompleteListing.localizedDescription : nil)
    }

    /// «Доступно мне»: `GET /api/files/shared-with-me` (контракт Molly, 02.08).
    /// UNION прямых шар, каскада от расшаренных папок и Диск-документов.
    func fetchSharedWithMe(query: String? = nil) async throws -> [DiskSharedFile] {
        var url = URLComponents(string: "\(baseURL)/api/files/shared-with-me")
        if let query, !query.isEmpty { url?.queryItems = [.init(name: "q", value: query)] }
        let data = try await get(url?.url)
        // Поштучный разбор, как у основного списка: одна непонятая запись не
        // должна прятать все расшаренные файлы.
        struct LenientShared: Decodable {
            let file: DiskSharedFile?
            init(from decoder: Decoder) throws {
                file = try? DiskSharedFile(from: decoder)
            }
        }
        struct Response: Decodable { let files: [LenientShared] }
        do {
            let raw = try JSONDecoder().decode(Response.self, from: data).files
            let files = raw.compactMap(\.file)
            DiagLog.write("Disk", "доступно мне: \(files.count)\(raw.count == files.count ? "" : ", пропущено: \(raw.count - files.count)")")
            return files
        } catch {
            DiagLog.write("Disk", "shared-with-me не разобрался (\(data.count) байт): \(error)")
            throw error
        }
    }

    /// Список папок: `GET /api/files/folders` (контракт Molly, 02.08).
    func fetchFolders() async throws -> [DiskFolder] {
        let data = try await get(URL(string: "\(baseURL)/api/files/folders"))
        struct Response: Decodable { let folders: [DiskFolder] }
        do {
            let folders = try JSONDecoder().decode(Response.self, from: data).folders
            DiagLog.write("Disk", "папки: \(folders.count)")
            return folders
        } catch {
            DiagLog.write("Disk", "папки не разобрались (\(data.count) байт): \(error)")
            throw error
        }
    }

    func fetchStats() async throws -> DiskStats {
        let data = try await get(URL(string: "\(baseURL)/api/files/stats"))
        return try JSONDecoder().decode(DiskStats.self, from: data)
    }

    /// Содержимое записи, у которой нет `mxcURL`: Диск-нативные документы и
    /// не-E2EE копии для шаринга лежат не в Matrix-медиа, а в блоб-хранилище.
    /// Отдаёт сырые байты (контракт Molly, #ops 30.07).
    func fetchBlob(id: String) async throws -> Data {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await get(URL(string: "\(baseURL)/api/files/blob/\(encoded)"))
    }

    /// Диск-нативные документы владельца (созданы вебом или «Сохранить на Диск»
    /// из Айлока). В общий /api/files они НЕ входят (живая проба 03.08: свежий
    /// документ в списке не появился) — веб подмешивает их отдельным запросом,
    /// повторяем его контракт.
    func fetchDiskDocs(query search: String? = nil) async throws -> [DiskFile] {
        struct Response: Decodable { let docs: [LenientDoc]?; var hasMore: Bool? }
        struct Doc: Decodable {
            let blobId: String
            let name: String?
            let mimetype: String?
            let size: Int64?
            let ts: Double?
            let folderID: String?
            let starred: Bool?
            let owner: String?
            let readOnly: Bool
            let canDownload: Bool
            let sharedWith: [Recipient]?
            struct Recipient: Decodable { let user: String? }

            enum CodingKeys: String, CodingKey { case blobId, name, mimetype, size, ts, starred, sharedWith, folderId, owner, canDownload, readonly }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // id этого бэкенда уже приходил числом (прецедент folderId) —
                // читаем терпимо, иначе смена типа молча выбросит запись.
                if let numeric = try? c.decodeIfPresent(Int64.self, forKey: .blobId) {
                    blobId = String(numeric)
                } else {
                    blobId = try c.decode(String.self, forKey: .blobId)
                }
                if let numeric = try? c.decodeIfPresent(Int64.self, forKey: .folderId) { folderID = String(numeric) }
                else { folderID = try? c.decodeIfPresent(String.self, forKey: .folderId) }
                name = try? c.decodeIfPresent(String.self, forKey: .name)
                mimetype = try? c.decodeIfPresent(String.self, forKey: .mimetype)
                size = try? c.decodeIfPresent(Int64.self, forKey: .size)
                ts = try? c.decodeIfPresent(Double.self, forKey: .ts)
                starred = try? c.decodeIfPresent(Bool.self, forKey: .starred)
                sharedWith = try? c.decodeIfPresent([Recipient].self, forKey: .sharedWith)
                owner = try c.decodeIfPresent(String.self, forKey: .owner)
                readOnly = try c.decodeIfPresent(Bool.self, forKey: .readonly) ?? false
                canDownload = try c.decodeIfPresent(Bool.self, forKey: .canDownload) ?? !readOnly
            }
        }
        // Поштучный разбор, как у shared-with-me: одна непонятая запись не
        // должна прятать все документы (схема этого API ещё меняется).
        struct LenientDoc: Decodable {
            let doc: Doc?
            init(from decoder: Decoder) throws {
                doc = try? Doc(from: decoder)
            }
        }

        var wrapped: [LenientDoc] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            var url = URLComponents(string: "\(baseURL)/api/files/disk-docs")
            url?.queryItems = [.init(name: "scope", value: "shelf"), .init(name: "limit", value: "500"), .init(name: "offset", value: String(offset)), .init(name: "order", value: "id")]
            if let search, !search.isEmpty { url?.queryItems?.append(.init(name: "q", value: search)) }
            let data = try await get(url?.url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let page = response.docs ?? []
            wrapped += page
            let more = response.hasMore ?? (page.count == 500)
            guard more else { break }
            guard offset < 50000 else { throw DiskServiceError.http(413) }
            offset += 500
        }
        let docs = wrapped.compactMap(\.doc).filter { !$0.blobId.isEmpty }
        if docs.count < wrapped.count {
            DiagLog.write("Disk", "disk-docs: пропущено записей \(wrapped.count - docs.count) из \(wrapped.count)")
        }
        return docs.map { doc in
            let mime = doc.mimetype ?? ""
            let category = Self.fileCategory(filename: doc.name ?? "", mimetype: mime)
            return DiskFile(eventID: nil, roomID: nil, blobID: doc.blobId,
                            sender: doc.owner ?? "", filename: doc.name ?? "", mimetype: mime,
                            size: doc.size ?? 0, msgtype: "m.file", category: category,
                            mxcURL: "",
                            // Int64(Double) трапается на мусорном значении вне
                            // диапазона — exactly+rounded безопасно даёт 0.
                            ts: Int64(exactly: (doc.ts ?? 0).rounded()) ?? 0,
                            isEncrypted: false,
                            folderID: doc.folderID, starred: doc.starred ?? false,
                            sharedWith: doc.sharedWith?.compactMap(\.user).filter { !$0.isEmpty },
                            owner: doc.owner, readOnly: doc.readOnly, canDownload: doc.canDownload)
        }
    }

    /// Загрузить содержимое к себе на Диск Диск-документом (diskDoc=1): запись
    /// появляется в общем списке файлов и открывается вебом как документ.
    /// Контракт — как у веба (FileIndexApi.uploadDiskDoc): сырое тело POST'ом,
    /// имя и тип в query, лимит сервера 40 МБ.
    func uploadDiskDoc(filename: String, mimetype: String, data: Data, folderID: String? = nil) async throws {
        var components = URLComponents(string: "\(baseURL)/api/files/blob")
        components?.queryItems = [URLQueryItem(name: "diskDoc", value: "1"),
                                  URLQueryItem(name: "filename", value: filename),
                                  URLQueryItem(name: "mimetype", value: mimetype)]
        if let folderID {
            guard let id = Int64(folderID), id > 0 else { throw DiskServiceError.invalidURL }
            components?.queryItems?.append(.init(name: "folderId", value: String(id)))
        }
        // URLComponents оставляет «+» сырым (по RFC он в query разрешён), а
        // form-urlencoded-парсер Node на сервере декодирует его пробелом:
        // «C++ разбор.md» доехал бы как «C   разбор.md». Веб шлёт %2B — дожимаем
        // так же. Пробелы URLComponents кодирует в %20, так что замена трогает
        // только литеральные плюсы (в т.ч. в mimetype вида image/svg+xml).
        if let encoded = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components?.url else { throw DiskServiceError.invalidURL }

        for attempt in 1...2 {
            let token = try accessTokenProvider()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = data

            let response: URLResponse
            do {
                (_, response) = try await session.data(for: request)
            } catch {
                // Как в get(): без этой строки сбой сети выглядел бы в выгрузке
                // как «не сохранилось и молчит» — ни следа, что POST вообще был.
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !isCancelled {
                    DiagLog.write("Disk", "загрузка Диск-документа не дошла: \(error.localizedDescription)")
                }
                throw error
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status == 200 { return }

            if status == 401, attempt == 1 {
                os_log(.default, log: diskLog, "401 на загрузке — обновляю токен и повторяю")
                await forceTokenRefresh?()
                continue
            }

            DiagLog.write("Disk", "загрузка Диск-документа → HTTP \(status)")
            throw status == 401 ? DiskServiceError.unauthorized : DiskServiceError.http(status)
        }

        throw DiskServiceError.unauthorized
    }

    // MARK: - Транспорт

    func downloadBlobFile(id: String, filename: String) async throws -> URL {
        guard UUID(uuidString: id) != nil, let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/files/blob/" + id) else { throw DiskServiceError.invalidURL }
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
            let (temporary, response) = try await session.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { try? FileManager.default.removeItem(at: temporary); await forceTokenRefresh?(); continue }
            guard status == 200, response.url?.host == url.host else { try? FileManager.default.removeItem(at: temporary); throw DiskServiceError.http(status) }
            let directory = URL.temporaryDirectory.appending(path: "disk-original-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            var suggested = filename
            if let encoded = header.components(separatedBy: "filename*=UTF-8''").last, encoded != header {
                suggested = encoded.components(separatedBy: ";")[0].removingPercentEncoding ?? filename
            } else if let named = header.components(separatedBy: "filename=").last, named != header {
                suggested = named.components(separatedBy: ";")[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
            var name = suggested.isEmpty ? "document-\(id)" : URL(fileURLWithPath: suggested).lastPathComponent
            name = String(name.prefix(100))
            if URL(fileURLWithPath: name).pathExtension.isEmpty { name += "." + ext }
            let result = directory.appending(path: name)
            try FileManager.default.moveItem(at: temporary, to: result)
            return result
        }
        throw DiskServiceError.unauthorized
    }

    func photoRequest(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard URLComponents(string: path)?.path.components(separatedBy: "/").contains("..") != true, let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/files/" + path) else { throw DiskServiceError.invalidURL }
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.httpMethod = method
            try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { await forceTokenRefresh?(); continue }
            guard (200...299).contains(status) else { if status == 401 { throw DiskServiceError.unauthorized }; throw DiskServiceError.http(status) }
            return data
        }
        throw DiskServiceError.unauthorized
    }

    /// Один повтор на 401: токен мог протухнуть, SDK обновляет его в фоне.
    /// Тот же приём, что в сервисе встреч.
    private func get(_ url: URL?) async throws -> Data {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DiskServiceError.invalidURL }
        // Go's query parser treats a literal plus as a space; preserve C++ and event IDs.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw DiskServiceError.invalidURL }

        for attempt in 1...2 {
            try Task.checkCancellation()
            let token = try accessTokenProvider()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Отмену не логируем: её вызывает обычное переключение фильтра, и
                // в выгрузке она выглядит как поток ошибок там, где ничего не сломано.
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !isCancelled {
                    // Сетевой сбой раньше не попадал в выгрузку вовсе: писался только
                    // ненулевой HTTP-статус. На устройстве это выглядело как «Диск пустой
                    // и молчит» — без единой строки, по которой видно, что запрос вообще был.
                    DiagLog.write("Disk", "запрос \(url.path) не дошёл: \(error.localizedDescription)")
                }
                throw error
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            try Task.checkCancellation()

            if status == 200 { return data }

            if status == 401, attempt == 1 {
                os_log(.default, log: diskLog, "401 — обновляю токен и повторяю")
                await forceTokenRefresh?()
                continue
            }

            DiagLog.write("Disk", "запрос \(url.path) → HTTP \(status)")
            throw status == 401 ? DiskServiceError.unauthorized : DiskServiceError.http(status)
        }

        throw DiskServiceError.unauthorized
    }
}
