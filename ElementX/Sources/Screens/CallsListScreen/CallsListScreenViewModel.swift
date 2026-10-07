//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log
import UIKit

typealias CallsListScreenViewModelType = StateStoreViewModel<CallsListScreenViewState, CallsListScreenViewAction>

protocol CallsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> { get }
    var context: CallsListScreenViewModelType.Context { get }
    func setActive(_ active: Bool)
    func stop()
}

class CallsListScreenViewModel: CallsListScreenViewModelType, CallsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let localCallHistoryService: LocalCallHistoryServiceProtocol
    private let callHistoryService: CallHistoryServiceProtocol?
    private let actionsSubject: PassthroughSubject<CallsListScreenViewModelAction, Never> = .init()
    private var callsCancellables: Set<AnyCancellable> = []

    private let audioPlayer: AudioPlayerProtocol
    private let fileManager = FileManager.default
    private var meetingsService: MeetingsService?

    /// Кэш записей с сервера для быстрого доступа по roomID
    private var recordingsCache: [String: CallHistoryAPIItem] = [:]

    /// Set of recording IDs that have been listened to (persisted)
    private var listenedRecordingIDs: Set<String> = []
    /// Cache of resolved room data (contactId → avatar, name, participants)
    private var resolvedRoomData: [String: CallHistoryRoomInfo] = [:]

    private static let listenedCacheKey = "listened-recording-ids"

    var actionsPublisher: AnyPublisher<CallsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol,
         localCallHistoryService: LocalCallHistoryServiceProtocol? = nil,
         callHistoryService: CallHistoryServiceProtocol? = nil,
         audioPlayer: AudioPlayerProtocol = AudioPlayer(),
         cacheService: STalkCacheService? = nil,
         isActive: Bool = true,
         now: @escaping () -> Date = Date.init,
         applicationIsActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         roomHistoryLoader: (() async throws -> [String: [CallHistoryItem]])? = nil) {
        self.userSession = userSession
        self.localCallHistoryService = localCallHistoryService ?? ServiceLocator.shared.localCallHistoryService
        self.callHistoryService = callHistoryService
        self.audioPlayer = audioPlayer
        self.cacheService = cacheService ?? ServiceLocator.shared.cacheService
        cacheKey = CallHistoryCacheSnapshot.key(userID: userSession.clientProxy.userID, homeserver: userSession.clientProxy.homeserver)
        self.isActive = isActive
        self.now = now
        self.applicationIsActive = applicationIsActive
        self.roomHistoryLoader = roomHistoryLoader
        previousLocalCalls = self.localCallHistoryService.getAllCalls()
        localRevision = CallHistoryCacheSnapshot.revision(previousLocalCalls)

        var initialState = CallsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
        setupAudioPlayerObserver()
        loadListenedRecordingIDs()
        setupMeetingsService()

        updateCallHistoryFromLocal(previousLocalCalls)
        DiagLog.write("CallHistory", "local history shown immediately: count=\(previousLocalCalls.count)")
        setupLocalHistorySubscription()
        loadCachedHistory()
    }

    override func process(viewAction: CallsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectCall(let call):
            actionsSubject.send(.startCall(userId: call.contactId))
        case .startNewCall:
            loadNewCallContacts()
            state.bindings.selectedNewCallContactIDs = []
            state.bindings.newCallSearchQuery = ""
            state.bindings.isVideoCall = false
            state.bindings.isNewCallSheetPresented = true
        case .makeCall(let contactIDs, let isVideo):
            handleMakeCall(contactIDs: contactIDs, isVideo: isVideo)
        case .playRecording(let call):
            handlePlayRecording(call)
        case .showCallDetail(let call):
            actionsSubject.send(.showCallDetail(call))
        case .seekPlayback(let progress):
            Task { await audioPlayer.seek(to: progress) }
        case .refresh:
            refreshIfNeeded(force: true)
            refreshMeetingsIfNeeded(force: true)
        case .rsvpMeeting(let meetingId, let response):
            handleRSVP(meetingId: meetingId, response: response)
        case .joinMeeting(let meeting):
            if let roomId = meeting.matrixRoomId {
                actionsSubject.send(.startCall(userId: roomId))
            }
        }
    }

    // MARK: - Cached history and background refresh

    private var snapshot = CallHistoryCacheSnapshot()
    private let cacheService: STalkCacheService?
    private let cacheKey: String
    private let now: () -> Date
    private let applicationIsActive: () -> Bool
    private let roomHistoryLoader: (() async throws -> [String: [CallHistoryItem]])?
    private var isActive: Bool
    private var stopped = false
    private var cacheLoaded = false
    private var localRevision: String
    private var previousLocalCalls: [LocalCallHistoryItem]
    private var cacheTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private var meetingsTask: Task<Void, Never>?
    private var meetingsRetryAfter = Date.distantPast
    private var retryAfter: Date = .distantPast
    private var forceAfterCurrentRefresh = false
    private var roomTokenRefreshTask: Task<String?, Never>?
    private static let retryInterval: TimeInterval = 30

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            refreshIfNeeded()
            refreshMeetingsIfNeeded()
            resolveAvatars()
        } else {
            refreshTask?.cancel()
            avatarTask?.cancel()
            meetingsTask?.cancel()
        }
    }

    func stop() {
        stopped = true
        isActive = false
        cacheTask?.cancel()
        refreshTask?.cancel()
        avatarTask?.cancel()
        meetingsTask?.cancel()
        roomTokenRefreshTask?.cancel()
        callsCancellables.removeAll()
        stopProgressTimer()
        audioPlayer.stop()
    }

    private func loadCachedHistory() {
        cacheTask = Task { [weak self] in
            guard let self else { return }
            if let cached = await cacheService?.load(CallHistoryCacheSnapshot.self, forKey: cacheKey), !stopped {
                snapshot = cached
                state.meetings = cached.meetings
                resolvedRoomData = cached.rooms
                if cached.localRevision != localRevision {
                    snapshot.recordingsFetchedAt = nil
                    snapshot.roomEventsFetchedAt = nil
                    for call in previousLocalCalls {
                        snapshot.roomFetchedAt[call.roomID] = nil
                    }
                }
                rebuildFetchedHistory()
                DiagLog.write("CallHistory", "cache restored: recordings=\(cached.recordings.count), roomCalls=\(cached.roomCalls.values.reduce(0) { $0 + $1.count })")
            }
            guard !Task.isCancelled, !stopped else { return }
            cacheLoaded = true
            updateCallHistoryFromLocal(localCallHistoryService.getAllCalls())
            refreshIfNeeded()
            refreshMeetingsIfNeeded()
        }
    }

    private func refreshIfNeeded(force: Bool = false, rerunIfLoading: Bool = false) {
        guard cacheLoaded, isActive, applicationIsActive(), !stopped else { return }
        if refreshTask != nil {
            forceAfterCurrentRefresh = forceAfterCurrentRefresh || rerunIfLoading
            return
        }
        guard force || now() >= retryAfter else { return }
        let recordingsNeeded = callHistoryService != nil && (force || !CallHistoryCacheSnapshot.isFresh(snapshot.recordingsFetchedAt, now: now()))
        let roomsNeeded: Bool
        if roomHistoryLoader != nil {
            roomsNeeded = force || !CallHistoryCacheSnapshot.isFresh(snapshot.roomEventsFetchedAt, now: now())
        } else {
            roomsNeeded = userSession.clientProxy is ClientProxy &&
                userSession.clientProxy.staticRoomSummaryProvider.statePublisher.value.isLoaded &&
                roomsToRefresh(force: force).isEmpty == false
        }
        guard recordingsNeeded || roomsNeeded else {
            DiagLog.write("CallHistory", "fresh cache: no history requests")
            return
        }
        retryAfter = now().addingTimeInterval(Self.retryInterval)
        state.isRefreshingHistory = true
        state.isLoading = state.callHistory.isEmpty && snapshot.recordingsFetchedAt == nil && snapshot.roomCalls.isEmpty
        let revisionAtStart = localRevision
        let started = ContinuousClock.now
        DiagLog.write("CallHistory", "refresh started: recordings=\(recordingsNeeded), rooms=\(roomsNeeded), force=\(force)")
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                if recordingsNeeded { group.addTask { await self.refreshRecordings(revision: revisionAtStart) } }
                if roomsNeeded { group.addTask { await self.refreshRoomHistory(force: force, revision: revisionAtStart) } }
            }
            refreshTask = nil
            guard !stopped else { return }
            state.isLoading = false
            state.isRefreshingHistory = false
            await persistHistory()
            resolveAvatars(force: true)
            DiagLog.write("CallHistory", "refresh finished: rows=\(state.callHistory.count), durationMs=\(Self.elapsedMilliseconds(since: started)), cancelled=\(Task.isCancelled)")
            let pendingForce = forceAfterCurrentRefresh
            forceAfterCurrentRefresh = false
            if Task.isCancelled { retryAfter = .distantPast }
            if pendingForce || (Task.isCancelled && isActive && applicationIsActive()) { refreshIfNeeded(force: pendingForce) }
        }
    }

    private func refreshRecordings(revision: String) async {
        guard let callHistoryService else { return }
        let started = ContinuousClock.now
        do {
            let recordings = try await callHistoryService.fetchRecordings(currentUserID: userSession.clientProxy.userID)
            guard !Task.isCancelled, !stopped else { return }
            snapshot.recordings = recordings
            snapshot.recordingsFetchedAt = localRevision == revision ? now() : nil
            rebuildFetchedHistory()
            updateCallHistoryFromLocal(localCallHistoryService.getAllCalls())
            await persistHistory()
            DiagLog.write("CallHistory", "recordings updated: count=\(recordings.count), durationMs=\(Self.elapsedMilliseconds(since: started))")
        } catch {
            if !Task.isCancelled { DiagLog.write("CallHistory", "recordings unavailable: errorCode=\((error as NSError).code); cached history retained") }
        }
    }

    private func roomsToRefresh(force: Bool) -> [String] {
        let summaries = userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher.value
        return Array(Set(summaries.filter { $0.activeMembersCount <= 10 }.map(\.id)))
            .filter { force || !CallHistoryCacheSnapshot.isFresh(snapshot.roomFetchedAt[$0], now: now()) }
            .sorted()
    }

    private func refreshRoomHistory(force: Bool, revision: String) async {
        if let roomHistoryLoader {
            do {
                let rooms = try await roomHistoryLoader()
                guard !Task.isCancelled, !stopped else { return }
                snapshot.roomCalls = rooms
                snapshot.roomEventsFetchedAt = localRevision == revision ? now() : nil
                rebuildFetchedHistory()
                updateCallHistoryFromLocal(localCallHistoryService.getAllCalls())
                await persistHistory()
            } catch {
                if !Task.isCancelled { DiagLog.write("CallHistory", "room history unavailable; cached history retained") }
            }
            return
        }
        guard let client = userSession.clientProxy as? ClientProxy,
              let token = try? client.matrixAccessToken(), !token.isEmpty else { return }
        let roomIDs = roomsToRefresh(force: force)
        let homeserver = client.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ownUserID = client.userID
        let cutoff = now().addingTimeInterval(-30 * 24 * 3600)
        roomTokenRefreshTask = nil
        var iterator = roomIDs.makeIterator()
        var succeeded = 0
        await withTaskGroup(of: (String, [CallHistoryItem]?).self) { group in
            func enqueue(_ roomID: String) {
                group.addTask {
                    guard let events = await self.fetchCallMemberEvents(roomID: roomID, homeserver: homeserver, accessToken: token) else { return (roomID, nil) }
                    let calls = await self.extractCallSessions(events, roomID: roomID, ownUserID: ownUserID, cutoffDate: cutoff, sessionGapMs: 60000)
                    return (roomID, calls)
                }
            }
            for _ in 0..<4 {
                if let roomID = iterator.next() { enqueue(roomID) }
            }
            for await (roomID, calls) in group {
                guard !Task.isCancelled, !stopped else { group.cancelAll(); break }
                if let calls {
                    snapshot.roomCalls[roomID] = calls
                    snapshot.roomFetchedAt[roomID] = localRevision == revision ? now() : nil
                    succeeded += 1
                    rebuildFetchedHistory()
                    updateCallHistoryFromLocal(localCallHistoryService.getAllCalls())
                }
                if let roomID = iterator.next() { enqueue(roomID) }
            }
        }
        if !Task.isCancelled {
            await persistHistory()
            DiagLog.write("CallHistory", "room scan: requested=\(roomIDs.count), succeeded=\(succeeded), concurrency=4")
        }
    }

    private func rebuildFetchedHistory() {
        serverRecordings = snapshot.recordings
        for call in snapshot.roomCalls.values.flatMap({ $0 }) {
            if !serverRecordings.contains(where: { $0.contactId == call.contactId && abs($0.timestamp.timeIntervalSince(call.timestamp)) < 300 }) {
                serverRecordings.append(call)
            }
        }
    }

    private func persistHistory() async {
        snapshot.localRevision = localRevision
        snapshot.rooms = resolvedRoomData
        await cacheService?.save(snapshot, forKey: cacheKey, ttl: CallHistoryCacheSnapshot.freshnessInterval)
    }

    private func refreshMeetingsIfNeeded(force: Bool = false) {
        guard cacheLoaded, isActive, applicationIsActive(), !stopped, let meetingsService, meetingsTask == nil,
              force || (now() >= meetingsRetryAfter && !CallHistoryCacheSnapshot.isFresh(snapshot.meetingsFetchedAt, now: now())) else { return }
        meetingsRetryAfter = now().addingTimeInterval(Self.retryInterval)
        state.isMeetingsLoading = state.meetings.isEmpty && snapshot.meetingsFetchedAt == nil
        meetingsTask = Task { [weak self] in
            await meetingsService.fetchMeetings()
            guard let self else { return }
            meetingsTask = nil
            state.isMeetingsLoading = false
            if Task.isCancelled { meetingsRetryAfter = .distantPast }
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: .now).components
        return duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
    }

    // MARK: - Local History Subscription

    private func setupLocalHistorySubscription() {
        localCallHistoryService.callHistoryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] localCalls in
                guard let self, !self.stopped else { return }
                let revision = CallHistoryCacheSnapshot.revision(localCalls)
                if revision != self.localRevision {
                    self.snapshot.recordingsFetchedAt = nil
                    self.snapshot.roomEventsFetchedAt = nil
                    for call in self.previousLocalCalls + localCalls {
                        self.snapshot.roomFetchedAt[call.roomID] = nil
                    }
                    self.localRevision = revision
                    self.previousLocalCalls = localCalls
                    self.refreshIfNeeded(force: true, rerunIfLoading: true)
                }
                self.updateCallHistoryFromLocal(localCalls)
            }
            .store(in: &callsCancellables)
        userSession.clientProxy.staticRoomSummaryProvider.statePublisher
            .map(\.isLoaded)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loaded in if loaded { self?.refreshIfNeeded() } }
            .store(in: &callsCancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshIfNeeded()
                self?.refreshMeetingsIfNeeded()
            }
            .store(in: &callsCancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshTask?.cancel()
                self?.avatarTask?.cancel()
                self?.meetingsTask?.cancel()
                self?.roomTokenRefreshTask?.cancel()
            }
            .store(in: &callsCancellables)
    }

    /// Кэш записей с сервера (egressId -> recording info)
    private var serverRecordings: [CallHistoryItem] = []

    private func updateCallHistoryFromLocal(_ localCalls: [LocalCallHistoryItem], resolveMetadata: Bool = true) {
        MXLog.info("📞 Updating call history from local: \(localCalls.count) calls, server recordings: \(serverRecordings.count)")

        // Конвертируем локальные записи в CallHistoryItem
        var calls = localCalls.map { (local: LocalCallHistoryItem) -> CallHistoryItem in
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
                } else {
                    // Fallback: формируем URL напрямую — запись может быть ещё не обновлена на сервере
                    let homeserver = userSession.clientProxy.homeserver
                    let domain = URL(string: homeserver)?.host ?? "stalk.implica.ru"
                    recordingURL = URL(string: "https://\(domain)/recording-api/api/recording/play/\(egressId)")
                }
            } else {
                // Попробуем найти запись по roomID и близкому времени
                if let matchingRecording = findMatchingRecording(for: local) {
                    recordingURL = matchingRecording.recordingURL
                }
            }

            return CallHistoryItem(id: local.id,
                                   contactName: local.displayName,
                                   contactId: local.roomID,
                                   callType: callType,
                                   timestamp: local.startedAt,
                                   duration: local.duration,
                                   isMissed: local.isMissed,
                                   recordingURL: recordingURL)
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

        // Apply cached room data (names, avatars) to freshly created items
        for i in calls.indices {
            if let cached = resolvedRoomData[calls[i].contactId] {
                if let name = cached.contactName { calls[i].contactName = name }
                if let url = cached.avatarURL { calls[i].avatarURL = url }
                if let count = cached.participantCount { calls[i].participantCount = count }
                if let urls = cached.participantAvatarURLs { calls[i].participantAvatarURLs = urls }
            }
        }

        // Only update state if data actually changed (preserves scroll position on navigation back)
        for i in calls.indices {
            calls[i].isListened = listenedRecordingIDs.contains(calls[i].id)
        }
        if state.callHistory != calls || state.isLoading {
            state.callHistory = calls
            applyListenedStatus()
        }
        state.isLoading = calls.isEmpty && (!cacheLoaded || (state.isRefreshingHistory && snapshot.recordingsFetchedAt == nil && snapshot.roomCalls.isEmpty))

        // Resolve avatars for rooms not yet cached
        let unresolvedRoomIDs = Set(calls.map(\.contactId)).subtracting(resolvedRoomData.keys)
        if resolveMetadata, !unresolvedRoomIDs.isEmpty {
            resolveAvatars()
        }
    }

    /// Resolves avatar URLs and participant info for call history items from Matrix room data
    private func resolveAvatars(force: Bool = false) {
        guard isActive, applicationIsActive(), !stopped, avatarTask == nil,
              userSession.clientProxy.staticRoomSummaryProvider.statePublisher.value.isLoaded else { return }
        let ids = Set(state.callHistory.map(\.contactId)).filter { force || resolvedRoomData[$0] == nil }
        guard !ids.isEmpty else { return }
        let ownUserID = userSession.clientProxy.userID
        avatarTask = Task { [weak self] in
            guard let self else { return }
            for roomID in ids {
                guard !Task.isCancelled, !stopped else { break }
                // Metadata must not wake sync for a room unavailable in the local SDK.
                guard userSession.clientProxy.roomMembership(roomID: roomID) == .joined,
                      case let .joined(room) = await userSession.clientProxy.roomForIdentifier(roomID) else { continue }
                let info = room.infoPublisher.value
                var metadata = CallHistoryRoomInfo(contactName: info.displayName, participantCount: Int(info.activeMembersCount))
                if info.activeMembersCount > 2, let members = await room.members() {
                    let otherMembers = members.filter { $0.userID != ownUserID }
                    metadata.participantAvatarURLs = otherMembers.compactMap(\.avatarURL)
                } else {
                    metadata.avatarURL = switch info.avatar {
                    case .heroes(let heroes) where heroes.count == 1: heroes[0].avatarURL
                    case .room(_, _, let url): url
                    case .space(_, _, let url): url
                    default: nil
                    }
                }
                guard !Task.isCancelled, !stopped else { break }
                resolvedRoomData[roomID] = metadata
            }
            avatarTask = nil
            guard !Task.isCancelled, !stopped else { return }
            // Merge metadata into the latest list, never restore an obsolete snapshot.
            updateCallHistoryFromLocal(localCallHistoryService.getAllCalls(), resolveMetadata: false)
            await persistHistory()
        }
    }

    private func findMatchingRecording(for localCall: LocalCallHistoryItem) -> CallHistoryItem? {
        serverRecordings.first { recording in
            isRecordingMatchingCall(recording, localCall: localCall)
        }
    }

    /// Проверяет соответствует ли запись локальному звонку
    private func isRecordingMatchingCall(_ recording: CallHistoryItem, localCall: LocalCallHistoryItem) -> Bool {
        // Проверяем roomID (contactId в recording может быть matrixRoomId или encoded roomName)
        let roomMatches = recording.contactId == localCall.roomID ||
            recording.contactId.contains(localCall.roomID)

        // Build 129 (Молли STMOB-104 spec): асимметричное окно match.
        // Recording.startedAt всегда >= callStart (egress lag 1-3 мин обычно):
        //   -30s buffer для jitter timestamp (Synapse vs egress)
        //   +5min для egress lag
        let delta = recording.timestamp.timeIntervalSince(localCall.startedAt)
        let callEndTs = (localCall.duration ?? 0) > 0 ? (localCall.duration ?? 0) : 0
        let timeMatches = delta >= -30 && delta <= callEndTs + 300

        // Вариант 1: roomID совпадает + время близко
        if roomMatches, timeMatches {
            return true
        }

        // Вариант 2: roomID разные (DM vs call room), но время и длительность совпадают
        // Это случай когда local хранит DM roomID, а сервер — call roomID
        if timeMatches {
            let localDuration = localCall.duration ?? 0
            let recordingDuration = recording.duration ?? 0
            // Если обе длительности > 0 и разница < 10 секунд — это один звонок
            if localDuration > 0, recordingDuration > 0 {
                let durationDiff = abs(localDuration - recordingDuration)
                if durationDiff < 10 {
                    return true
                }
            }
            // Или если время начала совпадает с точностью до 30 секунд — скорее всего один звонок
            if abs(delta) < 30 {
                return true
            }
        }

        return false
    }

    // MARK: - Call Events from Matrix Rooms

    /// Fetch call.member events from a room via Matrix API
    private func fetchCallMemberEvents(roomID: String, homeserver: String, accessToken: String) async -> [[String: Any]]? {
        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: pathCharacters),
              var components = URLComponents(string: "\(homeserver)/_matrix/client/v3/rooms/\(encodedRoomID)/messages") else { return nil }
        components.queryItems = [URLQueryItem(name: "dir", value: "b"), URLQueryItem(name: "limit", value: "100"),
                                 URLQueryItem(name: "filter", value: "{\"types\":[\"org.matrix.msc3401.call.member\",\"m.call.member\"]}")]
        guard let url = components.url else { return nil }
        var token = accessToken
        for attempt in 0...1 {
            guard !Task.isCancelled, isActive, applicationIsActive() else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse else { return nil }
            if httpResponse.statusCode == 401, attempt == 0 {
                if roomTokenRefreshTask == nil {
                    roomTokenRefreshTask = Task { [weak self] in
                        guard let client = self?.userSession.clientProxy as? ClientProxy else { return nil }
                        await client.forceTokenRefresh()
                        return try? client.matrixAccessToken()
                    }
                }
                guard let fresh = await roomTokenRefreshTask?.value, !fresh.isEmpty else { return nil }
                token = fresh
                continue
            }
            guard httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chunk = json["chunk"] as? [[String: Any]] else {
                DiagLog.write("CallHistory", "room history HTTP \(httpResponse.statusCode); previous cached entries retained")
                return nil
            }
            return chunk
        }
        return nil
    }

    /// Group call.member events into call sessions (mirrors web's extractCallSessions)
    private func extractCallSessions(_ events: [[String: Any]], roomID: String, ownUserID: String, cutoffDate: Date, sessionGapMs: Int) -> [CallHistoryItem] {
        // Sort by timestamp ascending
        let sorted = events.sorted { ($0["origin_server_ts"] as? Int ?? 0) < ($1["origin_server_ts"] as? Int ?? 0) }

        var sessions: [CallHistoryItem] = []
        var sessionStart = 0
        var sessionEnd = 0
        var caller: String?
        var allParticipants = Set<String>()
        var activeParticipants = Set<String>()
        var inSession = false

        func flushSession() {
            guard inSession, let caller else { return }
            let date = Date(timeIntervalSince1970: TimeInterval(sessionStart) / 1000)
            guard date > cutoffDate else { inSession = false; return }

            let isIncoming = caller != ownUserID
            let duration = TimeInterval(sessionEnd - sessionStart) / 1000
            let isMissed = isIncoming && !allParticipants.contains(ownUserID)

            sessions.append(CallHistoryItem(id: "rtc_\(CallHistoryCacheSnapshot.digest(roomID))_\(sessionStart)",
                                            contactName: SL10n.callDefault,
                                            contactId: roomID,
                                            callType: isIncoming ? .incoming : .outgoing,
                                            timestamp: date,
                                            duration: duration > 5 ? duration : nil,
                                            isMissed: isMissed,
                                            recordingURL: nil))
            inSession = false
        }

        for event in sorted {
            guard let ts = event["origin_server_ts"] as? Int else { continue }
            let sender = event["sender"] as? String ?? ""
            let content = event["content"] as? [String: Any]
            // MatrixRTC: join = has "application" field (like web's isRtcJoin)
            // OR legacy: has non-empty "memberships" array
            let hasApplication = content?["application"] as? String != nil
            let memberships = content?["memberships"] as? [[String: Any]] ?? []
            let isJoin = hasApplication || !memberships.isEmpty

            if isJoin {
                if !inSession || (ts - sessionEnd) > sessionGapMs {
                    flushSession()
                    sessionStart = ts
                    sessionEnd = ts
                    caller = sender
                    allParticipants = [sender]
                    activeParticipants = [sender]
                    inSession = true
                } else {
                    allParticipants.insert(sender)
                    activeParticipants.insert(sender)
                    sessionEnd = ts
                }
            } else {
                if inSession {
                    sessionEnd = ts
                    activeParticipants.remove(sender)
                    if activeParticipants.isEmpty {
                        flushSession()
                    }
                }
            }
        }
        flushSession()
        return sessions
    }

    /// Parse call.member events into CallHistoryItem entries
    private func parseCallEvents(_ events: [[String: Any]], roomID: String, ownUserID: String, cutoffDate: Date) -> [CallHistoryItem] {
        var calls: [CallHistoryItem] = []
        // Group by call session: events close in time (within 60s) from the same room = same call
        var processedTimestamps = Set<Int>()

        for event in events {
            guard let ts = event["origin_server_ts"] as? Int else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            guard date > cutoffDate else { continue }

            // Round to nearest minute to group related events
            let minuteKey = ts / 60000
            guard !processedTimestamps.contains(minuteKey) else { continue }
            processedTimestamps.insert(minuteKey)

            let sender = event["sender"] as? String ?? ""
            let callType: CallHistoryItem.CallType = (sender == ownUserID) ? .outgoing : .incoming

            // Check if call has active members (content.memberships array)
            let content = event["content"] as? [String: Any]
            let memberships = content?["memberships"] as? [[String: Any]] ?? []

            // Empty memberships = hangup event, skip
            if memberships.isEmpty { continue }

            let call = CallHistoryItem(id: "matrix_\(roomID)_\(ts)",
                                       contactName: SL10n.callDefault,
                                       contactId: roomID,
                                       callType: callType,
                                       timestamp: date,
                                       duration: nil,
                                       isMissed: false,
                                       recordingURL: nil)
            calls.append(call)
        }

        return calls
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
                    // Mark recording as listened
                    if let playingId = state.playingCallId {
                        markRecordingAsListened(playingId)
                    }
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
                    state.bindings.alertInfo = AlertInfo(id: UUID(), title: SL10n.callsPlayError, message: "\(error)")
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

        // Download file first, then play locally
        currentDownloadTask = Task {
            do {
                let localURL = try await downloadRecording(from: recordingURL, callId: call.id)

                // Check if cancelled
                guard !Task.isCancelled, state.playingCallId == call.id else {
                    return
                }

                await MainActor.run {
                    audioPlayer.load(sourceURL: recordingURL, playbackURL: localURL, autoplay: true)
                }
            } catch {
                guard !Task.isCancelled else { return }

                MXLog.error("Failed to download recording: \(error)")
                await MainActor.run {
                    state.playbackState = .error
                    state.playingCallId = nil
                    state.bindings.alertInfo = AlertInfo(id: UUID(), title: SL10n.callsDownloadError, message: "\(error.localizedDescription)")
                }
            }
        }
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
        let config = URLSessionConfiguration.ephemeral // Ephemeral avoids caching issues
        config.timeoutIntervalForRequest = 120.0
        config.timeoutIntervalForResource = 300.0
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        // Try to avoid QUIC issues
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)

        // Create request with explicit headers
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection") // Force connection close
        // Add auth token for Recording API endpoints
        if let token = getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120.0
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Disable HTTP/3 by using explicit HTTP version
        request.assumesHTTP3Capable = false

        // Retry up to 3 times
        var lastError: Error?
        for attempt in 1...3 {
            do {
                MXLog.info("Downloading recording from: \(url), attempt \(attempt)")

                // Use data() instead of download() for more reliable transfer
                let (data, response) = try await session.data(for: request)

                // Check response
                if let httpResponse = response as? HTTPURLResponse {
                    MXLog.info("Download response: \(httpResponse.statusCode), data size: \(data.count), content-length: \(httpResponse.expectedContentLength)")

                    guard httpResponse.statusCode == 200 else {
                        throw CallHistoryError.serverError("HTTP \(httpResponse.statusCode)")
                    }
                }

                MXLog.info("Downloaded data size: \(data.count) bytes")

                // Минимум 1KB — пустые/битые файлы
                if data.count < 1000 {
                    throw CallHistoryError.serverError("File too small: \(data.count) bytes")
                }

                // Write to file
                if fileManager.fileExists(atPath: localURL.path) {
                    try? fileManager.removeItem(at: localURL)
                }
                try data.write(to: localURL)

                MXLog.info("Saved to: \(localURL.path), size: \(data.count)")
                return localURL

            } catch {
                MXLog.error("Download attempt \(attempt) failed: \(error)")
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                }
            }
        }

        throw lastError ?? CallHistoryError.serverError("Download failed after 3 attempts")
    }

    // MARK: - Listened Status

    private func loadListenedRecordingIDs() {
        Task {
            if let ids = await ServiceLocator.shared.cacheService?.load(Set<String>.self, forKey: Self.listenedCacheKey) {
                listenedRecordingIDs = ids
            }
        }
    }

    private func markRecordingAsListened(_ recordingId: String) {
        guard !listenedRecordingIDs.contains(recordingId) else { return }
        listenedRecordingIDs.insert(recordingId)

        // Update UI
        if let index = state.callHistory.firstIndex(where: { $0.id == recordingId }) {
            state.callHistory[index].isListened = true
        }

        // Persist
        Task {
            await ServiceLocator.shared.cacheService?.save(listenedRecordingIDs, forKey: Self.listenedCacheKey, ttl: 365 * 24 * 3600)
        }
    }

    /// Apply listened status from cache to call history items
    private func applyListenedStatus() {
        for i in state.callHistory.indices {
            if listenedRecordingIDs.contains(state.callHistory[i].id) {
                state.callHistory[i].isListened = true
            }
        }
    }

    /// Get Matrix access token for API authorization
    private func getAccessToken() -> String? {
        if let clientProxy = userSession.clientProxy as? ClientProxy {
            return try? clientProxy.matrixAccessToken()
        }
        return nil
    }

    // MARK: - Meetings

    private func setupMeetingsService() {
        guard let concreteProxy = userSession.clientProxy as? ClientProxy else {
            return
        }

        let homeserver = userSession.clientProxy.homeserver
        meetingsService = MeetingsService(homeserver: homeserver,
                                          accessTokenProvider: { try concreteProxy.matrixAccessToken() },
                                          forceTokenRefresh: { await concreteProxy.forceTokenRefresh() })

        meetingsService?.meetingsSubject
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (meetings: [Meeting]) in
                guard let self, !self.stopped else { return }
                self.state.meetings = meetings
                self.snapshot.meetings = meetings
                self.snapshot.meetingsFetchedAt = self.now()
                self.state.isMeetingsLoading = false
                Task { await self.persistHistory() }
            }
            .store(in: &callsCancellables)
    }

    private func handleRSVP(meetingId: Int, response: String) {
        Task {
            guard let success = await meetingsService?.rsvp(meetingId: meetingId, response: response),
                  success else {
                return
            }
            // Refresh meetings to reflect updated RSVP
            await meetingsService?.fetchMeetings()
        }
    }

    // MARK: - New Call

    private func handleMakeCall(contactIDs: [String], isVideo: Bool) {
        guard !contactIDs.isEmpty else { return }

        if contactIDs.count == 1 {
            // Один контакт — звоним в его DM roomID
            actionsSubject.send(.startCall(userId: contactIDs[0]))
        } else {
            // Несколько контактов — собираем matrixUserIDs и создаём комнату
            let matrixUserIDs = contactIDs.compactMap { roomID -> String? in
                state.newCallContacts.first(where: { $0.id == roomID })?.matrixUserID
            }

            guard !matrixUserIDs.isEmpty else {
                // Fallback — звоним первому
                actionsSubject.send(.startCall(userId: contactIDs[0]))
                return
            }

            Task { [weak self] in
                guard let self else { return }
                let names = contactIDs.compactMap { roomID in
                    self.state.newCallContacts.first(where: { $0.id == roomID })?.displayName
                }
                let roomName = names.joined(separator: ", ")

                let result = await userSession.clientProxy.createRoom(name: roomName,
                                                                      topic: nil,
                                                                      accessType: .private,
                                                                      isEncrypted: false, // call room follows optional-encryption default (unencrypted)
                                                                      isSpace: false,
                                                                      userIDs: matrixUserIDs,
                                                                      avatarURL: nil,
                                                                      aliasLocalPart: nil)

                switch result {
                case .success(let roomID):
                    MXLog.info("[Calls] Created group room \(roomID) for call with \(matrixUserIDs.count) users")
                    actionsSubject.send(.startCall(userId: roomID))
                case .failure(let error):
                    MXLog.error("[Calls] Failed to create group room: \(error)")
                    // Fallback — звоним первому
                    actionsSubject.send(.startCall(userId: contactIDs[0]))
                }
            }
        }
    }

    private func loadNewCallContacts() {
        let summaries = userSession.clientProxy.roomSummaryProvider.roomListPublisher.value
        let ownUserID = userSession.clientProxy.userID
        var seen = Set<String>()
        var contacts: [NewCallContact] = []

        for summary in summaries where summary.isDirect {
            guard summary.activeMembersCount == 2,
                  !summary.name.hasPrefix("Empty Room"),
                  !seen.contains(summary.id) else { continue }

            let heroUserID = summary.heroes.first?.userID
            if let heroUserID, heroUserID == ownUserID { continue }
            if let heroUserID, seen.contains(heroUserID) { continue }

            seen.insert(summary.id)
            if let heroUserID { seen.insert(heroUserID) }

            let avatarURL = summary.avatarURL ?? summary.heroes.first?.avatarURL

            // Извлекаем username из matrixUserID: @user:server → @user
            contacts.append(NewCallContact(id: summary.id,
                                           displayName: summary.name,
                                           avatarURL: avatarURL,
                                           matrixUserID: heroUserID,
                                           isOnline: false,
                                           isFavorite: false))
        }

        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        state.newCallContacts = contacts
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
    func fetchTranscription(egressId: String) async throws -> TranscriptionData
    func retryTranscription(egressId: String) async throws -> TranscriptionData
    /// Build 115 fix: download recording m4a с Authorization Bearer header.
    /// Без авторизации recording-api отдаёт 401 → AVAudioPlayer не открывает файл → 0:00/0:00.
    func downloadRecording(from url: URL) async throws -> Data

    /// STALK-255 build 157: задачи которые юзер уже конвертировал в TrackIT issues.
    /// `refresh=true` форсирует re-fetch статусов из TrackIT (иначе кэш на сервере).
    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask]
    /// STALK-255 build 157: создать TrackIT issue из suggestedTask. Idempotent
    /// по ключу (egressId, topicIndex, taskIndex) — повторный вызов возвращает
    /// существующую задачу с тем же URL.
    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask
    /// STALK-255 build 157: список проектов TrackIT для picker'а. Подстрочный
    /// фильтр через `q` (пусто = все доступные).
    func searchTrackItProjects(query: String) async throws -> [TrackItProject]
}

