//
// Copyright 2026 Implica Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ArchiveScreenViewModelAction {
    case selectRoom(roomIdentifier: String)
    case showRoomDetails(roomIdentifier: String)
}

enum ArchiveScreenViewAction {
    case selectRoom(roomIdentifier: String)
    case unarchiveRoom(roomIdentifier: String)
    case showRoomDetails(roomIdentifier: String)
    case leaveRoom(roomIdentifier: String)
    case confirmLeaveRoom(roomIdentifier: String)
}

struct ArchiveScreenViewState: BindableState {
    var rooms: [HomeScreenRoom] = []
    var isLoading = true
    var bindings = ArchiveScreenViewStateBindings()
}

struct ArchiveScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
    var leaveRoomAlertItem: LeaveRoomAlertItem?
}
