//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ActiveSessionsScreen: View {
    @Bindable var context: ActiveSessionsScreenViewModel.Context

    var body: some View {
        Form {
            if context.viewState.isLoading, context.viewState.currentDevice == nil {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
            }

            if let current = context.viewState.currentDevice {
                Section {
                    deviceRow(item: current)
                } header: {
                    Text(NSLocalizedString("stalk_sessions_this_device", tableName: "Localizable", value: "Это устройство", comment: "Active session trust status: this device"))
                        .compoundListSectionHeader()
                }
            }

            if !context.viewState.otherDevices.isEmpty {
                let filtered = filteredOtherDevices()
                Section {
                    Toggle(isOn: $context.filterActiveLastWeekOnly) {
                        Text(NSLocalizedString("stalk_sessions_active_last_week", tableName: "Localizable", value: "Только активные за неделю", comment: "Filter toggle: only active last week"))
                            .font(.compound.bodyMD)
                    }
                    // STMOB-87: "Завершить все другие" скрыта — Matrix DELETE
                    // endpoint не работает для большинства сессий (MAS compat
                    // sessions возвращают 404 M_UNRECOGNIZED). Bulk cleanup
                    // делается серверным SQL — обратиться к admin.
                } header: {
                    Text(NSLocalizedString("stalk_sessions_filter", tableName: "Localizable", value: "Фильтр", comment: "Filter section header"))
                        .compoundListSectionHeader()
                }

                Section {
                    ForEach(filtered) { device in
                        deviceRow(item: device)
                            .swipeActions {
                                Button(role: .destructive) {
                                    context.send(viewAction: .requestSignOut(deviceID: device.id))
                                } label: {
                                    Label(NSLocalizedString("stalk_sessions_end", tableName: "Localizable", value: "Завершить", comment: "End session button"), systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            }
                    }
                } header: {
                    Text(String(format: NSLocalizedString("stalk_sessions_other_header", tableName: "Localizable", value: "Другие сессии (%1$d из %2$d)", comment: "Other sessions section header: shown/total"), filtered.count, context.viewState.otherDevices.count))
                        .compoundListSectionHeader()
                }
            }

            if let err = context.viewState.loadError {
                Section {
                    Text(String(format: NSLocalizedString("stalk_sessions_load_failed", tableName: "Localizable", value: "Не удалось загрузить: %@", comment: "Failed to load sessions error"), err))
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .font(.compound.bodyMD)
                }
            }
        }
        .compoundList()
        .navigationTitle(NSLocalizedString("stalk_sessions_title", tableName: "Localizable", value: "Активные сессии", comment: "Active sessions screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            context.send(viewAction: .reload)
        }
        .alert(item: $context.alertInfo)
    }

    private func filteredOtherDevices() -> [ActiveSessionItem] {
        guard context.filterActiveLastWeekOnly else {
            return context.viewState.otherDevices
        }
        let now = Date()
        return context.viewState.otherDevices.filter { $0.isActiveLastWeek(now: now) }
    }

    private func deviceRow(item: ActiveSessionItem) -> some View {
        ListRow(label: .default(title: item.displayName,
                                description: deviceDescription(for: item),
                                icon: \.devices),
                details: trustDetails(for: item.trustStatus),
                kind: .label)
    }

    private func deviceDescription(for item: ActiveSessionItem) -> String {
        var parts: [String] = []
        let truncated = String(item.id.suffix(8))
        parts.append("ID: \(truncated)")
        if let lastSeen = item.lastSeenRelative {
            parts.append(lastSeen)
        }
        if let ip = item.lastSeenIP, !ip.isEmpty {
            parts.append(ip)
        }
        return parts.joined(separator: " · ")
    }

    private func trustDetails(for status: ActiveSessionTrustStatus) -> ListRowDetails<Image>? {
        switch status {
        case .current:
            return .label(title: NSLocalizedString("stalk_sessions_current", tableName: "Localizable", value: "Текущая", comment: "Session detail label: current"), systemIcon: .checkmarkCircleFill)
        case .verified:
            return .label(title: NSLocalizedString("stalk_sessions_verified", tableName: "Localizable", value: "Проверено", comment: "Active session trust status: verified"), systemIcon: .lockFill)
        case .unverified:
            return .label(title: NSLocalizedString("stalk_sessions_unverified", tableName: "Localizable", value: "Не проверено", comment: "Active session trust status: unverified"), systemIcon: .exclamationmarkTriangle)
        case .unknown:
            return nil
        }
    }
}

// MARK: - Preview

struct ActiveSessionsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ActiveSessionsScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                         userIndicatorController: UserIndicatorControllerMock())

    static var previews: some View {
        NavigationStack {
            ActiveSessionsScreen(context: viewModel.context)
        }
    }
}
