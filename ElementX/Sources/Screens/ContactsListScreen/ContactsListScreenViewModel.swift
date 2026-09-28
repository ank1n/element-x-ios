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
    /// Guards the async DM find-or-create path against repeated contact taps (duplicate opens).
    private var isOpeningContact = false
    /// STMOB-303: не пускает к справочнику чаще, чем нужно. Подробно — у самого типа ниже.
    private var directoryGate = UserDirectoryFetchGate()
    private let now: () -> Date
    /// STMOB-303: последний известный состав справочника и контакты из комнат. Сеть ходит
    /// за сторожем, а список собирается из этих двух половин локально — см. publishContacts.
    private var directoryUsers: [UserProfileProxy] = []
    private var roomContacts: [ContactItem] = []
    /// Отложенный повтор похода после неудачи. Один на модель.
    private var directoryRetryTask: Task<Void, Never>?

    private static let favoritesKey = "ru.implica.stalk.favoriteContacts"
    private static let contactsCacheKeyPrefix = "ru.implica.stalk.cachedContacts."
    private var favoriteRoomIDs: Set<String> {
        didSet { saveFavorites() }
    }

    var actionsPublisher: AnyPublisher<ContactsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol, now: @escaping () -> Date = Date.init) {
        self.userSession = userSession
        self.now = now

        let saved = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        favoriteRoomIDs = Set(saved)

        var initialState = ContactsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupPresenceService()
        setupOrgProfileService()
        loadCachedContacts()
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

        // Re-entrancy guard: creating a DM is async, so repeated taps while the request is in
        // flight would otherwise fire multiple createDirectRoom calls (duplicate DMs / room opens).
        guard !isOpeningContact else { return }
        isOpeningContact = true
        // Immediate feedback: opening a directory contact with no existing DM needs a network
        // createDirectRoom (~1.5s). Without a visible spinner the tap feels dead and users tap
        // repeatedly — surface a per-row spinner for the whole async path.
        state.openingContactID = contact.id

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isOpeningContact = false
                self.state.openingContactID = nil
            }

            // First try to find existing DM (fast, local m.direct lookup)
            if case .success(let existingRoomID) = userSession.clientProxy.directRoomForUserID(matrixUserID),
               let roomID = existingRoomID {
                actionsSubject.send(.openChat(roomId: roomID))
                return
            }

            // No existing DM — create it (network round-trip)
            let result = await userSession.clientProxy.createDirectRoom(with: matrixUserID,
                                                                        expectedRoomName: contact.displayName)
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
        // Build 125: shared PresenceService из AppCoordinator (sync с HomeScreen + RoomScreen).
        // Fallback на локальный instance если shared отсутствует (тест scenarios).
        if let shared = AppCoordinator.sharedPresenceService {
            presenceService = shared
        } else if let concreteProxy = userSession.clientProxy as? ClientProxy {
            // STMOB-109 build 138: tokenProvider вместо immutable accessToken —
            // см. PresenceService.swift про token rotation fix.
            // STMOB-132 build 153: + tokenRefresher для force refresh на 401.
            presenceService = PresenceService(homeserver: userSession.clientProxy.homeserver,
                                              tokenProvider: { [weak concreteProxy] in
                                                  try? concreteProxy?.matrixAccessToken()
                                              },
                                              tokenRefresher: { [weak concreteProxy] in
                                                  await concreteProxy?.forceTokenRefresh()
                                              },
                                              ownUserID: userSession.clientProxy.userID)
        } else {
            return
        }

        // Subscribe to presence updates
        presenceService?.presenceSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presenceMap in
                self?.applyPresence(presenceMap)
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

    // MARK: - Contact Cache

    private var contactsCacheKey: String {
        Self.contactsCacheKeyPrefix + userSession.clientProxy.userID
    }

    private func loadCachedContacts() {
        guard let data = UserDefaults.standard.data(forKey: contactsCacheKey),
              let cached = try? JSONDecoder().decode([ContactItem].self, from: data) else { return }
        MXLog.info("[Contacts] Loaded \(cached.count) cached contacts")
        state.contacts = cached
        // Кэш раскладываем на те же две половины, из которых список собирается дальше:
        // иначе первое же изменение списка комнат стёрло бы справочные записи до похода.
        roomContacts = cached.filter { !$0.id.hasPrefix("@") }
        directoryUsers = cached.filter { $0.id.hasPrefix("@") }.map {
            UserProfileProxy(userID: $0.matrixUserID ?? $0.id, displayName: $0.displayName, avatarURL: $0.avatarURL)
        }
    }

    private func saveCachedContacts() {
        let contacts = state.contacts
        guard !contacts.isEmpty,
              let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: contactsCacheKey)
        MXLog.info("[Contacts] Saved \(contacts.count) contacts to cache")
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

        // Source 1: DM rooms (isDirect, exactly 2 members = 1-on-1)
        for summary in summaries where summary.isDirect {
            guard summary.activeMembersCount == 2,
                  !summary.name.hasPrefix("Empty Room"),
                  !summary.name.hasSuffix(" people"),
                  !seen.contains(summary.id) else { continue }

            // Дедупликация по userID — один юзер может иметь несколько DM комнат
            let heroUserID = summary.heroes.first?.userID
            if let heroUserID, seenUserIDs.contains(heroUserID) { continue }

            seen.insert(summary.id)
            if let heroUserID { seenUserIDs.insert(heroUserID) }
            let presence = heroUserID.flatMap { presenceMap[$0] }

            // For DMs, use hero's avatar (user profile pic) if room has no avatar
            let contactAvatarURL = summary.avatarURL ?? summary.heroes.first?.avatarURL

            contacts.append(ContactItem(id: summary.id,
                                        displayName: summary.name,
                                        avatarURL: contactAvatarURL,
                                        matrixUserID: heroUserID,
                                        isOnline: presence?.isOnline ?? false,
                                        lastSeenDate: presence?.lastSeenDate,
                                        isFavorite: favoriteRoomIDs.contains(summary.id)))

            if let heroUserID { userIDs.append(heroUserID) }
        }

        // Source 2: 2-member rooms (not isDirect, but exactly 1 hero = 1 other person → treat as contact)
        for summary in summaries where !summary.isDirect {
            guard summary.activeMembersCount == 2,
                  summary.heroes.count == 1,
                  !summary.name.hasPrefix("Empty Room"),
                  !summary.name.contains(","),
                  !seen.contains(summary.id) else { continue }

            // Skip if the hero user was already added from a DM
            let heroUserID = summary.heroes.first?.userID
            if let heroUserID, seenUserIDs.contains(heroUserID) { continue }

            seen.insert(summary.id)
            if let heroUserID { seenUserIDs.insert(heroUserID) }
            let presence = heroUserID.flatMap { presenceMap[$0] }

            // For 2-member rooms, use hero's avatar if room has no avatar
            let contactAvatarURL = summary.avatarURL ?? summary.heroes.first?.avatarURL

            contacts.append(ContactItem(id: summary.id,
                                        displayName: summary.name,
                                        avatarURL: contactAvatarURL,
                                        matrixUserID: heroUserID,
                                        isOnline: presence?.isOnline ?? false,
                                        lastSeenDate: presence?.lastSeenDate,
                                        isFavorite: favoriteRoomIDs.contains(summary.id)))

            if let heroUserID { userIDs.append(heroUserID) }
        }

        roomContacts = contacts
        publishContacts()
        state.isLoading = false
        saveCachedContacts()

        // Start or update polling with current user IDs
        if !userIDs.isEmpty {
            // Build 125: merge с existing polling — НЕ перезаписываем (другие screens
            // могли добавить свои userIDs).
            if let presenceService {
                let merged = Array(Set(presenceService.currentUserIDs).union(userIDs))
                if presenceService.currentUserIDs.isEmpty {
                    presenceService.startPolling(userIDs: merged)
                } else {
                    presenceService.updatePollingUserIDs(merged)
                    Task { await presenceService.fetchPresence(for: userIDs) }
                }
            }

            if let orgProfileService {
                Task { await orgProfileService.fetchProfiles(for: userIDs) }
            }
        }

        // Source 3: User Directory — async fetch server-wide users
        requestDirectoryFetch()
    }

    /// STMOB-303: собирает список из двух половин — контактов из комнат и последнего известного
    /// состава справочника. Без сети; зовётся на каждом изменении списка комнат и после похода.
    ///
    /// Справочную запись человека, у которого есть личный чат, не выбрасываем, а только прячем.
    /// Раньше её выбрасывали, и держалось это лишь на том, что справочник перезагружался на
    /// каждое изменение. С тех пор как поход идёт за сторожем раз в десять минут, выброшенная
    /// запись пропадала бы на эти десять минут, стоило личному чату исчезнуть из списка комнат:
    /// поиск или фильтр в «Чатах» (они сужают тот же общий список), выход из чата.
    private func publishContacts() {
        let ownUserID = userSession.clientProxy.userID
        let roomUserIDs = Set(roomContacts.compactMap(\.matrixUserID))
        let presenceMap = presenceService?.presenceSubject.value ?? [:]
        let orgProfiles = orgProfileService?.profilesSubject.value ?? [:]
        // То, что уже известно о человеке (присутствие, должность), при пересборке не теряем,
        // даже если свежих данных ещё нет — например, сразу после загрузки из кэша.
        let known = Dictionary(state.contacts.compactMap { contact in contact.matrixUserID.map { ($0, contact) } },
                               uniquingKeysWith: { first, _ in first })

        let directoryContacts = directoryUsers
            .filter { $0.userID != ownUserID && !roomUserIDs.contains($0.userID) }
            .map { user in
                ContactItem(id: user.userID,
                            displayName: user.displayName ?? user.userID.replacingOccurrences(of: "@", with: "").components(separatedBy: ":").first ?? user.userID,
                            avatarURL: user.avatarURL,
                            matrixUserID: user.userID,
                            isOnline: false,
                            lastSeenDate: nil,
                            isFavorite: false)
            }

        state.contacts = (roomContacts + directoryContacts).map { contact in
            var contact = contact
            contact.isFavorite = favoriteRoomIDs.contains(contact.id)
            guard let userID = contact.matrixUserID else { return contact }

            if let presence = presenceMap[userID] {
                contact.isOnline = presence.isOnline
                contact.lastSeenDate = presence.lastSeenDate
            } else if let previous = known[userID] {
                contact.isOnline = previous.isOnline
                contact.lastSeenDate = previous.lastSeenDate
            }

            let profile = orgProfiles[userID]
            contact.jobTitle = profile?.jobTitle ?? known[userID]?.jobTitle
            contact.department = profile?.department ?? known[userID]?.department
            return contact
        }
    }

    /// STMOB-303: сюда приходит КАЖДОЕ изменение списка комнат — новое сообщение в любом чате,
    /// прочтение, смена аватарки, поиск в «Чатах». Раньше каждое такое изменение сразу уходило
    /// в справочник, и на проде это давало до 1422 запросов в минуту. Теперь решает сторож:
    /// чаще раза в `refreshInterval` не ходим, одновременно — не больше одного похода,
    /// после отказа ждём.
    private func requestDirectoryFetch() {
        guard directoryGate.tryBegin(now: now()) else { return }

        Task { [weak self] in
            guard let self else { return }
            let result = await fetchUserDirectory()
            directoryGate.finish(result.outcome, now: now())
            applyDirectory(result)

            if result.outcome == .success {
                directoryRetryTask?.cancel()
                directoryRetryTask = nil
            } else {
                MXLog.warning("[Contacts] fetchUserDirectory: \(result.outcome), следующий поход не раньше \(directoryGate.nextAllowed)")
                scheduleDirectoryRetry()
            }
        }
    }

    /// Повтор после неудачи не должен зависеть от того, изменится ли что-то в комнатах:
    /// у нового сотрудника с пустым кэшем и без чатов изменений может не быть вовсе, и
    /// «Контакты» остались бы пустыми до перезапуска.
    ///
    /// Сон здесь только будит, а не меряет время: если приложение заморозят в фоне, повтор
    /// просто случится позже, а пускать ли его — решает сторож по часам.
    private func scheduleDirectoryRetry() {
        directoryRetryTask?.cancel()
        let delay = max(directoryGate.nextAllowed.timeIntervalSince(now()), 0)
        directoryRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.requestDirectoryFetch()
        }
    }

    private struct DirectoryFetchResult {
        let outcome: UserDirectoryFetchGate.Outcome
        let users: [UserProfileProxy]
        /// Весь справочник, а не его часть: можно заменить им прежний состав целиком.
        let isComplete: Bool
    }

    /// Fetch all users from User Directory.
    /// Requires Synapse config: user_directory.search_all_users: true
    ///
    /// STMOB-303: любая ошибка останавливает поход целиком. Раньше отказ пустого поиска
    /// выглядел как «пустой результат» и запускал перебор алфавита — один отказ 429
    /// превращался в 27 запросов, каждый из которых тоже получал 429.
    private func fetchUserDirectory() async -> DirectoryFetchResult {
        // Try empty search first (requires search_all_users: true)
        switch await userSession.clientProxy.searchUsers(searchTerm: "", limit: 500) {
        case .success(let searchResults) where !searchResults.results.isEmpty:
            MXLog.info("[Contacts] fetchUserDirectory: empty search returned \(searchResults.results.count)")
            return DirectoryFetchResult(outcome: .success, users: searchResults.results, isComplete: true)
        case .success:
            break
        case .failure(let error):
            // Пустого результата не было — был отказ. Перебор букв здесь только
            // умножил бы отказы, поэтому возвращаемся сразу.
            return DirectoryFetchResult(outcome: .init(error), users: [], isComplete: false)
        }

        // Fallback: if empty search returns nothing, search by common letters
        MXLog.info("[Contacts] fetchUserDirectory: fallback — searching a-z")
        var allUsers: [String: UserProfileProxy] = [:]
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            switch await userSession.clientProxy.searchUsers(searchTerm: String(letter), limit: 50) {
            case .success(let sr):
                for u in sr.results {
                    allUsers[u.userID] = u
                }
            case .failure(let error):
                // Собранное до отказа не выбрасываем — показываем, что успели.
                MXLog.warning("[Contacts] fetchUserDirectory: fallback stopped at '\(letter)'")
                return DirectoryFetchResult(outcome: .init(error), users: Array(allUsers.values), isComplete: false)
            }
        }
        MXLog.info("[Contacts] fetchUserDirectory: fallback found \(allUsers.count) unique users")
        return DirectoryFetchResult(outcome: .success, users: Array(allUsers.values), isComplete: true)
    }

    private func applyDirectory(_ result: DirectoryFetchResult) {
        let ownUserID = userSession.clientProxy.userID
        let previousUserIDs = Set(directoryUsers.map(\.userID))

        if result.isComplete {
            var seen = Set<String>()
            directoryUsers = result.users.filter { seen.insert($0.userID).inserted }
        } else if !result.users.isEmpty {
            // Часть справочника: дополняем и освежаем, но никого не выбрасываем.
            var merged = Dictionary(directoryUsers.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })
            for user in result.users {
                merged[user.userID] = user
            }
            directoryUsers = Array(merged.values)
        } else {
            return
        }

        publishContacts()
        MXLog.info("[Contacts] directory users: \(directoryUsers.count), total contacts now: \(state.contacts.count)")
        saveCachedContacts()

        let newUserIDs = directoryUsers.map(\.userID).filter { $0 != ownUserID && !previousUserIDs.contains($0) }
        guard !newUserIDs.isEmpty else { return }

        presenceService?.updatePollingUserIDs((presenceService?.currentUserIDs ?? []) + newUserIDs)
        if let orgProfileService {
            Task { await orgProfileService.fetchProfiles(for: newUserIDs) }
        }
    }
}

