// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SystemSearchResultRow: View {
    let hit: SystemSearchHit
    var mediaProvider: MediaProviderProtocol?
    var profileLoader: (@MainActor (SystemSearchHit) async -> UserProfileProxy?)?
    @State private var authorProfile: UserProfileProxy?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { kind; semantic }
                VStack(alignment: .leading, spacing: 4) { kind; semantic }
            }
            if hit.isFileResult {
                HStack(alignment: .top, spacing: 12) {
                    StalkFileBadge(fileShare: .init(blobID: "", name: hit.fileDisplayName, size: hit.meta?.size ?? 0,
                                                    mimetype: hit.meta?.mimetype ?? "", isDiskDocument: hit.entity_type == "disk_doc", permission: .read, sharedWith: []))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hit.fileDisplayName).font(.headline).foregroundStyle(.primary)
                            .lineLimit(3).truncationMode(.middle).multilineTextAlignment(.leading)
                        if let size = hit.meta?.size, size >= 0 {
                            Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                if let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    Text(title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
                if let snippet = hit.displayedSnippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snippet != hit.title {
                    Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let room = hit.meta?.room, !room.isEmpty {
                Label(room, systemImage: "bubble.left")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let author = authorProfile?.displayName ?? hit.meta?.author ?? authorProfile?.userID, !author.isEmpty {
                HStack(spacing: 6) {
                    if hit.isFileResult {
                        LoadableAvatarImage(url: authorProfile?.avatarURL, name: author,
                                            contentID: authorProfile?.userID ?? "search-author:" + author,
                                            avatarSize: .custom(24), mediaProvider: mediaProvider)
                            .accessibilityHidden(true)
                    }
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
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
        .task(id: hit.id) {
            authorProfile = nil
            guard hit.isFileResult, let profileLoader else { return }
            let profile = await profileLoader(hit)
            guard !Task.isCancelled else { return }
            authorProfile = profile
        }
    }

    private var kind: some View {
        Group {
            if hit.isFileResult { Text(SystemSearchScreen.typeName(hit.facetKind == "file" ? "attachment" : hit.facetKind)) }
            else { Label(SystemSearchScreen.typeName(hit.facetKind), systemImage: icon) }
        }
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
