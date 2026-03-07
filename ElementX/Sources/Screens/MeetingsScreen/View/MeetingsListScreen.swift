//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

// MARK: - PreferenceKey for collecting dot positions

private struct MeetingDotPosition: Equatable {
    let meetingId: Int
    let centerY: CGFloat // Y relative to timeline coordinate space
}

private struct MeetingDotPreferenceKey: PreferenceKey {
    static var defaultValue: [MeetingDotPosition] = []
    static func reduce(value: inout [MeetingDotPosition], nextValue: () -> [MeetingDotPosition]) {
        value.append(contentsOf: nextValue())
    }
}

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

    // MARK: - Git-style Timeline

    private let branchPalette: [Color] = [
        Color(red: 0.38, green: 0.42, blue: 0.96), // blue (main)
        Color(red: 0.95, green: 0.55, blue: 0.25),  // orange
        Color(red: 0.30, green: 0.78, blue: 0.55),  // green
        Color(red: 0.73, green: 0.45, blue: 0.90)   // purple
    ]

    private let timeColumnWidth: CGFloat = 48
    private let timelineColumnWidth: CGFloat = 28
    private let mainLineX: CGFloat = 62  // timeColumnWidth(48) + timelineColumnWidth/2(14)
    private let branchOffsetX: CGFloat = 16 // how far branch is from main

    /// Assign lanes: 0 = main, 1+ = branches
    private func assignLanes(_ meetings: [Meeting]) -> [Int: Int] {
        var lanes: [Int: Int] = [:]
        var activeLanes: [(endTime: Date, lane: Int)] = []

        for meeting in meetings {
            activeLanes.removeAll { $0.endTime <= meeting.startTime }
            let usedLanes = Set(activeLanes.map(\.lane))
            var lane = 0
            while usedLanes.contains(lane) { lane += 1 }
            lanes[meeting.id] = lane
            activeLanes.append((endTime: meeting.endTime, lane: lane))
        }
        return lanes
    }

    @State private var dotPositions: [MeetingDotPosition] = []

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

            VStack(spacing: 0) {
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

                    timelineMeetingRow(meeting, isActive: isActive, lane: lane)
                }
                if isToday, nowInsertIndex == nil, activeMeeting == nil {
                    nowTab(nextMeeting: nil)
                }
            }
            .coordinateSpace(name: "timeline")
            .onPreferenceChange(MeetingDotPreferenceKey.self) { positions in
                dotPositions = positions
            }
            .overlay(alignment: .topLeading) {
                // Единый overlay для ВСЕХ линий git-графа
                timelineOverlay(meetings: meetings, lanes: lanes, isToday: isToday, now: now)
            }
        }
    }

    // MARK: - Timeline Overlay (рисует все линии как единый граф)

    @ViewBuilder
    private func timelineOverlay(meetings: [Meeting], lanes: [Int: Int], isToday: Bool, now: Date) -> some View {
        Canvas { ctx, size in
            let positions = dotPositions
            guard !positions.isEmpty else { return }

            // Sort positions by Y
            let sorted = meetings.compactMap { m -> (meeting: Meeting, lane: Int, y: CGFloat)? in
                guard let lane = lanes[m.id],
                      let pos = positions.first(where: { $0.meetingId == m.id }) else { return nil }
                return (meeting: m, lane: lane, y: pos.centerY)
            }
            guard !sorted.isEmpty else { return }

            let mainX = mainLineX
            let bX = mainX + branchOffsetX

            // --- Draw main vertical line (through all lane-0 dots, top to bottom) ---
            let mainPath = Path { p in
                p.move(to: CGPoint(x: mainX, y: 0))
                p.addLine(to: CGPoint(x: mainX, y: size.height))
            }
            ctx.stroke(mainPath, with: .color(Color.secondary.opacity(0.18)), lineWidth: 1.5)

            // --- Draw branch lines ---
            // Group branch meetings (lane > 0) and draw their fork + line + merge
            for item in sorted where item.lane > 0 {
                let laneX = mainX + CGFloat(item.lane) * branchOffsetX
                let color = branchPalette[item.lane % branchPalette.count]
                let y = item.y

                // Find the meeting on main (lane 0) that overlaps — use it as fork/merge anchor
                let mainOverlap = sorted.filter { $0.lane == 0 && $0.meeting.startTime < item.meeting.endTime && $0.meeting.endTime > item.meeting.startTime }
                let forkY = mainOverlap.first.map { $0.y } ?? (y - 30)
                let mergeY: CGFloat
                // Find next meeting on main after this branch ends
                let nextMain = sorted.first(where: { $0.lane == 0 && $0.y > y })
                mergeY = nextMain.map { $0.y } ?? (y + 30)

                // Fork curve: from main to branch
                let forkPath = Path { p in
                    p.move(to: CGPoint(x: mainX, y: forkY))
                    p.addQuadCurve(
                        to: CGPoint(x: laneX, y: y),
                        control: CGPoint(x: laneX, y: forkY)
                    )
                }
                ctx.stroke(forkPath, with: .color(color), lineWidth: 2)

                // Merge curve: from branch back to main
                let mergePath = Path { p in
                    p.move(to: CGPoint(x: laneX, y: y))
                    p.addQuadCurve(
                        to: CGPoint(x: mainX, y: mergeY),
                        control: CGPoint(x: laneX, y: mergeY)
                    )
                }
                ctx.stroke(mergePath, with: .color(color), lineWidth: 2)
            }

            // --- Draw dots (commits) ---
            for item in sorted {
                let laneX = item.lane == 0 ? mainX : mainX + CGFloat(item.lane) * branchOffsetX
                let color = branchPalette[item.lane % branchPalette.count]
                let isActive = isToday && item.meeting.startTime <= now && item.meeting.endTime > now
                let dotSize: CGFloat = isActive ? 10 : 8

                // Dot
                let dotRect = CGRect(x: laneX - dotSize / 2, y: item.y - dotSize / 2, width: dotSize, height: dotSize)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(isActive ? .green : color))

                // Green ring for active
                if isActive {
                    let ringSize: CGFloat = 16
                    let ringRect = CGRect(x: laneX - ringSize / 2, y: item.y - ringSize / 2, width: ringSize, height: ringSize)
                    ctx.stroke(Path(ellipseIn: ringRect), with: .color(Color.green.opacity(0.4)), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Meeting Row (clean — no lines, just time + card)

    @ViewBuilder
    private func timelineMeetingRow(_ meeting: Meeting, isActive: Bool, lane: Int) -> some View {
        let laneColor = branchPalette[lane % branchPalette.count]
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
                .frame(width: timeColumnWidth, alignment: .trailing)

                // Timeline spacer (lines drawn in overlay) + dot position reporter
                Color.clear
                    .frame(width: timelineColumnWidth)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: MeetingDotPreferenceKey.self,
                                    value: [MeetingDotPosition(
                                        meetingId: meeting.id,
                                        centerY: geo.frame(in: .named("timeline")).midY
                                    )]
                                )
                        }
                    )

                // Card (with colored left edge for branches)
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

    // MARK: - Gap Indicator (only during working hours 09-18)

    private func gapIndicator(minutes: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeColumnWidth)

            Color.clear
                .frame(width: timelineColumnWidth)

            Text("Свободно \(formatGapMinutes(minutes))")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.4))
                .padding(.leading, 4)

            Spacer()
        }
        .frame(height: 20)
    }

    private func formatGapMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) мин" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    // MARK: - Now Tab (green current time block)

    @ViewBuilder
    private func nowTab(nextMeeting: Meeting?) -> some View {
        HStack(spacing: 0) {
            // Time
            Text(timeFormatter.string(from: Date()))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))
                .frame(width: timeColumnWidth, alignment: .trailing)

            Color.clear
                .frame(width: timelineColumnWidth)

            // Card with countdown
            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))

                if let next = nextMeeting {
                    let minutesLeft = max(0, Int(next.startTime.timeIntervalSince(Date()) / 60))
                    Text("До \"\(next.title)\" — \(formatGapMinutes(minutesLeft))")
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
