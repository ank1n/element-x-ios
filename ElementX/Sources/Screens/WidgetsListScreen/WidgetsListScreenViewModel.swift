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
    private var widgetsCancellables: Set<AnyCancellable> = []

    var actionsPublisher: AnyPublisher<WidgetsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol) {
        self.userSession = userSession

        var initialState = WidgetsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
        loadWidgets()
    }

    override func process(viewAction: WidgetsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectWidget(let widget):
            actionsSubject.send(.openWidget(widget))
        }
    }

    // MARK: - Private

    private func setupSubscriptions() {
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &widgetsCancellables)

        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &widgetsCancellables)

        userSession.sessionSecurityStatePublisher
            .map { $0.verificationState != .verified || $0.recoveryState != .enabled }
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.requiresExtraAccountSetup, on: self)
            .store(in: &widgetsCancellables)
    }

    private func loadWidgets() {
        state.widgets = [
            WidgetItem(
                id: "statistics",
                name: "Статистика",
                description: "Просмотр статистики и аналитики",
                icon: "chart.bar.fill",
                url: "https://stats.market.implica.ru/"
            ),
            WidgetItem(
                id: "calendar",
                name: "Календарь",
                description: "Календарь событий и встреч",
                icon: "calendar",
                url: "https://calendar.market.implica.ru/"
            ),
            WidgetItem(
                id: "tasks",
                name: "Задачи",
                description: "Управление задачами и проектами",
                icon: "checklist",
                url: "https://tasks.market.implica.ru/"
            ),
            WidgetItem(
                id: "files",
                name: "Файлы",
                description: "Файловый менеджер",
                icon: "folder.fill",
                url: "https://files.market.implica.ru/"
            ),
            WidgetItem(
                id: "notes",
                name: "Заметки",
                description: "Создание и редактирование заметок",
                icon: "note.text",
                url: "https://notes.market.implica.ru/"
            )
        ]
        state.isLoading = false
    }
}
