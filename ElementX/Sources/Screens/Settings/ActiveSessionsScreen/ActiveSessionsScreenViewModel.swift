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
                                                 title: NSLocalizedString("stalk_sessions_end_confirm_title", tableName: "Localizable", value: "Завершить сессию?", comment: "End session confirmation title"),
                                                 message: String(format: NSLocalizedString("stalk_sessions_end_confirm_message", tableName: "Localizable", value: "Сессия \"%@\" будет завершена. Это устройство выйдет из аккаунта.", comment: "End session confirmation message"), device.displayName),
                                                 primaryButton: .init(title: NSLocalizedString("stalk_sessions_end", tableName: "Localizable", value: "Завершить", comment: "End session button"), role: .destructive) { [weak self] in
                                                     self?.process(viewAction: .confirmSignOut(deviceID: deviceID))
                                                 },
                                                 secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        case .confirmSignOut(let deviceID):
            Task { await signOut(deviceID: deviceID) }
        case .endAllOthersTap:
            // STMOB-87: bulk delete native — confirmation alert.
            let count = state.otherDevices.count
            state.bindings.alertInfo = AlertInfo(id: .confirmEndAllOthers(count: count),
                                                 title: NSLocalizedString("stalk_sessions_end_all_confirm_title", tableName: "Localizable", value: "Завершить все другие сессии?", comment: "End all other sessions confirmation title"),
                                                 message: String(format: NSLocalizedString("stalk_sessions_end_all_confirm_message", tableName: "Localizable", value: "Будет завершено %d сессий. Это может занять несколько минут.", comment: "End all other sessions confirmation message"), count),
                                                 primaryButton: .init(title: NSLocalizedString("stalk_sessions_end_all", tableName: "Localizable", value: "Завершить все", comment: "End all sessions button"), role: .destructive) { [weak self] in
                                                     self?.process(viewAction: .confirmEndAllOthers)
                                                 },
                                                 secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        case .confirmEndAllOthers:
            Task { await endAllOthers() }
        }
    }

    /// Bulk delete всех "других" сессий через native DELETE loop с прогрессом.
    /// Synapse rate limit ~10 req/sec — делаем concurrent batch по 5 одновременно.
    private func endAllOthers() async {
        let devices = state.otherDevices
        let total = devices.count
        guard total > 0 else { return }

        var done = 0
        var failed = 0
        var firstErrorDetail: String?
        userIndicatorController.submitIndicator(.init(id: "bulkDelete", type: .modal, title: String(format: NSLocalizedString("stalk_sessions_ending_progress", tableName: "Localizable", value: "Завершение 0/%d…", comment: "Bulk delete sessions: initial progress"), total), persistent: true))

        // Concurrent batches по 5 — баланс между скоростью и rate limit Synapse
        let batchSize = 5
        struct DeleteOutcome {
            let deviceID: String
            let success: Bool
            let errorDetail: String?
        }
        for chunkStart in stride(from: 0, to: devices.count, by: batchSize) {
            let chunkEnd = min(chunkStart + batchSize, devices.count)
            let batch = Array(devices[chunkStart..<chunkEnd])
            await withTaskGroup(of: DeleteOutcome.self) { group in
                for device in batch {
                    group.addTask { [clientProxy] in
                        let result = await clientProxy.signOutDevice(deviceID: device.id)
                        switch result {
                        case .success:
                            return DeleteOutcome(deviceID: device.id, success: true, errorDetail: nil)
                        case .failure(let err):
                            let detail: String
                            if case let .httpError(status, body) = err {
                                detail = "HTTP \(status): \(body.prefix(200))"
                            } else {
                                detail = "\(err)"
                            }
                            return DeleteOutcome(deviceID: device.id, success: false, errorDetail: detail)
                        }
                    }
                }
                for await outcome in group {
                    if outcome.success {
                        done += 1
                    } else {
                        failed += 1
                        if firstErrorDetail == nil { firstErrorDetail = "\(outcome.deviceID): \(outcome.errorDetail ?? "?")" }
                    }
                }
            }
            // Update progress between batches
            userIndicatorController.submitIndicator(.init(id: "bulkDelete", type: .modal, title: String(format: NSLocalizedString("stalk_sessions_ended_progress", tableName: "Localizable", value: "Завершено %1$d/%2$d (ошибок %3$d)", comment: "Bulk delete sessions: progress with done/total/failed counts"), done, total, failed), persistent: true))
        }

        userIndicatorController.retractIndicatorWithId("bulkDelete")

        var msg = String(format: NSLocalizedString("stalk_sessions_bulk_result_message", tableName: "Localizable", value: "Завершено успешно: %1$d\nС ошибками: %2$d", comment: "Bulk delete sessions result: succeeded/failed counts"), done, failed)
        if let firstErrorDetail {
            msg += String(format: NSLocalizedString("stalk_sessions_bulk_first_error", tableName: "Localizable", value: "\n\nПервая ошибка:\n%@", comment: "Bulk delete sessions: first error detail"), firstErrorDetail)
        }
        state.bindings.alertInfo = AlertInfo(id: .bulkResult(succeeded: done, failed: failed),
                                             title: NSLocalizedString("stalk_sessions_done", tableName: "Localizable", value: "Готово", comment: "Done alert title"),
                                             message: msg)

        await reload()
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
                                             lastSeenTs: d.lastSeenTs,
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
            // Detailed error for diagnosis (HTTP status + body if available)
            switch error {
            case let .httpError(status, body):
                state.loadError = "HTTP \(status): \(body)"
            default:
                state.loadError = "\(error)"
            }
            state.isLoading = false
        }
    }

    private func signOut(deviceID: String) async {
        // STMOB-87 Phase 2.1: на MAS deployment большинство сессий — это
        // MAS-managed compat sessions (STALK_xxx, web sessions). Прямой
        // DELETE /_matrix/client/v3/devices/{id} для них возвращает 404
        // M_UNRECOGNIZED (Synapse считает что это не его devices).
        //
        // Поэтому первый шаг — открыть MAS sessionEnd URL для конкретного
        // device во встроенном ASWebAuthenticationSession (in-app browser).
        // MAS UI показывает confirmation страницу, юзер подтверждает,
        // session завершается через MAS.
        //
        // Если MAS URL не доступен (deployment не на MAS) — fallback на
        // прямой DELETE с {"auth":{}}.
        if let masURL = await clientProxy.accountURL(action: .deviceDelete(deviceId: deviceID)) {
            actionsSubject.send(.openMASURL(masURL))
            return
        }

        userIndicatorController.submitIndicator(.init(type: .modal, title: NSLocalizedString("stalk_sessions_ending_single", tableName: "Localizable", value: "Завершение сессии…", comment: "Ending single session indicator"), persistent: true))
        defer { userIndicatorController.retractAllIndicators() }

        let result = await clientProxy.signOutDevice(deviceID: deviceID)
        switch result {
        case .success:
            await reload()
        case .failure(let error):
            let detail: String
            switch error {
            case let .httpError(status, body):
                detail = "HTTP \(status)\n\(body)"
            default:
                detail = "\(error)"
            }
            state.bindings.alertInfo = AlertInfo(id: .signOutError(message: detail),
                                                 title: NSLocalizedString("stalk_sessions_end_failed_title", tableName: "Localizable", value: "Не удалось завершить сессию", comment: "Failed to end session alert title"),
                                                 message: detail)
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
