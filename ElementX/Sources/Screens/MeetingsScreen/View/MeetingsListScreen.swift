//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

struct MeetingsListScreen: View {
    @ObservedObject var context: MeetingsScreenViewModelType.Context

    // Colors matching reference design
    private let accentBlue = StalkTheme.accent
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        return f
    }()

    private let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE"
        return f
    }()

    private let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM yyyy"
        return f
    }()

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header (date + refresh)
                headerView
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                // Calendar (week strip / expandable month)
                CalendarGridView(selectedDate: Binding(get: { context.viewState.selectedDate },
                                                       set: { context.send(viewAction: .selectDate($0)) }),
                                 datesWithMeetings: context.viewState.datesWithMeetings,
                                 holidays: context.viewState.holidays)
                    .padding(.bottom, 8)

                // Filter row
                filterRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Meetings list
                ScrollViewReader { proxy in
                    ScrollView {
                        meetingsContent
                            .padding(.horizontal, 16)
                            .padding(.bottom, 70)
                    }
                    .refreshable {
                        context.send(viewAction: .refresh)
                    }
                    .onChange(of: context.viewState.selectedDate) {
                        if Calendar.current.isDateInToday(context.viewState.selectedDate) {
                            scrollToNow(proxy: proxy)
                        }
                    }
                    .onChange(of: context.viewState.meetingsForSelectedDate.count) {
                        // Scroll when meetings data arrives (loading finished or data changed)
                        if Calendar.current.isDateInToday(context.viewState.selectedDate),
                           !context.viewState.meetingsForSelectedDate.isEmpty {
                            scrollToNow(proxy: proxy)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(SL10n.meetingCalendar)
                    .font(.system(size: 20, weight: .bold))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    context.send(viewAction: .createMeeting)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accentBlue)
                }
            }
        }
    }

    // MARK: - Header (day number + weekday + month)

    private let today = Date()

    private var headerView: some View {
        Button {
            context.send(viewAction: .selectDate(today))
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(dayNumberFormatter.string(from: today))
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(weekdayFormatter.string(from: today).capitalized)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(monthYearFormatter.string(from: today).capitalized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter Row

    @State private var selectedFilterIndex = 0
    private let filters = ["all", SL10n.meetingTitle, SL10n.meetingCall]

    private var filterRow: some View {
        HStack {
            Text(SL10n.meetingTime)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Text(SL10n.meetingEvent)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Menu {
                ForEach(Array(filters.enumerated()), id: \.offset) { idx, filter in
                    Button(filter == "all" ? SL10n.meetingAll : filter) {
                        selectedFilterIndex = idx
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedFilterIndex == 0 ? SL10n.meetingAll : filters[selectedFilterIndex])
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accentBlue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accentBlue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule()
                    .fill(accentBlue.opacity(0.1)))
            }
        }
    }

    // MARK: - Meetings Content

    /// Group overlapping meetings into clusters
    private func clusterMeetings(_ meetings: [Meeting]) -> [[Meeting]] {
        guard !meetings.isEmpty else { return [] }
        var clusters: [[Meeting]] = []
        var current: [Meeting] = [meetings[0]]
        var clusterEnd = meetings[0].endTime

        for i in 1..<meetings.count {
            let m = meetings[i]
            if m.startTime < clusterEnd {
                // Overlaps with current cluster
                current.append(m)
                clusterEnd = max(clusterEnd, m.endTime)
            } else {
                clusters.append(current)
                current = [m]
                clusterEnd = m.endTime
            }
        }
        clusters.append(current)
        return clusters
    }

    private let parallelColors: [Color] = [
        StalkTheme.accent, // blue
        Color(red: 0.95, green: 0.55, blue: 0.25), // orange
        Color(red: 0.30, green: 0.78, blue: 0.55), // green
        Color(red: 0.73, green: 0.45, blue: 0.90) // purple
    ]

    @ViewBuilder
    private var meetingsContent: some View {
        let meetings = context.viewState.meetingsForSelectedDate
        if context.viewState.isLoading {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    skeletonCard
                }
            }
            .padding(.top, 8)
        } else if meetings.isEmpty {
            emptyState
                .padding(.top, 60)
        } else {
            let now = Date()
            let isToday = Calendar.current.isDateInToday(context.viewState.selectedDate)
            let activeMeeting = isToday ? meetings.first(where: { $0.startTime <= now && $0.endTime > now }) : nil
            let nowInsertIndex: Int? = (isToday && activeMeeting == nil) ? meetings.firstIndex(where: { $0.startTime > now }) : nil
            let nextMeeting: Meeting? = isToday ? meetings.first(where: { $0.startTime > now }) : nil
            let clusters = clusterMeetings(meetings)

            VStack(spacing: 0) {
                // Pre-compute flat start index for each cluster
                let clusterStartIndices: [Int] = {
                    var indices = [Int]()
                    var idx = 0
                    for cluster in clusters {
                        indices.append(idx)
                        idx += cluster.count
                    }
                    return indices
                }()

                ForEach(Array(clusters.enumerated()), id: \.offset) { clusterIdx, cluster in
                    let clusterStartFlatIdx = clusterStartIndices[clusterIdx]

                    // Now tab before this cluster?
                    if let ni = nowInsertIndex, ni >= clusterStartFlatIdx, ni < clusterStartFlatIdx + cluster.count {
                        nowTab(nextMeeting: nextMeeting)
                    }

                    // Gap indicator between clusters
                    if clusterIdx > 0 {
                        let prevCluster = clusters[clusterIdx - 1]
                        let prevEnd = prevCluster.map(\.endTime).max() ?? Date.distantPast
                        let curStart = cluster.first?.startTime ?? Date.distantFuture
                        let gapMinutes = Int(curStart.timeIntervalSince(prevEnd) / 60)
                        let prevHour = Calendar.current.component(.hour, from: prevEnd)
                        let curHour = Calendar.current.component(.hour, from: curStart)
                        if gapMinutes > 0, prevHour >= 9, curHour < 18 {
                            gapIndicator(minutes: gapMinutes)
                        }
                    }

                    if cluster.count == 1 {
                        let meeting = cluster[0]
                        let isActive = isToday && meeting.startTime <= now && meeting.endTime > now
                        timelineMeetingRow(meeting, isActive: isActive)
                    } else {
                        parallelMeetingsRow(cluster, isToday: isToday, now: now)
                    }
                }
                if isToday, nowInsertIndex == nil, activeMeeting == nil {
                    nowTab(nextMeeting: nil)
                }
            }
        }
    }

    // MARK: - Meeting Card (full style)

    private func meetingCard(_ meeting: Meeting, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if isActive {
                    Text(SL10n.meetingNow)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    statusIcon(meeting)
                }
            }

            if !meeting.description.isEmpty {
                Text(meeting.description)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if !meeting.location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(meeting.location)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                if !meeting.participants.isEmpty {
                    // Participant avatars (overlapping)
                    HStack(spacing: -6) {
                        ForEach(meeting.participants.prefix(5)) { participant in
                            let profile = context.viewState.participantProfiles[participant.userId]
                            let name = profile?.displayName ?? participantDisplayName(participant.userId)
                            LoadableAvatarImage(url: profile?.avatarURL,
                                                name: name,
                                                contentID: participant.userId,
                                                avatarSize: .custom(22),
                                                mediaProvider: context.viewState.mediaProvider)
                                .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        }
                        if meeting.participants.count > 5 {
                            Text("+\(meeting.participants.count - 5)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color(UIColor.systemGray5)))
                                .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(durationText(meeting))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .padding(.leading, 4)
        .background(HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(meeting.isPast ? Color.secondary.opacity(0.3) : meeting.labelColor)
                .frame(width: 3)
            Spacer()
        })
        .background(LinearGradient(colors: [
                Color(UIColor.systemBackground),
                (isActive ? Color.green : meeting.labelColor).opacity(0.1)
            ],
            startPoint: .leading,
            endPoint: .trailing))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(isActive ? Color.green.opacity(0.3) : meeting.labelColor.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Timeline Meeting Row

    private func timelineMeetingRow(_ meeting: Meeting, isActive: Bool) -> some View {
        Button {
            context.send(viewAction: .selectMeeting(meeting))
        } label: {
            HStack(alignment: .top, spacing: 0) {
                // Time column
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeFormatter.string(from: meeting.startTime))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isActive ? .green : .primary)
                    Text(timeFormatter.string(from: meeting.endTime))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(width: 48, alignment: .trailing)

                // Timeline dot + line
                VStack(spacing: 0) {
                    Circle()
                        .fill(isActive ? Color.green : statusColor(meeting.status))
                        .frame(width: isActive ? 10 : 8, height: isActive ? 10 : 8)
                        .padding(.top, 6)
                    Rectangle()
                        .fill(isActive ? Color.green.opacity(0.3) : Color.secondary.opacity(0.15))
                        .frame(width: isActive ? 2 : 1)
                }
                .frame(width: 24)

                // Card
                meetingCard(meeting, isActive: isActive)
            }
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Parallel Meetings Row (side-by-side mini cards)

    @ViewBuilder
    private func parallelMeetingsRow(_ meetings: [Meeting], isToday: Bool, now: Date) -> some View {
        let earliest = meetings.map(\.startTime).min() ?? Date()
        let latestEnd = meetings.map(\.endTime).max() ?? Date()

        HStack(alignment: .top, spacing: 0) {
            // Time column — show range of the cluster
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeFormatter.string(from: earliest))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(timeFormatter.string(from: latestEnd))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(width: 48, alignment: .trailing)

            // Timeline dot + line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(accentBlue)
                        .frame(width: 8, height: 8)
                    // Overlap indicator
                    Circle()
                        .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                        .frame(width: 14, height: 14)
                }
                .padding(.top, 6)
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1)
            }
            .frame(width: 24)

            // Side-by-side mini cards
            HStack(spacing: 6) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { _, meeting in
                    let isActive = isToday && meeting.startTime <= now && meeting.endTime > now
                    Button {
                        context.send(viewAction: .selectMeeting(meeting))
                    } label: {
                        miniMeetingCard(meeting, isActive: isActive, accentColor: meeting.labelColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func miniMeetingCard(_ meeting: Meeting, isActive: Bool, accentColor: Color) -> some View {
        HStack(spacing: 0) {
            // Vertical color bar on left edge
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("\(timeFormatter.string(from: meeting.startTime))–\(timeFormatter.string(from: meeting.endTime))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    if !meeting.participants.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text("\(meeting.participants.count)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text(durationText(meeting))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if isActive {
                    Text(SL10n.meetingNow)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZStack {
            cardBg
            if isActive { Color.green.opacity(0.05) }
        })
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Gap Indicator (only during working hours 09-18)

    private func gapIndicator(minutes: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 48)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 1, height: 6)
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 4, height: 4)
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 1, height: 6)
            }
            .frame(width: 24)

            Text(SL10n.meetingFree(formatGapMinutes(minutes)))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.4))
                .padding(.leading, 4)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func formatGapMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return String(format: NSLocalizedString("stalk_duration_minutes", tableName: "Localizable", value: "%d мин", comment: "Duration in minutes (short)"), minutes) }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? String(format: NSLocalizedString("stalk_duration_hours", tableName: "Localizable", value: "%d ч", comment: "Duration in hours (short)"), h) : String(format: NSLocalizedString("stalk_duration_hours_minutes", tableName: "Localizable", value: "%1$d ч %2$d мин", comment: "Duration in hours and minutes (short)"), h, m)
    }

    // MARK: - Now Tab (зелёный блок текущего времени)

    private func nowTab(nextMeeting: Meeting?) -> some View {
        HStack(spacing: 0) {
            // Время слева
            Text(timeFormatter.string(from: Date()))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))
                .frame(width: 48, alignment: .trailing)

            // Точка на таймлайне
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 24)

            // Карточка с обратным отсчётом — стиль как meetingCard
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))

                    if let next = nextMeeting {
                        let minutesLeft = max(0, Int(next.startTime.timeIntervalSince(Date()) / 60))
                        Text(SL10n.meetingUntil(next.title, formatGapMinutes(minutesLeft)))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 0.2, green: 0.65, blue: 0.35))
                            .lineLimit(1)
                    } else {
                        Text(SL10n.meetingNoMore)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 0.2, green: 0.65, blue: 0.35))
                    }

                    Spacer()
                }
            }
            .padding(12)
            .background(ZStack {
                cardBg
                Color.green.opacity(0.05)
            })
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
        .padding(.bottom, 12)
        .id("now_tab")
    }

    // MARK: - Status

    @ViewBuilder
    private func statusIcon(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .active:
            Image(systemName: "phone.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
                .padding(6)
                .background(Color.green.opacity(0.12))
                .clipShape(Circle())
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.green)
        case .scheduled:
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
                .foregroundColor(accentBlue)
                .padding(6)
                .background(accentBlue.opacity(0.12))
                .clipShape(Circle())
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)
        }
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .scheduled: return accentBlue
        case .active: return .green
        case .completed: return .gray
        case .cancelled: return .red
        }
    }

    private func scrollToNow(proxy: ScrollViewProxy) {
        // Multiple attempts with increasing delays to handle layout timing
        for delay in [0.1, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("now_tab", anchor: .center)
                }
            }
        }
    }

    /// Extract display name from Matrix userId: @name:server → name
    private func participantDisplayName(_ userId: String) -> String {
        guard userId.hasPrefix("@") else { return userId }
        let withoutAt = String(userId.dropFirst())
        if let colonIdx = withoutAt.firstIndex(of: ":") {
            return String(withoutAt[withoutAt.startIndex..<colonIdx])
        }
        return withoutAt
    }

    private func durationText(_ meeting: Meeting) -> String {
        let interval = meeting.endTime.timeIntervalSince(meeting.startTime)
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return String(format: NSLocalizedString("stalk_duration_minutes", tableName: "Localizable", value: "%d мин", comment: "Duration in minutes (short)"), minutes)
        }
        let hours = minutes / 60
        let remainingMin = minutes % 60
        if remainingMin == 0 {
            return String(format: NSLocalizedString("stalk_duration_hours", tableName: "Localizable", value: "%d ч", comment: "Duration in hours (short)"), hours)
        }
        return String(format: NSLocalizedString("stalk_duration_hours_minutes", tableName: "Localizable", value: "%1$d ч %2$d мин", comment: "Duration in hours and minutes (short)"), hours, remainingMin)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.35))
            Text(SL10n.meetingNoEvents)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Button {
                context.send(viewAction: .createMeeting)
            } label: {
                Text(SL10n.meetingCreate)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accentBlue)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule()
                        .stroke(accentBlue, lineWidth: 1))
            }
        }
    }

    // MARK: - Skeleton

    private var skeletonCard: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 30, height: 12)
            }
            .frame(width: 48)

            Color.clear.frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 120, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
                    .frame(width: 80, height: 12)
            }
            .padding(12)
            .background(cardBg)
            .cornerRadius(14)
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }
}
