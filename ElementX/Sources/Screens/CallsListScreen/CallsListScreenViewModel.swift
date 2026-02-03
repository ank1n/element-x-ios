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
    private let callHistoryService: CallHistoryServiceProtocol
    private let actionsSubject: PassthroughSubject<CallsListScreenViewModelAction, Never> = .init()
    private var callsCancellables: Set<AnyCancellable> = []

    private let audioPlayer: AudioPlayerProtocol

    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol,
         callHistoryService: CallHistoryServiceProtocol,
         audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.userSession = userSession
        self.callHistoryService = callHistoryService
        self.audioPlayer = audioPlayer

        var initialState = CallsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
        setupAudioPlayerObserver()
        loadCallHistory()
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
        }
    }

    // MARK: - Audio Playback

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
                case .didPausePlaying:
                    state.playbackState = .paused
                case .didStopPlaying, .didFinishPlaying:
                    state.playbackState = .stopped
                    state.playingCallId = nil
                    state.playbackProgress = 0
                case .didFailWithError:
                    state.playbackState = .error
                    state.playingCallId = nil
                }
            }
            .store(in: &callsCancellables)
    }

    private func handlePlayRecording(_ call: CallHistoryItem) {
        guard let recordingURL = call.recordingURL else { return }

        // If already playing this call, toggle pause/play
        if state.playingCallId == call.id {
            if state.playbackState == .playing {
                audioPlayer.pause()
            } else {
                audioPlayer.play()
            }
        } else {
            // Stop any current playback and start new one
            audioPlayer.stop()
            state.playingCallId = call.id
            audioPlayer.load(sourceURL: recordingURL, playbackURL: recordingURL, autoplay: true)
        }
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

    private func loadCallHistory() {
        state.isLoading = true

        Task {
            do {
                let recordings = try await callHistoryService.fetchRecordings()
                await MainActor.run {
                    state.callHistory = recordings
                    state.isLoading = false
                }
            } catch {
                MXLog.error("Failed to load call history: \(error)")
                await MainActor.run {
                    state.isLoading = false
                }
            }
        }
    }
}

// MARK: - Call History Service

protocol CallHistoryServiceProtocol: AnyObject {
    func fetchRecordings() async throws -> [CallHistoryItem]
}

class CallHistoryService: CallHistoryServiceProtocol {
    private let baseURL: URL
    private let urlSession: URLSession

    init(baseURL: URL, urlSession: URLSession? = nil) {
        self.baseURL = baseURL

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 10.0
            configuration.timeoutIntervalForResource = 30.0
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    func fetchRecordings() async throws -> [CallHistoryItem] {
        let url = baseURL.appendingPathComponent("/recording-api/list")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        let (data, response) = try await urlSession.data(for: request)

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

        return recordings.compactMap { $0.toCallHistoryItem() }
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