class CallHistoryService: NSObject, CallHistoryServiceProtocol, URLSessionDelegate {
    private let baseURL: URL
    private var urlSession: URLSession
    private let allowInsecureConnection: Bool
    private var accessToken: String?
    private var accessTokenProvider: (() throws -> String)?
    private var forceTokenRefresh: (() async -> Void)?

    init(baseURL: URL, accessToken: String? = nil, accessTokenProvider: (() throws -> String)? = nil, forceTokenRefresh: (() async -> Void)? = nil, urlSession: URLSession? = nil, allowInsecureConnection: Bool = false) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accessTokenProvider = accessTokenProvider
        self.forceTokenRefresh = forceTokenRefresh
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

    /// Update the access token (e.g. when user session becomes available)
    func updateAccessToken(_ token: String) {
        accessToken = token
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowInsecureConnection, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        let url = baseURL.appendingPathComponent("api/recording/list")
        for attempt in 0...1 {
            let token = try accessTokenProvider?() ?? accessToken
            guard let token, !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagLog.write("CallHistory", "recordings HTTP \(status), bytes=\(data.count)")
            if status == 401, attempt == 0, let forceTokenRefresh {
                await forceTokenRefresh()
                continue
            }
            return try processResponse(data: data, response: response, currentUserID: currentUserID, apiBaseURL: baseURL)
        }
        throw URLError(.userAuthenticationRequired)
    }

