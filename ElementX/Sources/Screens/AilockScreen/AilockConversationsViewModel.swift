//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias AilockConversationsViewModelType = StateStoreViewModel<AilockConversationsViewState, AilockConversationsViewAction>

protocol AilockConversationsViewModelProtocol {
    var actionsPublisher: AnyPublisher<AilockConversationsViewModelAction, Never> { get }
    var context: AilockConversationsViewModelType.Context { get }
}

/// История бесед с агентом: список, поиск, удаление.
///
/// STMOB-274. Пагинация у движка не курсорная — параметром `before` уходит ISO-метка
/// последнего элемента уже загруженного списка, а признак «есть ещё» = страница пришла полной.
class AilockConversationsViewModel: AilockConversationsViewModelType, AilockConversationsViewModelProtocol {
    private let service: AilockService
    private let agentID: String

    private let actionsSubject: PassthroughSubject<AilockConversationsViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AilockConversationsViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    private static let pageSize = 50

    init(service: AilockService, agentID: String) {
        self.service = service
        self.agentID = agentID

        super.init(initialViewState: AilockConversationsViewState())

        load()
    }

    override func process(viewAction: AilockConversationsViewAction) {
        switch viewAction {
        case .refresh:
            load()
        case .select(let conversation):
            actionsSubject.send(.selected(conversation))
        case .delete(let conversation):
            delete(conversation)
        case .loadMore:
            loadMore()
        case .search(let query):
            search(query)
        case .newConversation:
            actionsSubject.send(.newConversation)
        }
    }

    // MARK: - Загрузка

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            state.isLoading = state.conversations.isEmpty
            do {
                let conversations = try await service.conversations(agentID: agentID, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                state.conversations = conversations.sorted(by: Self.byDateDescending)
                state.hasMore = conversations.count >= Self.pageSize
                state.canDelete = service.capabilities.conversationsDelete
                state.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                state.isLoading = false
                if case .unavailable = (error as? AilockError) { return }
                state.errorMessage = (error as? LocalizedError)?.errorDescription ?? SL10n.ailockRequestFailed
                MXLog.error("sTalk Ailock: не удалось загрузить беседы: \(error)")
            }
        }
    }

    private func loadMore() {
        guard state.hasMore, !state.isLoadingMore, state.bindings.searchQuery.isEmpty else { return }
        guard let before = state.conversations.last?.sortDate else { return }

        state.isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            defer { state.isLoadingMore = false }
            do {
                let page = try await service.conversations(agentID: agentID, limit: Self.pageSize, before: before)
                guard !Task.isCancelled else { return }

                // Дедупликация по id: движок может вернуть пересечение по границе страницы.
                var known = Set(state.conversations.map(\.id))
                let fresh = page.filter { known.insert($0.id).inserted }
                state.conversations = (state.conversations + fresh).sorted(by: Self.byDateDescending)
                state.hasMore = page.count >= Self.pageSize && !fresh.isEmpty
            } catch {
                MXLog.error("sTalk Ailock: не удалось догрузить беседы: \(error)")
                state.hasMore = false
            }
        }
    }

    private func search(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            load()
            return
        }

        searchTask = Task { [weak self] in
            // Тот же дебаунс, что у веб-клиента.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                let results = try await service.searchConversations(query: trimmed, agentID: agentID)
                guard !Task.isCancelled else { return }
                state.conversations = results.sorted(by: Self.byDateDescending)
                state.hasMore = false
                state.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                MXLog.error("sTalk Ailock: поиск бесед не удался: \(error)")
            }
        }
    }

    private func delete(_ conversation: AilockConversation) {
        let previous = state.conversations
        state.conversations.removeAll { $0.id == conversation.id }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.deleteConversation(conversation.id)
            } catch {
                MXLog.error("sTalk Ailock: не удалось удалить беседу: \(error)")
                state.conversations = previous
                state.errorMessage = (error as? LocalizedError)?.errorDescription ?? SL10n.ailockRequestFailed
            }
        }
    }

    private static func byDateDescending(_ lhs: AilockConversation, _ rhs: AilockConversation) -> Bool {
        (lhs.sortDate ?? .distantPast) > (rhs.sortDate ?? .distantPast)
    }
}
