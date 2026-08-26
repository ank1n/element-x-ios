//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.log

private let ailockWSLog = OSLog(subsystem: "ru.implica.stalk", category: "AilockWS")

/// События потока Айлока.
///
/// STMOB-274. Протокол шире, чем наш экран: движок умеет присылать инструменты,
/// суб-агентов, todo-списки и артефакты. В MVP мы их не рисуем, поэтому всё «рабочее»
/// схлопывается в `.working`, а неизвестные события молча игнорируются — поток
/// не должен падать, когда движок начнёт слать больше.
enum AilockStreamEvent {
    /// Начало генерации ответа.
    case runStarted
    /// Дельта текста ответа. Итоговый текст собирается ТОЛЬКО из этих дельт.
    case token(String)
    /// Смена состояния: агент работает или ждёт ввода.
    case working(Bool)
    /// Терминатор ответа. Для role == "system" несёт текст баннера и severity.
    ///
    /// STMOB-285: здесь же приезжает метка «чем отвечено» (`data.llm`) — один раз,
    /// с финальным событием. В `agent.token.delta` её нет, там только текст.
    case response(role: String, text: String?, severity: String?, llm: AilockAnswerLLM?)
    /// STMOB-285: движок сменил набор моделей по ходу беседы. Это же уведомление
    /// приезжает потом системной строкой в истории — дедуп по `message_id`.
    case selectionNotice(AilockSelectionNotice)
    /// Файл, присланный агентом.
    case file(AilockFile)
    /// Агент задал уточняющий вопрос и ждёт ответа.
    case askUser(AilockPendingQuestion)
    case failed(String)
    case cancelled
    /// Сокет закрылся. `nil` — штатное закрытие.
    case disconnected(Error?)
}

/// Клиент стриминга Айлока.
///
/// Отправка сообщений возможна ТОЛЬКО по этому сокету — REST-роута для отправки нет.
/// Тикет одноразовый и живёт секунды, поэтому на каждый (ре)коннект нужен свежий
/// `POST /sessions`; сам сокет переподключением не занимается — это делает вью-модель.
actor AilockWebSocket {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<AilockStreamEvent>.Continuation?
    private var isClosed = false

    init(url: URL) {
        self.url = url
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // Ресурсный таймаут для сокета не задаём: соединение живёт весь диалог.
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        session = URLSession(configuration: configuration)
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// Открывает сокет и отдаёт поток событий. Поток завершается после `.disconnected`.
    func connect() -> AsyncStream<AilockStreamEvent> {
        let (stream, continuation) = AsyncStream<AilockStreamEvent>.makeStream()
        self.continuation = continuation

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        os_log(.default, log: ailockWSLog, "WS connect")
        Task { await self.receiveLoop() }

        return stream
    }

    // MARK: - Отправка

    /// Сообщение пользователя. `attachment_ids` кладём только непустыми — так делает остров.
    func send(content: String, attachmentIDs: [String] = []) async throws {
        var payload: [String: Any] = ["content": content]
        if !attachmentIDs.isEmpty { payload["attachment_ids"] = attachmentIDs }
        try await send(json: payload)
    }

    /// Ответ на уточняющий вопрос агента.
    func answer(questionID: String, answer: String) async throws {
        try await send(json: ["question_id": questionID, "answer": answer])
    }

    /// Остановка генерации.
    func cancelGeneration() async throws {
        try await send(json: ["type": "cancel"])
    }

    private func send(json: [String: Any]) async throws {
        guard let task, !isClosed else { throw AilockError.badResponse }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else { throw AilockError.badResponse }
        try await task.send(.string(text))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        os_log(.default, log: ailockWSLog, "WS closed")
    }

    // MARK: - Приём

    private func receiveLoop() async {
        guard let task else { return }

        while !isClosed {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text: text) }
                @unknown default:
                    continue
                }
            } catch {
                guard !isClosed else { return }
                os_log(.error, log: ailockWSLog, "WS receive error: %{public}@", error.localizedDescription)
                isClosed = true
                continuation?.yield(.disconnected(error))
                continuation?.finish()
                continuation = nil
                return
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        // ping гасим до диспетчера — отвечать не надо.
        guard event != "ping" else { return }

        let payload = json["data"] as? [String: Any] ?? [:]

        switch event {
        case "agent.run_started":
            continuation?.yield(.runStarted)

        case "agent.token":
            if let delta = payload["delta"] as? String, !delta.isEmpty {
                continuation?.yield(.token(delta))
            }

        case "agent.status":
            // Регистр значения не гарантирован: в одном и том же бандле встречается
            // и "Idle", и lowercase — сравниваем приведённым к нижнему регистру.
            let state = (payload["state"] as? String ?? "").lowercased()
            switch state {
            case "thinking", "toolexecution":
                continuation?.yield(.working(true))
            case "waitingforinput", "idle":
                continuation?.yield(.working(false))
            default:
                break
            }

        case "agent.response":
            // Ключа `llm` может не быть вовсе — исполнитель неизвестен. Это
            // нормальное состояние, а не ошибка: рисуем «неизвестно» и НЕ
            // подставляем текущую активную цепочку, иначе перепишем прошлое.
            continuation?.yield(.response(role: payload["role"] as? String ?? "assistant",
                                          text: payload["text"] as? String,
                                          severity: payload["severity"] as? String,
                                          llm: AilockAnswerLLM(json: payload["llm"] as? [String: Any])))

        case "agent.llm_selection_notice":
            if let notice = AilockSelectionNotice(json: payload) {
                continuation?.yield(.selectionNotice(notice))
            }

        case "agent.file":
            // По текущему коду движка событие несёт только url/filename/mime_type/conversation_id.
            // `attachment_id` читаем на будущее: когда агентские файлы переедут в chat_attachments
            // (M24 Ф3), скачивание заработает без правок клиента.
            let attachmentID = payload["attachment_id"] as? String
            let url = payload["url"] as? String
            guard url != nil || attachmentID != nil else { break }
            let filename = payload["filename"] as? String ?? "file"
            let mime = payload["mime_type"] as? String ?? "application/octet-stream"
            continuation?.yield(.file(AilockFile(id: url ?? attachmentID ?? UUID().uuidString,
                                                 filename: filename,
                                                 mimeType: mime,
                                                 url: url,
                                                 attachmentID: attachmentID)))

        case "agent.ask_user":
            guard let id = payload["question_id"] as? String,
                  let question = payload["question"] as? String else { break }
            continuation?.yield(.askUser(AilockPendingQuestion(questionID: id,
                                                               question: question,
                                                               defaultAnswer: payload["default"] as? String)))

        case "agent.error":
            continuation?.yield(.failed(payload["message"] as? String ?? SL10n.ailockRequestFailed))

        case "agent.cancelled":
            continuation?.yield(.cancelled)

        case "agent.thinking", "agent.tool_start", "agent.tool_progress", "agent.tool_end", "agent.tool_result":
            // Ход работы агента в MVP не показываем — только факт «работает».
            continuation?.yield(.working(true))

        default:
            // Артефакты, суб-агенты, todo и всё будущее — молча игнорируем.
            break
        }
    }
}
