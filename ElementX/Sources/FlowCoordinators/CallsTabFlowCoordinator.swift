//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftState

enum CallsTabFlowCoordinatorAction {
    case showSettings
}

class CallsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator

    private var callsListCoordinator: CallsListScreenCoordinator?

    enum State: StateType {
        case initial
        case callsListScreen
    }

    enum Event: EventType {
        case start
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<CallsTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<CallsTabFlowCoordinatorAction, Never> {
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
        callsListCoordinator?.stop()
    }

    // MARK: - Private

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .callsListScreen]) { [weak self] _ in
            self?.showCallsListScreen()
        }
    }

    private func showCallsListScreen() {
        // Initialize CallHistoryService with Recording API endpoint (dynamic based on homeserver)
        let homeserver = userSession.clientProxy.homeserver
        let domain = URL(string: homeserver)?.host ?? "stalk.implica.ru"
        let apiBaseURL = URL(string: "https://\(domain)/recording-api")!

        // Get Matrix access token for Recording API authorization
        var accessToken: String?
        if let clientProxy = userSession.clientProxy as? ClientProxy {
            accessToken = try? clientProxy.matrixAccessToken()
        }
        let callHistoryService = CallHistoryService(baseURL: apiBaseURL, accessToken: accessToken)

        let parameters = CallsListScreenCoordinatorParameters(
            userSession: userSession,
            callHistoryService: callHistoryService
        )
        let coordinator = CallsListScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .startCall(let userId):
                // TODO: Start call
                MXLog.info("Start call with: \(userId)")
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        callsListCoordinator = coordinator
    }
}
