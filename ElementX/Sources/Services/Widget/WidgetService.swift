//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

// MARK: - Protocol

protocol WidgetServiceProtocol {
    /// Publisher for widget changes
    var widgetsPublisher: AnyPublisher<[MatrixWidget], Never> { get }

    /// Get current widgets in the room
    func getWidgets() async -> [MatrixWidget]

    /// Refresh widgets from room state
    func refreshWidgets() async
}

// MARK: - Implementation

class WidgetService: WidgetServiceProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let widgetsSubject = CurrentValueSubject<[MatrixWidget], Never>([])

    var widgetsPublisher: AnyPublisher<[MatrixWidget], Never> {
        widgetsSubject.eraseToAnyPublisher()
    }

    init(roomProxy: JoinedRoomProxyProtocol) {
        self.roomProxy = roomProxy
    }

    // MARK: - Public Methods

    func getWidgets() async -> [MatrixWidget] {
        await refreshWidgets()
        return widgetsSubject.value
    }

    func refreshWidgets() async {
        // TODO: Implement actual Matrix SDK state event fetching
        // For now, provide demo widget to show UI works
        // In production, this should fetch m.widget and im.vector.modular.widgets state events

        let demoWidgets = [
            MatrixWidget(
                id: "stats_widget_1",
                type: "customwidget",
                name: "Статистика",
                url: "https://stats.market.implica.ru/?roomId=$matrix_room_id&userId=$matrix_user_id",
                creatorUserId: roomProxy.ownUserID,
                waitForIframeLoad: true,
                data: nil
            )
        ]

        widgetsSubject.send(demoWidgets)
        MXLog.info("Loaded \(demoWidgets.count) demo widgets")
    }

    // MARK: - Private Methods

    private func fetchStateEvents(type: String) async throws -> [[String: Any]] {
        // This would use the Matrix SDK to fetch state events
        // Implementation depends on the SDK's API
        // For now, return empty array - actual implementation needs SDK integration
        return []
    }

    private func parseWidget(from stateEvent: [String: Any]) -> MatrixWidget? {
        guard let stateKey = stateEvent["state_key"] as? String,
              let content = stateEvent["content"] as? [String: Any],
              let url = content["url"] as? String,
              !url.isEmpty else {
            return nil
        }

        // Empty content means widget was removed
        if content.isEmpty {
            return nil
        }

        let type = content["type"] as? String ?? "unknown"
        let name = content["name"] as? String ?? "Widget"
        let creatorUserId = content["creatorUserId"] as? String ?? ""
        let waitForIframeLoad = content["waitForIframeLoad"] as? Bool

        // Parse data field
        var widgetData: [String: AnyCodableValue]?
        if let data = content["data"] as? [String: Any] {
            widgetData = parseDataDictionary(data)
        }

        return MatrixWidget(
            id: stateKey,
            type: type,
            name: name,
            url: url,
            creatorUserId: creatorUserId,
            waitForIframeLoad: waitForIframeLoad,
            data: widgetData
        )
    }

    private func parseDataDictionary(_ dict: [String: Any]) -> [String: AnyCodableValue] {
        var result: [String: AnyCodableValue] = [:]

        for (key, value) in dict {
            if let stringValue = value as? String {
                result[key] = .string(stringValue)
            } else if let intValue = value as? Int {
                result[key] = .int(intValue)
            } else if let doubleValue = value as? Double {
                result[key] = .double(doubleValue)
            } else if let boolValue = value as? Bool {
                result[key] = .bool(boolValue)
            } else if let arrayValue = value as? [Any] {
                result[key] = .array(parseArray(arrayValue))
            } else if let dictValue = value as? [String: Any] {
                result[key] = .dictionary(parseDataDictionary(dictValue))
            }
        }

        return result
    }

    private func parseArray(_ array: [Any]) -> [AnyCodableValue] {
        array.compactMap { value -> AnyCodableValue? in
            if let stringValue = value as? String {
                return .string(stringValue)
            } else if let intValue = value as? Int {
                return .int(intValue)
            } else if let doubleValue = value as? Double {
                return .double(doubleValue)
            } else if let boolValue = value as? Bool {
                return .bool(boolValue)
            } else if let dictValue = value as? [String: Any] {
                return .dictionary(parseDataDictionary(dictValue))
            }
            return nil
        }
    }
}

// MARK: - Mock for Testing

class WidgetServiceMock: WidgetServiceProtocol {
    private let widgetsSubject = CurrentValueSubject<[MatrixWidget], Never>([])

    var widgetsPublisher: AnyPublisher<[MatrixWidget], Never> {
        widgetsSubject.eraseToAnyPublisher()
    }

    var mockWidgets: [MatrixWidget] = []

    func getWidgets() async -> [MatrixWidget] {
        mockWidgets
    }

    func refreshWidgets() async {
        widgetsSubject.send(mockWidgets)
    }

    func simulateWidgets(_ widgets: [MatrixWidget]) {
        mockWidgets = widgets
        widgetsSubject.send(widgets)
    }
}
