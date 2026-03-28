//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Sheet showing call participants with their status (in call or not)
struct CallParticipantsSheet: View {
    let participants: [CallParticipantInfo]
    let activeParticipantIDs: Set<String>
    let mediaProvider: MediaProviderProtocol?

    private let stalkAccent = StalkTheme.accent

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(SL10n.meetingParticipants(activeInCall.count))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Active participants first
                    ForEach(activeInCall) { participant in
                        participantRow(participant, isActive: true)
                    }

                    // Others
                    if !notInCall.isEmpty {
                        HStack {
                            Text(SL10n.contactsOffline)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                        ForEach(notInCall) { participant in
                            participantRow(participant, isActive: false)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Filtered lists

    private var activeInCall: [CallParticipantInfo] {
        participants.filter { activeParticipantIDs.contains($0.userID) }
    }

    private var notInCall: [CallParticipantInfo] {
        participants.filter { !activeParticipantIDs.contains($0.userID) }
    }

    // MARK: - Row

    private func participantRow(_ participant: CallParticipantInfo, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            // Avatar
            avatar(for: participant)
                .frame(width: 40, height: 40)

            // Name
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName ?? participant.userID)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(participant.userID)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status
            if isActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(SL10n.contactsOnlineStatus)
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .opacity(isActive ? 1.0 : 0.5)
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatar(for participant: CallParticipantInfo) -> some View {
        let name = participant.displayName ?? participant.userID
        let initial = String(name.prefix(1)).uppercased()

        ZStack {
            Circle()
                .fill(avatarColor(for: name))

            Text(initial)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            stalkAccent,
            Color(red: 0.3, green: 0.7, blue: 0.4),
            Color(red: 0.9, green: 0.5, blue: 0.2),
            Color(red: 0.6, green: 0.3, blue: 0.8),
            Color(red: 0.2, green: 0.6, blue: 0.9),
            Color(red: 0.9, green: 0.3, blue: 0.4)
        ]
        var hash: UInt64 = 5381
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char.value)
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}
