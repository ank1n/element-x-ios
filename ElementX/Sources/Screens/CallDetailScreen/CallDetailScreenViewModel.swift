//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias CallDetailScreenViewModelType = StateStoreViewModel<CallDetailScreenViewState, CallDetailScreenViewAction>

protocol CallDetailScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<CallDetailScreenViewModelAction, Never> { get }
    var context: CallDetailScreenViewModelType.Context { get }
}

class CallDetailScreenViewModel: CallDetailScreenViewModelType, CallDetailScreenViewModelProtocol {
    private let callHistoryService: CallHistoryServiceProtocol
    private let audioPlayer: AudioPlayerProtocol
    private let actionsSubject: PassthroughSubject<CallDetailScreenViewModelAction, Never> = .init()
    private var detailCancellables: Set<AnyCancellable> = []
    private var pollingCancellable: AnyCancellable?
    private var currentDownloadTask: Task<Void, Never>?

    var actionsPublisher: AnyPublisher<CallDetailScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(call: CallHistoryItem,
         callHistoryService: CallHistoryServiceProtocol,
         audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.callHistoryService = callHistoryService
        self.audioPlayer = audioPlayer

        let initialState = CallDetailScreenViewState(call: call)
        super.init(initialViewState: initialState)

        setupAudioPlayerSubscription()

        if call.hasRecording {
            Task { await loadTranscription() }
        } else {
            state.isTranscriptionLoading = false
        }
    }

    override func process(viewAction: CallDetailScreenViewAction) {
        switch viewAction {
        case .dismiss:
            stopPlayback()
            actionsSubject.send(.dismiss)
        case .selectTab(let tab):
            state.selectedTab = tab
        case .seekToTimestamp(let seconds):
            handleSeekToTimestamp(seconds)
        case .playPause:
            handlePlayPause()
        case .seekPlayback(let progress):
            Task { await audioPlayer.seek(to: progress) }
        case .retryTranscription:
            Task { await retryTranscription() }
        case .callBack:
            actionsSubject.send(.callBack(roomID: state.call.contactId))
        }
    }

    deinit {
        pollingCancellable?.cancel()
        currentDownloadTask?.cancel()
    }

    // MARK: - Transcription

    private func loadTranscription() async {
        guard let egressId = egressId else {
            await MainActor.run { state.isTranscriptionLoading = false }
            return
        }

        do {
            let data = try await callHistoryService.fetchTranscription(egressId: egressId)
            await MainActor.run {
                state.transcriptionData = data
                state.isTranscriptionLoading = false

                // Select first available tab
                if let firstTab = state.availableTabs.first {
                    state.selectedTab = firstTab
                }

                if data.status?.isInProgress == true {
                    startPolling()
                }
            }
        } catch {
            MXLog.error("CallDetail: Failed to fetch transcription: \(error)")
            await MainActor.run { state.isTranscriptionLoading = false }
        }
    }

    private func retryTranscription() async {
        guard let egressId else { return }

        do {
            let data = try await callHistoryService.retryTranscription(egressId: egressId)
            await MainActor.run {
                state.transcriptionData = data
                if data.status?.isInProgress == true {
                    startPolling()
                }
            }
        } catch {
            MXLog.error("CallDetail: Failed to retry transcription: \(error)")
        }
    }

