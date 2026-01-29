//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias WidgetWebViewScreenViewModelType = StateStoreViewModel<WidgetWebViewScreenViewState, WidgetWebViewScreenViewAction>

protocol WidgetWebViewScreenViewModelProtocol {
    var context: WidgetWebViewScreenViewModelType.Context { get }
}

class WidgetWebViewScreenViewModel: WidgetWebViewScreenViewModelType, WidgetWebViewScreenViewModelProtocol {
    init(widget: WidgetItem) {
        let initialState = WidgetWebViewScreenViewState(widget: widget)
        super.init(initialViewState: initialState)
    }

    override func process(viewAction: WidgetWebViewScreenViewAction) {
        switch viewAction {
        case .close:
            break  // Handled by coordinator
        }
    }
}
