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
}

final class MessageSearchScreenCoordinator: CoordinatorProtocol {
    private let viewModel: MessageSearchScreenViewModel

    private var cancellables = Set<AnyCancellable>()
    private let actionsSubject: PassthroughSubject<MessageSearchScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<MessageSearchScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: MessageSearchScreenCoordinatorParameters) {
        let searchService = MessageSearchService(homeserverURL: parameters.clientProxy.homeserver,
                                                 accessTokenProvider: { try parameters.clientProxy.matrixAccessToken() })
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
        AnyView(MessageSearchScreen(context: viewModel.context))
    }
}

enum MessageSearchScreenCoordinatorAction {
    case openRoomAtEvent(roomID: String, eventID: String)
    case dismiss
}
