//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import OrderedCollections
import SwiftUI

struct TextRoomTimelineView: View, TextBasedRoomTimelineViewProtocol {
    static let maxLinkPreviewsToRender = 2
    
    @Environment(\.timelineContext) private var context
    let timelineItem: TextRoomTimelineItem
    
    @State private var linkMetadata: OrderedDictionary<URL, LinkMetadataProviderItem>
    
    init(timelineItem: TextRoomTimelineItem, linkMetadata: OrderedDictionary<URL, LinkMetadataProviderItem> = [:]) {
        self.timelineItem = timelineItem
        self.linkMetadata = linkMetadata
    }
    
    var body: some View {
        let cards = diskCards
        return TimelineStyler(timelineItem: timelineItem) {
            // STMOB-274: ссылка на встречу разворачивается в карточку, как в вебе.
            // Пока встреча грузится или не нашлась — остаётся сама ссылка.
            if let fileShare = timelineItem.content.fileShare {
                StalkFileShareView(fileShare: fileShare) { context?.send(viewAction: .stalkFileShareTapped(itemID: timelineItem.id)) }
            } else if let code = timelineItem.content.meetingCode {
                StalkMeetingCardView(code: code, fallbackText: timelineItem.content.body)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if cards.count != 1 || timelineItem.body.trimmingCharacters(in: .whitespacesAndNewlines) != cards[0].url.absoluteString {
                        if let attributedString = timelineItem.content.formattedBody {
                            FormattedBodyText(attributedString: attributedString,
                                              additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                                              boostFontSize: timelineItem.shouldBoost)
                        } else {
                            FormattedBodyText(text: timelineItem.body,
                                              additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                                              boostFontSize: timelineItem.shouldBoost)
                        }
                    }
                    ForEach(cards) { card in
                        StalkDiskLinkCardView(card: card) { context?.send(viewAction: .stalkDiskLinkTapped(card.url)) }
                    }
                    ForEach(StalkDiskLink.labelledDocumentIDs(in: timelineItem.body), id: \.self) { id in
                        Button {
                            context?.send(viewAction: .stalkDiskReferenceTapped(blobID: id))
                        } label: {
                            Label(String(localized: "stalk_disk_open_document", defaultValue: "Открыть документ"), systemImage: "doc.text")
                        }.buttonStyle(.bordered)
                    }
                    if context?.viewState.linkPreviewsEnabled ?? false, !otherLinkURLs.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(otherLinkURLs, id: \.absoluteString) { url in
                                let metadata = linkMetadata[url]?.metadata ?? context?.viewState.linkMetadataProvider?.metadataItems[url]?.metadata
                                LinkPreviewView(url: url, metadata: metadata)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .task { await fetchLinkPreviews() }
    }
    
    private var otherLinkURLs: [URL] {
        linkMetadata.keys.filter { !isDiskURL($0) }
    }

    private func isDiskURL(_ url: URL) -> Bool {
        StalkDiskCard(url: url, homeserver: context?.viewState.homeserver.flatMap(URL.init(string:))) != nil
    }

    private var diskCards: [StalkDiskCard] {
        StalkDiskCard.links(in: timelineItem.body, formattedBody: timelineItem.content.formattedBody,
                            homeserver: context?.viewState.homeserver.flatMap(URL.init(string:)))
    }

    private func fetchLinkPreviews() async {
        guard context?.viewState.linkPreviewsEnabled ?? false else {
            return
        }
        
        await withTaskGroup { taskGroup in
            for url in timelineItem.links.filter({ !isDiskURL($0) }).prefix(Self.maxLinkPreviewsToRender) {
                taskGroup.addTask {
                    if case let .success(metadata) = await context?.viewState.linkMetadataProvider?.fetchMetadataFor(url: url) {
                        await MainActor.run {
                            linkMetadata[url] = metadata
                        }
                    }
                }
            }
        }
    }
}

struct TextRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        body.environmentObject(viewModel.context)
            .previewDisplayName("Bubble")
            .previewLayout(.sizeThatFits)
        body
            .environmentObject(viewModel.context)
            .environment(\.layoutDirection, .rightToLeft)
            .previewDisplayName("Bubble RTL")
            .previewLayout(.sizeThatFits)
    }
    
    static var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20.0) {
                TextRoomTimelineView(timelineItem: itemWith(text: "Short loin ground round tongue hamburger, fatback salami shoulder. Beef turkey sausage kielbasa strip steak. Alcatra capicola pig tail pancetta chislic.",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))
                
                TextRoomTimelineView(timelineItem: itemWith(text: "Check out this cool website: https://www.apple.com and also https://github.com for some great projects!",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))
                
                TextRoomTimelineView(timelineItem: itemWith(text: "Short loin ground round tongue hamburger, fatback salami shoulder. Beef turkey sausage kielbasa strip steak. Alcatra capicola pig tail pancetta chislic.",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))
                
                TextRoomTimelineView(timelineItem: itemWith(text: "Some other text",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))
                
                TextRoomTimelineView(timelineItem: itemWith(text: "טקסט אחר",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))
                
                TextRoomTimelineView(timelineItem: itemWith(html: "<ol><li>First item</li><li>Second item</li><li>Third item</li></ol>",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))
                
                TextRoomTimelineView(timelineItem: itemWith(html: "<ol><li>פריט ראשון</li><li>הפריט השני</li><li>פריט שלישי</li></ol>",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))
                
                // HTML with links for testing
                TextRoomTimelineView(timelineItem: itemWith(html: "Check out <a href=\"https://www.apple.com\">Apple's website</a> and <a href=\"https://github.com\">GitHub</a>!",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))
            }
        }
    }
    
    private static func itemWith(text: String, timestamp: Date, isOutgoing: Bool, senderId: String) -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: .randomEvent,
                             timestamp: timestamp,
                             isOutgoing: isOutgoing,
                             isEditable: isOutgoing,
                             canBeRepliedTo: true,
                             sender: .init(id: senderId),
                             content: .init(body: text))
    }
    
    private static func itemWith(html: String, timestamp: Date, isOutgoing: Bool, senderId: String) -> TextRoomTimelineItem {
        let builder = AttributedStringBuilder(cacheKey: "preview", mentionBuilder: MentionBuilder())
        let attributedString = builder.fromHTML(html)
        
        return TextRoomTimelineItem(id: .randomEvent,
                                    timestamp: timestamp,
                                    isOutgoing: isOutgoing,
                                    isEditable: isOutgoing,
                                    canBeRepliedTo: true,
                                    sender: .init(id: senderId),
                                    content: .init(body: "", formattedBody: attributedString))
    }
}
