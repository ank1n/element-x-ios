//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ActiveSessionsScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

final class ActiveSessionsScreenCoordinator: CoordinatorProtocol {
    private var viewModel: ActiveSessionsScreenViewModelProtocol

    private let actionsSubject: PassthroughSubject<ActiveSessionsScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<ActiveSessionsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init(parameters: ActiveSessionsScreenCoordinatorParameters) {
        viewModel = ActiveSessionsScreenViewModel(clientProxy: parameters.clientProxy,
                                                  userIndicatorController: parameters.userIndicatorController)

        viewModel.actions
            .sink { [weak self] action in
                self?.actionsSubject.send(action)
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ActiveSessionsScreen(context: viewModel.context))
    }
}
