//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

typealias CallHistoryScreenViewModelType = StateStoreViewModel<CallHistoryScreenViewState, CallHistoryScreenViewAction>

class CallHistoryScreenViewModel: CallHistoryScreenViewModelType, CallHistoryScreenViewModelProtocol {
    private let callHistoryService: CallHistoryServiceProtocol

    private let actionsSubject: PassthroughSubject<CallHistoryScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallHistoryScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(callHistoryService: CallHistoryServiceProtocol) {
        self.callHistoryService = callHistoryService

        super.init(initialViewState: CallHistoryScreenViewState(
            bindings: .init()
        ))
    }

    override func process(viewAction: CallHistoryScreenViewAction) {
        switch viewAction {
        case .appeared:
            Task { await loadRecordings() }
        case .refresh:
            Task { await loadRecordings() }
        case .selectFilter(let filter):
            state.selectedFilter = filter
            applyFilters()
        case .search(let query):
            state.searchQuery = query
            applyFilters()
        case .playRecording(let recording):
            actionsSubject.send(.playRecording(recording))
        }
    }

    // MARK: - Private

    private func loadRecordings() async {
        state.isLoading = true

        do {
            let recordings = try await callHistoryService.fetchRecordings()
            state.recordings = recordings
            applyFilters()
        } catch {
            MXLog.error("Failed to load recordings: \(error)")
            state.bindings.alertInfo = .init(
                id: UUID(),
                title: "Error",
                message: error.localizedDescription
            )
        }

        state.isLoading = false
    }

    private func applyFilters() {
        var filtered = state.recordings

        // Apply filter
        switch state.selectedFilter {
        case .all:
            break
        case .recorded:
            filtered = filtered.filter { $0.isCompleted }
        case .missed:
            // For now, show all. In future, could integrate with call events
            break
        }

        // Apply search
        if !state.searchQuery.isEmpty {
            filtered = filtered.filter {
                $0.roomName.localizedCaseInsensitiveContains(state.searchQuery)
            }
        }

        state.filteredRecordings = filtered
    }
}
