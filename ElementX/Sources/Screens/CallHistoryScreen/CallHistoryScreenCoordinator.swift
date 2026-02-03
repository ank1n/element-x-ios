//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct CallHistoryScreenCoordinatorParameters {
    let callHistoryService: CallHistoryServiceProtocol
}

enum CallHistoryScreenCoordinatorAction {
    case openRecording(URL)
}

final class CallHistoryScreenCoordinator: CoordinatorProtocol {
    private let parameters: CallHistoryScreenCoordinatorParameters
    private let viewModel: CallHistoryScreenViewModel

    private var cancellables = Set<AnyCancellable>()

    var callback: ((CallHistoryScreenCoordinatorAction) -> Void)?

    init(parameters: CallHistoryScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = CallHistoryScreenViewModel(
            callHistoryService: parameters.callHistoryService
        )
    }

    func start() {
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .playRecording(let recording):
                    if let url = recording.playbackURL {
                        self.callback?(.openRecording(url))
                    }
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(CallHistoryScreen(context: viewModel.context))
    }
}
