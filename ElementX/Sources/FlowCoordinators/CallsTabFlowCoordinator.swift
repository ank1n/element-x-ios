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
    case startCall(roomID: String)
}

class CallsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator

    private var callsListCoordinator: CallsListScreenCoordinator?
    private var callHistoryService: CallHistoryServiceProtocol?

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

        // Get Matrix access token provider for Recording API authorization (fresh token each call)
        let clientProxy = userSession.clientProxy as? ClientProxy
        let callHistoryService = CallHistoryService(baseURL: apiBaseURL,
                                                    accessTokenProvider: { try clientProxy?.matrixAccessToken() ?? "" },
                                                    forceTokenRefresh: { await clientProxy?.forceTokenRefresh() })
        self.callHistoryService = callHistoryService

        let parameters = CallsListScreenCoordinatorParameters(userSession: userSession,
                                                              callHistoryService: callHistoryService)
        let coordinator = CallsListScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .startCall(let userId):
                MXLog.info("sTalk: Start call from history with roomID: \(userId)")
                self.actionsSubject.send(.startCall(roomID: userId))
            case .showCallDetail(let call):
                self.showCallDetailScreen(call: call)
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        callsListCoordinator = coordinator
    }

    private func showCallDetailScreen(call: CallHistoryItem) {
        guard let callHistoryService else {
            MXLog.error("sTalk: CallHistoryService not available for call detail")
            return
        }

        let parameters = CallDetailScreenCoordinatorParameters(call: call,
                                                               callHistoryService: callHistoryService,
                                                               mediaProvider: userSession.mediaProvider,
                                                               clientProxy: userSession.clientProxy)
        let coordinator = CallDetailScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                navigationStackCoordinator.pop()
            case .callBack(let roomID):
                actionsSubject.send(.startCall(roomID: roomID))
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.push(coordinator)
    }
}
