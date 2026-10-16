// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StalkDiskLinkCardView: View {
    let card: StalkDiskCard
    let open: () -> Void
    @Environment(\.timelineContext) private var context
    @State private var metadata: StalkDiskPublicPreview.Metadata?

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: card.kind == .publicShare ? "doc.badge.arrow.up" : "doc.text.fill")
                    .font(.title2).foregroundStyle(StalkTheme.accent)
                    .frame(width: 36, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadata?.name ?? (card.name.isEmpty ? NSLocalizedString("stalk_disk_file_link", value: "Файл Диска", comment: "Disk file link card title") : card.name))
                        .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    if let size = metadata?.size, size > 0 { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    Text(card.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if card.kind == .publicShare {
                        Text("stalk_disk_external_link", tableName: "Localizable", comment: "Public Disk link label")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(card.kind == .publicShare
                        ? NSLocalizedString("stalk_disk_open_link", value: "Открыть ссылку", comment: "Open public Disk link")
                        : NSLocalizedString("stalk_file_share_open_in_disk", value: "Открыть в Диске", comment: "Open Disk file"))
                        .font(.subheadline.weight(.medium)).foregroundStyle(StalkTheme.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).padding(.top, 14)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
        .accessibilityIdentifier("stalk.diskFileCard")
        .task(id: card.id) {
            guard context?.viewState.linkPreviewsEnabled == true else { return }
            metadata = await StalkDiskPublicPreview.shared.metadata(for: card)
        }
    }
}
