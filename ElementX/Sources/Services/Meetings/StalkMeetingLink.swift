// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A meeting reference retains its destination separately from an HTML anchor's label.
enum StalkMeetingLink {
    struct Link: Equatable {
        let code: String
        let url: URL
        let fallback: AttributedString
    }

    enum Part: Equatable {
        case text(AttributedString)
        case meeting(Link)
    }

    /// Legacy whole-message API. Without a session host only relative links are safe.
    static func code(in body: String) -> String? {
        code(in: body, homeserver: nil)
    }

    static func code(in body: String, homeserver: URL?) -> String? {
        link(body.trimmingCharacters(in: .whitespacesAndNewlines), homeserver: homeserver)?.code
    }

    /// Compare authorities (including ports), never suffixes or a host supplied by the message.
    static func link(_ href: String, homeserver: URL?) -> Link? {
        guard !href.contains(where: \.isWhitespace),
              let components = URLComponents(string: href),
              components.user == nil, components.password == nil,
              let code = meetingCode(path: components.percentEncodedPath) else { return nil }
        let origin = homeserver.flatMap(MeetingsService.meetingOrigin)
        if let scheme = components.scheme?.lowercased() {
            if scheme == "vector" {
                guard components.host == "vector", components.port == nil, origin != nil else { return nil }
            } else {
                guard ["http", "https"].contains(scheme), let origin,
                      let destination = components.url.flatMap(MeetingsService.meetingOrigin),
                      destination.host?.lowercased() == origin.host?.lowercased(),
                      destination.port == origin.port else { return nil }
            }
        } else {
            guard components.host == nil, href.hasPrefix("/"), !href.hasPrefix("//") else { return nil }
        }
        let url: URL
        if let origin {
            // Canonical session URL also makes relative and desktop links openable on iOS.
            url = origin.appendingPathComponent("meet/s/\(code)")
        } else {
            guard let relative = URL(string: href) else { return nil }
            url = relative
        }
        return Link(code: code, url: url, fallback: AttributedString(href))
    }

    private static func meetingCode(path: String) -> String? {
        guard let match = path.range(of: #"^/meet/s/([A-Za-z0-9_-]+)/?$"#, options: .regularExpression) else { return nil }
        return String(path[match]).split(separator: "/").last.map(String.init)
    }

    /// Render these parts in order. Text slices preserve their original attributes, links and
    /// whitespace. Formatted content is authoritative: never append a second copy from body.
    static func parts(in body: String, formattedBody: AttributedString? = nil, homeserver: URL?) -> [Part] {
        let source = formattedBody ?? AttributedString(body)
        typealias Candidate = (range: Range<AttributedString.Index>, link: Link)
        var candidates: [Candidate] = []
        var anchorRanges: [Range<AttributedString.Index>] = []
        func isCode(_ range: Range<AttributedString.Index>) -> Bool {
            source[range].runs.contains { $0.codeBlock != nil || $0.inlinePresentationIntent?.contains(.code) == true }
        }
        for (url, range) in source.runs[\.link] {
            guard let url else { continue }
            anchorRanges.append(range)
            guard !isCode(range), let parsed = link(url.absoluteString, homeserver: homeserver) else { continue }
            candidates.append((range, Link(code: parsed.code, url: parsed.url, fallback: AttributedString(source[range]))))
        }
        let text = String(source.characters)
        // Consume complete absolute URLs first so a foreign URL's /meet/s path is never
        // mistaken for a relative local reference. Strip only sentence punctuation.
        let pattern = #"(?:https?://|vector://)[^\s<>\"']+|(?<![\w/:])/meet/s/[^\s<>\"']+"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let stringRange = Range(match.range, in: text) else { continue }
                let token = String(text[stringRange]).replacingOccurrences(of: #"[.,;!\)\]\}]+$"#, with: "", options: .regularExpression)
                let start = source.characters.index(source.startIndex, offsetBy: text[..<stringRange.lowerBound].count)
                let end = source.characters.index(start, offsetBy: token.count)
                let range = start..<end
                guard !anchorRanges.contains(where: { $0.overlaps(range) }), !isCode(range),
                      let parsed = link(token, homeserver: homeserver) else { continue }
                candidates.append((range, Link(code: parsed.code, url: parsed.url, fallback: AttributedString(source[range]))))
            }
        }
        var result: [Part] = []
        var cursor = source.startIndex
        for candidate in candidates.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard candidate.range.lowerBound >= cursor else { continue }
            if cursor < candidate.range.lowerBound {
                result.append(.text(AttributedString(source[cursor..<candidate.range.lowerBound])))
            }
            result.append(.meeting(candidate.link))
            cursor = candidate.range.upperBound
        }
        if cursor < source.endIndex { result.append(.text(AttributedString(source[cursor..<source.endIndex]))) }
        return result
    }
}

enum MeetingLinkPreview: Equatable {
    case available(Meeting)
    case forbidden, missing, expired, unauthenticated, networkError
}

/// Deliberately no metadata cache: each appearance/retry rechecks access. A lookup belongs
/// to its service/session, and never fetches a list or joins a room while previewing.
actor MeetingLookupService {
    private struct RequestKey: Hashable {
        let code: String
        let userID: String?
    }

    private let service: MeetingsService
    private var inFlight: [RequestKey: Task<MeetingLinkPreview, Never>] = [:]
    nonisolated let origin: URL?

    init(service: MeetingsService) {
        self.service = service
        origin = service.meetingAPIOrigin
    }

    func preview(code: String, userID: String? = nil) async -> MeetingLinkPreview {
        let key = RequestKey(code: code, userID: userID)
        if let task = inFlight[key] { return await task.value }

        // An unstructured task lets an individual card disappear without cancelling the
        // lookup shared by other cards. This dictionary belongs to one service instance.
        let task = Task {
            let result = await service.fetchMeetingLinkPreview(code: code, userID: userID)
            // Remove before *any* waiter receives the result. A retry can therefore never
            // reuse a completed task, even if it resumes before the original caller does.
            inFlight[key] = nil
            return result
        }
        inFlight[key] = task
        return await task.value
    }

    /// Compatibility for existing callers which only understand an optional meeting.
    func meeting(code: String) async -> Meeting? {
        guard case let .available(meeting) = await preview(code: code) else { return nil }
        return meeting
    }
}
