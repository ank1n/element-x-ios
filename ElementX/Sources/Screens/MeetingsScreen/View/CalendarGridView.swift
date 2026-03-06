//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Expandable calendar: week strip (collapsed) <-> full month grid (expanded).
/// Week strip: fixed highlight in center, days scroll horizontally,
/// the day that lands in center becomes selected.
struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithMeetings: Set<String>
    let holidays: Set<String>

    @State private var isExpanded = false
    @State private var displayedMonth: Date = .now
    @State private var dragOffset: CGFloat = 0

    private let calendar = Calendar.current
    private let weekdaysShort = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    private let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    // Colors
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let lightBg = Color(red: 0.94, green: 0.95, blue: 1.0)

    // Cell dimensions
    private let cellWidth: CGFloat = 52
    private let cellSpacing: CGFloat = 8
    private let cellHeight: CGFloat = 76

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

    // MARK: - Week Strip (Collapsed) — center-snapping horizontal scroll

    /// Generate a wide range of days (±3 months from today)
    private var allDays: [Date] {
        let today = Date()
        var days: [Date] = []
        for offset in -90...90 {
            if let d = calendar.date(byAdding: .day, value: offset, to: today) {
                days.append(d)
            }
        }
        return days
    }

    private var weekStripView: some View {
        let days = allDays
        let selectedIndex = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: selectedDate) }) ?? 90

        return GeometryReader { outerGeo in
            let screenWidth = outerGeo.size.width
            let sideInset = (screenWidth - cellWidth) / 2

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cellSpacing) {
                        ForEach(Array(days.enumerated()), id: \.offset) { index, date in
                            dayCellContent(date)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sideInset)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: Binding<Int?>(
                    get: { selectedIndex },
                    set: { newIndex in
                        if let newIndex, newIndex >= 0, newIndex < days.count {
                            let newDate = days[newIndex]
                            if !calendar.isDate(newDate, inSameDayAs: selectedDate) {
                                selectedDate = newDate
                            }
                        }
                    }
                ))
                .onAppear {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
            // Fixed highlight frame behind center cell
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentBlue)
                    .frame(width: cellWidth + 8, height: cellHeight + 8)
            }
        }
        .frame(height: cellHeight + 12)
    }

    private func dayCellContent(_ date: Date) -> some View {
        let isCenter = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let key = dateKeyFormatter.string(from: date)
        let hasMeeting = datesWithMeetings.contains(key)
        let dayNum = calendar.component(.day, from: date)
        let weekday = shortWeekday(for: date)

        return VStack(spacing: 5) {
            Text("\(dayNum)")
                .font(.system(size: isCenter ? 24 : 18, weight: isCenter ? .bold : .semibold))
                .foregroundColor(isCenter ? .white : .primary)

            Text(weekday)
                .font(.system(size: isCenter ? 13 : 11, weight: .medium))
                .foregroundColor(isCenter ? .white.opacity(0.9) : .secondary)

            Circle()
                .fill(hasMeeting ? (isCenter ? Color.white : Color.orange) : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(width: cellWidth, height: cellHeight)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isToday && !isCenter ? lightBg : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isToday && !isCenter ? accentBlue.opacity(0.3) : Color.clear, lineWidth: 1)
        )
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

            let days = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
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
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected || isToday ? .bold : .regular))
                    .foregroundColor(monthDayColor(isSelected: isSelected, isHoliday: isHoliday, isWeekend: isWeekend))

                Circle()
                    .fill(hasMeeting ? (isSelected ? Color.white : Color.orange) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accentBlue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isToday && !isSelected ? accentBlue : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func monthDayColor(isSelected: Bool, isHoliday: Bool, isWeekend: Bool) -> Color {
        if isSelected { return .white }
        if isHoliday { return .red }
        if isWeekend { return .red.opacity(0.7) }
        return .primary
    }

    // MARK: - Data Helpers

    private func daysInMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }

        var weekday = calendar.component(.weekday, from: firstDay)
        weekday = (weekday + 5) % 7

        var days: [Date?] = Array(repeating: nil, count: weekday)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }
        return days
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
