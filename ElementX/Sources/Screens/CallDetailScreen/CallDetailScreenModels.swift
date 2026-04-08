//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Transcription API Models

enum TranscriptionStatus: String, Codable {
    case pending
    case submitted
    case processing
    case completed
    case failed
    case retry

    var isInProgress: Bool {
        switch self {
        case .pending, .submitted, .processing:
            return true
        case .completed, .failed, .retry:
            return false
        }
    }
}

struct TranscriptionSegment: Codable, Identifiable, Equatable {
    var id: String {
        "\(speaker)-\(start)"
    }

    let speaker: String
    let speakerLabel: String?
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let confidence: Double?
    let channel: Int?

    enum CodingKeys: String, CodingKey {
        case speaker
        case speakerLabel = "speaker_label"
        case start, end, text, confidence, channel
    }
}

struct Transcription: Codable, Equatable {
    let language: String
    let segments: [TranscriptionSegment]
    let fullText: String
}

struct SummaryTopic: Codable, Identifiable, Equatable {
    var id: String {
        title
    }

    let title: String
    let discussed: String?
    let agreed: String?
    let timestamp: TimeInterval?
}

struct TranscriptionSummary: Codable, Equatable {
    let text: String
    let keyPoints: [String]
    let actionItems: [String]
    let topics: [SummaryTopic]?
}

struct TranscriptionError: Codable, Equatable {
    let code: String?
    let message: String
    let retryable: Bool?
}

struct TranscriptionData: Codable, Equatable {
    let available: Bool
    let status: TranscriptionStatus?
    let transcription: Transcription?
    let summary: TranscriptionSummary?
    let error: TranscriptionError?
}

// MARK: - View State

enum CallDetailTab: String, CaseIterable {
    case summary
    case details
    case transcription

    var title: String {
        switch self {
        case .summary: return "Резюме"
        case .details: return "Подробнее"
        case .transcription: return "Транскрипция"
        }
    }
}

enum CallDetailScreenViewAction {
    case dismiss
    case selectTab(CallDetailTab)
    case seekToTimestamp(TimeInterval)
    case playPause
    case seekPlayback(progress: Double)
    case retryTranscription
    case callBack
}

enum CallDetailScreenViewModelAction {
    case dismiss
    case callBack(roomID: String)
}

struct CallDetailScreenViewState: BindableState {
    let call: CallHistoryItem
    var selectedTab: CallDetailTab = .summary
    var transcriptionData: TranscriptionData?
    var isTranscriptionLoading = true

    // Playback
    var playbackState: MediaPlayerState = .stopped
    var playbackProgress: Double = 0
    var playbackDuration: TimeInterval = 0
    var playbackCurrentTime: TimeInterval = 0
    var isDownloading = false

    var bindings = CallDetailScreenViewStateBindings()

    var isPolling: Bool {
        transcriptionData?.status?.isInProgress == true
    }

    var hasTranscription: Bool {
        transcriptionData?.status == .completed
    }

    var hasSummary: Bool {
        guard let summary = transcriptionData?.summary else { return false }
        return !(summary.topics?.isEmpty ?? true) || !summary.text.isEmpty || !summary.keyPoints.isEmpty
    }

    var hasSegments: Bool {
        !(transcriptionData?.transcription?.segments.isEmpty ?? true)
    }

    /// Available tabs based on data
    var availableTabs: [CallDetailTab] {
        var tabs: [CallDetailTab] = []
        if hasSummary { tabs.append(.summary) }
        if let topics = transcriptionData?.summary?.topics, !topics.isEmpty { tabs.append(.details) }
        if hasSegments { tabs.append(.transcription) }
        return tabs
    }
}

struct CallDetailScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
}
