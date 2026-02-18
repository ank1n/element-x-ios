//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Kingfisher

extension ImageCache {
    static var onlyInMemory: ImageCache {
        let result = ImageCache.default
        result.memoryStorage.config.keepWhenEnteringBackground = true
        // Enable disk cache for avatars — persist across background/foreground cycles
        result.diskStorage.config.sizeLimit = 100 * 1024 * 1024 // 100 MB
        result.diskStorage.config.expiration = .days(7)
        return result
    }

    static var onlyOnDisk: ImageCache {
        let result = ImageCache.default
        result.memoryStorage.config.totalCostLimit = 1
        return result
    }
}
