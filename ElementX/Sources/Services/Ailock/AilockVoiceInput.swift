//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import CallKit
import Foundation
import os.log

private let ailockVoiceLog = OSLog(subsystem: "ru.implica.stalk", category: "AilockVoice")

// MARK: - Запись

/// Диктовка для поля ввода Айлока.
///
/// STMOB-274. Пишем **WAV 16 кГц моно PCM**, а не Opus: STT движка Айлока Opus не
/// декодирует (разбор Shelly по STALK-666), а перекодировать на телефоне незачем.
/// 16 кГц моно — то, что распознавателю и нужно: минута занимает ~1.9 МБ.
final class AilockVoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    /// Категория и режим аудио-сессии до начала записи — возвращаем их как было.
    /// Глухая деактивация ломала бы чужой сценарий, если он держит сессию.
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?
    private var previousOptions: AVAudioSession.CategoryOptions?
    private var didActivateSession = false

    /// Клиентский предел записи.
    ///
    /// Серверные потолки (Molly, STMOB-274) — 25 МиБ и 300 с, причём 413 наступает
    /// именно на них. Режем сильно раньше: диктовка в поле ввода длиннее двух минут
    /// не имеет смысла, а до отказа доводить пользователя незачем.
    /// Две минуты WAV PCM 16 кГц mono ≈ 3.8 МБ — с большим запасом по обеим границам.
    static let maxDuration: TimeInterval = 2 * 60

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var duration: TimeInterval {
        recorder?.currentTime ?? 0
    }

    /// Разрешение на микрофон. Ключ `NSMicrophoneUsageDescription` в приложении уже есть.
    static func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        // Во время звонка микрофон и маршрутизацию не забираем: переключение категории
        // посреди разговора рвёт звук у обеих сторон.
        guard !Self.isCallInProgress else { throw AilockVoiceError.callInProgress }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ailock-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")

        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions
        // Конфигурация сессии — минимально возможная, и это выстрадано двумя сборками.
        // 310: `.record` + `.duckOthers` → OSStatus -50 (опция допустима только для
        // playAndRecord / playback / multiRoute).
        // 311: опцию убрала, но осталась `.spokenAudio` — этот режим предназначен для
        // ВОСПРОИЗВЕДЕНИЯ речи и с категорией записи тоже даёт -50 (лог 211).
        // Правило на будущее: для диктовки — только `.record` + `.default`, любые
        // «улучшения» режима и опций проверять на устройстве, а не по смыслу названия.
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try session.setActive(true)
        didActivateSession = true

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        DiagLog.write("AilockVoice", "сессия: category=\(session.category.rawValue) mode=\(session.mode.rawValue)")

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw AilockVoiceError.recorderFailed }

        self.recorder = recorder
        fileURL = url
        os_log(.default, log: ailockVoiceLog, "запись начата")
    }

    /// Останавливает запись и отдаёт файл. `nil` — если писать было нечего.
    func finish() -> URL? {
        guard let recorder, let fileURL else {
            stopSession()
            return nil
        }
        let seconds = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        stopSession()

        // Меньше секунды — это случайный тап, а не речь.
        guard seconds >= 1 else {
            try? FileManager.default.removeItem(at: fileURL)
            self.fileURL = nil
            return nil
        }
        os_log(.default, log: ailockVoiceLog, "запись завершена, %{public}.1f с", seconds)
        self.fileURL = nil
        return fileURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        stopSession()
    }

    /// Текущий уровень сигнала 0…1 — для индикатора.
    func level() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        // -50 дБ и тише считаем тишиной.
        return max(0, min(1, (decibels + 50) / 50))
    }

    /// Идёт ли системный звонок (в том числе наш через CallKit).
    /// Наблюдатель CallKit держим живым: созданный на лету и тут же отпущенный
    /// объект может не успеть наполнить список звонков — Apple прямо требует его удерживать.
    private static let callObserver = CXCallObserver()

    private static var isCallInProgress: Bool {
        callObserver.calls.contains { !$0.hasEnded }
    }

    private func stopSession() {
        guard didActivateSession else { return }
        didActivateSession = false

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        // Возвращаем сессию в исходное состояние — следующий сценарий (звонок,
        // голосовое сообщение, плеер) не должен получить наши настройки записи.
        if let previousCategory {
            try? session.setCategory(previousCategory, mode: previousMode ?? .default, options: previousOptions ?? [])
        }
        previousCategory = nil
        previousMode = nil
        previousOptions = nil
    }
}

// MARK: - Расшифровка

