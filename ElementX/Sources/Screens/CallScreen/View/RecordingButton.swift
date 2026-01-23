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
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 44, height: 44)

                if recordingState.isTransitioning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
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
            return .gray.opacity(0.6)
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
                .font(.caption.bold())
                .foregroundColor(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
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
            Image(systemName: "record.circle")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("Start Recording?")
                .font(.title2.bold())

            Text("This call will be recorded. All participants will be notified that the recording has started.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("Start Recording")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(12)
                }

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
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
        RecordingButton(recordingState: .recording(egressId: "test")) { }
        RecordingButton(recordingState: .stopping) { }
        RecordingIndicator()
    }
    .padding()
    .background(Color.black)
}
