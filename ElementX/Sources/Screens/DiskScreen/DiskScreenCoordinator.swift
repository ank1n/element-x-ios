//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

enum DiskScreenCoordinatorAction {
    case hideTabBar(Bool)
}

struct DiskScreenCoordinatorParameters {
    /// База берётся от домена сессии, а не из apps-api: адрес виджета бывает
    /// захардкожен на .ru, и тогда токен другого домена получает 401 (STMOB-246).
    let baseURL: String
    let accessTokenProvider: () throws -> String
    let forceTokenRefresh: (() async -> Void)?
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
        viewModel = DiskScreenViewModel(service: service)

        viewModel.actionsPublisher
            .sink { action in
                switch action {
                case .openFile(let file):
                    // Открытие содержимого — следующий шаг. Для файлов из чатов
                    // путь известен (roomId + eventId → событие через SDK), для
                    // остальных ждём контракт скачивания от серверной стороны.
                    DiagLog.write("Disk", "выбран файл \(file.filename) (\(file.isEncrypted ? "зашифрован" : "открытый"))")
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
