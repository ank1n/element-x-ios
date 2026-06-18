//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AnalyticsEvents
import Combine
import MatrixRustSDK
import os
import SwiftUI

typealias HomeScreenViewModelType = StateStoreViewModel<HomeScreenViewState, HomeScreenViewAction>

class HomeScreenViewModel: HomeScreenViewModelType, HomeScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let analyticsService: AnalyticsService
    private let appSettings: AppSettings
    private let notificationManager: NotificationManagerProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let roomSummaryProvider: RoomSummaryProviderProtocol?
    private lazy var messageSearchService = MessageSearchService(homeserverURL: userSession.clientProxy.homeserver,
                                                                 accessTokenProvider: { [weak self] in try self?.userSession.clientProxy.matrixAccessToken() ?? "" })

    /// STMOB-244: room IDs of the user's meetings (from meetings-api). Meeting rooms carry the
    /// `io.stalk.meeting` state marker and are hidden from the main Chats list, surfaced only under
    /// the dedicated "Meetings" filter — mirroring the web client. The rust SDK doesn't expose the
    /// marker on the room list, so meetings-api (`GET /api/meetings`, full set incl. past) is the
    /// source of truth instead.
    private var meetingRoomIDs: Set<String> = []
    private lazy var meetingsService: MeetingsService = {
        let homeserver = userSession.clientProxy.homeserver
        let withScheme = homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"
        let baseURL: String
        if let url = URL(string: withScheme), let scheme = url.scheme, let host = url.host {
            baseURL = "\(scheme)://\(host)"
        } else {
            baseURL = withScheme
        }
        let clientProxy = userSession.clientProxy
        let concreteProxy = clientProxy as? ClientProxy
        return MeetingsService(homeserver: baseURL,
                               accessTokenProvider: { try clientProxy.matrixAccessToken() },
                               forceTokenRefresh: { await concreteProxy?.forceTokenRefresh() })
    }()

    private var messageSearchTask: Task<Void, Never>?
    
    private var actionsSubject: PassthroughSubject<HomeScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<HomeScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol,
         selectedRoomPublisher: CurrentValuePublisher<String?, Never>,
         appSettings: AppSettings,
         analyticsService: AnalyticsService,
         notificationManager: NotificationManagerProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.userSession = userSession
        self.analyticsService = analyticsService
        self.appSettings = appSettings
        self.notificationManager = notificationManager
        self.userIndicatorController = userIndicatorController
        
        roomSummaryProvider = userSession.clientProxy.roomSummaryProvider
        
        super.init(initialViewState: .init(userID: userSession.clientProxy.userID,
                                           bindings: .init(filtersState: .init(appSettings: appSettings))),
                   mediaProvider: userSession.mediaProvider)
        
        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }

                // sTalk: Don't show security banners — setupAutoRecovery() handles this automatically
                state.securityBannerMode = .none
                state.requiresExtraAccountSetup = false
            }
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .filter { state in
                state.verificationState != .unknown
                    && state.recoveryState != .settingUp
                    && state.recoveryState != .unknown
            }
            .sink { [weak self] state in
                guard let self else { return }
                
                self.analyticsService.updateUserProperties(AnalyticsEvent.newVerificationStateUserProperty(verificationState: state.verificationState, recoveryState: state.recoveryState))
                self.analyticsService.trackSessionSecurityState(state)
            }
            .store(in: &cancellables)
        
        selectedRoomPublisher
            .weakAssign(to: \.state.selectedRoomID, on: self)
            .store(in: &cancellables)
        
        appSettings.$hideUnreadMessagesBadge
            .sink { [weak self] _ in self?.updateRooms() }
            .store(in: &cancellables)
        
        appSettings.$seenInvites
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
        
        appSettings.$hasSeenNewSoundBanner
            .sink { [weak self] hasSeenNewSoundBanner in
                self?.state.shouldShowNewSoundBanner = !hasSeenNewSoundBanner
            }
            .store(in: &cancellables)
        
        userSession.clientProxy.hideInviteAvatarsPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.hideInviteAvatars, on: self)
            .store(in: &cancellables)
        
        Task {
            state.reportRoomEnabled = await userSession.clientProxy.isReportRoomSupported
        }
        
        let isSearchFieldFocused = context.$viewState.map(\.bindings.isSearchFieldFocused)
        let searchQuery = context.$viewState.map(\.bindings.searchQuery)
        let activeFilters = context.$viewState.map(\.bindings.filtersState.activeFilters)
        isSearchFieldFocused
            .combineLatest(searchQuery, activeFilters)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] isSearchFieldFocused, _, _ in
                guard let self else { return }
                // isSearchFieldFocused` is sometimes turning to true after cancelling the search. So to be extra sure we are updating the values correctly we read them directly in the next run loop, and we add a small delay if the value has changed
                let delay = isSearchFieldFocused == self.context.viewState.bindings.isSearchFieldFocused ? 0.0 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.updateFilter()
                }
            }
            .store(in: &cancellables)
        
        // Message content search is triggered from view via .onChange(of: searchQuery)

        setupRoomListSubscriptions()
        setupArchiveSubscription()
        setupMeetingRoomIDsRefresh()

        updateRooms()

        state.recentSearchQueries = appSettings.recentSearchQueries
    }
    
    // MARK: - Public
    
    override func process(viewAction: HomeScreenViewAction) {
        switch viewAction {
        case .selectRoom(let roomIdentifier):
            saveSearchQueryIfNeeded()
            state.bindings.searchQuery = ""
            state.bindings.isSearchFieldFocused = false
            actionsSubject.send(.presentRoom(roomIdentifier: roomIdentifier))
        case .showRoomDetails(let roomIdentifier):
            actionsSubject.send(.presentRoomDetails(roomIdentifier: roomIdentifier))
        case .leaveRoom(let roomIdentifier):
            startLeaveRoomProcess(roomID: roomIdentifier)
        case .confirmLeaveRoom(let roomIdentifier):
            Task { await leaveRoom(roomID: roomIdentifier) }
        case .reportRoom(let roomIdentifier):
            actionsSubject.send(.presentReportRoom(roomIdentifier: roomIdentifier))
        case .showSettings:
            actionsSubject.send(.presentSettingsScreen)
        case .setupRecovery:
            actionsSubject.send(.presentSecureBackupSettings)
        case .confirmRecoveryKey:
            actionsSubject.send(.presentRecoveryKeyScreen)
        case .resetEncryption:
            actionsSubject.send(.presentEncryptionResetScreen)
        case .skipRecoveryKeyConfirmation:
            state.securityBannerMode = .dismissed
        case .dismissNewSoundBanner:
            appSettings.hasSeenNewSoundBanner = true
        case .updateVisibleItemRange(let range):
            roomSummaryProvider?.updateVisibleRange(range)
        case .startChat:
            actionsSubject.send(.presentStartChatScreen)
        case .globalSearch:
            actionsSubject.send(.presentGlobalSearch)
        case .messageSearch:
            actionsSubject.send(.presentMessageSearch)
        case .searchQueryChanged(let query):
            performMessageSearch(query: query)
        case .markRoomAsUnread(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(true) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                case .failure(let error):
                    MXLog.error("Failed marking room \(roomIdentifier) as unread with error: \(error)")
                }
            }
        case .markRoomAsRead(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(false) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                    
                    if case .failure(let error) = await roomProxy.markAsRead(receiptType: appSettings.sharePresence ? .read : .readPrivate) {
                        MXLog.error("Failed marking room \(roomIdentifier) as read with error: \(error)")
                    }
                case .failure(let error):
                    MXLog.error("Failed flagging room \(roomIdentifier) as read with error: \(error)")
                }
            }
        case .markRoomAsFavourite(let roomIdentifier, let isFavourite):
            Task {
                await markRoomAsFavourite(roomIdentifier, isFavourite: isFavourite)
            }
        case .toggleMuteRoom(let roomIdentifier, let isMuted):
            Task {
                do {
                    if isMuted {
                        try await userSession.clientProxy.notificationSettings.setNotificationMode(roomId: roomIdentifier, mode: .allMessages)
                    } else {
                        try await userSession.clientProxy.notificationSettings.setNotificationMode(roomId: roomIdentifier, mode: .mute)
                    }
                } catch {
                    MXLog.error("Failed toggling mute for room \(roomIdentifier): \(error)")
                }
            }
        case .archiveRoom(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                if case .failure(let error) = await roomProxy.flagAsLowPriority(true) {
                    MXLog.error("Failed archiving room \(roomIdentifier): \(error)")
                    return
                }
                // Mute notifications for archived room
                do {
                    try await userSession.clientProxy.notificationSettings.setNotificationMode(roomId: roomIdentifier, mode: .mute)
                } catch {
                    MXLog.error("Failed muting archived room \(roomIdentifier): \(error)")
                }
                // Show undo toast
                let indicatorID = "archiveUndo-\(roomIdentifier)"
                let indicator = UserIndicator(id: indicatorID,
                                              type: .toast,
                                              title: SL10n.chatArchived,
                                              iconName: "archivebox",
                                              actionTitle: SL10n.actionUndo,
                                              action: { [weak self] in
                                                  guard let self else { return }
                                                  self.userIndicatorController.retractIndicatorWithId(indicatorID)
                                                  Task {
                                                      await self.unarchiveRoom(roomIdentifier: roomIdentifier)
                                                  }
                                              })
                userIndicatorController.submitIndicator(indicator)
            }
        case .openArchive:
            actionsSubject.send(.presentArchive)
        case .acceptInvite(let roomIdentifier):
            Task {
                await acceptInvite(roomID: roomIdentifier)
            }
        case .declineInvite(let roomIdentifier):
            Task { await showDeclineInviteConfirmationAlert(roomID: roomIdentifier) }
        case .selectRecentSearch(let query):
            state.bindings.searchQuery = query
        case .clearRecentSearches:
            appSettings.recentSearchQueries = []
            state.recentSearchQueries = []
        }
    }
    
    // perphery: ignore - used in release mode
    func presentCrashedLastRunAlert() {
        // Delay setting the alert otherwise it automatically gets dismissed. Same as the force logout one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                      title: L10n.crashDetectionDialogContent(InfoPlistReader.main.bundleDisplayName),
                                                      primaryButton: .init(title: L10n.actionNo, action: nil),
                                                      secondaryButton: .init(title: L10n.actionYes) { [weak self] in
                                                          self?.actionsSubject.send(.presentFeedbackScreen)
                                                      })
        }
    }
    
    // MARK: - Private
    
    private func saveSearchQueryIfNeeded() {
        let query = state.bindings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var recent = appSettings.recentSearchQueries
        recent.removeAll { $0 == query }
        recent.insert(query, at: 0)
        if recent.count > 5 { recent = Array(recent.prefix(5)) }
        appSettings.recentSearchQueries = recent
        state.recentSearchQueries = recent
    }

    private func performMessageSearch(query: String) {
        messageSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.messageSearchResults = []
            state.isMessageSearchLoading = false
            return
        }

        // Server-side search doesn't work for E2EE rooms (Synapse can't search encrypted content)
        // Message search is available per-room via 🔍 button in room toolbar (local with pagination)
    }

    private func updateFilter() {
        if state.shouldHideRoomList {
            roomSummaryProvider?.setFilter(.excludeAll)
        } else {
            if state.bindings.isSearchFieldFocused {
                roomSummaryProvider?.setFilter(.search(query: state.bindings.searchQuery))
            } else {
                roomSummaryProvider?.setFilter(.all(filters: state.bindings.filtersState.activeFilters.set))
            }
        }
    }
    
    private func setupRoomListSubscriptions() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        analyticsService.signpost.beginFirstRooms()
                
        roomSummaryProvider.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                
                updateRoomListMode(with: state)
            }
            .store(in: &cancellables)
        
        roomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
    }
    
    private func setupArchiveSubscription() {
        let archiveProvider = userSession.clientProxy.alternateRoomSummaryProvider
        // Temporarily set filter to count archived rooms
        archiveProvider.setFilter(.all(filters: [.lowPriority]))

        archiveProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms in
                guard let self else { return }
                state.archiveRoomCount = rooms.count
                let names = rooms.prefix(3).map(\.name)
                state.archivePreviewText = names.joined(separator: ", ")
                if rooms.count > 3 {
                    state.archivePreviewText += String(format: NSLocalizedString("stalk_home_archive_and_more", tableName: "Localizable", value: " и ещё %d", comment: "Archive preview: and N more"), rooms.count - 3)
                }
            }
            .store(in: &cancellables)
    }

    /// STMOB-244: keep `meetingRoomIDs` fresh from meetings-api so meeting rooms stay hidden from
    /// the main Chats list. Refreshed on launch and on a light interval (meetings change rarely).
    private func setupMeetingRoomIDsRefresh() {
        refreshMeetingRoomIDs()
        Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshMeetingRoomIDs() }
            .store(in: &cancellables)
    }

    private func refreshMeetingRoomIDs() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let meetings = try await meetingsService.fetchMeetingsList()
                // matrix_room_id is null for meetings whose room hasn't been created yet (lazy on
                // first join) — skip those, there's nothing to hide.
                let ids = Set(meetings.compactMap(\.matrixRoomId).filter { !$0.isEmpty })
                await MainActor.run {
                    guard ids != self.meetingRoomIDs else { return }
                    self.meetingRoomIDs = ids
                    self.updateRooms()
                }
            } catch {
                MXLog.warning("sTalk STMOB-244: failed loading meeting room IDs for Chats filter: \(error)")
            }
        }
    }

    private func updateRoomListMode(with roomSummaryProviderState: RoomSummaryProviderState) {
        let isLoadingData = !roomSummaryProviderState.isLoaded
        let hasNoRooms = roomSummaryProviderState.isLoaded && roomSummaryProviderState.totalNumberOfRooms == 0
        
        var roomListMode = state.roomListMode
        if isLoadingData {
            roomListMode = .skeletons
        } else if hasNoRooms {
            roomListMode = .empty
        } else {
            roomListMode = .rooms
        }
        
        guard roomListMode != state.roomListMode else {
            return
        }
        
        if roomListMode == .rooms, state.roomListMode == .skeletons {
            analyticsService.signpost.endFirstRooms()
        }
        
        state.roomListMode = roomListMode
        
        MXLog.info("Received room summary provider update, setting view room list mode to \"\(state.roomListMode)\"")
        // Delay user profile detail loading until after the initial room list loads
        if roomListMode == .rooms {
            Task {
                await self.userSession.clientProxy.loadUserAvatarURL()
                await self.userSession.clientProxy.loadUserDisplayName()
            }
        }
    }
        
    private func updateRooms() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        var rooms = [HomeScreenRoom]()
        let seenInvites = appSettings.seenInvites

        // STMOB-244: meeting rooms are hidden from the main Chats list and only shown under the
        // dedicated "Meetings" filter (mirrors the web client). Skip the filtering while searching
        // so search can still find meeting rooms.
        let meetingsFilterActive = state.bindings.filtersState.isFilterActive(.meetings)
        // When the Meetings filter is active always apply it (shows only meeting rooms, possibly
        // empty). Otherwise only bother filtering when there are meeting rooms to hide.
        let applyMeetingFilter = !state.bindings.isSearchFieldFocused && (meetingsFilterActive || !meetingRoomIDs.isEmpty)

        for summary in roomSummaryProvider.roomListPublisher.value {
            if applyMeetingFilter {
                let isMeetingRoom = meetingRoomIDs.contains(summary.id)
                if meetingsFilterActive {
                    if !isMeetingRoom { continue }
                } else if isMeetingRoom {
                    continue
                }
            }
            let room = HomeScreenRoom(summary: summary,
                                      hideUnreadMessagesBadge: appSettings.hideUnreadMessagesBadge,
                                      seenInvites: seenInvites)
            rooms.append(room)
        }
        
        // Invites and knocks first, then regular rooms
        let sorted = rooms.sorted { a, b in
            let aIsInvite: Bool = {
                if case .invite = a.type { return true }
                if case .knock = a.type { return true }
                return false
            }()
            let bIsInvite: Bool = {
                if case .invite = b.type { return true }
                if case .knock = b.type { return true }
                return false
            }()
            if aIsInvite != bIsInvite { return aIsInvite }
            return false // preserve server order within group
        }
        state.rooms = sorted

        // STMOB-103 build 120: обновляем polling presence для DM-собеседников.
        updatePresencePolling()
    }

    // MARK: - DM Presence (STMOB-103 build 120)

    private var dmPresenceServiceSubscribed = false

    private func setupDMPresenceService() {
        // Build 125: используем shared PresenceService из AppCoordinator вместо
        // локального instance. Гарантирует sync между HomeScreen list и RoomScreen
        // header.
        guard !dmPresenceServiceSubscribed, let service = AppCoordinator.sharedPresenceService else { return }
        dmPresenceServiceSubscribed = true
        service.presenceSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] map in
                self?.state.dmPresence = map
            }
            .store(in: &cancellables)
    }

    private func updatePresencePolling() {
        setupDMPresenceService()
        guard let service = AppCoordinator.sharedPresenceService else { return }
        let dmUserIDs = Array(Set(state.rooms.compactMap(\.dmUserID)))
        // Build 125: merge с existing polling — НЕ перезаписываем (RoomScreen
        // тоже мог добавить userID собеседника).
        let merged = Array(Set(service.currentUserIDs).union(dmUserIDs))
        guard !merged.isEmpty else { return }
        if service.currentUserIDs.isEmpty {
            service.startPolling(userIDs: merged)
        } else if Set(service.currentUserIDs) != Set(merged) {
            service.updatePollingUserIDs(merged)
            Task { await service.fetchPresence(for: merged) }
        }
    }

    private func markRoomAsFavourite(_ roomID: String, isFavourite: Bool) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            MXLog.error("Failed retrieving room for identifier: \(roomID)")
            return
        }
        
        switch await roomProxy.flagAsFavourite(isFavourite) {
        case .success:
            analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuFavouriteToggle)
        case .failure(let error):
            MXLog.error("Failed marking room \(roomID) as favourite: \(isFavourite) with error: \(error)")
        }
    }
    
    private func unarchiveRoom(roomIdentifier: String) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
            MXLog.error("Failed retrieving room for unarchive: \(roomIdentifier)")
            return
        }
        if case .failure(let error) = await roomProxy.flagAsLowPriority(false) {
            MXLog.error("Failed unarchiving room \(roomIdentifier): \(error)")
            return
        }
        do {
            try await userSession.clientProxy.notificationSettings.restoreDefaultNotificationMode(roomId: roomIdentifier)
        } catch {
            MXLog.error("Failed restoring notifications for room \(roomIdentifier): \(error)")
        }
    }

    private static let leaveRoomLoadingID = "LeaveRoomLoading"
    
    private func startLeaveRoomProcess(roomID: String) {
        Task {
            defer {
                userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
            }
            userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLoading, persistent: true))
            
            guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
                state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
                return
            }
            
            guard roomProxy.infoPublisher.value.joinedMembersCount > 1 else {
                state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID,
                                                                       isDM: roomProxy.isDirectOneToOneRoom,
                                                                       state: roomProxy.infoPublisher.value.isPrivate ?? true ? .empty : .public)
                return
            }
            
            if !roomProxy.isDirectOneToOneRoom {
                if case let .success(ownMember) = await roomProxy.getMember(userID: roomProxy.ownUserID),
                   ownMember.role.isOwner {
                    await roomProxy.updateMembers()
                    var isLastOwner = true
                    for member in roomProxy.membersPublisher.value where member.userID != roomProxy.ownUserID && member.membership == .join {
                        if member.role.isOwner {
                            isLastOwner = false
                            break
                        }
                    }
                    
                    if isLastOwner {
                        state.bindings.alertInfo = .init(id: UUID(),
                                                         title: L10n.leaveRoomAlertSelectNewOwnerTitle,
                                                         message: L10n.leaveRoomAlertSelectNewOwnerSubtitle,
                                                         primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                                         secondaryButton: .init(title: L10n.leaveRoomAlertSelectNewOwnerAction, role: .destructive) { [weak self] in
                                                             self?.actionsSubject.send(.transferOwnership(roomIdentifier: roomID))
                                                         })
                        return
                    }
                }
            }
            
            state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID, isDM: roomProxy.isDirectOneToOneRoom, state: roomProxy.infoPublisher.value.isPrivate ?? true ? .private : .public)
        }
    }
    
    private func leaveRoom(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
        }
        userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLeavingRoom, persistent: true))
        
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID),
              case .success = await roomProxy.leaveRoom() else {
            state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
            return
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: UUID().uuidString,
                                                              type: .toast,
                                                              title: L10n.commonCurrentUserLeftRoom,
                                                              iconName: "checkmark"))
        actionsSubject.send(.roomLeft(roomIdentifier: roomID))
    }
    
    // MARK: Invites
    
    private func acceptInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        switch await userSession.clientProxy.joinRoom(roomID, via: []) {
        case .success:
            await finishAcceptInvite(roomProxy: roomProxy)
        case .failure(let error):
            switch error {
            case .invalidInvite:
                displayError(title: L10n.dialogTitleError, message: L10n.errorInvalidInvite)
            default:
                displayError()
            }
        }
    }
    
    private func finishAcceptInvite(roomProxy: InvitedRoomProxyProtocol) async {
        if roomProxy.info.isSpace {
            let spaceService = userSession.clientProxy.spaceService
            
            switch await spaceService.spaceRoomList(spaceID: roomProxy.id) {
            case .success(let spaceRoomListProxy):
                actionsSubject.send(.presentSpace(spaceRoomListProxy))
            case .failure(let error):
                MXLog.error("Failed to get the space room list after accepting invite: \(error)")
                displayError()
                return
            }
        } else {
            actionsSubject.send(.presentRoom(roomIdentifier: roomProxy.id))
        }
        
        analyticsService.trackJoinedRoom(isDM: roomProxy.info.isDirect,
                                         isSpace: roomProxy.info.isSpace,
                                         activeMemberCount: UInt(roomProxy.info.activeMembersCount))
        appSettings.seenInvites.remove(roomProxy.id)
    }
    
    private func showDeclineInviteConfirmationAlert(roomID: String) async {
        guard let room = state.rooms.first(where: { $0.id == roomID }) else {
            displayError()
            return
        }
        
        let roomPlaceholder = room.isDirect ? (room.inviter?.displayName ?? room.name) : room.name
        let title = room.isDirect ? L10n.screenInvitesDeclineDirectChatTitle : L10n.screenInvitesDeclineChatTitle
        let message = room.isDirect ? L10n.screenInvitesDeclineDirectChatMessage(roomPlaceholder) : L10n.screenInvitesDeclineChatMessage(roomPlaceholder)
        
        if await userSession.clientProxy.isReportRoomSupported, let userID = room.inviter?.id {
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: title,
                                             message: message,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionDeclineAndBlock, role: .destructive) { [weak self] in self?.declineAndBlockInvite(userID: userID, roomID: roomID) },
                                             verticalButtons: [.init(title: L10n.actionDecline) { [weak self] in Task { await self?.declineInvite(roomID: room.id) } }])
        } else {
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: title,
                                             message: message,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionDecline, role: .destructive) { [weak self] in Task { await self?.declineInvite(roomID: room.id) } })
        }
    }
    
    private func declineAndBlockInvite(userID: String, roomID: String) {
        actionsSubject.send(.presentDeclineAndBlock(userID: userID, roomID: roomID))
    }
    
    private func declineInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        let result = await roomProxy.rejectInvitation()
        
        switch result {
        case .success:
            await notificationManager.removeDeliveredMessageNotifications(for: roomID) // Normally handled by the room flow, but that's never presented in this case.
            appSettings.seenInvites.remove(roomID)
        case .failure:
            displayError()
        }
    }
    
    private func displayError(title: String? = nil, message: String? = nil) {
        state.bindings.alertInfo = .init(id: UUID(),
                                         title: title ?? L10n.commonError,
                                         message: message ?? L10n.errorUnknown)
    }
}
