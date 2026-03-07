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
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
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
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEE"
        return f
    }()

    private let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "MMM yyyy"
        return f
    }()

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header (date + refresh)
                headerView
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                // Calendar (week strip / expandable month)
                CalendarGridView(
                    selectedDate: Binding(
                        get: { context.viewState.selectedDate },
                        set: { context.send(viewAction: .selectDate($0)) }
                    ),
                    datesWithMeetings: context.viewState.datesWithMeetings,
                    holidays: context.viewState.holidays
                )
                .padding(.bottom, 8)

                // Filter row
                filterRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Meetings list
                ScrollView {
                    meetingsContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }
                .refreshable {
                    context.send(viewAction: .refresh)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Календарь")
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

    // MARK: - Filter Row

    @State private var selectedFilterIndex = 0
    private let filters = ["all", "Встреча", "Звонок"]

    private var filterRow: some View {
        HStack {
            Text("Время")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Text("Событие")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Menu {
                ForEach(Array(filters.enumerated()), id: \.offset) { idx, filter in
                    Button(filter == "all" ? "Все" : filter) {
                        selectedFilterIndex = idx
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedFilterIndex == 0 ? "Все" : filters[selectedFilterIndex])
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accentBlue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accentBlue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(accentBlue.opacity(0.1))
                )
            }
        }
    }

    // MARK: - Meetings Content

    private let branchPalette: [Color] = [
        Color(red: 0.38, green: 0.42, blue: 0.96), // blue
        Color(red: 0.95, green: 0.55, blue: 0.25),  // orange
        Color(red: 0.30, green: 0.78, blue: 0.55)   // green
    ]

    /// Branch color for a meeting (nil if not parallel)
    private func branchColor(for meeting: Meeting, in meetings: [Meeting]) -> Color? {
        let overlapping = meetings.filter { $0.startTime < meeting.endTime && $0.endTime > meeting.startTime }
        guard overlapping.count > 1 else { return nil }
        let idx = overlapping.firstIndex(where: { $0.id == meeting.id }) ?? 0
        return branchPalette[idx % branchPalette.count]
    }

    /// Info about parallel branches visible at this row
    struct BranchInfo {
        let color: Color
        let isForking: Bool   // branch starts here (curve out from main)
        let isMerging: Bool   // branch ends here (curve back into main)
    }

    /// Get branch lines that should be drawn alongside this meeting's row
    private func branchLines(for meeting: Meeting, in meetings: [Meeting]) -> [BranchInfo] {
        let others = meetings.filter {
            $0.id != meeting.id && $0.startTime < meeting.endTime && $0.endTime > meeting.startTime
        }
        return others.compactMap { other -> BranchInfo? in
            guard let color = branchColor(for: other, in: meetings) else { return nil }
            let isForking = other.startTime >= meeting.startTime && other.startTime <= meeting.endTime
            let isMerging = other.endTime >= meeting.startTime && other.endTime <= meeting.endTime
            return BranchInfo(color: color, isForking: isForking, isMerging: isMerging)
        }
    }

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
            // Индекс для вставки зелёного таба текущего времени (только если нет активной встречи)
            let nowInsertIndex: Int? = (isToday && activeMeeting == nil) ? meetings.firstIndex(where: { $0.startTime > now }) : nil
            // Следующая встреча после текущего времени (для обратного отсчёта)
            let nextMeeting: Meeting? = isToday ? meetings.first(where: { $0.startTime > now }) : nil

            LazyVStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    // Зелёный таб текущего времени — между прошедшими и будущими встречами
                    if let ni = nowInsertIndex, index == ni {
                        nowTab(nextMeeting: nextMeeting)
                    }

                    // Индикатор свободного времени между встречами (рабочие часы 09-18)
                    if index > 0 {
                        let prev = meetings[index - 1]
                        let gapMinutes = Int(meeting.startTime.timeIntervalSince(prev.endTime) / 60)
                        let prevHour = Calendar.current.component(.hour, from: prev.endTime)
                        let curHour = Calendar.current.component(.hour, from: meeting.startTime)
                        if gapMinutes > 0, prevHour >= 9, curHour < 18 {
                            gapIndicator(minutes: gapMinutes)
                        }
                    }

                    let isActive = isToday && meeting.startTime <= now && meeting.endTime > now
                    let myBranch = branchColor(for: meeting, in: meetings)
                    let branches = branchLines(for: meeting, in: meetings)

                    timelineMeetingRow(meeting, isActive: isActive, showNowDot: isActive, branchColor: myBranch, branches: branches)
                }
                // Если все встречи прошли — зелёный таб в конце
                if isToday, nowInsertIndex == nil, activeMeeting == nil {
                    nowTab(nextMeeting: nil)
                }
            }
        }
    }

    // MARK: - Meeting Card (full style)

    @ViewBuilder
    private func meetingCard(_ meeting: Meeting, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if isActive {
                    Text("Сейчас")
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
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text("\(meeting.participants.count)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

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
        .background(isActive ? Color.green.opacity(0.05) : cardBg)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Timeline Meeting Row (with branch curves for parallel meetings)

    @ViewBuilder
    private func timelineMeetingRow(_ meeting: Meeting, isActive: Bool, showNowDot: Bool = false, branchColor: Color? = nil, branches: [BranchInfo] = []) -> some View {
        let hasParallel = branchColor != nil
        let timelineWidth: CGFloat = branches.isEmpty ? 24 : 38
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

                // Timeline column: main line + branch lines drawn as overlay
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(branchColor ?? (isActive ? Color.green : statusColor(meeting.status)))
                            .frame(width: isActive ? 10 : 8, height: isActive ? 10 : 8)
                        if showNowDot {
                            Circle()
                                .stroke(Color.red.opacity(0.4), lineWidth: 2)
                                .frame(width: 16, height: 16)
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.top, 6)
                    Rectangle()
                        .fill(isActive ? Color.green.opacity(0.3) : Color.secondary.opacity(0.15))
                        .frame(width: isActive ? 2 : 1)
                }
                .frame(width: timelineWidth)
                .overlay {
                    // Branch curves drawn as overlay (gets parent's actual size)
                    if !branches.isEmpty {
                        GeometryReader { geo in
                            let h = geo.size.height
                            let midX = timelineWidth / 2
                            let bX = timelineWidth - 4

                            ForEach(Array(branches.enumerated()), id: \.offset) { _, branch in
                                if branch.isForking {
                                    BranchCurve(from: CGPoint(x: midX, y: 12),
                                                through: CGPoint(x: bX, y: 30),
                                                to: CGPoint(x: bX, y: h),
                                                type: .fork)
                                        .stroke(branch.color, lineWidth: 2)
                                } else if branch.isMerging {
                                    BranchCurve(from: CGPoint(x: bX, y: 0),
                                                through: CGPoint(x: bX, y: h - 18),
                                                to: CGPoint(x: midX, y: h),
                                                type: .merge)
                                        .stroke(branch.color, lineWidth: 2)
                                } else {
                                    // Straight parallel line (no fork/merge — middle of overlap)
                                    Path { p in
                                        p.move(to: CGPoint(x: bX, y: 0))
                                        p.addLine(to: CGPoint(x: bX, y: h))
                                    }
                                    .stroke(branch.color.opacity(0.5), lineWidth: 2)
                                }
                            }
                        }
                    }
                }

                // Card (with colored left edge if parallel)
                if hasParallel, let bc = branchColor {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bc)
                            .frame(width: 4)
                            .padding(.vertical, 6)
                        meetingCard(meeting, isActive: isActive)
                            .padding(.leading, -1)
                    }
                } else {
                    meetingCard(meeting, isActive: isActive)
                }
            }
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
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

            Text("Свободно \(formatGapMinutes(minutes))")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.4))
                .padding(.leading, 4)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func formatGapMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) мин" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    // MARK: - Now Tab (зелёный блок текущего времени)

    @ViewBuilder
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

            // Карточка с обратным отсчётом
            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))

                if let next = nextMeeting {
                    let minutesLeft = max(0, Int(next.startTime.timeIntervalSince(Date()) / 60))
                    Text("До «\(next.title)» — \(formatGapMinutes(minutesLeft))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 0.2, green: 0.65, blue: 0.35))
                        .lineLimit(1)
                } else {
                    Text("Встреч больше нет")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 0.2, green: 0.65, blue: 0.35))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            )
        }
        .padding(.bottom, 12)
    }

    // MARK: - Branch Curve Shape

    private enum BranchCurveType { case fork, merge }

    private struct BranchCurve: Shape {
        let from: CGPoint
        let through: CGPoint
        let to: CGPoint
        let type: BranchCurveType

        func path(in rect: CGRect) -> Path {
            var path = Path()
            switch type {
            case .fork:
                // Curve out from main, then straight down
                path.move(to: from)
                path.addQuadCurve(to: through, control: CGPoint(x: to.x, y: from.y))
                path.addLine(to: to)
            case .merge:
                // Straight down, then curve back to main
                path.move(to: from)
                path.addLine(to: through)
                path.addQuadCurve(to: to, control: CGPoint(x: from.x, y: to.y))
            }
            return path
        }
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

    private func durationText(_ meeting: Meeting) -> String {
        let interval = meeting.endTime.timeIntervalSince(meeting.startTime)
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(minutes) мин"
        }
        let hours = minutes / 60
        let remainingMin = minutes % 60
        if remainingMin == 0 {
            return "\(hours) ч"
        }
        return "\(hours) ч \(remainingMin) мин"
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.35))
            Text("Нет событий на этот день")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Button {
                context.send(viewAction: .createMeeting)
            } label: {
                Text("Создать встречу")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accentBlue)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .stroke(accentBlue, lineWidth: 1)
                    )
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

