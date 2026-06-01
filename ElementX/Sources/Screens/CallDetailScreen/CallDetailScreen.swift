//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct CallDetailScreen: View {
    @ObservedObject var context: CallDetailScreenViewModelType.Context
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                callHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                if context.viewState.call.hasRecording {
                    audioPlayerBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                transcriptionContent
            }
        }
        .background(isCosmos ? Color(.systemGroupedBackground) : Color(.systemBackground))
        .navigationTitle(NSLocalizedString("stalk_calldetail_title", tableName: "Localizable", value: "Детали звонка", comment: "Call detail screen title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var callHeader: some View {
        HStack(spacing: 14) {
            // Avatar
            LoadableAvatarImage(url: context.viewState.call.avatarURL,
                                name: context.viewState.call.contactName,
                                contentID: context.viewState.call.contactId,
                                avatarSize: .custom(56),
                                mediaProvider: context.mediaProvider)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.viewState.call.contactName)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: callDirectionIcon)
                        .font(.system(size: 12))
                        .foregroundColor(callDirectionColor)

                    Text(callDateString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let duration = context.viewState.call.duration {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(formatDuration(duration))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                if context.viewState.call.isGroupCall {
                    Text(String(format: NSLocalizedString("stalk_calldetail_participants_count", tableName: "Localizable", value: "%d участников", comment: "Call detail: participants count"), context.viewState.call.participantCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Call back button
            Button {
                context.send(viewAction: .callBack)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: context.viewState.call.callType == .video ? "video.fill" : "phone.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    // MARK: - Audio Player Bar

    private var audioPlayerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Play/Pause button
                Button {
                    context.send(viewAction: .playPause)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isPlaying ? Color.accentColor : Color(.systemGray5))
                            .frame(width: 40, height: 40)

                        if context.viewState.isDownloading || context.viewState.playbackState == .loading {
                            ProgressView()
                                .tint(isPlaying ? .white : .accentColor)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isPlaying ? .white : .accentColor)
                        }
                    }
                }

                // Slider
                Slider(value: Binding(get: { context.viewState.playbackProgress },
                                      set: { context.send(viewAction: .seekPlayback(progress: $0)) }))
                    .tint(.accentColor)

                // Time
                Text(formatTime(context.viewState.playbackCurrentTime))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text("/")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(formatTime(context.viewState.playbackDuration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Transcription Content

    @ViewBuilder
    private var transcriptionContent: some View {
        if context.viewState.isTranscriptionLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text(NSLocalizedString("stalk_calldetail_loading", tableName: "Localizable", value: "Загрузка...", comment: "Loading placeholder"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if let status = context.viewState.transcriptionData?.status, status.isInProgress {
            VStack(spacing: 12) {
                ProgressView()
                Text(NSLocalizedString("stalk_calldetail_transcription_processing", tableName: "Localizable", value: "Транскрипция обрабатывается...", comment: "Transcription in progress placeholder"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if context.viewState.transcriptionData?.status == .failed {
            transcriptionErrorView
        } else if context.viewState.hasTranscription {
            tabsView
        } else if context.viewState.transcriptionData?.available == false || context.viewState.transcriptionData == nil {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(NSLocalizedString("stalk_calldetail_transcription_unavailable", tableName: "Localizable", value: "Транскрипция недоступна", comment: "Transcription unavailable placeholder"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    private var transcriptionErrorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            Text(NSLocalizedString("stalk_calldetail_transcription_failed", tableName: "Localizable", value: "Не удалось создать транскрипцию", comment: "Transcription creation failed message"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            if context.viewState.transcriptionData?.error?.retryable == true {
                Button {
                    context.send(viewAction: .retryTranscription)
                } label: {
                    Text(NSLocalizedString("stalk_calldetail_retry", tableName: "Localizable", value: "Повторить", comment: "Retry button"))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Tabs

    private var tabsView: some View {
        VStack(spacing: 0) {
            // Tab picker
            let tabs = context.viewState.availableTabs
            if tabs.count > 1 {
                Picker("", selection: Binding(get: { context.viewState.selectedTab },
                                              set: { context.send(viewAction: .selectTab($0)) })) {
                    ForEach(tabs, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // Tab content
            switch context.viewState.selectedTab {
            case .summary:
                summaryTabView
            case .details:
                detailsTabView
            case .transcription:
                transcriptTabView
            case .tasks:
                tasksTabView
            }
        }
    }

    // MARK: - Tasks Tab (STALK-255 build 157)

    private var tasksTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            let suggested = context.viewState.allSuggestedTasks
            let created = context.viewState.createdTasks
            let createdKeys = Set(created.map { "\($0.topicIndex)-\($0.taskIndex)" })
            let pending = suggested.filter { !createdKeys.contains($0.id) }

            if context.viewState.isTasksLoading, created.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 24)
            }

            if !pending.isEmpty {
                sectionHeader(NSLocalizedString("stalk_calldetail_llm_suggestions", tableName: "Localizable", value: "Предложения LLM", comment: "Section header: LLM suggestions"))
                ForEach(pending) { task in
                    suggestedTaskCard(task)
                }
            }

            if !created.isEmpty {
                HStack {
                    sectionHeader(NSLocalizedString("stalk_calldetail_created_tasks", tableName: "Localizable", value: "Созданные задачи", comment: "Section header: created tasks"))
                    Spacer()
                    Button {
                        context.send(viewAction: .refreshTasks)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                    }
                    .disabled(context.viewState.isTasksLoading)
                }
                ForEach(created) { task in
                    createdTaskCard(task)
                }
            }

            if pending.isEmpty, created.isEmpty, !context.viewState.isTasksLoading {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(NSLocalizedString("stalk_calldetail_no_suggested_tasks", tableName: "Localizable", value: "Нет предложенных задач", comment: "Empty state: no suggested tasks"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .sheet(isPresented: Binding(get: { context.viewState.projectPickerForTask != nil },
                                    set: { newValue in
                                        if !newValue { context.send(viewAction: .closeProjectPicker) }
                                    })) {
            projectPickerSheet
        }
    }

    private func suggestedTaskCard(_ task: SuggestedTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                context.send(viewAction: .openProjectPicker(task))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(NSLocalizedString("stalk_calldetail_create_in_trackit", tableName: "Localizable", value: "Создать в TrackIT", comment: "Create task in TrackIT button"))
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(10)
    }

    private func createdTaskCard(_ task: CreatedTask) -> some View {
        Button {
            if let url = task.trackitUrl {
                context.send(viewAction: .openTrackItIssue(url: url))
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let identifier = task.trackitProjectIdentifier, let seq = task.trackitSequenceId {
                        Text("\(identifier)-\(seq)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                    if let stateName = task.trackitStateName {
                        Text(stateName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(stateBadgeColor(group: task.trackitStateGroup))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                Text(task.taskText)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func stateBadgeColor(group: String?) -> Color {
        switch group {
        case "started": return .blue
        case "completed": return .green
        case "cancelled": return .gray
        default: return Color(red: 0.55, green: 0.55, blue: 0.55)
        }
    }

    private var projectPickerSheet: some View {
        NavigationStack {
            List {
                if context.viewState.isProjectsLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(context.viewState.trackItProjects) { project in
                    Button {
                        if let task = context.viewState.projectPickerForTask {
                            context.send(viewAction: .createTask(task, projectId: project.id, overrideText: nil))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(project.name).font(.headline)
                                Spacer()
                                Text(project.identifier).font(.caption).foregroundColor(.secondary)
                            }
                            if let desc = project.description, !desc.isEmpty {
                                Text(desc).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle(NSLocalizedString("stalk_calldetail_select_project", tableName: "Localizable", value: "Выберите проект", comment: "Project picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("stalk_calldetail_cancel", tableName: "Localizable", value: "Отмена", comment: "Cancel button")) { context.send(viewAction: .closeProjectPicker) }
                }
            }
        }
    }

    // MARK: - Summary Tab

    private var summaryTabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let topics = context.viewState.transcriptionData?.summary?.topics, !topics.isEmpty {
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    topicRow(index: index + 1, topic: topic)
                }
            } else if let text = context.viewState.transcriptionData?.summary?.text, !text.isEmpty {
                let points = text.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(point)
                            .font(.subheadline)
                    }
                }
            }

            // Key points
            if let keyPoints = context.viewState.transcriptionData?.summary?.keyPoints, !keyPoints.isEmpty {
                sectionHeader(NSLocalizedString("stalk_calldetail_key_points", tableName: "Localizable", value: "Ключевые моменты", comment: "Section header: key points"))
                ForEach(Array(keyPoints.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .padding(.top, 4)
                        Text(point)
                            .font(.subheadline)
                    }
                }
            }

            // Action items
            if let actionItems = context.viewState.transcriptionData?.summary?.actionItems, !actionItems.isEmpty {
                sectionHeader(NSLocalizedString("stalk_calldetail_action_items", tableName: "Localizable", value: "Задачи", comment: "Section header: action items / tasks"))
                ForEach(Array(actionItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .padding(.top, 2)
                        Text(item)
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Details Tab

    private var detailsTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let topics = context.viewState.transcriptionData?.summary?.topics {
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    VStack(alignment: .leading, spacing: 8) {
                        topicRow(index: index + 1, topic: topic)

                        if let discussed = topic.discussed, !discussed.isEmpty {
                            Text(discussed)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 36)
                        }

                        if let agreed = topic.agreed,
                           !agreed.isEmpty,
                           !agreed.lowercased().contains("не зафиксировали") {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.green)
                                Text(agreed)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                            .padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Transcript Tab

    private var transcriptTabView: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if let segments = context.viewState.transcriptionData?.transcription?.segments {
                // Build 114: id-based ForEach падал на симуляторе (вероятно
                // ID-коллизия при одинаковом speaker+start в floating-point).
                // Переход на offset-based id для гарантированной уникальности.
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 10) {
                        // Build 126: реальный avatar если найден в speakerAvatars,
                        // fallback — colored circle с инициалами.
                        let speakerName = segment.speakerLabel ?? segment.speaker
                        LoadableAvatarImage(url: context.viewState.speakerAvatars[speakerName],
                                            name: speakerName,
                                            contentID: speakerName,
                                            avatarSize: .custom(32),
                                            mediaProvider: context.mediaProvider)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(segment.speakerLabel ?? segment.speaker)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Button {
                                    context.send(viewAction: .seekToTimestamp(segment.start))
                                } label: {
                                    Text(formatTime(segment.start))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule()
                                            .fill(Color.accentColor.opacity(0.1)))
                                }
                            }

                            Text(segment.text)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Helpers

    private func topicRow(index: Int, topic: SummaryTopic) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 24)
                Text("\(index)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }

            Text(topic.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)

            Spacer()

            if let timestamp = topic.timestamp {
                Button {
                    context.send(viewAction: .seekToTimestamp(timestamp))
                } label: {
                    Text(formatTime(timestamp))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule()
                            .fill(Color.accentColor.opacity(0.1)))
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSec = Int(seconds)
        if totalSec < 60 { return String(format: NSLocalizedString("stalk_calldetail_dur_seconds", tableName: "Localizable", value: "%dс", comment: "Duration seconds (short, no space)"), totalSec) }
        let min = totalSec / 60
        let sec = totalSec % 60
        return sec > 0 ? String(format: NSLocalizedString("stalk_calldetail_dur_min_sec", tableName: "Localizable", value: "%1$dм %2$dс", comment: "Duration minutes and seconds (short)"), min, sec) : String(format: NSLocalizedString("stalk_calldetail_dur_minutes", tableName: "Localizable", value: "%dм", comment: "Duration minutes (short, no space)"), min)
    }

    private var isPlaying: Bool {
        context.viewState.playbackState == .playing
    }

    private var callDirectionIcon: String {
        switch context.viewState.call.callType {
        case .incoming:
            return context.viewState.call.isMissed ? "phone.arrow.down.left" : "phone.arrow.down.left"
        case .outgoing:
            return "phone.arrow.up.right"
        case .video:
            return "video"
        }
    }

    private var callDirectionColor: Color {
        context.viewState.call.isMissed ? .red : .secondary
    }

    private var callDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: context.viewState.call.timestamp)
    }

    /// Speaker colors for transcript
    private let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .indigo, .mint
    ]

    private func speakerColor(for speaker: String) -> Color {
        let hash = abs(speaker.hashValue)
        return speakerColors[hash % speakerColors.count]
    }

    private func speakerInitials(_ name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[parts.count - 1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
