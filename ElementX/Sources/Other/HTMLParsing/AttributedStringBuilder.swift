//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import LRUCache
import MatrixRustSDK
import SwiftSoup
import UIKit

protocol MentionBuilderProtocol {
    func handleUserMention(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, userID: String, userDisplayName: String?)
    func handleRoomIDMention(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, roomID: String)
    func handleRoomAliasMention(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, roomAlias: String, roomDisplayName: String?)
    func handleEventOnRoomAliasMention(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, eventID: String, roomAlias: String)
    func handleEventOnRoomIDMention(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, eventID: String, roomID: String)
    func handleAllUsersMention(for attributedString: NSMutableAttributedString, in range: NSRange)
}

extension NSAttributedString.Key {
    static let MatrixBlockquote: NSAttributedString.Key = .init(rawValue: BlockquoteAttribute.name)
    static let MatrixUserID: NSAttributedString.Key = .init(rawValue: UserIDAttribute.name)
    static let MatrixUserDisplayName: NSAttributedString.Key = .init(rawValue: UserDisplayNameAttribute.name)
    static let MatrixRoomDisplayName: NSAttributedString.Key = .init(rawValue: RoomDisplayNameAttribute.name)
    static let MatrixRoomID: NSAttributedString.Key = .init(rawValue: RoomIDAttribute.name)
    static let MatrixRoomAlias: NSAttributedString.Key = .init(rawValue: RoomAliasAttribute.name)
    static let MatrixEventOnRoomID: NSAttributedString.Key = .init(rawValue: EventOnRoomIDAttribute.name)
    static let MatrixEventOnRoomAlias: NSAttributedString.Key = .init(rawValue: EventOnRoomAliasAttribute.name)
    static let MatrixAllUsersMention: NSAttributedString.Key = .init(rawValue: AllUsersMentionAttribute.name)
    static let CodeBlock: NSAttributedString.Key = .init(rawValue: CodeBlockAttribute.name)
}

struct AttributedStringBuilder: AttributedStringBuilderProtocol {
    private static let defaultKey = "default"
    
    private let cacheKey: String
    private let mentionBuilder: MentionBuilderProtocol
    
    private static let attributeMSC4286 = "msc4286-external-payment-details"
    private static let cacheDispatchQueue = DispatchQueue(label: "ru.implica.stalk.attributed_string_builder_v2_cache")
    private static var caches: [String: LRUCache<String, AttributedString>] = [:]

    static func invalidateCaches() {
        caches.removeAll()
    }
    
    init(cacheKey: String = defaultKey, mentionBuilder: MentionBuilderProtocol) {
        self.cacheKey = cacheKey
        self.mentionBuilder = mentionBuilder
    }
        
    func fromPlain(_ string: String?, detectMarkdown: Bool) -> AttributedString? {
        guard let string else {
            return nil
        }

        // Кэш — первым (таймлайн ребилдит ячейки многократно). Ключи неймспейсим,
        // чтобы plain-, markdown- и html-результаты одной строки не пересекались.
        let storageKey = (detectMarkdown ? "plainmd:" : "plain:") + string
        if let cached = Self.cachedValue(forKey: storageKey, cacheKey: cacheKey) {
            return cached
        }

        // sTalk: боты (#ops и т.п.) шлют markdown в plain body БЕЗ formatted_body —
        // upstream рендерит его буквально («**жирный**»). При уверенных md-признаках
        // конвертируем в HTML и пускаем через полный fromHTML-пайплайн (цитаты,
        // код-блоки, списки, ссылки, пиллы-меншены — бесплатно). Обычный текст
        // без признаков идёт по старому пути нетронутым.
        if detectMarkdown, StalkMarkdown.looksLikeMarkdown(string) {
            let html = StalkMarkdown.toHTML(string)
            if !html.isEmpty, let result = fromHTML(html) {
                Self.cacheValue(result, forKey: storageKey, cacheKey: cacheKey)
                return result
            }
            // Пустой/неудачный результат (например, сообщение из одного «```») —
            // фолбэк на обычный plain-рендер ниже.
        }

        let mutableAttributedString = NSMutableAttributedString(string: string)
        addLinksAndMentions(mutableAttributedString)
        addMatrixEntityPermalinkAttributesTo(mutableAttributedString)

        let result = try? AttributedString(mutableAttributedString, including: \.elementX)
        Self.cacheValue(result, forKey: storageKey, cacheKey: cacheKey)

        return result
    }
        
