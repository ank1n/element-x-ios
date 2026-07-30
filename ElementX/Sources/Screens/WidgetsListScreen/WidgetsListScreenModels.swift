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
    var isLoading = true
    var errorMessage: String?

    // User info for avatar
    var userID = ""
    var userDisplayName: String?
    var userAvatarURL: URL?
    var requiresExtraAccountSetup = false

    var bindings = WidgetsListScreenViewStateBindings()
}

struct WidgetsListScreenViewStateBindings {
    var searchQuery = ""
}

/// Widget category for filtering
enum WidgetCategory: String, CaseIterable, Codable {
    case productivity
    case communication
    case tools

    var displayName: String {
        switch self {
        case .productivity: return SL10n.appsProductivity
        case .communication: return SL10n.appsCommunication
        case .tools: return SL10n.appsTools
        }
    }

    /// Map API "category" field to local category
    init(apiCategory: String) {
        switch apiCategory.lowercased() {
        case "productivity":
            self = .productivity
        case "communication":
            self = .communication
        case "tools":
            self = .tools
        default:
            self = .tools
        }
    }
}

/// Available widget/app
struct WidgetItem: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let description: String
    let icon: String // SF Symbol name
    let iconURL: URL? // Remote icon URL (from API)
    let url: String // Full URL to open widget (empty for builtin)
    let apiURL: String? // Backend API URL for builtin apps
    let type: String // "builtin", "widget", "smartapp"
    var category: WidgetCategory = .tools

    var isBuiltin: Bool {
        type == "builtin"
    }

    // MARK: - Айлок (STMOB-274)

    /// Идентификатор записи приложения. Должен совпасть с тем, что Molly заведёт в apps-api.
    static let ailockAppID = "ailock"

    /// Агент по умолчанию: то же значение, что стоит в конфиге веб-клиента (`defaultAgentId`).
    /// Когда apps-api начнёт отдавать агента, значение приедет оттуда.
    static let ailockAgentID = "925edd2e-e9e5-44bb-b2e9-d40ae299b381"

    /// Локальная запись приложения — нужна, пока Айлока нет в реестре apps-api.
    /// Подмешивается только если door-2 реально развёрнут на текущем домене,
    /// и уступает серверной записи с тем же id (дублей не будет).
    static var ailock: WidgetItem {
        WidgetItem(id: ailockAppID,
                   name: SL10n.ailockTitle,
                   description: SL10n.ailockDescription,
                   icon: "sparkles",
                   url: "",
                   apiURL: nil,
                   type: "builtin",
                   category: .tools)
    }

    init(id: String, name: String, description: String, icon: String = "", iconURL: URL? = nil, url: String, apiURL: String? = nil, type: String = "widget", category: WidgetCategory = .tools) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.iconURL = iconURL
        self.url = url
        self.apiURL = apiURL
        self.type = type
        self.category = category
    }
}

// MARK: - Apps API v3 Response Models

/// Response from /apps-api/apps
struct AppsAPIResponse: Decodable {
    let apps: [AppsAPIApp]
    let total: Int
}

/// Single app from apps-api v3
struct AppsAPIApp: Decodable {
    let id: String
    let name: String
    let description: String
    let icon: AppsAPIIcon // { "sf": "calendar", "material": "event" }
    let url: String // Full URL or empty for builtin
    let apiUrl: String? // Backend API URL for builtin apps (e.g. meetings)
    let category: String // "productivity", "tools"
    let type: String // "builtin", "widget", "smartapp"
    let enabled: Bool
}

/// Icon object with platform-specific names
struct AppsAPIIcon: Decodable {
    let sf: String? // SF Symbols name (iOS)
    let material: String? // Material Icons name (Android)
}
