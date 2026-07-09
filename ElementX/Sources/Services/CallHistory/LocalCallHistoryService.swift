//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// Local call history item stored on device
struct LocalCallHistoryItem: Codable, Identifiable, Equatable {
    let id: String // Unique ID (UUID)
    let roomID: String
    var roomDisplayName: String?
    var participantUserIDs: [String]
    var participantDisplayNames: [String: String] // userID -> displayName
    let direction: CallDirection
    let startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval?
    var isMissed: Bool
    var recordingEgressId: String? // Link to recording if available

    enum CallDirection: String, Codable {
        case incoming
        case outgoing
    }

    var displayName: String {
        if let roomDisplayName, !roomDisplayName.isEmpty {
            return roomDisplayName
        }

        let names = participantDisplayNames.values.sorted()
        if names.isEmpty {
            return SL10n.callDefault
        } else if names.count == 1 {
            return names[0]
        } else {
            return names.joined(separator: ", ")
        }
    }
}

/// Protocol for local call history storage
protocol LocalCallHistoryServiceProtocol: AnyObject {
    var callHistoryPublisher: AnyPublisher<[LocalCallHistoryItem], Never> { get }

    func setUserID(_ userID: String)
    func startCall(roomID: String, direction: LocalCallHistoryItem.CallDirection) -> String
    func endCall(id: String, missed: Bool)
    func updateCallInfo(id: String, roomDisplayName: String?, participants: [String: String])
    func linkRecording(callID: String, egressId: String)
    func getAllCalls() -> [LocalCallHistoryItem]
    func getCall(by id: String) -> LocalCallHistoryItem?
    func deleteCall(id: String)
    func clearHistory()
}

/// Local storage for call history using UserDefaults (simple implementation)
/// For production, consider using Core Data or SQLite
class LocalCallHistoryService: LocalCallHistoryServiceProtocol {
    /// Per-user storage key so call history is scoped to the logged-in account (and therefore the
    /// server too, since a Matrix userID includes the domain — @user:server). Without this the
    /// history was one global list, mixing calls from every account/server the device ever used and
    /// showing them all after login ("extra entries"). Falls back to the legacy key until a user is set.
    private var currentUserID: String?
    private let legacyStorageKey = "ru.implica.stalk.callHistory"
    private var storageKey: String {
        if let currentUserID {
            return "\(legacyStorageKey).\(currentUserID)"
        }
        return legacyStorageKey
    }

    private let userDefaults: UserDefaults
    private let maxHistoryItems = 100

    private var callHistory: [LocalCallHistoryItem] = []
    private let callHistorySubject = CurrentValueSubject<[LocalCallHistoryItem], Never>([])

    var callHistoryPublisher: AnyPublisher<[LocalCallHistoryItem], Never> {
        callHistorySubject.eraseToAnyPublisher()
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadHistory()
    }

    // MARK: - Public Methods

    /// Scope the history to a specific account. Called once the user session is available; reloads
    /// from that account's store so entries from a previously logged-in account/server disappear.
    func setUserID(_ userID: String) {
        guard currentUserID != userID else { return }
        currentUserID = userID
        migrateLegacyHistoryIfNeeded(for: userID)
        loadHistory()
        notifyChange()
    }

    /// One-time move of the old global history into this account's scoped store, keeping only calls
    /// whose room lives on the user's own server (userID domain). A real single-account user keeps
    /// their history across the update; calls that belong to a different server are dropped. Runs
    /// once per account (skipped once a scoped store exists). Note: the legacy log never recorded
    /// which local account placed each call, so on a device where several accounts of the SAME server
    /// were used, those calls can't be told apart and will appear for each such account — a rarely-hit
    /// case that doesn't occur for normal single-account users.
    private func migrateLegacyHistoryIfNeeded(for userID: String) {
        guard userDefaults.data(forKey: storageKey) == nil,
              let legacyData = userDefaults.data(forKey: legacyStorageKey),
              let domain = userID.split(separator: ":").last.map(String.init) else {
            return
        }

        do {
            let legacy = try JSONDecoder().decode([LocalCallHistoryItem].self, from: legacyData)
            let mine = legacy.filter { $0.roomID.hasSuffix(":\(domain)") }
            guard !mine.isEmpty else { return }
            let data = try JSONEncoder().encode(mine)
            userDefaults.set(data, forKey: storageKey)
            MXLog.info("📞 Migrated \(mine.count)/\(legacy.count) legacy calls into \(userID)'s history")
        } catch {
            MXLog.error("📞 Failed to migrate legacy call history: \(error)")
        }
    }

