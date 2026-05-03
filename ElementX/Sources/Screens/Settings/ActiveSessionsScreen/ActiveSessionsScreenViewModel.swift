//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import SwiftUI

typealias ActiveSessionsScreenViewModelType = StateStoreViewModelV2<ActiveSessionsScreenViewState, ActiveSessionsScreenViewAction>

class ActiveSessionsScreenViewModel: ActiveSessionsScreenViewModelType, ActiveSessionsScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    private let actionsSubject: PassthroughSubject<ActiveSessionsScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<ActiveSessionsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController

        let state = ActiveSessionsScreenViewState(currentDeviceID: clientProxy.deviceID ?? "",
                                                  bindings: .init())
        super.init(initialViewState: state)

        Task { await reload() }
    }

    override func process(viewAction: ActiveSessionsScreenViewAction) {
        switch viewAction {
        case .reload:
            Task { await reload() }
        case .selectDevice:
            // Phase 1: no-op — placeholder для Phase 3 (Verify flow)
            break
        case .requestSignOut(let deviceID):
            guard let device = state.otherDevices.first(where: { $0.id == deviceID }) else { return }
            state.bindings.alertInfo = AlertInfo(id: .confirmSignOut(deviceID: deviceID, displayName: device.displayName),
                                                 title: "Завершить сессию?",
                                                 message: "Сессия \"\(device.displayName)\" будет завершена. Это устройство выйдет из аккаунта.",
                                                 primaryButton: .init(title: "Завершить", role: .destructive) { [weak self] in
                                                     self?.process(viewAction: .confirmSignOut(deviceID: deviceID))
                                                 },
                                                 secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        case .confirmSignOut(let deviceID):
            Task { await signOut(deviceID: deviceID) }
        }
    }

    // MARK: - Private

    private func reload() async {
        state.isLoading = true
        state.loadError = nil

        let result = await clientProxy.fetchActiveDevices()
        switch result {
        case .success(let devices):
            let now = Date()
            let myID = clientProxy.deviceID ?? ""
            var current: ActiveSessionItem?
            var others: [ActiveSessionItem] = []

            for d in devices {
                let item = ActiveSessionItem(id: d.deviceID,
                                             displayName: d.displayName ?? d.deviceID,
                                             lastSeenRelative: Self.relative(from: d.lastSeenTs, now: now),
                                             lastSeenIP: d.lastSeenIP,
                                             isCurrent: d.deviceID == myID,
                                             trustStatus: d.deviceID == myID ? .current : .unknown)
                if item.isCurrent {
                    current = item
                } else {
                    others.append(item)
                }
            }

            // sort other devices by last_seen desc
            others.sort { l, r in
                (l.lastSeenRelative ?? "") < (r.lastSeenRelative ?? "")
            }

            state.currentDevice = current
            state.otherDevices = others
            state.isLoading = false

        case .failure(let error):
            state.loadError = "\(error)"
            state.isLoading = false
        }
    }

    private func signOut(deviceID: String) async {
        userIndicatorController.submitIndicator(.init(type: .modal, title: "Завершение сессии…", persistent: true))
        defer { userIndicatorController.retractAllIndicators() }

        let result = await clientProxy.signOutDevice(deviceID: deviceID)
        switch result {
        case .success:
            await reload()
        case .failure(let error):
            state.bindings.alertInfo = AlertInfo(id: .signOutError(message: "\(error)"),
                                                 title: "Не удалось завершить сессию",
                                                 message: "\(error)")
        }
    }

    // MARK: - Helpers

    private static func relative(from ts: Int?, now: Date) -> String? {
        guard let ts else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
