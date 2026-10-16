//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct MessageSearchScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let roomSummaryProvider: RoomSummaryProviderProtocol?
    var isCallActive: () -> Bool = { false }
}

final class MessageSearchScreenCoordinator: CoordinatorProtocol {
    private let viewModel: MessageSearchScreenViewModel
    private let client: ClientProxyProtocol
    private let isCallActive: () -> Bool

    private var cancellables = Set<AnyCancellable>()
    private let actionsSubject: PassthroughSubject<MessageSearchScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<MessageSearchScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: MessageSearchScreenCoordinatorParameters) {
        client = parameters.clientProxy
        isCallActive = parameters.isCallActive
        let searchService = MessageSearchService(homeserverURL: parameters.clientProxy.homeserver,
                                                 accessTokenProvider: { try parameters.clientProxy.matrixAccessToken() },
                                                 forceTokenRefresh: { await parameters.clientProxy.forceTokenRefresh() })
        viewModel = MessageSearchScreenViewModel(searchService: searchService,
                                                 roomSummaryProvider: parameters.roomSummaryProvider)

        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .openRoomAtEvent(let roomID, let eventID):
                    self?.actionsSubject.send(.openRoomAtEvent(roomID: roomID, eventID: eventID))
                case .dismiss:
                    self?.actionsSubject.send(.dismiss)
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(SystemSearchScreen(client: client, isCallActive: isCallActive) { [weak self] target, title in
            self?.actionsSubject.send(.systemTarget(target, title: title))
        })
    }
}

enum MessageSearchScreenCoordinatorAction {
    case systemTarget(SystemSearchTarget, title: String?)
    case openRoomAtEvent(roomID: String, eventID: String)
    case dismiss
}
