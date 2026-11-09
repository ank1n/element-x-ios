// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct CallReceiveVideoToggle: View {
    @ObservedObject var reception: CallCameraReception
    let setEnabled: (Bool) -> Void
    var body: some View {
        Toggle(isOn: Binding(get: { reception.isEnabled }, set: setEnabled)) {
            Label(NSLocalizedString("stalk_call_receive_video", comment: "Receive participant cameras"), systemImage: "video")
        }
        .accessibilityHint(NSLocalizedString("stalk_call_receive_video_hint", comment: "Audio and screen sharing continue"))
        .accessibilityIdentifier("callReceiveVideoToggle")
    }
}

struct CallIncomingVideoNotice: View {
    @ObservedObject var reception: CallCameraReception
    var body: some View {
        if reception.status != .enabled {
            HStack(spacing: 12) {
                if reception.status == .updating { ProgressView().tint(.white) }
                Text(NSLocalizedString(messageKey, comment: "Incoming participant video status"))
                    .font(.footnote).foregroundStyle(.white)
                Spacer(minLength: 0)
                if reception.status != .updating {
                    Button {
                        if reception.status == .failed { reception.retry() }
                        else { reception.setEnabled(true) }
                    } label: {
                        Text(NSLocalizedString(reception.status == .failed ? "stalk_call_receive_video_retry" : "stalk_call_receive_video_enable", comment: "Restore incoming cameras"))
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .accessibilityIdentifier("callRestoreVideoReception")
                }
            }
            .padding(12).background(.black.opacity(0.8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("callIncomingVideoStatus")
        }
    }

    private var messageKey: String {
        switch reception.status {
        case .enabled: "stalk_call_receive_video"
        case .disabled: "stalk_call_receive_video_disabled"
        case .updating: reception.isEnabled ? "stalk_call_receive_video_enabling" : "stalk_call_receive_video_disabling"
        case .failed: reception.isEnabled ? "stalk_call_receive_video_enable_failed" : "stalk_call_receive_video_disable_failed"
        }
    }
}
