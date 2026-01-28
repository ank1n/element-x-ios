//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum WidgetsListScreenViewAction {
    case showSettings
    case selectWidget(WidgetRoomItem)
}

enum WidgetsListScreenViewModelAction {
    case showSettings
    case openWidget(widget: MatrixWidget, roomId: String)
}

struct WidgetsListScreenViewState: BindableState {
    var rooms: [WidgetRoomItem] = []
    var isLoading: Bool = false
}

/// Room with widgets
struct WidgetRoomItem: Identifiable, Equatable {
    let id: String  // Room ID
    let roomName: String
    let roomAvatar: RoomAvatar
    let widgets: [MatrixWidget]
}
