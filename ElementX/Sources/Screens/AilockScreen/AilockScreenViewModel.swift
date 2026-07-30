//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import UIKit

typealias AilockScreenViewModelType = StateStoreViewModel<AilockScreenViewState, AilockScreenViewAction>

protocol AilockScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<AilockScreenViewModelAction, Never> { get }
    var context: AilockScreenViewModelType.Context { get }
}

/// Экран чата с агентом Айлок.
///
/// STMOB-274. Ключевые особенности контура, которые определяют логику:
/// * отправить сообщение можно ТОЛЬКО по WebSocket — REST-роута для отправки нет;
/// * `ws_ticket` одноразовый и живёт секунды, поэтому на каждый (ре)коннект нужен
///   свежий `POST /sessions` — сессию нельзя создать заранее «про запас»;
/// * итоговый текст ответа собирается только из дельт `agent.token`;
/// * вложения загружаются в уже существующую беседу, т.е. после создания сессии.
class AilockScreenViewModel: AilockScreenViewModelType, AilockScreenViewModelProtocol {
    private let service: AilockService
    private let agentID: String

    /// Голосовой ввод. `nil` — если расшифровка на этом сервере недоступна.
    private let transcriber: AilockVoiceTranscriber?
    private let voiceRecorder = AilockVoiceRecorder()
    private var voiceTickerTask: Task<Void, Never>?

    private let actionsSubject: PassthroughSubject<AilockScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AilockScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    /// Текущая беседа. nil — пользователь ещё ничего не отправлял в этой сессии экрана.
    private(set) var conversationID: String?

    private var socket: AilockWebSocket?
    private var streamTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Буфер дельт: перерисовывать ленту на каждый токен слишком дорого.
    private var streamBuffer = ""
    private var flushTask: Task<Void, Never>?
    private var streamingMessageID: String?

    /// Локальные файлы, выбранные пользователем: id вложения → URL на диске.
    private var localAttachments: [String: URL] = [:]

    private static let lastConversationKey = "ailock.lastConversationID"

    init(service: AilockService, agentID: String, transcriber: AilockVoiceTranscriber?) {
        self.service = service
        self.agentID = agentID
        self.transcriber = transcriber

        super.init(initialViewState: AilockScreenViewState())

        observeApplicationState()
        restoreLastConversation()
    }

    override func process(viewAction: AilockScreenViewAction) {
        switch viewAction {
        case .sendMessage:
            send()
        case .stopGeneration:
            stopGeneration()
        case .attachFiles(let urls):
            attach(urls: urls)
        case .removeAttachment(let id):
            state.pendingAttachments.removeAll { $0.id == id }
            localAttachments[id] = nil
        case .openConversations:
            actionsSubject.send(.openConversations)
        case .newConversation:
            startNewConversation()
        case .openFile(let file):
            open(file: file)
        case .retry:
            state.errorMessage = nil
            state.isUnavailable = false
            restoreLastConversation()
        case .dismissError:
            state.errorMessage = nil
        case .startVoiceInput:
            startVoiceInput()
        case .finishVoiceInput:
            finishVoiceInput()
        case .cancelVoiceInput:
            cancelVoiceInput()
        }
    }

    // MARK: - Голосовой ввод

    /// Диктовка: пишем WAV, расшифровываем через recording-api и кладём текст в поле —
    /// не отправляя. Пользователь должен успеть поправить распознанное перед отправкой.
    private func startVoiceInput() {
        guard state.voicePhase == .idle, transcriber != nil else { return }

        Task { [weak self] in
            guard let self else { return }
            guard await AilockVoiceRecorder.requestPermission() else {
                state.errorMessage = SL10n.ailockMicDenied
                return
            }

            do {
                try voiceRecorder.start()
            } catch {
                state.errorMessage = SL10n.ailockRecordFailed
                return
            }

            state.voicePhase = .recording
            state.voiceDuration = 0
            state.voiceLevel = 0
            startVoiceTicker()
        }
    }

