//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.log

private let ailockLog = OSLog(subsystem: "ru.implica.stalk", category: "Ailock")

// MARK: - Домен

/// Сессия Айлока: результат POST /sessions. `wsTicket` одноразовый и живёт секунды,
/// поэтому сессию создаём непосредственно перед открытием сокета, а не заранее.
struct AilockSession {
    let conversationID: String
    let wsTicket: String
    let capabilities: AilockCapabilities
}

/// STMOB-274: движок отдаёт ровно два булевых ключа. Всё, чего нет — false.
struct AilockCapabilities: Equatable {
    var conversationsDelete = false
    var conversationsRename = false

    init() { }

    init(json: [String: Any]?) {
        conversationsDelete = json?["conversations_delete"] as? Bool == true
        conversationsRename = json?["conversations_rename"] as? Bool == true
    }
}

struct AilockConversation: Identifiable, Equatable {
    let id: String
    let title: String?
    let createdAt: Date?
    let lastMessageAt: Date?

    /// Метка, по которой движок пагинирует список (параметр `before`).
    var sortDate: Date? {
        lastMessageAt ?? createdAt
    }

    var displayTitle: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SL10n.ailockUntitledConversation
        }
        return title
    }
}

/// Файл: и вложение пользователя, и файл, присланный агентом.
struct AilockFile: Identifiable, Equatable {
    let id: String
    let filename: String
    let mimeType: String
    /// Для файлов агента — ссылка из события `agent.file` либо из истории.
    /// Для только что загруженных вложений пользователя ссылки нет.
    let url: String?

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}

/// Одно сообщение в ленте. Собирается либо из истории, либо из потока событий.
struct AilockMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        /// Системный баннер движка (`agent.response` с role == "system").
        case system(severity: String)
    }

    let id: String
    var role: Role
    var text: String
    var files: [AilockFile] = []
    var createdAt: Date
    /// true, пока сообщение дописывается потоком токенов.
    var isStreaming = false

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
    }
}

struct AilockConversationStatus {
    let running: Bool
    let pendingQuestion: AilockPendingQuestion?
}

struct AilockPendingQuestion: Equatable {
    let questionID: String
    let question: String
    let defaultAnswer: String?
}

/// Тело ошибки gateway: `{"error": "...", "detail": "..."}`.
struct AilockErrorBody: Decodable {
    let error: String
    let detail: String?
}

enum AilockError: Error, LocalizedError {
    /// Сервис не развёрнут на этом домене (404 от gateway / SPA).
    case unavailable
    case http(status: Int, code: String?, detail: String?)
    case missingTicket
    case badResponse
    case fileTooLarge
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return SL10n.ailockUnavailable
        case .http(let status, let code, _):
            if status == 401 || status == 403 { return SL10n.ailockNoAccess }
            if status == 429 { return SL10n.ailockRateLimited }
            return code.map { "\(SL10n.ailockRequestFailed) (\($0))" } ?? SL10n.ailockRequestFailed
        case .missingTicket:
            return SL10n.ailockNoStreaming
        case .badResponse:
            return SL10n.ailockRequestFailed
        case .fileTooLarge:
            return SL10n.ailockFileTooLarge
        case .unsupportedFileType:
            return SL10n.ailockFileUnsupported
        }
    }
}

// MARK: - Сервис

/// REST-часть Айлока (door-2 gateway). Стриминг живёт в `AilockWebSocket`.
///
/// STMOB-274. Контракт снят живыми пробами прода и из раздаваемого острова
/// `/salamander-chat/ailock-chat.mjs`:
///   engineApiUrl = https://<homeserver>/api/ailock/v1
///   BASE         = engineApiUrl + /api/v1
/// Двойной `/api/v1` — не опечатка, а фактический живой путь: ingress монтирует
/// gateway на `/api/ailock/v1`, а кит сам дописывает `/api/v1`.
///
/// Мультидомен (STMOB-246): база всегда выводится из `clientProxy.homeserver`.
/// Токен не кэшируется — MAS ротирует его, провайдер зовётся на каждый запрос.
final class AilockService {
    private let engineBaseURL: String
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: (() async -> Void)?

    private let session: URLSession

    /// Последние известные capabilities: приходят и в теле POST /sessions,
    /// и заголовком `X-Ailock-Capabilities` в ответе списка бесед.
    private(set) var capabilities = AilockCapabilities()

    init(homeserver: String,
         accessTokenProvider: @escaping () throws -> String,
         forceTokenRefresh: (() async -> Void)? = nil) {
        let trimmed = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        engineBaseURL = "\(trimmed)/api/ailock/v1"
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)

