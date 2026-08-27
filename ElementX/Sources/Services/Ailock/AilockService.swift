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
    /// STMOB-285: набор моделей приезжает В ОТВЕТЕ на подъём сессии — и при
    /// создании беседы, и при возобновлении, причём с ранее выбранным сотрудником
    /// вариантом. Отдельный GET нужен только для обновления уже живой сессии.
    /// `nil` — выбор этой беседе не положен, чип не рисуем (это норма, не ошибка).
    let llmChains: AilockLLMChains?
}

/// Уровень размышления. Шкала закрытая: значение вне её сервер отвергает
/// как `400 invalid_reasoning_mode`.
enum AilockReasoningMode: String, CaseIterable, Equatable {
    case auto, low, medium, high

    var title: String {
        switch self {
        case .auto: SL10n.ailockReasoningAuto
        case .low: SL10n.ailockReasoningLow
        case .medium: SL10n.ailockReasoningMedium
        case .high: SL10n.ailockReasoningHigh
        }
    }
}

/// Одна цепочка (модель) из набора, выданного сотруднику.
struct AilockLLMChain: Identifiable, Equatable {
    let id: String
    let displayName: String
    let modelWindow: Int?
    /// Сколько звеньев в цепочке — `members[]` контракта. Веб показывает это
    /// подписью под названием («2 звена»), повторяем.
    let memberCount: Int
    /// Вариант по умолчанию — в меню помечается словом, как в вебе.
    let isDefault: Bool

    init?(json: [String: Any]) {
        // STMOB-287: идентификатор читаем ТЕРПИМО. Раньше здесь требовалась
        // строка ровно под именем `id`, и любое расхождение — число вместо
        // строки, имя `chain_id` — приводило к тому, что compactMap молча
        // вычищал ВЕСЬ список, а снаружи это выглядело как «сервер не прислал
        // моделей». Так же терпимо мы уже читаем идентификаторы папок Диска.
        let rawID = (json["id"] as? String)
            ?? (json["chain_id"] as? String)
            ?? (json["id"] as? Int).map(String.init)
            ?? (json["chain_id"] as? Int).map(String.init)
        guard let rawID, !rawID.isEmpty else { return nil }
        id = rawID
        // Показывать сам id нельзя — он служебный. Если имени нет, честнее
        // промолчать, чем выводить идентификатор.
        displayName = ((json["display_name"] as? String) ?? (json["name"] as? String) ?? (json["title"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let members = json["members"] as? [[String: Any]] ?? []
        memberCount = members.count
        isDefault = json["is_default"] as? Bool == true
        // `model_window` лежит у ЗВЕНА, а не у цепочки — берём у первого.
        modelWindow = (members.first?["model_window"] as? Int) ?? (json["model_window"] as? Int)
    }

    /// Подпись в меню: число звеньев и пометка варианта по умолчанию.
    var menuSubtitle: String {
        var parts: [String] = []
        if memberCount > 0 { parts.append(SL10n.ailockChainLinks(memberCount)) }
        if isDefault { parts.append(SL10n.ailockChainDefault) }
        return parts.joined(separator: " · ")
    }
}

/// Набор моделей беседы плюс состояние управления размышлением.
struct AilockLLMChains: Equatable {
    let chains: [AilockLLMChain]
    let activeChainID: String?
    let reasoningMode: AilockReasoningMode
    /// Действующая модель не умеет управлять размышлением — чип не показываем,
    /// иначе кнопка была бы без эффекта.
    let reasoningControllable: Bool

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        let raw = (json["chains"] as? [[String: Any]])
            ?? (json["items"] as? [[String: Any]])
            ?? (json["available"] as? [[String: Any]])
            ?? []
        chains = raw.compactMap(AilockLLMChain.init(json:))
        // Диагностика на случай расхождения формы: сколько элементов пришло и
        // сколько мы смогли прочитать. Разрыв между ними означает, что имена
        // полей разошлись с контрактом, а не что сервер прислал пусто.
        if raw.count != chains.count {
            DiagLog.write("Ailock", "набор моделей: пришло \(raw.count), прочитано \(chains.count) — расходятся имена полей: \(raw.first?.keys.sorted().joined(separator: ",") ?? "-")")
        } else if raw.isEmpty {
            DiagLog.write("Ailock", "набор моделей пуст, ключи llm_chains: \(json.keys.sorted().joined(separator: ","))")
        }
        activeChainID = json["active_chain_id"] as? String
        reasoningMode = (json["reasoning_mode"] as? String).flatMap(AilockReasoningMode.init(rawValue:)) ?? .auto
        reasoningControllable = json["reasoning_controllable"] as? Bool == true
    }

    var activeChain: AilockLLMChain? {
        chains.first { $0.id == activeChainID }
    }
}

/// «Чем отвечено» — метка КОНКРЕТНОГО хода.
///
/// STMOB-285: вычислять её из `active_chain_id` нельзя. Тот описывает следующий
/// ход и меняется по ходу беседы: подставив его в прошлые ответы, мы перепишем
/// всю историю задним числом под текущий выбор. Метка приезжает вместе с ходом —
/// в живом потоке финальным `agent.response`, в истории полем у строки.
struct AilockAnswerLLM: Equatable {
    let chainID: String?
    let provider: String?
    let model: String?
    let selectedBy: String?
    let reasoningMode: AilockReasoningMode?
    /// Размышление просили, но оно не применилось. Показывать честно: иначе
    /// человек уверен, что получил дорогой режим, а получил обычный.
    let reasoningApplied: Bool?

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        chainID = json["chain_id"] as? String
        provider = json["provider"] as? String
        model = json["model"] as? String
        selectedBy = json["selected_by"] as? String
        reasoningMode = (json["reasoning_mode"] as? String).flatMap(AilockReasoningMode.init(rawValue:))
        reasoningApplied = json["reasoning_applied"] as? Bool
    }

    /// Человекочитаемое имя: сопоставляем с набором беседы, а сам `chain_id`
    /// не показываем никогда.
    func displayName(in chains: AilockLLMChains?) -> String? {
        if let chainID, let match = chains?.chains.first(where: { $0.id == chainID }), !match.displayName.isEmpty {
            return match.displayName
        }
        if let model, !model.isEmpty { return model }
        return nil
    }
}

/// Уведомление о смене набора по ходу беседы. Приезжает дважды — событием в
/// потоке и системной строкой в истории, поэтому дедуп по `messageID`.
struct AilockSelectionNotice: Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
    let severity: String?

