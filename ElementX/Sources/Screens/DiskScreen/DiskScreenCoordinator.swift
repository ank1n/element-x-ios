//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

enum DiskScreenCoordinatorAction {
    case hideTabBar(Bool)
    /// Зашифрованный файл открывается только в своей комнате — там есть ключи.
    /// Он же переход «найти в чате».
    case openRoom(roomID: String, eventID: String)
    /// Переслать файл в другой чат.
    case forward(roomID: String, eventID: String)
    /// Переслать содержимым (файлы без Matrix-события): вложение через пикер комнат.
    case forwardFile(url: URL, name: String)
}

struct DiskScreenCoordinatorParameters {
    /// База берётся от домена сессии, а не из apps-api: адрес виджета бывает
    /// захардкожен на .ru, и тогда токен другого домена получает 401 (STMOB-246).
    let baseURL: String
    let accessTokenProvider: () throws -> String
    let forceTokenRefresh: (() async -> Void)?
    let mediaProvider: MediaProviderProtocol?
    /// Профиль по userID — для аватарок получателей шаринга в списке.
    let profileResolver: ((String) async -> UserProfileProxy?)?
    /// Имя комнаты по roomID — «в какой группе запощен файл» (dp).
    let roomNameResolver: ((String) async -> String?)?
}

final class DiskScreenCoordinator: CoordinatorProtocol {
    private let viewModel: DiskScreenViewModel
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<DiskScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: DiskScreenCoordinatorParameters) {
        let service = DiskService(baseURL: parameters.baseURL,
                                  accessTokenProvider: parameters.accessTokenProvider,
                                  forceTokenRefresh: parameters.forceTokenRefresh)
        viewModel = DiskScreenViewModel(service: service,
                                        mediaProvider: parameters.mediaProvider,
                                        profileResolver: parameters.profileResolver,
                                        roomNameResolver: parameters.roomNameResolver)

        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .openRoom(let roomID, let eventID):
                    self?.actionsSubject.send(.openRoom(roomID: roomID, eventID: eventID))
                case .forward(let roomID, let eventID):
                    self?.actionsSubject.send(.forward(roomID: roomID, eventID: eventID))
                case .forwardFile(let url, let name):
                    self?.actionsSubject.send(.forwardFile(url: url, name: name))
                case .dismiss:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(DiskScreen(context: viewModel))
    }
}
