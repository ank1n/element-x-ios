//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias WidgetsListScreenViewModelType = StateStoreViewModel<WidgetsListScreenViewState, WidgetsListScreenViewAction>

protocol WidgetsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<WidgetsListScreenViewModelAction, Never> { get }
    var context: WidgetsListScreenViewModelType.Context { get }
}

class WidgetsListScreenViewModel: WidgetsListScreenViewModelType, WidgetsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let actionsSubject: PassthroughSubject<WidgetsListScreenViewModelAction, Never> = .init()

    var actionsPublisher: AnyPublisher<WidgetsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol) {
        self.userSession = userSession

        super.init(initialViewState: WidgetsListScreenViewState(), mediaProvider: userSession.mediaProvider)

        Task {
            await loadWidgets()
        }
    }

    override func process(viewAction: WidgetsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectWidget(let item):
            // Open first widget in the room
            if let widget = item.widgets.first {
                actionsSubject.send(.openWidget(widget: widget, roomId: item.id))
            }
        }
    }

    // MARK: - Private

    private func loadWidgets() async {
        state.isLoading = true

        var roomsWithWidgets: [WidgetRoomItem] = []

        // Get all room summaries from provider
        let roomSummaryProvider = userSession.clientProxy.roomSummaryProvider
        let summaries = roomSummaryProvider.roomListPublisher.value

        // For demo purposes, show all rooms with demo widgets
        // TODO: In production, fetch actual widgets from room state events
        for summary in summaries where !summary.isSpace {
            // Demo widget for each room
            let demoWidgets = [
                MatrixWidget(
                    id: "stats_widget_\(summary.id)",
                    type: "customwidget",
                    name: "Статистика",
                    url: "https://stats.market.implica.ru/?roomId=\(summary.id)",
                    creatorUserId: "@system:matrix.org",
                    waitForIframeLoad: true,
                    data: nil
                )
            ]

            let item = WidgetRoomItem(
                id: summary.id,
                roomName: summary.name,
                roomAvatar: summary.avatar,
                widgets: demoWidgets
            )
            roomsWithWidgets.append(item)
        }

        state.rooms = roomsWithWidgets
        state.isLoading = false
    }
}
