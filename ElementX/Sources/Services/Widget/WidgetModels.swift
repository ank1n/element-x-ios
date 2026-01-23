//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Matrix Widget Model

struct MatrixWidget: Identifiable, Codable, Equatable {
    /// The state_key of the widget event (unique identifier)
    let id: String
    /// The widget type (e.g., "customwidget", "jitsi", "etherpad")
    let type: String
    /// Display name of the widget
    let name: String
    /// URL template for the widget
    let url: String
    /// User ID of the widget creator
    let creatorUserId: String
    /// Whether to wait for iframe to load
    let waitForIframeLoad: Bool?
    /// Additional widget data
    let data: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case url
        case creatorUserId
        case waitForIframeLoad
        case data
    }
}

// MARK: - Widget State Event Types

enum WidgetStateEventType: String, CaseIterable {
    case mWidget = "m.widget"
    case imVectorWidget = "im.vector.modular.widgets"
}

// MARK: - Widget Event Content

struct WidgetEventContent: Codable {
    let type: String?
    let name: String?
    let url: String?
    let creatorUserId: String?
    let waitForIframeLoad: Bool?
    let data: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case url
        case creatorUserId = "creatorUserId"
        case waitForIframeLoad
        case data
    }
}

// MARK: - AnyCodableValue for arbitrary JSON

enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }

        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
            return
        }

        if let dictionary = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dictionary)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

// MARK: - Widget URL Processing

extension MatrixWidget {
    /// Process widget URL by substituting template variables
    func processedURL(roomId: String, userId: String, displayName: String? = nil, avatarURL: String? = nil) -> URL? {
        var urlString = url

        // Replace Matrix template variables
        urlString = urlString.replacingOccurrences(of: "$matrix_room_id", with: roomId)
        urlString = urlString.replacingOccurrences(of: "$matrix_user_id", with: userId)

        if let displayName {
            urlString = urlString.replacingOccurrences(of: "$matrix_display_name", with: displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? displayName)
        }

        if let avatarURL {
            urlString = urlString.replacingOccurrences(of: "$matrix_avatar_url", with: avatarURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? avatarURL)
        }

        // Also support URL-encoded versions
        urlString = urlString.replacingOccurrences(of: "%24matrix_room_id", with: roomId)
        urlString = urlString.replacingOccurrences(of: "%24matrix_user_id", with: userId)

        return URL(string: urlString)
    }
}