    private func startPolling() {
        pollingCancellable?.cancel()
        pollingCancellable = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    guard let self, let egressId = self.egressId else { return }
                    do {
                        let data = try await self.callHistoryService.fetchTranscription(egressId: egressId)
                        await MainActor.run {
                            self.state.transcriptionData = data
                            if let firstTab = self.state.availableTabs.first, !self.state.availableTabs.contains(self.state.selectedTab) {
                                self.state.selectedTab = firstTab
                            }
                            if data.status?.isInProgress != true {
                                self.pollingCancellable?.cancel()
                                self.pollingCancellable = nil
                            }
                        }
                    } catch {
                        MXLog.error("CallDetail: Polling error: \(error)")
                    }
                }
            }
    }

    // MARK: - Playback

    private func setupAudioPlayerSubscription() {
        audioPlayer.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .didStartLoading:
                    state.playbackState = .loading
                case .didFinishLoading:
                    state.playbackDuration = audioPlayer.duration
                case .didStartPlaying:
                    state.playbackState = .playing
                    startPlaybackTimer()
                case .didPausePlaying:
                    state.playbackState = .paused
                case .didStopPlaying, .didFinishPlaying:
                    state.playbackState = .stopped
                    state.playbackProgress = 0
                    state.playbackCurrentTime = 0
                case .didFailWithError:
                    state.playbackState = .error
                }
            }
            .store(in: &detailCancellables)
    }

    private func handlePlayPause() {
        switch audioPlayer.state {
        case .playing:
            audioPlayer.pause()
        case .paused:
            audioPlayer.play()
        case .stopped:
            loadAndPlayRecording()
        default:
            break
        }
    }

    private func loadAndPlayRecording() {
        guard let recordingURL = state.call.recordingURL else { return }
        state.isDownloading = true

        currentDownloadTask?.cancel()
        currentDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await downloadRecording(from: recordingURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.state.isDownloading = false
                    self.audioPlayer.load(sourceURL: localURL, playbackURL: recordingURL, autoplay: true)
                }
            } catch {
                MXLog.error("CallDetail: Download failed: \(error)")
                await MainActor.run {
                    self.state.isDownloading = false
                    self.state.playbackState = .error
                }
            }
        }
    }

    private func downloadRecording(from url: URL) async throws -> URL {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let localURL = cacheDir.appendingPathComponent("\(state.call.id).mp4")

        // Use cached file if exists and not too small
        if FileManager.default.fileExists(atPath: localURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 {
            return localURL
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        for attempt in 1...3 {
            do {
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("close", forHTTPHeaderField: "Connection")

                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1024 else {
                    if attempt < 3 { try? await Task.sleep(for: .seconds(2)); continue }
                    throw CallHistoryError.invalidResponse
                }

                try data.write(to: localURL)
                return localURL
            } catch {
                if attempt == 3 { throw error }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw CallHistoryError.invalidResponse
    }

    private func handleSeekToTimestamp(_ seconds: TimeInterval) {
        // Start playback if not already playing
        if audioPlayer.state == .stopped {
            loadAndPlayRecording()
            // Seek after load via a delayed task
            Task {
                // Wait for loading
                try? await Task.sleep(for: .seconds(1))
                let progress = state.playbackDuration > 0 ? seconds / state.playbackDuration : 0
                await audioPlayer.seek(to: min(1.0, max(0, progress)))
            }
        } else {
            let progress = state.playbackDuration > 0 ? seconds / state.playbackDuration : 0
            Task { await audioPlayer.seek(to: min(1.0, max(0, progress))) }
        }
    }

    private func startPlaybackTimer() {
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, audioPlayer.state == .playing else { return }
                state.playbackCurrentTime = audioPlayer.currentTime
                state.playbackDuration = audioPlayer.duration
                state.playbackProgress = audioPlayer.duration > 0 ? audioPlayer.currentTime / audioPlayer.duration : 0
            }
            .store(in: &detailCancellables)
    }

    private func stopPlayback() {
        currentDownloadTask?.cancel()
        audioPlayer.stop()
    }

    // MARK: - Helpers

    private var egressId: String? {
        // Build 112: было `id.hasPrefix("EG_")` — устаревшее предположение.
        // Реальный формат egress_id в recording-api PG: `session_<timestamp_ms>`
        // (см. transcriptions.egress_id). Старая проверка всегда давала nil →
        // loadTranscription делал early return → пустой UI на CallDetailScreen.
        // Web работает потому что не имеет такого filter'а.
        let id = state.call.id
        return id.isEmpty ? nil : id
    }
}