    /// Do not use the default HTML renderer of NSAttributedString because this method
    /// runs on the UI thread which we want to avoid because renderHTMLString is called
    /// most of the time from a background thread.
    /// Use DTCoreText HTML renderer instead.
    /// Using DTCoreText, which renders static string, helps to avoid code injection attacks
    /// that could happen with the default HTML renderer of NSAttributedString which is a
    /// webview.
    func fromHTML(_ htmlString: String?) -> AttributedString? {
        guard let originalHTMLString = htmlString else {
            return nil
        }
        
        if let cached = Self.cachedValue(forKey: originalHTMLString, cacheKey: cacheKey) {
            return cached
        }
                
        let htmlString = originalHTMLString.replacingHtmlBreaksOccurrences()
        
        let doc = try? SwiftSoup.parseBodyFragment(htmlString)
        
        guard let body = doc?.body() else {
            return nil
        }
        
        var listIndex = 1
        let mutableAttributedString = attributedString(element: body, documentBody: body, preserveFormatting: false, listTag: nil, listIndex: &listIndex, indentLevel: 0)
        detectPhishingAttempts(mutableAttributedString)
        addLinksAndMentions(mutableAttributedString)
        addMatrixEntityPermalinkAttributesTo(mutableAttributedString)
        removeParsingArtefacts(mutableAttributedString)
        
        let result = try? AttributedString(mutableAttributedString, including: \.elementX)
        Self.cacheValue(result, forKey: originalHTMLString, cacheKey: cacheKey)
        
        return result
    }
        
    // MARK: - Private
    
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func attributedString(element: Element,
                          documentBody: Element,
                          preserveFormatting: Bool,
                          listTag: String?,
                          listIndex: inout Int,
                          indentLevel: Int) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                // If this node is plain text just append its preformatted contents
                if node.parent() == documentBody {
                    result.append(NSAttributedString(string: textNode.getWholeText()))
                    continue
                }
                
                var text = preserveFormatting ? textNode.getWholeText() : textNode.text()
                
                // There seem to be sibling TextNodes following every </br> tag that
                // contain one single space character which we don't want as it
                // breaks line head indents.
                if (node.previousSibling() as? Element)?.tagName() == "br" {
                    text.trimPrefix(" ")
                }
                 
