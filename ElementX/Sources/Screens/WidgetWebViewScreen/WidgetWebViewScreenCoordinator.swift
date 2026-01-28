//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct WidgetWebViewScreenCoordinatorParameters {
    let widget: MatrixWidget
    let roomProxy: JoinedRoomProxyProtocol
}

final class WidgetWebViewScreenCoordinator: CoordinatorProtocol {
    private let parameters: WidgetWebViewScreenCoordinatorParameters
    private var viewModel: WidgetWebViewScreenViewModelProtocol

    init(parameters: WidgetWebViewScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = WidgetWebViewScreenViewModel(widget: parameters.widget, roomProxy: parameters.roomProxy)
    }

    func start() {
        // Setup if needed
    }

    func stop() {
        // Cleanup if needed
    }

    func toPresentable() -> AnyView {
        AnyView(WidgetWebViewScreen(context: viewModel.context))
    }
}
