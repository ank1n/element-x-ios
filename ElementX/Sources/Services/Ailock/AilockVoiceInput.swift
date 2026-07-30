//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
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

    /// Клиентский предел — как у транскрибации голосовых (STMOB-265).
    static let maxDuration: TimeInterval = 5 * 60

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
        stopSession()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ailock-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

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

    private func stopSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Расшифровка

enum AilockVoiceError: Error, LocalizedError {
    case permissionDenied
    case recorderFailed
    case tooShort
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return SL10n.ailockMicDenied
        case .recorderFailed: return SL10n.ailockRecordFailed
        case .tooShort: return SL10n.ailockRecordTooShort
        case .http: return SL10n.ailockTranscribeFailed
        case .empty: return SL10n.ailockTranscribeEmpty
        }
    }
}

/// Расшифровка надиктованного через recording-api.
///
/// STMOB-274. Второй раз STT не изобретаем: маршрут тот же, что у транскрибации
/// голосовых сообщений (STMOB-265 / STALK-666) — сырые байты аудио на
/// `POST /api/recording/transcribe-voice`, внутри сервер зовёт STT движка Айлока.
///
/// Отличие диктовки: у неё нет события Matrix, а `event_id`/`room_id` в контракте
/// обязательны и служат ключом кэша. До ответа Molly шлём явно помеченный
/// синтетический идентификатор — так запись диктовки видно в кэше сервера и её
/// нельзя спутать с расшифровкой настоящего голосового.
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

        guard var components = URLComponents(string: "\(baseURL)/api/recording/transcribe-voice") else {
            throw AilockVoiceError.http(0)
        }
        components.queryItems = [URLQueryItem(name: "event_id", value: "ailock-dictation-\(UUID().uuidString)"),
                                 URLQueryItem(name: "room_id", value: "ailock")]
        guard let url = components.url else { throw AilockVoiceError.http(0) }

        let (data, status) = try await upload(url: url, fileURL: fileURL)
        DiagLog.write("AilockVoice", "POST transcribe-voice -> \(status)")
        guard status == 200 else { throw AilockVoiceError.http(status) }

        guard let decoded = try? JSONDecoder().decode(VoiceTranscribeResponse.self, from: data) else {
            throw AilockVoiceError.http(status)
        }

        // Готовность определяется статусом, а не непустотой текста: `completed` с пустым
        // текстом — легитимное «речь не распознана» (на этом уже спотыкался веб, STMOB-265).
        let text = (decoded.fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AilockVoiceError.empty }
        return text
    }

    private func upload(url: URL, fileURL: URL) async throws -> (Data, Int) {
        func attempt(refreshFirst: Bool) async throws -> (Data, Int) {
            if refreshFirst { await forceTokenRefresh?() }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let (data, status) = try await attempt(refreshFirst: false)
        guard status == 401 else { return (data, status) }
        return try await attempt(refreshFirst: true)
    }
}