                result.append(NSAttributedString(string: text))
                continue
            }
            
            guard let childElement = node as? Element else {
                continue
            }
            
            let tag = childElement.tagName().lowercased()
            var content = NSMutableAttributedString()
            var childIndex = 1
            
            let fontPointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
            
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = max(3, Int(String(tag.dropFirst())) ?? 1)
                let size: CGFloat = fontPointSize + CGFloat(6 - level) * 2
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.append(NSAttributedString(string: "\n"))
                content.setFontPreservingSymbolicTraits(UIFont.boldSystemFont(ofSize: size))

            case "p", "div":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.append(NSAttributedString(string: "\n"))
                
            case "br":
                content = NSMutableAttributedString(string: "\n")
                
            case "b", "strong":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.setFontPreservingSymbolicTraits(UIFont.boldSystemFont(ofSize: fontPointSize))
                
            case "i", "em":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.setFontPreservingSymbolicTraits(UIFont.italicSystemFont(ofSize: fontPointSize))
                
            case "u":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: content.length))
                
            case "s", "del":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: content.length))
                
            case "sup":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.addAttribute(.baselineOffset, value: 6, range: NSRange(location: 0, length: content.length))
                content.setFontPreservingSymbolicTraits(UIFont.systemFont(ofSize: fontPointSize * 0.7))
                
            case "sub":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.addAttribute(.baselineOffset, value: -4, range: NSRange(location: 0, length: content.length))
                content.setFontPreservingSymbolicTraits(UIFont.systemFont(ofSize: fontPointSize * 0.7))
                
            case "blockquote":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                content.addAttribute(.MatrixBlockquote, value: true, range: NSRange(location: 0, length: content.length))
                
            case "code", "pre":
                let preserveFormatting = preserveFormatting || tag == "pre"
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                
                let fontPointSize = fontPointSize * 0.9 // Intentionally shrink code blocks by 10%
                content.setFontPreservingSymbolicTraits(UIFont.monospacedSystemFont(ofSize: fontPointSize, weight: .regular))
                
                content.addAttribute(.CodeBlock, value: true, range: NSRange(location: 0, length: content.length))
                content.addAttribute(.backgroundColor, value: UIColor.compound._bgCodeBlock as Any, range: NSRange(location: 0, length: content.length))
                
                // Don't allow identifiers or links in code blocks
                content.removeAttribute(.MatrixRoomID, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.MatrixRoomAlias, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.MatrixUserID, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.MatrixEventOnRoomID, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.MatrixEventOnRoomAlias, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.MatrixAllUsersMention, range: NSRange(location: 0, length: content.length))
                content.removeAttribute(.link, range: NSRange(location: 0, length: content.length))
                
            case "hr":
                content = NSMutableAttributedString(string: "\n")
                
            case "a":
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                if let href = try? childElement.attr("href"), let url = URL(string: href) {
                    content.addAttribute(.link, value: url, range: NSRange(location: 0, length: content.length))
                }
                
            case "span":
                if childElement.dataset()[Self.attributeMSC4286] == nil {
                    content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
                }
                
            case "ul", "ol":
                var listIndex = 1
                if let startAttribute = try? childElement.attr("start"), let startIndex = Int(startAttribute) {
                    listIndex = startIndex
                }
                
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: tag, listIndex: &listIndex, indentLevel: indentLevel + 1)
                
                if indentLevel > 0 {
                    content.insert(NSAttributedString("\n"), at: 0)
                }

            case "li":
                var bullet = String(repeating: "  ", count: indentLevel)
                if listTag == "ol" {
                    bullet += "\(listIndex). "
                    listIndex += 1
                } else {
                    bullet += "• "
                }
                
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel + 1)
                content.insert(NSAttributedString(string: bullet), at: 0)
                if !(content.string.last?.isNewline ?? false) {
                    content.append(NSAttributedString(string: "\n"))
                }
                
            case "img":
                if let alt = try? childElement.attr("alt"), !alt.isEmpty {
                    content = NSMutableAttributedString(string: "[img: \(alt)]")
                } else {
                    content = NSMutableAttributedString(string: "[img]")
                }
                
            default:
                content = attributedString(element: childElement, documentBody: documentBody, preserveFormatting: preserveFormatting, listTag: listTag, listIndex: &childIndex, indentLevel: indentLevel)
            }
            
            result.append(content)
        }
        
        return result
    }
    
    private static func cacheValue(_ value: AttributedString?, forKey key: String, cacheKey: String) {
        cacheDispatchQueue.sync {
            if caches[cacheKey] == nil {
                caches[cacheKey] = LRUCache<String, AttributedString>(countLimit: 1000)
            }
            
            caches[cacheKey]?.setValue(value, forKey: key)
        }
    }
    
    private static func cachedValue(forKey key: String, cacheKey: String) -> AttributedString? {
        var result: AttributedString?
        cacheDispatchQueue.sync {
            result = caches[cacheKey]?.value(forKey: key)
        }
        
        return result
    }
    
    // swiftlint:disable:next cyclomatic_complexity
    private func addLinksAndMentions(_ attributedString: NSMutableAttributedString) {
        let string = attributedString.string
        
        // Event identifiers and room aliases and identifiers detected in plain text are techincally incomplete
        // without via parameters and we won't bother detecting them
        
        var matches: [TextParsingMatch] = MatrixEntityRegex.userIdentifierRegex.matches(in: string).compactMap { match in
            guard let matchRange = Range(match.range, in: string) else {
                return nil
            }
            
            let identifier = String(string[matchRange])

            return TextParsingMatch(type: .userID(identifier: identifier), range: match.range)
        }
        
        matches.append(contentsOf: MatrixEntityRegex.roomAliasRegex.matches(in: string).compactMap { match in
            guard let matchRange = Range(match.range, in: string) else {
                return nil
            }
            
            let alias = String(string[matchRange])
            
            return TextParsingMatch(type: .roomAlias(alias: alias), range: match.range)
        })
        
        matches.append(contentsOf: MatrixEntityRegex.uriRegex.matches(in: string).compactMap { match in
            guard let matchRange = Range(match.range, in: string) else {
                return nil
            }
            
            let uri = String(string[matchRange])
            
            return TextParsingMatch(type: .matrixURI(uri: uri), range: match.range)
        })
        
        matches.append(contentsOf: MatrixEntityRegex.linkRegex.matches(in: string).compactMap { match in
            guard let matchRange = Range(match.range, in: string), let url = match.url else {
                return nil
            }
            
            // If the NSDataDetector found a hyperlink then sanitise it
            if url.scheme?.contains("http") ?? false {
                // Use the underlying string so it gets an `https` scheme if it didn't have any
                return TextParsingMatch(type: .link(urlString: String(string[matchRange]).asSanitizedLink), range: match.range)
            } else { // otherwise use it as it is e.g. mailto: (https://github.com/element-hq/element-x-ios/issues/4913)
                return TextParsingMatch(type: .link(urlString: url.absoluteString), range: match.range)
            }
        })
        
        matches.append(contentsOf: MatrixEntityRegex.allUsersRegex.matches(in: attributedString.string).map { match in
            TextParsingMatch(type: .atRoom, range: match.range)
        })
        
        guard matches.count > 0 else {
            return
        }
        
        // Sort the links by length so the longest one always takes priority
        matches.sorted { $0.range.length > $1.range.length }.forEach { [attributedString] match in
            // Don't highlight links within codeblocks
            let isInCodeBlock = attributedString.attribute(.CodeBlock, at: match.range.location, effectiveRange: nil) != nil
            if isInCodeBlock {
                return
            }
            
            var hasLink = false
            attributedString.enumerateAttribute(.link, in: match.range, options: []) { value, _, stop in
                if value != nil, !isInCodeBlock {
                    hasLink = true
                    stop.pointee = true
                }
            }
            
            if hasLink {
                return
            }
                        
            switch match.type {
            case .atRoom:
                attributedString.addAttribute(.MatrixAllUsersMention, value: true, range: match.range)
            case .roomAlias(let alias):
                if let urlString = try? matrixToRoomAliasPermalink(roomAlias: alias),
                   let url = URL(string: urlString) {
                    attributedString.addAttribute(.link, value: url, range: match.range)
                }
            case .matrixURI(let uri):
                if let url = URL(string: uri) {
                    attributedString.addAttribute(.link, value: url, range: match.range)
                }
            case .userID, .link:
                if let url = match.link {
                    attributedString.addAttribute(.link, value: url, range: match.range)
                }
            }
        }
    }
    
    func addMatrixEntityPermalinkAttributesTo(_ attributedString: NSMutableAttributedString) {
        attributedString.enumerateAttribute(.link, in: .init(location: 0, length: attributedString.length), options: []) { value, range, _ in
            if value != nil {
                if let url = value as? URL,
                   let matrixEntity = parseMatrixEntityFrom(uri: url.absoluteString) {
                    switch matrixEntity.id {
                    case .user(let userID):
                        mentionBuilder.handleUserMention(for: attributedString, in: range, url: url, userID: userID, userDisplayName: nil)
                    case .room(let roomID):
                        mentionBuilder.handleRoomIDMention(for: attributedString, in: range, url: url, roomID: roomID)
                    case .roomAlias(let alias):
                        mentionBuilder.handleRoomAliasMention(for: attributedString, in: range, url: url, roomAlias: alias, roomDisplayName: nil)
                    case .eventOnRoomId(let roomID, let eventID):
                        mentionBuilder.handleEventOnRoomIDMention(for: attributedString, in: range, url: url, eventID: eventID, roomID: roomID)
                    case .eventOnRoomAlias(let alias, let eventID):
                        mentionBuilder.handleEventOnRoomAliasMention(for: attributedString, in: range, url: url, eventID: eventID, roomAlias: alias)
                    }
                }
            }
        }
        
        attributedString.enumerateAttribute(.MatrixAllUsersMention, in: .init(location: 0, length: attributedString.length), options: []) { value, range, _ in
            if let value = value as? Bool,
               value {
                mentionBuilder.handleAllUsersMention(for: attributedString, in: range)
            }
        }
    }
        
    private func detectPhishingAttempts(_ attributedString: NSMutableAttributedString) {
        attributedString.enumerateAttribute(.link, in: .init(location: 0, length: attributedString.length), options: []) { value, range, _ in
            guard value != nil, let internalURL = value as? URL else {
                return
            }
            let displayString = attributedString.attributedSubstring(from: range).string
            
            guard PhishingDetector.isPhishingAttempt(displayString: displayString, internalURL: internalURL) else {
                return
            }
            handlePhishingAttempt(for: attributedString, in: range, internalURL: internalURL, displayString: displayString)
        }
    }
    
    private func handlePhishingAttempt(for attributedString: NSMutableAttributedString,
                                       in range: NSRange,
                                       internalURL: URL,
                                       displayString: String) {
        // Let's remove the existing link attribute
        attributedString.removeAttribute(.link, range: range)
        
        var urlComponents = URLComponents()
        urlComponents.scheme = URL.confirmationScheme
        urlComponents.host = ""
        let parameters = ConfirmURLParameters(internalURL: internalURL, displayString: displayString)
        urlComponents.queryItems = parameters.urlQueryItems
        
        guard let finalURL = urlComponents.url else {
            return
        }
        
        attributedString.addAttribute(.link, value: finalURL, range: range)
    }
    
    private func removeParsingArtefacts(_ attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else {
            return
        }
        
        // Ruma's markdown parsing sometimes inserts extra trailing new lines
        // https://github.com/ruma/ruma/blob/c3dc6de3e03b2ca131eab889a9d310ef160b95ac/crates/ruma-events/src/room/message.rs#L962
        while (attributedString.string as NSString).hasSuffixCharacter(from: .whitespacesAndNewlines) {
            attributedString.deleteCharacters(in: .init(location: attributedString.length - 1, length: 1))
        }
    }
}

