//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct ContactsListScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
}

enum ContactsListScreenCoordinatorAction {
    case showSettings
    case openChat(roomId: String)
}

final class ContactsListScreenCoordinator: CoordinatorProtocol {
    private let parameters: ContactsListScreenCoordinatorParameters
    private var viewModel: ContactsListScreenViewModelProtocol

    private let actionsSubject: PassthroughSubject<ContactsListScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ContactsListScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ContactsListScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = ContactsListScreenViewModel(userSession: parameters.userSession)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .openChat(let roomId):
                self.actionsSubject.send(.openChat(roomId: roomId))
            }
        }
        .store(in: &cancellables)
    }

    func stop() {
        // Cleanup if needed
    }

    func toPresentable() -> AnyView {
        AnyView(ContactsListScreen(context: viewModel.context))
    }

    private var cancellables = Set<AnyCancellable>()
}
