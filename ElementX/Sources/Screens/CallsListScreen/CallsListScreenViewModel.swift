//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias CallsListScreenViewModelType = StateStoreViewModel<CallsListScreenViewState, CallsListScreenViewAction>

protocol CallsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> { get }
    var context: CallsListScreenViewModelType.Context { get }
}

class CallsListScreenViewModel: CallsListScreenViewModelType, CallsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let localCallHistoryService: LocalCallHistoryServiceProtocol
    private let callHistoryService: CallHistoryServiceProtocol?
    private let actionsSubject: PassthroughSubject<CallsListScreenViewModelAction, Never> = .init()
    private var callsCancellables: Set<AnyCancellable> = []

    private let audioPlayer: AudioPlayerProtocol
    private let fileManager = FileManager.default

    /// Кэш записей с сервера для быстрого доступа по roomID
    private var recordingsCache: [String: CallHistoryAPIItem] = [:]

    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol,
         localCallHistoryService: LocalCallHistoryServiceProtocol? = nil,
         callHistoryService: CallHistoryServiceProtocol? = nil,
         audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.userSession = userSession
        self.localCallHistoryService = localCallHistoryService ?? ServiceLocator.shared.localCallHistoryService
        self.callHistoryService = callHistoryService
        self.audioPlayer = audioPlayer

        var initialState = CallsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
        setupAudioPlayerObserver()
        setupLocalHistorySubscription()
        loadRecordingsFromServer()
    }

    override func process(viewAction: CallsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectCall(let call):
            actionsSubject.send(.startCall(userId: call.contactId))
        case .startNewCall:
            break
        case .playRecording(let call):
            handlePlayRecording(call)
        case .refresh:
            loadRecordingsFromServer()
        }
    }

    // MARK: - Local History Subscription

    private func setupLocalHistorySubscription() {
        localCallHistoryService.callHistoryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] localCalls in
                self?.updateCallHistoryFromLocal(localCalls)
            }
            .store(in: &callsCancellables)
    }

    /// Кэш записей с сервера (egressId -> recording info)
    private var serverRecordings: [CallHistoryItem] = []

    private func updateCallHistoryFromLocal(_ localCalls: [LocalCallHistoryItem]) {
        MXLog.info("📞 Updating call history from local: \(localCalls.count) calls, server recordings: \(serverRecordings.count)")

        // Конвертируем локальные записи в CallHistoryItem
        var calls = localCalls.map { local -> CallHistoryItem in
            // Определяем тип звонка
            let callType: CallHistoryItem.CallType
            switch local.direction {
            case .incoming:
                callType = .incoming
            case .outgoing:
                callType = .outgoing
            }

            // Ищем запись для этого звонка по egressId или по времени
            var recordingURL: URL?
            if let egressId = local.recordingEgressId {
                // Проверяем статус записи на сервере - URL будет только для завершенных записей
                if let serverRecording = serverRecordings.first(where: { $0.id == egressId }),
                   serverRecording.recordingURL != nil {
                    recordingURL = serverRecording.recordingURL
                }
                // Если запись не найдена или не завершена - не показываем кнопку воспроизведения
            } else {
                // Попробуем найти запись по roomID и близкому времени
                if let matchingRecording = findMatchingRecording(for: local) {
                    recordingURL = matchingRecording.recordingURL
                }
            }

            return CallHistoryItem(
                id: local.id,
                contactName: local.displayName,
                contactId: local.roomID,
                callType: callType,
                timestamp: local.startedAt,
                duration: local.duration,
                isMissed: local.isMissed,
                recordingURL: recordingURL
            )
        }

        // Добавляем записи с сервера которые не имеют соответствия в локальной истории
        for recording in serverRecordings {
            let hasLocalMatch = localCalls.contains { local in
                isRecordingMatchingCall(recording, localCall: local)
            }
            if !hasLocalMatch {
                calls.append(recording)
            }
        }

        // Сортируем по времени (новые сверху)
        calls.sort { $0.timestamp > $1.timestamp }

        state.callHistory = calls
        state.isLoading = false
    }

    /// Находит запись с сервера, соответствующую локальному звонку
    private func findMatchingRecording(for localCall: LocalCallHistoryItem) -> CallHistoryItem? {
        serverRecordings.first { recording in
            isRecordingMatchingCall(recording, localCall: localCall)
        }
    }

    /// Проверяет соответствует ли запись локальному звонку (по roomID и близости времени)
    private func isRecordingMatchingCall(_ recording: CallHistoryItem, localCall: LocalCallHistoryItem) -> Bool {
        // Проверяем roomID (contactId в recording может быть matrixRoomId или encoded roomName)
        let roomMatches = recording.contactId == localCall.roomID ||
                          recording.contactId.contains(localCall.roomID)

        // Проверяем близость по времени (в пределах 5 минут)
        let timeDiff = abs(recording.timestamp.timeIntervalSince(localCall.startedAt))
        let timeMatches = timeDiff < 300 // 5 минут

        return roomMatches && timeMatches
    }

    // MARK: - Server Recordings

    private func loadRecordingsFromServer() {
        guard let callHistoryService else {
            MXLog.info("📞 No call history service configured, skipping server fetch")
            return
        }

        MXLog.info("📞 Fetching recordings from server...")

        let currentUserID = userSession.clientProxy.userID
        Task {
            do {
                let recordings = try await callHistoryService.fetchRecordings(currentUserID: currentUserID)
                MXLog.info("📞 Loaded \(recordings.count) recordings from server")

                await MainActor.run {
                    // Сохраняем записи в кэш
                    serverRecordings = recordings

                    // Обновляем UI объединяя с локальной историей
                    let localCalls = localCallHistoryService.getAllCalls()
                    updateCallHistoryFromLocal(localCalls)
                }
            } catch {
                MXLog.error("📞 Failed to fetch recordings: \(error)")
                await MainActor.run {
                    state.isLoading = false
                }
            }
        }
    }

    // MARK: - Audio Playback

    private var progressTimer: Timer?

    private func setupAudioPlayerObserver() {
        audioPlayer.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .didStartLoading:
                    state.playbackState = .loading
                case .didFinishLoading:
                    break
                case .didStartPlaying:
                    state.playbackState = .playing
                    startProgressTimer()
                case .didPausePlaying:
                    state.playbackState = .paused
                    stopProgressTimer()
                case .didStopPlaying, .didFinishPlaying:
                    state.playbackState = .stopped
                    state.playingCallId = nil
                    state.playbackProgress = 0
                    state.playbackDuration = 0
                    state.playbackCurrentTime = 0
                    stopProgressTimer()
                case .didFailWithError(let error):
                    MXLog.error("🔴 Audio playback failed: \(error)")
                    state.playbackState = .error
                    state.playingCallId = nil
                    stopProgressTimer()
                    state.bindings.alertInfo = AlertInfo(id: UUID(), title: "Ошибка воспроизведения", message: "\(error)")
                }
            }
            .store(in: &callsCancellables)
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let duration = audioPlayer.duration
            let currentTime = audioPlayer.currentTime

            if duration > 0 {
                state.playbackProgress = currentTime / duration
                state.playbackDuration = duration
                state.playbackCurrentTime = currentTime
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private var currentDownloadTask: Task<Void, Never>?

    private func handlePlayRecording(_ call: CallHistoryItem) {
        guard let recordingURL = call.recordingURL else {
            MXLog.error("No recording URL for call \(call.id)")
            return
        }

        // If already playing this call, toggle stop
        if state.playingCallId == call.id {
            stopPlayback()
            return
        }

        // Stop any current playback and cancel download
        stopPlayback()

        state.playingCallId = call.id
        state.playbackState = .loading

        // Сначала пробуем воспроизвести напрямую с URL (стриминг)
        // Если не работает — скачиваем файл
        MXLog.info("Playing recording directly from URL: \(recordingURL)")
        audioPlayer.load(sourceURL: recordingURL, playbackURL: recordingURL, autoplay: true)
    }

    private func stopPlayback() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        audioPlayer.stop()
        audioPlayer.reset()
        state.playingCallId = nil
        state.playbackState = .stopped
        state.playbackProgress = 0
    }

    private func downloadRecording(from url: URL, callId: String) async throws -> URL {
        let cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let localURL = cacheDirectory.appendingPathComponent("\(callId).mp4")

        // Check if cached file exists and is valid (> 500KB for short recordings)
        if fileManager.fileExists(atPath: localURL.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: localURL.path)
            let fileSize = attrs?[.size] as? Int ?? 0
            if fileSize > 500_000 {
                MXLog.info("Using cached file: \(localURL.path), size: \(fileSize)")
                return localURL
            } else {
                // Remove corrupted/incomplete file
                try? fileManager.removeItem(at: localURL)
                MXLog.info("Removed corrupted cache file, size was: \(fileSize)")
            }
        }

        // Create URLSession with longer timeout for large files
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 120.0
        let session = URLSession(configuration: config)

        // Retry up to 3 times
        var lastError: Error?
        for attempt in 1...3 {
            do {
                MXLog.info("Downloading recording from: \(url), attempt \(attempt)")
                let (tempURL, response) = try await session.download(from: url)

                // Check response
                if let httpResponse = response as? HTTPURLResponse {
                    MXLog.info("Download response: \(httpResponse.statusCode), content-length: \(httpResponse.expectedContentLength)")

                    guard httpResponse.statusCode == 200 else {
                        throw CallHistoryError.serverError("HTTP \(httpResponse.statusCode)")
                    }
                }

                // Check downloaded file size
                let tempAttrs = try? fileManager.attributesOfItem(atPath: tempURL.path)
                let downloadedSize = tempAttrs?[.size] as? Int ?? 0
                MXLog.info("Downloaded file size: \(downloadedSize)")

                // Минимум 100KB для коротких записей
                if downloadedSize < 100_000 {
                    throw CallHistoryError.serverError("File too small: \(downloadedSize) bytes")
                }

                // Move to cache
                if fileManager.fileExists(atPath: localURL.path) {
                    try? fileManager.removeItem(at: localURL)
                }
                try fileManager.moveItem(at: tempURL, to: localURL)

                MXLog.info("Saved to: \(localURL.path)")
                return localURL

            } catch {
                MXLog.error("Download attempt \(attempt) failed: \(error)")
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                }
            }
        }

        throw lastError ?? CallHistoryError.serverError("Download failed after 3 attempts")
    }

    // MARK: - Private

    private func setupSubscriptions() {
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &callsCancellables)

        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &callsCancellables)

        userSession.sessionSecurityStatePublisher
            .map { $0.verificationState != .verified || $0.recoveryState != .enabled }
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.requiresExtraAccountSetup, on: self)
            .store(in: &callsCancellables)
    }
}

