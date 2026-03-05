//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct TimelineDeliveryStatusView: View {
    enum Status {
        case sending
        case sent
        case read
    }

    let deliveryStatus: Status

    var body: some View {
        switch deliveryStatus {
        case .sending:
            CompoundIcon(\.circle, size: .xSmall, relativeTo: .compound.bodyMD)
                .foregroundColor(.compound.iconSecondary)
                .accessibilityLabel(L10n.commonSending)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.compound.iconSecondary)
                .accessibilityLabel(L10n.commonSent)
        case .read:
            // sTalk: double checkmark (read) — blue like Telegram
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.compound.iconAccentTertiary)
            .accessibilityLabel(L10n.commonSent)
        }
    }
}

struct TimelineDeliveryStatusView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 8) {
            TimelineDeliveryStatusView(deliveryStatus: .sending)
            TimelineDeliveryStatusView(deliveryStatus: .sent)
            TimelineDeliveryStatusView(deliveryStatus: .read)
        }
    }
}
