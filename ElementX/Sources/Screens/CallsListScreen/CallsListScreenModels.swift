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

    var bindings = CallsListScreenViewStateBindings()
}

struct CallsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Call history item
struct CallHistoryItem: Identifiable, Equatable {
    let id: String
    let contactName: String
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

/// Individual recording from API
struct CallHistoryAPIItem: Codable {
    let egressId: String
    let roomName: String
    let status: Int
    let startedAt: String?
    let endedAt: String?

    func toCallHistoryItem() -> CallHistoryItem? {
        guard let startedAtString = startedAt,
              let startDate = ISO8601DateFormatter().date(from: startedAtString) else {
            return nil
        }

        let endDate: Date? = if let endedAtString = endedAt {
            ISO8601DateFormatter().date(from: endedAtString)
        } else {
            nil
        }

        let duration = if let endDate {
            endDate.timeIntervalSince(startDate)
        } else {
            nil as TimeInterval?
        }

        let playbackURL: URL? = if RecordingStatus(rawValue: status) == .complete {
            URL(string: "https://minio.market.implica.ru/livekit-recordings/\(egressId).mp4")
        } else {
            nil
        }

        return CallHistoryItem(
            id: egressId,
            contactName: roomName,
            contactId: roomName, // TODO: Map to Matrix room ID
            callType: .outgoing,
            timestamp: startDate,
            duration: duration,
            isMissed: false,
            recordingURL: playbackURL
        )
    }
}
