//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

typealias MeetingDetailViewModelType = StateStoreViewModel<MeetingDetailViewState, MeetingDetailViewAction>

struct MeetingDetailScreen: View {
    @ObservedObject var context: MeetingDetailViewModelType.Context

    // Colors matching calendar screen
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE"
        return f
    }()

    private var meeting: Meeting { context.viewState.meeting }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Header card
                    headerCard

                    // Date & Time card
                    dateTimeCard

                    // Description card (if present)
                    if !meeting.description.isEmpty {
                        descriptionCard
                    }

                    // Participants card
                    participantsCard

                    // Actions
                    actionsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Встреча")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 12) {
            // Status + Title
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primary)

                    statusBadge(meeting.status)
                }
                Spacer()

                // Status icon
                statusCircle(meeting.status)
            }

            // Quick info row
            HStack(spacing: 16) {
                if !meeting.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(accentBlue)
                        Text(meeting.location)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(accentBlue)
                    Text("\(meeting.participants.count)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if meeting.accessLevel == "public" {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("Открытая")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Date & Time Card

    private var dateTimeCard: some View {
        VStack(spacing: 0) {
            // Date header with weekday
            HStack(spacing: 12) {
                // Day circle
                VStack(spacing: 2) {
                    Text(timeFormatter.string(from: meeting.startTime))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text("\(Calendar.current.component(.day, from: meeting.startTime))")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 56, height: 56)
                .background(accentBlue)
                .cornerRadius(14)

                VStack(alignment: .leading, spacing: 4) {
                    Text(weekdayFormatter.string(from: meeting.startTime).capitalized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(dateFormatter.string(from: meeting.startTime))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(16)

            Divider()
                .padding(.horizontal, 16)

            // Duration row
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 14))
                    .foregroundColor(accentBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(timeFormatter.string(from: meeting.startTime)) — \(timeFormatter.string(from: meeting.endTime))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text(durationText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(16)

            // Meeting link (if available)
            if let link = context.viewState.meetingLink {
                Divider()
                    .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 14))
                        .foregroundColor(accentBlue)
                        .frame(width: 24)

                    Text(link)
                        .font(.system(size: 13))
                        .foregroundColor(accentBlue)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        context.send(viewAction: .copyLink)
                    } label: {
                        Image(systemName: context.viewState.linkCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundColor(context.viewState.linkCopied ? .green : accentBlue)
                    }
                }
                .padding(16)
            }
        }
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Description Card

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13))
                    .foregroundColor(accentBlue)
                Text("Описание")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(meeting.description)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Participants Card

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13))
                    .foregroundColor(accentBlue)
                Text("Участники (\(meeting.participants.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            ForEach(meeting.participants) { participant in
                participantRow(participant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    @ViewBuilder
    private func participantRow(_ participant: MeetingParticipant) -> some View {
        HStack(spacing: 10) {
            // Avatar circle with initial
            ZStack {
                Circle()
                    .fill(avatarColor(for: participant.displayName))
                Text(String(participant.displayName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)

            Text(participant.displayName)
                .font(.system(size: 14))
                .foregroundColor(.primary)

            Spacer()

            // RSVP pill
            Text(rsvpLabel(participant.rsvp))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(rsvpColor(participant.rsvp))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(rsvpColor(participant.rsvp).opacity(0.1))
                .cornerRadius(8)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 10) {
            // Join call — via Matrix room or ensure-room by meeting code
            if meeting.matrixRoomId != nil || meeting.meetingCode != nil {
                Button {
                    context.send(viewAction: .joinCall)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 15))
                        Text("Начать звонок")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accentBlue)
                    .cornerRadius(14)
                    .shadow(color: accentBlue.opacity(0.3), radius: 6, y: 2)
                }
            }

            // RSVP (non-creator)
            if !context.viewState.isCreator, let myRSVP = context.viewState.myRSVP {
                HStack(spacing: 10) {
                    rsvpActionButton("Приму", icon: "checkmark", status: .accepted, current: myRSVP, color: .green)
                    rsvpActionButton("Отклоню", icon: "xmark", status: .declined, current: myRSVP, color: .red)
                }
            }

            // Edit & Delete (creator)
            if context.viewState.isCreator {
                HStack(spacing: 10) {
                    Button {
                        context.send(viewAction: .edit)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                            Text("Редактировать")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(accentBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(cardBg)
                        .cornerRadius(14)
                        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    }

                    Button {
                        context.send(viewAction: .delete)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                            Text("Удалить")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(cardBg)
                        .cornerRadius(14)
                        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(_ status: MeetingStatus) -> some View {
        let (text, color): (String, Color) = switch status {
        case .scheduled: ("Запланирована", accentBlue)
        case .active: ("Активна", .green)
        case .completed: ("Завершена", .gray)
        case .cancelled: ("Отменена", .red)
        }
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .cornerRadius(8)
    }

    @ViewBuilder
    private func statusCircle(_ status: MeetingStatus) -> some View {
        let (icon, color): (String, Color) = switch status {
        case .scheduled: ("clock.fill", accentBlue)
        case .active: ("phone.fill", .green)
        case .completed: ("checkmark", .gray)
        case .cancelled: ("xmark", .red)
        }
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundColor(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.1))
            .clipShape(Circle())
    }

    @ViewBuilder
    private func rsvpActionButton(_ label: String, icon: String, status: RSVPStatus, current: RSVPStatus, color: Color) -> some View {
        let isActive = current == status
        Button {
            context.send(viewAction: .rsvp(status))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "\(icon).circle.fill" : icon)
                    .font(.system(size: 14))
                Text(isActive ? (status == .accepted ? "Принято" : "Отклонено") : label)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(isActive ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(isActive ? color : cardBg)
            .cornerRadius(14)
            .shadow(color: isActive ? color.opacity(0.3) : .black.opacity(0.05), radius: 6, y: 2)
        }
    }

    private var durationText: String {
        let interval = meeting.endTime.timeIntervalSince(meeting.startTime)
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours) ч" }
        return "\(hours) ч \(rem) мин"
    }

    private func rsvpColor(_ rsvp: RSVPStatus) -> Color {
        switch rsvp {
        case .accepted: return .green
        case .declined: return .red
        case .pending: return .gray
        }
    }

    private func rsvpLabel(_ rsvp: RSVPStatus) -> String {
        switch rsvp {
        case .accepted: return "Принял"
        case .declined: return "Отклонил"
        case .pending: return "Ожидает"
        }
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            accentBlue,
            Color(red: 0.96, green: 0.49, blue: 0.37),
            Color(red: 0.30, green: 0.78, blue: 0.55),
            Color(red: 0.95, green: 0.68, blue: 0.25),
            Color(red: 0.73, green: 0.45, blue: 0.90)
        ]
        // Stable hash — djb2 algorithm (hashValue is randomized per launch)
        var hash: UInt64 = 5381
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char.value)
        }
        let index = Int(hash % UInt64(colors.count))
        return colors[index]
    }
}
