//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

typealias MeetingDetailViewModelType = StateStoreViewModel<MeetingDetailViewState, MeetingDetailViewAction>

struct MeetingDetailScreen: View {
    @ObservedObject var context: MeetingDetailViewModelType.Context

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(context.viewState.meeting.title)
                        .font(.title2.bold())

                    statusBadge(context.viewState.meeting.status)
                }

                Divider()

                // Date & Time
                infoRow(icon: "calendar", title: "Начало", value: dateFormatter.string(from: context.viewState.meeting.startTime))
                infoRow(icon: "calendar.badge.clock", title: "Конец", value: dateFormatter.string(from: context.viewState.meeting.endTime))

                if !context.viewState.meeting.location.isEmpty {
                    infoRow(icon: "mappin.and.ellipse", title: "Место", value: context.viewState.meeting.location)
                }

                if !context.viewState.meeting.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Описание", systemImage: "text.alignleft")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                        Text(context.viewState.meeting.description)
                            .font(.body)
                    }
                }

                // Meeting link
                if let link = context.viewState.meetingLink {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Ссылка на встречу", systemImage: "link")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                        HStack {
                            Text(link)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                context.send(viewAction: .copyLink)
                            } label: {
                                Image(systemName: context.viewState.linkCopied ? "checkmark" : "doc.on.doc")
                                    .foregroundColor(context.viewState.linkCopied ? .green : .accentColor)
                            }
                        }
                    }
                }

                // Guest access
                HStack(spacing: 12) {
                    Image(systemName: context.viewState.meeting.accessLevel == "public" ? "globe" : "lock.fill")
                        .foregroundColor(.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Доступ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(context.viewState.meeting.accessLevel == "public" ? "Открытая (гости разрешены)" : "Закрытая (только участники)")
                            .font(.subheadline)
                    }
                }

                // Attachments
                if let attachments = context.viewState.meeting.attachments, !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Вложения (\(attachments.count))", systemImage: "paperclip")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: attachmentIcon(attachment.filename))
                                    .foregroundColor(.accentColor)
                                Text(attachment.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Divider()

                // Participants
                VStack(alignment: .leading, spacing: 8) {
                    Label("Участники (\(context.viewState.meeting.participants.count))", systemImage: "person.2")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)

                    ForEach(context.viewState.meeting.participants) { participant in
                        participantRow(participant)
                    }
                }

                Divider()

                // Actions
                VStack(spacing: 12) {
                    // Join call button
                    if let roomId = context.viewState.meeting.matrixRoomId, !roomId.isEmpty {
                        Button {
                            context.send(viewAction: .joinCall)
                        } label: {
                            Label("Присоединиться к звонку", systemImage: "phone.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // RSVP buttons (only for non-creators)
                    if !context.viewState.isCreator, let myRSVP = context.viewState.myRSVP {
                        HStack(spacing: 12) {
                            rsvpButton("Приму", icon: "checkmark", status: .accepted, current: myRSVP)
                            rsvpButton("Отклоню", icon: "xmark", status: .declined, current: myRSVP)
                        }
                    }

                    // Edit & Delete (creator only)
                    if context.viewState.isCreator {
                        HStack(spacing: 12) {
                            Button {
                                context.send(viewAction: .edit)
                            } label: {
                                Label("Редактировать", systemImage: "pencil")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                context.send(viewAction: .delete)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Встреча")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func participantRow(_ participant: MeetingParticipant) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(rsvpColor(participant.rsvp))
                .frame(width: 8, height: 8)
            Text(participant.displayName)
                .font(.subheadline)
            Spacer()
            Text(rsvpLabel(participant.rsvp))
                .font(.caption)
                .foregroundColor(rsvpColor(participant.rsvp))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ status: MeetingStatus) -> some View {
        let (text, color): (String, Color) = switch status {
        case .scheduled: ("Запланирована", .blue)
        case .active: ("Активна", .green)
        case .completed: ("Завершена", .gray)
        case .cancelled: ("Отменена", .red)
        }
        Text(text)
            .font(.caption.bold())
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(6)
    }

    @ViewBuilder
    private func rsvpButton(_ label: String, icon: String, status: RSVPStatus, current: RSVPStatus) -> some View {
        if current == status {
            Button {
                context.send(viewAction: .rsvp(status))
            } label: {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                context.send(viewAction: .rsvp(status))
            } label: {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
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

    private func attachmentIcon(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "mp4", "mov", "avi": return "film"
        default: return "doc"
        }
    }
}
