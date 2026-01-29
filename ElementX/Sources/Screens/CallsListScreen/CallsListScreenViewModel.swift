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
    private let actionsSubject: PassthroughSubject<CallsListScreenViewModelAction, Never> = .init()
    private var callsCancellables: Set<AnyCancellable> = []

    private let audioPlayer: AudioPlayerProtocol

    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol, audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.userSession = userSession
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
        // Demo call history with some recordings
        state.callHistory = [
            CallHistoryItem(
                id: "1",
                contactName: "Алексей Петров",
                contactId: "@alexey:server.com",
                callType: .incoming,
                timestamp: Date().addingTimeInterval(-3600),
                duration: 125,
                isMissed: false,
                recordingURL: URL(string: "https://api.market.implica.ru/recordings/call-1.mp3")
            ),
            CallHistoryItem(
                id: "2",
                contactName: "Мария Иванова",
                contactId: "@maria:server.com",
                callType: .outgoing,
                timestamp: Date().addingTimeInterval(-7200),
                duration: 340,
                isMissed: false,
                recordingURL: URL(string: "https://api.market.implica.ru/recordings/call-2.mp3")
            ),
            CallHistoryItem(
                id: "3",
                contactName: "Дмитрий Сидоров",
                contactId: "@dmitry:server.com",
                callType: .video,
                timestamp: Date().addingTimeInterval(-86400),
                duration: nil,
                isMissed: true,
                recordingURL: nil
            ),
            CallHistoryItem(
                id: "4",
                contactName: "Елена Козлова",
                contactId: "@elena:server.com",
                callType: .incoming,
                timestamp: Date().addingTimeInterval(-172800),
                duration: 45,
                isMissed: false,
                recordingURL: nil
            ),
            CallHistoryItem(
                id: "5",
                contactName: "Сергей Новиков",
                contactId: "@sergey:server.com",
                callType: .outgoing,
                timestamp: Date().addingTimeInterval(-259200),
                duration: nil,
                isMissed: true,
                recordingURL: nil
            )
        ]
        state.isLoading = false
    }
}
