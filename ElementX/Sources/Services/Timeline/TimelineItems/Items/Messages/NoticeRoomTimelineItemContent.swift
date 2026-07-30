//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import UIKit

struct NoticeRoomTimelineItemContent: Hashable {
    let body: String
    var formattedBody: AttributedString?
    /// STMOB-275: карточка «поделился файлом». Приходит кастомным полем на этом же
    /// уведомлении, поэтому отдельного типа события заводить не нужно: не разобрали —
    /// показываем `body`, там осмысленный текст со ссылкой.
    var fileShare: StalkFileShare?
}