// MARK: - STMOB-303

/// Сторож походов «Контактов» в справочник пользователей Synapse.
///
/// Раньше «Контакты» шли в справочник на КАЖДОЕ изменение списка комнат, и каждый поход
/// был пустым поиском плюс перебором 26 букв. Отказ 429 выглядел как пустой результат и
/// сам запускал перебор, поэтому один отказ превращался в 27 запросов, а следующее
/// сообщение в любом чате добавляло ещё 27 поверх. На проде — до 1422 запросов в минуту,
/// 80% отбиты сервером.
///
/// Правила:
/// - одновременно не больше одного похода;
/// - после удачи — не чаще раза в `refreshInterval`: состав справочника от новых сообщений
///   не меняется, а видимые контакты и так держатся из кэша;
/// - после отказа — отступ с удвоением от `initialBackoff`, но не меньше, чем просит сервер
///   в `retry_after_ms`, и не больше `maxBackoff`.
///
/// Сам сторож только решает «можно ли сейчас» по часам. Повтор после отказа планирует
/// модель (scheduleDirectoryRetry), чтобы он не зависел от изменений в комнатах.
struct UserDirectoryFetchGate {
    enum Outcome: Equatable, CustomStringConvertible {
        case success
        case rateLimited(retryAfter: TimeInterval?)
        case failed

