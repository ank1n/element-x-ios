//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

// MARK: - STMOB-265: транскрибация голосовых по запросу

//
// Паритет с вебом (STALK-666). Бэкенд общий: recording-api принимает сырые байты
// голосового и синхронно (1-2с) отдаёт распознанный текст.
//
// Три правила из постановки, которые здесь зашиты:
//  1. В ЗАШИФРОВАННЫХ комнатах фичи нет вообще — расшифрованное аудио не должно
//     уходить в STT. Гейт стоит выше, в таймлайне, и по шифрованию КОМНАТЫ:
//     у только что отправленного своего сообщения шифрование ещё не применилось,
//     и гейт по событию протёк бы.
//  2. Кэш per-user: наличие записи = «этот пользователь сам запрашивал» → только
//     ему текст показывается сразу. Остальные видят иконку, пока не нажмут.
//  3. Повторно STT не дёргаем: есть текст — показываем из кэша.

enum VoiceTranscriptionPhase: Equatable {
    case idle
    case loading
    /// Распознанный текст.
    case loaded(String)
    /// Сервер отработал, но речи не нашёл.
    case empty
    case failed(String)
}

enum VoiceTranscriptionError: Error {
    case tooLarge(UInt)
    case mediaUnavailable
    case http(Int)
    case badResponse
}

/// Ответ recording-api. Все поля опциональные: сервер может отдать частичный ответ,
/// и падать на декоде из-за лишнего/недостающего ключа мы не хотим.
struct VoiceTranscribeResponse: Decodable {
    let pollId: String?
    let status: String?
    let fullText: String?

    /// STMOB-265 (Molly, code review): признак готовности — статус, а НЕ truthiness
    /// fullText. `status:"completed"` + `fullText:""` — легитимный результат «речь не
    /// распознана», а не «ещё не готово». Именно на этой путанице споткнулся веб-код
    /// (truthy-проверка пустой строки в JS) — поллинг впустую крутился 3 минуты и
    /// затем ложно показывал ошибку вместо «не распознано».
    var isCompleted: Bool {
        status == "completed"
    }
}

// MARK: - Сеть

final class VoiceTranscriptionService {
    /// Клиентский пре-гейт: свои голосовые ограничены 30 минутами, но прислать
    /// могут что угодно. Проверяем ДО скачивания, чтобы не тащить файл зря.
    static let maxUploadBytes: UInt = 25 * 1024 * 1024

    private let baseURL: URL
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: () async -> Void
    private let urlSession: URLSession

    init(baseURL: URL,
         accessTokenProvider: @escaping () throws -> String,
         forceTokenRefresh: @escaping () async -> Void) {
        self.baseURL = baseURL
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh

        // Свои таймауты: у RecordingService 10/30с — заливка голосового на мобильной
        // сети туда не влезет.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        urlSession = URLSession(configuration: configuration)
    }

