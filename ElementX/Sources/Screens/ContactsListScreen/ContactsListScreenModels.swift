//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum ContactsListScreenViewAction {
    case showSettings
    case selectContact(ContactItem)
    case addContact
}

enum ContactsListScreenViewModelAction {
    case showSettings
    case openChat(roomId: String)
}

struct ContactsListScreenViewState: BindableState {
    var contacts: [ContactItem] = []
    var isLoading: Bool = false
    var searchQuery = ""

    // User info for avatar
    var userID: String = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    var bindings = ContactsListScreenViewStateBindings()
}

struct ContactsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Contact item
struct ContactItem: Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatarURL: URL?
    let isOnline: Bool
}
