//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct WidgetsCoordinatorParameters {
    let roomProxy: JoinedRoomProxyProtocol
    let userSession: UserSessionProtocol
}

enum WidgetsCoordinatorAction {
    case dismiss
}

final class WidgetsCoordinator: CoordinatorProtocol {
    private let parameters: WidgetsCoordinatorParameters
    private let widgetService: WidgetService
    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject = PassthroughSubject<WidgetsCoordinatorAction, Never>()
    var actions: AnyPublisher<WidgetsCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: WidgetsCoordinatorParameters) {
        self.parameters = parameters
        self.widgetService = WidgetService(roomProxy: parameters.roomProxy)
    }

    func start() {
        // Initial load handled by view
    }

    func stop() {
        // Cleanup if needed
    }

    func toPresentable() -> AnyView {
        AnyView(
            WidgetsCoordinatorView(
                widgetService: widgetService,
                roomId: parameters.roomProxy.id,
                userId: parameters.userSession.clientProxy.userID,
                displayName: parameters.userSession.clientProxy.userDisplayNamePublisher.value,
                onDismiss: { [weak self] in
                    self?.actionsSubject.send(.dismiss)
                }
            )
        )
    }
}

// MARK: - Coordinator View

private struct WidgetsCoordinatorView: View {
    let widgetService: WidgetService
    let roomId: String
    let userId: String
    let displayName: String?
    let onDismiss: () -> Void

    @State private var selectedWidget: MatrixWidget?

    var body: some View {
        NavigationStack {
            WidgetListView(
                viewModel: WidgetListViewModel(widgetService: widgetService),
                onWidgetSelected: { widget in
                    selectedWidget = widget
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionClose) {
                        onDismiss()
                    }
                }
            }
            .sheet(item: $selectedWidget) { widget in
                WidgetScreen(
                    widget: widget,
                    roomId: roomId,
                    userId: userId,
                    displayName: displayName,
                    onClose: {
                        selectedWidget = nil
                    }
                )
            }
        }
    }
}
