//
// Copyright 2026 Implica Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ArchiveScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let mediaProvider: MediaProviderProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ArchiveScreenCoordinatorAction {
    case selectRoom(roomIdentifier: String)
    case showRoomDetails(roomIdentifier: String)
}

final class ArchiveScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ArchiveScreenViewModel

    private let actionsSubject: PassthroughSubject<ArchiveScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    var actions: AnyPublisher<ArchiveScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ArchiveScreenCoordinatorParameters) {
        viewModel = ArchiveScreenViewModel(userSession: parameters.userSession,
                                           mediaProvider: parameters.mediaProvider,
                                           userIndicatorController: parameters.userIndicatorController)

        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .selectRoom(let roomIdentifier):
                    actionsSubject.send(.selectRoom(roomIdentifier: roomIdentifier))
                case .showRoomDetails(let roomIdentifier):
                    actionsSubject.send(.showRoomDetails(roomIdentifier: roomIdentifier))
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ArchiveScreen(context: viewModel.context))
    }
}
