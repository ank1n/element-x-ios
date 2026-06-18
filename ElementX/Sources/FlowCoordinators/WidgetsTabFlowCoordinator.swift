//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftState

enum WidgetsTabFlowCoordinatorAction {
    case showSettings
    case startCall(roomID: String)
    case hideTabBar(Bool)
}

class WidgetsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator

    private var widgetsListCoordinator: WidgetsListScreenCoordinator?

    enum State: StateType {
        case initial
        case widgetsListScreen
    }

    enum Event: EventType {
        case start
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<WidgetsTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<WidgetsTabFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(navigationStackCoordinator: NavigationStackCoordinator, flowParameters: CommonFlowParameters) {
        userSession = flowParameters.userSession
        self.navigationStackCoordinator = navigationStackCoordinator
        self.flowParameters = flowParameters

        stateMachine = .init(state: .initial)
        configureStateMachine()
    }

    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }

    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        clearRoute(animated: animated)
    }

    func clearRoute(animated: Bool) {
        // Clear any presented screens
    }

    func stop() {
        widgetsListCoordinator?.stop()
    }

    // MARK: - Private

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .widgetsListScreen]) { [weak self] _ in
            self?.showWidgetsListScreen()
        }
    }

    private func showWidgetsListScreen() {
        let parameters = WidgetsListScreenCoordinatorParameters(userSession: userSession)
        let coordinator = WidgetsListScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .openWidget(let widget):
                self.presentWidget(widget)
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        widgetsListCoordinator = coordinator
    }

    private func presentWidget(_ widget: WidgetItem) {
        // Builtin apps get native screens
        if widget.isBuiltin {
            presentBuiltinApp(widget)
            return
        }

        let parameters = WidgetWebViewScreenCoordinatorParameters(widget: widget)
        let coordinator = WidgetWebViewScreenCoordinator(parameters: parameters)

        navigationStackCoordinator.push(coordinator)
    }

    private func presentBuiltinApp(_ widget: WidgetItem) {
        switch widget.id {
        case "meetings-calendar":
            guard let apiURL = widget.apiURL, !apiURL.isEmpty else {
                MXLog.error("sTalk: Missing apiURL for meetings-calendar")
                return
            }
            _ = apiURL // presence of the widget gates availability; the host comes from the session below
            // STMOB-246: meetings-api lives on the session's own homeserver. The widget's apiUrl
            // returned by apps-api can be hardcoded to stalk.implica.ru server-side, so using it
            // made iOS hit .ru with the session's (e.g. .uz) token -> 401 -> -1011. Derive the base
            // from the logged-in homeserver instead so meetings load on any sTalk domain. Path stays
            // identical (/api/meetings) since every sTalk deployment shares the same structure.
            let homeserver = userSession.clientProxy.homeserver
            let normalizedHS = homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"
            let baseURL: String
            if let url = URL(string: normalizedHS), let scheme = url.scheme, let host = url.host {
                baseURL = "\(scheme)://\(host)"
            } else {
                baseURL = normalizedHS
            }
            // Pass a closure so each API call gets a fresh OIDC token
            let clientProxy = userSession.clientProxy
            let concreteProxy = clientProxy as? ClientProxy
            let parameters = MeetingsScreenCoordinatorParameters(apiURL: baseURL,
                                                                 accessTokenProvider: { try clientProxy.matrixAccessToken() },
                                                                 forceTokenRefresh: { await concreteProxy?.forceTokenRefresh() },
                                                                 currentUserId: userSession.clientProxy.userID,
                                                                 clientProxy: clientProxy,
                                                                 mediaProvider: userSession.mediaProvider)
            let coordinator = MeetingsScreenCoordinator(parameters: parameters,
                                                        navigationStackCoordinator: navigationStackCoordinator)
            coordinator.actionsPublisher
                .sink { [weak self] action in
                    switch action {
                    case .startCall(let roomID):
                        DiagLog.write("Meeting", "WidgetsTabFlowCoordinator .startCall room=\(roomID) → UserSessionFlow")
                        self?.actionsSubject.send(.startCall(roomID: roomID))
                    case .hideTabBar(let hide):
                        self?.actionsSubject.send(.hideTabBar(hide))
                    }
                }
                .store(in: &cancellables)
            navigationStackCoordinator.push(coordinator)
        default:
            MXLog.warning("sTalk: Unknown builtin app: \(widget.id)")
        }
    }
}
