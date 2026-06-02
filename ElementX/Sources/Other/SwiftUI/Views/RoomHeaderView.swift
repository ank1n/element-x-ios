//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI

struct RoomHeaderView: View {
    let roomName: String
    var roomSubtitle: String?
    let roomAvatar: RoomAvatar
    var dmRecipientVerificationState: UserIdentityVerificationState?
    /// STMOB-103 build 122: presence DM-собеседника. Telegram-style — точка
    /// на avatar + subtitle "в сети"/"был в сети X назад" под именем.
    var dmRecipientPresence: UserPresence?

    let mediaProvider: MediaProviderProtocol?

    let action: () -> Void
    
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                // On iOS 26+ we use the toolbarRole(.editor) to leading align.
                content
            }
            .backportButtonStyleGlass()
        } else {
            // On iOS 18 and lower, the editor role causes an animation glitch with the back button whenever
            // you push a screen whilst the large title is visible on the room screen.
            content
                // So take up as much space as possible, with a leading alignment for use in the default principal toolbar position.
                // STMOB-190/STALK-358: idealWidth must stay FINITE. `.greatestFiniteMagnitude` overflowed to
                // NaN/∞ inside _UITAMICAdaptorView → NSLayoutConstraint.setConstant assertion → SIGABRT on iOS ≤18
                // when the principal nav-bar title laid out (crash on re-entry restoring the last room).
                .frame(maxWidth: .infinity, alignment: .leading)
                // Using a button stops it from getting truncated in the navigation bar
                .contentShape(.rect)
                .onTapGesture(perform: action)
        }
    }
    
    private var content: some View {
        HStack(spacing: 8) {
            avatarImage
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(roomName)
                        .lineLimit(1)
                        .font(.compound.bodyLGSemibold)
                        .accessibilityIdentifier(A11yIdentifiers.roomScreen.name)
                    // Build 122: presence subtitle для DM имеет приоритет над roomSubtitle.
                    if let presenceSubtitleText {
                        Text(presenceSubtitleText)
                            .lineLimit(1)
                            .font(.compound.bodyXS)
                            .foregroundStyle(presenceSubtitleColor)
                    } else if let roomSubtitle {
                        Text(roomSubtitle)
                            .lineLimit(1)
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                    }
                }

                if let dmRecipientVerificationState {
                    VerificationBadge(verificationState: dmRecipientVerificationState)
                }
            }
        }
    }

    private var avatarImage: some View {
        RoomAvatarImage(avatar: roomAvatar,
                        avatarSize: .room(on: .timeline),
                        mediaProvider: mediaProvider)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.avatar)
            // Build 122: зелёная/жёлтая/серая точка на avatar для DM
            .overlay(alignment: .bottomTrailing) {
                if let presence = dmRecipientPresence {
                    Circle()
                        .fill(Self.presenceColor(presence))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                }
            }
    }

    private var presenceSubtitleText: String? {
        guard let presence = dmRecipientPresence else { return nil }
        if presence.isOnline { return NSLocalizedString("stalk_presence_online_lower", tableName: "Localizable", value: "в сети", comment: "Presence subtitle: online (lowercase)") }
        if let last = presence.lastSeenDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.locale = Locale(identifier: "ru_RU")
            return String(format: NSLocalizedString("stalk_presence_last_seen_lower", tableName: "Localizable", value: "был в сети %@", comment: "Presence subtitle: last seen <relative time> (lowercase)"), formatter.localizedString(for: last, relativeTo: Date()))
        }
        return NSLocalizedString("stalk_presence_offline_lower", tableName: "Localizable", value: "не в сети", comment: "Presence subtitle: offline (lowercase)")
    }

    private var presenceSubtitleColor: Color {
        guard let presence = dmRecipientPresence, presence.isOnline else {
            return .compound.textSecondary
        }
        return Color(red: 0.18, green: 0.8, blue: 0.44)
    }

    static func presenceColor(_ presence: UserPresence) -> Color {
        if presence.isOnline { return Color(red: 0.18, green: 0.8, blue: 0.44) }
        // Build 125: lastSeen < 1 час → жёлтый (idle), иначе серый
        if let last = presence.lastSeenDate, Date().timeIntervalSince(last) < 3600 {
            return Color(red: 0.95, green: 0.7, blue: 0.18)
        }
        return Color(red: 0.55, green: 0.6, blue: 0.65)
    }
}

extension RoomHeaderView {
    static var toolbarRole: ToolbarRole {
        if #available(iOS 26.0, *) {
            .editor
        } else {
            .automatic
        }
    }
}

struct RoomHeaderView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 8) {
            makeHeader(avatarURL: nil, verificationState: .notVerified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .notVerified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .verified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .verificationViolation)
            makeHeader(avatarURL: .mockMXCAvatar,
                       roomSubtitle: "Subtitle",
                       verificationState: .verified)
        }
        .previewLayout(.sizeThatFits)
    }
    
    static func makeHeader(avatarURL: URL?,
                           roomSubtitle: String? = nil,
                           verificationState: UserIdentityVerificationState) -> some View {
        RoomHeaderView(roomName: "Some Room name",
                       roomSubtitle: roomSubtitle,
                       roomAvatar: .room(id: "1",
                                         name: "Some Room Name",
                                         avatarURL: avatarURL),
                       dmRecipientVerificationState: verificationState,
                       mediaProvider: MediaProviderMock(configuration: .init())) { }
            .padding()
    }
}