    private func processResponse(data: Data, response: URLResponse, currentUserID: String?, apiBaseURL: URL? = nil) throws -> [CallHistoryItem] {
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

        return recordings.compactMap { $0.toCallHistoryItem(currentUserID: currentUserID, apiBaseURL: apiBaseURL) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func fetchTranscription(egressId: String) async throws -> TranscriptionData {
        let url = baseURL.appendingPathComponent("api/recording/transcription/\(egressId)")
        return try await performAuthenticatedRequest(url: url, method: "GET")
    }

    func retryTranscription(egressId: String) async throws -> TranscriptionData {
        let url = baseURL.appendingPathComponent("api/recording/transcription/\(egressId)/retry")
        return try await performAuthenticatedRequest(url: url, method: "POST")
    }

    func downloadRecording(from url: URL) async throws -> Data {
        var lastError: Error?
        for attempt in 1...3 {
            let token = (try? accessTokenProvider?()) ?? accessToken
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.timeoutInterval = 120

            do {
                let (data, response) = try await urlSession.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if statusCode == 401, attempt < 3 {
                    await forceTokenRefresh?()
                    continue
                }
                guard statusCode == 200, data.count > 1024 else {
                    throw CallHistoryError.serverError("HTTP \(statusCode), bytes=\(data.count)")
                }
                return data
            } catch {
                lastError = error
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        throw lastError ?? CallHistoryError.invalidResponse
    }

    /// Обёртка, которой отмечаем окончательный отказ: она проходит мимо ветки
    /// повторов и разворачивается обратно в исходную ошибку у вызывающего.
    private struct PermanentFailure: Error {
        let underlying: Error
    }

    private func performAuthenticatedRequest<T: Decodable>(url: URL, method: String, jsonBody: [String: Any]? = nil) async throws -> T {
        var lastError: Error?
        for attempt in 1...3 {
            let token = (try? accessTokenProvider?()) ?? accessToken

            var request = URLRequest(url: url)
            request.httpMethod = method
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
            }
            request.timeoutInterval = 30.0

            do {
                let (data, response) = try await urlSession.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

                if statusCode == 401, attempt < 3 {
                    await forceTokenRefresh?()
                    continue
                }

                guard statusCode == 200 else {
                    // 4xx (кроме 401, он разобран выше вместе с обновлением токена)
                    // — это вердикт сервера, а не сбой связи. Повтор даст ровно тот
                    // же ответ, только экран простоит лишние две секунды в загрузке.
                    // Стало актуально с STALK-751: чужая запись теперь отвечает 403,
                    // и без этого один отказ превращался бы в три запроса.
                    let failure = CallHistoryError.serverError("HTTP \(statusCode)")
                    if (400..<500).contains(statusCode) { throw PermanentFailure(underlying: failure) }
                    throw failure
                }

                return try JSONDecoder().decode(T.self, from: data)
            } catch let permanent as PermanentFailure {
                throw permanent.underlying
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? CallHistoryError.invalidResponse
    }

    // MARK: - STALK-255 Tasks API (build 157)

    private struct TasksListResponse: Decodable {
        let tasks: [CreatedTask]
    }

    private struct ProjectsResponse: Decodable {
        let projects: [TrackItProject]
    }

    private struct CreateTaskResponse: Decodable {
        let task: CreatedTask
        let idempotent: Bool?
    }

    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/recording/tasks/\(egressId)"), resolvingAgainstBaseURL: false)
        if refresh {
            components?.queryItems = [URLQueryItem(name: "refresh", value: "1")]
        }
        guard let url = components?.url else { throw CallHistoryError.invalidResponse }
        let resp: TasksListResponse = try await performAuthenticatedRequest(url: url, method: "GET")
        return resp.tasks
    }

    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask {
        let url = baseURL.appendingPathComponent("api/recording/tasks/create")
        var body: [String: Any] = [
            "egressId": egressId,
            "topicIndex": topicIndex,
            "taskIndex": taskIndex,
            "projectId": projectId
        ]
        if let overrideText, !overrideText.isEmpty {
            body["text"] = overrideText
        }
        let resp: CreateTaskResponse = try await performAuthenticatedRequest(url: url, method: "POST", jsonBody: body)
        return resp.task
    }

    func searchTrackItProjects(query: String) async throws -> [TrackItProject] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/recording/trackit/projects"), resolvingAgainstBaseURL: false)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        }
        guard let url = components?.url else { throw CallHistoryError.invalidResponse }
        let resp: ProjectsResponse = try await performAuthenticatedRequest(url: url, method: "GET")
        return resp.projects
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
