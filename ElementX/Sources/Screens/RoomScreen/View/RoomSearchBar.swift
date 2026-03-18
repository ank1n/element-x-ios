//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Telegram-style search bar: input at top, navigation at bottom
struct RoomSearchBar: View {
    @Binding var searchQuery: String
    let resultCount: Int
    let currentIndex: Int
    var isLoading: Bool = false
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        // Top: search input
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 16))

            TextField(L10n.actionSearch, text: $searchQuery)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .submitLabel(.search)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
            }

            Button(action: onDismiss) {
                Text(SL10n.actionCancel)
                    .font(.system(size: 16))
                    .foregroundColor(StalkTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFocused = true }
    }
}

/// Bottom navigation bar for search results (Telegram-style)
struct RoomSearchNavigationBar: View {
    let resultCount: Int
    let currentIndex: Int
    var isLoading: Bool = false
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left: icon + counter
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                if resultCount > 0 {
                    Text("\(currentIndex + 1) из \(resultCount)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                } else if !isLoading {
                    Text("0 из 0")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Right: navigation arrows
            HStack(spacing: 16) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(resultCount > 0 ? StalkTheme.accent : .secondary.opacity(0.4))
                }
                .disabled(resultCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(resultCount > 0 ? StalkTheme.accent : .secondary.opacity(0.4))
                }
                .disabled(resultCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
