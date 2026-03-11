//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

private struct DayCenterItem: Equatable {
    let key: String
    let centerX: CGFloat
}

private struct DayCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [DayCenterItem] = []
    static func reduce(value: inout [DayCenterItem], nextValue: () -> [DayCenterItem]) {
        value.append(contentsOf: nextValue())
    }
}

/// Expandable calendar: week strip (collapsed) <-> full month grid (expanded).
/// Week strip: days scroll horizontally, the day closest to center gets highlighted
/// and becomes the selected date.
struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithMeetings: Set<String>
    let holidays: Set<String>

    @State private var isExpanded = false
    @State private var displayedMonth: Date = .now
    @State private var dragOffset: CGFloat = 0
    @State private var scrolledDayID: String?
    @State private var needsInitialScroll = true
    @State private var scrollProxy: ScrollViewProxy?

    private let calendar = Calendar.current
    private let weekdaysShort = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    private static let dateKeyFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var dateKeyFormatter: DateFormatter { Self.dateKeyFormat }

    private let days: [Date] = {
        let cal = Calendar.current
        let today = Date()
        var result: [Date] = []
        for offset in -90...90 {
            if let d = cal.date(byAdding: .day, value: offset, to: today) {
                result.append(d)
            }
        }
        return result
    }()

    private let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let lightBg = Color(red: 0.94, green: 0.95, blue: 1.0)

    private let cellWidth: CGFloat = 54
    private let cellSpacing: CGFloat = 6
    private let cellHeight: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                monthView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                weekStripView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if value.translation.height > 40 {
                            isExpanded = true
                        } else if value.translation.height < -40 {
                            isExpanded = false
                        }
                        dragOffset = 0
                    }
                }
        )
        .onChange(of: selectedDate) {
            let selectedMonth = calendar.dateComponents([.year, .month], from: selectedDate)
            let displayedMonthComps = calendar.dateComponents([.year, .month], from: displayedMonth)
            if selectedMonth != displayedMonthComps {
                displayedMonth = selectedDate
            }
        }
    }

    // MARK: - Week Strip — scroll with fixed center highlight

    private var weekStripView: some View {
        GeometryReader { outerGeo in
            let screenWidth = outerGeo.size.width
            let screenMidX = screenWidth / 2
            let sideInset = (screenWidth - cellWidth) / 2

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cellSpacing) {
                        ForEach(days, id: \.timeIntervalSince1970) { date in
                            let key = dateKeyFormatter.string(from: date)
                            dayCell(date: date, isCenter: key == scrolledDayID)
                                .padding(.vertical, 10) // room for shadow
                                .id(key)
                                .background(
                                    GeometryReader { cellGeo in
                                        Color.clear
                                            .preference(
                                                key: DayCenterPreferenceKey.self,
                                                value: [DayCenterItem(
                                                    key: key,
                                                    centerX: cellGeo.frame(in: .global).midX
                                                )]
                                            )
                                    }
                                )
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sideInset)
                }
                .scrollPosition(id: $scrolledDayID, anchor: .center)
                .onChange(of: scrolledDayID) { _, newID in
                    guard let newID, !needsInitialScroll else { return }
                    if let date = days.first(where: { dateKeyFormatter.string(from: $0) == newID }) {
                        if !calendar.isDate(date, inSameDayAs: selectedDate) {
                            selectedDate = date
                        }
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .idle, let scrolledDayID {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            proxy.scrollTo(scrolledDayID, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    let todayKey = dateKeyFormatter.string(from: selectedDate)
                    scrolledDayID = todayKey
                    proxy.scrollTo(todayKey, anchor: .center)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        needsInitialScroll = false
                    }
                }
            }
        }
        .frame(height: cellHeight + 24) // extra space for shadow to not clip
    }

    /// Day cell with blue bg when centered. No animation on state change.
    private func dayCell(date: Date, isCenter: Bool) -> some View {
        let key = dateKeyFormatter.string(from: date)
        let isToday = calendar.isDateInToday(date)
        let isHoliday = holidays.contains(key)
        let isWeekend = calendar.isDateInWeekend(date)
        let hasMeeting = datesWithMeetings.contains(key)
        let dayNum = calendar.component(.day, from: date)
        let weekday = shortWeekday(for: date)

        let dayColor: Color = {
            if isCenter { return .white }
            if isToday { return accentBlue }
            if isHoliday { return .red }
            if isWeekend { return .red.opacity(0.7) }
            return .primary
        }()

        let weekdayColor: Color = {
            if isCenter { return .white.opacity(0.9) }
            if isHoliday || isWeekend { return .red.opacity(0.5) }
            return .secondary
        }()

        return VStack(spacing: 4) {
            Text("\(dayNum)")
                .font(.system(size: isCenter ? 26 : 18, weight: isCenter || isToday ? .bold : .medium))
                .foregroundColor(dayColor)

            Text(weekday)
                .font(.system(size: isCenter ? 13 : 11, weight: .medium))
                .foregroundColor(weekdayColor)

            Circle()
                .fill(hasMeeting ? (isCenter ? Color.white : Color.orange) : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(width: cellWidth, height: cellHeight)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isCenter ? accentBlue : (isToday ? accentBlue.opacity(0.12) : Color.clear))
                .shadow(color: isCenter ? accentBlue.opacity(0.35) : .clear, radius: 8, y: 3)
        )
        .transaction { $0.animation = nil }
    }

    // MARK: - Month Grid (Expanded)

    private var monthView: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: previousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer()
                Text(monthYearFormatter.string(from: displayedMonth).capitalized)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: nextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            HStack(spacing: 0) {
                ForEach(weekdaysShort, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            let monthDays = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        monthDayCell(day)
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func monthDayCell(_ date: Date) -> some View {
        let key = dateKeyFormatter.string(from: date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let isHoliday = holidays.contains(key)
        let hasMeeting = datesWithMeetings.contains(key)
        let isWeekend = calendar.isDateInWeekend(date)

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedDate = date
                scrolledDayID = key
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected || isToday ? .bold : .regular))
                    .foregroundColor(monthDayColor(isSelected: isSelected, isToday: isToday, isHoliday: isHoliday, isWeekend: isWeekend))

                Circle()
                    .fill(hasMeeting ? (isSelected ? Color.white : Color.orange) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accentBlue : Color.clear)
                    .shadow(color: isSelected ? accentBlue.opacity(0.35) : .clear, radius: 6, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func monthDayColor(isSelected: Bool, isToday: Bool = false, isHoliday: Bool, isWeekend: Bool) -> Color {
        if isSelected { return .white }
        if isToday { return accentBlue }
        if isHoliday { return .red }
        if isWeekend { return .red.opacity(0.7) }
        return .primary
    }

    // MARK: - Helpers

    private func daysInMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }
        var weekday = calendar.component(.weekday, from: firstDay)
        weekday = (weekday + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: weekday)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                result.append(date)
            }
        }
        return result
    }

    private func shortWeekday(for date: Date) -> String {
        let idx = (calendar.component(.weekday, from: date) + 5) % 7
        return weekdaysShort[idx]
    }

    private func previousMonth() {
        if let prev = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.25)) { displayedMonth = prev }
        }
    }

    private func nextMonth() {
        if let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.25)) { displayedMonth = next }
        }
    }
}
