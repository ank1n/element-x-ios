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

    /// Агента клиент НЕ назначает: по контракту door-2 (подтверждено Shelly 31.07)
    /// gateway подставляет свой server-side default. Хардкод здесь однажды разошёлся бы
    /// с сервером и увёл бы мобильных пользователей к чужому агенту.
    static let ailockAgentID: String? = nil

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

    // MARK: - Диск (STMOB-275)

    /// Идентификатор записи приложения. Должен совпасть с тем, что заведут в apps-api.
    /// ВАЖНО: тип обязан быть `builtin` — веб-виджеты отрезаются фильтром выше после
    /// реджекта Apple по гайдлайну 2.1(a) на сборке 193.
    static let filesAppID = "files"

    /// Локальная запись, пока «Диска» нет в реестре apps-api. Уступает серверной
    /// записи с тем же id, поэтому дублей не будет.
    static var files: WidgetItem {
        WidgetItem(id: filesAppID,
                   name: NSLocalizedString("stalk_disk_title", tableName: "Localizable", value: "Диск", comment: "Disk app name"),
                   description: NSLocalizedString("stalk_disk_app_description", tableName: "Localizable",
                                                  value: "Файлы из чатов и документы", comment: "Disk app description"),
                   icon: "folder.fill",
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
    /// Логотип приложения на уровне записи — второе место, где его разумно ждать.
    /// Необязательное: реестр его пока не отдаёт (STMOB-277).
    let iconUrl: String?
}

/// Icon object with platform-specific names
///
/// STMOB-277: реестр отдаёт `sf`/`material`/`emoji`/`web`, то есть глиф на iOS и
/// эмодзи в вебе — из-за этого одно и то же приложение выглядит по-разному на двух
/// клиентах. Настоящий логотип должен приходить ссылкой; поля для него пока нет.
/// Читаем ЛЮБОЕ из правдоподобных имён, чтобы иконки подхватились в день, когда
/// Molly заведёт поле, и без релиза клиента — тот же приём, что с `attachment_id`
/// у Айлока.
struct AppsAPIIcon: Decodable {
    let sf: String? // SF Symbols name (iOS)
    let material: String? // Material Icons name (Android)
    let emoji: String?
    let web: String?

    private let url: String?
    private let png: String?
    private let svg: String?
    private let image: String?

    /// СЫРОЙ путь логотипа, если реестр его отдаёт. Именно строка: путь бывает
    /// ОТНОСИТЕЛЬНЫМ (/apps-api/icons/x.png), и URL(string:) собирает из него
    /// объект без хоста — AsyncImage такой молча не грузит, клиент падал на
    /// запасной глиф (скрин dp 02.08 «какого хера иконки сменил»). Достройку до
    /// домена сессии делает вью-модель — у модели домена нет.
    var logoPath: String? {
        for candidate in [url, png, svg, image] {
            if let candidate, !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }
}