    /// Заливает аудио и возвращает ответ сервера.
    /// - Note: тело шлём ПОТОКОМ С ДИСКА (`upload(for:fromFile:)`), а не через `Data`:
    ///   голосовое может быть в мегабайтах, и держать его целиком в памяти незачем.
    func transcribe(fileURL: URL, mimeType: String?, roomID: String, eventID: String) async throws -> VoiceTranscribeResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/recording/transcribe-voice"),
                                             resolvingAgainstBaseURL: false) else {
            throw VoiceTranscriptionError.badResponse
        }
        // room_id вида !abc:host обязан percent-энкодиться — через queryItems это
        // делается само, ручная склейка строки ломает запрос.
        components.queryItems = [URLQueryItem(name: "event_id", value: eventID),
                                 URLQueryItem(name: "room_id", value: roomID)]
        guard let url = components.url else { throw VoiceTranscriptionError.badResponse }

        let started = Date()
        let (data, status) = try await upload(url: url, fileURL: fileURL, mimeType: mimeType)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        DiagLog.write("Transcribe", "POST transcribe-voice → \(status) за \(elapsed)с event=\(eventID)")

        guard status == 200 else { throw VoiceTranscriptionError.http(status) }
        guard var response = try? JSONDecoder().decode(VoiceTranscribeResponse.self, from: data) else {
            throw VoiceTranscriptionError.badResponse
        }

        // Контракт синхронный (1-2с) — это резервный путь на случай, если сервер
        // всё же вернул промежуточный статус. Готовность проверяем ИСКЛЮЧИТЕЛЬНО по
        // status, не по содержимому fullText (см. isCompleted).
        if !response.isCompleted, let pollId = response.pollId {
            let deadline = Date().addingTimeInterval(30)
            while !response.isCompleted, Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                response = try await poll(pollID: pollId)
            }
            DiagLog.write("Transcribe", "poll fallback: completed=\(response.isCompleted) event=\(eventID)")
        }
        return response
    }

    /// Резервный путь: ответ на POST обычно уже содержит текст.
    func poll(pollID: String) async throws -> VoiceTranscribeResponse {
        let url = baseURL.appendingPathComponent("/api/recording/transcription/voice/\(pollID)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let decoded = try? JSONDecoder().decode(VoiceTranscribeResponse.self, from: data) else {
            throw VoiceTranscriptionError.http(status)
        }
        return decoded
    }

    /// Один запрос текущим токеном; на 401 — обновление токена и ровно один повтор
    /// (тот же приём, что в RecordingService после STMOB-231: токен ротируется на MAS).
    private func upload(url: URL, fileURL: URL, mimeType: String?) async throws -> (Data, Int) {
        func attempt(refreshFirst: Bool) async throws -> (Data, Int) {
            if refreshFirst { await forceTokenRefresh() }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(mimeType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let (data, status) = try await attempt(refreshFirst: false)
        guard status == 401 else { return (data, status) }
        DiagLog.write("Transcribe", "401 → обновляю токен и повторяю")
        return try await attempt(refreshFirst: true)
    }
}

// MARK: - Кэш

/// Локальный кэш расшифровок, отдельный на каждого пользователя.
///
/// Наличие записи означает «этот пользователь сам запрашивал расшифровку» — по
/// этому признаку текст раскрывается автоматически. Кладём в `UserDefaults`, а не в
/// `Library/Caches`: оттуда iOS чистит по своему усмотрению, и авто-показ у
/// запрашивавшего терялся бы.
final class VoiceTranscriptionCache {
    struct Entry: Codable {
        let text: String
        let isEmpty: Bool
        let date: Date
    }

    private static let maxEntries = 500
    private let key: String
    private let store: UserDefaults
    private var entries: [String: Entry]

    init(userID: String, store: UserDefaults = .standard) {
        key = "ru.implica.stalk.voiceTranscripts.\(userID)"
        self.store = store
        if let data = store.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func entry(for eventID: String) -> Entry? {
        entries[eventID]
    }

    func store(text: String, isEmpty: Bool, for eventID: String) {
        entries[eventID] = Entry(text: text, isEmpty: isEmpty, date: Date())
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { $0.value.date > $1.value.date }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: key)
    }
}

// MARK: - Состояние одного сообщения

/// Состояние расшифровки одного голосового. Живёт в сторе, а не в модели айтема:
/// айтемы таймлайна пересоздаются из SDK на каждый диф, и поле бы затиралось.
@MainActor
final class VoiceTranscriptionState: ObservableObject, Identifiable {
    nonisolated let id: String
    @Published private(set) var phase: VoiceTranscriptionPhase
    @Published var isExpanded: Bool

    init(eventID: String, phase: VoiceTranscriptionPhase = .idle, isExpanded: Bool = false) {
        id = eventID
        self.phase = phase
        self.isExpanded = isExpanded
    }

    func setPhase(_ phase: VoiceTranscriptionPhase) {
        self.phase = phase
    }
}

// MARK: - Стор

/// Реестр состояний + дедупликация запросов + кэш.
@MainActor
final class VoiceTranscriptionStore {
    private let service: VoiceTranscriptionService
    private let cache: VoiceTranscriptionCache
    private var states: [String: VoiceTranscriptionState] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(service: VoiceTranscriptionService, cache: VoiceTranscriptionCache) {
        self.service = service
        self.cache = cache
    }

    /// Состояние для сообщения. Если пользователь уже запрашивал расшифровку —
    /// поднимаем её из кэша сразу раскрытой.
    func state(for eventID: String) -> VoiceTranscriptionState {
        if let existing = states[eventID] { return existing }
        let state: VoiceTranscriptionState
        if let cached = cache.entry(for: eventID) {
            state = VoiceTranscriptionState(eventID: eventID,
                                            phase: cached.isEmpty ? .empty : .loaded(cached.text),
                                            isExpanded: true)
        } else {
            state = VoiceTranscriptionState(eventID: eventID)
        }
        states[eventID] = state
        return state
    }

    /// Запрашивает расшифровку, если её ещё нет.
    ///
    /// `fileHandle` держим живым до конца заливки: файлом владеет Rust-прокси, и при
    /// его освобождении файл стирается с диска — заливка упала бы на середине.
    func requestIfNeeded(eventID: String,
                         roomID: String,
                         fileURL: URL,
                         mimeType: String?,
                         fileHandle: AnyObject?) {
        let state = state(for: eventID)
        switch state.phase {
        case .loaded, .empty, .loading:
            return // готово или уже в работе — второй раз STT не дёргаем
        case .idle, .failed:
            break
        }
        guard inFlight[eventID] == nil else { return }

        state.setPhase(.loading)
        inFlight[eventID] = Task { [weak self] in
            guard let self else { return }
            defer { inFlight[eventID] = nil }
            do {
                // withExtendedLifetime синхронный, поэтому держим handle явной ссылкой
                // до конца заливки: файлом владеет Rust-прокси и стирает его при
                // освобождении — запрос упал бы на середине.
                let keepAlive = fileHandle
                let response = try await service.transcribe(fileURL: fileURL, mimeType: mimeType, roomID: roomID, eventID: eventID)
                _ = keepAlive
                // Готовность — по status (см. isCompleted), не по truthiness fullText:
                // status:"completed" + fullText:"" — легитимное «речь не распознана».
                guard response.isCompleted else {
                    state.setPhase(.failed("timeout"))
                    DiagLog.write("Transcribe", "poll timeout event=\(eventID)")
                    return
                }
                let text = (response.fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                cache.store(text: text, isEmpty: text.isEmpty, for: eventID)
                state.setPhase(text.isEmpty ? .empty : .loaded(text))
                DiagLog.write("Transcribe", "готово event=\(eventID) символов=\(text.count)")
            } catch {
                let message: String
                if case VoiceTranscriptionError.http(let code) = error {
                    message = "HTTP \(code)"
                } else {
                    message = error.localizedDescription
                }
                state.setPhase(.failed(message))
                DiagLog.write("Transcribe", "ошибка event=\(eventID): \(message)")
            }
        }
    }
}
