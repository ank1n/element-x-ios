// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Adapts a Disk URL to the existing file card; opening and public metadata stay URL-scoped.
struct StalkDiskLinkCardView: View {
    let card: StalkDiskCard
    let open: () -> Void
    @Environment(\.timelineContext) private var context
    @State private var metadata: StalkDiskPublicPreview.Metadata?

    var body: some View {
        StalkFileShareView(fileShare: presentation,
                           showsPermission: false,
                           isExternalLink: card.kind == .publicShare,
                           onTap: open)
            .accessibilityIdentifier("stalk.diskFileCard")
            .accessibilityHint(card.host)
            .task(id: card.id) {
                guard context?.viewState.linkPreviewsEnabled == true else { return }
                metadata = await StalkDiskPublicPreview.shared.metadata(for: card)
            }
    }

    private var presentation: StalkFileShare {
        let document = StalkDiskLink(url: card.url)
        return .init(blobID: document?.blobID ?? "",
                     name: metadata?.name ?? (card.name.isEmpty ? NSLocalizedString("stalk_disk_file_link", value: "Файл Диска", comment: "Disk file link card title") : card.name),
                     size: metadata?.size ?? 0,
                     mimetype: metadata?.mimetype ?? "",
                     isDiskDocument: document?.isDiskDocument ?? true,
                     permission: .read, // URL alone supplies no permission; the card hides this field.
                     sharedWith: [])
    }
}
