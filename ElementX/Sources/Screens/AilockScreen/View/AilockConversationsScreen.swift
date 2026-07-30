//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// История бесед с агентом: поиск, переключение, удаление.
struct AilockConversationsScreen: View {
    @ObservedObject var context: AilockConversationsViewModelType.Context

    var body: some View {
        List {
            if context.viewState.conversations.isEmpty, !context.viewState.isLoading {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(context.viewState.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { conversation in
                        row(conversation)
                    }
                }
            }

            if context.viewState.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .onAppear { context.send(viewAction: .loadMore) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(SL10n.ailockHistoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $context.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: SL10n.ailockSearchPlaceholder)
        .onChange(of: context.searchQuery) { _, query in
            context.send(viewAction: .search(query))
        }
        .refreshable {
            context.send(viewAction: .refresh)
        }
        .overlay {
            if context.viewState.isLoading {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    context.send(viewAction: .newConversation)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }

    private func row(_ conversation: AilockConversation) -> some View {
        Button {
            context.send(viewAction: .select(conversation))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let date = conversation.sortDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if context.viewState.canDelete {
                Button(role: .destructive) {
                    context.send(viewAction: .delete(conversation))
                } label: {
                    Label(SL10n.ailockDelete, systemImage: "trash")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(SL10n.ailockHistoryEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
