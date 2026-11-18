// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Compound
import SwiftUI

/// STALK-1601: альбом в ленте. Картинки и видео — сеткой (`GalleryGridLayout`),
/// файлы и аудио — строками под ней, подпись — под всем. Тап по вложению открывает
/// обычный просмотрщик с листанием внутри альбома.
struct GalleryRoomTimelineView: View {
    @Environment(\.timelineContext) private var context
    let timelineItem: GalleryRoomTimelineItem

    private static let maxGridWidth = 300.0
    private static let spacing = 2.0

    private var content: GalleryRoomTimelineItemContent {
        timelineItem.content
    }

    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            VStack(alignment: .leading, spacing: 4) {
                let visualIndices = content.visualMediaIndices
                if visualIndices.count == 1, let index = visualIndices.first {
                    singleMedia(at: index)
                        .clipShape(RoundedRectangle(cornerRadius: timelineItem.hasBubbleChrome ? 6 : 0))
                } else if !visualIndices.isEmpty {
                    grid(visualIndices)
                        .clipShape(RoundedRectangle(cornerRadius: timelineItem.hasBubbleChrome ? 6 : 0))
                }

                ForEach(content.fileIndices, id: \.self) { index in
                    fileRow(at: index)
                }

                if let attributedCaption = content.formattedCaption {
                    FormattedBodyText(attributedString: attributedCaption,
                                      additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                                      boostFontSize: timelineItem.shouldBoost)
                } else if let caption = content.caption {
                    FormattedBodyText(text: caption,
                                      additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                                      boostFontSize: timelineItem.shouldBoost)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SL10n.galleryAlbum)
        }
    }

    // MARK: - Media

    /// Одно медиа в альбоме — как обычная картинка/видео, с сохранением пропорций.
    private func singleMedia(at index: Int) -> some View {
        thumbnail(at: index, fill: false)
            .timelineMediaFrame(imageInfo: content.items[index].thumbnailInfo)
            .contentShape(Rectangle())
            .onTapGesture { openItem(at: index) }
    }

    private func grid(_ indices: [Int]) -> some View {
        let rows = GalleryGridLayout.rows(for: indices.count)
        let starts = rows.indices.map { rows[..<$0].reduce(0, +) }

        return VStack(spacing: Self.spacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(starts[row]..<(starts[row] + rows[row]), id: \.self) { position in
                        cell(at: indices[position])
                    }
                }
                // Ряд из одной ячейки — широкая плитка 2:1, иначе квадраты.
                .aspectRatio(CGFloat(max(rows[row], 2)), contentMode: .fit)
            }
        }
        .frame(maxWidth: Self.maxGridWidth)
    }

    private func cell(at index: Int) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { thumbnail(at: index, fill: true) }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { openItem(at: index) }
    }

    @ViewBuilder
    private func thumbnail(at index: Int, fill: Bool) -> some View {
        let item = content.items[index]
        let isVideo = if case .video = item { true } else { false }

        if let info = item.thumbnailInfo {
            LoadableImage(mediaSource: info.source,
                          mediaType: .timelineItem(uniqueID: .init("\(timelineItem.id.uniqueID.value)-\(index)")),
                          blurhash: blurhash(of: item),
                          size: info.size,
                          mediaProvider: context?.mediaProvider) { imageView in
                imageView
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .overlay { if isVideo { playIcon } }
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
                .overlay { if isVideo { playIcon } }
        }
    }

    private func blurhash(of item: GalleryRoomTimelineItemContent.Item) -> String? {
        switch item {
        case .image(let content): content.blurhash
        case .video(let content): content.blurhash
        case .audio, .file: nil
        }
    }

    private var playIcon: some View {
        Image(systemName: "play.circle.fill")
            .resizable()
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
            .foregroundColor(.white)
    }

    private var placeholder: some View {
        Rectangle()
            .foregroundColor(timelineItem.isOutgoing ? .compound._bgBubbleOutgoing : .compound._bgBubbleIncoming)
            .opacity(0.3)
    }

    // MARK: - Files

    @ViewBuilder
    private func fileRow(at index: Int) -> some View {
        let (filename, fileSize, mimeType): (String, UInt?, String?) = switch content.items[index] {
        case .file(let file): (file.filename, file.fileSize, file.contentType?.preferredMIMEType)
        case .audio(let audio): (audio.filename, audio.fileSize, audio.contentType?.preferredMIMEType)
        case .image(let image): (image.filename, image.imageInfo.fileSize, image.contentType?.preferredMIMEType)
        case .video(let video): (video.filename, video.videoInfo.fileSize, video.contentType?.preferredMIMEType)
        }

        StalkFileShareView(fileShare: .init(blobID: "", name: filename, size: Int64(fileSize ?? 0), mimetype: mimeType ?? "",
                                            isDiskDocument: false, permission: .read, sharedWith: []),
                           showsPermission: false,
                           onTap: { openItem(at: index) })
    }

    private func openItem(at index: Int) {
        context?.send(viewAction: .galleryItemTapped(itemID: timelineItem.id, index: index))
    }
}

struct GalleryRoomTimelineView_Previews: PreviewProvider {
    static let viewModel = TimelineViewModel.mock

    static var previews: some View {
        ScrollView {
            VStack(spacing: 20.0) {
                ForEach([2, 3, 4, 7], id: \.self) { count in
                    GalleryRoomTimelineView(timelineItem: makeTimelineItem(count: count, caption: count == 3 ? "Альбом с подписью" : nil))
                }
            }
        }
        .environmentObject(viewModel.context)
        .environment(\.timelineContext, viewModel.context)
        .previewLayout(.fixed(width: 390, height: 1600))
    }

    private static func makeTimelineItem(count: Int, caption: String?) -> GalleryRoomTimelineItem {
        let image = ImageRoomTimelineItemContent(filename: "image.jpg",
                                                 imageInfo: .mockImage,
                                                 thumbnailInfo: .mockThumbnail,
                                                 blurhash: "L%KUc%kqS$RP?Ks,WEf8OlrqaekW",
                                                 contentType: .jpeg)
        return GalleryRoomTimelineItem(id: .randomEvent,
                                       timestamp: .mock,
                                       isOutgoing: false,
                                       isEditable: false,
                                       canBeRepliedTo: true,
                                       sender: .init(id: "Bob"),
                                       content: .init(caption: caption, items: Array(repeating: .image(image), count: count)))
    }
}
