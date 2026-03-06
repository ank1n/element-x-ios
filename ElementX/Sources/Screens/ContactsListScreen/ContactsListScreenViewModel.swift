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
            openContact(contact)
        case .addContact:
            break
        case .selectFilter(let filter):
            state.selectedFilter = filter
        case .toggleFavorite(let contact):
            toggleFavorite(contact)
        }
    }

    /// Open a contact. If it's a room-based contact, navigate directly.
    /// If it's a User Directory contact (id starts with @), find or create a DM room first.
    private func openContact(_ contact: ContactItem) {
        // Room-based contacts have room IDs (start with !)
        if contact.id.hasPrefix("!") {
            actionsSubject.send(.openChat(roomId: contact.id))
            return
        }

        // User Directory contact — find or create DM
        guard let matrixUserID = contact.matrixUserID else { return }

        Task { [weak self] in
            guard let self else { return }

            // First try to find existing DM
            if case .success(let existingRoomID) = userSession.clientProxy.directRoomForUserID(matrixUserID),
               let roomID = existingRoomID {
                actionsSubject.send(.openChat(roomId: roomID))
                return
            }

            // Create new DM
            let result = await userSession.clientProxy.createDirectRoom(
                with: matrixUserID,
                expectedRoomName: contact.displayName
            )
            switch result {
            case .success(let roomID):
                actionsSubject.send(.openChat(roomId: roomID))
            case .failure(let error):
                MXLog.error("[Contacts] Failed to create DM with \(matrixUserID): \(error)")
            }
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
        var seen = Set<String>() // roomID dedup
        var seenUserIDs = Set<String>() // userID dedup across sources
        var contacts: [ContactItem] = []
        var userIDs: [String] = []
        let ownUserID = userSession.clientProxy.userID
        let presenceMap = presenceService?.presenceSubject.value ?? [:]

        // Source 1: DM rooms (isDirect)
        for summary in summaries where summary.isDirect {
            guard summary.activeMembersCount >= 2,
                  !summary.name.hasPrefix("Empty Room"),
                  !seen.contains(summary.id) else { continue }
            seen.insert(summary.id)

            let heroUserID = summary.heroes.first?.userID
            if let heroUserID { seenUserIDs.insert(heroUserID) }
            let presence = heroUserID.flatMap { presenceMap[$0] }

            contacts.append(ContactItem(
                id: summary.id,
                displayName: summary.name,
                avatarURL: summary.avatarURL,
                matrixUserID: heroUserID,
                isOnline: presence?.isOnline ?? false,
                lastSeenDate: presence?.lastSeenDate,
                isFavorite: favoriteRoomIDs.contains(summary.id)
            ))

            if let heroUserID { userIDs.append(heroUserID) }
        }

        // Source 2: 2-member rooms (not isDirect, but only 2 active members → treat as contact)
        for summary in summaries where !summary.isDirect {
            guard summary.activeMembersCount == 2,
                  !summary.name.hasPrefix("Empty Room"),
                  !seen.contains(summary.id) else { continue }

            // Skip if the hero user was already added from a DM
            let heroUserID = summary.heroes.first?.userID
            if let heroUserID, seenUserIDs.contains(heroUserID) { continue }

            seen.insert(summary.id)
            if let heroUserID { seenUserIDs.insert(heroUserID) }
            let presence = heroUserID.flatMap { presenceMap[$0] }

            contacts.append(ContactItem(
                id: summary.id,
                displayName: summary.name,
                avatarURL: summary.avatarURL,
                matrixUserID: heroUserID,
                isOnline: presence?.isOnline ?? false,
                lastSeenDate: presence?.lastSeenDate,
                isFavorite: favoriteRoomIDs.contains(summary.id)
            ))

            if let heroUserID { userIDs.append(heroUserID) }
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

            if let orgProfileService {
                Task { await orgProfileService.fetchProfiles(for: userIDs) }
            }
        }

        // Source 3: User Directory — async fetch server-wide users
        fetchUserDirectory(existingUserIDs: seenUserIDs)
    }

    /// Fetch all users from User Directory that aren't already in the contacts list.
    /// Requires Synapse config: user_directory.search_all_users: true
    private func fetchUserDirectory(existingUserIDs: Set<String>) {
        Task { [weak self] in
            guard let self else { return }
            let ownUserID = userSession.clientProxy.userID

            MXLog.info("[Contacts] fetchUserDirectory: existingUserIDs=\(existingUserIDs.count)")

            // Try empty search first (requires search_all_users: true)
            var users: [UserProfileProxy] = []
            let result = await userSession.clientProxy.searchUsers(searchTerm: "", limit: 500)
            if case .success(let searchResults) = result {
                users = searchResults.results
                MXLog.info("[Contacts] fetchUserDirectory: empty search returned \(users.count)")
            }

            // Fallback: if empty search returns nothing, search by common letters
            if users.isEmpty {
                MXLog.info("[Contacts] fetchUserDirectory: fallback — searching a-z")
                var allUsers: [String: UserProfileProxy] = [:]
                for letter in "abcdefghijklmnopqrstuvwxyz" {
                    let r = await userSession.clientProxy.searchUsers(searchTerm: String(letter), limit: 50)
                    if case .success(let sr) = r {
                        for u in sr.results { allUsers[u.userID] = u }
                    }
                }
                users = Array(allUsers.values)
                MXLog.info("[Contacts] fetchUserDirectory: fallback found \(users.count) unique users")
            }

            guard !users.isEmpty else { return }

            let presenceMap = presenceService?.presenceSubject.value ?? [:]
            var newContacts: [ContactItem] = []
            var newUserIDs: [String] = []

            for user in users {
                guard user.userID != ownUserID,
                      !existingUserIDs.contains(user.userID) else { continue }

                let presence = presenceMap[user.userID]
                newContacts.append(ContactItem(
                    id: user.userID,
                    displayName: user.displayName ?? user.userID.replacingOccurrences(of: "@", with: "").components(separatedBy: ":").first ?? user.userID,
                    avatarURL: user.avatarURL,
                    matrixUserID: user.userID,
                    isOnline: presence?.isOnline ?? false,
                    lastSeenDate: presence?.lastSeenDate,
                    isFavorite: favoriteRoomIDs.contains(user.userID)
                ))
                newUserIDs.append(user.userID)
            }

            guard !newContacts.isEmpty else { return }
            MXLog.info("[Contacts] fetchUserDirectory: adding \(newContacts.count) new contacts")

            await MainActor.run {
                let existingIDs = Set(self.state.contacts.map(\.id))
                let existingMatrixIDs = Set(self.state.contacts.compactMap(\.matrixUserID))
                let filtered = newContacts.filter { !existingIDs.contains($0.id) && !existingMatrixIDs.contains($0.matrixUserID ?? "") }
                self.state.contacts.append(contentsOf: filtered)
                MXLog.info("[Contacts] total contacts now: \(self.state.contacts.count)")
            }

            if !newUserIDs.isEmpty {
                presenceService?.updatePollingUserIDs(
                    (presenceService?.currentUserIDs ?? []) + newUserIDs
                )
                if let orgProfileService {
                    await orgProfileService.fetchProfiles(for: newUserIDs)
                }
            }
        }
    }
}