private struct TextParsingMatch {
    enum MatchType {
        case userID(identifier: String)
        case roomAlias(alias: String)
        case matrixURI(uri: String)
        case link(urlString: String)
        case atRoom
    }
    
    let type: MatchType
    let range: NSRange
    
    var link: URL? {
        switch type {
        case .userID(let identifier):
            return try? URL(string: matrixToUserPermalink(userId: identifier))
        case .link(let urlString):
            return URL(string: urlString)
        default:
            return nil
        }
    }
}

private extension NSMutableAttributedString {
    func setFontPreservingSymbolicTraits(_ newFont: UIFont) {
        enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { value, range, _ in
            // STMOB-195: don't override the font on emoji runs. Forcing the system font
            // (which lacks emoji glyphs) onto an emoji range strips the Apple Color Emoji
            // font that DTCoreText assigned, so emoji render as tofu/“?”. Leave such
            // ranges untouched and only restyle text runs.
            if attributedSubstring(from: range).string.containsEmoji {
                return
            }
            if let oldFont = value as? UIFont {
                // keep the traits (bold, italic, etc.)
                let traits = oldFont.fontDescriptor.symbolicTraits
                if let descriptor = newFont.fontDescriptor.withSymbolicTraits(traits) {
                    let updatedFont = UIFont(descriptor: descriptor, size: newFont.pointSize)
                    addAttribute(.font, value: updatedFont, range: range)
                } else {
                    // fallback if traits can't be applied
                    addAttribute(.font, value: newFont, range: range)
                }
            } else {
                addAttribute(.font, value: newFont, range: range)
            }
        }
    }
}

