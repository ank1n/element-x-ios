// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Shared multiline entry surface for Ailock and system search.
struct StalkComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    var isDisabled = false
    var showsClearButton = false
    var minimumHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
            if showsClearButton, !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SL10n.actionClear)
            }
        }
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        .disabled(isDisabled)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : AilockPalette.ice,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if colorScheme != .dark {
                RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AilockPalette.iceBorder, lineWidth: 1)
            }
        }
    }
}
