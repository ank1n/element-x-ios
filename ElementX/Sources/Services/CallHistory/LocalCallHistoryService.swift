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
    private let storageKey = "ru.implica.stalk.callHistory"
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
