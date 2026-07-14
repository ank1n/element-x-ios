//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import Compound
import SwiftState
import SwiftUI

enum UserSessionFlowCoordinatorAction {
    case logout
    case clearCache
    /// Logout and disable App Lock without any confirmation. The user forgot their PIN.
    case forceLogout
}

class UserSessionFlowCoordinator: FlowCoordinatorProtocol {
    enum HomeTab: Hashable { case contacts, calls, chats, apps, profile }

    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationTabCoordinator: NavigationTabCoordinator<HomeTab>
    private let appLockService: AppLockServiceProtocol
    private let flowParameters: CommonFlowParameters

    private var userSession: UserSessionProtocol {
        flowParameters.userSession
    }

    private let onboardingFlowCoordinator: OnboardingFlowCoordinator
    private let onboardingStackCoordinator: NavigationStackCoordinator

    // Tab coordinators
    private let contactsTabFlowCoordinator: ContactsTabFlowCoordinator
    private let contactsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let callsTabFlowCoordinator: CallsTabFlowCoordinator
    private let callsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let chatsTabFlowCoordinator: ChatsTabFlowCoordinator
    private let chatsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let appsTabFlowCoordinator: WidgetsTabFlowCoordinator
    private let appsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails

    // 5. Profile tab
    private let profileTabFlowCoordinator: SettingsFlowCoordinator
    private let profileTabStackCoordinator: NavigationStackCoordinator
    private let profileTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails

    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        /// The root screen for this flow.
        case tabBar
    }

    enum Event: EventType {
        /// The flow is being started.
        case start
    }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []
    
    private let actionsSubject: PassthroughSubject<UserSessionFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<UserSessionFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(isNewLogin: Bool,
         navigationRootCoordinator: NavigationRootCoordinator,
         appLockService: AppLockServiceProtocol,
         flowParameters: CommonFlowParameters) {
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appLockService = appLockService
        self.flowParameters = flowParameters
        
        navigationTabCoordinator = NavigationTabCoordinator()
        navigationRootCoordinator.setRootCoordinator(navigationTabCoordinator)

        // STMOB-102 Phase 3 (Option C): зелёная полоса активного звонка через
        // отдельный UIWindow поверх status bar — Telegram/WhatsApp pattern.
        // Сжимает основной контент через additionalSafeAreaInsets и не блокирует
        // navigation bar / back button (передаёт touches через PassthroughWindow).
        flowParameters.windowManager.installCallBanner(coordinator: navigationTabCoordinator)

        // 1. Contacts tab
        let contactsStackCoordinator = NavigationStackCoordinator()
        contactsTabFlowCoordinator = ContactsTabFlowCoordinator(navigationStackCoordinator: contactsStackCoordinator,
                                                                flowParameters: flowParameters)
        contactsTabDetails = .init(tag: HomeTab.contacts, title: SL10n.tabContacts, icon: \.userProfile, selectedIcon: \.userProfileSolid, sfSymbol: "person", sfSymbolSelected: "person.fill", lottieAnimation: "TabContacts")
        contactsTabDetails.barVisibilityOverride = .visible
        contactsTabFlowCoordinator.onTabBarVisibilityChange = { [weak contactsTabDetails] visibility in
            contactsTabDetails?.barVisibilityOverride = visibility
        }

        // 2. Calls tab
        let callsStackCoordinator = NavigationStackCoordinator()
        callsTabFlowCoordinator = CallsTabFlowCoordinator(navigationStackCoordinator: callsStackCoordinator,
                                                          flowParameters: flowParameters)
        callsTabDetails = .init(tag: HomeTab.calls, title: SL10n.tabCalls, icon: \.voiceCall, selectedIcon: \.voiceCallSolid, sfSymbol: "phone", sfSymbolSelected: "phone.fill", lottieAnimation: "TabCalls")
        callsTabDetails.barVisibilityOverride = .visible

        // 3. Chats tab
        let chatsSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        chatsTabFlowCoordinator = ChatsTabFlowCoordinator(isNewLogin: isNewLogin,
                                                          navigationSplitCoordinator: chatsSplitCoordinator,
                                                          flowParameters: flowParameters)
        chatsTabDetails = .init(tag: HomeTab.chats, title: SL10n.tabChats, icon: \.chat, selectedIcon: \.chatSolid, sfSymbol: "message", sfSymbolSelected: "message.fill", lottieAnimation: "TabChats")
        chatsTabDetails.navigationSplitCoordinator = chatsSplitCoordinator
        // chatsTabDetails.barVisibilityOverride = .visible  // Let auto-hide work when detail is shown

        // 4. Apps tab
        let appsStackCoordinator = NavigationStackCoordinator()
        appsTabFlowCoordinator = WidgetsTabFlowCoordinator(navigationStackCoordinator: appsStackCoordinator,
                                                           flowParameters: flowParameters)
        appsTabDetails = .init(tag: HomeTab.apps, title: SL10n.tabApps, icon: \.extensions, selectedIcon: \.extensionsSolid, sfSymbol: "square.grid.2x2", sfSymbolSelected: "square.grid.2x2.fill", lottieAnimation: "TabApps")
        appsTabDetails.barVisibilityOverride = .visible

        // 5. Profile tab (uses SettingsFlowCoordinator)
        let profileStack = NavigationStackCoordinator()
        profileTabStackCoordinator = profileStack
        profileTabFlowCoordinator = SettingsFlowCoordinator(appLockService: appLockService,
                                                            navigationStackCoordinator: profileStack,
                                                            flowParameters: flowParameters)
        profileTabDetails = .init(tag: HomeTab.profile, title: SL10n.tabSettings, icon: \.userProfile, selectedIcon: \.userProfileSolid, sfSymbol: "gearshape", sfSymbolSelected: "gearshape.fill", lottieAnimation: "TabSettings")
        profileTabDetails.barVisibilityOverride = .visible

        onboardingStackCoordinator = NavigationStackCoordinator()
        onboardingFlowCoordinator = OnboardingFlowCoordinator(isNewLogin: isNewLogin,
                                                              appLockService: appLockService,
                                                              navigationStackCoordinator: onboardingStackCoordinator,
                                                              flowParameters: flowParameters)

        navigationTabCoordinator.setTabs([
            .init(coordinator: contactsStackCoordinator, details: contactsTabDetails),
            .init(coordinator: callsStackCoordinator, details: callsTabDetails),
            .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
            .init(coordinator: appsStackCoordinator, details: appsTabDetails),
            .init(coordinator: profileStack, details: profileTabDetails)
        ])
        // sTalk: при старте открывать Чаты, не Контакты. Tab order в UI остаётся
        // тот же (Contacts слева как было), но selectedTab = .chats by default.
        navigationTabCoordinator.selectedTab = .chats
        
        stateMachine = flowParameters.stateMachineFactory.makeUserSessionFlowStateMachine(state: .initial)
        configureStateMachine()
        
        setupObservers()
    }
    
    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }
    
    func stop() {
        contactsTabFlowCoordinator.stop()
        callsTabFlowCoordinator.stop()
        chatsTabFlowCoordinator.stop()
        appsTabFlowCoordinator.stop()
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        switch appRoute {
        case .accountProvisioningLink:
            break // We always ignore this flow when logged in.
        case .settings, .chatBackupSettings:
            navigationTabCoordinator.selectedTab = .profile
            profileTabFlowCoordinator.handleAppRoute(appRoute, animated: animated)
        case .call(let roomID):
            Task { await presentCallScreen(roomID: roomID) }
        case .genericCallLink(let url):
            presentCallScreen(genericCallLink: url)
        case .meeting(let code):
            Task { await presentCallScreen(meetingCode: code) }
        case .roomList, .room, .roomAlias, .childRoom, .childRoomAlias,
             .roomDetails, .roomMemberDetails, .userProfile,
             .event, .eventOnRoomAlias, .childEvent, .childEventOnRoomAlias,
             .share, .transferOwnership, .thread:
            clearPresentedSheets(animated: animated) // Make sure the presented route is visible.
            chatsTabFlowCoordinator.handleAppRoute(appRoute, animated: animated)
            if navigationTabCoordinator.selectedTab != .chats {
                navigationTabCoordinator.selectedTab = .chats
            }
        }
    }
    
    func clearRoute(animated: Bool) {
        clearPresentedSheets(animated: animated)
        chatsTabFlowCoordinator.clearRoute(animated: animated)
    }
    
    /// Clearing routes is more complicated than it first seems. When passing routes
    /// to the chats flow we can't clear all routes as e.g. childRoom/childEvent etc
    /// expect to push into the existing stack. But we do need to hide any sheets that
    /// might cover up the presented route. BUT! We probably shouldn't dismiss onboarding
    /// or verification flows until they're complete… This needs more thought before we
    /// codify it all into the state machine.
    private func clearPresentedSheets(animated: Bool) {
        // Settings is now a tab, no sheets to clear for it
    }
    
    func isDisplayingRoomScreen(withRoomID roomID: String) -> Bool {
        guard navigationTabCoordinator.selectedTab == .chats else { return false }
        return chatsTabFlowCoordinator.isDisplayingRoomScreen(withRoomID: roomID)
    }
    
    // MARK: - Private
    
    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .tabBar]) { [weak self] _ in
            guard let self else { return }

            contactsTabFlowCoordinator.start()
            callsTabFlowCoordinator.start()
            chatsTabFlowCoordinator.start()
            appsTabFlowCoordinator.start()
            profileTabFlowCoordinator.handleAppRoute(.settings, animated: false)
            attemptStartingOnboarding()
        }

        stateMachine.addErrorHandler { context in
            fatalError("Unexpected transition: \(context)")
        }
    }
    
    private func setupObservers() {
        chatsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .switchToChatsTab:
                    navigationTabCoordinator.selectedTab = .chats
                case .showSettings:
                    navigationTabCoordinator.selectedTab = .profile
                case .showChatBackupSettings:
                    handleAppRoute(.chatBackupSettings, animated: true)
                case .sessionVerification(let flow):
                    presentSessionVerificationScreen(flow: flow)
                case .showCallScreen(let roomProxy, let videoEnabled):
                    presentCallScreen(roomProxy: roomProxy, videoEnabled: videoEnabled)
                case .hideCallScreenOverlay:
                    hideCallScreenOverlay()
                case .logout:
                    Task { await self.runLogoutFlow() }
                }
            }
            .store(in: &cancellables)
        
        // Contacts tab actions
        contactsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .showSettings:
                    navigationTabCoordinator.selectedTab = .profile
                case .presentCallScreen(let roomProxy, let videoEnabled):
                    self.presentCallScreen(roomProxy: roomProxy, videoEnabled: videoEnabled)
                }
            }
            .store(in: &cancellables)

        // Calls tab actions
        callsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .showSettings:
                    navigationTabCoordinator.selectedTab = .profile
                case .startCall(let roomID):
                    Task { await self.presentCallScreen(roomID: roomID) }
                }
            }
            .store(in: &cancellables)

        // Apps tab actions
        appsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .showSettings:
                    navigationTabCoordinator.selectedTab = .profile
                case .startCall(let roomID):
                    Task { await self.presentCallScreen(roomID: roomID) }
                case .hideTabBar(let hide):
                    appsTabDetails.barVisibilityOverride = hide ? .hidden : .visible
                }
            }
            .store(in: &cancellables)

        // Profile tab actions
        profileTabFlowCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .dismiss:
                    navigationTabCoordinator.selectedTab = .chats
                case .clearCache:
                    actionsSubject.send(.clearCache)
                case .runLogoutFlow:
                    Task { await self.runLogoutFlow() }
                case .forceLogout:
                    actionsSubject.send(.forceLogout)
                }
            }
            .store(in: &cancellables)

        // Unread badge count on Chats tab
        userSession.clientProxy.alternateRoomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms in
                guard let self else { return }
                let totalUnread = rooms.reduce(0) { sum, room in
                    sum + Int(room.unreadNotificationsCount)
                }
                chatsTabDetails.badgeCount = totalUnread
            }
            .store(in: &cancellables)

        userSession.sessionSecurityStatePublisher
            .map(\.verificationState)
            .filter { $0 != .unknown }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                
                attemptStartingOnboarding()
                setupSessionVerificationRequestsObserver()
            }
            .store(in: &cancellables)
        
        let reachabilityNotificationID = "ru.implica.stalk.reachability.notification"
        userSession.clientProxy.homeserverReachabilityPublisher.removeDuplicates()
            .combineLatest(flowParameters.appMediator.networkMonitor.reachabilityPublisher.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] homeserverReachability, networkReachability in
                MXLog.info("Homeserver reachability: \(homeserverReachability)")
                
                guard let self else { return }
                switch (networkReachability, homeserverReachability) {
                case (.reachable, .reachable):
                    flowParameters.userIndicatorController.retractIndicatorWithId(reachabilityNotificationID)
                case (.reachable, .unreachable):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonServerUnreachable,
                                                                                 persistent: true))
                case (.unreachable, _):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonOffline,
                                                                                 persistent: true))
                }
            }
            .store(in: &cancellables)
        
        onboardingFlowCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .requestPresentation(let animated):
                    navigationTabCoordinator.setFullScreenCoverCoordinator(onboardingStackCoordinator, animated: animated)
                case .dismiss:
                    navigationTabCoordinator.setFullScreenCoverCoordinator(nil)
                case .logout:
                    logout()
                }
            }
            .store(in: &cancellables)
        
        flowParameters.elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                switch action {
                case .endCall:
                    self?.dismissCallScreenIfNeeded()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        // Always keep TabBar visible - don't hide based on spaces
        // userSession.clientProxy.spaceService.topLevelSpacesPublisher
        //     .combineLatest(flowParameters.appSettings.$createSpaceEnabled)
        //     .map { topLevelSpaces, isCreateSpaceEnabled in
        //         !isCreateSpaceEnabled && topLevelSpaces.isEmpty ? .hidden : nil
        //     }
        //     .weakAssign(to: \.chatsTabDetails.barVisibilityOverride, on: self)
        //     .store(in: &cancellables)
    }
    
    // MARK: - Onboarding
    
    private func attemptStartingOnboarding() {
        MXLog.info("Attempting to start onboarding")
        
        if onboardingFlowCoordinator.shouldStart {
            clearRoute(animated: false)
            onboardingFlowCoordinator.start()
        }
    }
    
    // MARK: - Settings (now embedded as Profile tab)
    
    // MARK: - Session Verification
    
    private func setupSessionVerificationRequestsObserver() {
        userSession.clientProxy.sessionVerificationController?.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self, case .receivedVerificationRequest(let details) = action else {
                    return
                }
                
                MXLog.info("Received session verification request")
                
                if details.senderProfile.userID == userSession.clientProxy.userID {
                    presentSessionVerificationScreen(flow: .deviceResponder(requestDetails: details))
                } else {
                    presentSessionVerificationScreen(flow: .userResponder(requestDetails: details))
                }
            }
            .store(in: &cancellables)
    }
    
    private func presentSessionVerificationScreen(flow: SessionVerificationScreenFlow) {
        guard let sessionVerificationController = userSession.clientProxy.sessionVerificationController else {
            fatalError("The sessionVerificationController should aways be valid at this point")
        }
        
        let navigationStackCoordinator = NavigationStackCoordinator()
        
        let parameters = SessionVerificationScreenCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController,
                                                                        flow: flow,
                                                                        appSettings: flowParameters.appSettings,
                                                                        mediaProvider: userSession.mediaProvider)
        
        let coordinator = SessionVerificationScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .done:
                    self?.navigationTabCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationTabCoordinator.setSheetCoordinator(navigationStackCoordinator)
    }
    
    // MARK: - Calls
    
    private func presentCallScreen(genericCallLink url: URL) {
        presentCallScreen(configuration: .init(genericCallLink: url))
    }
    
    /// STMOB-216: resolve a meeting code (from a `/meet/s/<code>` link) to a room via
    /// the meet-api, then open its native call. Falls back to an error toast on failure.
    private func presentCallScreen(meetingCode code: String) async {
        guard let concreteProxy = userSession.clientProxy as? ClientProxy else {
            DiagLog.write("Meeting", "meeting link code=\(code) — no concrete clientProxy")
            return
        }
        let service = MeetingsService(homeserver: userSession.clientProxy.homeserver,
                                      accessTokenProvider: { try concreteProxy.matrixAccessToken() },
                                      forceTokenRefresh: { await concreteProxy.forceTokenRefresh() })

        let loadingID = "meetingLinkResolve"
        flowParameters.userIndicatorController.submitIndicator(.init(id: loadingID, type: .modal, title: L10n.commonLoading, persistent: true))
        DiagLog.write("Meeting", "meeting link code=\(code) → ensureRoom")
        do {
            let roomID = try await service.ensureRoom(code: code, userId: userSession.clientProxy.userID)
            flowParameters.userIndicatorController.retractIndicatorWithId(loadingID)
            DiagLog.write("Meeting", "meeting link code=\(code) → room=\(roomID) → present")
            await presentCallScreen(roomID: roomID)
        } catch {
            flowParameters.userIndicatorController.retractIndicatorWithId(loadingID)
            DiagLog.write("Meeting", "meeting link ensureRoom FAILED code=\(code): \(error.localizedDescription)")
            flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        }
    }

    private func presentCallScreen(roomID: String) async {
        // STMOB-151 build 174: переписан с silent guard на auto-join +
        // диагностику. Раньше guard let .joined exit'ил молча если room
        // не sync'нута (nil) или ещё в .invited (meeting auto-invite
        // не accepted клиентом) — кнопка "Начать звонок" из MeetingDetail
        // не делала НИЧЕГО, ни ошибки в UI, ни записи в лог. Теперь:
        // .joined → present, .invited/.nil → joinRoom + retry, иначе → error toast.
        DiagLog.write("Meeting", "presentCallScreen(roomID:) START room=\(roomID)")
        let roomType = await userSession.clientProxy.roomForIdentifier(roomID)
        switch roomType {
        case .joined(let roomProxy):
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) state=joined → present")
            presentCallScreen(roomProxy: roomProxy)
        case .invited:
            await joinAndPresentCallScreen(roomID: roomID, fromState: "invited")
        case .none:
            await joinAndPresentCallScreen(roomID: roomID, fromState: "nil(not-synced)")
        case .knocked:
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) state=knocked — нельзя join без approval")
            flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        case .banned:
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) state=banned — забанены")
            flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        case .left:
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) state=left → joinRoom")
            await joinAndPresentCallScreen(roomID: roomID, fromState: "left")
        }
    }

    /// Helper: join room then re-fetch and present call screen.
    /// Used когда room в .invited/.left/nil — нужно join сначала.
    private func joinAndPresentCallScreen(roomID: String, fromState: String) async {
        DiagLog.write("Meeting", "presentCallScreen room=\(roomID) state=\(fromState) → joinRoom")
        // STMOB-151 build 175: insert roomID в roomsToAwait ДО joinRoom.
        // ClientProxy.roomForIdentifier использует roomsToAwait для активации
        // waitForRoomToSync (с timeout 10s). Без этого после joinRoom OK
        // re-fetch может зависнуть на `staticRoomSummaryProvider.statePublisher
        // .values.first { $0.isLoaded }` БЕЗ таймаута если sync ещё не подключён.
        // Симптом build 174 (dp.bondar 00:16:18): joinRoom OK → re-fetch
        // никогда не вернулся, кнопка работала только со 2-го нажатия через 23s.
        userSession.clientProxy.roomsToAwait.insert(roomID)
        let joinResult = await userSession.clientProxy.joinRoom(roomID, via: [])
        switch joinResult {
        case .success:
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) joinRoom OK → re-fetch")
            // STMOB-151 build 175: timeout wrapper 8s. Если roomForIdentifier
            // не вернулся за 8s — error toast + suggest retry. Раньше silent hang.
            let refetched = await withTimeout(seconds: 8) {
                await self.userSession.clientProxy.roomForIdentifier(roomID)
            }
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) re-fetch result=\(refetched.map { String(describing: $0).prefix(40) } ?? "TIMEOUT")")
            if case let .joined(roomProxy) = refetched {
                presentCallScreen(roomProxy: roomProxy)
            } else {
                DiagLog.write("Meeting", "presentCallScreen room=\(roomID) joinRoom OK но re-fetch != .joined")
                flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
            }
        case .failure(let err):
            DiagLog.write("Meeting", "presentCallScreen room=\(roomID) joinRoom FAILED \(err)")
            flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        }
    }

    /// STMOB-151 build 175: timeout wrapper для async operations. Возвращает
    /// результат если завершилось до timeout, иначе nil.
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
    
    private func presentCallScreen(roomProxy: JoinedRoomProxyProtocol, videoEnabled: Bool = true) {
        // Если в комнате уже есть звонок И текущий пользователь НЕ участвует в нём,
        // значит пользователь присоединяется к входящему звонку
        let roomInfo = roomProxy.infoPublisher.value
        let isJoiningExistingCall = roomInfo.hasRoomCall &&
            !roomInfo.activeRoomCallParticipants.contains(roomProxy.ownUserID)
        if isJoiningExistingCall {
            flowParameters.elementCallService.markNextCallAsIncoming()
        }

        // sTalk: For incoming calls, default to video OFF (user can enable manually).
        // The caller decides their own video state, but receiver should start without video
        // to match standard telephony behavior.
        let effectiveVideoEnabled = isJoiningExistingCall ? false : videoEnabled
        MXLog.info("sTalk: presentCallScreen — videoEnabled=\(videoEnabled), isJoiningExistingCall=\(isJoiningExistingCall), effectiveVideoEnabled=\(effectiveVideoEnabled), hasRoomCall=\(roomInfo.hasRoomCall), participants=\(roomInfo.activeRoomCallParticipants)")

        let colorScheme: ColorScheme = flowParameters.windowManager.mainWindow.traitCollection.userInterfaceStyle == .light ? .light : .dark
        presentCallScreen(configuration: .init(roomProxy: roomProxy,
                                               clientProxy: userSession.clientProxy,
                                               clientID: InfoPlistReader.main.bundleIdentifier,
                                               elementCallBaseURL: flowParameters.appSettings.elementCallBaseURL,
                                               elementCallBaseURLOverride: flowParameters.appSettings.elementCallBaseURLOverride,
                                               colorScheme: colorScheme),
                          startWithVideoEnabled: effectiveVideoEnabled)
    }
    
    private var callScreenPictureInPictureController: AVPictureInPictureController?
    /// Подписки ТЕКУЩЕГО call-экрана. Отдельно от общих cancellables: sink
    /// захватывает координатор сильно — в общем наборе прошлые звонки
    /// утекали навсегда (лог dp 128: зомби-аудио старого звонка).
    private var callScreenCancellables = Set<AnyCancellable>()
    private var minimizedCallTimer: Timer?

    private func startMinimizedCallTimer(coordinator: CallScreenCoordinator) {
        stopMinimizedCallTimer()
        minimizedCallTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.navigationTabCoordinator.minimizedCallElapsedTime = coordinator.callElapsedTime
            }
        }
    }

    private func stopMinimizedCallTimer() {
        minimizedCallTimer?.invalidate()
        minimizedCallTimer = nil
    }

    private func presentCallScreen(configuration: ElementCallConfiguration, startWithVideoEnabled: Bool = true) {
        guard flowParameters.ongoingCallRoomIDPublisher.value != configuration.callRoomID else {
            MXLog.info("Returning to existing call.")
            callScreenPictureInPictureController?.stopPictureInPicture()
            return
        }

        // STMOB (лог dp 128): второй звонок при живом первом. Старый координатор
        // надо ЖЁСТКО остановить и ДОЖДАТЬСЯ полного disconnect LiveKit (bounded 8s),
        // иначе два менеджера живут параллельно: зомби-аудио старого звонка,
        // драка за аудио-сессию, SFU кикает дубль identity → флаппинг обоих.
        if let existingCall = navigationTabCoordinator.overlayCoordinator as? CallScreenCoordinator {
            DiagLog.write("Call", "presentCallScreen: REPLACING live call — stop old, await disconnect")
            callScreenPictureInPictureController = nil
            navigationTabCoordinator.minimizedCallDisplayName = nil
            navigationTabCoordinator.restoreCallHandler = nil
            stopMinimizedCallTimer()
            navigationTabCoordinator.setOverlayCoordinator(nil)
            Task { [weak self] in
                await existingCall.stopAndWait()
                guard let self else { return }
                DiagLog.write("Call", "presentCallScreen: old call stopped — presenting new")
                self.presentCallScreen(configuration: configuration, startWithVideoEnabled: startWithVideoEnabled)
            }
            return
        }
        
        // sTalk: Register call in local history
        let callHistoryService = ServiceLocator.shared.localCallHistoryService
        var currentCallID: String?
        if let callHistoryService {
            let roomID: String
            switch configuration.kind {
            case .genericCallLink:
                roomID = "generic-call"
            case .roomCall(let roomProxy, _, _, _, _, _):
                roomID = roomProxy.id
            }
            let callID = callHistoryService.startCall(roomID: roomID, direction: .outgoing)
            currentCallID = callID

            // STMOB-221: enrich the outgoing history entry with the room name and
            // participants. startCall only stores a roomID, and outgoing calls were
            // never enriched (only incoming calls are, in CallHistoryCoordinator),
            // so call history fell back to the generic "Звонок" label for the callee.
            if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
                let ownUserID = userSession.clientProxy.userID
                Task {
                    let roomDisplayName = roomProxy.infoPublisher.value.displayName
                    var participants: [String: String] = [:]
                    if let members = await roomProxy.members() {
                        for member in members where member.isActive && member.userID != ownUserID {
                            participants[member.userID] = member.displayName ?? member.userID
                        }
                    }
                    callHistoryService.updateCallInfo(id: callID,
                                                      roomDisplayName: roomDisplayName,
                                                      participants: participants)
                }
            }
        }

        callScreenCancellables.removeAll()
        let callScreenCoordinator = CallScreenCoordinator(parameters: .init(elementCallService: flowParameters.elementCallService,
                                                                            configuration: configuration,
                                                                            allowPictureInPicture: true,
                                                                            appSettings: flowParameters.appSettings,
                                                                            appHooks: flowParameters.appHooks,
                                                                            analytics: flowParameters.analytics,
                                                                            recordingService: ServiceLocator.shared.recordingService,
                                                                            mediaProvider: userSession.mediaProvider,
                                                                            localCallHistoryService: callHistoryService,
                                                                            currentCallID: currentCallID,
                                                                            startWithVideoEnabled: startWithVideoEnabled,
                                                                            orientationManager: flowParameters.windowManager))
        
        callScreenCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .pictureInPictureIsAvailable(let controller):
                    callScreenPictureInPictureController = controller
                case .pictureInPictureStarted:
                    MXLog.info("Hiding call for PiP presentation.")
                    // sTalk: Set display name for minimized call bar (PiP path)
                    if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
                        self.navigationTabCoordinator.minimizedCallDisplayName = roomProxy.infoPublisher.value.displayName ?? SL10n.callDefault
                    }
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .pictureInPictureStopped:
                    MXLog.info("Restoring call after PiP presentation.")
                    self.stopMinimizedCallTimer()
                    navigationTabCoordinator.setOverlayPresentationMode(.fullScreen)
                case .minimizeCall:
                    MXLog.info("sTalk: minimizeCall received — setting minimized mode")
                    // sTalk: Set display name and elapsed time for minimized call banner
                    if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
                        self.navigationTabCoordinator.minimizedCallDisplayName = roomProxy.infoPublisher.value.displayName ?? SL10n.callDefault
                    }
                    self.navigationTabCoordinator.minimizedCallElapsedTime = callScreenCoordinator.callElapsedTime
                    self.startMinimizedCallTimer(coordinator: callScreenCoordinator)
                    self.navigationTabCoordinator.restoreCallHandler = { [weak self] in
                        callScreenCoordinator.restoreFromMinimized()
                        self?.stopMinimizedCallTimer()
                    }
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .dismiss:
                    // sTalk: End call in local history
                    if let currentCallID {
                        callHistoryService?.endCall(id: currentCallID, missed: false)
                    }
                    callScreenPictureInPictureController = nil
                    self.navigationTabCoordinator.minimizedCallDisplayName = nil
                    self.navigationTabCoordinator.restoreCallHandler = nil
                    self.stopMinimizedCallTimer()
                    navigationTabCoordinator.setOverlayCoordinator(nil)
                    self.callScreenCancellables.removeAll()
                }
            }
            .store(in: &callScreenCancellables)

        navigationTabCoordinator.setOverlayCoordinator(callScreenCoordinator, animated: true)
        
        flowParameters.analytics.track(screen: .RoomCall)
    }
    
    private func hideCallScreenOverlay() {
        guard let callScreenPictureInPictureController else {
            // sTalk: In native call mode PiP is not available — keep fullscreen
            MXLog.warning("Picture in picture isn't available — keeping call fullscreen.")
            return
        }
        
        MXLog.info("Starting picture in picture to hide the call screen overlay.")
        callScreenPictureInPictureController.startPictureInPicture()
        navigationTabCoordinator.setOverlayPresentationMode(.minimized)
    }
    
    private func dismissCallScreenIfNeeded() {
        guard navigationTabCoordinator.overlayCoordinator is CallScreenCoordinator else {
            return
        }
        
        navigationTabCoordinator.setOverlayCoordinator(nil)
    }

    // MARK: - Logout
    
    private func runLogoutFlow() async {
        let secureBackupController = userSession.clientProxy.secureBackupController
        
        guard case let .success(isLastDevice) = await userSession.clientProxy.isOnlyDeviceLeft() else {
            flowParameters.userIndicatorController.alertInfo = .init(id: .init())
            return
        }
        
        guard isLastDevice else {
            logout()
            return
        }
        
        guard secureBackupController.recoveryState.value == .enabled else {
            flowParameters.userIndicatorController.alertInfo = .init(id: .init(),
                                                                     title: L10n.screenSignoutRecoveryDisabledTitle,
                                                                     message: L10n.screenSignoutRecoveryDisabledSubtitle,
                                                                     primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                         self?.actionsSubject.send(.logout)
                                                                     }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                                         self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                                     })
            return
        }
        
        guard secureBackupController.keyBackupState.value == .enabled else {
            flowParameters.userIndicatorController.alertInfo = .init(id: .init(),
                                                                     title: L10n.screenSignoutKeyBackupDisabledTitle,
                                                                     message: L10n.screenSignoutKeyBackupDisabledSubtitle,
                                                                     primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                         self?.actionsSubject.send(.logout)
                                                                     }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                                         self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                                     })
            return
        }
        
        // STMOB-187: recovery key управляется централизованно (корп-провижининг),
        // поэтому отдельный экран "Have you saved your recovery key?" не нужен —
        // показываем обычный диалог подтверждения выхода.
        logout()
    }

    private func logout() {
        flowParameters.userIndicatorController.alertInfo = .init(id: .init(),
                                                                 title: L10n.screenSignoutConfirmationDialogTitle,
                                                                 message: L10n.screenSignoutConfirmationDialogContent,
                                                                 primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                     self?.actionsSubject.send(.logout)
                                                                 })
    }
}
