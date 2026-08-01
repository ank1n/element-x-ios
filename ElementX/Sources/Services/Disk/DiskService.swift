//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

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
        sharedWith = try c.decodeIfPresent([String].self, forKey: .sharedWith)
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
    /// Сколько записей не разобралось. Ноль в норме; ненулевое пишем в лог.
    let skipped: Int

    private enum CodingKeys: String, CodingKey {
        case files, nextBefore
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
    let ts: Int64
    /// Кому ещё доступен файл. Поле запрошено у Molly (dp: веб показывает всех
    /// в колонке «Доступ»); пока сервер его не шлёт — nil, зажжётся само.
    let recipients: [Recipient]?

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
             permission, isDiskDoc, viaFolderName, needsKeys, ts, recipients, sharedWith
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

    private enum CodingKeys: String, CodingKey {
        case id, name, count
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

enum DiskServiceError: Error {
    case invalidURL
    case unauthorized
    case http(Int)
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
    private let baseURL: String
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: (() async -> Void)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    init(baseURL: String,
         accessTokenProvider: @escaping () throws -> String,
         forceTokenRefresh: (() async -> Void)? = nil) {
        self.baseURL = baseURL
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh
    }

    /// Список файлов. `before` — курсор из `nextBefore` предыдущей страницы.
    func fetchFiles(category: DiskFileCategory? = nil, before: String? = nil, folder: String? = nil, roomID: String? = nil) async throws -> (files: [DiskFile], nextBefore: String?) {
        var components = URLComponents(string: "\(baseURL)/api/files")
        var query: [URLQueryItem] = []
        if let folder {
            // Содержимое конкретной папки (контракт Molly, 02.08).
            query.append(URLQueryItem(name: "folder", value: folder))
        }
        if let roomID {
            // Файлы конкретного чата (dp: чаты как папки; параметр из контракта).
            query.append(URLQueryItem(name: "room_id", value: roomID))
        }
        if let category, category != .other {
            // Имя параметра — `filter`, НЕ `category`. Проверено на проде: с
            // `category=images` сервер молча отдаёт всё (14 записей, обе категории),
            // с `filter=images` — только изображения (8). Молчаливое игнорирование
            // означало бы, что любая вкладка показывает одно и то же.
            query.append(URLQueryItem(name: "filter", value: category.rawValue))
        }
        if let before, !before.isEmpty {
            // `nextBefore` — не непрозрачный курсор, а метка времени события
            // (например 1783922871243). Параметр `before` проверен: вторая страница
            // возвращает другие файлы, `until`/`since`/`from` игнорируются.
            query.append(URLQueryItem(name: "before", value: before))
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
        return (decoded.files, decoded.nextBefore)
    }

    /// «Доступно мне»: `GET /api/files/shared-with-me` (контракт Molly, 02.08).
    /// UNION прямых шар, каскада от расшаренных папок и Диск-документов.
    func fetchSharedWithMe() async throws -> [DiskSharedFile] {
        let data = try await get(URL(string: "\(baseURL)/api/files/shared-with-me"))
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

    // MARK: - Транспорт

    /// Один повтор на 401: токен мог протухнуть, SDK обновляет его в фоне.
    /// Тот же приём, что в сервисе встреч.
    private func get(_ url: URL?) async throws -> Data {
        guard let url else { throw DiskServiceError.invalidURL }

        for attempt in 1...2 {
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
