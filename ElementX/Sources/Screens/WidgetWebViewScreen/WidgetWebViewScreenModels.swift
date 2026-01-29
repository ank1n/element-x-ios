//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum WidgetWebViewScreenViewAction {
    case close
}

struct WidgetWebViewScreenViewState: BindableState {
    let widget: WidgetItem
    var isLoading: Bool = true
}
