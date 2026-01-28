//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftState
import SwiftUI

@MainActor
protocol AuthenticationFlowCoordinatorDelegate: AnyObject {
    func authenticationFlowCoordinator(didLoginWithSession userSession: UserSessionProtocol)
}

class AuthenticationFlowCoordinator: FlowCoordinatorProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let bugReportService: BugReportServiceProtocol
    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let appMediator: AppMediatorProtocol
    private let appSettings: AppSettings
    private let analytics: AnalyticsService
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let savedAccountsStore: SavedAccountsStore

    enum State: StateType {
        /// The state machine hasn't started.
        case initial

        /// The initial screen shown when you first launch the app.
        case startScreen

        /// The screen used for the whole QR Code flow.
        case qrCodeLoginScreen

        /// The screen showing saved accounts for sign-in.
        case savedAccountsScreen
        /// The screen to enter a new server address.
        case serverInputScreen
        /// The web authentication session is being presented.
        case oidcAuthentication

        /// The flow is complete.
        case complete
    }

    enum Event: EventType {
        /// The flow is being started.
        case start

        /// Modify the flow using the provisioning parameters in the `userInfo`.
        case applyProvisioningParameters

        /// The user would like to login with a QR code.
        case loginWithQR
        /// Show saved accounts screen for login.
        case showSavedAccounts
        /// Show server input screen for registration.
        case showServerInput

        /// The QR login flow was aborted.
        case cancelledLoginWithQR
        /// The saved accounts screen was dismissed.
        case cancelledSavedAccounts
        /// The server input screen was dismissed.
        case cancelledServerInput(previousState: State)

        /// Show the web authentication session for OIDC (using the parameters in the `userInfo`).
        case continueWithOIDC
        /// The web authentication session was aborted.
        case cancelledOIDCAuthentication(previousState: State)

        /// Show server input from saved accounts (add new server).
        case addNewServer

        /// The user has successfully signed in. The new session can be found in the `userInfo`.
        case signedIn
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables = Set<AnyCancellable>()

    private var oidcPresenter: OIDCAuthenticationPresenter?

    // periphery:ignore - retaining purpose
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?

    /// Flag to prevent dismissal callbacks from firing state machine events
    private var isIntentionalDismissal = false

    weak var delegate: AuthenticationFlowCoordinatorDelegate?

    init(authenticationService: AuthenticationServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         navigationRootCoordinator: NavigationRootCoordinator,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         analytics: AnalyticsService,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.authenticationService = authenticationService
        self.bugReportService = bugReportService
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appMediator = appMediator
        self.appSettings = appSettings
        self.analytics = analytics
        self.userIndicatorController = userIndicatorController
        self.savedAccountsStore = SavedAccountsStore()

        navigationStackCoordinator = NavigationStackCoordinator()

        stateMachine = .init(state: .initial)
        configureStateMachine()
    }

    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }

    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        switch appRoute {
        case .accountProvisioningLink(let provisioningParameters):
            if stateMachine.state != .startScreen {
                clearRoute(animated: animated)
            }

            stateMachine.tryEvent(.applyProvisioningParameters, userInfo: provisioningParameters)
        default:
            fatalError()
        }
    }

    func clearRoute(animated: Bool) {
        switch stateMachine.state {
        case .initial, .startScreen:
            break
        case .qrCodeLoginScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledLoginWithQR)
        case .savedAccountsScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledSavedAccounts)
        case .serverInputScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledServerInput(previousState: .startScreen))
        case .oidcAuthentication:
            oidcPresenter?.cancel()
            navigationStackCoordinator.popToRoot(animated: animated)
        case .complete:
            fatalError()
        }
    }

    // MARK: - Setup

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .startScreen]) { [weak self] _ in
            self?.showStartScreen(fromState: .initial)
        }

        stateMachine.addRoutes(event: .applyProvisioningParameters, transitions: [.initial => .startScreen,
                                                                                  .startScreen => .startScreen]) { [weak self] context in
            guard let provisioningParameters = context.userInfo as? AccountProvisioningParameters else { fatalError("The authentication configuration is missing.") }
            self?.showStartScreen(fromState: context.fromState, applying: provisioningParameters)
        }

        // QR Code

        stateMachine.addRoutes(event: .loginWithQR, transitions: [.startScreen => .qrCodeLoginScreen]) { [weak self] _ in
            self?.showQRCodeLoginScreen()
        }
        stateMachine.addRoutes(event: .cancelledLoginWithQR, transitions: [.qrCodeLoginScreen => .startScreen])

        // Saved Accounts (Sign In flow)

        stateMachine.addRoutes(event: .showSavedAccounts, transitions: [.startScreen => .savedAccountsScreen]) { [weak self] _ in
            self?.showSavedAccountsScreen()
        }
        stateMachine.addRoutes(event: .cancelledSavedAccounts, transitions: [.savedAccountsScreen => .startScreen])

        // Server Input (from saved accounts for new server, or from start screen for registration)

        stateMachine.addRoutes(event: .showServerInput, transitions: [.startScreen => .serverInputScreen]) { [weak self] _ in
            self?.showServerInputScreen(authenticationFlow: .register, fromState: .startScreen)
        }
        stateMachine.addRoutes(event: .addNewServer, transitions: [.savedAccountsScreen => .serverInputScreen]) { [weak self] _ in
            self?.showServerInputScreen(authenticationFlow: .login, fromState: .savedAccountsScreen)
        }
        stateMachine.addRoutes(event: .cancelledServerInput(previousState: .savedAccountsScreen), transitions: [.serverInputScreen => .savedAccountsScreen])
        stateMachine.addRoutes(event: .cancelledServerInput(previousState: .startScreen), transitions: [.serverInputScreen => .startScreen])

        // OIDC Authentication

        stateMachine.addRoutes(event: .continueWithOIDC, transitions: [.savedAccountsScreen => .oidcAuthentication,
                                                                       .serverInputScreen => .oidcAuthentication,
                                                                       .startScreen => .oidcAuthentication]) { [weak self] context in
            guard let userInfo = context.userInfo as? (OIDCAuthorizationDataProxy, UIWindow, Bool) else {
                fatalError("Missing the OIDC data and presentation anchor.")
            }
            let (oidcData, window, useEphemeral) = (userInfo.0, userInfo.1, userInfo.2)
            self?.showOIDCAuthentication(oidcData: oidcData, presentationAnchor: window, useEphemeral: useEphemeral, fromState: context.fromState)
        }
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .savedAccountsScreen), transitions: [.oidcAuthentication => .savedAccountsScreen])
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .serverInputScreen), transitions: [.oidcAuthentication => .serverInputScreen])
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .startScreen), transitions: [.oidcAuthentication => .startScreen])

        // Completion

        stateMachine.addRoutes(event: .signedIn, transitions: [.qrCodeLoginScreen => .complete,
                                                               .oidcAuthentication => .complete]) { [weak self] context in
            guard let userSession = context.userInfo as? UserSessionProtocol else { fatalError("The user session wasn't included in the context") }
            self?.userHasSignedIn(userSession: userSession)
        }

        // Logging

        stateMachine.addAnyHandler(.any => .any) { context in
            MXLog.info("Transitioning from `\(context.fromState)` to `\(context.toState)` with event `\(String(describing: context.event))`.")
        }

        // Unhandled

        stateMachine.addErrorHandler { context in
            switch (context.fromState, context.toState) {
            case (.complete, .complete):
                break
            default:
                fatalError("Unexpected transition: \(context)")
            }
        }
    }

    private func showStartScreen(fromState: State, applying provisioningParameters: AccountProvisioningParameters? = nil) {
        let parameters = AuthenticationStartScreenParameters(authenticationService: authenticationService,
                                                             provisioningParameters: provisioningParameters,
                                                             isBugReportServiceEnabled: false,
                                                             appSettings: appSettings,
                                                             userIndicatorController: userIndicatorController)
        let coordinator = AuthenticationStartScreenCoordinator(parameters: parameters)

        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .loginWithQR:
                    stateMachine.tryEvent(.loginWithQR)
                case .login:
                    stateMachine.tryEvent(.showSavedAccounts)
                case .register:
                    stateMachine.tryEvent(.showServerInput)
                case .reportProblem:
                    break // Disabled

                case .loginDirectlyWithOIDC(let oidcData, let window):
                    stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window, true))
                case .loginDirectlyWithPassword:
                    break // Disabled - only SSO
                }
            }
            .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)

        if fromState == .initial {
            navigationRootCoordinator.setRootCoordinator(navigationStackCoordinator)
        }
    }

    // MARK: - QR Code

    private func showQRCodeLoginScreen() {
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = QRCodeLoginScreenCoordinator(parameters: .init(mode: .login(authenticationService),
                                                                         canSignInManually: true,
                                                                         orientationManager: appMediator.windowManager,
                                                                         appMediator: appMediator))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else {
                return
            }
            switch action {
            case .signInManually:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
                stateMachine.tryEvent(.showSavedAccounts)
            case .dismiss:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
            case .signedIn(let userSession):
                navigationStackCoordinator.setSheetCoordinator(nil)
                appSettings.hasRunIdentityConfirmationOnboarding = true
                DispatchQueue.main.async {
                    self.stateMachine.tryEvent(.signedIn, userInfo: userSession)
                }
            case .requestOIDCAuthorisation, .linkedDevice:
                fatalError("QR code login shouldn't request an OIDC flow or link a device.")
            }
        }
        .store(in: &cancellables)

        stackCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator)
    }

    // MARK: - Saved Accounts

    private func showSavedAccountsScreen() {
        let navigationCoordinator = NavigationStackCoordinator()
        let parameters = SavedAccountsScreenCoordinatorParameters(savedAccountsStore: savedAccountsStore)
        let coordinator = SavedAccountsScreenCoordinator(parameters: parameters)

        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .selectAccount(let account):
                    isIntentionalDismissal = true
                    navigationStackCoordinator.setSheetCoordinator(nil)
                    Task { await self.configureAndStartOIDC(serverURL: account.serverURL, flow: .login, loginHint: account.userId) }
                case .addNewServer:
                    isIntentionalDismissal = true
                    navigationStackCoordinator.setSheetCoordinator(nil)
                    stateMachine.tryEvent(.addNewServer)
                case .dismiss:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)

        navigationCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(navigationCoordinator) { [weak self] in
            guard let self, !isIntentionalDismissal else {
                self?.isIntentionalDismissal = false
                return
            }
            stateMachine.tryEvent(.cancelledSavedAccounts)
        }
    }

    // MARK: - Server Input

    private func showServerInputScreen(authenticationFlow: AuthenticationFlow, fromState: State) {
        let navigationCoordinator = NavigationStackCoordinator()

        let parameters = ServerSelectionScreenCoordinatorParameters(authenticationService: authenticationService,
                                                                    authenticationFlow: authenticationFlow,
                                                                    appSettings: appSettings,
                                                                    userIndicatorController: userIndicatorController)
        let coordinator = ServerSelectionScreenCoordinator(parameters: parameters)

        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .updated:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                    // Server was configured, now start OIDC with forced login and ephemeral session (new server)
                    Task { await self.startOIDCAfterConfigure(flow: authenticationFlow, forceLogin: true, useEphemeral: true) }
                case .dismiss:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)

        navigationCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(navigationCoordinator) { [weak self] in
            self?.stateMachine.tryEvent(.cancelledServerInput(previousState: fromState))
        }
    }

    // MARK: - OIDC

    private func configureAndStartOIDC(serverURL: String, flow: AuthenticationFlow, loginHint: String? = nil, forceLogin: Bool = false, useEphemeral: Bool = false) async {
        startLoading()
        defer { stopLoading() }

        authenticationService.reset()

        guard case .success = await authenticationService.configure(for: serverURL, flow: flow) else {
            displayError(message: "Failed to configure server: \(serverURL)")
            return
        }

        guard authenticationService.homeserver.value.loginMode.supportsOIDCFlow else {
            displayError(message: "Server does not support SSO/OIDC. Please use a server with Keycloak.")
            return
        }

        guard let window = await getWindow() else {
            displayError(message: "Cannot present authentication")
            return
        }

        switch await authenticationService.urlForOIDCLogin(loginHint: loginHint, forceLogin: forceLogin) {
        case .success(let oidcData):
            stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window, useEphemeral))
        case .failure:
            displayError(message: "Failed to start SSO login")
        }
    }

    private func startOIDCAfterConfigure(flow: AuthenticationFlow, forceLogin: Bool = false, useEphemeral: Bool = false) async {
        startLoading()
        defer { stopLoading() }

        guard authenticationService.homeserver.value.loginMode.supportsOIDCFlow else {
            displayError(message: "Server does not support SSO/OIDC. Please use a server with Keycloak.")
            return
        }

        guard let window = await getWindow() else {
            displayError(message: "Cannot present authentication")
            return
        }

        switch await authenticationService.urlForOIDCLogin(loginHint: nil, forceLogin: forceLogin) {
        case .success(let oidcData):
            stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window, useEphemeral))
        case .failure:
            displayError(message: "Failed to start SSO login")
        }
    }

    private func showOIDCAuthentication(oidcData: OIDCAuthorizationDataProxy, presentationAnchor: UIWindow, useEphemeral: Bool, fromState: State) {
        let presenter = OIDCAuthenticationPresenter(authenticationService: authenticationService,
                                                    oidcRedirectURL: appSettings.oidcRedirectURL,
                                                    presentationAnchor: presentationAnchor,
                                                    userIndicatorController: userIndicatorController,
                                                    useEphemeralSession: useEphemeral)
        oidcPresenter = presenter

        Task {
            switch await presenter.authenticate(using: oidcData) {
            case .success(let userSession):
                // Save account after successful login
                let serverAddress = authenticationService.homeserver.value.address
                let userId = userSession.clientProxy.userID
                let savedAccount = SavedAccount(serverURL: serverAddress,
                                                userId: userId,
                                                displayName: nil,
                                                lastUsedAt: Date())
                savedAccountsStore.save(savedAccount)

                stateMachine.tryEvent(.signedIn, userInfo: userSession)
            case .failure:
                stateMachine.tryEvent(.cancelledOIDCAuthentication(previousState: fromState))
            }
            oidcPresenter = nil
        }
    }

    // MARK: - Helpers

    @MainActor
    private func getWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private let loadingIndicatorID = "\(AuthenticationFlowCoordinator.self)-Loading"

    private func startLoading() {
        userIndicatorController.submitIndicator(UserIndicator(id: loadingIndicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }

    private func stopLoading() {
        userIndicatorController.retractIndicatorWithId(loadingIndicatorID)
    }

    private func displayError(message: String) {
        userIndicatorController.submitIndicator(UserIndicator(title: message, iconName: "xmark.circle"))
        MXLog.error("Auth flow error: \(message)")
    }

    // MARK: - Completion

    private func userHasSignedIn(userSession: UserSessionProtocol) {
        delegate?.authenticationFlowCoordinator(didLoginWithSession: userSession)
    }
}