// MARK: - Call History Service

protocol CallHistoryServiceProtocol: AnyObject {
    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem]
}

class CallHistoryService: NSObject, CallHistoryServiceProtocol, URLSessionDelegate {
    private let baseURL: URL
    private var urlSession: URLSession
    private let allowInsecureConnection: Bool

    init(baseURL: URL, urlSession: URLSession? = nil, allowInsecureConnection: Bool = false) {
        self.baseURL = baseURL
        self.allowInsecureConnection = allowInsecureConnection

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        configuration.timeoutIntervalForResource = 30.0

        // Initialize with temporary session
        self.urlSession = URLSession(configuration: configuration)

        super.init()

        // Now reinitialize with proper configuration
        if let urlSession {
            self.urlSession = urlSession
        } else if allowInsecureConnection {
            // If allowing insecure connections, use custom delegate
            self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowInsecureConnection && challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        let url = baseURL.appendingPathComponent("api/recording/list")
        print("📞 FETCH: URL = \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0

        // Retry up to 3 times
        var lastError: Error?
        for attempt in 1...3 {
            do {
                print("📞 FETCH: Attempt \(attempt)...")
                let (data, response) = try await urlSession.data(for: request)
                print("📞 FETCH: Got response, data size: \(data.count)")
                return try processResponse(data: data, response: response, currentUserID: currentUserID)
            } catch {
                print("📞 FETCH: Attempt \(attempt) failed: \(error)")
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
        }
        throw lastError ?? CallHistoryError.invalidResponse
    }

    private func processResponse(data: Data, response: URLResponse, currentUserID: String?) throws -> [CallHistoryItem] {

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CallHistoryError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw CallHistoryError.serverError("HTTP \(httpResponse.statusCode)")
        }

        let apiResponse = try JSONDecoder().decode(CallHistoryResponse.self, from: data)

        guard apiResponse.success, let recordings = apiResponse.recordings else {
            let errorMessage = apiResponse.error ?? "Failed to fetch recordings"
            throw CallHistoryError.serverError(errorMessage)
        }

        return recordings.compactMap { $0.toCallHistoryItem(currentUserID: currentUserID) }
            .sorted { $0.timestamp > $1.timestamp }
    }
}

enum CallHistoryError: LocalizedError {
    case networkError(Error)
    case serverError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}
