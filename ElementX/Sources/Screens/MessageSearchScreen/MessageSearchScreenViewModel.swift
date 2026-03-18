//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias MessageSearchScreenViewModelType = StateStoreViewModel<MessageSearchScreenViewState, MessageSearchScreenViewAction>

class MessageSearchScreenViewModel: MessageSearchScreenViewModelType {
    private let searchService: MessageSearchService
    private let roomSummaryProvider: RoomSummaryProviderProtocol?
    private var searchCancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var nextBatch: String?

    private let actionsSubject: PassthroughSubject<MessageSearchScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<MessageSearchScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(searchService: MessageSearchService, roomSummaryProvider: RoomSummaryProviderProtocol?) {
        self.searchService = searchService
        self.roomSummaryProvider = roomSummaryProvider
        super.init(initialViewState: MessageSearchScreenViewState())

        setupSearchSubscription()
    }

    override func process(viewAction: MessageSearchScreenViewAction) {
        switch viewAction {
        case .search:
            performSearch(append: false)
        case .loadMore:
            performSearch(append: true)
        case .selectResult(let roomID, let eventID):
            actionsSubject.send(.openRoomAtEvent(roomID: roomID, eventID: eventID))
        case .dismiss:
            actionsSubject.send(.dismiss)
        }
    }

    private func setupSearchSubscription() {
        context.$viewState
            .map(\.bindings.searchQuery)
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performSearch(append: false)
            }
            .store(in: &searchCancellables)
    }

    private func performSearch(append: Bool) {
        searchTask?.cancel()

        let query = state.bindings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state.results = []
            state.totalCount = 0
            state.hasMore = false
            state.isLoading = false
            return
        }

        if !append {
            nextBatch = nil
        }

        state.isLoading = true

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.searchService.searchMessages(
                    query: query,
                    nextBatch: self.nextBatch
                )

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    let newResults = response.results.map { result in
                        MessageSearchScreenResult(
                            eventID: result.eventID,
                            roomID: result.roomID,
                            roomName: self.roomName(for: result.roomID),
                            senderName: result.senderDisplayName,
                            body: result.body,
                            timestamp: result.timestamp
                        )
                    }

                    if append {
                        self.state.results.append(contentsOf: newResults)
                    } else {
                        self.state.results = newResults
                    }

                    self.state.totalCount = response.totalCount
                    self.state.hasMore = response.nextBatch != nil
                    self.nextBatch = response.nextBatch
                    self.state.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.state.isLoading = false
                    MXLog.error("sTalk: Message search failed: \(error)")
                }
            }
        }
    }

    private func roomName(for roomID: String) -> String? {
        // Try to get room name from summary provider
        nil // Will be resolved from room list
    }
}
