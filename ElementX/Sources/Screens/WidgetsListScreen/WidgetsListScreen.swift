//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct WidgetsListScreen: View {
    @ObservedObject var context: WidgetsListScreenViewModelType.Context

    var body: some View {
        mainContent
            .navigationTitle("Виджеты")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        context.send(viewAction: .showSettings)
                    } label: {
                        CompoundIcon(\.settings)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
    }

    @ViewBuilder
    private var mainContent: some View {
        if context.viewState.isLoading {
            ProgressView("Загрузка виджетов...")
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if context.viewState.rooms.isEmpty {
            emptyState
        } else {
            roomsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.dashed")
                .font(.system(size: 64))
                .foregroundColor(.compound.textSecondary)

            Text("Нет виджетов")
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text("Виджеты будут отображаться здесь когда администратор добавит их в комнаты")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var roomsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(context.viewState.rooms) { room in
                    roomCell(room)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func roomCell(_ room: WidgetRoomItem) -> some View {
        Button {
            context.send(viewAction: .selectWidget(room))
        } label: {
            HStack(spacing: 12) {
                // Room avatar
                RoomAvatarImage(avatar: room.roomAvatar,
                                avatarSize: .room(on: .chats),
                                mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(room.roomName)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)

                    Text("\(room.widgets.count) виджет(ов)")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)

                    // Show widget names
                    ForEach(room.widgets.prefix(3)) { widget in
                        HStack(spacing: 6) {
                            Image(systemName: "app.fill")
                                .font(.caption)
                                .foregroundColor(.compound.iconSecondary)

                            Text(widget.name)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.compound.iconSecondary)
            }
            .padding(12)
            .background(Color.compound.bgSubtleSecondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

struct WidgetsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = WidgetsListScreenViewModel(userSession: UserSessionMock(.init()))
        WidgetsListScreen(context: viewModel.context)
    }
}
