// Copyright 2025 Element Creations Ltd., New Vector Ltd.
// Copyright 2026 ООО «Имплика».
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
import SwiftUI

/// STALK-1144: the four conversation types, one horizontal row, no hidden filters.
struct RoomListFiltersView: View {
    @Binding var state: RoomListFiltersState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomListFilter.primaryDisplayOrder) { filter in chip(filter) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ filter: RoomListFilter) -> some View {
        let selected = state.isFilterActive(filter)
        return Button {
            state.clearFilters()
            if !selected { state.activateFilter(filter) }
        } label: {
            Text(filter.localizedName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.primary : Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("room_filter_\(filter.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Previews

struct RoomListFiltersView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        RoomListFiltersView(state: .constant(.init(appSettings: ServiceLocator.shared.settings)))
        RoomListFiltersView(state: .constant(.init(activeFilters: [.rooms],
                                                   appSettings: ServiceLocator.shared.settings)))
        RoomListFiltersView(state: .constant(.init(activeFilters: [.meetings],
                                                   appSettings: ServiceLocator.shared.settings)))
    }
}
