//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftState

enum ContactsTabFlowCoordinatorAction {
    case showSettings
}

class ContactsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator

    private var contactsListCoordinator: ContactsListScreenCoordinator?

    enum State: StateType {
        case initial
        case contactsListScreen
    }

    enum Event: EventType {
        case start
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<ContactsTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ContactsTabFlowCoordinatorAction, Never> {
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
        contactsListCoordinator?.stop()
    }

    // MARK: - Private

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .contactsListScreen]) { [weak self] _ in
            self?.showContactsListScreen()
        }
    }

    private func showContactsListScreen() {
        let parameters = ContactsListScreenCoordinatorParameters(userSession: userSession)
        let coordinator = ContactsListScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .openChat(let roomId):
                // TODO: Navigate to chat
                MXLog.info("Open chat: \(roomId)")
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        contactsListCoordinator = coordinator
    }
}
