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
            guard let apiURL = widget.apiURL, !apiURL.isEmpty,
                  let accessToken = try? userSession.clientProxy.matrixAccessToken() else {
                MXLog.error("sTalk: Missing apiURL or accessToken for meetings-calendar")
                return
            }
            // apiURL is like "https://stalk.implica.ru/api/meetings"
            // MeetingsService needs just the base: "https://stalk.implica.ru"
            let baseURL: String
            if let range = apiURL.range(of: "/api/") {
                baseURL = String(apiURL[apiURL.startIndex..<range.lowerBound])
            } else {
                baseURL = apiURL
            }
            let parameters = MeetingsScreenCoordinatorParameters(
                apiURL: baseURL,
                accessToken: accessToken,
                currentUserId: userSession.clientProxy.userID,
                clientProxy: userSession.clientProxy
            )
            let coordinator = MeetingsScreenCoordinator(
                parameters: parameters,
                navigationStackCoordinator: navigationStackCoordinator
            )
            navigationStackCoordinator.push(coordinator)
        default:
            MXLog.warning("sTalk: Unknown builtin app: \(widget.id)")
        }
    }
}
