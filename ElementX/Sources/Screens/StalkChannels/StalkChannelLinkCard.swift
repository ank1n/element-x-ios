// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StalkChannelLinkCard: View {
    let url: URL
    @ObservedObject var service: StalkChannelService
    @State private var entry: StalkChannelDirectoryEntry?
    @Environment(\.openURL) private var openURL
    var body: some View {
        Group {
            if let entry {
                Button { openURL(url) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "megaphone.fill").foregroundStyle(StalkTheme.accent)
                            .frame(width: 40, height: 40).background(StalkTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.headline).foregroundStyle(.primary)
                            // No publications or snippets are fetched for non-members.
                            Text(StalkChannelStrings.text(entry.joined ? "open" : entry.requiresApproval ? "request" : "subscribe"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
        .task(id: url) {
            do { entry = try await service.lookup(url.absoluteString) } catch { entry = nil }
        }
    }

    static func candidates(in body: String) -> [URL] {
        guard body.contains("matrix.to/") || body.contains("#/room/") else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return Array(detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap(\.url)
            .filter { $0.host == "matrix.to" || $0.fragment?.hasPrefix("/room/") == true }.prefix(2))
    }
}
