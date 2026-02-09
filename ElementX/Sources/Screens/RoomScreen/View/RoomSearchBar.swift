//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct RoomSearchBar: View {
    @Binding var searchQuery: String
    let resultCount: Int
    let currentIndex: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.compound.iconTertiary)
                .font(.system(size: 16))

            TextField(L10n.actionSearch, text: $searchQuery)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.compound.bodyMD)
                .submitLabel(.search)

            if !searchQuery.isEmpty {
                Text(resultCount > 0 ? "\(currentIndex + 1)/\(resultCount)" : "0/0")
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .monospacedDigit()

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(resultCount == 0)
                .foregroundColor(resultCount == 0 ? .compound.iconDisabled : .compound.iconPrimary)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(resultCount == 0)
                .foregroundColor(resultCount == 0 ? .compound.iconDisabled : .compound.iconPrimary)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.compound.iconTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.compound.bgCanvasDefault)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFocused = true }
    }
}
