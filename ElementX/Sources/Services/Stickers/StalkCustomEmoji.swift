// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftSoup
import SwiftUI

struct StalkCustomEmoji: Identifiable {
    let id: String
    let label: String
    let shortcode: String
    let alias: String
    let mxc: String
    var asset: String {
        "stalk-capy-" + id
    }

    static let all: [Self] = [
        .init(id: "face", label: NSLocalizedString("Капибара", comment: "Built-in capybara display name"), shortcode: ":capybara:", alias: ":капибара:", mxc: "mxc://stalk.implica.ru/TQuTEsJzjsZmesfSlunbelkS"),
        .init(id: "full", label: NSLocalizedString("Капибара целиком", comment: "Built-in capybara display name"), shortcode: ":capybara_full:", alias: ":капибара_целиком:", mxc: "mxc://stalk.implica.ru/nzYCLaLYeleWuBoIBrkpnucD"),
        .init(id: "sleep", label: NSLocalizedString("Спящая капибара", comment: "Built-in capybara display name"), shortcode: ":capybara_sleep:", alias: ":капибара_спит:", mxc: "mxc://stalk.implica.ru/UZyxgtUeLWSXiYBpOokBGEgS"),
        .init(id: "laugh", label: NSLocalizedString("Капибара смеётся", comment: "Built-in capybara display name"), shortcode: ":capybara_laugh:", alias: ":капибара_смех:", mxc: "mxc://stalk.implica.ru/oNlnPijTldJoLXJroCcSRBJn"),
        .init(id: "love", label: NSLocalizedString("Влюблённая капибара", comment: "Built-in capybara display name"), shortcode: ":capybara_love:", alias: ":капибара_любовь:", mxc: "mxc://stalk.implica.ru/iZetZndOiLYkMmSurddwygOr"),
        .init(id: "surprised", label: NSLocalizedString("Удивлённая капибара", comment: "Built-in capybara display name"), shortcode: ":capybara_surprised:", alias: ":капибара_удивление:", mxc: "mxc://stalk.implica.ru/nXNJttwNMeiCRksqZwZZiZqS"),
        .init(id: "sad", label: NSLocalizedString("Грустная капибара", comment: "Built-in capybara display name"), shortcode: ":capybara_sad:", alias: ":капибара_грусть:", mxc: "mxc://stalk.implica.ru/kSDXInIzSkADZmddqkkoRCjO"),
        .init(id: "wink", label: NSLocalizedString("Капибара подмигивает", comment: "Built-in capybara display name"), shortcode: ":capybara_wink:", alias: ":капибара_подмигивание:", mxc: "mxc://stalk.implica.ru/ycXHaqckOVEItbYKLfnvvMsq")
    ]
    static func lookup(_ value: String) -> Self? {
        all.first { $0.mxc == value || $0.shortcode.caseInsensitiveCompare(value) == .orderedSame || $0.alias.caseInsensitiveCompare(value) == .orderedSame }
    }

    static let pattern = try! NSRegularExpression(pattern: ":(" + all.flatMap { [$0.shortcode.dropFirst().dropLast(), $0.alias.dropFirst().dropLast()] }.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|") + "):", options: .caseInsensitive)

    static func formatted(plain: String, html: String?) -> String? {
        guard pattern.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil,
              let document = try? SwiftSoup.parseBodyFragment(html ?? StalkMarkdown.toHTML(plain)), let body = document.body() else { return html }
        var changed = false
        func walk(_ node: Node, excluded: Bool) throws {
            let blocked = excluded || (node as? Element).map { ["pre", "code", "a", "mx-reply", "script", "style", "textarea"].contains($0.tagName()) } == true
            if let text = node as? TextNode, !blocked {
                let raw = text.getWholeText()
                let matches = pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
                guard !matches.isEmpty else { return }
                var result = ""
                var position = raw.startIndex
                func escape(_ string: String) -> String {
                    string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                }
                for match in matches {
                    guard let range = Range(match.range, in: raw), let emoji = lookup(String(raw[range])) else { continue }
                    result += escape(String(raw[position..<range.lowerBound]))
                    result += "<img data-mx-emoticon src=\"\(emoji.mxc)\" alt=\"\(emoji.shortcode)\" width=\"32\" height=\"32\">"
                    position = range.upperBound
                }
                result += escape(String(raw[position...]))
                try text.before(result)
                try text.remove()
                changed = true
            } else { for child in node.getChildNodes() {
                try walk(child, excluded: blocked)
            } }
        }
        do { try walk(body, excluded: false); if changed { return try body.html() }; return html } catch { return html }
    }

    static func atomicRange(in text: String, at range: NSRange) -> NSRange? {
        let source = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard source.substring(to: match.range.location).filter({ $0 == "`" }).count % 2 == 0 else { continue }
            if range.length == 0 {
                if range.location > match.range.location, range.location < NSMaxRange(match.range) { return match.range }
            } else if NSIntersectionRange(range, match.range).length > 0 { return NSUnionRange(range, match.range) }
        }
        return nil
    }

    static func render(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        for match in pattern.matches(in: source.string, range: NSRange(location: 0, length: source.length)).reversed() {
            let attributes = source.attributes(at: match.range.location, effectiveRange: nil)
            guard attributes[.link] == nil, attributes[.CodeBlock] == nil,
                  (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) != true,
                  let emoji = lookup((source.string as NSString).substring(with: match.range)), let image = UIImage(named: emoji.asset) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            let height = (attributes[.font] as? UIFont)?.lineHeight ?? 28
            attachment.bounds = CGRect(x: 0, y: -4, width: height, height: height)
            result.replaceCharacters(in: match.range, with: NSAttributedString(attachment: attachment))
        }
        return result
    }
}

struct StalkEmojiGlyph: View {
    let value: String
    var body: some View {
        if let emoji = StalkCustomEmoji.lookup(value) {
            Image(emoji.asset).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityLabel(emoji.label)
        } else { Text(value) }
    }
}

extension SharedStickerPack {
    static let capybaras = SharedStickerPack(id: "builtin-capybara", title: NSLocalizedString("Капибары", comment: "Built-in capybara display name"), items: [
        .init(id: "wave", label: NSLocalizedString("Капибара: привет!", comment: "Built-in capybara display name"), mxc: "mxc://stalk.implica.ru/jXNbqeQCViPHYvmEJthlspIN", mimetype: "image/png", size: 1_600_342, w: 1254, h: 1254, animated: false),
        .init(id: "coffee", label: NSLocalizedString("Капибара с кофе", comment: "Built-in capybara display name"), mxc: "mxc://stalk.implica.ru/mePVXHrBJdsRAfdNynclGLsd", mimetype: "image/png", size: 1_369_225, w: 1254, h: 1254, animated: false),
        .init(id: "heart", label: NSLocalizedString("Капибара обнимает сердце", comment: "Built-in capybara display name"), mxc: "mxc://stalk.implica.ru/KQoYzDJGlCQKRxVkwcBxxpNb", mimetype: "image/png", size: 1_454_858, w: 1254, h: 1254, animated: false),
        .init(id: "bath", label: NSLocalizedString("Капибара отдыхает", comment: "Built-in capybara display name"), mxc: "mxc://stalk.implica.ru/eUFamkqUVYjDZFSegNpLKYrN", mimetype: "image/png", size: 1_478_430, w: 1254, h: 1254, animated: false)
    ])
}
