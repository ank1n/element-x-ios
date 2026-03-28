//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct NativeLoginScreenCoordinatorParameters {
    let authenticationService: AuthenticationServiceProtocol
    let oidcData: OIDCAuthorizationDataProxy
}

enum NativeLoginScreenCoordinatorAction {
    case signedIn(UserSessionProtocol)
    case cancelled
}

final class NativeLoginScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NativeLoginScreenViewModel
    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<NativeLoginScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<NativeLoginScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: NativeLoginScreenCoordinatorParameters) {
        viewModel = NativeLoginScreenViewModel(authenticationService: parameters.authenticationService,
                                               oidcData: parameters.oidcData)

        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .signedIn(let session):
                    self?.actionsSubject.send(.signedIn(session))
                case .cancelled:
                    self?.actionsSubject.send(.cancelled)
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(NavigationStack {
            NativeLoginScreen(context: viewModel.context)
        })
    }
}
