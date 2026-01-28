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
            case .openWidget(let widget, let roomId):
                Task { await self.presentWidget(widget, roomId: roomId) }
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        widgetsListCoordinator = coordinator
    }

    private func presentWidget(_ widget: MatrixWidget, roomId: String) async {
        // Get room proxy from client
        guard let roomProxyType = await userSession.clientProxy.roomForIdentifier(roomId) else {
            MXLog.error("Failed to find room for identifier: \(roomId)")
            return
        }

        // Check if it's a joined room
        guard case let .joined(roomProxy) = roomProxyType else {
            MXLog.error("Room is not joined: \(roomId)")
            return
        }

        let parameters = WidgetWebViewScreenCoordinatorParameters(widget: widget, roomProxy: roomProxy)
        let coordinator = WidgetWebViewScreenCoordinator(parameters: parameters)

        navigationStackCoordinator.push(coordinator)
    }
}