    func startCall(roomID: String, direction: LocalCallHistoryItem.CallDirection) -> String {
        let callID = UUID().uuidString

        let item = LocalCallHistoryItem(id: callID,
                                        roomID: roomID,
                                        roomDisplayName: nil,
                                        participantUserIDs: [],
                                        participantDisplayNames: [:],
                                        direction: direction,
                                        startedAt: Date(),
                                        endedAt: nil,
                                        duration: nil,
                                        isMissed: false,
                                        recordingEgressId: nil)

        callHistory.insert(item, at: 0)
        trimHistory()
        saveHistory()
        notifyChange()

        MXLog.info("📞 Call started: \(callID), room: \(roomID), direction: \(direction)")
        return callID
    }

    func endCall(id: String, missed: Bool) {
        guard let index = callHistory.firstIndex(where: { $0.id == id }) else {
            MXLog.warning("📞 Call not found for end: \(id)")
            return
        }

        let endTime = Date()
        callHistory[index].endedAt = endTime
        callHistory[index].duration = endTime.timeIntervalSince(callHistory[index].startedAt)
        callHistory[index].isMissed = missed

        saveHistory()
        notifyChange()

        MXLog.info("📞 Call ended: \(id), missed: \(missed), duration: \(callHistory[index].duration ?? 0)")
    }

    func updateCallInfo(id: String, roomDisplayName: String?, participants: [String: String]) {
        guard let index = callHistory.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let roomDisplayName {
            callHistory[index].roomDisplayName = roomDisplayName
        }

        callHistory[index].participantUserIDs = Array(participants.keys)
        callHistory[index].participantDisplayNames = participants

        saveHistory()
        notifyChange()
    }

    func linkRecording(callID: String, egressId: String) {
        guard let index = callHistory.firstIndex(where: { $0.id == callID }) else {
            // Try to find by room ID and time proximity
            return
        }

        callHistory[index].recordingEgressId = egressId
        saveHistory()
        notifyChange()

        MXLog.info("📞 Recording linked: call \(callID) -> egress \(egressId)")
    }

    func getAllCalls() -> [LocalCallHistoryItem] {
        callHistory
    }

    func getCall(by id: String) -> LocalCallHistoryItem? {
        callHistory.first { $0.id == id }
    }

    func deleteCall(id: String) {
        callHistory.removeAll { $0.id == id }
        saveHistory()
        notifyChange()
    }

    func clearHistory() {
        callHistory.removeAll()
        saveHistory()
        notifyChange()
    }

    // MARK: - Private Methods

    private func loadHistory() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            callHistory = []
            return
        }

        do {
            callHistory = try JSONDecoder().decode([LocalCallHistoryItem].self, from: data)
            notifyChange()
            MXLog.info("📞 Loaded \(callHistory.count) calls from history")
        } catch {
            MXLog.error("📞 Failed to load call history: \(error)")
            callHistory = []
        }
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(callHistory)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            MXLog.error("📞 Failed to save call history: \(error)")
        }
    }

    private func trimHistory() {
        if callHistory.count > maxHistoryItems {
            callHistory = Array(callHistory.prefix(maxHistoryItems))
        }
    }

    private func notifyChange() {
        callHistorySubject.send(callHistory)
    }
}
