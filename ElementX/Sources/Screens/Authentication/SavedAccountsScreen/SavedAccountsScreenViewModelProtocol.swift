//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine

@MainActor
protocol SavedAccountsScreenViewModelProtocol {
    var actions: AnyPublisher<SavedAccountsScreenViewModelAction, Never> { get }
    var context: SavedAccountsScreenViewModel.Context { get }
}
