//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - API Request/Response Models

struct RecordingStartRequest: Codable {
    let roomName: String
    let layout: String?

    init(roomName: String, layout: String = "grid-dark") {
        self.roomName = roomName
        self.layout = layout
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

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case starting
    case recording(egressId: String)
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
