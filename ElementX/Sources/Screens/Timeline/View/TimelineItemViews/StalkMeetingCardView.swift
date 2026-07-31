//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Карточка встречи в ленте вместо голой ссылки `/meet/s/<код>`.
///
/// STMOB-274. Значения (палитра, порядок, размеры, формат времени, правила бейджей)
/// взяты из вёрстки веба — Molly выгрузила их из `MeetingLinkBody.tsx` и CSS,
/// чтобы одна и та же встреча выглядела одинаково на телефоне и в браузере.
///
/// Пока встреча грузится или не нашлась — показываем ССЫЛКУ, а не заглушку:
/// у пользователя должен остаться рабочий способ попасть на встречу.
struct StalkMeetingCardView: View {
    let code: String
    let fallbackText: String

    @Environment(\.openURL) private var openURL

    @State private var meeting: Meeting?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let meeting {
                card(meeting)
            } else {
                fallbackLink
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            meeting = await ServiceLocator.shared.meetingLookup?.meeting(code: code)
        }
    }

    // MARK: - Карточка

    private func card(_ meeting: Meeting) -> some View {
        let palette = Self.palette(for: meeting.colorLabel)
        let isCancelled = meeting.status == .cancelled

        return HStack(spacing: 0) {
            Rectangle()
                .fill(palette.stripe)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                head(meeting, palette: palette)

                if !meeting.description.isEmpty {
                    Text(meeting.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Self.secondaryText)
                        .lineLimit(2)
                }

                row(icon: "clock", text: Self.formatWhen(meeting))

                if !meeting.creatorId.isEmpty {
                    row(icon: "person", text: Self.organiser(meeting))
                }

                if !isCancelled {
                    joinButton(palette: palette)
                }
            }
            .padding(.init(top: 9, leading: 15, bottom: 9, trailing: 12))
        }
        .frame(maxWidth: 330, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .opacity(isCancelled ? 0.6 : 1)
    }

    private func head(_ meeting: Meeting, palette: Palette) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.badgeBackground)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.stripe)
                }

            Text(meeting.title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Self.titleText)
                .lineLimit(2)

            Spacer(minLength: 6)

            badges(meeting)
        }
    }

    /// Бейджи справа. Шифрование показывается ВСЕГДА — открытый замок значит
    /// «комната не зашифрована», и это отдельная информация, а не отсутствие бейджа.
    private func badges(_ meeting: Meeting) -> some View {
        HStack(spacing: 6) {
            Image(systemName: meeting.isEncrypted ? "lock.fill" : "lock.open")
                .font(.system(size: 11))
                .foregroundStyle(meeting.isEncrypted ? Self.encryptedColor : Self.mutedColor)

            if meeting.allowsGuests {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.guestColor)
            }

            if let attachments = meeting.attachments, !attachments.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                    Text("\(attachments.count)")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundStyle(Self.attachmentColor)
            }
        }
    }

    private func row(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Self.secondaryText)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Self.secondaryText)
                .lineLimit(1)
        }
    }

    private func joinButton(palette: Palette) -> some View {
        Button {
            // Ведём себя ровно как тап по самой ссылке: приложение уже умеет
            // разрешать код встречи в комнату и открывать звонок (STMOB-216).
            if let url = URL(string: fallbackText) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 12))
                Text(SL10n.meetingJoin)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.stripe, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Фолбэк

    private var fallbackLink: some View {
        Text(fallbackText)
            .font(.body)
            .foregroundStyle(StalkTheme.accent)
            .underline()
            .onTapGesture {
                if let url = URL(string: fallbackText) { openURL(url) }
            }
    }

    // MARK: - Оформление

    struct Palette {
        let stripe: Color
        let badgeBackground: Color
    }

    /// Палитра `color_label` из веба. Неизвестное значение — зелёный, как там же.
    static func palette(for label: String) -> Palette {
        switch label.lowercased() {
        case "blue": Palette(stripe: Color(red: 0.145, green: 0.388, blue: 0.922),
                             badgeBackground: Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.10))
        case "purple": Palette(stripe: Color(red: 0.545, green: 0.361, blue: 0.965),
                               badgeBackground: Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.10))
        case "orange": Palette(stripe: Color(red: 0.961, green: 0.620, blue: 0.043),
                               badgeBackground: Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.10))
        case "red": Palette(stripe: Color(red: 0.937, green: 0.267, blue: 0.267),
                            badgeBackground: Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.10))
        default: Palette(stripe: Color(red: 0.051, green: 0.741, blue: 0.545),
                         badgeBackground: Color(red: 0.051, green: 0.741, blue: 0.545).opacity(0.10))
        }
    }

    private static let titleText = Color(red: 0.086, green: 0.196, blue: 0.306)
    private static let secondaryText = Color(red: 0.357, green: 0.455, blue: 0.533)
    private static let encryptedColor = Color(red: 0.051, green: 0.612, blue: 0.455)
    private static let mutedColor = Color(red: 0.682, green: 0.737, blue: 0.780)
    private static let guestColor = Color(red: 0.145, green: 0.388, blue: 0.922)
    private static let attachmentColor = Color(red: 0.494, green: 0.588, blue: 0.663)

    /// Формат веба: «30 июл. 2026 г., 14:00» либо «…, 14:00–15:00» (короткое тире).
    /// Спец-обработок нет намеренно — ни для перехода через полночь, ни для
    /// прошедших: так же, как в вебе, иначе клиенты разойдутся.
    static func formatWhen(_ meeting: Meeting) -> String {
        let date = dateFormatter.string(from: meeting.startTime)
        let start = timeFormatter.string(from: meeting.startTime)
        guard !meeting.isIndefinite else { return "\(date), \(start)" }
        let end = timeFormatter.string(from: meeting.endTime)
        return "\(date), \(start)\u{2013}\(end)"
    }

    private static func organiser(_ meeting: Meeting) -> String {
        meeting.participants.first { $0.userId == meeting.creatorId }?.displayName ?? meeting.creatorId
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
