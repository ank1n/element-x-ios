//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftState
import SwiftUI

enum ContactsTabFlowCoordinatorAction {
    case showSettings
    case presentCallScreen(roomProxy: JoinedRoomProxyProtocol, videoEnabled: Bool)
}

class ContactsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator
    /// Для управления видимостью таб-бара при навигации в комнату
    var onTabBarVisibilityChange: ((Visibility) -> Void)?

    private var contactsListCoordinator: ContactsListScreenCoordinator?
    private var roomFlowCoordinator: RoomFlowCoordinator?

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
        navigationStackCoordinator.popToRoot(animated: animated)
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
                self.openRoom(roomID: roomId)
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        contactsListCoordinator = coordinator
    }

    private func openRoom(roomID: String) {
        // A room flow from this tab is already active — ignore duplicate requests so we don't push
        // several copies of the room onto the stack. Cleared to nil on .finished when the user leaves.
        guard roomFlowCoordinator == nil else {
            MXLog.info("[Contacts] Ignoring openRoom(\(roomID)) — a room flow is already active")
            return
        }
        let roomFlowCoordinator = RoomFlowCoordinator(roomID: roomID,
                                                      isChildFlow: true,
                                                      navigationStackCoordinator: navigationStackCoordinator,
                                                      flowParameters: flowParameters)

        roomFlowCoordinator.actions.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .presentCallScreen(let roomProxy, let videoEnabled):
                actionsSubject.send(.presentCallScreen(roomProxy: roomProxy, videoEnabled: videoEnabled))
            case .finished:
                self.roomFlowCoordinator = nil
                // Показываем таб-бар при возврате из комнаты
                self.onTabBarVisibilityChange?(.visible)
            default:
                break
            }
        }
        .store(in: &cancellables)

        self.roomFlowCoordinator = roomFlowCoordinator
        // Скрываем таб-бар при входе в комнату
        onTabBarVisibilityChange?(.hidden)
        roomFlowCoordinator.handleAppRoute(.room(roomID: roomID, via: []), animated: true)
    }
}
