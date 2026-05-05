//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
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

    private let clientProxy: ClientProxyProtocol?

    init(call: CallHistoryItem,
         callHistoryService: CallHistoryServiceProtocol,
         mediaProvider: MediaProviderProtocol?,
         clientProxy: ClientProxyProtocol? = nil,
         audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.callHistoryService = callHistoryService
        self.clientProxy = clientProxy
        self.audioPlayer = audioPlayer

        let initialState = CallDetailScreenViewState(call: call)
        // Build 114: mediaProvider обязателен — LoadableAvatarImage падает с
        // assertionFailure в DEBUG если context.mediaProvider == nil.
        super.init(initialViewState: initialState, mediaProvider: mediaProvider)

        setupAudioPlayerSubscription()

        // Build 115 diag: понять почему транскрипция не показывается на устройстве.
        DiagLog.write("CallDetail", "init: callId=\(call.id) hasRecording=\(call.hasRecording) recordingURL=\(call.recordingURL?.absoluteString ?? "nil")")
        if call.hasRecording {
            Task { await loadTranscription() }
            // Build 116 fix: предзагрузить аудиофайл (без autoplay) сразу при открытии
            // экрана — иначе AudioPlayer не знает duration → UI показывает 0:00 / 0:00
            // пока пользователь не тапнет Play. Длительность подтянется как только
            // AVPlayerItem распарсит m4a метаданные.
            preloadRecording()
        } else {
            DiagLog.write("CallDetail", "  hasRecording=false → loadTranscription SKIP")
            state.isTranscriptionLoading = false
        }

        // Build 126: подтянуть room avatar (для шапки) + members (для transcript
        // speaker avatars). Только если у call есть matrix room ID.
        if call.contactId.hasPrefix("!"), clientProxy != nil {
            Task { await loadRoomMetadata(roomID: call.contactId) }
        }
    }

    private func loadRoomMetadata(roomID: String) async {
        guard let clientProxy else { return }
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            DiagLog.write("CallDetail", "  loadRoomMetadata FAIL — room not joined: \(roomID)")
            return
        }

        // Header avatar — group room avatar URL (extract из RoomAvatar enum).
        let info = roomProxy.infoPublisher.value
        let headerAvatarURL: URL? = {
            switch info.avatar {
            case .room(_, _, let url): return url
            case .space(_, _, let url): return url
            case .heroes(let users): return users.first?.avatarURL
            case .tombstoned: return nil
            }
        }()
        DiagLog.write("CallDetail", "  loadRoomMetadata header=\(headerAvatarURL?.absoluteString ?? "nil")")
        await MainActor.run {
            if let headerAvatarURL {
                state.call.avatarURL = headerAvatarURL
            }
        }

        // Build 126b: members могут быть не загружены при init — подписываемся на
        // publisher и обновляем speakerAvatars при каждом emit.
        await roomProxy.updateMembers()
        roomProxy.membersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] members in
                guard let self else { return }
                var map: [String: URL] = [:]
                for member in members {
                    guard let url = member.avatarURL,
                          let display = member.displayName,
                          !display.isEmpty else { continue }
                    map[display] = url
                }
                if !map.isEmpty {
                    DiagLog.write("CallDetail", "  members publisher → speakers=\(map.count)")
                    self.state.speakerAvatars = map
                }
            }
            .store(in: &detailCancellables)
    }

    private func preloadRecording() {
        guard let recordingURL = state.call.recordingURL else { return }
        DiagLog.write("CallDetail", "  preloadRecording START")
        Task { [weak self] in
            guard let self else { return }
            do {
                // Build 119: только download + чтение duration через AVURLAsset.
                // НЕ вызываем audioPlayer.load — иначе player ставит .loading,
                // UI показывает спиннер до тапа Play. Player загружается только
                // в handlePlayPause / handleSeekToTimestamp.
                let localURL = try await downloadRecording(from: recordingURL)
                let asset = AVURLAsset(url: localURL)
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                await MainActor.run {
                    if seconds.isFinite, seconds > 0 {
                        self.state.playbackDuration = seconds
                    }
                }
                DiagLog.write("CallDetail", "  preload duration=\(seconds)s")
            } catch {
                DiagLog.write("CallDetail", "  preloadRecording FAIL \(error)")
            }
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
            DiagLog.write("CallDetail", "  loadTranscription SKIP — egressId nil (call.id empty)")
            await MainActor.run { state.isTranscriptionLoading = false }
            return
        }
        DiagLog.write("CallDetail", "  loadTranscription START egressId=\(egressId)")

        do {
            let data = try await callHistoryService.fetchTranscription(egressId: egressId)
            DiagLog.write("CallDetail", "  fetchTranscription OK available=\(data.available) status=\(data.status?.rawValue ?? "nil") hasTranscription=\(data.transcription != nil) hasSummary=\(data.summary != nil) segments=\(data.transcription?.segments.count ?? 0) topics=\(data.summary?.topics?.count ?? 0)")
            await MainActor.run {
                state.transcriptionData = data
                state.isTranscriptionLoading = false

                // Select first available tab
                if let firstTab = state.availableTabs.first {
                    state.selectedTab = firstTab
                }
                let tabs = state.availableTabs.map(\.rawValue).joined(separator: ",")
                DiagLog.write("CallDetail", "  availableTabs=\(tabs) selected=\(state.selectedTab.rawValue)")

                if data.status?.isInProgress == true {
                    startPolling()
                }
            }
        } catch {
            DiagLog.write("CallDetail", "  fetchTranscription FAIL \(error)")
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
                    // Build 115 fix: args были перепутаны. AudioPlayer.load использует
                    // playbackURL для AVPlayerItem; передавать local (downloaded) файл,
                    // не remote — иначе AVPlayer стримит без Bearer auth → 401 → 0:00/0:00.
                    self.audioPlayer.load(sourceURL: recordingURL, playbackURL: localURL, autoplay: true)
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

        // Build 118: ключ кеша — egressId (session_xxx из recordingURL), а не call.id.
        // На iPhone call.id это нестабильный UUID локальной истории — менялся бы между
        // launch'ами и каждый раз заставлял бы качать m4a заново. egressId стабилен.
        let cacheKey = egressId ?? state.call.id
        let localURL = cacheDir.appendingPathComponent("\(cacheKey).mp4")

        // Use cached file if exists and not too small
        if FileManager.default.fileExists(atPath: localURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 {
            return localURL
        }

        // Build 115 fix: используем callHistoryService.downloadRecording — он
        // добавляет Authorization: Bearer header. Без него recording-api отдаёт
        // 401 → AVAudioPlayer не открывает файл → длительность 0:00 / 0:00.
        DiagLog.write("CallDetail", "  download START url=\(url.absoluteString)")
        let data = try await callHistoryService.downloadRecording(from: url)
        DiagLog.write("CallDetail", "  download OK \(data.count) bytes")
        try data.write(to: localURL)
        return localURL
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
        // Build 118: на iPhone state.call.id — UUID из LocalCallHistoryService
        // (не session_xxx). Recording API знает только session_<timestamp_ms>.
        // Извлекаем правильный id из последнего path component recordingURL:
        // `.../play/session_1777960175326` → "session_1777960175326".
        if let url = state.call.recordingURL,
           let last = url.pathComponents.last,
           !last.isEmpty,
           last != "play" {
            return last
        }
        // Fallback: на симуляторе или при отсутствии recordingURL — call.id.
        let id = state.call.id
        return id.isEmpty ? nil : id
    }
}
