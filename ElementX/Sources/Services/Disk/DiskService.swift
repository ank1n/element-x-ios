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
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
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
        nextBefore = try c.decodeIfPresent(String.self, forKey: .nextBefore)
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
    func fetchFiles(category: DiskFileCategory? = nil, before: String? = nil) async throws -> (files: [DiskFile], nextBefore: String?) {
        var components = URLComponents(string: "\(baseURL)/api/files")
        var query: [URLQueryItem] = []
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
                // Сетевой сбой раньше не попадал в выгрузку вовсе: писался только
                // ненулевой HTTP-статус. На устройстве это выглядело как «Диск пустой
                // и молчит» — без единой строки, по которой видно, что запрос вообще был.
                DiagLog.write("Disk", "запрос \(url.path) не дошёл: \(error.localizedDescription)")
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
