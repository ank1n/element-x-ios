//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Call Recording Item

struct CallRecordingItem: Identifiable, Equatable {
    let id: String // egressId
    let roomId: String
    let roomName: String
    let startedAt: Date
    let endedAt: Date?
    let status: RecordingStatus
    let filepath: String?

    var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return endedAt.timeIntervalSince(startedAt)
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: startedAt)
    }

    var isCompleted: Bool {
        status == .complete
    }

    var playbackURL: URL? {
        guard let filepath, isCompleted else { return nil }
        // MinIO/S3 URL will be constructed from filepath
        return URL(string: "https://minio.market.implica.ru/livekit-recordings/\(filepath)")
    }
}

// MARK: - Recording Status

enum RecordingStatus: Int, Codable {
    case starting = 0
    case active = 1
    case ending = 2
    case complete = 3
    case failed = 4

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
        }
    }

    var isInProgress: Bool {
        switch self {
        case .starting, .active, .ending:
            return true
        case .complete, .failed:
            return false
        }
    }
}

// MARK: - Call Direction

enum CallDirection {
    case incoming
    case outgoing
    case missed

    var icon: String {
        switch self {
        case .incoming:
            return "arrow.down.left"
        case .outgoing:
            return "arrow.up.right"
        case .missed:
            return "phone.down"
        }
    }

    var displayName: String {
        switch self {
        case .incoming:
            return "Incoming"
        case .outgoing:
            return "Outgoing"
        case .missed:
            return "Missed"
        }
    }
}

// MARK: - Call History Filter

enum CallHistoryFilter: String, CaseIterable {
    case all = "All"
    case recorded = "Recorded"
    case missed = "Missed"

    var displayName: String {
        rawValue
    }
}

// MARK: - API Response Models

struct CallHistoryResponse: Codable {
    let success: Bool
    let recordings: [CallHistoryAPIItem]?
    let error: String?
}

struct CallHistoryAPIItem: Codable {
    let egressId: String
    let roomName: String
    let status: Int
    let startedAt: String?
    let endedAt: String?

    func toCallRecordingItem() -> CallRecordingItem? {
        guard let startedAtString = startedAt,
              let startDate = ISO8601DateFormatter().date(from: startedAtString) else {
            return nil
        }

        let endDate: Date? = if let endedAtString = endedAt {
            ISO8601DateFormatter().date(from: endedAtString)
        } else {
            nil
        }

        let recordingStatus = RecordingStatus(rawValue: status) ?? .failed

        return CallRecordingItem(
            id: egressId,
            roomId: roomName, // This might need mapping from LiveKit room to Matrix room ID
            roomName: roomName,
            startedAt: startDate,
            endedAt: endDate,
            status: recordingStatus,
            filepath: nil // Will be fetched separately if needed
        )
    }
}
