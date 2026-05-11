//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import OrderedCollections
import SwiftUI

typealias RoomScreenViewModelType = StateStoreViewModel<RoomScreenViewState, RoomScreenViewAction>

class RoomScreenViewModel: RoomScreenViewModelType, RoomScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let roomProxy: JoinedRoomProxyProtocol
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let userIndicatorController: UserIndicatorControllerProtocol
    private var timelineController: (any TimelineControllerProtocol)?

    private var initialSelectedPinnedEventID: String?
    private let pinnedEventStringBuilder: RoomEventStringBuilder
    
    private var identityPinningViolations = [String: RoomMemberProxyProtocol]()
    private var identityVerificationViolations = [String: RoomMemberProxyProtocol]()
    
    private let actionsSubject: PassthroughSubject<RoomScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<RoomScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var pinnedEventsTimelineItemProvider: TimelineItemProviderProtocol? {
        didSet {
            guard let pinnedEventsTimelineItemProvider else {
                return
            }
            
            buildPinnedEventContents(timelineItems: pinnedEventsTimelineItemProvider.itemProxies)
            pinnedEventsTimelineItemProvider.updatePublisher
                // When pinning or unpinning an item, the timeline might return empty for a short while, so we need to debounce it to prevent weird UI behaviours like the banner disappearing
                .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                .sink { [weak self] updatedItems, _ in
                    guard let self else { return }
                    buildPinnedEventContents(timelineItems: updatedItems)
                }
                .store(in: &cancellables)
        }
    }
    
    init(userSession: UserSessionProtocol,
         roomProxy: JoinedRoomProxyProtocol,
         initialSelectedPinnedEventID: String?,
         ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>,
         appSettings: AppSettings,
         appHooks: AppHooks,
         analyticsService: AnalyticsService,
         userIndicatorController: UserIndicatorControllerProtocol,
         timelineController: (any TimelineControllerProtocol)? = nil) {
        clientProxy = userSession.clientProxy
        self.roomProxy = roomProxy
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.userIndicatorController = userIndicatorController
        self.timelineController = timelineController

        self.initialSelectedPinnedEventID = initialSelectedPinnedEventID
        pinnedEventStringBuilder = .pinnedEventStringBuilder(userID: roomProxy.ownUserID)

        let viewState = RoomScreenViewState(roomTitle: roomProxy.infoPublisher.value.displayName ?? roomProxy.id,
                                            roomAvatar: roomProxy.infoPublisher.value.avatar,
                                            hasOngoingCall: roomProxy.infoPublisher.value.hasRoomCall,
                                            hasSuccessor: roomProxy.infoPublisher.value.successor != nil)
        super.init(initialViewState: appHooks.roomScreenHook.update(viewState),
                   mediaProvider: userSession.mediaProvider)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
        setupSubscriptions(ongoingCallRoomIDPublisher: ongoingCallRoomIDPublisher)
        setupSearchSubscription()

        Task {
            await updateVerificationBadge()
        }
        // STMOB-84 build 141: lazy pin internal users в этой комнате.
        pinDomainTrustMembersLazy()
    }

    override func process(viewAction: RoomScreenViewAction) {
        switch viewAction {
        case .tappedPinnedEventsBanner:
            handleTappedPinnedEventsBanner()
        case .viewAllPins:
            analyticsService.trackInteraction(name: .PinnedMessageBannerViewAllButton)
            actionsSubject.send(.displayPinnedEventsTimeline)
        case .displayRoomDetails:
            actionsSubject.send(.displayRoomDetails)
        case .displayCall:
            actionsSubject.send(.displayCall)
            actionsSubject.send(.removeComposerFocus)
            analyticsService.trackInteraction(name: .MobileRoomCallButton)
        case .displayVoiceCall:
            actionsSubject.send(.displayVoiceCall)
            actionsSubject.send(.removeComposerFocus)
            analyticsService.trackInteraction(name: .MobileRoomCallButton)
        case .footerViewAction(let action):
            switch action {
            case .resolvePinViolation(let userID):
                Task { await resolveIdentityPinningViolation(userID) }
            case .resolveVerificationViolation(let userID):
                Task { await resolveIdentityVerificationViolation(userID) }
            case .dismissHistoryVisibleAlert:
                appSettings.acknowledgedHistoryVisibleRooms.insert(roomProxy.id)
                state.historyVisibleDetails = nil
            }
        case .acceptKnock(let eventID):
            Task { await acceptKnock(eventID: eventID) }
        case .dismissKnockRequests:
            Task { await markAllKnocksAsSeen() }
        case .viewKnockRequests:
            actionsSubject.send(.displayKnockRequests)
        case .displaySuccessorRoom:
            guard let successorID = roomProxy.infoPublisher.value.successor?.roomId else { return }
            let serverNames = roomProxy.knownServerNames(maxCount: 50) // Limit to the same number used by ClientProxy.resolveRoomAlias(_:)
            actionsSubject.send(.displayRoom(roomID: successorID, via: Array(serverNames)))
        case .toggleSearch:
            toggleSearch()
        case .searchNext:
            navigateSearchResult(forward: true)
        case .searchPrevious:
            navigateSearchResult(forward: false)
        }
    }
    
    func stop() {
        // When navigating away from the room, we need to mark the room as fully read.
        // This does not affect the read receipts only the notification count.
        Task { await roomProxy.markAsRead(receiptType: .fullyRead) }
        // Work around QLPreviewController dismissal issues, see the InteractiveQuickLookModifier.
        state.bindings.mediaPreviewViewModel = nil
    }
    
    func timelineHasScrolled(direction: ScrollDirection) {
        state.lastScrollDirection = direction
    }
    
    func setSelectedPinnedEventID(_ eventID: String) {
        state.pinnedEventsBannerState.setSelectedPinnedEventID(eventID)
    }
    
    func displayMediaPreview(_ mediaPreviewViewModel: TimelineMediaPreviewViewModel) {
        mediaPreviewViewModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                state.bindings.mediaPreviewViewModel = nil
            case .displayMessageForwarding(let forwardingItem):
                state.bindings.mediaPreviewViewModel = nil
                // We need a small delay because we need to wait for the media preview to be fully dismissed.
                DispatchQueue.main.asyncAfter(deadline: .now() + TimelineMediaPreviewViewModel.displayMessageForwardingDelay) {
                    self.actionsSubject.send(.displayMessageForwarding(forwardingItem))
                }
            case .viewInRoomTimeline:
                fatalError("\(action) should not be visible on a room preview.")
            }
        }
        .store(in: &cancellables)
        
        state.bindings.mediaPreviewViewModel = mediaPreviewViewModel
    }
    
    // MARK: - Private
    
    private func setupSubscriptions(ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>) {
        appSettings.$knockingEnabled
            .weakAssign(to: \.state.isKnockingEnabled, on: self)
            .store(in: &cancellables)
                
        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)
        
        let identityStatusChangesPublisher = roomProxy.identityStatusChangesPublisher.receive(on: DispatchQueue.main)
        
        Task { [weak self] in
            for await changes in identityStatusChangesPublisher.values {
                guard !Task.isCancelled else {
                    return
                }
                
                await self?.processIdentityStatusChanges(changes)
                await self?.updateVerificationBadge()
            }
        }
        .store(in: &cancellables)
        
        clientProxy.homeserverReachabilityPublisher
            .filter { $0 == .reachable }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupPinnedEventsTimelineItemProviderIfNeeded()
            }
            .store(in: &cancellables)
        
        ongoingCallRoomIDPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ongoingCallRoomID in
                guard let self else { return }
                state.isParticipatingInOngoingCall = ongoingCallRoomID == roomProxy.id
            }
            .store(in: &cancellables)
        
        roomProxy.knockRequestsStatePublisher
            // We only care about unseen requests
            .map { knockRequestsState in
                guard case let .loaded(requests) = knockRequestsState else {
                    return []
                }
                
                return requests
                    .filter { !$0.isSeen }
                    .map(KnockRequestInfo.init)
            }
            // If the requests have the same event ids we can discard the output
            .removeDuplicates { Set($0.map(\.eventID)) == Set($1.map(\.eventID)) }
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .weakAssign(to: \.state.unseenKnockRequests, on: self)
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.roomProxy.timeline.retryDecryption(sessionIDs: nil)
            }
            .store(in: &cancellables)
    }
    
    private func processIdentityStatusChanges(_ changes: [IdentityStatusChange]) async {
        for change in changes {
            switch change.changedTo {
            case .pinViolation:
                guard case let .success(member) = await roomProxy.getMember(userID: change.userId) else {
                    MXLog.error("Failed retrieving room member for identity status change: \(change)")
                    continue
                }

                identityPinningViolations[change.userId] = member
            case .verificationViolation:
                // sTalk: Auto-resolve verification violations — in corporate environment
                // identity resets are expected (auto-bootstrap). Withdraw the violation to unblock sending.
                MXLog.info("sTalk: Auto-resolving verification violation for \(change.userId)")
                Task { await resolveIdentityVerificationViolation(change.userId) }
                continue
            default:
                identityVerificationViolations[change.userId] = nil
                identityPinningViolations[change.userId] = nil
            }
        }

        if let member = identityVerificationViolations.values.first {
            state.identityViolationDetails = .verificationViolation(member: member,
                                                                    learnMoreURL: appSettings.identityPinningViolationDetailsURL)
        } else if let member = identityPinningViolations.values.first {
            state.identityViolationDetails = .pinViolation(member: member,
                                                           learnMoreURL: appSettings.identityPinningViolationDetailsURL)
        } else {
            state.identityViolationDetails = nil
        }
    }
    
    /// STMOB-84 build 141: на открытии комнаты дёргаем pin для internal users
    /// (`@*:stalk.implica.ru`). Идемпотентно — повторный pin SDK игнорирует.
    /// Покрывает случай: юзер появился в комнате уже ПОСЛЕ initial domain-trust
    /// hook'а в UserSession (новый member, недавний invite принят и т.д.).
    private func pinDomainTrustMembersLazy() {
        let domain = ":stalk.implica.ru"
        let ownUserID = roomProxy.ownUserID
        let candidates = roomProxy.membersPublisher.value
            .map(\.userID)
            .filter { $0.hasSuffix(domain) && $0 != ownUserID }
        guard !candidates.isEmpty else { return }
        Task { [clientProxy] in
            var pinned = 0
            for userID in candidates {
                if case .success = await clientProxy.pinUserIdentity(userID) {
                    pinned += 1
                }
            }
            DiagLog.write("E2EE", "domainTrust lazy room=\(self.roomProxy.id) pinned=\(pinned)/\(candidates.count)")
        }
    }

    private func updateVerificationBadge() async {
        // Build 124 fix: исключаем системных ботов (meet-cleanup и подобных) из
        // dmRecipient resolve. У комнаты с Жилиным первым non-self был
        // @meet-cleanup, а не @rusty → presence резолвилась для бота.
        guard roomProxy.isDirectOneToOneRoom,
              let dmRecipient = roomProxy.membersPublisher.value.first(where: { member in
                  member.userID != roomProxy.ownUserID && !Self.isSystemBot(userID: member.userID)
              }) else {
            state.dmRecipientVerificationState = .notVerified
            return
        }

        // STMOB-103 build 123: setup presence ДО userIdentity check.
        // Иначе если userIdentity lookup fails (для бота / неверифицированного user)
        // guard return → presence subtitle не появляется.
        setupDMPresence(userID: dmRecipient.userID)

        guard case let .success(userIdentity) = await clientProxy.userIdentity(for: dmRecipient.userID, fallBackToServer: true),
              let userIdentity else {
            state.dmRecipientVerificationState = .notVerified
            return
        }

        state.dmRecipientVerificationState = userIdentity.verificationState
    }

    // MARK: - DM Presence (STMOB-103 build 122)

    private var dmPresenceSubscribed = false

    /// STMOB-103 build 124+: системные боты + guest meet users (динамические ID
    /// типа @meet-8913e350:..., @meet-cleanup:...) — игнорируем при resolve
    /// dmRecipient. Любой `@meet-*` user — это session guest или cleanup bot.
    private static func isSystemBot(userID: String) -> Bool {
        userID.hasPrefix("@meet-") || userID.hasPrefix("@stalk-system:")
    }

    private func setupDMPresence(userID: String) {
        DiagLog.write("RoomDMPresence", "setup userID=\(userID) room=\(roomProxy.id) subscribed=\(dmPresenceSubscribed)")
        // Build 125: shared PresenceService — sync с HomeScreen и ContactsListScreen.
        guard let service = AppCoordinator.sharedPresenceService else { return }
        if !dmPresenceSubscribed {
            dmPresenceSubscribed = true
            service.presenceSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] map in
                    let presence = map[userID]
                    DiagLog.write("RoomDMPresence", "  update userID=\(userID) found=\(presence != nil) isOnline=\(presence?.isOnline ?? false)")
                    self?.state.dmRecipientPresence = presence
                }
                .store(in: &cancellables)
        }
        // Регистрируем userID собеседника в общий poll если не зарегистрирован.
        if !service.currentUserIDs.contains(userID) {
            let merged = Array(Set(service.currentUserIDs + [userID]))
            if service.currentUserIDs.isEmpty {
                service.startPolling(userIDs: merged)
            } else {
                service.updatePollingUserIDs(merged)
                Task { await service.fetchPresence(for: [userID]) }
            }
        } else {
            // Уже polit — присвоим cached value для немедленного отображения
            state.dmRecipientPresence = service.presenceSubject.value[userID]
        }
    }
    
    private func resolveIdentityPinningViolation(_ userID: String) async {
        defer {
            hideLoadingIndicator()
        }
        
        showLoadingIndicator()
        
        if case .failure = await clientProxy.pinUserIdentity(userID) {
            userIndicatorController.alertInfo = .init(id: .init(), title: L10n.commonError)
        }
    }
    
    private func resolveIdentityVerificationViolation(_ userID: String) async {
        defer {
            hideLoadingIndicator()
        }

        showLoadingIndicator()

        if case .failure = await clientProxy.withdrawUserIdentityVerification(userID) {
            userIndicatorController.alertInfo = .init(id: .init(), title: L10n.commonError)
        }
    }
    
    private func buildPinnedEventContents(timelineItems: [TimelineItemProxy]) {
        var pinnedEventContents = OrderedDictionary<String, AttributedString>()
        
        for item in timelineItems {
            // Only remote events are pinned
            if case let .event(event) = item,
               let eventID = event.id.eventID {
                pinnedEventContents.updateValue(pinnedEventStringBuilder.buildAttributedString(for: event) ?? AttributedString(L10n.commonUnsupportedEvent),
                                                forKey: eventID)
            }
        }
        
        state.pinnedEventsBannerState.setPinnedEventContents(pinnedEventContents)
        
        // If it's the first time we are setting the pinned events, we should select the initial event if available.
        if let initialSelectedPinnedEventID {
            state.pinnedEventsBannerState.setSelectedPinnedEventID(initialSelectedPinnedEventID)
            self.initialSelectedPinnedEventID = nil
        }
    }
    
    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        state.roomTitle = roomInfo.displayName ?? roomProxy.id
        state.roomAvatar = roomInfo.avatar
        state.hasOngoingCall = roomInfo.hasRoomCall
        state.hasSuccessor = roomInfo.successor != nil
        
        let pinnedEventIDs = roomInfo.pinnedEventIDs
        // Only update the loading state of the banner
        if state.pinnedEventsBannerState.isLoading {
            state.pinnedEventsBannerState = .loading(numbersOfEvents: pinnedEventIDs.count)
        }
        
        switch (roomProxy.isDirectOneToOneRoom, roomInfo.joinRule) {
        case (false, .knock), (false, .knockRestricted):
            state.isKnockableRoom = true
        default:
            state.isKnockableRoom = false
        }

        if let powerLevels = roomInfo.powerLevels {
            state.canSendMessage = powerLevels.canOwnUser(sendMessage: .roomMessage)
            state.canJoinCall = powerLevels.canOwnUserJoinCall()
            state.canAcceptKnocks = powerLevels.canOwnUserInvite()
            state.canDeclineKnocks = powerLevels.canOwnUserKick()
            state.canBan = powerLevels.canOwnUserBan()
        }
        
        let isHistoryVisible = roomInfo.historyVisibility == .shared || roomInfo.historyVisibility == .worldReadable
        let isHistoryVisibleBannerAcknowledged = appSettings.acknowledgedHistoryVisibleRooms.contains(roomInfo.id)

        if appSettings.enableKeyShareOnInvite, roomInfo.isEncrypted {
            if isHistoryVisible, !isHistoryVisibleBannerAcknowledged {
                // Whenever the user opens an encrypted room with shared/world-readable history visbility, we show them a warning banner if they have not already dismissed it.
                state.historyVisibleDetails = .historyVisible(learnMoreURL: appSettings.historySharingDetailsURL)
            } else if !isHistoryVisible, isHistoryVisibleBannerAcknowledged {
                // Whenever the user opens a room with non-shared history visibility, we clear the dismiss flag to ensure that the banner is displayed again if the history is made visible in the future.
                appSettings.acknowledgedHistoryVisibleRooms.remove(roomInfo.id)
                state.historyVisibleDetails = nil
            }
        }
    }
    
    private func setupPinnedEventsTimelineItemProviderIfNeeded() {
        guard pinnedEventsTimelineItemProvider == nil else {
            return
        }
        
        Task {
            guard case let .success(pinnedEventsTimeline) = await roomProxy.pinnedEventsTimeline() else {
                return
            }
            
            if pinnedEventsTimelineItemProvider == nil {
                pinnedEventsTimelineItemProvider = pinnedEventsTimeline.timelineItemProvider
            }
        }
    }
        
    private func acceptKnock(eventID: String) async {
        guard case let .loaded(requests) = roomProxy.knockRequestsStatePublisher.value,
              let request = requests.first(where: { $0.eventID == eventID }) else {
            return
        }
        
        state.handledEventIDs.insert(eventID)
        switch await request.accept() {
        case .success:
            break
        case .failure:
            userIndicatorController.submitIndicator(.init(id: Self.errorIndicatorIdentifier, type: .toast, title: L10n.errorUnknown))
            state.handledEventIDs.remove(eventID)
        }
    }
    
    private func markAllKnocksAsSeen() async {
        guard case let .loaded(requests) = roomProxy.knockRequestsStatePublisher.value else {
            return
        }
        state.handledEventIDs.formUnion(Set(requests.map(\.eventID)))
        
        let failedIDs = await withTaskGroup(of: (String, Result<Void, KnockRequestProxyError>).self) { group in
            for request in requests {
                group.addTask {
                    await (request.eventID, request.markAsSeen())
                }
            }
            
            var failedIDs = [String]()
            for await result in group where result.1.isFailure {
                failedIDs.append(result.0)
            }
            return failedIDs
        }
        state.handledEventIDs.subtract(failedIDs)
    }
    
    private func handleTappedPinnedEventsBanner() {
        analyticsService.trackInteraction(name: .PinnedMessageBannerClick)
        if let eventID = state.pinnedEventsBannerState.selectedPinnedEventID {
            Task {
                switch await roomProxy.loadOrFetchEventDetails(for: eventID) {
                case .success(let event):
                    if appSettings.threadsEnabled,
                       let threadRootEventID = event.threadRootEventId() {
                        actionsSubject.send(.focusEvent(eventID: threadRootEventID))
                        actionsSubject.send(.displayThread(threadRootEventID: threadRootEventID, focussedEventID: eventID))
                    } else {
                        actionsSubject.send(.focusEvent(eventID: eventID))
                    }
                case .failure:
                    userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
                }
            }
        }
        state.pinnedEventsBannerState.previousPin()
    }
    
    // MARK: - Search

    private func setupSearchSubscription() {
        context.$viewState
            .map(\.bindings.searchQuery)
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    private var searchTask: Task<Void, Never>?

    private func performSearch(query: String) {
        // Cancel previous search pagination
        searchTask?.cancel()

        guard !query.isEmpty, let timelineController else {
            state.searchResultEventIDs = []
            state.currentSearchResultIndex = 0
            state.isSearchLoading = false
            return
        }

        // First: search currently loaded items
        let resultEventIDs = searchLoadedItems(query: query, in: timelineController)
        state.searchResultEventIDs = resultEventIDs
        state.currentSearchResultIndex = resultEventIDs.isEmpty ? 0 : resultEventIDs.count - 1

        // Focus on the last (most recent) result
        if let eventID = resultEventIDs.last {
            actionsSubject.send(.focusSearchResult(eventID: eventID))
        }
    }

    private func searchLoadedItems(query: String, in timelineController: any TimelineControllerProtocol) -> [String] {
        var resultEventIDs = [String]()
        for item in timelineController.timelineItems {
            // Only search message items (text, image captions, etc.) — not system/state events
            guard let eventItem = item as? EventBasedMessageTimelineItemProtocol,
                  let eventID = item.id.eventID else {
                continue
            }
            if eventItem.body.localizedCaseInsensitiveContains(query) {
                resultEventIDs.append(eventID)
            }
        }
        return resultEventIDs
    }

    private func toggleSearch() {
        state.isSearchActive.toggle()
        if !state.isSearchActive {
            searchTask?.cancel()
            state.bindings.searchQuery = ""
            state.searchResultEventIDs = []
            state.currentSearchResultIndex = 0
            state.isSearchLoading = false
            actionsSubject.send(.clearSearchFocus)
        }
    }

    func activateSearch() {
        state.isSearchActive = true
    }

    private func navigateSearchResult(forward: Bool) {
        guard !state.searchResultEventIDs.isEmpty else { return }

        if forward {
            state.currentSearchResultIndex = (state.currentSearchResultIndex + 1) % state.searchResultEventIDs.count
        } else {
            state.currentSearchResultIndex = (state.currentSearchResultIndex - 1 + state.searchResultEventIDs.count) % state.searchResultEventIDs.count
        }

        let eventID = state.searchResultEventIDs[state.currentSearchResultIndex]
        actionsSubject.send(.focusSearchResult(eventID: eventID))
    }

    // MARK: Loading indicators

    private static let loadingIndicatorIdentifier = "\(RoomScreenViewModel.self)-Loading"
    private static let errorIndicatorIdentifier = "\(RoomScreenViewModel.self)-Error"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(.init(id: Self.loadingIndicatorIdentifier, type: .toast, title: L10n.commonLoading))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
}

extension RoomScreenViewModel {
    static func mock(roomProxyMock: JoinedRoomProxyMock,
                     clientProxyMock: ClientProxyMock = ClientProxyMock(.init()),
                     appHooks: AppHooks = AppHooks()) -> RoomScreenViewModel {
        RoomScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxyMock)),
                            roomProxy: roomProxyMock,
                            initialSelectedPinnedEventID: nil,
                            ongoingCallRoomIDPublisher: .init(.init(nil)),
                            appSettings: ServiceLocator.shared.settings,
                            appHooks: appHooks,
                            analyticsService: ServiceLocator.shared.analytics,
                            userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
}

private extension KnockRequestInfo {
    init(from proxy: KnockRequestProxyProtocol) {
        self.init(displayName: proxy.displayName,
                  avatarURL: proxy.avatarURL,
                  userID: proxy.userID,
                  reason: proxy.reason,
                  eventID: proxy.eventID)
    }
}
