//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct CallsListScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
}

enum CallsListScreenCoordinatorAction {
    case showSettings
    case startCall(userId: String)
}

final class CallsListScreenCoordinator: CoordinatorProtocol {
    private let parameters: CallsListScreenCoordinatorParameters
    private var viewModel: CallsListScreenViewModelProtocol

    private let actionsSubject: PassthroughSubject<CallsListScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<CallsListScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: CallsListScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = CallsListScreenViewModel(userSession: parameters.userSession)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .startCall(let userId):
                self.actionsSubject.send(.startCall(userId: userId))
            }
        }
        .store(in: &cancellables)
    }

    func stop() {
        // Cleanup if needed
    }

    func toPresentable() -> AnyView {
        AnyView(CallsListScreen(context: viewModel.context))
    }

    private var cancellables = Set<AnyCancellable>()
}
