//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct WidgetsListScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    var availability: ApplicationAvailabilityService?
}

enum WidgetsListScreenCoordinatorAction {
    case showSettings
    case openWidget(WidgetItem)
}

final class WidgetsListScreenCoordinator: CoordinatorProtocol {
    private let parameters: WidgetsListScreenCoordinatorParameters
    private var viewModel: WidgetsListScreenViewModelProtocol

    private let actionsSubject: PassthroughSubject<WidgetsListScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<WidgetsListScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: WidgetsListScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = WidgetsListScreenViewModel(userSession: parameters.userSession, availability: parameters.availability)
    }

    func start() {
        if let availability = parameters.availability {
            availability.$snapshot.removeDuplicates().dropFirst().sink { [weak self] _ in
                self?.viewModel.context.send(viewAction: .refresh)
            }.store(in: &cancellables)
        }
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .openWidget(let widget):
                self.actionsSubject.send(.openWidget(widget))
            }
        }
        .store(in: &cancellables)
    }

    func stop() {
        // Cleanup if needed
    }

    func toPresentable() -> AnyView {
        AnyView(WidgetsListScreen(context: viewModel.context))
    }

    private var cancellables = Set<AnyCancellable>()
}
