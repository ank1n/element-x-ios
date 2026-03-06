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
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .alert(item: $context.alertInfo)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $selectedFilter) {
                ForEach(CallFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Изменить") {
                // TODO: implement edit mode (delete call history)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .startNewCall)
            } label: {
                Image(systemName: "phone.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Meetings section
                    if !upcomingMeetings.isEmpty {
                        Section {
                            ForEach(upcomingMeetings) { meeting in
                                meetingCell(meeting)
                            }
                        } header: {
                            dateSectionHeader("Встречи")
                        }
                    }

                    // Call history
                    if context.viewState.isLoading {
                        loadingCells
                    } else if filteredCalls.isEmpty && upcomingMeetings.isEmpty {
                        emptyStateView(minHeight: geometry.size.height)
                    } else {
                        ForEach(groupedCalls, id: \.title) { group in
                            Section {
                                ForEach(group.calls) { call in
                                    callCell(call)
                                }
                            } header: {
                                dateSectionHeader(group.title)
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
    }

    private func dateSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.compound.bgSubtleSecondary)
    }

    private struct CallGroup: Equatable {
        let title: String
        let calls: [CallHistoryItem]
    }

    private var groupedCalls: [CallGroup] {
        let calendar = Calendar.current
        var groups: [(String, [CallHistoryItem])] = []
        var currentTitle = ""
        var currentCalls: [CallHistoryItem] = []

        for call in filteredCalls {
            let title = dateGroupTitle(for: call.timestamp, calendar: calendar)
            if title != currentTitle {
                if !currentCalls.isEmpty {
                    groups.append((currentTitle, currentCalls))
                }
                currentTitle = title
                currentCalls = [call]
            } else {
                currentCalls.append(call)
            }
        }
        if !currentCalls.isEmpty {
            groups.append((currentTitle, currentCalls))
        }
        return groups.map { CallGroup(title: $0.0, calls: $0.1) }
    }

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
        }

        return calls
    }

    // MARK: - Meetings

    private var upcomingMeetings: [Meeting] {
        context.viewState.meetings
            .filter { !$0.isPast }
            .sorted { $0.startTime < $1.startTime }
    }

    private func meetingCell(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Calendar icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 44, height: 44)

                    VStack(spacing: 0) {
                        Text(meetingDayShort(meeting.startTime))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                        Text(meetingDayNumber(meeting.startTime))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.green)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundColor(.compound.textSecondary)

                        Text(meetingTimeRange(meeting))
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)

                        if !meeting.location.isEmpty {
                            let location = meeting.location
                            Text("·")
                                .foregroundColor(.compound.textSecondary)
                            Image(systemName: "mappin")
                                .font(.caption2)
                                .foregroundColor(.compound.textSecondary)
                            Text(location)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    // Participant count + my RSVP status
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption2)
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
                    }
                }

                Spacer()

                // RSVP buttons
                rsvpButtons(for: meeting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 72)
        }
    }

    @ViewBuilder
    private func rsvpButtons(for meeting: Meeting) -> some View {
        let myRsvp = myRSVP(for: meeting)

        if myRsvp == nil || myRsvp == .pending {
            HStack(spacing: 6) {
                Button {
                    context.send(viewAction: .rsvpMeeting(meetingId: meeting.id, response: "accepted"))
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.green)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    context.send(viewAction: .rsvpMeeting(meetingId: meeting.id, response: "declined"))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.compound.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.compound.bgSubtleSecondary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        } else if meeting.matrixRoomId != nil {
            Button {
                context.send(viewAction: .joinMeeting(meeting))
            } label: {
                Image(systemName: "video.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.compound.iconPrimary)
                    .frame(width: 30, height: 30)
                    .background(Color.compound.bgSubtleSecondary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
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
        case .pending: return .compound.textSecondary
        }
    }

    private func meetingDayShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private func meetingDayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func meetingTimeRange(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: meeting.startTime)
        return "\(start) – \(formatter.string(from: meeting.endTime))"
    }

    // MARK: - Call History

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
