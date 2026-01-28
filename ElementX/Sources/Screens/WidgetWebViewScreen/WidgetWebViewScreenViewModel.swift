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
    private let widget: MatrixWidget
    private let roomProxy: JoinedRoomProxyProtocol

    init(widget: MatrixWidget, roomProxy: JoinedRoomProxyProtocol) {
        self.widget = widget
        self.roomProxy = roomProxy

        let webViewModel = WidgetWebViewModel()

        let initialState = WidgetWebViewScreenViewState(
            widget: widget,
            roomId: roomProxy.id,
            userId: roomProxy.ownUserID,
            displayName: nil,  // TODO: Get user display name
            webViewModel: webViewModel
        )
        super.init(initialViewState: initialState)
    }

    override func process(viewAction: WidgetWebViewScreenViewAction) {
        switch viewAction {
        case .close:
            break  // Handled by coordinator
        }
    }
}
