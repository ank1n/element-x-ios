//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

// MARK: - Top Search Bar (Cosmos Style)

struct RoomSearchBar: View {
    @Binding var searchQuery: String
    let resultCount: Int
    let currentIndex: Int
    var isLoading: Bool = false
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    private let accent = StalkTheme.accent

    var body: some View {
        HStack(spacing: 8) {
            // Search capsule
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(accent)

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
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(accent.opacity(0.08))
                    .overlay(
                        Capsule()
                            .stroke(accent.opacity(0.2), lineWidth: 1)
                    )
            )

            // Close button (icon, no text)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.systemGray6))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFocused = true }
    }
}

// MARK: - Bottom Navigation Bar (Cosmos Style)

struct RoomSearchNavigationBar: View {
    let resultCount: Int
    let currentIndex: Int
    var isLoading: Bool = false
    let onPrevious: () -> Void
    let onNext: () -> Void

    private let accent = StalkTheme.accent

    var body: some View {
        HStack(spacing: 0) {
            // Left: badge counter
            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.trailing, 8)
            }

            // Counter badge
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))

                if resultCount > 0 {
                    Text("\(currentIndex + 1)/\(resultCount)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                } else {
                    Text("0")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(accent)
            )

            Spacer()

            // Right: navigation arrows in circles
            HStack(spacing: 10) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(resultCount > 0 ? accent : .secondary.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(resultCount > 0 ? accent.opacity(0.1) : Color(UIColor.systemGray6))
                        )
                }
                .disabled(resultCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(resultCount > 0 ? accent : .secondary.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(resultCount > 0 ? accent.opacity(0.1) : Color(UIColor.systemGray6))
                        )
                }
                .disabled(resultCount == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
