// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct MeetingVenuePhoto: View {
    let source: String?
    let name: String
    let mediaProvider: MediaProviderProtocol?
    var height: CGFloat = 120
    var body: some View {
        if let url = MeetingVenueStrings.photoURL(source), let mediaProvider {
            LoadableImage(url: url, mediaType: .generic, size: CGSize(width: 640, height: 240), mediaProvider: mediaProvider) { $0.scaledToFill() } placeholder: {
                Color(uiColor: .secondarySystemBackground).overlay(Image(systemName: "door.left.hand.open"))
            }
            .frame(maxWidth: .infinity).frame(height: height).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(String(format: MeetingVenueStrings.text("photo"), name))
        }
    }
}