    private func startVoiceTicker() {
        voiceTickerTask?.cancel()
        voiceTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, state.voicePhase == .recording else { return }
                state.voiceDuration = voiceRecorder.duration
                state.voiceLevel = voiceRecorder.level()
                // Длинную диктовку закрываем сами: это поле ввода, а не голосовое сообщение.
                if state.voiceDuration >= AilockVoiceRecorder.maxDuration {
                    finishVoiceInput()
                    return
                }
            }
        }
    }

    private func finishVoiceInput() {
        guard state.voicePhase == .recording else { return }
        voiceTickerTask?.cancel()

        guard let fileURL = voiceRecorder.finish() else {
            state.voicePhase = .idle
            state.errorMessage = SL10n.ailockRecordTooShort
            return
        }

        state.voicePhase = .transcribing
        Task { [weak self] in
            guard let self, let transcriber else { return }
            do {
                let text = try await transcriber.transcribe(fileURL: fileURL)
                let existing = state.bindings.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                state.bindings.composerText = existing.isEmpty ? text : existing + " " + text
            } catch {
                state.errorMessage = (error as? LocalizedError)?.errorDescription ?? SL10n.ailockTranscribeFailed
                MXLog.error("sTalk Ailock: диктовка не расшифрована: \(error)")
                // Маршрута нет или он не наш (другой домен, выключенный recording-api) —
                // прячем микрофон до конца сессии, чтобы не предлагать заведомо мёртвую кнопку.
                if case AilockVoiceError.http(let status) = error, status == 403 || status == 404 || status == 405 {
                    state.isVoiceUnavailable = true
                }
            }
            state.voicePhase = .idle
        }
    }

    private func cancelVoiceInput() {
        voiceTickerTask?.cancel()
        voiceRecorder.cancel()
        state.voicePhase = .idle
        state.voiceDuration = 0
        state.voiceLevel = 0
    }

    /// Открыть существующую беседу (выбор из истории).
    func open(conversation: AilockConversation) {
        guard conversation.id != conversationID else { return }
        closeSocket()
        conversationID = conversation.id
        state.conversationTitle = conversation.title
        state.messages = []
        state.pendingQuestion = nil
        UserDefaults.standard.set(conversation.id, forKey: Self.lastConversationKey)
        loadHistory()
    }

    /// Освободить ресурсы при закрытии экрана.
    func stop() {
        closeSocket()
        workTask?.cancel()
        flushTask?.cancel()
    }

    // MARK: - Отправка

    private func send() {
        let text = state.bindings.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = state.pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        state.bindings.composerText = ""
        state.pendingAttachments = []
        state.errorMessage = nil

        // Эхо от сервера не приходит — вставляем реплику пользователя оптимистично.
        let userMessage = AilockMessage(id: "user-\(UUID().uuidString)",
                                        role: .user,
                                        text: text,
                                        files: attachments,
                                        createdAt: Date())
        state.messages.append(userMessage)

        let pendingQuestion = state.pendingQuestion
        state.pendingQuestion = nil

        workTask?.cancel()
        workTask = Task { [weak self] in
            await self?.performSend(text: text, attachments: attachments, answering: pendingQuestion)
        }
    }

    private func performSend(text: String, attachments: [AilockFile], answering: AilockPendingQuestion?) async {
        do {
            try await ensureConnected()

            var attachmentIDs: [String] = []
            if !attachments.isEmpty, let conversationID {
                state.isUploadingAttachment = true
                defer { state.isUploadingAttachment = false }

                for attachment in attachments {
                    guard let localURL = localAttachments[attachment.id] else { continue }
                    let uploaded = try await service.uploadAttachment(conversationID: conversationID, fileURL: localURL)
                    attachmentIDs.append(uploaded.id)
                    localAttachments[attachment.id] = nil
                }
            }

            guard let socket else { throw AilockError.badResponse }

            if let answering {
                try await socket.answer(questionID: answering.questionID, answer: text)
            } else {
                try await socket.send(content: text, attachmentIDs: attachmentIDs)
            }

            beginStreamingPlaceholder()
        } catch {
            handle(error: error)
        }
    }

    private func stopGeneration() {
        guard let socket else { return }
        Task {
            try? await socket.cancelGeneration()
        }
    }

    // MARK: - Соединение

    /// Создаёт сессию и открывает сокет. Тикет одноразовый, поэтому вызывается
    /// непосредственно перед каждым подключением, а не заранее.
    private func ensureConnected() async throws {
        if socket != nil { return }

        state.isConnecting = true
        defer { state.isConnecting = false }

        let session = try await service.createSession(agentID: agentID, conversationID: conversationID)
        conversationID = session.conversationID
        UserDefaults.standard.set(session.conversationID, forKey: Self.lastConversationKey)

        guard let url = service.webSocketURL(conversationID: session.conversationID, ticket: session.wsTicket) else {
            throw AilockError.badResponse
        }

        let socket = AilockWebSocket(url: url)
        self.socket = socket
        reconnectAttemptCount = 0

        let stream = await socket.connect()
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(event: event)
            }
        }
    }

    private func closeSocket() {
        streamTask?.cancel()
        streamTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
    }

    private var reconnectAttemptCount = 0

    /// Реконнект по схеме острова: до 5 попыток, задержки 1/2/4/8/8 с, перед каждой —
    /// проверка статуса беседы (вдруг ответ уже готов и переподключаться незачем).
    private func scheduleReconnect() {
        guard let conversationID else { return }
        guard reconnectAttemptCount < 5 else {
            finalizeStreamingMessage()
            return
        }

        let attempt = reconnectAttemptCount
        reconnectAttemptCount += 1

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let delay = min(1_000_000_000 * UInt64(1 << attempt), 8_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }

            do {
                let status = try await service.status(conversationID: conversationID)

                if !status.running, status.pendingQuestion == nil {
                    // Ответ уже завершён — просто перечитываем историю.
                    finalizeStreamingMessage()
                    loadHistory()
                    return
                }

                if let question = status.pendingQuestion {
                    state.pendingQuestion = question
                }

                try await ensureConnected()
            } catch {
                scheduleReconnect()
            }
        }
    }

    // MARK: - Приём событий

    @MainActor
    private func handle(event: AilockStreamEvent) {
        switch event {
        case .runStarted:
            state.isRunning = true
            beginStreamingPlaceholder()

        case .token(let delta):
            state.isRunning = true
            append(delta: delta)

        case .working(let isWorking):
            state.isRunning = isWorking

        case .response(let role, let text, let severity):
            if role == "system" {
                flushBuffer()
                removeEmptyStreamingPlaceholder()
                state.messages.append(AilockMessage(id: "system-\(UUID().uuidString)",
                                                    role: .system(severity: severity ?? "info"),
                                                    text: text ?? "",
                                                    createdAt: Date()))
                state.isRunning = false
                streamingMessageID = nil
                return
            }
            // Для обычного ответа `text` — не источник истины (кит его не читает),
            // но если дельты потерялись, лучше показать его, чем пустое сообщение.
            flushBuffer()
            if let index = streamingIndex(), state.messages[index].text.isEmpty, let text, !text.isEmpty {
                state.messages[index].text = text
            }
            finalizeStreamingMessage()
            state.isRunning = false

        case .file(let file):
            flushBuffer()
            if let index = streamingIndex() {
                state.messages[index].files.append(file)
            } else {
                state.messages.append(AilockMessage(id: "file-\(UUID().uuidString)",
                                                    role: .assistant,
                                                    text: "",
                                                    files: [file],
                                                    createdAt: Date()))
            }

        case .askUser(let question):
            flushBuffer()
            finalizeStreamingMessage()
            state.isRunning = false
            state.pendingQuestion = question
            state.messages.append(AilockMessage(id: "ask-\(question.questionID)",
                                                role: .assistant,
                                                text: question.question,
                                                createdAt: Date()))

        case .failed(let message):
            flushBuffer()
            removeEmptyStreamingPlaceholder()
            state.isRunning = false
            state.messages.append(AilockMessage(id: "error-\(UUID().uuidString)",
                                                role: .system(severity: "danger"),
                                                text: message,
                                                createdAt: Date()))

        case .cancelled:
            flushBuffer()
            finalizeStreamingMessage()
            state.isRunning = false

        case .disconnected(let error):
            socket = nil
            streamTask = nil
            guard error != nil else { return }
            // Обрыв на живой генерации — пробуем восстановиться.
            if state.isRunning || streamingMessageID != nil {
                scheduleReconnect()
            }
        }
    }

    // MARK: - Стриминг текста

    private func beginStreamingPlaceholder() {
        guard streamingMessageID == nil else { return }
        let identifier = "asst-\(UUID().uuidString)"
        streamingMessageID = identifier
        state.messages.append(AilockMessage(id: identifier,
                                            role: .assistant,
                                            text: "",
                                            createdAt: Date(),
                                            isStreaming: true))
    }

    private func streamingIndex() -> Int? {
        guard let streamingMessageID else { return nil }
        return state.messages.firstIndex { $0.id == streamingMessageID }
    }

    /// Дельты копятся в буфере и выливаются в состояние пачками — иначе на быстром
    /// потоке SwiftUI перерисовывает ленту десятки раз в секунду.
    private func append(delta: String) {
        beginStreamingPlaceholder()
        streamBuffer += delta

        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, !Task.isCancelled else { return }
            flushTask = nil
            flushBuffer()
        }
    }

    private func flushBuffer() {
        flushTask?.cancel()
        flushTask = nil
        guard !streamBuffer.isEmpty else { return }
        if let index = streamingIndex() {
            state.messages[index].text += streamBuffer
        }
        streamBuffer = ""
    }

    private func finalizeStreamingMessage() {
        flushBuffer()
        if let index = streamingIndex() {
            state.messages[index].isStreaming = false
            if state.messages[index].isEmpty {
                state.messages.remove(at: index)
            }
        }
        streamingMessageID = nil
    }

    private func removeEmptyStreamingPlaceholder() {
        if let index = streamingIndex(), state.messages[index].isEmpty {
            state.messages.remove(at: index)
        }
        streamingMessageID = nil
    }

    // MARK: - История

    private func restoreLastConversation() {
        guard let saved = UserDefaults.standard.string(forKey: Self.lastConversationKey), !saved.isEmpty else { return }
        conversationID = saved
        loadHistory()
    }

    private func loadHistory() {
        guard let conversationID else { return }

        state.isLoadingHistory = true
        workTask?.cancel()
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await service.messages(conversationID: conversationID)
                guard !Task.isCancelled else { return }
                state.messages = messages
                state.isLoadingHistory = false

                // Беседа могла остаться в работе — подхватываем состояние.
                let status = try await service.status(conversationID: conversationID)
                if let question = status.pendingQuestion {
                    state.pendingQuestion = question
                } else if status.running {
                    state.isRunning = true
                    try await ensureConnected()
                }
            } catch {
                state.isLoadingHistory = false
                switch error as? AilockError {
                case .unavailable:
                    state.isUnavailable = true
                case .http(let status, _, _) where status == 404:
                    // Беседа могла быть удалена с другого клиента — начинаем с чистого листа.
                    self.conversationID = nil
                    UserDefaults.standard.removeObject(forKey: Self.lastConversationKey)
                    state.messages = []
                default:
                    handle(error: error)
                }
            }
        }
    }

    private func startNewConversation() {
        closeSocket()
        conversationID = nil
        streamingMessageID = nil
        streamBuffer = ""
        UserDefaults.standard.removeObject(forKey: Self.lastConversationKey)
        state.messages = []
        state.pendingQuestion = nil
        state.pendingAttachments = []
        state.conversationTitle = nil
        state.isRunning = false
        state.errorMessage = nil
    }

    // MARK: - Файлы

    private func attach(urls: [URL]) {
        for url in urls {
            // Файл из системного пикера доступен только внутри security scope.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let copy = destination.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)

                let identifier = copy.absoluteString
                localAttachments[identifier] = copy
                state.pendingAttachments.append(AilockFile(id: identifier,
                                                           filename: url.lastPathComponent,
                                                           mimeType: "application/octet-stream",
                                                           url: nil))
            } catch {
                MXLog.error("sTalk Ailock: не удалось скопировать вложение: \(error)")
                state.errorMessage = SL10n.ailockAttachFailed
            }
        }
    }

    private func open(file: AilockFile) {
        guard file.isDownloadable else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await service.download(file: file, conversationID: conversationID)
                state.bindings.sharedFile = AilockSharedFile(url: localURL)
            } catch {
                handle(error: error)
            }
        }
    }

    // MARK: - Прочее

    private func handle(error: Error) {
        if case .unavailable = (error as? AilockError) {
            state.isUnavailable = true
            return
        }
        MXLog.error("sTalk Ailock: \(error)")
        DiagLog.write("Ailock", "error: \(error.localizedDescription)")
        state.errorMessage = (error as? LocalizedError)?.errorDescription ?? SL10n.ailockRequestFailed
        state.isRunning = false
        removeEmptyStreamingPlaceholder()
    }

    /// В фоне сеть не трогаем (правило 0xDEAD10CC): рвём сокет и поднимаем его при возврате.
    private func observeApplicationState() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.flushBuffer()
                self?.closeSocket()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, conversationID != nil, socket == nil else { return }
                guard state.isRunning || state.pendingQuestion != nil else { return }
                reconnectAttemptCount = 0
                scheduleReconnect()
            }
            .store(in: &cancellables)
    }
}
