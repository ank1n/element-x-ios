//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum CallHistoryScreenViewModelAction {
    case playRecording(CallRecordingItem)
}

struct CallHistoryScreenViewState: BindableState {
    var recordings: [CallRecordingItem] = []
    var filteredRecordings: [CallRecordingItem] = []
    var selectedFilter: CallHistoryFilter = .all
    var searchQuery: String = ""
    var isLoading: Bool = false
    var bindings: CallHistoryScreenViewStateBindings

    var hasRecordings: Bool {
        !recordings.isEmpty
    }
}

struct CallHistoryScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
}

enum CallHistoryScreenViewAction {
    case appeared
    case refresh
    case selectFilter(CallHistoryFilter)
    case search(String)
    case playRecording(CallRecordingItem)
}