    init?(json: [String: Any]?) {
        guard let json,
              let messageID = json["message_id"] as? String, !messageID.isEmpty,
              let text = json["text"] as? String, !text.isEmpty else { return nil }
        id = messageID
        kind = json["kind"] as? String ?? "switched"
        self.text = text
        severity = json["severity"] as? String
    }
}

/// Лимиты расхода: сервер отдаёт ТОЛЬКО проценты заполненности окон, назначенных
/// сотруднику. Абсолютных сумм организации маршрут не отдаёт и не должен.
///
/// ⚠️ Проценты сейчас занижены: часть ходов у движка помечена `unpriced`, тарифа
/// нет. Поэтому чип только информирует — никаких блокировок и отказов на этой
/// цифре строить нельзя, и порог может не сработать вовсе.
struct AilockSpendLimit: Identifiable, Equatable {
    let id: String
    let title: String
    let percent: Double

    init?(json: [String: Any]) {
        guard let percent = (json["percent"] as? Double) ?? (json["percent"] as? Int).map(Double.init) else { return nil }
        id = (json["id"] as? String) ?? (json["window"] as? String) ?? UUID().uuidString
        title = (json["display_name"] as? String) ?? (json["window"] as? String) ?? ""
        self.percent = percent
    }
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
    /// Идентификатор вложения внутри беседы. Если он есть — качаем по owner-scoped пути.
    let attachmentID: String?