        os_log(.default, log: ailockLog, "AilockService init: base=%{public}@", engineBaseURL)
    }

    /// Базовый префикс REST-роутов.
    private var apiBase: String {
        "\(engineBaseURL)/api/v1"
    }

    /// Развёрнут ли door-2 на этом домене.
    ///
    /// STMOB-274: пока Айлока нет в реестре apps-api, вкладка «Приложения» подмешивает
    /// запись локально — но только там, где сервис реально есть. На домене без door-2
    /// (например .uz, где контур на HOLD) запрос уходит в SPA и роут не отвечает как API,
    /// поэтому приложение просто не появится — это и есть тихая деградация.
    static func probeAvailability(homeserver: String, accessToken: String?) async -> Bool {
        let trimmed = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        guard let url = URL(string: "\(trimmed)/api/ailock/v1/api/v1/conversations?limit=1") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // 200 — доступ есть; 401/403 — роут живой, но токен не принят (это тоже «сервис есть»).
            // 404 приходит и от gateway (not_found), и от SPA — считаем, что сервиса нет.
            return http.statusCode == 200 || http.statusCode == 401 || http.statusCode == 403
        } catch {
            return false
        }
    }

    /// Хост для WebSocket — тот же, схема wss.
    var webSocketBase: String {
        engineBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }

    // MARK: - Сессия и стриминг

    /// POST /sessions — создаёт (или возобновляет) беседу и выдаёт одноразовый ws-тикет.
    ///
    /// Важно: в ките этот вызов идёт мимо общего транспорта и НЕ рефрешит токен на 401.
    /// Мы делаем ретрай сами — иначе протухший MAS-токен молча ломает весь чат.
    func createSession(agentID: String, conversationID: String? = nil) async throws -> AilockSession {
        var body: [String: Any] = ["agent_id": agentID]
        if let conversationID { body["conversation_id"] = conversationID }

        let data = try await request(path: "/sessions",
                                     method: "POST",
                                     jsonBody: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversation = json["conversation_id"] as? String else {
            throw AilockError.badResponse
        }
        guard let ticket = json["ws_ticket"] as? String, !ticket.isEmpty else {
            // Кит в этом месте прямо говорит: скорее всего выключен ticket-store на сервере.
            throw AilockError.missingTicket
        }

        let caps = AilockCapabilities(json: json["capabilities"] as? [String: Any])
        capabilities = caps
        return AilockSession(conversationID: conversation, wsTicket: ticket, capabilities: caps)
    }

    /// URL сокета. Ключ — conversation_id, а не идентификатор сессии.
    func webSocketURL(conversationID: String, ticket: String) -> URL? {
        let conv = conversationID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationID
        let tkt = ticket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ticket
        return URL(string: "\(webSocketBase)/api/v1/sessions/\(conv)/ws?ticket=\(tkt)")
    }

    // MARK: - Беседы

    /// GET /conversations. Пагинация не курсорная: `before` — ISO-метка последнего элемента.
    func conversations(agentID: String?, limit: Int = 50, before: Date? = nil) async throws -> [AilockConversation] {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let agentID, !agentID.isEmpty { query.append(URLQueryItem(name: "agent_id", value: agentID)) }
        if let before { query.append(URLQueryItem(name: "before", value: Self.iso8601.string(from: before))) }

        let (data, response) = try await requestWithResponse(path: "/conversations", method: "GET", query: query)

        // Capabilities дублируются заголовком ответа — забираем и отсюда.
        if let header = response.value(forHTTPHeaderField: "X-Ailock-Capabilities"),
           let headerData = header.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] {
            capabilities = AilockCapabilities(json: json)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AilockError.badResponse
        }
        let rows = json["conversations"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.conversation(from:))
    }

    /// GET /conversations/search?q= — ответ голым массивом, не конвертом.
    func searchConversations(query: String, agentID: String?) async throws -> [AilockConversation] {
        var items = [URLQueryItem(name: "q", value: query)]
        if let agentID, !agentID.isEmpty { items.append(URLQueryItem(name: "agent_id", value: agentID)) }

        let data = try await request(path: "/conversations/search", method: "GET", query: items)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AilockError.badResponse
        }
        return rows.compactMap(Self.conversation(from:))
    }

    func deleteConversation(_ conversationID: String) async throws {
        _ = try await request(path: "/conversations/\(Self.escape(conversationID))", method: "DELETE")
    }

    /// GET /conversations/{id}/status — нужен перед реконнектом и при открытии беседы.
    func status(conversationID: String) async throws -> AilockConversationStatus {
        let data = try await request(path: "/conversations/\(Self.escape(conversationID))/status", method: "GET")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AilockError.badResponse
        }
        var pending: AilockPendingQuestion?
        if let q = json["pending_question"] as? [String: Any],
           let id = q["question_id"] as? String,
           let text = q["question"] as? String {
            pending = AilockPendingQuestion(questionID: id, question: text, defaultAnswer: q["default"] as? String)
        }
        return AilockConversationStatus(running: json["running"] as? Bool == true, pendingQuestion: pending)
    }

    // MARK: - История

    /// GET /conversations/{id}/messages.
    ///
    /// Ответ — не готовые сообщения, а сырые строки LLM-лога (user/assistant/tool/system).
    /// Разбор повторяет логику острова, иначе история выглядит иначе, чем живой стрим.
    func messages(conversationID: String) async throws -> [AilockMessage] {
        let data = try await request(path: "/conversations/\(Self.escape(conversationID))/messages", method: "GET")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AilockError.badResponse
        }
        let rows = json["messages"] as? [[String: Any]] ?? []
        return AilockHistoryParser.parse(rows: rows)
    }

    // MARK: - Файлы

    /// POST /conversations/{id}/attachments — multipart, поле `file`, ровно один файл на запрос.
    /// Полученный id уходит в WS-кадре вместе с текстом сообщения.
    func uploadAttachment(conversationID: String, fileURL: URL) async throws -> AilockFile {
        let filename = fileURL.lastPathComponent
        let mimeType = Self.mimeType(for: fileURL)
        let fileData = try Data(contentsOf: fileURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let data = try await request(path: "/conversations/\(Self.escape(conversationID))/attachments",
                                     method: "POST",
                                     rawBody: body,
                                     contentType: "multipart/form-data; boundary=\(boundary)")

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // Движок отвечает то `id`, то `attachment_id` — кит принимает оба.
        guard let id = (json?["id"] as? String) ?? (json?["attachment_id"] as? String) else {
            throw AilockError.badResponse
        }
        return AilockFile(id: id, filename: filename, mimeType: mimeType, url: nil)
    }

    /// Скачивание файла, присланного агентом, во временную директорию.
    /// Ссылка может прийти относительной — тогда достраиваем от базы движка.
    func download(file: AilockFile) async throws -> URL {
        guard let raw = file.url, let url = absoluteURL(from: raw) else { throw AilockError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token = try? accessTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw AilockError.http(status: status, code: nil, detail: nil)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fileURL = destination.appendingPathComponent(file.filename.isEmpty ? "file" : file.filename)
        try data.write(to: fileURL)
        return fileURL
    }

    func absoluteURL(from raw: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        // Кит строит ссылки относительно engineApiUrl, а не корня сайта.
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: "\(engineBaseURL)\(path)")
    }

    // MARK: - Транспорт

    private func request(path: String,
                         method: String,
                         query: [URLQueryItem] = [],
                         jsonBody: [String: Any]? = nil,
                         rawBody: Data? = nil,
                         contentType: String? = nil) async throws -> Data {
        try await requestWithResponse(path: path,
                                      method: method,
                                      query: query,
                                      jsonBody: jsonBody,
                                      rawBody: rawBody,
                                      contentType: contentType).0
    }

    /// Общий транспорт: свежий токен на каждый запрос, на 401 — refresh и ровно один повтор.
    private func requestWithResponse(path: String,
                                     method: String,
                                     query: [URLQueryItem] = [],
                                     jsonBody: [String: Any]? = nil,
                                     rawBody: Data? = nil,
                                     contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: "\(apiBase)\(path)") else { throw AilockError.badResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AilockError.badResponse }

        var lastError: Error = AilockError.badResponse

        for attempt in 1...2 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 20

            if let token = try? accessTokenProvider() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            } else if let rawBody {
                request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.httpBody = rawBody
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw AilockError.badResponse }

                if http.statusCode == 401, attempt == 1 {
                    os_log(.default, log: ailockLog, "%{public}@ %{public}@: 401 — обновляем токен", method, path)
                    await forceTokenRefresh?()
                    continue
                }

                if (200...299).contains(http.statusCode) {
                    return (data, http)
                }

                let body = try? JSONDecoder().decode(AilockErrorBody.self, from: data)

                // 404 на нашем префиксе означает, что door-2 на этом домене не развёрнут:
                // молча деградируем, а не показываем «ошибка сервера» (правило мультидомена).
                if http.statusCode == 404, body?.error == "not_found" {
                    throw AilockError.unavailable
                }
                if http.statusCode == 413 { throw AilockError.fileTooLarge }
                if http.statusCode == 415 { throw AilockError.unsupportedFileType }

                throw AilockError.http(status: http.statusCode, code: body?.error, detail: body?.detail)
            } catch {
                lastError = error
                if attempt == 2 { break }
                // Сетевую ошибку не ретраим — повтор только ради 401 выше.
                if !(error is AilockError) { break }
                if case AilockError.http(let status, _, _) = error, status == 401 { continue }
                break
            }
        }

        os_log(.error, log: ailockLog, "%{public}@ %{public}@ failed: %{public}@",
               method, path, lastError.localizedDescription)
        throw lastError
    }

    // MARK: - Разбор

    private static func conversation(from json: [String: Any]) -> AilockConversation? {
        guard let id = json["id"] as? String else { return nil }
        return AilockConversation(id: id,
                                  title: json["title"] as? String,
                                  createdAt: date(from: json["created_at"] as? String),
                                  lastMessageAt: date(from: json["last_message_at"] as? String))
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601.date(from: string) ?? iso8601Plain.date(from: string)
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: return "application/octet-stream"
        }
    }
}
