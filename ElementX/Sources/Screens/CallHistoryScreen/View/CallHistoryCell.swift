//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct CallHistoryCell: View {
    let recording: CallRecordingItem
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Room name and date
            HStack {
                Text(recording.roomName)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Text(recording.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Call info: direction and duration
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Outgoing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary)

                Text(recording.formattedDuration)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Recording status and playback button
            if recording.isCompleted {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)

                    Text(recording.formattedDuration)
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.primary)

                    Spacer()

                    Button(action: onPlay) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Запись")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.orange)
                        .font(.caption)

                    Text(recording.status.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        CallHistoryCell(
            recording: CallRecordingItem(
                id: "test-1",
                roomId: "!abc:server.com",
                roomName: "Анкин",
                startedAt: Date().addingTimeInterval(-7200),
                endedAt: Date().addingTimeInterval(-7065),
                status: .complete,
                filepath: "recordings/test.mp4"
            ),
            onPlay: {}
        )

        CallHistoryCell(
            recording: CallRecordingItem(
                id: "test-2",
                roomId: "!def:server.com",
                roomName: "Дмитрий",
                startedAt: Date().addingTimeInterval(-3600),
                endedAt: Date().addingTimeInterval(-3120),
                status: .complete,
                filepath: "recordings/test2.mp4"
            ),
            onPlay: {}
        )

        CallHistoryCell(
            recording: CallRecordingItem(
                id: "test-3",
                roomId: "!ghi:server.com",
                roomName: "Meeting Room",
                startedAt: Date().addingTimeInterval(-1800),
                endedAt: nil,
                status: .failed,
                filepath: nil
            ),
            onPlay: {}
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
