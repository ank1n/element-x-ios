//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

enum CacheAndStorageScreenCoordinatorAction {
    case clearCache
}

final class CacheAndStorageScreenCoordinator: CoordinatorProtocol {
    private let actionsSubject: PassthroughSubject<CacheAndStorageScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<CacheAndStorageScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init() { }

    func toPresentable() -> AnyView {
        AnyView(CacheAndStorageScreen(onClearAllCache: { [weak self] in
            self?.actionsSubject.send(.clearCache)
        }))
    }
}