    init(id: String, filename: String, mimeType: String, url: String?, attachmentID: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.url = url
        self.attachmentID = attachmentID
    }

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    /// Можно ли файл скачать.
    ///
    /// STMOB-274, вердикт Shelly 30.07: файлы, произведённые агентом, движок пока кладёт
    /// в локальный uploads-контур и отдаёт ссылкой `/api/v1/uploads/{uuid}`. Этот путь
    /// door-2 сознательно НЕ проксирует (адресация по имени, владение не проверить —
    /// решение STALK-653). Переписать ссылку на owner-scoped путь на клиенте нельзя:
    /// в событии `agent.file` нет `attachment_id`. Перенос агентских файлов в
    /// `chat_attachments` — M24 Ф3, ориентир 10.08. До тех пор такой файл показываем,
    /// но кнопку скачивания не предлагаем — мёртвых кнопок в интерфейсе быть не должно.
    var isDownloadable: Bool {
        if attachmentID != nil { return true }
        guard let url else { return false }
        return !url.contains("/uploads/")
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
    /// STMOB-285: чем отвечён ИМЕННО этот ход. Приезжает с финальным
    /// `agent.response` в потоке и полем `llm` у строки в истории. Пусто —
    /// исполнитель неизвестен (старые ходы, ходы человека); подставлять сюда
    /// текущий выбор нельзя, история перепишется задним числом.
    var llm: AilockAnswerLLM?

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
    /// Локальной копии вложения больше нет, а на сервер оно ещё не уехало.
    /// Отправлять текст молча без обещанного файла нельзя — человек уверен, что файл ушёл.
    case attachmentUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return SL10n.ailockUnavailable
        case .http(let status, let code, _):
            // Машинный код пользователю ничего не говорит: переводим известные в
            // человеческую причину, а незнакомые показываем как есть — иначе при новой
            // ошибке сервера в интерфейсе останется бессодержательное «не удалось».
            switch code {
            case "exchange_failed":
                return SL10n.ailockNoAccess
            case "no_subject_token":
                return SL10n.ailockNoAccess
            case "rate_limited":
                return SL10n.ailockRateLimited
            default:
                break
            }
            if status == 401 || status == 403 { return SL10n.ailockNoAccess }
            if status == 429 { return SL10n.ailockRateLimited }
            if status >= 500 { return SL10n.ailockServerUnavailable }
            return code.map { "\(SL10n.ailockRequestFailed) (\($0))" } ?? SL10n.ailockRequestFailed
        case .missingTicket:
            return SL10n.ailockNoStreaming
        case .badResponse:
            return SL10n.ailockRequestFailed
        case .fileTooLarge:
            return SL10n.ailockFileTooLarge
        case .unsupportedFileType:
            return SL10n.ailockFileUnsupported
        case .attachmentUnavailable:
            return SL10n.ailockAttachFailed
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

    /// STMOB-285: последний известный набор моделей беседы. Обновляется подъёмом
    /// сессии и сменой выбора; нужен ещё и для того, чтобы у метки «чем отвечено»
    /// найти человекочитаемое имя по служебному `chain_id`.
    private(set) var llmChains: AilockLLMChains?

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
    /// STMOB-274. Проба отвечает на вопрос «есть ли здесь сервис», а НЕ «пустят ли меня».
    /// Это разные вещи, и их смешение уже стоило нам сборки 307: на мисти door-2 отдаёт
    /// `502 exchange_failed` (шлюз есть, обмен токена не проходит), проба считала это
    /// отсутствием сервиса — и приложение не показывалось вовсе. В итоге неисправность
    /// стала невидимой: пользователь не видит ни Айлока, ни причины.
    ///
    /// Правило теперь такое: сервисом считается всё, что ответило как API.
    /// * 200 / 401 / 403 — маршрут жив, вопрос только в доступе;
    /// * 5xx с JSON-телом — ответил сам шлюз, значит он развёрнут;
    /// * 404 (в т.ч. `{"error":"not_found"}` от Express) — door-2 здесь не смонтирован;
    /// * HTML — запрос ушёл в SPA, сервиса нет;
    /// * сетевая ошибка — не знаем, считаем, что нет, но результат не кэшируем.
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }

            switch http.statusCode {
            case 200, 401, 403:
                return true
            case 404, 405:
                return false
            default:
                // Всё прочее — только если ответил API, а не страница приложения.
                let isJSON = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
                    || data.first == UInt8(ascii: "{")
                os_log(.default, log: ailockLog, "probe -> %{public}d, json=%{public}@",
                       http.statusCode, isJSON ? "yes" : "no")
                return isJSON
            }
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
    /// - Parameter agentID: nil — агента выбирает сам gateway (server-side default).
    ///   Так и надо: по контракту gateway (подтверждено Shelly 31.07) клиент агента не
    ///   назначает, а подставлять свой — значит однажды разойтись с сервером.
    func createSession(agentID: String?, conversationID: String? = nil) async throws -> AilockSession {
        var body: [String: Any] = [:]
        if let agentID, !agentID.isEmpty { body["agent_id"] = agentID }
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

        // STMOB-285: набор моделей приезжает прямо здесь — второго запроса не нужно.
        // Ключа может не быть вовсе: значит выбор этой беседе не положен, чип не
        // рисуем. Наш шлюз ПЕРЕСОБИРАЕТ тело ответа, а не проксирует, и пробрасывает
        // `llm_chains` только при открытой заслонке — если чип однажды пропадёт при
        // живом движке, смотреть сюда, а не на Айлок.
        let chains = AilockLLMChains(json: json["llm_chains"] as? [String: Any])
        llmChains = chains
        DiagLog.write("Ailock", "сессия поднята: моделей=\(chains?.chains.count ?? 0) размышление=\(chains?.reasoningControllable == true ? "управляемо" : "нет")")

        return AilockSession(conversationID: conversation, wsTicket: ticket, capabilities: caps, llmChains: chains)
    }

