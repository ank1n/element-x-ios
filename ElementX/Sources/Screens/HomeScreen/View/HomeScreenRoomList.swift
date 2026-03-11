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
    let content: () -> Content

    init(leadingActions: [SwipeAction] = [],
         trailingActions: [SwipeAction] = [],
         @ViewBuilder content: @escaping () -> Content) {
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.content = content
    }

    var body: some View {
        content()
    }
}

// MARK: - Room List

struct HomeScreenRoomList: View {
    @ObservedObject var context: HomeScreenViewModel.Context
    @AppStorage("stalk_design_theme") private var designTheme: String = "cosmos"

    private var isCosmos: Bool { designTheme == "cosmos" }

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
                cosmosCellWrapper {
                    HomeScreenInviteCell(room: room, context: context, hideInviteAvatars: context.viewState.hideInviteAvatars)
                }
            case .knock:
                cosmosCellWrapper {
                    HomeScreenKnockedCell(room: room, context: context)
                }
            case .room:
                let isSelected = context.viewState.selectedRoomID == room.id

                cosmosCellWrapper {
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

    // MARK: - Cosmos Card Wrapper

    @ViewBuilder
    private func cosmosCellWrapper<C: View>(@ViewBuilder content: () -> C) -> some View {
        if isCosmos {
            content()
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        } else {
            content()
        }
    }
}
