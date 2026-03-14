//
// Copyright 2026 Implica Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ArchiveScreen: View {
    @ObservedObject var context: ArchiveScreenViewModel.Context
    @AppStorage("stalk_design_theme") private var designTheme: String = "cosmos"

    private var isCosmos: Bool { designTheme == "cosmos" }

    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)

    var body: some View {
        content
            .navigationTitle(SL10n.archiveTitle)
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $context.alertInfo)
            .alert(item: $context.leaveRoomAlertItem,
                   actions: leaveRoomAlertActions,
                   message: leaveRoomAlertMessage)
    }

    @ViewBuilder
    private var content: some View {
        if context.viewState.rooms.isEmpty && !context.viewState.isLoading {
            emptyState
        } else {
            roomList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundColor(.compound.iconSecondary)
            Text(SL10n.archiveEmpty)
                .font(.compound.bodyLG)
                .foregroundColor(.compound.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.compound.bgCanvasDefault)
    }

    private var roomList: some View {
        ZStack {
            if isCosmos {
                LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(context.viewState.rooms) { room in
                        switch room.type {
                        case .room:
                            ArchiveRoomSwipeView(room: room, context: context) {
                                HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: context.mediaProvider) { action in
                                    switch action {
                                    case .selectRoom(let id):
                                        context.send(viewAction: .selectRoom(roomIdentifier: id))
                                    default:
                                        break
                                    }
                                }
                            }
                            .background(isCosmos ? Color(UIColor.systemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: isCosmos ? 14 : 0))
                            .shadow(color: isCosmos ? .black.opacity(0.05) : .clear, radius: 6, y: 2)
                            .padding(.horizontal, isCosmos ? 12 : 0)
                            .padding(.vertical, isCosmos ? 3 : 0)
                            .contextMenu {
                            Button {
                                context.send(viewAction: .unarchiveRoom(roomIdentifier: room.id))
                            } label: {
                                Label(SL10n.actionUnarchive, systemImage: "tray.and.arrow.up")
                            }

                            Button {
                                context.send(viewAction: .showRoomDetails(roomIdentifier: room.id))
                            } label: {
                                Label(L10n.commonSettings, icon: \.settings)
                            }

                            Button(role: .destructive) {
                                context.send(viewAction: .leaveRoom(roomIdentifier: room.id))
                            } label: {
                                Label(L10n.actionLeaveRoom, icon: \.leave)
                            }
                        }
                    default:
                        HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: context.mediaProvider) { _ in }
                            .background(isCosmos ? Color(UIColor.systemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: isCosmos ? 14 : 0))
                            .shadow(color: isCosmos ? .black.opacity(0.05) : .clear, radius: 6, y: 2)
                            .padding(.horizontal, isCosmos ? 12 : 0)
                            .padding(.vertical, isCosmos ? 3 : 0)
                    }
                }
            }
        }
        .background(isCosmos ? Color.clear : Color.compound.bgCanvasDefault)
        }
    }

    // MARK: - Leave Room Alert

    @ViewBuilder
    private func leaveRoomAlertActions(_ item: LeaveRoomAlertItem) -> some View {
        Button(item.cancelTitle, role: .cancel) { }
        Button(item.confirmationTitle, role: .destructive) {
            context.send(viewAction: .confirmLeaveRoom(roomIdentifier: item.roomID))
        }
    }

    private func leaveRoomAlertMessage(_ item: LeaveRoomAlertItem) -> some View {
        Text(item.subtitle)
    }
}

// MARK: - Swipe Actions

private struct ArchiveSwipeAction {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

private struct ArchiveRoomSwipeView<Content: View>: View {
    let room: HomeScreenRoom
    @ObservedObject var context: ArchiveScreenViewModel.Context
    let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var prevOffset: CGFloat = 0

    private let actionButtonWidth: CGFloat = 74
    private let snapThreshold: CGFloat = 0.4

    private var leadingActions: [ArchiveSwipeAction] {
        [
            ArchiveSwipeAction(
                title: SL10n.actionUnarchiveShort,
                icon: "tray.and.arrow.up",
                color: .green
            ) {
                context.send(viewAction: .unarchiveRoom(roomIdentifier: room.id))
            }
        ]
    }

    private var trailingActions: [ArchiveSwipeAction] {
        [
            ArchiveSwipeAction(
                title: L10n.commonSettings,
                icon: "gearshape",
                color: Color(.systemGray)
            ) {
                context.send(viewAction: .showRoomDetails(roomIdentifier: room.id))
            },
            ArchiveSwipeAction(
                title: SL10n.actionDelete,
                icon: "trash",
                color: .red
            ) {
                context.send(viewAction: .leaveRoom(roomIdentifier: room.id))
            }
        ]
    }

    private var maxLeadingOffset: CGFloat {
        CGFloat(leadingActions.count) * actionButtonWidth
    }

    private var maxTrailingOffset: CGFloat {
        CGFloat(trailingActions.count) * actionButtonWidth
    }

    var body: some View {
        ZStack(alignment: .center) {
            if !leadingActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(leadingActions.indices, id: \.self) { index in
                        actionButton(action: leadingActions[index])
                    }
                    Spacer()
                }
            }

            if !trailingActions.isEmpty {
                HStack(spacing: 0) {
                    Spacer()
                    ForEach(trailingActions.indices, id: \.self) { index in
                        actionButton(action: trailingActions[index])
                    }
                }
            }

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

    private func actionButton(action: ArchiveSwipeAction) -> some View {
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
