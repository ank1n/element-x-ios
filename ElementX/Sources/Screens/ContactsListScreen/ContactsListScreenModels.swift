//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum ContactFilter: String, CaseIterable {
    case all = "Все"
    case online = "В сети"
    case favorites = "Избранные"
}

enum ContactsListScreenViewAction {
    case showSettings
    case selectContact(ContactItem)
    case addContact
    case selectFilter(ContactFilter)
    case toggleFavorite(ContactItem)
}

enum ContactsListScreenViewModelAction {
    case showSettings
    case openChat(roomId: String)
}

struct ContactsListScreenViewState: BindableState {
    var contacts: [ContactItem] = []
    var isLoading: Bool = false
    var searchQuery = ""
    var selectedFilter: ContactFilter = .all

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
    let matrixUserID: String?
    var isOnline: Bool
    var lastSeenDate: Date?
    var isFavorite: Bool
    // org-profile fields
    var jobTitle: String?
    var department: String?
}
