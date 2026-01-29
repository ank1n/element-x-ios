//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias ContactsListScreenViewModelType = StateStoreViewModel<ContactsListScreenViewState, ContactsListScreenViewAction>

protocol ContactsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<ContactsListScreenViewModelAction, Never> { get }
    var context: ContactsListScreenViewModelType.Context { get }
}

class ContactsListScreenViewModel: ContactsListScreenViewModelType, ContactsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let actionsSubject: PassthroughSubject<ContactsListScreenViewModelAction, Never> = .init()
    private var contactsCancellables: Set<AnyCancellable> = []

    var actionsPublisher: AnyPublisher<ContactsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol) {
        self.userSession = userSession

        var initialState = ContactsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
    }

    override func process(viewAction: ContactsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectContact(let contact):
            actionsSubject.send(.openChat(roomId: contact.id))
        case .addContact:
            break
        }
    }

    // MARK: - Private

    private func setupSubscriptions() {
        state.isLoading = true

        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &contactsCancellables)

        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &contactsCancellables)

        userSession.sessionSecurityStatePublisher
            .map { $0.verificationState != .verified || $0.recoveryState != .enabled }
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.requiresExtraAccountSetup, on: self)
            .store(in: &contactsCancellables)

        userSession.clientProxy.roomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summaries in
                self?.updateContacts(from: summaries)
            }
            .store(in: &contactsCancellables)
    }

    private func updateContacts(from summaries: [RoomSummary]) {
        var contacts: [ContactItem] = []

        for summary in summaries where summary.isDirect {
            let contact = ContactItem(
                id: summary.id,
                displayName: summary.name,
                avatarURL: nil,
                isOnline: false
            )
            contacts.append(contact)
        }

        state.contacts = contacts
        state.isLoading = false
    }
}
