//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct SavedAccountsScreenCoordinatorParameters {
    let savedAccountsStore: SavedAccountsStore
}

enum SavedAccountsScreenCoordinatorAction {
    /// User selected a saved account
    case selectAccount(SavedAccount)
    /// User wants to add a new server
    case addNewServer
    /// User dismissed the screen
    case dismiss
}

final class SavedAccountsScreenCoordinator: CoordinatorProtocol {
    private var viewModel: SavedAccountsScreenViewModelProtocol
    private let actionsSubject: PassthroughSubject<SavedAccountsScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    var actions: AnyPublisher<SavedAccountsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: SavedAccountsScreenCoordinatorParameters) {
        viewModel = SavedAccountsScreenViewModel(savedAccountsStore: parameters.savedAccountsStore)
    }

    func start() {
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .selectAccount(let account):
                    actionsSubject.send(.selectAccount(account))
                case .addNewServer:
                    actionsSubject.send(.addNewServer)
                case .dismiss:
                    actionsSubject.send(.dismiss)
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(SavedAccountsScreen(context: viewModel.context))
    }
}
