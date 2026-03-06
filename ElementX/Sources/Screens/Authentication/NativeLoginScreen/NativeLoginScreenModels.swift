//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum NativeLoginScreenViewAction {
    case login
    case cancel
}

enum NativeLoginScreenViewModelAction {
    case signedIn(UserSessionProtocol)
    case cancelled
}

struct NativeLoginScreenViewState: BindableState {
    var isLoading = false
    var bindings = NativeLoginScreenBindings()
}

struct NativeLoginScreenBindings {
    var username = ""
    var password = ""
    var alertInfo: AlertInfo<UUID>?
}
