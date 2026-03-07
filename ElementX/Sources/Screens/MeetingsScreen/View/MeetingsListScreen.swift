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

    // MARK: - Meetings Content (Git-style lanes)

    private let branchPalette: [Color] = [
        Color(red: 0.38, green: 0.42, blue: 0.96), // blue (main)
        Color(red: 0.95, green: 0.55, blue: 0.25),  // orange
        Color(red: 0.30, green: 0.78, blue: 0.55),  // green
        Color(red: 0.73, green: 0.45, blue: 0.90)   // purple
    ]

    /// Assign each meeting a lane (0 = main, 1+ = branches).
    /// First meeting in an overlap group stays on lane 0, others get lane 1, 2...
    private func assignLanes(_ meetings: [Meeting]) -> [Int: Int] {
        var lanes: [Int: Int] = [:] // meetingId -> lane
        var activeLanes: [(endTime: Date, lane: Int)] = [] // tracks when each lane frees up

        for meeting in meetings {
            // Remove expired lanes
            activeLanes.removeAll { $0.endTime <= meeting.startTime }

            // Find lowest available lane
            let usedLanes = Set(activeLanes.map(\.lane))
            var lane = 0
            while usedLanes.contains(lane) { lane += 1 }

            lanes[meeting.id] = lane
            activeLanes.append((endTime: meeting.endTime, lane: lane))
        }
        return lanes
    }

    /// For a given row, which lanes have active meetings passing through?
    /// Returns lanes that have a meeting spanning this row but whose dot is NOT on this row.
    private func activeLanesAt(index: Int, meetings: [Meeting], lanes: [Int: Int]) -> [(lane: Int, color: Color)] {
        let current = meetings[index]
        var result: [(lane: Int, color: Color)] = []
        for (i, m) in meetings.enumerated() {
            guard i != index else { continue }
            let lane = lanes[m.id] ?? 0
            // Meeting m spans through current's row if it started before/at current and ends after current starts
            if m.startTime <= current.startTime && m.endTime > current.startTime {
                result.append((lane: lane, color: branchPalette[lane % branchPalette.count]))
            }
        }
        return result
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
            let nowInsertIndex: Int? = (isToday && activeMeeting == nil) ? meetings.firstIndex(where: { $0.startTime > now }) : nil
            let nextMeeting: Meeting? = isToday ? meetings.first(where: { $0.startTime > now }) : nil
            let lanes = assignLanes(meetings)
            let maxLane = lanes.values.max() ?? 0

            LazyVStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    if let ni = nowInsertIndex, index == ni {
                        nowTab(nextMeeting: nextMeeting)
                    }

                    // Свободно между встречами (рабочие часы)
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
                    let lane = lanes[meeting.id] ?? 0
                    let laneColor = branchPalette[lane % branchPalette.count]

                    // Determine fork/merge for this meeting's lane
                    let isForking = lane > 0 // branches always fork from main
                    let isMerging = lane > 0 // branches always merge back

                    // Which OTHER lanes are active (passing through) at this row?
                    let passingLanes = activeLanesAt(index: index, meetings: meetings, lanes: lanes)

                    // Is this the first row of this meeting on its lane? (fork point)
                    // Is this the last row? (merge point)
                    // For fork: check if previous meeting in list is NOT on same lane or doesn't overlap
                    let showFork = lane > 0 && (index == 0 || {
                        let prev = meetings[index - 1]
                        return !(prev.endTime > meeting.startTime && (lanes[prev.id] ?? 0) == lane)
                    }())
                    let showMerge = lane > 0 && (index == meetings.count - 1 || {
                        let next = meetings[index + 1]
                        return !(meeting.endTime > next.startTime && (lanes[next.id] ?? 0) == lane)
                    }())

                    timelineMeetingRow(
                        meeting,
                        isActive: isActive,
                        showNowDot: isActive,
                        lane: lane,
                        laneColor: laneColor,
                        maxLane: maxLane,
                        showFork: showFork,
                        showMerge: showMerge,
                        passingLanes: passingLanes
                    )
                }
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

    // MARK: - Timeline Meeting Row (git-style lanes)

    private let laneSpacing: CGFloat = 18 // horizontal distance between lanes
    private let mainLineX: CGFloat = 10   // center of lane 0

    /// Width of the timeline column based on max lanes
    private func timelineColumnWidth(maxLane: Int) -> CGFloat {
        CGFloat(maxLane + 1) * laneSpacing + 8
    }

    /// X position for a given lane
    private func laneX(_ lane: Int) -> CGFloat {
        mainLineX + CGFloat(lane) * laneSpacing
    }

    @ViewBuilder
    private func timelineMeetingRow(
        _ meeting: Meeting,
        isActive: Bool,
        showNowDot: Bool = false,
        lane: Int,
        laneColor: Color,
        maxLane: Int,
        showFork: Bool,
        showMerge: Bool,
        passingLanes: [(lane: Int, color: Color)]
    ) -> some View {
        let colWidth = timelineColumnWidth(maxLane: maxLane)
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

                // Timeline column — lanes drawn as overlay on a spacer
                Color.clear
                    .frame(width: colWidth)
                    .overlay {
                        GeometryReader { geo in
                            let h = geo.size.height
                            let dotY: CGFloat = 14 // vertical center of the dot
                            let myX = laneX(lane)
                            let mainX = laneX(0)

                            // 1. Main vertical line (lane 0) — always present
                            Path { p in
                                p.move(to: CGPoint(x: mainX, y: 0))
                                p.addLine(to: CGPoint(x: mainX, y: h))
                            }
                            .stroke(
                                lane == 0 && isActive ? Color.green.opacity(0.4) : Color.secondary.opacity(0.15),
                                lineWidth: lane == 0 && isActive ? 2.5 : 1.5
                            )

                            // 2. Passing lanes — other meetings that span through this row
                            ForEach(Array(passingLanes.enumerated()), id: \.offset) { _, pl in
                                let plX = laneX(pl.lane)
                                Path { p in
                                    p.move(to: CGPoint(x: plX, y: 0))
                                    p.addLine(to: CGPoint(x: plX, y: h))
                                }
                                .stroke(pl.color.opacity(0.6), lineWidth: 2)
                            }

                            // 3. This meeting's branch line (if not on main)
                            if lane > 0 {
                                // Fork curve: from main line to this lane
                                if showFork {
                                    Path { p in
                                        p.move(to: CGPoint(x: mainX, y: dotY - 8))
                                        p.addQuadCurve(
                                            to: CGPoint(x: myX, y: dotY + 8),
                                            control: CGPoint(x: myX, y: dotY - 8)
                                        )
                                    }
                                    .stroke(laneColor, lineWidth: 2)
                                }

                                // Vertical line on branch lane (below dot to bottom)
                                if !showMerge {
                                    Path { p in
                                        p.move(to: CGPoint(x: myX, y: dotY))
                                        p.addLine(to: CGPoint(x: myX, y: h))
                                    }
                                    .stroke(laneColor.opacity(0.6), lineWidth: 2)
                                }

                                // Merge curve: from this lane back to main
                                if showMerge {
                                    Path { p in
                                        p.move(to: CGPoint(x: myX, y: dotY + 8))
                                        p.addQuadCurve(
                                            to: CGPoint(x: mainX, y: h),
                                            control: CGPoint(x: myX, y: h)
                                        )
                                    }
                                    .stroke(laneColor, lineWidth: 2)
                                }
                            }

                            // 4. Dot (commit) on this meeting's lane
                            Circle()
                                .fill(isActive ? Color.green : laneColor)
                                .frame(width: isActive ? 10 : 8, height: isActive ? 10 : 8)
                                .position(x: myX, y: dotY)

                            // Now indicator ring on active dot
                            if showNowDot {
                                Circle()
                                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                                    .frame(width: 16, height: 16)
                                    .position(x: myX, y: dotY)
                            }
                        }
                    }

                // Card (with colored left edge for branch meetings)
                if lane > 0 {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(laneColor)
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

    // (Branch curves are now drawn inline via Path in timelineMeetingRow)

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

