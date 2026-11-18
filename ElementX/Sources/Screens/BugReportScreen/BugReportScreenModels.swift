//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit

enum BugReportScreenViewModelAction {
    case cancel
    case viewLogs
    case submitStarted(progressPublisher: CurrentValuePublisher<Double, Never>)
    case submitFinished
    case submitFailed(error: Error)
}

struct BugReportScreenViewState: BindableState {
    let canSendLogFiles: Bool
    var screenshot: UIImage?
    var bindings: BugReportScreenViewStateBindings
    let isModallyPresented: Bool
    var shouldDisableInteraction = false
    /// STALK-1603: «Мои заявки» — обращения пользователя на его сервере
    var myRequests: [FeedbackRequestsService.Item]?
    var isLoadingMyRequests = false
    var myRequestsError: String?
    var selectedRequest: FeedbackRequestsService.Detail?
}

/// STALK-1603: вкладки как в «Обратной связи» веба
enum BugReportScreenTab: Hashable {
    case bug
    case feature
    case myRequests
}

struct BugReportScreenViewStateBindings {
    var reportText: String
    var sendingLogsEnabled: Bool
    var canContact: Bool
    var selectedTab: BugReportScreenTab = .bug
    var isShowingRequestDetail = false
}

enum BugReportScreenViewAction {
    case cancel
    case submit
    case removeScreenshot
    case attachScreenshot(UIImage)
    case viewLogs
    case loadMyRequests
    case openRequest(id: String)
}
