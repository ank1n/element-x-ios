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
}

enum ActiveSessionsScreenAlertType: Hashable {
    case confirmSignOut(deviceID: String, displayName: String)
    case signOutError(message: String)
}

// MARK: - View actions

enum ActiveSessionsScreenViewAction {
    case reload
    case selectDevice(deviceID: String)
    case requestSignOut(deviceID: String)
    case confirmSignOut(deviceID: String)
}

// MARK: - Device row item

struct ActiveSessionItem: Identifiable, Hashable {
    let id: String // device_id
    let displayName: String
    let lastSeenRelative: String? // "2 часа назад" / nil if never
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
        case .current: return "Это устройство"
        case .verified: return "Проверено"
        case .unverified: return "Не проверено"
        case .unknown: return "—"
        }
    }
}
