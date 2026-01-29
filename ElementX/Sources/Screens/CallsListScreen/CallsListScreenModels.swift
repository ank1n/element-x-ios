//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum CallsListScreenViewAction {
    case showSettings
    case selectCall(CallHistoryItem)
    case startNewCall
    case playRecording(CallHistoryItem)
}

enum CallsListScreenViewModelAction {
    case showSettings
    case startCall(userId: String)
}

struct CallsListScreenViewState: BindableState {
    var callHistory: [CallHistoryItem] = []
    var isLoading: Bool = false
    var searchQuery = ""

    // User info for avatar
    var userID: String = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    // Audio playback state
    var playingCallId: String?
    var playbackState: MediaPlayerState = .stopped
    var playbackProgress: Double = 0

    var bindings = CallsListScreenViewStateBindings()
}

struct CallsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Call history item
struct CallHistoryItem: Identifiable, Equatable {
    let id: String
    let contactName: String
    let contactId: String
    let callType: CallType
    let timestamp: Date
    let duration: TimeInterval?
    let isMissed: Bool
    let recordingURL: URL?

    var hasRecording: Bool {
        recordingURL != nil
    }

    enum CallType: String {
        case incoming
        case outgoing
        case video
    }
}
