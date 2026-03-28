//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum MessageSearchScreenViewAction {
    case search
    case loadMore
    case selectResult(roomID: String, eventID: String)
    case dismiss
}

enum MessageSearchScreenViewModelAction {
    case openRoomAtEvent(roomID: String, eventID: String)
    case dismiss
}

struct MessageSearchScreenViewState: BindableState {
    var results: [MessageSearchScreenResult] = []
    var isLoading = false
    var totalCount = 0
    var hasMore = false
    var bindings = MessageSearchScreenBindings()
}

struct MessageSearchScreenBindings {
    var searchQuery = ""
}

struct MessageSearchScreenResult: Identifiable {
    let eventID: String
    let roomID: String
    let roomName: String?
    let senderName: String
    let body: String
    let timestamp: Date

    var id: String {
        eventID
    }
}
