//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct MessageSearchScreen: View {
    @ObservedObject var context: MessageSearchScreenViewModelType.Context

    private let stalkAccent = StalkTheme.accent

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if context.viewState.results.isEmpty && !context.viewState.isLoading && !context.viewState.bindings.searchQuery.isEmpty {
                emptyState
            } else if context.viewState.results.isEmpty && context.viewState.bindings.searchQuery.isEmpty {
                promptState
            } else {
                resultsList
            }
        }
        .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        .compoundSearchField()
        .disableAutocorrection(true)
        .navigationTitle(SL10n.callsSearch)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(context.viewState.results) { result in
                    resultRow(result)
                }

                if context.viewState.isLoading {
                    ProgressView()
                        .padding(20)
                }

                if context.viewState.hasMore && !context.viewState.isLoading {
                    Button {
                        context.send(viewAction: .loadMore)
                    } label: {
                        Text(SL10n.appsLoading)
                            .font(.system(size: 14))
                            .foregroundColor(stalkAccent)
                            .padding(12)
                    }
                }
            }
            .padding(.bottom, 80)
        }
    }

    private func resultRow(_ result: MessageSearchScreenResult) -> some View {
        Button {
            context.send(viewAction: .selectResult(roomID: result.roomID, eventID: result.eventID))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    // Room name
                    if let roomName = result.roomName {
                        Text(roomName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(stalkAccent)
                    }

                    Spacer()

                    // Date
                    Text(dateFormatter.string(from: result.timestamp))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                // Sender
                Text(result.senderName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // Message body with highlighted search term
                highlightedText(result.body, query: context.viewState.bindings.searchQuery)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Divider().padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Highlighted Text

    private func highlightedText(_ text: String, query: String) -> Text {
        guard !query.isEmpty else { return Text(text) }

        let lowercaseText = text.lowercased()
        let lowercaseQuery = query.lowercased()

        guard let range = lowercaseText.range(of: lowercaseQuery) else {
            return Text(text)
        }

        let before = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let after = String(text[range.upperBound..<text.endIndex])

        return Text(before) + Text(match).bold().foregroundColor(.primary) + Text(after)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text(SL10n.searchNoResults)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var promptState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.3))
            Spacer()
        }
    }
}
