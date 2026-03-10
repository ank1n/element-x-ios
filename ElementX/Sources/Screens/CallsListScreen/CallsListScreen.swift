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
    @AppStorage("stalk_design_theme") private var designTheme: String = "cosmos"

    private var isCosmos: Bool { designTheme == "cosmos" }

    // MARK: - Cosmos Colors

    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let cardBg = Color(UIColor.systemBackground)

    enum CallFilter: String, CaseIterable {
        case all = "Все"
        case missed = "Пропущенные"
    }

    var body: some View {
        Group {
            if isCosmos {
                ZStack {
                    LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                    cosmosContent
                }
            } else {
                classicContent
            }
        }
        .navigationTitle(isCosmos ? "Звонки" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if isCosmos {
                cosmosToolbar
            } else {
                classicToolbar
            }
        }
        .alert(item: $context.alertInfo)
    }

    @ToolbarContentBuilder
    private var cosmosToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .startNewCall)
            } label: {
                Image(systemName: "phone.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentBlue)
            }
        }
    }

    @ToolbarContentBuilder
    private var classicToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $selectedFilter) {
                ForEach(CallFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .startNewCall)
            } label: {
                Image(systemName: "phone.badge.plus")
            }
        }
    }

    // MARK: - Classic Content (unchanged)

    @ViewBuilder
    private var classicContent: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if context.viewState.isLoading {
                        classicLoadingCells
                    } else if groupedHistory.isEmpty {
                        classicEmptyStateView(minHeight: geometry.size.height)
                    } else {
                        ForEach(groupedHistory, id: \.title) { group in
                            Section {
                                ForEach(group.items) { item in
                                    switch item {
                                    case .call(let call):
                                        classicCallCell(call)
                                    case .meeting(let meeting):
                                        classicMeetingCell(meeting)
                                    }
                                }
                            } header: {
                                classicDateSectionHeader(group.title)
                            }
                        }
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
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
    }

    private func classicDateSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.compound.bgSubtleSecondary)
    }

    private var classicLoadingCells: some View {
        ForEach(0..<5, id: \.self) { _ in
            classicSkeletonCell
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var classicSkeletonCell: some View {
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

    private func classicEmptyStateView(minHeight: CGFloat) -> some View {
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

    private func classicMeetingCell(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Avatar — calendar icon style
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 52, height: 52)

                    Image(systemName: "calendar")
                        .font(.system(size: 22))
                        .foregroundColor(.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(meeting.title)
                            .font(.compound.bodyLGSemibold)
                            .foregroundColor(.compound.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(meetingTimeRange(meeting))
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundColor(.compound.textSecondary)
                        Text("\(meeting.participants.count)")
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)

                        if let myRsvp = myRSVP(for: meeting) {
                            Text("·")
                                .foregroundColor(.compound.textSecondary)
                            Text(rsvpLabel(myRsvp))
                                .font(.compound.bodySM)
                                .foregroundColor(rsvpColor(myRsvp))
                        }

                        if !meeting.location.isEmpty {
                            Text("·")
                                .foregroundColor(.compound.textSecondary)
                            Text(meeting.location)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 84)
        }
    }

    private func classicCallCell(_ call: CallHistoryItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(avatarColor(for: call.contactName))
                        .frame(width: 52, height: 52)

                    Text(String(call.contactName.prefix(1)).uppercased())
                        .font(.compound.headingMD)
                        .foregroundColor(.compound.textOnSolidPrimary)
                }

                // Call info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(call.contactName)
                            .font(.compound.bodyLGSemibold)
                            .foregroundColor(call.isMissed ? .compound.textCriticalPrimary : .compound.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(timeAgo(from: call.timestamp))
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: callIcon(for: call))
                            .font(.caption)
                            .foregroundColor(call.isMissed ? .compound.iconCriticalPrimary : .compound.textSecondary)

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

                // Action buttons
                HStack(spacing: 8) {
                    // Play button (if has recording)
                    if call.hasRecording {
                        Button {
                            context.send(viewAction: .playRecording(call))
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isPlayingCall(call) ? Color.compound.bgActionPrimaryRest : Color.compound.bgSubtleSecondary)
                                    .frame(width: 36, height: 36)

                                if context.viewState.playingCallId == call.id && context.viewState.playbackState == .loading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .compound.iconPrimary))
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: isPlayingCall(call) ? "pause.fill" : "play.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(isPlayingCall(call) ? .compound.textOnSolidPrimary : .compound.iconPrimary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Call button (always)
                    Button {
                        context.send(viewAction: .selectCall(call))
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.compound.bgSubtleSecondary)
                                .frame(width: 36, height: 36)

                            Image(systemName: "phone.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.compound.iconPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Interactive slider when playing this call
            if context.viewState.playingCallId == call.id && context.viewState.playbackState != .stopped {
                HStack(spacing: 8) {
                    Text(formatTime(context.viewState.playbackCurrentTime))
                        .font(.caption2)
                        .foregroundColor(.compound.textSecondary)
                        .monospacedDigit()

                    Slider(
                        value: Binding(
                            get: { context.viewState.playbackProgress },
                            set: { context.send(viewAction: .seekPlayback(progress: $0)) }
                        ),
                        in: 0...1
                    )
                    .tint(.compound.iconAccentTertiary)

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

    // MARK: - Cosmos Content

    @ViewBuilder
    private var cosmosContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // Capsule filters
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CallFilter.allCases, id: \.self) { filter in
                                Button {
                                    selectedFilter = filter
                                } label: {
                                    Text(filter.rawValue)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(selectedFilter == filter ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule()
                                                .fill(selectedFilter == filter ? accentBlue : Color(UIColor.systemGray6))
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    // Content
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if context.viewState.isLoading {
                            cosmosLoadingCells
                        } else if groupedHistory.isEmpty {
                            cosmosEmptyStateView(minHeight: geometry.size.height - 140)
                        } else {
                            ForEach(groupedHistory, id: \.title) { group in
                                Section {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                            switch item {
                                            case .call(let call):
                                                cosmosCallCell(call, isLast: index == group.items.count - 1)
                                            case .meeting(let meeting):
                                                cosmosMeetingCellInline(meeting, isLast: index == group.items.count - 1)
                                            }
                                        }
                                    }
                                    .background(cardBg)
                                    .cornerRadius(14)
                                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                                } header: {
                                    cosmosDateSectionHeader(group.title)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .compoundSearchField()
            .disableAutocorrection(true)
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

    private func cosmosDateSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                LinearGradient(colors: [bgGradientTop.opacity(0.9), bgGradientBottom.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom)
            )
    }

    private var cosmosLoadingCells: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                cosmosSkeletonCell
            }
        }
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var cosmosSkeletonCell: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color(UIColor.systemGray6))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray6))
                    .frame(width: 140, height: 16)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray6))
                    .frame(width: 100, height: 14)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func cosmosEmptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "phone")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Нет звонков")
                .font(.compound.headingLG)
                .foregroundColor(.primary)

            Text("История звонков будет отображаться здесь")
                .font(.compound.bodyMD)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    /// Meeting cell rendered inline inside the grouped card (same style as call cells)
    private func cosmosMeetingCellInline(_ meeting: Meeting, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Avatar — calendar icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 52, height: 52)

                    Image(systemName: "calendar")
                        .font(.system(size: 22))
                        .foregroundColor(.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(meeting.title)
                            .font(.compound.bodyLGSemibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text(meetingTimeRange(meeting))
                            .font(.compound.bodySM)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(meeting.participants.count)")
                            .font(.compound.bodySM)
                            .foregroundColor(.secondary)

                        if let myRsvp = myRSVP(for: meeting) {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(rsvpLabel(myRsvp))
                                .font(.compound.bodySM)
                                .foregroundColor(rsvpColor(myRsvp))
                        }

                        if !meeting.location.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(meeting.location)
                                .font(.compound.bodySM)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 84)
            }
        }
    }

    private func cosmosCallCell(_ call: CallHistoryItem, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Avatar with direction badge
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(call.isMissed ? Color.red.opacity(0.15) : avatarColor(for: call.contactName))
                        .frame(width: 52, height: 52)
                        .overlay {
                            if call.isMissed {
                                Image(systemName: "phone.arrow.down.left")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.red)
                            } else {
                                Text(String(call.contactName.prefix(1)).uppercased())
                                    .font(.compound.headingMD)
                                    .foregroundColor(.white)
                            }
                        }

                    // Direction badge
                    if !call.isMissed {
                        ZStack {
                            Circle()
                                .fill(Color(UIColor.systemBackground))
                                .frame(width: 22, height: 22)
                            Circle()
                                .fill(callDirectionColor(for: call))
                                .frame(width: 18, height: 18)
                            Image(systemName: callDirectionIcon(for: call))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .offset(x: 2, y: 2)
                    }
                }

                // Call info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(call.contactName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(call.isMissed ? .red : .primary)
                            .lineLimit(1)

                        Spacer()

                        Text(timeAgo(from: call.timestamp))
                            .font(.system(size: 13))
                            .foregroundColor(call.isMissed ? .red.opacity(0.7) : .secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: callIcon(for: call))
                            .font(.system(size: 11))
                            .foregroundColor(call.isMissed ? .red.opacity(0.7) : .secondary)

                        Text(callDescription(for: call))
                            .font(.system(size: 13))
                            .foregroundColor(call.isMissed ? .red.opacity(0.7) : .secondary)

                        if call.hasRecording {
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                                .foregroundColor(accentBlue)
                        }
                    }
                }

                // Action buttons
                HStack(spacing: 8) {
                    if call.hasRecording {
                        Button {
                            context.send(viewAction: .playRecording(call))
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isPlayingCall(call) ? accentBlue : Color(UIColor.systemGray6))
                                    .frame(width: 36, height: 36)

                                if context.viewState.playingCallId == call.id && context.viewState.playbackState == .loading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: isPlayingCall(call) ? "pause.fill" : "play.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(isPlayingCall(call) ? .white : .primary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        context.send(viewAction: .selectCall(call))
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(UIColor.systemGray6))
                                .frame(width: 36, height: 36)

                            Image(systemName: call.callType == .video ? "video.fill" : "phone.fill")
                                .font(.system(size: 12))
                                .foregroundColor(accentBlue)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Interactive slider when playing this call
            if context.viewState.playingCallId == call.id && context.viewState.playbackState != .stopped {
                HStack(spacing: 8) {
                    Text(formatTime(context.viewState.playbackCurrentTime))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    Slider(
                        value: Binding(
                            get: { context.viewState.playbackProgress },
                            set: { context.send(viewAction: .seekPlayback(progress: $0)) }
                        ),
                        in: 0...1
                    )
                    .tint(accentBlue)

                    Text(formatTime(context.viewState.playbackDuration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            // Divider (not on last cell)
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 84)
            }
        }
    }

    // MARK: - Shared Data

    private func dateGroupTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Сегодня"
        } else if calendar.isDateInYesterday(date) {
            return "Вчера"
        } else {
            let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if daysAgo < 7 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ru_RU")
                formatter.dateFormat = "EEEE"
                return formatter.string(from: date).capitalized
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ru_RU")
                formatter.dateFormat = "d MMMM"
                return formatter.string(from: date)
            }
        }
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
        }

        return calls
    }

    // MARK: - Unified History

    /// Wrapper that merges calls and past meetings into one timeline
    private enum HistoryItem: Identifiable {
        case call(CallHistoryItem)
        case meeting(Meeting)

        var id: String {
            switch self {
            case .call(let c): return "call-\(c.id)"
            case .meeting(let m): return "meeting-\(m.id)"
            }
        }

        var date: Date {
            switch self {
            case .call(let c): return c.timestamp
            case .meeting(let m): return m.startTime
            }
        }

        var isMissedCall: Bool {
            if case .call(let c) = self { return c.isMissed }
            return false
        }
    }

    private var unifiedHistory: [HistoryItem] {
        var items: [HistoryItem] = []

        // Past meetings where I'm the creator or was a participant
        let myID = context.viewState.userID
        let pastMeetings = context.viewState.meetings.filter { meeting in
            meeting.isPast && (
                meeting.creatorId == myID ||
                meeting.participants.contains(where: { $0.userId == myID })
            )
        }
        items += pastMeetings.map { .meeting($0) }

        // Calls (filtered by search & missed filter)
        items += filteredCalls.map { .call($0) }

        // Sort by date descending
        items.sort { $0.date > $1.date }
        return items
    }

    private struct HistoryGroup: Equatable {
        let title: String
        let items: [HistoryItem]

        static func == (lhs: HistoryGroup, rhs: HistoryGroup) -> Bool {
            lhs.title == rhs.title && lhs.items.map(\.id) == rhs.items.map(\.id)
        }
    }

    private var groupedHistory: [HistoryGroup] {
        let calendar = Calendar.current
        var groups: [(String, [HistoryItem])] = []
        var currentTitle = ""
        var currentItems: [HistoryItem] = []

        for item in unifiedHistory {
            let title = dateGroupTitle(for: item.date, calendar: calendar)
            if title != currentTitle {
                if !currentItems.isEmpty {
                    groups.append((currentTitle, currentItems))
                }
                currentTitle = title
                currentItems = [item]
            } else {
                currentItems.append(item)
            }
        }
        if !currentItems.isEmpty {
            groups.append((currentTitle, currentItems))
        }
        return groups.map { HistoryGroup(title: $0.0, items: $0.1) }
    }

    private func myRSVP(for meeting: Meeting) -> RSVPStatus? {
        meeting.participants.first(where: { $0.userId == context.viewState.userID })?.rsvp
    }

    private func rsvpLabel(_ rsvp: RSVPStatus) -> String {
        switch rsvp {
        case .accepted: return "Принято"
        case .declined: return "Отклонено"
        case .pending: return "Ожидает"
        }
    }

    private func rsvpColor(_ rsvp: RSVPStatus) -> Color {
        switch rsvp {
        case .accepted: return .green
        case .declined: return .red
        case .pending: return isCosmos ? .secondary : .compound.textSecondary
        }
    }

    private func meetingTimeRange(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: meeting.startTime)
        return "\(start) – \(formatter.string(from: meeting.endTime))"
    }

    // MARK: - Shared Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink
        ]
        var hash: UInt64 = 5381
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char.value)
        }
        let index = Int(hash % UInt64(colors.count))
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

    private func callDirectionIcon(for call: CallHistoryItem) -> String {
        switch call.callType {
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        case .video: return "video.fill"
        }
    }

    private func callDirectionColor(for call: CallHistoryItem) -> Color {
        switch call.callType {
        case .incoming: return Color(red: 0.30, green: 0.78, blue: 0.55) // green
        case .outgoing: return accentBlue
        case .video: return accentBlue
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
}

// MARK: - Previews

struct CallsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        // Setup ServiceLocator for preview
        ServiceLocator.shared.setupLocalCallHistoryService()

        let mockService = CallHistoryService(baseURL: URL(string: "https://stalk.implica.ru/recording-api")!)
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
