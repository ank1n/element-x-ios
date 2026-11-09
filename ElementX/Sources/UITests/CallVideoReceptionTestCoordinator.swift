// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

final class CallVideoReceptionTestCoordinator: CoordinatorProtocol {
    private let reception = CallCameraReception { [] }
    func toPresentable() -> AnyView {
        AnyView(VStack(spacing: 24) {
            CallReceiveVideoToggle(reception: reception) { self.reception.setEnabled($0) }
            CallIncomingVideoNotice(reception: reception)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).preferredColorScheme(.dark))
    }
}