    /// Перечитать набор моделей. Работает ТОЛЬКО для живой сессии: после рестарта
    /// пода движка отвечает 404, из базы не читает.
    ///
    /// Поэтому порядок при открытии беседы такой: сперва `createSession` с
    /// `conversationID` (возобновление поднимает живое состояние и само отдаёт
    /// набор), и лишь потом, если нужно обновить список, — этот метод. Обратный
    /// порядок даёт почти гарантированный 404 и лишний запрос.
    func refreshLLMChains(conversationID: String) async throws -> AilockLLMChains? {
        let data = try await request(path: "/conversations/\(Self.escape(conversationID))/llm-chains", method: "GET")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let chains = AilockLLMChains(json: json)
        if let chains { llmChains = chains }
        return chains
    }

    /// Сменить модель и/или уровень размышления. Поля независимы — можно слать
    /// любое одно. `chainID == nil` при `resetChain == true` возвращает беседу к
    /// варианту по умолчанию; операция обратима.
    ///
    /// ⚠️ Выбор действует СО СЛЕДУЮЩЕГО хода: идущий ответ дочитывается прежней
    /// моделью. Это надо сказать человеку, иначе он решит, что не сработало.
    /// ⚠️ Выбор запоминается за СОТРУДНИКОМ, а не за устройством: смена на вебе
    /// будет видна на телефоне и наоборот.
    @discardableResult
    func setLLMChain(conversationID: String,
                     chainID: String?,
                     resetChain: Bool = false,
                     reasoningMode: AilockReasoningMode?) async throws -> AilockLLMChains? {
        var body: [String: Any] = [:]
        if resetChain {
            body["chain_id"] = NSNull()
        } else if let chainID {
            body["chain_id"] = chainID
        }
        if let reasoningMode { body["reasoning_mode"] = reasoningMode.rawValue }

        // Наш шлюз проверяет тело ДО авторизации: пустое даёт 400 empty_selection
        // даже без токена. Значит 400 на этом маршруте ничего не говорит о токене —
        // и значит пустой запрос слать просто незачем.
        guard !body.isEmpty else { return llmChains }

        let data = try await request(path: "/conversations/\(Self.escape(conversationID))/llm-chain",
                                     method: "POST",
                                     jsonBody: body)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Ответ несёт только новое состояние выбора — список цепочек в нём не
        // повторяется, поэтому берём его из уже известного набора.
        guard let json else { return llmChains }
        let updated = AilockLLMChains(json: [
            "chains": llmChains?.chains.map { ["id": $0.id, "display_name": $0.displayName] } ?? [],
            "active_chain_id": json["active_chain_id"] as Any,
            "reasoning_mode": json["reasoning_mode"] as Any,
            "reasoning_controllable": json["reasoning_controllable"] as Any
        ])
        if let updated { llmChains = updated }
        return updated
    }

    /// GET /me/spend-limits — проценты заполненности окон сотрудника.
    /// Пустой ответ = лимитов не назначено, чип не рисуем. Это нормальное
    /// состояние, а не ошибка.
    func spendLimits(chainID: String? = nil) async throws -> [AilockSpendLimit] {
        var query: [URLQueryItem] = []
        if let chainID, !chainID.isEmpty { query.append(URLQueryItem(name: "chain_id", value: chainID)) }
        let data = try await request(path: "/me/spend-limits", method: "GET", query: query)
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let raw = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["limits"] as? [[String: Any]]) ?? []
        return raw.compactMap(AilockSpendLimit.init(json:))
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
        return AilockFile(id: id, filename: filename, mimeType: mimeType, url: nil, attachmentID: id)
    }

    /// Скачивание файла во временную директорию.
    ///
    /// Приоритет — owner-scoped путь по `attachment_id` внутри беседы (единственный,
    /// который door-2 пропускает). Если его нет, идём по ссылке из события; она может
    /// прийти относительной — тогда достраиваем от базы движка.
    func download(file: AilockFile, conversationID: String?) async throws -> URL {
        let source: URL?
        if let attachmentID = file.attachmentID, let conversationID {
            source = URL(string: "\(apiBase)/conversations/\(Self.escape(conversationID))/attachments/\(Self.escape(attachmentID))")
        } else if let raw = file.url {
            source = absoluteURL(from: raw)
        } else {
            source = nil
        }

        guard let url = source else { throw AilockError.badResponse }

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
                    // Контролируемый замер door-2 (запрошен Shelly 30.07): в лог идут только
                    // метод, путь и HTTP-статус — ни токена, ни тела, ни ПДн.
                    os_log(.default, log: ailockLog, "%{public}@ %{public}@ -> %{public}d",
                           method, path, http.statusCode)
                    DiagLog.write("Ailock", "\(method) \(path) -> \(http.statusCode)")
                    return (data, http)
                }

                os_log(.error, log: ailockLog, "%{public}@ %{public}@ -> %{public}d",
                       method, path, http.statusCode)
                DiagLog.write("Ailock", "\(method) \(path) -> \(http.statusCode)")

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
