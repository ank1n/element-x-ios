//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum ContactFilter: CaseIterable {
    case all
    case online
    case favorites

    var title: String {
        switch self {
        case .all: return SL10n.contactsAll
        case .online: return SL10n.contactsOnline
        case .favorites: return SL10n.contactsFavorites
        }
    }
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

    // Filter counts
    var onlineCount: Int { contacts.filter(\.isOnline).count }
    var favoritesCount: Int { contacts.filter(\.isFavorite).count }
}

struct ContactsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Contact item
struct ContactItem: Identifiable, Equatable, Codable {
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