private extension String {
    /// STMOB-195: true if the string contains any emoji scalar — used to avoid
    /// overriding the emoji font when restyling attributed text.
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation ||
                (scalar.properties.isEmoji && scalar.value > 0x238C) ||
                scalar.value == 0x200D || // ZWJ (emoji sequences)
                (0x1F000...0x1FAFF).contains(scalar.value) ||
                (0x2600...0x27BF).contains(scalar.value) // misc symbols / dingbats
        }
    }
}

private extension NSString {
    func hasSuffixCharacter(from characterSet: CharacterSet) -> Bool {
        if length == 0 {
            return false
        }
        
        let lastChar = character(at: length - 1)
        
        return (characterSet as NSCharacterSet).characterIsMember(lastChar)
    }
}

// MARK: - sTalk Markdown → HTML (рендер plain-body markdown от ботов)

/// Консервативный markdown→HTML конвертер для plain-text сообщений БЕЗ formatted_body.
/// Включается только при уверенных признаках (`looksLikeMarkdown`), чтобы обычные
/// человеческие тексты («2*3», snake_case, «- забыл купить») не форматировались ложно.
/// Весь ввод HTML-эскейпится ДО конвертации — инъекция тегов из plain-текста невозможна.
enum StalkMarkdown {
    // Прекомпилированные регексы (перф: fromPlain — горячий путь таймлайна)
    private static let detectBold = regex(#"(?<![\w*])\*\*\S(?:[^*\n]*\S)?\*\*(?![\w*])"#)
    private static let detectCode = regex(#"`[^`\n]+`"#)
    private static let detectLink = regex(#"\[[^\]\n]+\]\(https?://[^\s)"]+\)"#)
    private static let detectHeading = regex(#"(^|\n)#{1,6} \S"#)
    private static let detectQuote = regex(#"(^|\n)> \S"#)
    // Список — признак только от ДВУХ подряд строк-пунктов (одиночное «- забыл» — не markdown)
    private static let detectUnorderedList = regex(#"(^|\n)[-*] [^\n]*\n[-*] \S"#)
    private static let detectOrderedList = regex(#"(^|\n)\d{1,3}\. [^\n]*\n\d{1,3}\. \S"#)
    private static let detectStrike = regex(#"~~\S(?:[^~\n]*\S)?~~"#)

    private static let headingPrefix = regex(#"^#{1,6} "#)
    private static let unorderedItem = regex(#"^[-*] "#)
    private static let orderedItem = regex(#"^(\d{1,3})\. "#)

    private static let inlineCode = regex(#"`([^`\n]+)`"#)
    private static let inlineLink = regex(#"\[([^\]\n]+)\]\((https?://[^\s)"]+)\)"#)
    private static let inlineBareURL = regex(#"https?://[^\s]+"#)
    private static let inlineBold = regex(#"(?<![\w*])\*\*(\S(?:[^*\n]*?\S)?)\*\*(?![\w*])"#)
    private static let inlineStrike = regex(#"~~(\S(?:[^~\n]*?\S)?)~~"#)
    private static let inlineEmAsterisk = regex(#"(?<![\w*])\*(\S(?:[^*\n]*?\S)?)\*(?![\w*])"#)
    private static let inlineEmUnderscore = regex(#"(?<![\w])_(\S(?:[^_\n]*?\S)?)_(?![\w])"#)

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression?, _ string: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    /// Уверенные признаки markdown. Одиночные *курсив*/_подчёркивания_ и одиночные
    /// строки-пункты признаком НЕ считаются (ложные срабатывания на человеческих текстах).
    static func looksLikeMarkdown(_ string: String) -> Bool {
        if string.contains("```") { return true }
        if matches(detectBold, string) { return true }
        if matches(detectCode, string) { return true }
        if matches(detectLink, string) { return true }
        if matches(detectHeading, string) { return true }
        if matches(detectQuote, string) { return true }
        if matches(detectUnorderedList, string) { return true }
        if matches(detectOrderedList, string) { return true }
        if matches(detectStrike, string) { return true }
        return false
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func toHTML(_ string: String) -> String {
        let lines = string.components(separatedBy: "\n")
        var html = ""
        var inFence = false
        var fenceBuffer: [String] = []
        var listBuffer: [String] = []
        var listOrdered = false
        var listStartNumber = 1
        var pendingListBlank = false
        var quoteBuffer: [String] = []

        func flushList() {
            guard !listBuffer.isEmpty else { return }
            let items = listBuffer.map { "<li>\($0)</li>" }.joined()
            if listOrdered {
                // Сохраняем реальную нумерацию автора («3. созвон» ≠ «1. созвон»)
                html += listStartNumber == 1 ? "<ol>\(items)</ol>" : "<ol start=\"\(listStartNumber)\">\(items)</ol>"
            } else {
                html += "<ul>\(items)</ul>"
            }
            listBuffer = []
            pendingListBlank = false
        }
        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            html += "<blockquote>" + quoteBuffer.joined(separator: "<br/>") + "</blockquote>"
            quoteBuffer = []
        }
        func appendListItem(ordered: Bool, startNumber: Int, item: String) {
            // Смена типа списка — закрыть предыдущий, номер не терять
            if !listBuffer.isEmpty, listOrdered != ordered {
                flushList()
            }
            if listBuffer.isEmpty {
                listOrdered = ordered
                listStartNumber = startNumber
            }
            listBuffer.append(item)
            pendingListBlank = false
        }
        /// Локальное замыкание (НЕ inout!): flushList + отложенный <br/> за пустую
        /// строку, оборвавшую список. Статик-хелпер с inout падал на эксклюзивности.
        func flushListAndBreak() {
            let hadPending = pendingListBlank
            flushList()
            if hadPending {
                html += "<br/>"
            }
            pendingListBlank = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks: содержимое эскейпится и НЕ обрабатывается инлайн-правилами
            if trimmed.hasPrefix("```"), !inFence {
                let rest = String(trimmed.dropFirst(3))
                // Однострочный fence «```код```» — эмитим сразу, без входа в fence-режим
                if rest.count > 3, rest.hasSuffix("```") {
                    flushList(); flushQuote()
                    html += "<pre><code>" + escape(String(rest.dropLast(3))) + "</code></pre>"
                    continue
                }
                flushList(); flushQuote()
                inFence = true
                continue
            }
            if inFence {
                if trimmed.hasPrefix("```") {
                    html += "<pre><code>" + fenceBuffer.map(escape).joined(separator: "\n") + "</code></pre>"
                    fenceBuffer = []
                    inFence = false
                } else {
                    fenceBuffer.append(line)
                }
                continue
            }

            // Пустая строка внутри списка не рвёт его («1. a\n\n2. b»)
            if trimmed.isEmpty, !listBuffer.isEmpty {
                pendingListBlank = true
                continue
            }

            // Заголовки
            if let match = firstMatch(headingPrefix, in: trimmed) {
                flushListAndBreak(); flushQuote()
                let level = match.range.length - 1
                html += "<h\(level)>" + inline(String(trimmed.dropFirst(match.range.length))) + "</h\(level)>"
                continue
            }
            // Цитаты (группируются)
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushListAndBreak()
                quoteBuffer.append(inline(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))))
                continue
            }
            // Списки (группируются, пустая строка между пунктами допускается)
            if let match = firstMatch(unorderedItem, in: trimmed) {
                flushQuote()
                appendListItem(ordered: false, startNumber: 1, item: inline(String(trimmed.dropFirst(match.range.length))))
                continue
            }
            if let match = firstMatch(orderedItem, in: trimmed) {
                flushQuote()
                let numberText = (trimmed as NSString).substring(with: match.range(at: 1))
                appendListItem(ordered: true, startNumber: Int(numberText) ?? 1, item: inline(String(trimmed.dropFirst(match.range.length))))
                continue
            }
            // Горизонтальная линия
            if trimmed == "---" || trimmed == "***" {
                flushListAndBreak(); flushQuote()
                html += "<hr/>"
                continue
            }

            flushListAndBreak(); flushQuote()
            html += inline(line) + "<br/>"
        }
        // Незакрытый fence — отдаём как код (боты режут сообщения)
        if inFence, !fenceBuffer.isEmpty {
            html += "<pre><code>" + fenceBuffer.map(escape).joined(separator: "\n") + "</code></pre>"
        }
        flushList(); flushQuote()
        return html
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in string: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    // MARK: Inline

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Инлайн-правила поверх HTML-эскейпнутого текста. Код-спаны, markdown-ссылки и голые
    /// URL извлекаются в плейсхолдеры ДО остальных правил — их содержимое не форматируется.
    private static func inline(_ raw: String) -> String {
        // U+FFFC из ввода вычищаем — он служит маркером плейсхолдеров (и смысла в тексте не несёт)
        var text = escape(raw).replacingOccurrences(of: "\u{FFFC}", with: "")
        var tokens: [String] = []

        func stash(_ html: String) -> String {
            tokens.append(html)
            return "\u{FFFC}\(tokens.count - 1)\u{FFFC}"
        }

        // Код-спаны — первыми, их содержимое неприкосновенно
        text = replacing(text, inlineCode) { groups in
            stash("<code>\(groups[1])</code>")
        }
        // Ссылки [текст](http...) — URL защищаем от прочих правил
        text = replacing(text, inlineLink) { groups in
            stash("<a href=\"\(groups[2])\">\(groups[1])</a>")
        }
        // Голые URL — тоже в плейсхолдеры (подчёркивания в пути не должны стать курсивом)
        text = replacing(text, inlineBareURL) { groups in
            stash(groups[0])
        }
        // Жирный / зачёркнутый / курсив (с гардами от snake_case и «2**3»)
        text = replacing(text, inlineBold) { "<strong>\($0[1])</strong>" }
        text = replacing(text, inlineStrike) { "<del>\($0[1])</del>" }
        text = replacing(text, inlineEmAsterisk) { "<em>\($0[1])</em>" }
        text = replacing(text, inlineEmUnderscore) { "<em>\($0[1])</em>" }

        // Восстанавливаем в ОБРАТНОМ порядке: поздние токены (ссылки) могут содержать
        // плейсхолдеры ранних (код-спанов) — reverse-проход закрывает вложенность
        for (index, token) in tokens.enumerated().reversed() {
            text = text.replacingOccurrences(of: "\u{FFFC}\(index)\u{FFFC}", with: token)
        }
        return text
    }

    private static func replacing(_ string: String, _ regex: NSRegularExpression?, with builder: ([String]) -> String) -> String {
        guard let regex else { return string }
        let nsString = string as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: nsString.length)) {
            result += nsString.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            var groups: [String] = []
            for groupIndex in 0..<match.numberOfRanges {
                let range = match.range(at: groupIndex)
                groups.append(range.location == NSNotFound ? "" : nsString.substring(with: range))
            }
            result += builder(groups)
            lastEnd = match.range.location + match.range.length
        }
        result += nsString.substring(from: lastEnd)
        return result
    }
}
