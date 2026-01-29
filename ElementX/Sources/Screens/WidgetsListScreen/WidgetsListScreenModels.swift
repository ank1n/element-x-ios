//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum WidgetsListScreenViewAction {
    case showSettings
    case selectWidget(WidgetItem)
}

enum WidgetsListScreenViewModelAction {
    case showSettings
    case openWidget(WidgetItem)
}

struct WidgetsListScreenViewState: BindableState {
    var widgets: [WidgetItem] = []
    var isLoading: Bool = false
    var searchQuery = ""

    // User info for avatar
    var userID: String = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    var bindings = WidgetsListScreenViewStateBindings()
}

struct WidgetsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Available widget
struct WidgetItem: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let url: String
}
