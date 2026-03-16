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
    private let accentBlue = StalkTheme.accent
    private let cardBg = Color(UIColor.systemBackground)

    enum CallFilter: CaseIterable {
        case all
        case missed

        var title: String {
            switch self {
            case .all: return SL10n.callsAll
            case .missed: return SL10n.callsMissed
            }
        }
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
        .navigationTitle(isCosmos ? SL10n.tabCalls : "")
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
        .sheet(isPresented: $context.isNewCallSheetPresented) {
            newCallSheet
        }
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
                    Text(filter.title).tag(filter)
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

            Text(SL10n.callsEmpty)
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text(SL10n.callsEmptyHint)
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
                if call.isGroupCall {
                    groupCallAvatars(call)
                } else {
                    LoadableAvatarImage(url: call.avatarURL,
                                        name: call.contactName,
                                        contentID: call.contactId,
                                        avatarSize: .custom(52),
                                        mediaProvider: context.mediaProvider)
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
                                    Text(filter.title)
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
                    LazyVStack(spacing: 0) {
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

            Text(SL10n.callsEmpty)
                .font(.compound.headingLG)
                .foregroundColor(.primary)

            Text(SL10n.callsEmptyHint)
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
                    if call.isMissed {
                        Circle()
                            .fill(Color.red.opacity(0.15))
                            .frame(width: 52, height: 52)
                            .overlay {
                                Image(systemName: "phone.arrow.down.left")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                    } else if call.isGroupCall {
                        // Наложенные аватарки для группового звонка
                        groupCallAvatars(call)
                    } else {
                        LoadableAvatarImage(url: call.avatarURL,
                                            name: call.contactName,
                                            contentID: call.contactId,
                                            avatarSize: .custom(52),
                                            mediaProvider: context.mediaProvider)
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

    // MARK: - Group Call Avatars

    /// Наложенные аватарки для группового звонка (2 аватарки + бейдж "+N")
    @ViewBuilder
    private func groupCallAvatars(_ call: CallHistoryItem) -> some View {
        let urls = call.participantAvatarURLs
        let count = call.participantCount
        let names = call.contactName.components(separatedBy: ", ")

        let url0 = urls.first
        let url1 = urls.count > 1 ? urls[1] : nil
        let name0 = names.first ?? "?"
        let name1 = names.count > 1 ? names[1] : "?"

        return ZStack {
            // Второй аватар (сзади, сдвинут вправо-вверх)
            LoadableAvatarImage(url: url1,
                                name: name1,
                                contentID: "\(call.contactId)-1",
                                avatarSize: .custom(34),
                                mediaProvider: context.mediaProvider)
                .offset(x: 12, y: -8)

            // Первый аватар (спереди, сдвинут влево-вниз)
            LoadableAvatarImage(url: url0,
                                name: name0,
                                contentID: "\(call.contactId)-0",
                                avatarSize: .custom(34),
                                mediaProvider: context.mediaProvider)
                .overlay(
                    Circle()
                        .stroke(Color(UIColor.systemBackground), lineWidth: 2)
                )
                .offset(x: -8, y: 8)

            // Бейдж "+N" если > 3 участников (2 аватарки уже видны)
            if count > 3 {
                Text("+\(count - 2)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.8)))
                    .offset(x: 16, y: 16)
            }
        }
        .frame(width: 52, height: 52)
    }

    // MARK: - Shared Data

    private func dateGroupTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return SL10n.callsToday
        } else if calendar.isDateInYesterday(date) {
            return SL10n.callsYesterday
        } else {
            let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if daysAgo < 7 {
                let formatter = DateFormatter()
                formatter.locale = Locale.current
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
        case .accepted: return SL10n.meetingAccepted
        case .declined: return SL10n.meetingDeclined
        case .pending: return SL10n.meetingRsvpPending
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

        if call.isGroupCall {
            parts.append(SL10n.callsGroup(call.participantCount))
        } else {
            switch call.callType {
            case .incoming:
                parts.append(call.isMissed ? SL10n.callsMissedCall : SL10n.callsIncoming)
            case .outgoing:
                parts.append(SL10n.callsOutgoing)
            case .video:
                parts.append(call.isMissed ? SL10n.callsMissedVideo : SL10n.callsVideoCall)
            }
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
        formatter.locale = Locale.current
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func isPlayingCall(_ call: CallHistoryItem) -> Bool {
        context.viewState.playingCallId == call.id && context.viewState.playbackState == .playing
    }

    // MARK: - New Call Sheet

    private var selectedNewCallContacts: [NewCallContact] {
        let ids = context.selectedNewCallContactIDs
        return context.viewState.newCallContacts.filter { ids.contains($0.id) }
    }

    private var filteredNewCallContacts: [NewCallContact] {
        let query = context.newCallSearchQuery
        guard !query.isEmpty else { return context.viewState.newCallContacts }
        return context.viewState.newCallContacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            ($0.matrixUserID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Короткий username из @user:server → @user
    private func shortUsername(_ matrixUserID: String?) -> String? {
        guard let uid = matrixUserID else { return nil }
        let parts = uid.components(separatedBy: ":")
        return parts.first // @user
    }

    private var callButtonTitle: String {
        let selected = selectedNewCallContacts
        if selected.isEmpty {
            return SL10n.callsCallButtonDefault
        } else if selected.count == 1 {
            return SL10n.callsCallButton(selected[0].displayName)
        } else {
            return SL10n.callsCallButtonCount(selected.count)
        }
    }

    @ViewBuilder
    private var newCallSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Чипсы выбранных контактов + поле поиска
                newCallChipsAndSearch
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Список контактов
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredNewCallContacts) { contact in
                            newCallContactRow(contact)
                        }
                    }
                }

                // Нижняя панель: Видеозвонок + кнопка
                VStack(spacing: 12) {
                    // Видеозвонок toggle
                    Button {
                        context.isVideoCall.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .stroke(context.isVideoCall ? accentBlue : Color(UIColor.systemGray3), lineWidth: 2)
                                    .frame(width: 22, height: 22)
                                if context.isVideoCall {
                                    Circle()
                                        .fill(accentBlue)
                                        .frame(width: 14, height: 14)
                                }
                            }
                            Text(SL10n.callsVideoCall)
                                .font(.system(size: 16))
                                .foregroundColor(.primary)
                        }
                    }

                    // Call button
                    Button {
                        startCallWithSelectedContacts()
                    } label: {
                        Text(callButtonTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(selectedNewCallContacts.isEmpty ? Color.gray : accentBlue)
                            )
                    }
                    .disabled(selectedNewCallContacts.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(SL10n.callsNewCall)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        context.isNewCallSheetPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var newCallChipsAndSearch: some View {
        let selected = selectedNewCallContacts

        VStack(alignment: .leading, spacing: 6) {
            // Чипсы выбранных контактов
            if !selected.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selected) { contact in
                            HStack(spacing: 4) {
                                LoadableAvatarImage(url: contact.avatarURL,
                                                    name: contact.displayName,
                                                    contentID: contact.id,
                                                    avatarSize: .custom(24),
                                                    mediaProvider: context.mediaProvider)
                                Text(contact.displayName)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(16)
                        }
                    }
                }
            }

            // Поле поиска
            TextField(SL10n.callsSearch, text: $context.newCallSearchQuery)
                .disableAutocorrection(true)
                .font(.system(size: 16))
        }
        .padding(10)
        .background(Color(UIColor.systemGray6).opacity(0.5))
        .cornerRadius(12)
    }

    private func newCallContactRow(_ contact: NewCallContact) -> some View {
        let isSelected = context.selectedNewCallContactIDs.contains(contact.id)

        return Button {
            if isSelected {
                context.selectedNewCallContactIDs.remove(contact.id)
            } else {
                context.selectedNewCallContactIDs.insert(contact.id)
            }
        } label: {
            HStack(spacing: 12) {
                // Чекбокс
                ZStack {
                    Circle()
                        .stroke(isSelected ? accentBlue : Color(UIColor.systemGray3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle()
                            .fill(accentBlue)
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                // Аватар
                LoadableAvatarImage(url: contact.avatarURL,
                                    name: contact.displayName,
                                    contentID: contact.id,
                                    avatarSize: .custom(44),
                                    mediaProvider: context.mediaProvider)

                // Имя и @username
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(contact.displayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if contact.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12))
                                .foregroundColor(accentBlue)
                        }
                    }

                    if let username = shortUsername(contact.matrixUserID) {
                        Text(username)
                            .font(.system(size: 13))
                            .foregroundColor(accentBlue)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func startCallWithSelectedContacts() {
        let selected = selectedNewCallContacts
        guard !selected.isEmpty else { return }
        context.isNewCallSheetPresented = false
        let contactIDs = selected.map(\.id)
        context.send(viewAction: .makeCall(contactIDs: contactIDs, isVideo: context.isVideoCall))
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
