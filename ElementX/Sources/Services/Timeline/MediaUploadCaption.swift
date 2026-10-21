// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MatrixRustSDK

/// Only selected mention entities carry notification intent; typed @text does not.
struct MediaUploadCaption: Equatable {
    var text: String
    var html: String?
    var mentions: IntentionalMentions

    init?(attributed: NSAttributedString, allowRoomMention: Bool) {
        var text = "", markdown = "", anchors: [String: String] = [:], users = Set<String>(), room = false
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            if let id = attributes[.MatrixUserID] as? String, let url = try? URL(string: matrixToUserPermalink(userId: id)) {
                let name = attributes[.MatrixUserDisplayName] as? String ?? id
                let token = "MENTION" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                text += name; markdown += token; users.insert(id)
                anchors[token] = "<a href=\"\(escape(url.absoluteString))\">\(escape(name))</a>"
            } else if attributes[.MatrixAllUsersMention] as? Bool == true {
                text += "@room"; markdown += "@room"; room = allowRoomMention
            } else {
                let part = attributed.attributedSubstring(from: range).string
                text += part; markdown += part
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        var formatted = StalkMarkdown.toHTML(markdown)
        for (token, anchor) in anchors {
            formatted = formatted.replacingOccurrences(of: token, with: anchor)
        }
        html = formatted
        mentions = .init(userIDs: users, atRoom: room)
    }
}

extension TimelineControllerProtocol {
    /// Preview/test implementations can keep their existing upload implementation.
    func sendAttachment(_ media: MediaInfo, caption: MediaUploadCaption?, requestHandle: @MainActor (SendAttachmentJoinHandleProtocol) -> Void) async -> Result<Void, TimelineControllerError> {
        switch media {
        case let .file(url, info): await sendFile(url: url, fileInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .image(url, thumbnail, info): await sendImage(url: url, thumbnailURL: thumbnail, imageInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .video(url, thumbnail, info): await sendVideo(url: url, thumbnailURL: thumbnail, videoInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .audio(url, info): await sendAudio(url: url, audioInfo: info, caption: caption?.text, requestHandle: requestHandle)
        }
    }
}

extension TimelineProxyProtocol {
    func sendAttachment(_ media: MediaInfo, caption: MediaUploadCaption?, requestHandle: @MainActor (SendAttachmentJoinHandleProtocol) -> Void) async -> Result<Void, TimelineProxyError> {
        switch media {
        case let .file(url, info): await sendFile(url: url, fileInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .image(url, thumbnail, info): await sendImage(url: url, thumbnailURL: thumbnail, imageInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .video(url, thumbnail, info): await sendVideo(url: url, thumbnailURL: thumbnail, videoInfo: info, caption: caption?.text, requestHandle: requestHandle)
        case let .audio(url, info): await sendAudio(url: url, audioInfo: info, caption: caption?.text, requestHandle: requestHandle)
        }
    }
}
