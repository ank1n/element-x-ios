//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum WidgetsListScreenViewAction {
    case showSettings
    case selectWidget(WidgetItem)
    case refresh
}

enum WidgetsListScreenViewModelAction {
    case showSettings
    case openWidget(WidgetItem)
}

struct WidgetsListScreenViewState: BindableState {
    var widgets: [WidgetItem] = []
    var isLoading: Bool = true
    var errorMessage: String?

    // User info for avatar
    var userID: String = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    var bindings = WidgetsListScreenViewStateBindings()
}

struct WidgetsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Widget category for filtering
enum WidgetCategory: String, CaseIterable {
    case productivity = "Продуктивность"
    case communication = "Связь"
    case tools = "Инструменты"

    /// Map API "type" field to category
    init(apiType: String) {
        switch apiType.lowercased() {
        case "smartapp":
            self = .tools
        case "widget":
            self = .tools
        case "communication":
            self = .communication
        case "productivity":
            self = .productivity
        default:
            self = .tools
        }
    }
}

/// Available widget
struct WidgetItem: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let icon: String           // SF Symbol name (fallback)
    let iconURL: URL?          // Remote icon URL (from API)
    let url: String            // Full URL to open widget
    var category: WidgetCategory = .tools

    init(id: String, name: String, description: String, icon: String = "", iconURL: URL? = nil, url: String, category: WidgetCategory = .tools) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.iconURL = iconURL
        self.url = url
        self.category = category
    }
}

// MARK: - Apps API Response Models

/// Response from /apps-api/widgets
struct AppsAPIResponse: Decodable {
    let widgets: [AppsAPIWidget]
    let total: Int
}

/// Single widget from apps-api
struct AppsAPIWidget: Decodable {
    let id: String
    let name: String
    let description: String
    let icon: String           // Relative path: /smartapps/icon.png
    let url: String            // Relative path: /smartapps/weather-bot/
    let type: String           // "smartapp", "widget"
    let enabled: Bool
}
