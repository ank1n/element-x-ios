//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

// MARK: - Swipe Action Infrastructure

private struct SwipeAction {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

private struct SwipeActionView<Content: View>: View {
    let leadingActions: [SwipeAction]
    let trailingActions: [SwipeAction]
    let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var prevOffset: CGFloat = 0

    private let actionButtonWidth: CGFloat = 74
    private let snapThreshold: CGFloat = 0.4

    init(leadingActions: [SwipeAction] = [],
         trailingActions: [SwipeAction] = [],
         @ViewBuilder content: @escaping () -> Content) {
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.content = content
    }

    private var maxLeadingOffset: CGFloat {
        CGFloat(leadingActions.count) * actionButtonWidth
    }

    private var maxTrailingOffset: CGFloat {
        CGFloat(trailingActions.count) * actionButtonWidth
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Leading actions (revealed when swiping right)
            if !leadingActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(leadingActions.indices, id: \.self) { index in
                        actionButton(action: leadingActions[index])
                    }
                    Spacer()
                }
            }

            // Trailing actions (revealed when swiping left)
            if !trailingActions.isEmpty {
                HStack(spacing: 0) {
                    Spacer()
                    ForEach(trailingActions.indices, id: \.self) { index in
                        actionButton(action: trailingActions[index])
                    }
                }
            }

            // Main content
            content()
                .offset(x: offset)
                .allowsHitTesting(offset == 0)
        }
        .clipped()
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onChanged { value in
                    let translation = value.translation.width + prevOffset
                    if translation > 0 {
                        if leadingActions.isEmpty {
                            offset = translation * 0.2
                        } else {
                            let limit = maxLeadingOffset
                            offset = translation > limit ? limit + (translation - limit) * 0.2 : translation
                        }
                    } else {
                        if trailingActions.isEmpty {
                            offset = translation * 0.2
                        } else {
                            let limit = -maxTrailingOffset
                            offset = translation < limit ? limit + (translation - limit) * 0.2 : translation
                        }
                    }
                }
                .onEnded { value in
                    let velocity = value.predictedEndTranslation.width - value.translation.width
                    withAnimation(.easeOut(duration: 0.2)) {
                        if offset > 0 {
                            if offset > maxLeadingOffset * snapThreshold || velocity > 200 {
                                offset = maxLeadingOffset
                                prevOffset = maxLeadingOffset
                            } else {
                                offset = 0
                                prevOffset = 0
                            }
                        } else if offset < 0 {
                            if -offset > maxTrailingOffset * snapThreshold || velocity < -200 {
                                offset = -maxTrailingOffset
                                prevOffset = -maxTrailingOffset
                            } else {
                                offset = 0
                                prevOffset = 0
                            }
                        } else {
                            offset = 0
                            prevOffset = 0
                        }
                    }
                }
        )
    }

    private func actionButton(action: SwipeAction) -> some View {
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
            .frame(width: actionButtonWidth)
            .background(action.color)
        }
    }
}

// MARK: - Room List

struct HomeScreenRoomList: View {
    @ObservedObject var context: HomeScreenViewModel.Context

    var body: some View {
        if !context.viewState.shouldHideRoomList {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(context.viewState.visibleRooms) { room in
            switch room.type {
            case .placeholder:
                HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: context.mediaProvider, action: context.send)
                    .redacted(reason: .placeholder)
            case .invite:
                HomeScreenInviteCell(room: room, context: context, hideInviteAvatars: context.viewState.hideInviteAvatars)
            case .knock:
                HomeScreenKnockedCell(room: room, context: context)
            case .room:
                let isSelected = context.viewState.selectedRoomID == room.id

                SwipeActionView(
                    leadingActions: leadingActions(for: room),
                    trailingActions: trailingActions(for: room)
                ) {
                    HomeScreenRoomCell(room: room, isSelected: isSelected, mediaProvider: context.mediaProvider, action: context.send)
                }
                .contextMenu {
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
        }
    }

    // MARK: - Swipe Actions

    private func leadingActions(for room: HomeScreenRoom) -> [SwipeAction] {
        [
            SwipeAction(
                title: room.isFavourite ? L10n.commonFavourited : L10n.commonFavourite,
                icon: room.isFavourite ? "star.fill" : "star",
                color: .orange
            ) {
                context.send(viewAction: .markRoomAsFavourite(roomIdentifier: room.id, isFavourite: !room.isFavourite))
            }
        ]
    }

    private func trailingActions(for room: HomeScreenRoom) -> [SwipeAction] {
        [
            SwipeAction(
                title: "Архив",
                icon: "archivebox",
                color: .purple
            ) {
                context.send(viewAction: .archiveRoom(roomIdentifier: room.id))
            },
            SwipeAction(
                title: room.badges.isMuteShown ? "Вкл. звук" : "Без звука",
                icon: room.badges.isMuteShown ? "bell.slash.fill" : "bell.slash",
                color: room.badges.isMuteShown ? .green : .orange
            ) {
                context.send(viewAction: .toggleMuteRoom(roomIdentifier: room.id, isMuted: room.badges.isMuteShown))
            },
            SwipeAction(
                title: L10n.commonSettings,
                icon: "gearshape",
                color: Color(.systemGray)
            ) {
                context.send(viewAction: .showRoomDetails(roomIdentifier: room.id))
            },
            SwipeAction(
                title: "Удалить",
                icon: "trash",
                color: .red
            ) {
                context.send(viewAction: .leaveRoom(roomIdentifier: room.id))
            }
        ]
    }
}
