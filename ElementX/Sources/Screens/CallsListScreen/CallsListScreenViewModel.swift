//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

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
    private var meetingsService: MeetingsService?

    /// Кэш записей с сервера для быстрого доступа по roomID
    private var recordingsCache: [String: CallHistoryAPIItem] = [:]

    /// Set of recording IDs that have been listened to (persisted)
    private var listenedRecordingIDs: Set<String> = []
    /// Cache of resolved room data (contactId → avatar, name, participants)
    private var resolvedRoomData: [String: ResolvedRoomInfo] = [:]

    private struct ResolvedRoomInfo {
        var contactName: String?
        var avatarURL: URL?
        var participantCount: Int?
        var participantAvatarURLs: [URL]?
    }

    private static let listenedCacheKey = "listened-recording-ids"

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
        loadListenedRecordingIDs()
        setupMeetingsService()

        // Load all data sources once, then build list
        loadAllCallData()

        // Subscribe to local changes for future updates only (new calls while app is open)
        setupLocalHistorySubscription()
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
            initialLoadDone = false
            loadAllCallData()
            Task { await meetingsService?.fetchMeetings() }
        case .rsvpMeeting(let meetingId, let response):
            handleRSVP(meetingId: meetingId, response: response)
        case .joinMeeting(let meeting):
            if let roomId = meeting.matrixRoomId {
                actionsSubject.send(.startCall(userId: roomId))
            }
        }
    }

    // MARK: - Initial Data Load

    private var initialLoadDone = false

    /// Load all 3 data sources, then build list once
    private func loadAllCallData() {
        Task { [weak self] in
            guard let self else { return }

            // 1. Server recordings
            let currentUserID = userSession.clientProxy.userID
            if let service = callHistoryService {
                do {
                    let recordings = try await service.fetchRecordings(currentUserID: currentUserID)
                    await MainActor.run { self.serverRecordings = recordings }
                    await ServiceLocator.shared.cacheService?.save(recordings, forKey: Self.recordingsCacheKey, ttl: Self.recordingsCacheTTL)
                } catch {
                    // Try cache
                    if let cached = await ServiceLocator.shared.cacheService?.load([CallHistoryItem].self, forKey: Self.recordingsCacheKey) {
                        await MainActor.run { self.serverRecordings = cached }
                    }
                }
            }

            // 2. Room event calls (parallel would be ideal but sequential is simpler)
            await self.loadCallEventsFromRoomsSync()

            // 3. Build final list with local + server + room events
            await MainActor.run {
                let localCalls = self.localCallHistoryService.getAllCalls()
                self.initialLoadDone = true
                self.updateCallHistoryFromLocal(localCalls)
            }
        }
    }

    // MARK: - Local History Subscription

    private func setupLocalHistorySubscription() {
        localCallHistoryService.callHistoryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] localCalls in
                guard let self, self.initialLoadDone else { return }
                self.updateCallHistoryFromLocal(localCalls)
            }
            .store(in: &callsCancellables)
    }

    /// Кэш записей с сервера (egressId -> recording info)
    private var serverRecordings: [CallHistoryItem] = []

    private func updateCallHistoryFromLocal(_ localCalls: [LocalCallHistoryItem]) {
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
        if state.callHistory.map(\.id) != calls.map(\.id) || state.isLoading {
            state.callHistory = calls
            applyListenedStatus()
        }
        state.isLoading = false

        // Resolve avatars for rooms not yet cached
        let unresolvedRoomIDs = Set(calls.map(\.contactId)).subtracting(resolvedRoomData.keys)
        if !unresolvedRoomIDs.isEmpty {
            resolveAvatars()
        }
    }

    /// Resolves avatar URLs and participant info for call history items from Matrix room data
    private func resolveAvatars() {
        let ownUserID = userSession.clientProxy.userID
        // Take a snapshot to work on off-main-thread
        let snapshot = state.callHistory
        Task {
            var items = snapshot
            var changed = false

            for i in items.indices {
                let roomID = items[i].contactId
                guard let roomProxyType = await userSession.clientProxy.roomForIdentifier(roomID),
                      case .joined(let roomProxy) = roomProxyType else { continue }

                let info = roomProxy.infoPublisher.value
                let memberCount = Int(info.activeMembersCount)

                if memberCount != items[i].participantCount {
                    items[i].participantCount = memberCount
                    changed = true
                }

                // Resolve room name for calls with default name
                let currentName = items[i].contactName
                if currentName == SL10n.callDefault || currentName == SL10n.callsVideoCall {
                    if let roomName = info.displayName, !roomName.isEmpty, roomName != "Empty Room" {
                        items[i].contactName = roomName
                        changed = true
                    }
                }

                if memberCount > 2 {
                    if let members = await roomProxy.members() {
                        let otherMembers = members.filter { $0.userID != ownUserID }
                        items[i].participantAvatarURLs = otherMembers.compactMap(\.avatarURL)
                        let memberNames = otherMembers.compactMap(\.displayName)
                        if !memberNames.isEmpty, items[i].contactName == SL10n.callDefault || items[i].contactName == SL10n.callsVideoCall {
                            items[i].contactName = memberNames.count <= 2
                                ? memberNames.joined(separator: ", ")
                                : "\(memberNames.prefix(2).joined(separator: ", ")) +\(memberNames.count - 2)"
                        }
                        changed = true
                    }
                } else {
                    if items[i].avatarURL == nil {
                        let resolvedURL: URL? = switch info.avatar {
                        case .heroes(let heroes) where heroes.count == 1: heroes[0].avatarURL
                        case .room(_, _, let url): url
                        case .space(_, _, let url): url
                        default: nil
                        }
                        if let resolvedURL {
                            items[i].avatarURL = resolvedURL
                            changed = true
                        }
                    }
                }
            }

            // Save to cache + single batch UI update
            if changed {
                await MainActor.run {
                    for item in items {
                        self.resolvedRoomData[item.contactId] = ResolvedRoomInfo(contactName: item.contactName,
                                                                                 avatarURL: item.avatarURL,
                                                                                 participantCount: item.participantCount,
                                                                                 participantAvatarURLs: item.participantAvatarURLs)
                    }
                    self.state.callHistory = items
                }
            }
        }
    }

    /// Находит запись с сервера, соответствующую локальному звонку
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

        // Проверяем близость по времени (в пределах 5 минут)
        let timeDiff = abs(recording.timestamp.timeIntervalSince(localCall.startedAt))
        let timeMatches = timeDiff < 300 // 5 минут

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
            if timeDiff < 30 {
                return true
            }
        }

        return false
    }

    // MARK: - Call Events from Matrix Rooms

    /// Fetch call history from Matrix room events (call.member).
    /// This covers calls WITHOUT recordings that wouldn't appear from the recording API.
    /// Async version that merges room event calls into serverRecordings without triggering UI update
    private func loadCallEventsFromRoomsSync() async {
        let homeserver = userSession.clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ownUserID = userSession.clientProxy.userID
        let concreteProxy = userSession.clientProxy as? ClientProxy

        await concreteProxy?.forceTokenRefresh()
        guard let token = try? concreteProxy?.matrixAccessToken() else { return }

        let summaries = userSession.clientProxy.roomSummaryProvider.roomListPublisher.value
        let callRoomIDs = summaries.filter { $0.activeMembersCount <= 10 }.map(\.id)

        var callEvents: [CallHistoryItem] = []
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)

        for roomID in callRoomIDs {
            guard let events = await fetchCallMemberEvents(roomID: roomID, homeserver: homeserver, accessToken: token) else { continue }
            guard !events.isEmpty else { continue }
            let calls = extractCallSessions(events, roomID: roomID, ownUserID: ownUserID, cutoffDate: thirtyDaysAgo, sessionGapMs: 60000)
            callEvents.append(contentsOf: calls)
        }

        await MainActor.run {
            for call in callEvents {
                let alreadyExists = serverRecordings.contains { existing in
                    existing.contactId == call.contactId &&
                        abs(existing.timestamp.timeIntervalSince(call.timestamp)) < 300
                }
                if !alreadyExists {
                    serverRecordings.append(call)
                }
            }
        }
    }

    private func loadCallEventsFromRooms() {
        let homeserver = userSession.clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ownUserID = userSession.clientProxy.userID
        let concreteProxy = userSession.clientProxy as? ClientProxy

        MXLog.info("📞 loadCallEventsFromRooms: starting... (proxy: \(concreteProxy != nil))")

        Task {
            // Force token refresh before fetching (MAS tokens expire every 15 min)
            await concreteProxy?.forceTokenRefresh()

            guard let token = try? concreteProxy?.matrixAccessToken() else {
                MXLog.error("📞 loadCallEventsFromRooms: no access token after refresh")
                return
            }

            // Get rooms from SDK room list
            let summaries = userSession.clientProxy.roomSummaryProvider.roomListPublisher.value
            // Only check DM rooms and small group rooms (where calls happen)
            let callRoomIDs = summaries.filter { $0.activeMembersCount <= 10 }.map(\.id)

            MXLog.info("📞 Loading call events from \(callRoomIDs.count) rooms")

            // Debug: write room scan info
            var scanDebug = ["ROOMS SCAN: \(callRoomIDs.count) rooms, homeserver=\(homeserver), hasToken=\(token.prefix(10))...\n"]

            var callEvents: [CallHistoryItem] = []
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
            let sessionGapMs = 60000 // Same as web: 60s gap = new call session

            for roomID in callRoomIDs {
                guard let events = await fetchCallMemberEvents(roomID: roomID, homeserver: homeserver, accessToken: token) else {
                    scanDebug.append("  \(roomID.prefix(30)): FAILED (nil)\n")
                    continue
                }
                if events.isEmpty {
                    continue
                }
                scanDebug.append("  \(roomID.prefix(30)): \(events.count) events\n")
                // Dump first 3 events for debug
                for e in events.prefix(3) {
                    let ts = e["origin_server_ts"] as? Int ?? 0
                    let sender = e["sender"] as? String ?? "?"
                    let content = e["content"] as? [String: Any] ?? [:]
                    let memberships = content["memberships"] as? [[String: Any]] ?? []
                    let application = content["application"] as? String
                    scanDebug.append("    ts=\(ts) sender=\(sender.prefix(20)) memberships=\(memberships.count) app=\(application ?? "nil") keys=\(content.keys.sorted())\n")
                }

                // Group into call sessions (like web's extractCallSessions)
                let calls = extractCallSessions(events, roomID: roomID, ownUserID: ownUserID, cutoffDate: thirtyDaysAgo, sessionGapMs: sessionGapMs)
                callEvents.append(contentsOf: calls)
            }
            try? scanDebug.joined().write(toFile: NSTemporaryDirectory() + "stalk_roomscan_debug.txt", atomically: true, encoding: .utf8)

            MXLog.info("📞 Found \(callEvents.count) calls from room events")
            // Debug: write room event calls to tmp file
            let df2 = DateFormatter(); df2.dateFormat = "yyyy-MM-dd HH:mm"
            var debugLines2 = ["ROOM EVENT CALLS: \(callEvents.count)\n"]
            for c in callEvents.sorted(by: { $0.timestamp > $1.timestamp }) {
                debugLines2.append("\(c.id.prefix(35)) | \(df2.string(from: c.timestamp)) | \(c.contactName)\n")
            }
            try? debugLines2.joined().write(toFile: NSTemporaryDirectory() + "stalk_roomcalls_debug.txt", atomically: true, encoding: .utf8)

            await MainActor.run {
                // Merge with existing — add only calls that don't match server recordings
                for call in callEvents {
                    let alreadyExists = serverRecordings.contains { existing in
                        existing.contactId == call.contactId &&
                            abs(existing.timestamp.timeIntervalSince(call.timestamp)) < 300
                    }
                    if !alreadyExists {
                        serverRecordings.append(call)
                    }
                }
                let localCalls = localCallHistoryService.getAllCalls()
                updateCallHistoryFromLocal(localCalls)
            }
        }
    }

    /// Fetch call.member events from a room via Matrix API
    private func fetchCallMemberEvents(roomID: String, homeserver: String, accessToken: String) async -> [[String: Any]]? {
        guard let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }

        let filterJSON = "{\"types\":[\"org.matrix.msc3401.call.member\"]}"
        guard let encodedFilter = filterJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(homeserver)/_matrix/client/v3/rooms/\(encodedRoomID)/messages?dir=b&limit=100&filter=\(encodedFilter)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else { return nil }

        if httpResponse.statusCode == 401 {
            MXLog.info("📞 fetchCallMemberEvents: 401 for room \(roomID.prefix(20))")
            return nil
        }

        guard httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chunk = json["chunk"] as? [[String: Any]] else { return nil }

        return chunk
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

            sessions.append(CallHistoryItem(id: "rtc_\(roomID.hashValue)_\(sessionStart)",
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

    // MARK: - Server Recordings

    private static let recordingsCacheKey = "recordings-list"
    private static let recordingsCacheTTL: TimeInterval = 300 // 5 minutes

    private func loadRecordingsFromServer(forceRefresh: Bool = false) {
        // 1. Always show cache instantly (for fast UI — no spinner)
        Task {
            if let cached = await ServiceLocator.shared.cacheService?.load([CallHistoryItem].self, forKey: Self.recordingsCacheKey) {
                await MainActor.run {
                    serverRecordings = cached
                    let localCalls = localCallHistoryService.getAllCalls()
                    updateCallHistoryFromLocal(localCalls)
                    MXLog.info("📞 Loaded \(cached.count) recordings from cache")
                }
            }
        }

        // 2. Always fetch from server to check for updates (new recordings from other devices etc.)
        guard let callHistoryService else {
            MXLog.info("📞 No call history service configured, skipping server fetch")
            return
        }

        MXLog.info("📞 Fetching recordings from server...")

        let currentUserID = userSession.clientProxy.userID
        Task {
            do {
                let recordings = try await callHistoryService.fetchRecordings(currentUserID: currentUserID)
                MXLog.info("📞 Updated \(recordings.count) recordings from server")
                // Debug: write recordings to tmp file for inspection
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
                var debugLines = ["SERVER RECORDINGS: \(recordings.count)\n"]
                for r in recordings {
                    debugLines.append("\(r.id.prefix(25)) | \(df.string(from: r.timestamp)) | \(r.contactName)\n")
                }
                try? debugLines.joined().write(toFile: NSTemporaryDirectory() + "stalk_recordings_debug.txt", atomically: true, encoding: .utf8)

                // Save to cache
                await ServiceLocator.shared.cacheService?.save(recordings, forKey: Self.recordingsCacheKey, ttl: Self.recordingsCacheTTL)

                await MainActor.run {
                    serverRecordings = recordings
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

    /// Invalidate recordings cache (call after ending a call)
    static func invalidateRecordingsCache() {
        Task {
            await ServiceLocator.shared.cacheService?.invalidate(forKey: recordingsCacheKey)
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (meetings: [Meeting]) in
                self?.state.meetings = meetings
                self?.state.isMeetingsLoading = false
            }
            .store(in: &callsCancellables)

        state.isMeetingsLoading = true
        Task { await meetingsService?.fetchMeetings() }
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
        MXLog.info("📞 FETCH: URL = \(url.absoluteString)")

        // Retry up to 3 times, refreshing token on 401
        var lastError: Error?
        for attempt in 1...3 {
            // Get fresh token each attempt (SDK may have refreshed it)
            let token = (try? accessTokenProvider?()) ?? accessToken

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 30.0

            do {
                MXLog.info("📞 FETCH: Attempt \(attempt)...")
                let (data, response) = try await urlSession.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                MXLog.info("📞 FETCH: HTTP \(statusCode), data size: \(data.count)")

                // On 401, wait for SDK to refresh token and retry
                if statusCode == 401, attempt < 3 {
                    MXLog.info("📞 FETCH: 401 — forcing SDK token refresh...")
                    await forceTokenRefresh?()
                    continue
                }

                return try processResponse(data: data, response: response, currentUserID: currentUserID, apiBaseURL: baseURL)
            } catch {
                MXLog.error("📞 FETCH: Attempt \(attempt) failed: \(error)")
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? CallHistoryError.invalidResponse
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

    private func performAuthenticatedRequest<T: Decodable>(url: URL, method: String) async throws -> T {
        var lastError: Error?
        for attempt in 1...3 {
            let token = (try? accessTokenProvider?()) ?? accessToken

            var request = URLRequest(url: url)
            request.httpMethod = method
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
                    throw CallHistoryError.serverError("HTTP \(statusCode)")
                }

                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? CallHistoryError.invalidResponse
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
