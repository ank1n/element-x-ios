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

/// STALK-255 build 157/161: tasks предложенные LLM-summarizer внутри topic.
/// Юзер может конвертировать их в TrackIT issues через POST /api/recording/tasks/create.
///
/// Build 161 hotfix: server отдаёт snake_case (`topic_index`, `task_index`)
/// несмотря на то что в spec @molly было camelCase. Без CodingKeys
/// DecodingError ломал весь TranscriptionData → транскрипция не открывалась.
struct SuggestedTask: Codable, Identifiable, Equatable {
    var id: String {
        "\(topicIndex)-\(taskIndex)"
    }

    let topicIndex: Int
    let taskIndex: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case topicIndex = "topic_index"
        case taskIndex = "task_index"
        case text
    }
}

struct SummaryTopic: Codable, Identifiable, Equatable {
    var id: String {
        title
    }

    let title: String
    let discussed: String?
    let agreed: String?
    let timestamp: TimeInterval?
    /// STALK-255 build 157: только новые записи. Старые звонки suggestedTasks=nil.
    let suggestedTasks: [SuggestedTask]?
}

/// STALK-255 build 157: уже созданная задача в TrackIT — приходит из
/// `GET /api/recording/tasks/{egressId}`. Содержит ссылку на Plane Issue и
/// текущий статус (Todo/InProgress/Done/...) для отображения badge.
struct CreatedTask: Codable, Identifiable, Equatable {
    let id: Int
    let egressId: String
    let topicIndex: Int
    let taskIndex: Int
    let taskText: String
    let trackitIssueId: String?
    let trackitProjectId: String?
    let trackitProjectIdentifier: String?
    let trackitSequenceId: Int?
    let trackitStateId: String?
    let trackitStateName: String?
    let trackitStateGroup: String?
    let trackitUrl: String?
    let createdBy: String?
    let createdAt: String?
    let statusSyncedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case egressId = "egress_id"
        case topicIndex = "topic_index"
        case taskIndex = "task_index"
        case taskText = "task_text"
        case trackitIssueId = "trackit_issue_id"
        case trackitProjectId = "trackit_project_id"
        case trackitProjectIdentifier = "trackit_project_identifier"
        case trackitSequenceId = "trackit_sequence_id"
        case trackitStateId = "trackit_state_id"
        case trackitStateName = "trackit_state_name"
        case trackitStateGroup = "trackit_state_group"
        case trackitUrl = "trackit_url"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case statusSyncedAt = "status_synced_at"
    }
}

/// STALK-255 build 157: проект TrackIT для выбора при создании задачи.
struct TrackItProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let identifier: String
    let description: String?
}

struct TranscriptionSummary: Codable, Equatable {
    // Build 113: все поля optional. Server (recording-api) возвращает text:null
    // когда summary_text пуст в DB — non-optional String ломал DecodingError →
    // transcriptionData = nil → пустой UI. Aibolit может не генерировать
    // text/action_items для коротких звонков, оставляя только topics.
    let text: String?
    let keyPoints: [String]?
    let actionItems: [String]?
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
    /// STALK-255 build 157: задачи из LLM-summarizer suggestedTasks +
    /// уже созданные TrackIT issues. Sync с web "Задачи" вкладкой.
    case tasks

    var title: String {
        switch self {
        case .summary: return "Резюме"
        case .details: return "Подробнее"
        case .transcription: return "Транскрипция"
        case .tasks: return "Задачи"
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
    /// STALK-255 build 157: создать задачу в TrackIT из suggested task.
    case createTask(SuggestedTask, projectId: String, overrideText: String?)
    /// STALK-255 build 157: открыть/закрыть picker проектов TrackIT.
    case openProjectPicker(SuggestedTask)
    case closeProjectPicker
    /// STALK-255 build 157: search TrackIT projects по подстроке.
    case searchProjects(query: String)
    /// STALK-255 build 157: открыть TrackIT issue в браузере.
    case openTrackItIssue(url: String)
    /// STALK-255 build 157: refresh статусов созданных задач из TrackIT.
    case refreshTasks
}

enum CallDetailScreenViewModelAction {
    case dismiss
    case callBack(roomID: String)
}

struct CallDetailScreenViewState: BindableState {
    /// Build 126: var вместо let — нужно обновить avatarURL после resolve room metadata.
    var call: CallHistoryItem
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

    /// Build 126: avatars резолвленные из room members по displayName.
    /// Используется в transcript view для каждого segment speaker.
    var speakerAvatars: [String: URL] = [:]

    var isPolling: Bool {
        transcriptionData?.status?.isInProgress == true
    }

    var hasTranscription: Bool {
        transcriptionData?.status == .completed
    }

    var hasSummary: Bool {
        guard let summary = transcriptionData?.summary else { return false }
        let hasTopics = !(summary.topics?.isEmpty ?? true)
        let hasText = !(summary.text?.isEmpty ?? true)
        let hasKeyPoints = !(summary.keyPoints?.isEmpty ?? true)
        return hasTopics || hasText || hasKeyPoints
    }

    var hasSegments: Bool {
        !(transcriptionData?.transcription?.segments.isEmpty ?? true)
    }

    /// STALK-255 build 157: суммируем suggestedTasks из всех topics в плоский
    /// список — UI tab "Задачи" показывает их как flat list карточек.
    var allSuggestedTasks: [SuggestedTask] {
        guard let topics = transcriptionData?.summary?.topics else { return [] }
        return topics.compactMap(\.suggestedTasks).flatMap(\.self)
    }

    var hasTasks: Bool {
        !allSuggestedTasks.isEmpty || !createdTasks.isEmpty
    }

    /// STALK-255 build 157: уже созданные TrackIT-задачи для звонка.
    var createdTasks: [CreatedTask] = []
    var isTasksLoading = false
    var trackItProjects: [TrackItProject] = []
    var isProjectsLoading = false
    /// SuggestedTask для которой открыт project picker. nil = picker закрыт.
    var projectPickerForTask: SuggestedTask?

    /// Available tabs based on data
    var availableTabs: [CallDetailTab] {
        var tabs: [CallDetailTab] = []
        if hasSummary { tabs.append(.summary) }
        if let topics = transcriptionData?.summary?.topics, !topics.isEmpty { tabs.append(.details) }
        if hasSegments { tabs.append(.transcription) }
        if hasTasks { tabs.append(.tasks) }
        return tabs
    }
}

struct CallDetailScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
}
