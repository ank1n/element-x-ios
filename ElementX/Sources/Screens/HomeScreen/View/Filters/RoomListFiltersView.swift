//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct RoomListFiltersView: View {
    let leadingID = "leading"
    @Binding var state: RoomListFiltersState
    @Namespace private var namespace
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    /// When you connect a mouse on macOS the scrollbars aren't hidden. This is some extra padding
    /// applied to the scroll view content to make sure the bars don't overlap the filters.
    private var macScrollBarPadding: CGFloat {
        ProcessInfo.processInfo.isiOSAppOnMac ? 16 : 0
    }

    /// All filters in stable order (enum declaration order, never reorders)
    /// In Cosmos: hide invites and lowPriority — not part of our design
    private var allFilters: [RoomListFilter] {
        let all = RoomListFilter.allCases.filter { state.activeFilters.contains($0) || state.availableFilters.contains($0) }
        if isCosmos {
            return all.filter { $0 != .invites && $0 != .lowPriority }
        }
        return all
    }

    var body: some View {
        if isCosmos {
            cosmosBody
        } else {
            classicBody
        }
    }

    // MARK: - Cosmos (capsules, no reorder, no X button)

    private var cosmosBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allFilters) { filter in
                    RoomListFilterView(filter: filter,
                                       isActive: cosmosBinding(for: filter))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    /// In Cosmos: tapping an active filter deactivates it (back to "all"),
    /// tapping an inactive one activates it exclusively (single-select).
    private func cosmosBinding(for filter: RoomListFilter) -> Binding<Bool> {
        Binding<Bool>(get: {
            state.isFilterActive(filter)
        }, set: { isEnabled, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                if isEnabled {
                    // Clear others first, then activate this one
                    state.clearFilters()
                    state.activateFilter(filter)
                } else {
                    state.deactivateFilter(filter)
                }
            }
        })
    }

    // MARK: - Classic (original behavior with reorder + X button)

    private var classicBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: 0, height: 0)
                        .id(leadingID)

                    HStack(spacing: 0) {
                        if state.isFiltering {
                            clearButton(scrollViewProxy: proxy)
                        }

                        ForEach(state.activeFilters) { filter in
                            RoomListFilterView(filter: filter,
                                               isActive: getBinding(for: filter, scrollViewProxy: proxy))
                                .matchedGeometryEffect(id: filter.id, in: namespace)
                                .zIndex(1)
                        }
                        ForEach(state.availableFilters) { filter in
                            RoomListFilterView(filter: filter,
                                               isActive: getBinding(for: filter, scrollViewProxy: proxy))
                                .matchedGeometryEffect(id: filter.id, in: namespace)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, macScrollBarPadding)
                }
            }
            .scrollIndicators(.hidden)
            .padding(.vertical, 4)
            .padding(.bottom, -macScrollBarPadding)
        }
    }
    
    private func clearButton(scrollViewProxy: ScrollViewProxy) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2).disabledDuringTests()) {
                state.clearFilters()
                scrollViewProxy.scrollTo(leadingID, anchor: .leading)
            }
        }, label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.compound.bgActionPrimaryRest)
        })
        .accessibilityLabel(L10n.screenRoomlistClearFilters)
    }
    
    private func getBinding(for filter: RoomListFilter, scrollViewProxy: ScrollViewProxy) -> Binding<Bool> {
        Binding<Bool>(get: {
            state.isFilterActive(filter)
        }, set: { isEnabled, _ in
            withAnimation(.easeInOut(duration: 0.2).disabledDuringTests()) {
                if isEnabled {
                    state.activateFilter(filter)
                    scrollViewProxy.scrollTo(leadingID, anchor: .leading)
                } else {
                    state.deactivateFilter(filter)
                }
            }
        })
    }
}

// MARK: - Previews

struct RoomListFiltersView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        RoomListFiltersView(state: .constant(.init(appSettings: ServiceLocator.shared.settings)))
        RoomListFiltersView(state: .constant(.init(activeFilters: [.rooms, .favourites],
                                                   appSettings: ServiceLocator.shared.settings)))
        RoomListFiltersView(state: .constant(.init(activeFilters: [.lowPriority],
                                                   appSettings: ServiceLocator.shared.settings)))
    }
}
