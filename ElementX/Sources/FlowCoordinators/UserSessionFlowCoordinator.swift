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

    private var userSession: UserSessionProtocol { flowParameters.userSession }

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

        // 1. Contacts tab
        let contactsStackCoordinator = NavigationStackCoordinator()
        contactsTabFlowCoordinator = ContactsTabFlowCoordinator(navigationStackCoordinator: contactsStackCoordinator,
                                                                 flowParameters: flowParameters)
        contactsTabDetails = .init(tag: HomeTab.contacts, title: "Контакты", icon: \.userProfile, selectedIcon: \.userProfileSolid, sfSymbol: "person", sfSymbolSelected: "person.fill", lottieAnimation: "TabContacts")
        contactsTabDetails.barVisibilityOverride = .visible

        // 2. Calls tab
        let callsStackCoordinator = NavigationStackCoordinator()
        callsTabFlowCoordinator = CallsTabFlowCoordinator(navigationStackCoordinator: callsStackCoordinator,
                                                          flowParameters: flowParameters)
        callsTabDetails = .init(tag: HomeTab.calls, title: "Звонки", icon: \.voiceCall, selectedIcon: \.voiceCallSolid, sfSymbol: "phone", sfSymbolSelected: "phone.fill", lottieAnimation: "TabCalls")
        callsTabDetails.barVisibilityOverride = .visible

        // 3. Chats tab
        let chatsSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        chatsTabFlowCoordinator = ChatsTabFlowCoordinator(isNewLogin: isNewLogin,
                                                          navigationSplitCoordinator: chatsSplitCoordinator,
                                                          flowParameters: flowParameters)
        chatsTabDetails = .init(tag: HomeTab.chats, title: "Чаты", icon: \.chat, selectedIcon: \.chatSolid, sfSymbol: "message", sfSymbolSelected: "message.fill", lottieAnimation: "TabChats")
        chatsTabDetails.navigationSplitCoordinator = chatsSplitCoordinator
        // chatsTabDetails.barVisibilityOverride = .visible  // Let auto-hide work when detail is shown

        // 4. Apps tab
        let appsStackCoordinator = NavigationStackCoordinator()
        appsTabFlowCoordinator = WidgetsTabFlowCoordinator(navigationStackCoordinator: appsStackCoordinator,
                                                           flowParameters: flowParameters)
        appsTabDetails = .init(tag: HomeTab.apps, title: "Приложения", icon: \.extensions, selectedIcon: \.extensionsSolid, sfSymbol: "square.grid.2x2", sfSymbolSelected: "square.grid.2x2.fill", lottieAnimation: "TabApps")
        appsTabDetails.barVisibilityOverride = .visible

        // 5. Profile tab (uses SettingsFlowCoordinator)
        let profileStack = NavigationStackCoordinator()
        profileTabStackCoordinator = profileStack
        profileTabFlowCoordinator = SettingsFlowCoordinator(appLockService: appLockService,
                                                             navigationStackCoordinator: profileStack,
                                                             flowParameters: flowParameters)
        profileTabDetails = .init(tag: HomeTab.profile, title: "Настройки", icon: \.userProfile, selectedIcon: \.userProfileSolid, sfSymbol: "gearshape", sfSymbolSelected: "gearshape.fill", lottieAnimation: "TabSettings")
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
    
    // Clearing routes is more complicated than it first seems. When passing routes
    // to the chats flow we can't clear all routes as e.g. childRoom/childEvent etc
    // expect to push into the existing stack. But we do need to hide any sheets that
    // might cover up the presented route. BUT! We probably shouldn't dismiss onboarding
    // or verification flows until they're complete… This needs more thought before we
    // codify it all into the state machine.
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
    
    private func presentCallScreen(roomID: String) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            return
        }
        
        presentCallScreen(roomProxy: roomProxy)
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
    private func presentCallScreen(configuration: ElementCallConfiguration, startWithVideoEnabled: Bool = true) {
        guard flowParameters.ongoingCallRoomIDPublisher.value != configuration.callRoomID else {
            MXLog.info("Returning to existing call.")
            callScreenPictureInPictureController?.stopPictureInPicture()
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
            currentCallID = callHistoryService.startCall(roomID: roomID, direction: .outgoing)
        }

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
                                                                            startWithVideoEnabled: startWithVideoEnabled))
        
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
                        self.navigationTabCoordinator.minimizedCallDisplayName = roomProxy.infoPublisher.value.displayName ?? "Звонок"
                    }
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .pictureInPictureStopped:
                    MXLog.info("Restoring call after PiP presentation.")
                    navigationTabCoordinator.setOverlayPresentationMode(.fullScreen)
                case .minimizeCall:
                    MXLog.info("sTalk: minimizeCall received — setting minimized mode")
                    // sTalk: Set display name for minimized call bar
                    if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
                        self.navigationTabCoordinator.minimizedCallDisplayName = roomProxy.infoPublisher.value.displayName ?? "Звонок"
                    }
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .dismiss:
                    // sTalk: End call in local history
                    if let currentCallID {
                        callHistoryService?.endCall(id: currentCallID, missed: false)
                    }
                    callScreenPictureInPictureController = nil
                    self.navigationTabCoordinator.minimizedCallDisplayName = nil
                    navigationTabCoordinator.setOverlayCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationTabCoordinator.setOverlayCoordinator(callScreenCoordinator, animated: true)
        
        flowParameters.analytics.track(screen: .RoomCall)
    }
    
    private func hideCallScreenOverlay() {
        guard let callScreenPictureInPictureController else {
            MXLog.warning("Picture in picture isn't available, dismissing the call screen.")
            dismissCallScreenIfNeeded()
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
        
        presentSecureBackupLogoutConfirmationScreen()
    }
    
    private func logout() {
        flowParameters.userIndicatorController.alertInfo = .init(id: .init(),
                                                                 title: L10n.screenSignoutConfirmationDialogTitle,
                                                                 message: L10n.screenSignoutConfirmationDialogContent,
                                                                 primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                                     self?.actionsSubject.send(.logout)
                                                                 })
    }
    
    private func presentSecureBackupLogoutConfirmationScreen() {
        let coordinator = SecureBackupLogoutConfirmationScreenCoordinator(parameters: .init(secureBackupController: userSession.clientProxy.secureBackupController,
                                                                                            homeserverReachabilityPublisher: userSession.clientProxy.homeserverReachabilityPublisher))
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .cancel:
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .settings:
                    chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .logout:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)
        
        navigationTabCoordinator.setSheetCoordinator(coordinator, animated: true)
    }
}
