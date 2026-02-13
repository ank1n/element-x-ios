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

    /// Extract domain from homeserver URL for building service URLs
    private var serverDomain: String {
        let homeserver = userSession.clientProxy.homeserver
        return URL(string: homeserver)?.host ?? "stalk.implica.ru"
    }

    /// Base URL of the homeserver (e.g., https://stalk.implica.ru)
    private var serverBaseURL: String {
        let homeserver = userSession.clientProxy.homeserver
        if let url = URL(string: homeserver), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)"
        }
        return "https://stalk.implica.ru"
    }

    private func loadWidgets() {
        let baseURL = serverBaseURL
        state.widgets = [
            WidgetItem(
                id: "statistics",
                name: "Статистика",
                description: "Статистика сервера и активности",
                icon: "chart.bar.fill",
                url: "\(baseURL)/stats/",
                category: .tools
            ),
            WidgetItem(
                id: "dimension",
                name: "Интеграции",
                description: "Управление виджетами и ботами",
                icon: "puzzlepiece.fill",
                url: "https://dimension.\(serverDomain)/element",
                category: .tools
            )
        ]
        state.isLoading = false
    }
}
