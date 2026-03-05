//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct TimelineItemStatusView: View {
    let timelineItem: EventBasedTimelineItemProtocol
    let adjustedDeliveryStatus: TimelineItemDeliveryStatus?
    @EnvironmentObject private var context: TimelineViewModel.Context

    private var isLastOutgoingMessage: Bool {
        timelineItem.isOutgoing && context.viewState.timelineState.uniqueIDs.last == timelineItem.id.uniqueID
    }

    var body: some View {
        mainContent
    }

    @ViewBuilder
    private var mainContent: some View {
        // sTalk: delivery checkmarks are now shown inline with timestamp
        // in TimelineItemSendInfoLabel. This badge area is no longer used.
        EmptyView()
    }
}
