//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

typealias SavedAccountsScreenViewModelType = StateStoreViewModelV2<SavedAccountsScreenViewState, SavedAccountsScreenViewAction>

class SavedAccountsScreenViewModel: SavedAccountsScreenViewModelType, SavedAccountsScreenViewModelProtocol {
    private let savedAccountsStore: SavedAccountsStore
    private let actionsSubject: PassthroughSubject<SavedAccountsScreenViewModelAction, Never> = .init()

    var actions: AnyPublisher<SavedAccountsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(savedAccountsStore: SavedAccountsStore) {
        self.savedAccountsStore = savedAccountsStore

        let accounts = savedAccountsStore.getAll()
        let initialViewState = SavedAccountsScreenViewState(accounts: accounts)
        super.init(initialViewState: initialViewState)
    }

    override func process(viewAction: SavedAccountsScreenViewAction) {
        switch viewAction {
        case .selectAccount(let account):
            actionsSubject.send(.selectAccount(account))
        case .addNewServer:
            actionsSubject.send(.addNewServer)
        case .deleteAccount(let id):
            savedAccountsStore.delete(id: id)
            state.accounts = savedAccountsStore.getAll()
        case .dismiss:
            actionsSubject.send(.dismiss)
        }
    }
}
