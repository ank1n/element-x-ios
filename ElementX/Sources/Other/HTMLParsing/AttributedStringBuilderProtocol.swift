//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct AttributedStringBuilderComponent: Hashable, Identifiable {
    let id: String
    let attributedString: AttributedString
    let isBlockquote: Bool
}

protocol AttributedStringBuilderProtocol {
    func fromPlain(_ string: String?, detectMarkdown: Bool) -> AttributedString?

    func fromHTML(_ htmlString: String?) -> AttributedString?

    func addMatrixEntityPermalinkAttributesTo(_ attributedString: NSMutableAttributedString)
}

extension AttributedStringBuilderProtocol {
    /// По умолчанию рендерим markdown в plain-body (боты шлют md без formatted_body).
    /// detectMarkdown: false — для строк, где md-конвенции неуместны (эмоты «* name …»,
    /// подписи к медиа, топик комнаты).
    func fromPlain(_ string: String?) -> AttributedString? {
        fromPlain(string, detectMarkdown: true)
    }
}
