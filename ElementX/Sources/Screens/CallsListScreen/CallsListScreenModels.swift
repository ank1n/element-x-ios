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

    var isCompleted: Bool {
        self == .complete
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

    func toCallHistoryItem() -> CallHistoryItem? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let startedAtString = startedAt,
              let startDate = formatter.date(from: startedAtString) else {
            return nil
        }

        let endDate: Date? = if let endedAtString = endedAt {
            formatter.date(from: endedAtString)
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

        let playbackURL: URL? = if RecordingStatus(rawValue: status) == .complete {
            URL(string: "https://livekit.market.implica.ru/recording-api/api/recording/play/\(egressId)")
        } else {
            nil
        }

        // Use participants from API v2 if available
        let displayName: String
        if let participants, !participants.isEmpty {
            displayName = participants.map { $0.displayName }.joined(separator: ", ")
        } else {
            displayName = "Видеозвонок"
        }

        // Use matrixRoomId if available, otherwise fallback to roomName
        let contactId = matrixRoomId ?? roomName

        return CallHistoryItem(
            id: egressId,
            contactName: displayName,
            contactId: contactId,
            callType: .video,
            timestamp: startDate,
            duration: callDuration,
            isMissed: false,
            recordingURL: playbackURL
        )
    }
}
