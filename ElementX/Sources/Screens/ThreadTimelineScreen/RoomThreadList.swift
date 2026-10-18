// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import MatrixRustSDK
import SwiftUI

enum StalkThreadStrings {
    static var title: String {
        NSLocalizedString("stalk_threads_title", comment: "Room discussions")
    }

    static var empty: String {
        NSLocalizedString("stalk_threads_empty", comment: "Empty discussions")
    }

    static var unavailable: String {
        NSLocalizedString("stalk_threads_unavailable", comment: "Unavailable thread message")
    }
}

/// Keep the SDK's reactive list alive for the screen's lifetime. No plaintext REST fallback.
@MainActor
final class RoomThreadListModel: ObservableObject {
    @Published private(set) var items: [ThreadListItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var endReached = false
    private let service: ThreadListServiceProtocol
    private var observation: TaskHandle?
    private var listener: ThreadListObserver?

    init(service: ThreadListServiceProtocol) {
        self.service = service
        let listener = ThreadListObserver { [weak self] in self?.reloadSnapshot() }
        self.listener = listener
        observation = service.subscribeToItemsUpdates(listener: listener)
        reloadSnapshot()
    }

    deinit { observation?.cancel() }

    private func reloadSnapshot() {
        // A snapshot avoids applying a diff to an already-updated list after async hops.
        var seen = Set<String>()
        items = service.items().filter { seen.insert($0.rootEvent.eventId).inserted }
    }

    func loadMore() async {
        guard !isLoading, !endReached else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await service.paginate()
            guard !Task.isCancelled else { return }
            reloadSnapshot()
            if case .idle(let end) = service.paginationState() { endReached = end }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = L10n.commonSomethingWentWrong
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        await service.reset()
        endReached = false
        await loadMore()
    }

    static func preview(_ event: ThreadListItemEvent) -> String {
        guard case .msgLike(let content) = event.content else { return StalkThreadStrings.unavailable }
        switch content.kind {
        case .message(let message): return message.body
        case .sticker(let body, _, _): return body
        default: return StalkThreadStrings.unavailable
        }
    }

    static func sender(_ event: ThreadListItemEvent) -> String {
        if case .ready(let name, _, _) = event.senderProfile, let name, !name.isEmpty { return name }
        return event.sender
    }
}

private final class ThreadListObserver: ThreadListEntriesListener, @unchecked Sendable {
    private let update: @MainActor () -> Void
    init(update: @escaping @MainActor () -> Void) {
        self.update = update
    }

    func onUpdate(diff: [ThreadListUpdate]) {
        Task { @MainActor in update() }
    }
}

struct RoomThreadListView: View {
    @StateObject var model: RoomThreadListModel
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.items.isEmpty, !model.isLoading, model.error == nil {
                    Text(StalkThreadStrings.empty).foregroundStyle(.secondary)
                }
                ForEach(model.items, id: \.rootEvent.eventId) { item in
                    Button { select(item.rootEvent.eventId) } label: {
                        RoomThreadListRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.actionRetry) { Task { await model.loadMore() } }
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if !model.endReached {
                    Button(L10n.actionLoadMore) { Task { await model.loadMore() } }
                }
            }
            .navigationTitle(StalkThreadStrings.title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
            .refreshable { await model.refresh() }
            .task { await model.loadMore() }
        }
    }
}

final class RoomThreadListCoordinator: CoordinatorProtocol {
    private let model: RoomThreadListModel
    private let select: (String) -> Void
    init(service: ThreadListServiceProtocol, select: @escaping (String) -> Void) {
        model = RoomThreadListModel(service: service)
        self.select = select
    }

    func toPresentable() -> AnyView {
        let listModel = model
        return AnyView(RoomThreadListView(model: listModel, select: select))
    }
}

struct RoomThreadListRow: View {
    let item: ThreadListItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(RoomThreadListModel.sender(item.rootEvent)).font(.headline)
            Text(RoomThreadListModel.preview(item.rootEvent)).lineLimit(3)
            if let latest = item.latestEvent {
                Text(RoomThreadListModel.sender(latest) + ": " + RoomThreadListModel.preview(latest))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Label(String(item.numReplies), systemImage: "bubble.left.and.bubble.right")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel(String(format: NSLocalizedString("stalk_threads_reply_count", comment: "Thread reply count"), String(item.numReplies)))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
