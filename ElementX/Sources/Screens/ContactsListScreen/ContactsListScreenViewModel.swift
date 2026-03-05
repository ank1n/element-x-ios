//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import UIKit

typealias ContactsListScreenViewModelType = StateStoreViewModel<ContactsListScreenViewState, ContactsListScreenViewAction>

protocol ContactsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<ContactsListScreenViewModelAction, Never> { get }
    var context: ContactsListScreenViewModelType.Context { get }
}

class ContactsListScreenViewModel: ContactsListScreenViewModelType, ContactsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let actionsSubject: PassthroughSubject<ContactsListScreenViewModelAction, Never> = .init()
    private var contactsCancellables: Set<AnyCancellable> = []
    private var presenceService: PresenceService?
    private var orgProfileService: OrgProfileService?

    private static let favoritesKey = "ru.implica.stalk.favoriteContacts"
    private var favoriteRoomIDs: Set<String> {
        didSet { saveFavorites() }
    }

    var actionsPublisher: AnyPublisher<ContactsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol) {
        self.userSession = userSession

        let saved = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        self.favoriteRoomIDs = Set(saved)

        var initialState = ContactsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupPresenceService()
        setupOrgProfileService()
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
        case .selectFilter(let filter):
            state.selectedFilter = filter
        case .toggleFavorite(let contact):
            toggleFavorite(contact)
        }
    }

    // MARK: - Private

    private func setupPresenceService() {
        guard let concreteProxy = userSession.clientProxy as? ClientProxy,
              let accessToken = try? concreteProxy.matrixAccessToken() else {
            return
        }

        let homeserver = userSession.clientProxy.homeserver
        let ownUserID = userSession.clientProxy.userID

        presenceService = PresenceService(homeserver: homeserver,
                                          accessToken: accessToken,
                                          ownUserID: ownUserID)

        // Subscribe to presence updates
        presenceService?.presenceSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presenceMap in
                self?.applyPresence(presenceMap)
            }
            .store(in: &contactsCancellables)

        // App lifecycle: foreground → online, background → offline
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self, let presenceService = self.presenceService else { return }
                let userIDs = self.state.contacts.compactMap(\.matrixUserID)
                if !userIDs.isEmpty {
                    presenceService.startPolling(userIDs: userIDs)
                } else {
                    Task { await presenceService.setOwnPresence("online") }
                }
            }
            .store(in: &contactsCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { await self?.presenceService?.setOwnPresence("offline") }
                self?.presenceService?.stopPolling()
            }
            .store(in: &contactsCancellables)
    }

    private func toggleFavorite(_ contact: ContactItem) {
        MXLog.info("[Contacts] toggleFavorite: \(contact.displayName) id=\(contact.id)")
        if favoriteRoomIDs.contains(contact.id) {
            favoriteRoomIDs.remove(contact.id)
        } else {
            favoriteRoomIDs.insert(contact.id)
        }

        if let index = state.contacts.firstIndex(where: { $0.id == contact.id }) {
            state.contacts[index].isFavorite = favoriteRoomIDs.contains(contact.id)
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteRoomIDs), forKey: Self.favoritesKey)
    }

    private func applyPresence(_ presenceMap: [String: UserPresence]) {
        guard !presenceMap.isEmpty else { return }

        var contacts = state.contacts
        for i in contacts.indices {
            guard let matrixUserID = contacts[i].matrixUserID,
                  let presence = presenceMap[matrixUserID] else { continue }
            contacts[i].isOnline = presence.isOnline
            contacts[i].lastSeenDate = presence.lastSeenDate
        }
        state.contacts = contacts
    }

    // MARK: - Org Profile

    private func setupOrgProfileService() {
        guard let concreteProxy = userSession.clientProxy as? ClientProxy,
              let accessToken = try? concreteProxy.matrixAccessToken() else {
            return
        }

        let homeserver = userSession.clientProxy.homeserver

        orgProfileService = OrgProfileService(homeserver: homeserver, accessToken: accessToken)

        orgProfileService?.profilesSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (profilesMap: [String: OrgProfile]) in
                self?.applyOrgProfiles(profilesMap)
            }
            .store(in: &contactsCancellables)
    }

    private func applyOrgProfiles(_ profilesMap: [String: OrgProfile]) {
        guard !profilesMap.isEmpty else { return }

        var contacts = state.contacts
        for i in contacts.indices {
            guard let matrixUserID = contacts[i].matrixUserID,
                  let profile = profilesMap[matrixUserID] else { continue }
            contacts[i].jobTitle = profile.jobTitle
            contacts[i].department = profile.department
        }
        state.contacts = contacts
    }

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

        // Combine main rooms + archived rooms so archived contacts still appear
        let mainRooms = userSession.clientProxy.roomSummaryProvider.roomListPublisher
        let archivedRooms = userSession.clientProxy.alternateRoomSummaryProvider.roomListPublisher
        mainRooms.combineLatest(archivedRooms)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] main, archived in
                self?.updateContacts(from: main + archived)
            }
            .store(in: &contactsCancellables)
    }

    private func updateContacts(from summaries: [RoomSummary]) {
        var seen = Set<String>()
        var contacts: [ContactItem] = []
        var userIDs: [String] = []

        for summary in summaries where summary.isDirect {
            // Пропускаем пустые/покинутые комнаты и дубликаты
            guard summary.activeMembersCount >= 2,
                  !summary.name.hasPrefix("Empty Room"),
                  !seen.contains(summary.id) else {
                continue
            }
            seen.insert(summary.id)

            // Hero — собеседник в DM
            let heroUserID = summary.heroes.first?.userID

            // Preserve existing presence if available
            let presenceMap = presenceService?.presenceSubject.value ?? [:]
            let presence = heroUserID.flatMap { presenceMap[$0] }

            let contact = ContactItem(
                id: summary.id,
                displayName: summary.name,
                avatarURL: summary.avatarURL,
                matrixUserID: heroUserID,
                isOnline: presence?.isOnline ?? false,
                lastSeenDate: presence?.lastSeenDate,
                isFavorite: favoriteRoomIDs.contains(summary.id)
            )
            contacts.append(contact)

            if let heroUserID {
                userIDs.append(heroUserID)
            }
        }

        state.contacts = contacts
        state.isLoading = false

        // Start or update polling with current user IDs
        if !userIDs.isEmpty {
            if presenceService?.presenceSubject.value.isEmpty == true {
                presenceService?.startPolling(userIDs: userIDs)
            } else {
                presenceService?.updatePollingUserIDs(userIDs)
            }

            // Fetch org-profiles for contacts (one-time per user)
            if let orgProfileService {
                Task { await orgProfileService.fetchProfiles(for: userIDs) }
            }
        }
    }
}
