//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

// MARK: - Swipe Action (used by ContactsListScreen)

struct SwipeAction {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

struct SwipeActionView<Content: View>: View {
    let leadingActions: [SwipeAction]
    let trailingActions: [SwipeAction]
    let cornerRadius: CGFloat
    let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var prevOffset: CGFloat = 0
    private let actionWidth: CGFloat = 74
    private let snapThreshold: CGFloat = 0.4

    init(leadingActions: [SwipeAction] = [],
         trailingActions: [SwipeAction] = [],
         cornerRadius: CGFloat = 0,
         @ViewBuilder content: @escaping () -> Content) {
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.cornerRadius = cornerRadius
        self.content = content
    }

    private var maxLeadingOffset: CGFloat {
        CGFloat(leadingActions.count) * actionWidth
    }

    private var maxTrailingOffset: CGFloat {
        CGFloat(trailingActions.count) * actionWidth
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Leading actions — только при свайпе вправо
            if !leadingActions.isEmpty, offset > 0 {
                HStack(spacing: 0) {
                    ForEach(leadingActions.indices, id: \.self) { i in
                        actionButton(leadingActions[i],
                                     extraTrailingPadding: i == leadingActions.count - 1 ? 20 : 0)
                    }
                }
                // Левый край скруглён (видимый), правый прямой (уходит под карточку)
                .clipShape(.rect(topLeadingRadius: cornerRadius,
                                 bottomLeadingRadius: cornerRadius,
                                 bottomTrailingRadius: 0,
                                 topTrailingRadius: 0))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Trailing actions — только при свайпе влево
            if !trailingActions.isEmpty, offset < 0 {
                HStack(spacing: 0) {
                    ForEach(trailingActions.indices, id: \.self) { i in
                        actionButton(trailingActions[i],
                                     extraLeadingPadding: i == 0 ? 20 : 0)
                    }
                }
                // Правый край скруглён (видимый), левый прямой (уходит под карточку)
                .clipShape(.rect(topLeadingRadius: 0,
                                 bottomLeadingRadius: 0,
                                 bottomTrailingRadius: cornerRadius,
                                 topTrailingRadius: cornerRadius))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Main content — zIndex(1) чтобы карточка была ПОВЕРХ кнопок
            content()
                .offset(x: offset)
                .zIndex(1)
                .gesture(HorizontalPanGesture(shouldBegin: { !leadingActions.isEmpty || !trailingActions.isEmpty }, allowsLeftward: true) { pan in
                    switch pan.state {
                    case .began, .changed:
                        let translation = pan.translation(in: nil).x + prevOffset
                        if translation > 0 {
                            offset = leadingActions.isEmpty ? translation * 0.2 : min(translation, maxLeadingOffset)
                        } else {
                            offset = trailingActions.isEmpty ? translation * 0.2 : max(translation, -maxTrailingOffset)
                        }
                    case .ended:
                        finishSwipe(velocity: pan.velocity(in: nil).x, cancelled: false)
                    case .cancelled, .failed:
                        finishSwipe(velocity: 0, cancelled: true)
                    default: break
                    }
                })
        }
    }

    private func finishSwipe(velocity: CGFloat, cancelled: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            if cancelled {
                offset = prevOffset
            } else if offset > 0, !leadingActions.isEmpty,
                      offset > maxLeadingOffset * snapThreshold || velocity > 200 {
                offset = maxLeadingOffset; prevOffset = offset
            } else if offset < 0, !trailingActions.isEmpty,
                      -offset > maxTrailingOffset * snapThreshold || velocity < -200 {
                offset = -maxTrailingOffset; prevOffset = offset
            } else {
                offset = 0; prevOffset = 0
            }
        }
    }

    private func actionButton(_ action: SwipeAction,
                              extraLeadingPadding: CGFloat = 0,
                              extraTrailingPadding: CGFloat = 0) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                offset = 0
                prevOffset = 0
            }
            action.action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.icon)
                    .font(.system(size: 20))
                Text(action.title)
                    .font(.system(size: 11))
            }
            .foregroundColor(.white)
            .frame(maxHeight: .infinity)
            .frame(width: actionWidth)
            // Доп. padding со стороны карточки — заливается цветом, уходит под карточку
            .padding(.leading, extraLeadingPadding)
            .padding(.trailing, extraTrailingPadding)
            .background(action.color)
        }
    }
}

// MARK: - Room List

