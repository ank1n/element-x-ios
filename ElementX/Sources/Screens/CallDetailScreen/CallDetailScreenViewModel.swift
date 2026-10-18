//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine
import Foundation
import UIKit

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
    private var attendeesRequest: Task<Void, Never>?
    private var tasksRequest: Task<Void, Never>?
    private var tasksRevision = 0
    private var tasksVisible = true
    private var userSelectedTab = false
    private let initialTab: CallDetailTab?

    var actionsPublisher: AnyPublisher<CallDetailScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private let clientProxy: ClientProxyProtocol?

    init(call: CallHistoryItem,
         callHistoryService: CallHistoryServiceProtocol,
         mediaProvider: MediaProviderProtocol?,
         clientProxy: ClientProxyProtocol? = nil,
         initialTab: CallDetailTab? = nil,
         audioPlayer: AudioPlayerProtocol = AudioPlayer()) {
        self.callHistoryService = callHistoryService
        self.clientProxy = clientProxy
        self.audioPlayer = audioPlayer
        self.initialTab = initialTab

        var initialState = CallDetailScreenViewState(call: call)
        initialState.actualAttendees = (call.attendeeIDs ?? []).map { CallAttendee(id: $0, name: $0) }
        initialState.tasksTabRequested = initialTab == .tasks
        if let initialTab { initialState.selectedTab = initialTab }
        // Build 114: mediaProvider обязателен — LoadableAvatarImage падает с
        // assertionFailure в DEBUG если context.mediaProvider == nil.
        super.init(initialViewState: initialState, mediaProvider: mediaProvider)

        setupAudioPlayerSubscription()
        loadAttendees()

        // Status totals and the Tasks tab share this one request, independently of transcription.
        Task { await loadTasks(refresh: true) }

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

    private func loadAttendees() {
        guard attendeesRequest == nil else { return }
        let ids = state.call.taskRecordingIDs
        guard !ids.isEmpty else { return }
        state.isAttendeesLoading = true
        state.attendeesError = false
        attendeesRequest = Task { [weak self] in
            guard let self else { return }
            var rows: [CallAttendee] = (state.call.attendeeIDs ?? []).map { CallAttendee(id: $0, name: $0) }
            var failed = false
            // Detail only, never a request per calendar/history row.
            for id in ids {
                guard !Task.isCancelled else { return }
                do { rows += try await callHistoryService.fetchCallAttendees(egressId: id) }
                catch { failed = true }
            }
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            state.actualAttendees = rows.filter { seen.insert($0.id).inserted }
            state.attendeesError = failed
            state.isAttendeesLoading = false
            // Use exact profile IDs, including people who have since left the room.
            if let clientProxy {
                for id in CallSummaryPeople.uniqueIDs(rows.map(\.id)) where state.participantProfiles[id] == nil {
                    guard !Task.isCancelled else { return }
                    if case .success(let profile) = await clientProxy.profile(for: id) {
                        guard !Task.isCancelled else { return }
                        state.participantProfiles[id] = ResolvedParticipant(displayName: profile.displayName ?? id, avatarURL: profile.avatarURL)
                    }
                }
            }
            attendeesRequest = nil
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
                for member in members {
                    self.state.participantProfiles[member.userID] = ResolvedParticipant(displayName: member.displayName ?? member.userID,
                                                                                       avatarURL: member.avatarURL)
                }
                var map: [String: URL] = [:]
                let nameCounts = Dictionary(grouping: members, by: { $0.displayName ?? "" }).mapValues(\.count)
                for member in members {
                    guard let url = member.avatarURL,
                          let display = member.displayName,
                          !display.isEmpty, nameCounts[display] == 1 else { continue }
                    map[display] = url
                }
                if !map.isEmpty {
                    DiagLog.write("CallDetail", "  members publisher → speakers=\(map.count)")
                    self.state.speakerAvatars = map
                }
            }
            .store(in: &detailCancellables)

        // STMOB-257: слушаем room-событие готовности транскрибации. Molly шлёт
        // `im.stalk.transcription_ready` (session_id=egress_id) в комнату звонка;
        // Sygnal deny гасит только APNS-пуш, через /sync событие приходит. Как
        // прилетело для нашего egressId — мгновенно перезагружаем транскрипцию
        // (быстрее 10с-поллинга). Паттерн как у encryption_keys в NativeCallSession.
        await roomProxy.timeline.subscribeForUpdates()
        roomProxy.timeline.timelineItemProvider.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, _ in
                guard let self else { return }
                for item in items {
                    guard case .event(let eventItem) = item,
                          case .msgLike(let msgContent) = eventItem.content,
                          case .other(let eventType) = msgContent.kind,
                          case .other(let typeStr) = eventType,
                          typeStr.contains("transcription_ready") else { continue }
                    guard let json = eventItem.debugInfo.originalJSON,
                          let data = json.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let content = dict["content"] as? [String: Any] else { continue }
                    let sessionId = content["session_id"] as? String
                    if sessionId == self.egressId {
                        DiagLog.write("CallDetail", "  transcription_ready event matched egress=\(self.egressId ?? "") → reload")
                        Task { await self.loadTranscription() }
                    }
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
        case .refreshParticipants:
            loadAttendees()
        case .appeared:
            let returning = !tasksVisible
            tasksVisible = true
            if returning { loadAttendees() }
            if returning || !state.tasksHaveLoaded { Task { await loadTasks(refresh: true) } }
        case .disappeared:
            attendeesRequest?.cancel()
            attendeesRequest = nil
            tasksVisible = false
            tasksRevision += 1
            tasksRequest?.cancel()
            tasksRequest = nil
            state.isTasksLoading = false
        case .dismiss:
            attendeesRequest?.cancel()
            attendeesRequest = nil
            tasksVisible = false
            tasksRevision += 1
            tasksRequest?.cancel()
            stopPlayback()
            actionsSubject.send(.dismiss)
        case .selectTab(let tab):
            userSelectedTab = true
            if tab == .tasks { state.tasksTabRequested = true }
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
        case .createTask(let task, let projectId, let overrideText):
            Task { await createTask(task, projectId: projectId, overrideText: overrideText) }
        case .openProjectPicker(let task):
            state.projectPickerForTask = task
            Task { await loadProjects(query: "") }
        case .closeProjectPicker:
            state.projectPickerForTask = nil
        case .searchProjects(let query):
            Task { await loadProjects(query: query) }
        case .openTrackItIssue(let urlString):
            // STMOB build 163: открыть в TrackIT app через deep link если
            // приложение установлено. Если нет — НЕ открываем браузер
            // (по запросу юзера: не переходить если нет TrackIT app).
            // URL формата https://trackit.implica.ru/<ws>/projects/<pid>/issues/<id>
            // мапим в plane://issue/<id> и trackit://issue/<id>.
            if let url = URL(string: urlString) {
                let issueID: String? = {
                    let comps = url.pathComponents.filter { !$0.isEmpty }
                    if let i = comps.firstIndex(of: "issues"), i + 1 < comps.count {
                        return comps[i + 1]
                    }
                    return nil
                }()
                let candidates: [String] = [
                    issueID.map { "trackit://issue/\($0)" },
                    issueID.map { "plane://issue/\($0)" },
                    "trackit://",
                    "plane://"
                ].compactMap { $0 }

                for candidate in candidates {
                    if let deep = URL(string: candidate),
                       UIApplication.shared.canOpenURL(deep) {
                        UIApplication.shared.open(deep)
                        DiagLog.write("CallDetail", "  openTrackItIssue → app deep link: \(candidate)")
                        return
                    }
                }
                DiagLog.write("CallDetail", "  openTrackItIssue → TrackIT app NOT installed, NOT opening browser (по запросу)")
            }
        case .openParticipant(let id):
            guard CallSummaryPeople.isUserID(id) else { return }
            actionsSubject.send(.openParticipant(id))
        case .refreshTasks:
            Task { await loadTasks(refresh: true) }
        }
    }

    deinit {
        attendeesRequest?.cancel()
        pollingCancellable?.cancel()
        currentDownloadTask?.cancel()
        tasksRequest?.cancel()
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

                normalizeSelectedTab(preferDefault: !userSelectedTab && initialTab == nil)
                let tabs = state.availableTabs.map(\.rawValue).joined(separator: ",")
                DiagLog.write("CallDetail", "  availableTabs=\(tabs) selected=\(state.selectedTab.rawValue)")

                if data.status?.isInProgress == true {
                    startPolling()
                }
            }
        } catch {
            DiagLog.write("CallDetail", "  fetchTranscription FAIL \(error)")
            MXLog.error("CallDetail: Failed to fetch transcription: \(error)")
            await MainActor.run {
                state.isTranscriptionLoading = false
                normalizeSelectedTab()
            }
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
                // 0xDEAD10CC-гигиена: тик в фоне = no-op (сеть/401→token refresh
                // в фоновом CPU-окне без bg task = суспенд посреди SDK-записи)
                guard UIApplication.shared.applicationState != .background else { return }
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

    // MARK: - STALK-255 Tasks (build 157)

    /// Подтянуть уже созданные TrackIT-задачи для этого звонка.
    /// Запускается при первом открытии вкладки "Задачи" и по action .refreshTasks.
    private func loadTasks(refresh: Bool) async {
        guard tasksVisible, !state.call.taskRecordingIDs.isEmpty else { return }
        if let tasksRequest { await tasksRequest.value; return }
        tasksRevision += 1
        let revision = tasksRevision
        let ids = state.call.taskRecordingIDs
        let service = callHistoryService
        state.isTasksLoading = true
        state.tasksError = nil
        normalizeSelectedTab()
        let request = Task { [weak self] in
            do {
                // Bound concurrency: status refresh can itself call TrackIT for each issue.
                let rows = try await withThrowingTaskGroup(of: (Int, [CreatedTask]).self) { group in
                    var next = 0
                    for _ in 0..<min(4, ids.count) {
                        let index = next; next += 1
                        group.addTask { try await (index, service.fetchCreatedTasks(egressId: ids[index], refresh: refresh)) }
                    }
                    var pages: [(Int, [CreatedTask])] = []
                    while let result = try await group.next() {
                        try Task.checkCancellation()
                        pages.append(result)
                        if next < ids.count {
                            let index = next; next += 1
                            group.addTask { try await (index, service.fetchCreatedTasks(egressId: ids[index], refresh: refresh)) }
                        }
                    }
                    return pages.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                try Task.checkCancellation()
                guard let self, tasksVisible, tasksRevision == revision else { return }
                state.createdTasks = rows
                state.taskStatistics = CallTaskStatistics(tasks: rows)
                state.tasksHaveLoaded = true
            } catch {
                guard let self, !Task.isCancelled, tasksVisible, tasksRevision == revision else { return }
                // Keep previous rows, but never present a failed/partial refresh as zero or fresh totals.
                state.tasksError = NSLocalizedString("stalk_call_tasks_refresh_failed", value: "Could not update task statuses", comment: "Call task statuses refresh failed")
            }
            guard let self, tasksVisible, tasksRevision == revision else { return }
            state.isTasksLoading = false
            tasksRequest = nil
            normalizeSelectedTab()
        }
        tasksRequest = request
        await request.value
    }

    private func normalizeSelectedTab(preferDefault: Bool = false) {
        if state.isTranscriptionLoading, !state.tasksTabRequested, !userSelectedTab { return }
        if preferDefault || !state.availableTabs.contains(state.selectedTab),
           let first = state.availableTabs.first {
            state.selectedTab = first
        }
    }

    private func loadProjects(query: String) async {
        await MainActor.run { state.isProjectsLoading = true }
        do {
            let projects = try await callHistoryService.searchTrackItProjects(query: query)
            await MainActor.run {
                state.trackItProjects = projects
                state.isProjectsLoading = false
            }
        } catch {
            await MainActor.run { state.isProjectsLoading = false }
            DiagLog.write("CallDetail", "  loadProjects FAIL \(error)")
        }
    }

    private func createTask(_ task: SuggestedTask, projectId: String, overrideText: String?) async {
        guard let egressId else { return }
        do {
            let created = try await callHistoryService.createTask(egressId: egressId,
                                                                  topicIndex: task.topicIndex,
                                                                  taskIndex: task.taskIndex,
                                                                  projectId: projectId,
                                                                  overrideText: overrideText)
            await MainActor.run {
                // Заменяем или добавляем по (topicIndex, taskIndex) ключу — idempotent
                // от сервера может вернуть существующую задачу. UI не должен
                // дублировать карточки.
                if let i = state.createdTasks.firstIndex(where: { $0.egressId == created.egressId && $0.topicIndex == created.topicIndex && $0.taskIndex == created.taskIndex }) {
                    state.createdTasks[i] = created
                } else {
                    state.createdTasks.append(created)
                }
                state.projectPickerForTask = nil
                state.taskStatistics = CallTaskStatistics(tasks: state.createdTasks)
                state.tasksHaveLoaded = true
            }
            if let clientProxy {
                NotificationCenter.default.post(name: .stalkCallTasksChanged, object: nil,
                                                userInfo: ["egressIDs": state.call.taskRecordingIDs,
                                                           "userID": clientProxy.userID, "homeserver": clientProxy.homeserver])
            }
            // Revalidate all sessions, including idempotent creations; never increment a cached count.
            tasksRevision += 1
            tasksRequest?.cancel()
            tasksRequest = nil
            state.isTasksLoading = false
            await loadTasks(refresh: true)
            DiagLog.write("CallDetail", "  createTask OK \(created.trackitProjectIdentifier ?? "?")-\(created.trackitSequenceId ?? 0)")
        } catch {
            await MainActor.run {
                state.bindings.alertInfo = AlertInfo(id: .init(), title: NSLocalizedString("stalk_calldetail_task_create_failed", tableName: "Localizable", value: "Не удалось создать задачу", comment: "Failed to create task alert title"), message: "\(error)")
            }
            DiagLog.write("CallDetail", "  createTask FAIL \(error)")
        }
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
        // Failed/non-playable recordings still have task metadata; local UUIDs are not API IDs.
        return state.call.taskRecordingIDs.first
    }
}