enum AilockVoiceError: Error, LocalizedError {
    case permissionDenied
    case recorderFailed
    case callInProgress
    case tooShort
    case tooLarge
    case rateLimited(retryAfter: Int?)
    case unavailable
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return SL10n.ailockMicDenied
        case .recorderFailed: return SL10n.ailockRecordFailed
        case .callInProgress: return SL10n.ailockMicBusy
        case .tooShort: return SL10n.ailockRecordTooShort
        case .tooLarge: return SL10n.ailockRecordTooLong
        case .rateLimited(let retryAfter):
            guard let retryAfter, retryAfter > 0 else { return SL10n.ailockRateLimited }
            return "\(SL10n.ailockRateLimited) (\(retryAfter) с)"
        case .unavailable: return SL10n.ailockTranscribeUnavailable
        case .http: return SL10n.ailockTranscribeFailed
        case .empty: return SL10n.ailockTranscribeEmpty
        }
    }
}

/// Единый конверт ошибок диктовки (Molly, STMOB-274): разнобой upstream
/// нормализуется на сервере, наружу приходит всегда одна форма.
private struct AilockDictateError: Decodable {
    let error: String?
    let message: String?
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case error, message
        case retryAfterSeconds = "retry_after_seconds"
    }
}

private struct AilockDictateResponse: Decodable {
    let text: String?
}

/// Расшифровка надиктованного через recording-api.
///
/// STMOB-274. Контракт Molly от 30.07 (отдельный маршрут именно под диктовку —
/// у неё нет события Matrix, поэтому авторизуется ПОЛЬЗОВАТЕЛЬ, а не доступ к
/// чужому медиа, в отличие от транскрибации голосовых по STALK-666):
/// ```
/// POST {homeserver}/api/recording/stt/dictate
/// Authorization: Bearer <matrix access token>
/// multipart/form-data, единственное поле `audio` — WAV PCM mono 16 кГц
/// → 200 {"text": "..."}
/// → 401 / 413 / 429 / 502 / 503 в конверте {error, message, retry_after_seconds}
/// ```
/// Ключ тенанта STT остаётся на сервере и в клиент не попадает.
/// Серверные потолки — 25 МиБ и 300 с; мы режем запись раньше, чтобы до 413 не доводить.
final class AilockVoiceTranscriber {
    private let baseURL: String
    private let accessTokenProvider: () throws -> String
    private let forceTokenRefresh: (() async -> Void)?
    private let urlSession: URLSession

    init(homeserver: String,
         accessTokenProvider: @escaping () throws -> String,
         forceTokenRefresh: (() async -> Void)? = nil) {
        baseURL = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        urlSession = URLSession(configuration: configuration)
    }

    func transcribe(fileURL: URL) async throws -> String {
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard let url = URL(string: "\(baseURL)/api/recording/stt/dictate") else {
            throw AilockVoiceError.http(0)
        }

        let audio = try Data(contentsOf: fileURL)
        let (data, status) = try await upload(url: url, audio: audio)
        DiagLog.write("AilockVoice", "POST stt/dictate -> \(status), \(audio.count) байт")

        guard status == 200 else { throw Self.error(status: status, body: data) }

        guard let decoded = try? JSONDecoder().decode(AilockDictateResponse.self, from: data) else {
            throw AilockVoiceError.http(status)
        }
        let text = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Пустой текст при 200 — это «речь не распознана», а не сбой.
        guard !text.isEmpty else { throw AilockVoiceError.empty }
        return text
    }

    /// Разбор нормализованного конверта ошибок.
    private static func error(status: Int, body: Data) -> AilockVoiceError {
        let decoded = try? JSONDecoder().decode(AilockDictateError.self, from: body)

        switch decoded?.error {
        case "payload_too_large": return .tooLarge
        case "rate_limited": return .rateLimited(retryAfter: decoded?.retryAfterSeconds)
        case "stt_capacity", "stt_unavailable": return .unavailable
        case "invalid_audio": return .http(status)
        default: break
        }

        switch status {
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: decoded?.retryAfterSeconds)
        case 502, 503: return .unavailable
        default: return .http(status)
        }
    }

    /// Тело запроса — **сырой WAV**, канонический v1-контракт маршрута.
    ///
    /// Проверено живой пробой прода: raw + `Content-Type: audio/wav` → 200 с текстом,
    /// multipart (и с полем `audio`, и с `file`) → 400 `invalid_audio`.
    /// Автоматического фолбэка на multipart сознательно НЕТ (вердикт Shelly): повтор
    /// после любого 400 маскировал бы по-настоящему битую запись и удваивал нагрузку.
    /// Переход на другой формат — только версионированно, не тихой сменой поведения.
    private func upload(url: URL, audio: Data) async throws -> (Data, Int) {
        func attempt(refreshFirst: Bool) async throws -> (Data, Int) {
            if refreshFirst { await forceTokenRefresh?() }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.upload(for: request, from: audio)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let (data, status) = try await attempt(refreshFirst: false)
        guard status == 401 else { return (data, status) }
        return try await attempt(refreshFirst: true)
    }
}
