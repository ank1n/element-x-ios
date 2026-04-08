//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct CallDetailScreenCoordinatorParameters {
    let call: CallHistoryItem
    let callHistoryService: CallHistoryServiceProtocol
    let mediaProvider: MediaProviderProtocol?
}

enum CallDetailScreenCoordinatorAction {
    case dismiss
    case callBack(roomID: String)
}

final class CallDetailScreenCoordinator: CoordinatorProtocol {
    private var viewModel: CallDetailScreenViewModelProtocol
    private let actionsSubject: PassthroughSubject<CallDetailScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    var actionsPublisher: AnyPublisher<CallDetailScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: CallDetailScreenCoordinatorParameters) {
        viewModel = CallDetailScreenViewModel(call: parameters.call,
                                              callHistoryService: parameters.callHistoryService)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                actionsSubject.send(.dismiss)
            case .callBack(let roomID):
                actionsSubject.send(.callBack(roomID: roomID))
            }
        }
        .store(in: &cancellables)
    }

    func stop() { }

    func toPresentable() -> AnyView {
        AnyView(CallDetailScreen(context: viewModel.context))
    }
}
