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
    /// STMOB-304: строка появилась на экране / ушла с него — присутствие опрашиваем только для видимых.
    case contactRowAppeared(ContactItem.ID)
    case contactRowDisappeared(ContactItem.ID)
}

enum ContactsListScreenViewModelAction {
    case showSettings
    case openChat(roomId: String)
}

struct ContactsListScreenViewState: BindableState {
    var contacts: [ContactItem] = []
    var isLoading = false
    var searchQuery = ""
    var selectedFilter: ContactFilter = .all

    /// Contact whose chat is currently being opened (async DM create) — drives a per-row spinner
    /// so the tap gives immediate feedback during the ~1.5s network round-trip.
    var openingContactID: String?

    // User info for avatar
    var userID = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    var bindings = ContactsListScreenViewStateBindings()

    /// Filter counts
    var onlineCount: Int {
        contacts.filter(\.isOnline).count
    }

    var favoritesCount: Int {
        contacts.filter(\.isFavorite).count
    }
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
    /// Вердикт сервера на момент последнего ответа — как в `UserPresence`.
    var serverOnline: Bool
    var lastSeenDate: Date?
    var isFavorite: Bool
    // org-profile fields
    var jobTitle: String?
    var department: String?

    /// STMOB-304: «в сети» считается заново, с затуханием через пять минут, как в `UserPresence`.
    /// Раньше здесь хранился флаг-снимок: он переносился из кэша прошлой сессии, и у тех, кого
    /// больше не опрашивают (строка ушла с экрана), зелёная точка замерзала навсегда.
    var isOnline: Bool {
        UserPresence.isOnline(serverOnline: serverOnline, lastSeenDate: lastSeenDate, at: Date())
    }

    init(id: String,
         displayName: String,
         avatarURL: URL?,
         matrixUserID: String?,
         serverOnline: Bool,
         lastSeenDate: Date?,
         isFavorite: Bool,
         jobTitle: String? = nil,
         department: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.matrixUserID = matrixUserID
        self.serverOnline = serverOnline
        self.lastSeenDate = lastSeenDate
        self.isFavorite = isFavorite
        self.jobTitle = jobTitle
        self.department = department
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, avatarURL, matrixUserID, serverOnline, lastSeenDate, isFavorite, jobTitle, department
        /// Сборки до 339 требуют этот ключ: пишем его, чтобы откат на них не терял кэш. Читать не будем.
        case legacyIsOnline = "isOnline"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(matrixUserID, forKey: .matrixUserID)
        try container.encode(serverOnline, forKey: .serverOnline)
        try container.encodeIfPresent(lastSeenDate, forKey: .lastSeenDate)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(jobTitle, forKey: .jobTitle)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encode(false, forKey: .legacyIsOnline)
    }

    /// Кэш прошлых версий хранил флаг `isOnline`; ему не верим — присутствие придёт из опроса.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        matrixUserID = try container.decodeIfPresent(String.self, forKey: .matrixUserID)
        serverOnline = try container.decodeIfPresent(Bool.self, forKey: .serverOnline) ?? false
        lastSeenDate = try container.decodeIfPresent(Date.self, forKey: .lastSeenDate)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        jobTitle = try container.decodeIfPresent(String.self, forKey: .jobTitle)
        department = try container.decodeIfPresent(String.self, forKey: .department)
    }
}
