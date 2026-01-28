//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Model

struct SavedAccount: Codable, Identifiable, Equatable {
    /// Unique identifier for the saved account
    var id: String { "\(serverURL)_\(userId)" }
    /// The homeserver URL (e.g. "matrix.market.implica.ru")
    let serverURL: String
    /// The Matrix user ID (e.g. "@user:server.ru")
    let userId: String
    /// Display name if available
    let displayName: String?
    /// Last time this account was used
    var lastUsedAt: Date
}

// MARK: - Store

class SavedAccountsStore {
    private let userDefaultsKey = "savedAccounts"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Get all saved accounts, sorted by last used (most recent first)
    func getAll() -> [SavedAccount] {
        guard let data = userDefaults.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            let accounts = try JSONDecoder().decode([SavedAccount].self, from: data)
            return accounts.sorted { $0.lastUsedAt > $1.lastUsedAt }
        } catch {
            MXLog.error("Failed to decode saved accounts: \(error)")
            return []
        }
    }

    /// Save or update an account. If account with same server+userId exists, updates lastUsedAt.
    func save(_ account: SavedAccount) {
        var accounts = getAll()

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }

        persist(accounts)
    }

    /// Update the lastUsedAt timestamp for an existing account
    func updateLastUsed(serverURL: String, userId: String) {
        var accounts = getAll()
        let id = "\(serverURL)_\(userId)"

        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].lastUsedAt = Date()
            persist(accounts)
        }
    }

    /// Delete a saved account by its ID
    func delete(id: String) {
        var accounts = getAll()
        accounts.removeAll { $0.id == id }
        persist(accounts)
    }


    private func persist(_ accounts: [SavedAccount]) {
        do {
            let data = try JSONEncoder().encode(accounts)
            userDefaults.set(data, forKey: userDefaultsKey)
        } catch {
            MXLog.error("Failed to encode saved accounts: \(error)")
        }
    }
}
