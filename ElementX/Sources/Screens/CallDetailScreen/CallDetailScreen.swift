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
        .navigationTitle("Детали звонка")
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
                    Text("\(context.viewState.call.participantCount) участников")
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
                Text("Загрузка...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if let status = context.viewState.transcriptionData?.status, status.isInProgress {
            VStack(spacing: 12) {
                ProgressView()
                Text("Транскрипция обрабатывается...")
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
                Text("Транскрипция недоступна")
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
            Text("Не удалось создать транскрипцию")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if context.viewState.transcriptionData?.error?.retryable == true {
                Button {
                    context.send(viewAction: .retryTranscription)
                } label: {
                    Text("Повторить")
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
                sectionHeader("Ключевые моменты")
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
                sectionHeader("Задачи")
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
                ForEach(segments) { segment in
                    HStack(alignment: .top, spacing: 10) {
                        // Speaker avatar placeholder
                        ZStack {
                            Circle()
                                .fill(speakerColor(for: segment.speaker))
                                .frame(width: 32, height: 32)
                            Text(speakerInitials(segment.speakerLabel ?? segment.speaker))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

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
        if totalSec < 60 { return "\(totalSec)с" }
        let min = totalSec / 60
        let sec = totalSec % 60
        return sec > 0 ? "\(min)м \(sec)с" : "\(min)м"
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
