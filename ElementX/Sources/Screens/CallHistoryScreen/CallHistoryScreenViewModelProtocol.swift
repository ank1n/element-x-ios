//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine

@MainActor
protocol CallHistoryScreenViewModelProtocol {
    var actions: AnyPublisher<CallHistoryScreenViewModelAction, Never> { get }
    var context: CallHistoryScreenViewModelType.Context { get }
}
