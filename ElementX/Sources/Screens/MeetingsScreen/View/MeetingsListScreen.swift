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
        Color(red: 0.30, green: 0.78, blue: 0.55),  // green
        Color(red: 0.73, green: 0.45, blue: 0.90)   // purple
    ]

    /// Assign lanes (0 = first branch level, 1 = second, etc.)
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

    /// Pixels per minute for the time-proportional graph
    private let pixelsPerMinute: CGFloat = 2.0
    private let minEventHeight: CGFloat = 50
    private let graphTimelineX: CGFloat = 40  // X of main timeline
    private let graphBranchSpacing: CGFloat = 20  // spacing between branch levels

    @ViewBuilder
    private var meetingsContent: some View {
        let meetings = context.viewState.meetingsForSelectedDate
        if context.viewState.isLoading {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in skeletonCard }
            }
            .padding(.top, 8)
        } else if meetings.isEmpty {
            emptyState
                .padding(.top, 60)
        } else {
            let now = Date()
            let isToday = Calendar.current.isDateInToday(context.viewState.selectedDate)
            let lanes = assignLanes(meetings)

            VStack(spacing: 16) {
                // Git-граф (пропорциональный по времени)
                gitTimelineGraph(meetings: meetings, lanes: lanes, isToday: isToday, now: now)

                // Список карточек с цветовыми маркерами
                VStack(spacing: 8) {
                    ForEach(meetings) { meeting in
                        let lane = lanes[meeting.id] ?? 0
                        let color = branchPalette[lane % branchPalette.count]
                        let isActive = isToday && meeting.startTime <= now && meeting.endTime > now

                        Button {
                            context.send(viewAction: .selectMeeting(meeting))
                        } label: {
                            HStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color)
                                    .frame(width: 5)
                                    .padding(.vertical, 4)
                                meetingCard(meeting, isActive: isActive)
                                    .padding(.leading, 4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Зелёный таб текущего времени
                if isToday {
                    let activeMeeting = meetings.first(where: { $0.startTime <= now && $0.endTime > now })
                    if activeMeeting == nil {
                        let nextMeeting = meetings.first(where: { $0.startTime > now })
                        nowTab(nextMeeting: nextMeeting)
                    }
                }
            }
        }
    }

    // MARK: - Git Timeline Graph (пропорциональный по времени)

    @ViewBuilder
    private func gitTimelineGraph(meetings: [Meeting], lanes: [Int: Int], isToday: Bool, now: Date) -> some View {
        let allTimes = meetings.flatMap { [$0.startTime, $0.endTime] }
        let minTime = allTimes.min() ?? Date()
        let maxTime = allTimes.max() ?? Date()
        let totalMinutes = maxTime.timeIntervalSince(minTime) / 60
        let graphHeight = max(CGFloat(totalMinutes) * pixelsPerMinute, CGFloat(meetings.count) * minEventHeight)
        let maxLane = (lanes.values.max() ?? 0)
        let graphWidth: CGFloat = graphTimelineX + CGFloat(maxLane + 1) * graphBranchSpacing + 140 // space for labels

        Canvas { ctx, size in
            let scale = graphHeight / CGFloat(totalMinutes)

            func timeY(_ date: Date) -> CGFloat {
                let mins = date.timeIntervalSince(minTime) / 60
                return CGFloat(mins) * scale + 12 // 12px top padding
            }

            let mainX = graphTimelineX

            // --- Main vertical timeline ---
            let mainPath = Path { p in
                p.move(to: CGPoint(x: mainX, y: 0))
                p.addLine(to: CGPoint(x: mainX, y: graphHeight + 24))
            }
            ctx.stroke(mainPath, with: .color(Color.secondary.opacity(0.2)), lineWidth: 1.5)

            // --- Branches for each meeting ---
            for meeting in meetings {
                let lane = lanes[meeting.id] ?? 0
                let color = branchPalette[lane % branchPalette.count]
                let branchX = mainX + CGFloat(lane + 1) * graphBranchSpacing
                let startY = timeY(meeting.startTime)
                let endY = timeY(meeting.endTime)
                let curveR: CGFloat = 8

                // Fork: main → branch (smooth curve)
                let forkPath = Path { p in
                    p.move(to: CGPoint(x: mainX, y: startY))
                    p.addLine(to: CGPoint(x: mainX + curveR, y: startY))
                    p.addQuadCurve(
                        to: CGPoint(x: branchX, y: startY + curveR),
                        control: CGPoint(x: branchX, y: startY)
                    )
                }
                ctx.stroke(forkPath, with: .color(color), lineWidth: 2)

                // Vertical branch line
                let branchLine = Path { p in
                    p.move(to: CGPoint(x: branchX, y: startY + curveR))
                    p.addLine(to: CGPoint(x: branchX, y: endY - curveR))
                }
                ctx.stroke(branchLine, with: .color(color), lineWidth: 2)

                // Merge: branch → main (smooth curve)
                let mergePath = Path { p in
                    p.move(to: CGPoint(x: branchX, y: endY - curveR))
                    p.addQuadCurve(
                        to: CGPoint(x: mainX + curveR, y: endY),
                        control: CGPoint(x: branchX, y: endY)
                    )
                    p.addLine(to: CGPoint(x: mainX, y: endY))
                }
                ctx.stroke(mergePath, with: .color(color), lineWidth: 2)

                // Start dot
                let startDot = CGRect(x: mainX - 4, y: startY - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: startDot), with: .color(color))

                // End dot
                let endDot = CGRect(x: mainX - 3, y: endY - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: endDot), with: .color(color.opacity(0.5)))

                // Meeting title label (next to branch)
                let labelX = branchX + 8
                let labelY = startY + (endY - startY) / 2 - 7
                ctx.draw(
                    Text(meeting.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color),
                    at: CGPoint(x: labelX, y: labelY),
                    anchor: .leading
                )

                // Active indicator
                if isToday && meeting.startTime <= now && meeting.endTime > now {
                    let nowY = timeY(now)
                    let nowDot = CGRect(x: branchX - 5, y: nowY - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: nowDot), with: .color(.green))
                    let nowRing = CGRect(x: branchX - 8, y: nowY - 8, width: 16, height: 16)
                    ctx.stroke(Path(ellipseIn: nowRing), with: .color(.green.opacity(0.3)), lineWidth: 2)
                }
            }

            // --- Time labels on the left ---
            var drawnLabels: [CGFloat] = [] // avoid overlapping labels
            for meeting in meetings {
                for date in [meeting.startTime, meeting.endTime] {
                    let y = timeY(date)
                    // Skip if too close to previous label
                    if drawnLabels.contains(where: { abs($0 - y) < 14 }) { continue }
                    drawnLabels.append(y)

                    ctx.draw(
                        Text(timeFormatter.string(from: date))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary),
                        at: CGPoint(x: mainX - 10, y: y),
                        anchor: .trailing
                    )
                }
            }

            // --- Now line (if today) ---
            if isToday {
                let nowY = timeY(now)
                if nowY >= 0 && nowY <= graphHeight + 24 {
                    let nowLine = Path { p in
                        p.move(to: CGPoint(x: 0, y: nowY))
                        p.addLine(to: CGPoint(x: size.width, y: nowY))
                    }
                    ctx.stroke(nowLine, with: .color(.green.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .frame(height: graphHeight + 24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBg)
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        )
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

    // (Timeline rows removed — git graph + card list approach)

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

    // (Branch curves now drawn directly in Canvas)

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