        init(_ error: ClientProxyError) {
            self = error.isRateLimited ? .rateLimited(retryAfter: error.retryAfter) : .failed
        }

        var description: String {
            switch self {
            case .success: "успех"
            case .rateLimited(let retryAfter): "отказ по частоте, сервер просит \(retryAfter.map { "\($0) с" } ?? "без срока")"
            case .failed: "ошибка"
            }
        }
    }

    var refreshInterval: TimeInterval = 10 * 60
    var initialBackoff: TimeInterval = 1
    var maxBackoff: TimeInterval = 10 * 60

    private(set) var isInFlight = false
    private(set) var nextAllowed = Date.distantPast
    private(set) var consecutiveFailures = 0

    /// Можно ли идти сейчас. Если да — поход считается начатым до вызова `finish`.
    mutating func tryBegin(now: Date) -> Bool {
        guard !isInFlight, now >= nextAllowed else { return false }
        isInFlight = true
        return true
    }

    mutating func finish(_ outcome: Outcome, now: Date) {
        isInFlight = false

        switch outcome {
        case .success:
            consecutiveFailures = 0
            nextAllowed = now.addingTimeInterval(refreshInterval)
        case .rateLimited(let retryAfter):
            consecutiveFailures += 1
            // Просьбу сервера уважаем, но не больше потолка: модель живёт всю сессию, и
            // ошибочный огромный срок закрыл бы справочник до перезапуска приложения.
            nextAllowed = now.addingTimeInterval(min(max(retryAfter ?? 0, currentBackoff), maxBackoff))
        case .failed:
            consecutiveFailures += 1
            nextAllowed = now.addingTimeInterval(currentBackoff)
        }
    }

    /// 1, 2, 4, 8… секунд с потолком. Степень ограничена, чтобы не уйти в бесконечность.
    private var currentBackoff: TimeInterval {
        let exponent = Double(min(max(consecutiveFailures - 1, 0), 30))
        return min(initialBackoff * pow(2, exponent), maxBackoff)
    }
}
