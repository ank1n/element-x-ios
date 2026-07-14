//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol CallScreenViewModelProtocol {
    var actions: AnyPublisher<CallScreenViewModelAction, Never> { get }
    var context: CallScreenViewModelType.Context { get }
    
    func stop()
    /// Останов с ОЖИДАНИЕМ полного disconnect LiveKit (bounded) — для подмены
    /// звонка вторым: без ожидания два менеджера живут параллельно (зомби-аудио).
    func stopAndWaitCleanup() async
}
