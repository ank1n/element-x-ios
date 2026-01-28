//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum SavedAccountsScreenViewModelAction {
    /// User selected a saved account to sign in
    case selectAccount(SavedAccount)
    /// User wants to add a new server
    case addNewServer
    /// User dismissed the screen
    case dismiss
}

struct SavedAccountsScreenViewState: BindableState {
    /// List of saved accounts sorted by last used
    var accounts: [SavedAccount]
    /// Whether the list is empty (first-time user)
    var isEmpty: Bool { accounts.isEmpty }

    var bindings = SavedAccountsScreenBindings()
}

struct SavedAccountsScreenBindings {
    var alertInfo: AlertInfo<SavedAccountsScreenAlertType>?
}

enum SavedAccountsScreenAlertType: Hashable {
    case deleteConfirmation(accountId: String)
}

enum SavedAccountsScreenViewAction {
    /// User tapped on a saved account
    case selectAccount(SavedAccount)
    /// User tapped "Add new server"
    case addNewServer
    /// User swiped to delete an account
    case deleteAccount(id: String)
    /// User tapped back/dismiss
    case dismiss
}