struct HomeScreenRoomList: View {
    @ObservedObject var context: HomeScreenViewModel.Context
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    var body: some View {
        if !context.viewState.shouldHideRoomList {
            if isCosmos {
                // Wrap in VStack so card styling applies to the group, not each cell
                VStack(spacing: 0) {
                    content
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rooms = context.viewState.visibleRooms
        let favouriteCount = rooms.prefix(while: \.isFavourite).count
        ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
            VStack(spacing: 0) {
                if favouriteCount > 0, index == 0 || index == favouriteCount {
                    Text(index == 0 ? RoomListFilter.favourites.localizedName : NSLocalizedString("stalk_roomlist_other_conversations", comment: "Non-favourite conversations"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                }
                switch room.type {
                case .placeholder:
                    HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: context.mediaProvider, action: context.send, presence: nil)
                        .redacted(reason: .placeholder)
                case .invite:
                    HomeScreenInviteCell(room: room, context: context, hideInviteAvatars: context.viewState.hideInviteAvatars)
                case .knock:
                    HomeScreenKnockedCell(room: room, context: context)
                case .room:
                    let isSelected = context.viewState.selectedRoomID == room.id
                    SwipeActionView(leadingActions: leadingSwipeActions(for: room),
                                    trailingActions: trailingSwipeActions(for: room),
                                    cornerRadius: isCosmos ? 14 : 0) {
                        HomeScreenRoomCell(room: room, isSelected: isSelected, mediaProvider: context.mediaProvider, action: context.send, presence: room.dmUserID.flatMap { context.viewState.dmPresence[$0] }, meetingSummaryService: context.viewState.showsMeetingSessionSummaries ? context.viewState.meetingSummaryService : nil)
                    }
                    .contextMenu {
                        roomContextMenu(for: room)
                    }
                }

                // Cosmos: thin divider between cells (like calls list)
                if isCosmos, index < rooms.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 1 / UIScreen.main.scale)
                        .padding(.leading, 76)
                }
            }
            .background {
                if index == 0 {
                    GeometryReader { geometry in
                        Color.clear.preference(key: HomeScreenFirstRoomHeightKey.self, value: geometry.size.height)
                    }
                }
            }
        }
    }

    // MARK: - Swipe Actions

    /// Swipe right: Favourite + Archive
    private func leadingSwipeActions(for room: HomeScreenRoom) -> [SwipeAction] {
        [
            SwipeAction(title: room.isFavourite ? SL10n.actionRemoveFavorite : SL10n.actionAddFavorite,
                        icon: room.isFavourite ? "star.fill" : "star",
                        color: .orange) {
                context.send(viewAction: .markRoomAsFavourite(roomIdentifier: room.id, isFavourite: !room.isFavourite))
            },
            SwipeAction(title: SL10n.actionArchive,
                        icon: "archivebox",
                        color: .purple) {
                context.send(viewAction: .archiveRoom(roomIdentifier: room.id))
            }
        ]
    }

    /// Swipe left: Mute + Settings + Delete
    private func trailingSwipeActions(for room: HomeScreenRoom) -> [SwipeAction] {
        [
            SwipeAction(title: room.badges.isMuteShown ? SL10n.actionUnmute : SL10n.actionMute,
                        icon: room.badges.isMuteShown ? "bell.slash.fill" : "bell.slash",
                        color: room.badges.isMuteShown ? .green : .orange) {
                context.send(viewAction: .toggleMuteRoom(roomIdentifier: room.id, isMuted: room.badges.isMuteShown))
            },
            SwipeAction(title: SL10n.actionSettings,
                        icon: "gearshape",
                        color: Color(.systemGray)) {
                context.send(viewAction: .showRoomDetails(roomIdentifier: room.id))
            },
            SwipeAction(title: SL10n.actionDelete,
                        icon: "trash",
                        color: .red) {
                context.send(viewAction: .leaveRoom(roomIdentifier: room.id))
            }
        ]
    }

    @ViewBuilder
    private func roomContextMenu(for room: HomeScreenRoom) -> some View {
        if room.badges.isDotShown {
            Button {
                context.send(viewAction: .markRoomAsRead(roomIdentifier: room.id))
            } label: {
                Label(L10n.screenRoomlistMarkAsRead, icon: \.markAsRead)
            }
        } else {
            Button {
                context.send(viewAction: .markRoomAsUnread(roomIdentifier: room.id))
            } label: {
                Label(L10n.screenRoomlistMarkAsUnread, icon: \.markAsUnread)
            }
        }

        if room.isFavourite {
            Button {
                context.send(viewAction: .markRoomAsFavourite(roomIdentifier: room.id, isFavourite: false))
            } label: {
                Label(L10n.commonFavourited, icon: \.favouriteSolid)
            }
        } else {
            Button {
                context.send(viewAction: .markRoomAsFavourite(roomIdentifier: room.id, isFavourite: true))
            } label: {
                Label(L10n.commonFavourite, icon: \.favourite)
            }
        }

        Button {
            context.send(viewAction: .showRoomDetails(roomIdentifier: room.id))
        } label: {
            Label(L10n.commonSettings, icon: \.settings)
        }

        if context.viewState.reportRoomEnabled {
            Button(role: .destructive) {
                context.send(viewAction: .reportRoom(roomIdentifier: room.id))
            } label: {
                Label(L10n.actionReportRoom, icon: \.chatProblem)
            }
        }

        Button(role: .destructive) {
            context.send(viewAction: .leaveRoom(roomIdentifier: room.id))
        } label: {
            Label(L10n.actionLeaveRoom, icon: \.leave)
        }
    }
}

/// The first row may be a taller invitation and grows with Dynamic Type.
struct HomeScreenFirstRoomHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
