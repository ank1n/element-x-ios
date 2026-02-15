//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - API Request/Response Models

/// Participant info for Recording API v2
struct RecordingParticipantRequest: Codable {
    let userId: String
    let displayName: String
}

struct RecordingStartRequest: Codable {
    let roomName: String
    let layout: String?

    // Recording API v2 fields
    let matrixRoomId: String?
    let participants: [RecordingParticipantRequest]?
    let initiatedBy: String?

    init(roomName: String, layout: String = "grid-dark") {
        self.roomName = roomName
        self.layout = layout
        self.matrixRoomId = nil
        self.participants = nil
        self.initiatedBy = nil
    }

    /// Recording API v2 initializer with participant metadata
    init(roomName: String,
         layout: String = "grid-dark",
         matrixRoomId: String?,
         participants: [(userId: String, displayName: String)]?,
         initiatedBy: String?) {
        self.roomName = roomName
        self.layout = layout
        self.matrixRoomId = matrixRoomId
        self.participants = participants?.map {
            RecordingParticipantRequest(userId: $0.userId, displayName: $0.displayName)
        }
        self.initiatedBy = initiatedBy
    }
}

struct RecordingStartResponse: Codable {
    let success: Bool
    let egressId: String?
    let status: Int?
    let roomName: String?
    let filepath: String?
    let error: String?
}

struct RecordingStopRequest: Codable {
    let egressId: String
}

struct RecordingStopResponse: Codable {
    let success: Bool
    let egressId: String?
    let status: Int?
    let error: String?
}

struct RecordingStatusResponse: Codable {
    let success: Bool
    let egress: EgressInfo?
    let error: String?
}

struct EgressInfo: Codable {
    let egressId: String
    let roomName: String?
    let status: Int?
    let startedAt: String?
    let endedAt: String?
}

// MARK: - Recording List (for remote recording detection)

struct RecordingListResponse: Codable {
    let success: Bool
    let recordings: [RecordingListItem]?
    let error: String?
}

struct RecordingListItem: Codable {
    let egressId: String
    let roomName: String?
    let status: Int?
    let startedAt: String?
    let initiatedBy: String?
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case starting
    case recording(egressId: String, duration: TimeInterval)
    case stopping
    case error(String)

    var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    var recordingDuration: TimeInterval? {
        if case .recording(_, let duration) = self {
            return duration
        }
        return nil
    }

    var formattedDuration: String? {
        guard let duration = recordingDuration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Recording Error

enum RecordingError: LocalizedError {
    case networkError(Error)
    case serverError(String)
    case invalidResponse
    case noActiveRecording
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .noActiveRecording:
            return "No active recording"
        case .alreadyRecording:
            return "Recording already in progress"
        }
    }
}
