//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum CallsListScreenViewAction {
    case showSettings
    case selectCall(CallHistoryItem)
    case startNewCall
    case playRecording(CallHistoryItem)
    case refresh
}

enum CallsListScreenViewModelAction {
    case showSettings
    case startCall(userId: String)
}

struct CallsListScreenViewState: BindableState {
    var callHistory: [CallHistoryItem] = []
    var isLoading: Bool = false
    var searchQuery = ""

    // User info for avatar
    var userID: String = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    // Audio playback state
    var playingCallId: String?
    var playbackState: MediaPlayerState = .stopped
    var playbackProgress: Double = 0
    var playbackDuration: TimeInterval = 0
    var playbackCurrentTime: TimeInterval = 0
    var downloadProgress: Double = 0  // 0.0 to 1.0

    var bindings = CallsListScreenViewStateBindings()
}

struct CallsListScreenViewStateBindings {
    var searchQuery = ""
    var alertInfo: AlertInfo<UUID>?
}

/// Call history item
struct CallHistoryItem: Identifiable, Equatable {
    let id: String
    var contactName: String
    let contactId: String
    let callType: CallType
    let timestamp: Date
    let duration: TimeInterval?
    let isMissed: Bool
    let recordingURL: URL?

    var hasRecording: Bool {
        recordingURL != nil
    }

    enum CallType: String {
        case incoming
        case outgoing
        case video
    }
}

// MARK: - Call History API Models

/// Recording status from API
enum RecordingStatus: Int, Codable {
    case starting = 0
    case active = 1
    case ending = 2
    case complete = 3
    case failed = 4
    case aborted = 5  // запись прервана

    var isCompleted: Bool {
        self == .complete
    }

    var displayName: String {
        switch self {
        case .starting:
            return "Starting..."
        case .active:
            return "Recording"
        case .ending:
            return "Finishing..."
        case .complete:
            return "Available"
        case .failed:
            return "Failed"
        case .aborted:
            return "Aborted"
        }
    }

    var isInProgress: Bool {
        switch self {
        case .starting, .active, .ending:
            return true
        case .complete, .failed, .aborted:
            return false
        }
    }
}

/// API response for recordings list
struct CallHistoryResponse: Codable {
    let success: Bool
    let recordings: [CallHistoryAPIItem]?
    let error: String?
}

/// Participant info from Recording API v2
struct RecordingParticipant: Codable {
    let userId: String
    let displayName: String
}

/// Individual recording from API
struct CallHistoryAPIItem: Codable {
    let egressId: String
    let roomName: String
    let status: Int
    let startedAt: String?
    let endedAt: String?

    // New fields from Recording API v2
    let matrixRoomId: String?
    let participants: [RecordingParticipant]?
    let initiatedBy: String?
    let duration: Int?
    let fileSize: Int?

    func toCallHistoryItem(currentUserID: String? = nil) -> CallHistoryItem? {
        guard let startedAtString = startedAt,
              let startDate = Self.parseDate(startedAtString) else {
            return nil
        }

        let endDate: Date? = if let endedAtString = endedAt {
            Self.parseDate(endedAtString)
        } else {
            nil
        }

        // Use duration from API if available, otherwise calculate from dates
        let callDuration: TimeInterval? = if let duration {
            TimeInterval(duration)
        } else if let endDate {
            endDate.timeIntervalSince(startDate)
        } else {
            nil
        }

        // Разрешаем воспроизведение для:
        // - status 3 (COMPLETE) - запись завершена
        // - status 2 (ENDING) с endedAt - файл уже создан, LiveKit ещё не обновил статус
        let recordingStatus = RecordingStatus(rawValue: status)
        let isPlayable = recordingStatus == .complete || (recordingStatus == .ending && endedAt != nil)
        let playbackURL: URL? = if isPlayable {
            URL(string: "https://livekit.market.implica.ru/recording-api/api/recording/play/\(egressId)")
        } else {
            nil
        }

        // Use participants from API v2 if available (limit to 2 names)
        let displayName: String
        if let participants, !participants.isEmpty {
            let names = participants.map { $0.displayName }
            if names.count <= 2 {
                displayName = names.joined(separator: ", ")
            } else {
                let firstTwo = names.prefix(2).joined(separator: ", ")
                displayName = "\(firstTwo) +\(names.count - 2)"
            }
        } else {
            displayName = "Видеозвонок"
        }

        // Determine call direction from initiatedBy
        let callType: CallHistoryItem.CallType
        if let currentUserID, let initiatedBy {
            callType = initiatedBy == currentUserID ? .outgoing : .incoming
        } else {
            callType = .video
        }

        // Use matrixRoomId if available, otherwise fallback to roomName
        let contactId = matrixRoomId ?? roomName

        return CallHistoryItem(
            id: egressId,
            contactName: displayName,
            contactId: contactId,
            callType: callType,
            timestamp: startDate,
            duration: callDuration,
            isMissed: false,
            recordingURL: playbackURL
        )
    }

    /// Парсит дату в разных форматах от Recording API
    private static func parseDate(_ string: String) -> Date? {
        // Формат 1: "2026-02-04 10:17:11" (из API v2) - время в UTC
        let simpleFormatter = DateFormatter()
        simpleFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        simpleFormatter.timeZone = TimeZone(identifier: "UTC")
        if let date = simpleFormatter.date(from: string) {
            return date
        }

        // Формат 2: ISO8601 с миллисекундами "2026-02-04T10:17:11.000Z"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: string) {
            return date
        }

        // Формат 3: ISO8601 без миллисекунд "2026-02-04T10:17:11Z"
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: string)
    }
}
