//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct MeetingsListScreen: View {
    @ObservedObject var context: MeetingsScreenViewModelType.Context

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Calendar grid
                CalendarGridView(
                    selectedDate: Binding(
                        get: { context.viewState.selectedDate },
                        set: { context.send(viewAction: .selectDate($0)) }
                    ),
                    datesWithMeetings: context.viewState.datesWithMeetings,
                    holidays: context.viewState.holidays
                )

                Divider()

                // Selected date header
                HStack {
                    Text(dateFormatter.string(from: context.viewState.selectedDate))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)

                // Meetings list for selected date
                let meetings = context.viewState.meetingsForSelectedDate
                if context.viewState.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if meetings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Нет встреч на этот день")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(meetings) { meeting in
                            meetingRow(meeting)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
        .refreshable {
            context.send(viewAction: .refresh)
        }
        .navigationTitle("Календарь")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    context.send(viewAction: .createMeeting)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func meetingRow(_ meeting: Meeting) -> some View {
        Button {
            context.send(viewAction: .selectMeeting(meeting))
        } label: {
            HStack(spacing: 12) {
                // Time column
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeFormatter.string(from: meeting.startTime))
                        .font(.system(size: 14, weight: .semibold))
                    Text(timeFormatter.string(from: meeting.endTime))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(width: 50, alignment: .leading)

                // Color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(statusColor(meeting.status))
                    .frame(width: 3)

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if !meeting.location.isEmpty {
                        Label(meeting.location, systemImage: "mappin")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Participants
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(meeting.participants.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        let accepted = meeting.participants.filter { $0.rsvp == .accepted }.count
                        if accepted > 0 {
                            Text("\(accepted) подтв.")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .scheduled: return .blue
        case .active: return .green
        case .completed: return .gray
        case .cancelled: return .red
        }
    }
}
