//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct RecordingButton: View {
    let recordingState: RecordingState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background circle — Telegram style
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 36, height: 36)

                if recordingState.isTransitioning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: iconColor))
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }
            }
        }
        .disabled(recordingState.isTransitioning)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        recordingState.isRecording ? "stop.fill" : "record.circle"
    }

    private var backgroundColor: Color {
        switch recordingState {
        case .recording:
            return .red
        case .error:
            return .orange
        default:
            return .white.opacity(0.15)
        }
    }

    private var iconColor: Color {
        switch recordingState {
        case .recording, .error:
            return .white
        default:
            return .white
        }
    }

    private var accessibilityLabel: String {
        switch recordingState {
        case .idle:
            return "Start recording"
        case .starting:
            return "Starting recording"
        case .recording:
            return "Stop recording"
        case .stopping:
            return "Stopping recording"
        case .error:
            return "Recording error"
        }
    }
}

// MARK: - Recording Indicator

struct RecordingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isAnimating ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)

            Text("REC")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.85))
        .clipShape(Capsule())
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Recording Consent Sheet

struct RecordingConsentView: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Red circle icon
            ZStack {
                Circle()
                    .strokeBorder(Color.red, lineWidth: 3)
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(Color.red)
                    .frame(width: 20, height: 20)
            }

            Text("Начать запись?")
                .font(.title2.bold())

            Text("Звонок будет записан. Все участники будут уведомлены о начале записи.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("Начать запись")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(12)
                }

                Button(action: onCancel) {
                    Text("Отмена")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 32)
    }
}

#Preview {
    VStack(spacing: 20) {
        RecordingButton(recordingState: .idle) { }
        RecordingButton(recordingState: .starting) { }
        RecordingButton(recordingState: .recording(egressId: "test", duration: 65)) { }
        RecordingButton(recordingState: .stopping) { }
        RecordingIndicator()
    }
    .padding()
    .background(Color.black)
}
