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
                    Text("Это устройство")
                        .compoundListSectionHeader()
                }
            }

            if !context.viewState.otherDevices.isEmpty {
                Section {
                    ForEach(context.viewState.otherDevices) { device in
                        deviceRow(item: device)
                            .swipeActions {
                                Button(role: .destructive) {
                                    context.send(viewAction: .requestSignOut(deviceID: device.id))
                                } label: {
                                    Label("Завершить", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            }
                    }
                } header: {
                    Text("Другие сессии (\(context.viewState.otherDevices.count))")
                        .compoundListSectionHeader()
                }
            }

            if let err = context.viewState.loadError {
                Section {
                    Text("Не удалось загрузить: \(err)")
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .font(.compound.bodyMD)
                }
            }
        }
        .compoundList()
        .navigationTitle("Активные сессии")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            context.send(viewAction: .reload)
        }
        .alert(item: $context.alertInfo)
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
            return .label(title: "Текущая", systemIcon: .checkmarkCircleFill)
        case .verified:
            return .label(title: "Проверено", systemIcon: .lockFill)
        case .unverified:
            return .label(title: "Не проверено", systemIcon: .exclamationmarkTriangle)
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
