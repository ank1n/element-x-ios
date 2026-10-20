// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SystemSearchResultRow: View {
    let hit: SystemSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { kind; semantic }
                VStack(alignment: .leading, spacing: 4) { kind; semantic }
            }
            if let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hit.text != hit.title {
                Text(hit.text)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let room = hit.meta?.room, !room.isEmpty {
                Label(room, systemImage: "bubble.left")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let author = hit.meta?.author, !author.isEmpty {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(hit.badges, id: \.self) { badge in
                Text(badge).font(.caption).foregroundStyle(.secondary)
            }
            if hit.target == nil {
                Text(NSLocalizedString("Переход к этому объекту недоступен", comment: "Unavailable search target"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var kind: some View {
        Label(SystemSearchScreen.typeName(hit.facetKind), systemImage: icon)
            .font(.caption.weight(.semibold)).foregroundStyle(StalkTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var semantic: some View {
        if hit.by == "sense" || hit.by == "both" {
            Text(NSLocalizedString("По смыслу", comment: "Semantic search match"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch hit.facetKind {
        case "message", "comment": "bubble.left"
        case "task": "checklist"
        case "meeting": "calendar"
        case "transcript", "voice_transcript": "waveform"
        case "disk_doc", "attachment": "doc"
        default: "magnifyingglass"
        }
    }
}
