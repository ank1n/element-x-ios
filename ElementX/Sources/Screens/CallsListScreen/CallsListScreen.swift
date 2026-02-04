//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct CallsListScreen: View {
    @ObservedObject var context: CallsListScreenViewModelType.Context
    @State private var selectedFilter: CallFilter = .all

    enum CallFilter: String, CaseIterable {
        case all = "Все"
        case missed = "Пропущенные"
        case incoming = "Входящие"
        case outgoing = "Исходящие"
    }

    var body: some View {
        content
            .navigationTitle("Звонки")
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .toolbarBloom(hasSearchBar: true)
            .alert(item: $context.alertInfo)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            settingsButton
        }
        .backportSharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .startNewCall)
            } label: {
                CompoundIcon(\.plus)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            context.send(viewAction: .showSettings)
        } label: {
            LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                name: context.viewState.userDisplayName,
                                contentID: context.viewState.userID,
                                avatarSize: .user(on: .chats),
                                mediaProvider: context.mediaProvider)
                .clipShape(.circle)
                .overlayBadge(10, isBadged: context.viewState.requiresExtraAccountSetup)
                .compositingGroup()
        }
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Section {
                        if context.viewState.isLoading {
                            loadingCells
                        } else if filteredCalls.isEmpty {
                            emptyStateView(minHeight: geometry.size.height)
                        } else {
                            ForEach(filteredCalls) { call in
                                callCell(call)
                            }
                        }
                    } header: {
                        filtersSection
                    }
                }
                .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .compoundSearchField()
                .disableAutocorrection(true)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(context.viewState.callHistory.isEmpty ? .basedOnSize : .automatic)
            .refreshable {
                context.send(viewAction: .refresh)
            }
            .onAppear {
                context.send(viewAction: .refresh)
            }
        }
    }

    @ViewBuilder
    private var filtersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CallFilter.allCases, id: \.self) { filter in
                    FilterChipView(title: filter.rawValue,
                                   isSelected: selectedFilter == filter) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.compound.bgCanvasDefault)
    }

    private var loadingCells: some View {
        ForEach(0..<5, id: \.self) { _ in
            skeletonCell
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var skeletonCell: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.compound.bgSubtleSecondary)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 140, height: 16)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 100, height: 14)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func emptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "phone")
                .font(.system(size: 64))
                .foregroundColor(.compound.textSecondary)

            Text("Нет звонков")
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text("История звонков будет отображаться здесь")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    private var filteredCalls: [CallHistoryItem] {
        var calls = context.viewState.callHistory

        if !context.searchQuery.isEmpty {
            calls = calls.filter {
                $0.contactName.localizedCaseInsensitiveContains(context.searchQuery)
            }
        }

        switch selectedFilter {
        case .all:
            break
        case .missed:
            calls = calls.filter { $0.isMissed }
        case .incoming:
            calls = calls.filter { $0.callType == .incoming }
        case .outgoing:
            calls = calls.filter { $0.callType == .outgoing }
        }

        return calls
    }

    private func callCell(_ call: CallHistoryItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(avatarColor(for: call.contactName))
                        .frame(width: 52, height: 52)

                    Text(String(call.contactName.prefix(1)).uppercased())
                        .font(.compound.headingMD)
                        .foregroundColor(.white)
                }

                // Call info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(call.contactName)
                            .font(.compound.bodyLGSemibold)
                            .foregroundColor(call.isMissed ? .red : .compound.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(timeAgo(from: call.timestamp))
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: callIcon(for: call))
                            .font(.caption)
                            .foregroundColor(call.isMissed ? .red : .compound.textSecondary)

                        Text(callDescription(for: call))
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)

                        if call.hasRecording {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundColor(.compound.iconAccentTertiary)
                        }
                    }
                }

                // Action button - always shown for consistent layout
                Button {
                    if call.hasRecording {
                        context.send(viewAction: .playRecording(call))
                    } else {
                        context.send(viewAction: .selectCall(call))
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(actionButtonBackground(for: call))
                            .frame(width: 40, height: 40)

                        if context.viewState.playingCallId == call.id && context.viewState.playbackState == .loading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: actionButtonIcon(for: call))
                                .font(.system(size: 14))
                                .foregroundColor(actionButtonForeground(for: call))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Progress bar when playing this call
            if context.viewState.playingCallId == call.id && context.viewState.playbackState != .stopped {
                HStack(spacing: 8) {
                    Text(formatTime(context.viewState.playbackCurrentTime))
                        .font(.caption2)
                        .foregroundColor(.compound.textSecondary)
                        .monospacedDigit()

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.compound.bgSubtleSecondary)
                                .frame(height: 4)
                                .cornerRadius(2)

                            Rectangle()
                                .fill(Color.compound.iconAccentTertiary)
                                .frame(width: geometry.size.width * context.viewState.playbackProgress, height: 4)
                                .cornerRadius(2)
                        }
                    }
                    .frame(height: 4)

                    Text(formatTime(context.viewState.playbackDuration))
                        .font(.caption2)
                        .foregroundColor(.compound.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 84)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink
        ]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    private func callIcon(for call: CallHistoryItem) -> String {
        switch call.callType {
        case .incoming:
            return "phone.arrow.down.left"
        case .outgoing:
            return "phone.arrow.up.right"
        case .video:
            return "video"
        }
    }

    private func callDescription(for call: CallHistoryItem) -> String {
        var parts: [String] = []

        switch call.callType {
        case .incoming:
            parts.append(call.isMissed ? "Пропущенный" : "Входящий")
        case .outgoing:
            parts.append("Исходящий")
        case .video:
            parts.append(call.isMissed ? "Пропущенный видеозвонок" : "Видеозвонок")
        }

        if let duration = call.duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            parts.append(String(format: "%d:%02d", minutes, seconds))
        }

        return parts.joined(separator: " • ")
    }

    private func timeAgo(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func isPlayingCall(_ call: CallHistoryItem) -> Bool {
        context.viewState.playingCallId == call.id && context.viewState.playbackState == .playing
    }

    // MARK: - Action Button Helpers

    private func actionButtonIcon(for call: CallHistoryItem) -> String {
        if call.hasRecording {
            return isPlayingCall(call) ? "pause.fill" : "play.fill"
        } else {
            return "phone.fill"
        }
    }

    private func actionButtonBackground(for call: CallHistoryItem) -> Color {
        if call.hasRecording && isPlayingCall(call) {
            return Color.compound.bgActionPrimaryRest
        }
        return Color.compound.bgSubtleSecondary
    }

    private func actionButtonForeground(for call: CallHistoryItem) -> Color {
        if call.hasRecording && isPlayingCall(call) {
            return .white
        }
        return .compound.iconPrimary
    }
}

// MARK: - Previews

struct CallsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        // Setup ServiceLocator for preview
        ServiceLocator.shared.setupLocalCallHistoryService()

        let mockService = CallHistoryService(baseURL: URL(string: "https://livekit.market.implica.ru/recording-api")!)
        let viewModel = CallsListScreenViewModel(
            userSession: UserSessionMock(.init()),
            localCallHistoryService: ServiceLocator.shared.localCallHistoryService,
            callHistoryService: mockService
        )
        return NavigationStack {
            CallsListScreen(context: viewModel.context)
        }
    }
}
