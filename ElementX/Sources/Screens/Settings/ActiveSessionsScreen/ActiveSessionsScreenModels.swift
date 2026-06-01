//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// MARK: - Coordinator actions

enum ActiveSessionsScreenCoordinatorAction {
    case dismiss
    /// STMOB-87 Phase 2.1: на MAS deployment device deletion работает только
    /// через MAS веб UI (Synapse возвращает 404 M_UNRECOGNIZED для прямого
    /// DELETE /_matrix/client/v3/devices/{id}). Coordinator должен открыть
    /// URL во встроенном ASWebAuthenticationSession (in-app browser).
    case openMASURL(URL)
}

// MARK: - View state

struct ActiveSessionsScreenViewState: BindableState {
    var currentDeviceID: String
    var currentDevice: ActiveSessionItem?
    var otherDevices: [ActiveSessionItem] = []
    var isLoading = false
    var loadError: String?
    var bindings: ActiveSessionsScreenBindings = .init()
}

struct ActiveSessionsScreenBindings {
    var alertInfo: AlertInfo<ActiveSessionsScreenAlertType>?
    /// Filter: показывать только сессии активные за последнюю неделю.
    /// По умолчанию выключен (показываем все). Включается toggle в UI.
    var filterActiveLastWeekOnly = false
}

enum ActiveSessionsScreenAlertType: Hashable {
    case confirmSignOut(deviceID: String, displayName: String)
    case signOutError(message: String)
    case confirmEndAllOthers(count: Int)
    case bulkResult(succeeded: Int, failed: Int)
}

// MARK: - View actions

enum ActiveSessionsScreenViewAction {
    case reload
    case selectDevice(deviceID: String)
    case requestSignOut(deviceID: String)
    case confirmSignOut(deviceID: String)
    /// "Завершить все другие" → confirmation alert
    case endAllOthersTap
    /// Подтверждено — иду в bulk DELETE loop по всем "другим" сессиям.
    case confirmEndAllOthers
}

extension ActiveSessionItem {
    /// Считаем сессию активной если last_seen_ts < 7 дней назад.
    /// Если last_seen unknown — считаем неактивной (стейл).
    func isActiveLastWeek(now: Date) -> Bool {
        guard let lastSeenTs else { return false }
        let date = Date(timeIntervalSince1970: TimeInterval(lastSeenTs) / 1000.0)
        return now.timeIntervalSince(date) < 7 * 24 * 3600
    }
}

// MARK: - Device row item

struct ActiveSessionItem: Identifiable, Hashable {
    let id: String // device_id
    let displayName: String
    let lastSeenRelative: String? // "2 часа назад" / nil if never
    let lastSeenTs: Int? // raw ms timestamp for filtering
    let lastSeenIP: String?
    let isCurrent: Bool
    let trustStatus: ActiveSessionTrustStatus
}

enum ActiveSessionTrustStatus: Hashable {
    case current // this device — special case
    case verified // verified via cross-signing
    case unverified // unknown / not verified
    case unknown // failed to determine

    var localizedTitle: String {
        switch self {
        case .current: return NSLocalizedString("stalk_sessions_this_device", tableName: "Localizable", value: "Это устройство", comment: "Active session trust status: this device")
        case .verified: return NSLocalizedString("stalk_sessions_verified", tableName: "Localizable", value: "Проверено", comment: "Active session trust status: verified")
        case .unverified: return NSLocalizedString("stalk_sessions_unverified", tableName: "Localizable", value: "Не проверено", comment: "Active session trust status: unverified")
        case .unknown: return "—"
        }
    }
}
