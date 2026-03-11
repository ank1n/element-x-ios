//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SentrySwiftUI
import SwiftUI

struct HomeScreenContent: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isArchiveRevealed = false
    @State private var areFiltersVisible = true
    @State private var lastScrollOffset: CGFloat = 0
    @AppStorage("stalk_design_theme") private var designTheme: String = "cosmos"

    @ObservedObject var context: HomeScreenViewModel.Context
    let scrollViewAdapter: ScrollViewAdapter

    private var isCosmos: Bool { designTheme == "cosmos" }

    // Cosmos colors
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)
    
    var body: some View {
        ZStack {
            if isCosmos {
                LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                // Filters outside ScrollView — hide on scroll up, show on pull down
                if context.viewState.shouldShowFilters, areFiltersVisible {
                    RoomListFiltersView(state: $context.filtersState)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                roomList
            }
            .animation(.easeInOut(duration: 0.25), value: areFiltersVisible)
        }
        .searchable(text: $context.searchQuery, isPresented: $context.isSearchFieldFocused, placement: .navigationBarDrawer(displayMode: .always))
        .compoundSearchField()
        .disableAutocorrection(true)
        .sentryTrace("\(Self.self)")
    }
    
    private var roomList: some View {
        GeometryReader { geometry in
            ScrollView {
                switch context.viewState.roomListMode {
                case .skeletons:
                    LazyVStack(spacing: 0) {
                        ForEach(context.viewState.visibleRooms) { room in
                            HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: context.mediaProvider, action: context.send)
                                .redacted(reason: .placeholder)
                                .shimmer() // Putting this directly on the LazyVStack creates an accordion animation on iOS 16.
                        }
                    }
                    .disabled(true)
                    .accessibilityRepresentation {
                        Text(L10n.commonLoading)
                    }
                case .empty:
                    HomeScreenEmptyStateLayout(minHeight: geometry.size.height) {
                        topSection

                        HomeScreenEmptyStateView(context: context)
                            .layoutPriority(1)
                    }
                case .rooms:
                    LazyVStack(spacing: 0) {
                        Section {
                            // Archive row — hidden by default, appears on pull-down (Telegram-style)
                            if context.viewState.archiveRoomCount > 0
                                && !context.viewState.bindings.isSearchFieldFocused
                                && isArchiveRevealed {
                                archiveRow
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if !context.viewState.shouldShowEmptyFilterState {
                                HomeScreenRoomList(context: context)
                            }
                        } header: {
                            topSection
                        }

                        // Space for StalkTabBar so last item isn't hidden
                        Spacer()
                            .frame(height: 70)
                    }
                }
            }
            .introspect(.scrollView, on: .supportedVersions) { scrollView in
                guard scrollView != scrollViewAdapter.scrollView else { return }
                scrollViewAdapter.scrollView = scrollView
            }
            .onReceive(scrollViewAdapter.didScroll) { _ in
                updateVisibleRange()
                checkOverscrollForArchive()
                trackScrollDirection()
            }
            .onReceive(scrollViewAdapter.isScrolling) { _ in
                updateVisibleRange()
            }
            .onChange(of: context.searchQuery) {
                updateVisibleRange()
            }
            .onChange(of: context.viewState.visibleRooms) {
                updateVisibleRange()

                // We have been seeing a lot of issues around the room list not updating properly after
                // rooms shifting around:
                // * Tapping on the room list doesn't always take you to the right room  - https://github.com/element-hq/element-x-ios/issues/2386
                // * Big blank gaps in the room list - https://github.com/element-hq/element-x-ios/issues/3026
                //
                // We initially thought it's caused by the filters header or the geometry reader but
                // the problem is still reproducible without those.
                //
                // As a last attempt we will manually force it to update by shifting the
                // inner scroll view by a point every time the room list is updated
                // Disabled: 1pt scroll hack causes visible jitter with cosmos card styling
                // DispatchQueue.main.async {
                //     guard !scrollViewAdapter.isScrolling.value, let scrollView = scrollViewAdapter.scrollView else {
                //         return
                //     }
                //     let oldOffset = scrollView.contentOffset
                //     var newOffset = scrollView.contentOffset
                //     newOffset.y += 1
                //     scrollView.setContentOffset(newOffset, animated: false)
                //     scrollView.setContentOffset(oldOffset, animated: false)
                // }
            }
            .background {
                Button("") {
                    context.send(viewAction: .globalSearch)
                }
                .keyboardShortcut(KeyEquivalent("k"), modifiers: [.command])
            }
            .overlay {
                if context.viewState.shouldShowEmptyFilterState {
                    RoomListFiltersEmptyStateView(state: context.filtersState)
                        .background(isCosmos ? Color.clear : .compound.bgCanvasDefault)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if context.viewState.shouldHideRoomList, !context.viewState.recentSearchQueries.isEmpty {
                    recentSearchesView
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(isCosmos ? Color.clear : .compound.bgCanvasDefault)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollDisabled(context.viewState.roomListMode == .skeletons)
            .scrollBounceBehavior(context.viewState.roomListMode == .empty ? .basedOnSize : .automatic)
            .animation(.elementDefault, value: context.viewState.roomListMode)
            .animation(.none, value: context.viewState.visibleRooms)
            .onChange(of: context.viewState.roomListMode) { _, newMode in
                if newMode != .rooms {
                    isArchiveRevealed = false
                }
            }
        }
    }
    
    @ViewBuilder
    private var topSection: some View {
        VStack(spacing: 0) {
            if case let .show(state) = context.viewState.securityBannerMode {
                HomeScreenRecoveryKeyConfirmationBanner(state: state, context: context)
            } else if context.viewState.shouldShowNewSoundBanner {
                HomeScreenNewSoundBanner { context.send(viewAction: .dismissNewSoundBanner) }
            }
        }
        .background(isCosmos ? Color.clear : Color.compound.bgCanvasDefault)
    }
    
    // MARK: - Archive Row

    private var archiveRow: some View {
        Button {
            context.send(viewAction: .openArchive)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Архив")
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)

                    if !context.viewState.archivePreviewText.isEmpty {
                        Text(context.viewState.archivePreviewText)
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCosmos ? 8 : 12)
            .background(isCosmos ? Color(UIColor.systemBackground) : Color.compound.bgCanvasDefault)
            .cornerRadius(isCosmos ? 12 : 0)
            .shadow(color: isCosmos ? .black.opacity(0.03) : .clear, radius: 2, y: 1)
            .padding(.horizontal, isCosmos ? 8 : 0)
            .padding(.vertical, isCosmos ? 2 : 0)
        }
    }

    // MARK: - Recent Searches

    private var recentSearchesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Недавние")
                    .font(.compound.bodySMSemibold)
                    .foregroundColor(.compound.textSecondary)
                Spacer()
                Button {
                    context.send(viewAction: .clearRecentSearches)
                } label: {
                    Text("Очистить")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textActionAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(context.viewState.recentSearchQueries, id: \.self) { query in
                Button {
                    context.send(viewAction: .selectRecentSearch(query: query))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16))
                            .foregroundColor(.compound.iconSecondary)
                        Text(query)
                            .font(.compound.bodyLG)
                            .foregroundColor(.compound.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// Detects pull-down overscroll to reveal / scroll-up to hide the archive row (Telegram-style)
    private func trackScrollDirection() {
        guard let scrollView = scrollViewAdapter.scrollView else { return }
        let currentOffset = scrollView.contentOffset.y
        let delta = currentOffset - lastScrollOffset

        // Detect bounce zones
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
        let isInBottomBounce = currentOffset > maxOffset - 10

        // In bottom bounce: don't hide filters (prevents layout feedback loop)
        // But still allow showing them when scrolling back up
        if isInBottomBounce {
            lastScrollOffset = currentOffset
            return
        }

        // Threshold to avoid jitter
        if delta > 8, currentOffset > 50 {
            // Scrolling up (content moving up) → hide filters
            areFiltersVisible = false
        } else if delta < -8 {
            // Scrolling down (pulling down) → show filters
            areFiltersVisible = true
        }

        lastScrollOffset = currentOffset
    }

    private func checkOverscrollForArchive() {
        guard context.viewState.archiveRoomCount > 0,
              context.viewState.roomListMode == .rooms,
              let scrollView = scrollViewAdapter.scrollView else { return }
        let topInset = scrollView.adjustedContentInset.top
        let offset = scrollView.contentOffset.y + topInset

        if !isArchiveRevealed {
            // Pull down past 60pt → reveal archive
            if offset < -60 {
                withAnimation(.easeOut(duration: 0.25)) {
                    isArchiveRevealed = true
                }
            }
        } else {
            // Scrolled up past archive row height (76pt) → hide it
            if offset > 80 {
                // Compensate content shift so visible rooms don't jump
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y - 76),
                    animated: false
                )
                withAnimation(.easeOut(duration: 0.25)) {
                    isArchiveRevealed = false
                }
            }
        }
    }

    /// Often times the scroll view's content size isn't correct yet when this method is called e.g. when cancelling a search
    /// Dispatch it with a delay to allow the UI to update and the computations to be correct
    /// Once we move to iOS 17 we should remove all of this and use scroll anchors instead
    private func updateVisibleRange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delayedUpdateVisibleRange() }
    }
    
    private func delayedUpdateVisibleRange() {
        guard let scrollView = scrollViewAdapter.scrollView,
              scrollViewAdapter.isScrolling.value == false, // Ignore while scrolling
              context.searchQuery.isEmpty == true, // Ignore while filtering
              context.viewState.visibleRooms.count > 0 else {
            return
        }
        
        guard scrollView.contentSize.height > scrollView.bounds.height else {
            return
        }
        
        let adjustedContentSize = max(scrollView.contentSize.height - scrollView.contentInset.top - scrollView.contentInset.bottom, scrollView.bounds.height)
        let cellHeight = adjustedContentSize / Double(context.viewState.visibleRooms.count)
        
        let firstIndex = Int(max(0.0, scrollView.contentOffset.y + scrollView.contentInset.top) / cellHeight)
        let lastIndex = Int(max(0.0, scrollView.contentOffset.y + scrollView.bounds.height) / cellHeight)
        
        // This will be deduped and throttled on the view model layer
        context.send(viewAction: .updateVisibleItemRange(firstIndex..<lastIndex))
    }
}
