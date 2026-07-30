//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

enum AilockScreenCoordinatorAction {
    case hideTabBar(Bool)
}

struct AilockScreenCoordinatorParameters {
    /// Домен текущей сессии — база для door-2 (STMOB-246: только от homeserver, без хардкода).
    let homeserver: String
    let accessTokenProvider: () throws -> String
    let forceTokenRefresh: (() async -> Void)?
    /// Идентификатор агента для POST /sessions.
    let agentID: String
}

/// Приложение «Айлок» во вкладке «Приложения»: чат с агентом + история бесед.
final class AilockScreenCoordinator: CoordinatorProtocol {
    private let parameters: AilockScreenCoordinatorParameters
    private let service: AilockService
    private let chatViewModel: AilockScreenViewModel
    private var conversationsViewModel: AilockConversationsViewModel?

    private let navigationStackCoordinator: NavigationStackCoordinator
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<AilockScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AilockScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: AilockScreenCoordinatorParameters, navigationStackCoordinator: NavigationStackCoordinator) {
        self.parameters = parameters
        self.navigationStackCoordinator = navigationStackCoordinator

        service = AilockService(homeserver: parameters.homeserver,
                                accessTokenProvider: parameters.accessTokenProvider,
                                forceTokenRefresh: parameters.forceTokenRefresh)
        // Диктовка идёт через recording-api того же домена (STMOB-265 / STALK-666),
        // а не через door-2: STT-ключ тенанта серверный и в клиент не попадает.
        let transcriber = AilockVoiceTranscriber(homeserver: parameters.homeserver,
                                                 accessTokenProvider: parameters.accessTokenProvider,
                                                 forceTokenRefresh: parameters.forceTokenRefresh)
        chatViewModel = AilockScreenViewModel(service: service,
                                              agentID: parameters.agentID,
                                              transcriber: transcriber)

        chatViewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .openConversations:
                    showConversations()
                case .hideTabBar(let hidden):
                    actionsSubject.send(.hideTabBar(hidden))
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(AilockChatScreen(context: chatViewModel.context))
    }

    func stop() {
        chatViewModel.stop()
    }

    // MARK: - Навигация

    private func showConversations() {
        let viewModel = AilockConversationsViewModel(service: service, agentID: parameters.agentID)
        conversationsViewModel = viewModel

        viewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .selected(let conversation):
                    chatViewModel.open(conversation: conversation)
                    navigationStackCoordinator.pop()
                case .newConversation:
                    chatViewModel.process(viewAction: .newConversation)
                    navigationStackCoordinator.pop()
                case .dismiss:
                    navigationStackCoordinator.pop()
                }
            }
            .store(in: &cancellables)

        navigationStackCoordinator.push(AilockConversationsCoordinatorShim(viewModel: viewModel))
    }
}

// MARK: - Shim для NavigationStack

final class AilockConversationsCoordinatorShim: CoordinatorProtocol {
    let viewModel: AilockConversationsViewModel

    init(viewModel: AilockConversationsViewModel) {
        self.viewModel = viewModel
    }

    func toPresentable() -> AnyView {
        AnyView(AilockConversationsScreen(context: viewModel.context))
    }
}
