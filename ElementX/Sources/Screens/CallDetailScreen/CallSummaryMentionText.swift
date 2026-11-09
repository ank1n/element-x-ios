// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UIKit

enum CallSummaryMentions {
    struct Mention: Equatable {
        let range: NSRange
        let userID: String
    }

    /// Match exact Matrix identities. A bare localpart is usable only when the roster
    /// identifies a single account; display names are never identity evidence.
    static func userID(_ identity: String, knownIDs: [String]) -> String? {
        if !identity.contains(":") {
            let matches = Set(knownIDs.filter { CallSummaryPeople.isUserID($0) && $0.split(separator: ":", maxSplits: 1).first.map(String.init) == identity })
            return matches.count == 1 ? matches.first : nil
        }
        let pattern = "^(@[^:\\s]+:(?:\\[[^\\]]+\\]|[^:\\s]+)(?::[0-9]+)?)(?::[^\\s]+)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: identity, range: NSRange(identity.startIndex..., in: identity)),
              let range = Range(match.range(at: 1), in: identity) else { return nil }
        let id = String(identity[range])
        return CallSummaryPeople.isUserID(id) ? id : nil
    }

    static func mentions(in text: String, knownIDs: [String]) -> [Mention] {
        let pattern = #"(?<![\p{L}\p{N}._%+/#\-])@[^\s<>()\[\]{},;!?\"«»]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            var range = match.range
            while range.length > 0, ".:".contains(source.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                range.length -= 1
            }
            guard let id = userID(source.substring(with: range), knownIDs: knownIDs) else { return nil }
            return Mention(range: range, userID: id)
        }
    }

    static func fallbackName(_ id: String) -> String {
        String(id.dropFirst().split(separator: ":", maxSplits: 1).first ?? Substring(id))
    }
}

struct CallSummaryMentionText: View {
    let text: String
    let profiles: [String: ResolvedParticipant]
    let knownIDs: [String]
    let mediaProvider: MediaProviderProtocol?
    let open: (String) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15
    @State private var images: [URL: UIImage] = [:]

    var body: some View {
        let mentions = CallSummaryMentions.mentions(in: text, knownIDs: knownIDs)
        let urls = Array(Set(mentions.compactMap { profiles[$0.userID]?.avatarURL })).sorted { $0.absoluteString < $1.absoluteString }
        CallSummaryMentionTextView(text: text, mentions: mentions, profiles: profiles, images: images,
                                   fontSize: fontSize, open: open)
            .task(id: urls) {
                guard let mediaProvider else { return }
                for url in urls where images[url] == nil {
                    guard !Task.isCancelled, let source = try? MediaSourceProxy(url: url, mimeType: nil) else { continue }
                    if case let .success(image) = await mediaProvider.loadImageFromSource(source, size: CGSize(width: 64, height: 64)), !Task.isCancelled {
                        images[url] = image
                    }
                }
            }
    }
}

private struct CallSummaryMentionTextView: UIViewRepresentable {
    let text: String
    let mentions: [CallSummaryMentions.Mention]
    let profiles: [String: ResolvedParticipant]
    let images: [URL: UIImage]
    let fontSize: CGFloat
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(open: open)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: UIColor.label, .underlineStyle: 0]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.open = open
        let font = UIFont.systemFont(ofSize: fontSize)
        let key = RenderKey(text: text, mentions: mentions, profiles: profiles,
                            images: images.mapValues { ObjectIdentifier($0) }, fontName: font.fontName,
                            pointSize: font.pointSize, style: view.traitCollection.userInterfaceStyle.rawValue)
        guard context.coordinator.renderKey != key else { return }
        context.coordinator.renderKey = key
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let result = NSMutableAttributedString(string: "")
        let source = text as NSString
        var cursor = 0
        for mention in mentions {
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: mention.range.location - cursor)), attributes: attributes))
            let profile = profiles[mention.userID]
            let name = profile.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? CallSummaryMentions.fallbackName(mention.userID)
            let size = font.lineHeight
            let avatar = NSTextAttachment()
            let image = profile?.avatarURL.flatMap { images[$0] }
            avatar.image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).addClip()
                if let image {
                    let scale = max(size / image.size.width, size / image.size.height)
                    let width = image.size.width * scale, height = image.size.height * scale
                    image.draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
                } else {
                    UIColor.systemIndigo.withAlphaComponent(0.15).setFill()
                    UIBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size)).fill()
                    let letter = String(name.prefix(1)).uppercased() as NSString
                    let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.65, weight: .semibold), .foregroundColor: UIColor.systemIndigo]
                    let bounds = letter.size(withAttributes: style)
                    letter.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2), withAttributes: style)
                }
            }
            avatar.bounds = CGRect(x: 0, y: font.descender, width: size, height: size)
            let label = NSMutableAttributedString(attachment: avatar)
            label.append(NSAttributedString(string: "\u{00A0}" + name, attributes: attributes))
            var url = URLComponents(); url.scheme = "stalk-call-user"; url.host = "profile"
            url.queryItems = [URLQueryItem(name: "id", value: mention.userID)]
            if let url = url.url {
                label.addAttributes([.link: url, .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)], range: NSRange(location: 0, length: label.length))
            }
            result.append(label)
            cursor = NSMaxRange(mention.range)
        }
        result.append(NSAttributedString(string: source.substring(from: cursor), attributes: attributes))
        if view.attributedText != result { view.attributedText = result }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    struct RenderKey: Equatable {
        let text: String
        let mentions: [CallSummaryMentions.Mention]
        let profiles: [String: ResolvedParticipant]
        let images: [URL: ObjectIdentifier]
        let fontName: String
        let pointSize: CGFloat
        let style: Int
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var renderKey: RenderKey?
        var open: (String) -> Void
        init(open: @escaping (String) -> Void) {
            self.open = open
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if URL.scheme == "stalk-call-user", let id = URLComponents(url: URL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
               CallSummaryPeople.isUserID(id) { open(id) }
            return false
        }
    }
}
