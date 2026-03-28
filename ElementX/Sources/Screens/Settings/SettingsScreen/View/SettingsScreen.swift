//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SFSafeSymbols
import SwiftUI

struct SettingsScreen: View {
    let context: SettingsScreenViewModel.Context
    @AppStorage("stalk_design_theme") private var settingsDesignTheme = "cosmos"

    private var isCosmos: Bool {
        settingsDesignTheme == "cosmos"
    }

    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)

    private var shouldHideManageAccountSection: Bool {
        context.viewState.accountProfileURL == nil &&
            context.viewState.accountSessionsListURL == nil &&
            !context.viewState.showBlockedUsers
    }

    var body: some View {
        ZStack {
            if isCosmos {
                LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            Form {
                userSection

                manageMyAppSection

                if !shouldHideManageAccountSection {
                    manageAccountSection
                }

                statusSection

                dndSection

                callsSettingsSection

                appearanceSection

                generalSection

                storageSection

                signOutSection

                if context.viewState.showDeveloperOptions {
                    developerOptionsSection
                }
            }
            .environment(\.defaultMinListRowHeight, 48)
            .scrollContentBackground(.hidden)
            .background(isCosmos ? Color.clear.ignoresSafeArea() : Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Spacer().frame(height: 70)
            }
        }
        .navigationTitle(SL10n.tabSettings)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }
    
    private let accentBlue = StalkTheme.accent

    private var userSection: some View {
        Section {
            if isCosmos {
                ListRow(kind: .custom { cosmosProfileCard })
            } else {
                ListRow(kind: .custom { classicProfileCard })
            }
        }
    }

    private var cosmosProfileCard: some View {
        VStack(spacing: 16) {
            // Avatar with ring
            LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                name: context.viewState.userDisplayName,
                                contentID: context.viewState.userID,
                                avatarSize: .custom(88),
                                mediaProvider: context.mediaProvider)
                .accessibilityHidden(true)
                .overlay(Circle()
                    .stroke(accentBlue.opacity(0.2), lineWidth: 3)
                    .frame(width: 94, height: 94))
                .shadow(color: accentBlue.opacity(0.15), radius: 8, y: 2)

            VStack(spacing: 4) {
                Text(context.viewState.userDisplayName ?? "")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                Text(context.viewState.userID)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // Action buttons
            HStack(spacing: 10) {
                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera")
                            .font(.system(size: 13, weight: .medium))
                        Text(SL10n.settingsPhoto)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(accentBlue)
                    .clipShape(Capsule())
                    .shadow(color: accentBlue.opacity(0.3), radius: 4, y: 2)
                }

                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                        Text(SL10n.settingsName)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(accentBlue)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color(UIColor.systemBackground))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(accentBlue.opacity(0.3), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var classicProfileCard: some View {
        VStack(spacing: 8) {
            LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                name: context.viewState.userDisplayName,
                                contentID: context.viewState.userID,
                                avatarSize: .custom(80),
                                mediaProvider: context.mediaProvider)
                .accessibilityHidden(true)

            Text(context.viewState.userDisplayName ?? "")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.compound.textPrimary)

            Text(context.viewState.userID)
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)

            HStack(spacing: 12) {
                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    Label(SL10n.settingsChangePhoto, systemImage: "camera")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    Label(SL10n.settingsChangeName, systemImage: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
    
    private var manageMyAppSection: some View {
        Section(header: Text(SL10n.settingsAccount)) {
            ListRow(label: .default(title: L10n.screenNotificationSettingsTitle,
                                    icon: \.notifications),
                    kind: .navigationLink {
                        context.send(viewAction: .notifications)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.notifications)
            
            ListRow(label: .default(title: L10n.commonScreenLock,
                                    icon: \.lock),
                    kind: .navigationLink {
                        context.send(viewAction: .appLock)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.screenLock)
            
            switch context.viewState.securitySectionMode {
            case .secureBackup:
                ListRow(label: .default(title: L10n.commonEncryption,
                                        icon: \.key),
                        details: context.viewState.showSecuritySectionBadge ? .icon(securitySectionBadge) : nil,
                        kind: .navigationLink { context.send(viewAction: .secureBackup) })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.secureBackup)
            default:
                EmptyView()
            }
        }
    }
    
    private var manageAccountSection: some View {
        Section(header: Text(SL10n.settingsPrivacy)) {
            if context.viewState.showLinkNewDeviceButton {
                ListRow(label: .default(title: L10n.commonLinkNewDevice,
                                        icon: \.devices),
                        kind: .navigationLink {
                            context.send(viewAction: .linkNewDevice)
                        })
            }
            
            if let url = context.viewState.accountProfileURL {
                ListRow(label: .default(title: L10n.actionManageAccount,
                                        icon: \.userProfile),
                        kind: .button {
                            context.send(viewAction: .manageAccount(url: url))
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.account)
            }
            
            if let url = context.viewState.accountSessionsListURL {
                ListRow(label: .default(title: L10n.actionManageDevices,
                                        icon: \.devices),
                        kind: .button {
                            context.send(viewAction: .manageAccount(url: url))
                        })
            }
            
            if context.viewState.showBlockedUsers {
                ListRow(label: .default(title: L10n.commonBlockedUsers,
                                        icon: \.block),
                        kind: .navigationLink {
                            context.send(viewAction: .blockedUsers)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.blockedUsers)
            }
        }
    }
    
    // MARK: - User Status

    @AppStorage("stalk_user_status_text") private var userStatusText = ""
    @AppStorage("stalk_user_status_preset") private var userStatusPreset = ""

    private var statusSection: some View {
        Section(header: Text(SL10n.statusTitle)) {
            HStack {
                Image(systemName: "face.smiling")
                    .foregroundColor(.orange)
                TextField(SL10n.statusPlaceholder, text: $userStatusText)
                    .font(.system(size: 16))
            }

            // Preset statuses
            ForEach([
                ("checkmark.circle", SL10n.statusAvailable, "available", Color.green),
                ("clock.fill", SL10n.statusBusy, "busy", Color.red),
                ("video.fill", SL10n.statusInMeeting, "meeting", StalkTheme.accent),
                ("airplane", SL10n.statusOnVacation, "vacation", Color.orange)
            ], id: \.2) { icon, title, preset, color in
                Button {
                    userStatusPreset = userStatusPreset == preset ? "" : preset
                    if userStatusPreset == preset { userStatusText = title }
                    else { userStatusText = "" }
                } label: {
                    HStack {
                        Image(systemName: icon)
                            .foregroundColor(color)
                            .frame(width: 24)
                        Text(title)
                            .foregroundColor(.primary)
                        Spacer()
                        if userStatusPreset == preset {
                            Image(systemName: "checkmark")
                                .foregroundColor(StalkTheme.accent)
                        }
                    }
                }
            }

            if !userStatusText.isEmpty {
                Button {
                    userStatusText = ""
                    userStatusPreset = ""
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                            .frame(width: 24)
                        Text(SL10n.statusClear)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - DND Schedule

    @AppStorage("stalk_dnd_enabled") private var dndEnabled = false
    @AppStorage("stalk_dnd_from_hour") private var dndFromHour = 22
    @AppStorage("stalk_dnd_from_minute") private var dndFromMinute = 0
    @AppStorage("stalk_dnd_to_hour") private var dndToHour = 9
    @AppStorage("stalk_dnd_to_minute") private var dndToMinute = 0

    private var dndFromDate: Binding<Date> {
        Binding(get: {
                    Calendar.current.date(from: DateComponents(hour: dndFromHour, minute: dndFromMinute)) ?? Date()
                },
                set: { newDate in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    dndFromHour = comps.hour ?? 22
                    dndFromMinute = comps.minute ?? 0
                })
    }

    private var dndToDate: Binding<Date> {
        Binding(get: {
                    Calendar.current.date(from: DateComponents(hour: dndToHour, minute: dndToMinute)) ?? Date()
                },
                set: { newDate in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    dndToHour = comps.hour ?? 9
                    dndToMinute = comps.minute ?? 0
                })
    }

    private var dndSection: some View {
        Section(header: Text(SL10n.dndTitle)) {
            Toggle(isOn: $dndEnabled) {
                Label {
                    Text(SL10n.dndSchedule)
                } icon: {
                    Image(systemName: "moon.fill")
                        .foregroundColor(.indigo)
                }
            }
            .tint(StalkTheme.accent)

            if dndEnabled {
                DatePicker(SL10n.dndFrom, selection: dndFromDate, displayedComponents: .hourAndMinute)
                DatePicker(SL10n.dndTo, selection: dndToDate, displayedComponents: .hourAndMinute)
            }
        }
    }

    // MARK: - Calls Settings

    @AppStorage("stalk_background_blur_enabled") private var backgroundBlurEnabled = false
    @AppStorage("stalk_noise_suppression_enabled") private var noiseSuppressionEnabled = true
    @AppStorage("stalk_native_calls_enabled") private var nativeCallsEnabled = false

    private var callsSettingsSection: some View {
        Section(header: Text(SL10n.tabCalls)) {
            Toggle(isOn: $backgroundBlurEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SL10n.callBackgroundBlur)
                        Text(SL10n.callBackgroundBlurHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.fill.viewfinder")
                        .foregroundColor(StalkTheme.accent)
                }
            }
            .tint(StalkTheme.accent)

            Toggle(isOn: $nativeCallsEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Нативные звонки")
                        Text("Экспериментально: без WebView, нативный LiveKit SDK")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "phone.badge.waveform")
                        .foregroundColor(.purple)
                }
            }
            .tint(StalkTheme.accent)

            Toggle(isOn: $noiseSuppressionEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SL10n.callNoiseSuppression)
                        Text(SL10n.callNoiseSuppressionHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.orange)
                }
            }
            .tint(StalkTheme.accent)
        }
    }

    private var appearanceSection: some View {
        Section(header: Text(SL10n.settingsAppearance)) {
            Picker(selection: $settingsDesignTheme) {
                Text(SL10n.settingsThemeCosmos).tag("cosmos")
                Text(SL10n.settingsThemeClassic).tag("classic")
            } label: {
                Label {
                    Text(SL10n.settingsThemeDesign)
                } icon: {
                    Image(systemName: "paintbrush.fill")
                        .foregroundColor(.purple)
                }
            }
        }
    }

    private var generalSection: some View {
        Section(header: Text(SL10n.settingsSupport)) {
            ListRow(label: .default(title: L10n.commonAdvancedSettings,
                                    icon: \.settings),
                    kind: .navigationLink {
                        context.send(viewAction: .advancedSettings)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.advancedSettings)
            
            ListRow(label: .default(title: L10n.screenAdvancedSettingsLabs,
                                    icon: \.labs),
                    kind: .navigationLink {
                        context.send(viewAction: .labs)
                    })
            
            ListRow(label: .default(title: L10n.commonAbout,
                                    icon: \.info),
                    kind: .navigationLink {
                        context.send(viewAction: .about)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.about)
            
            if context.viewState.isBugReportServiceEnabled {
                ListRow(label: .default(title: L10n.commonReportAProblem,
                                        icon: \.chatProblem),
                        kind: .navigationLink {
                            context.send(viewAction: .reportBug)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.reportBug)
            }
            
            if context.viewState.showAnalyticsSettings {
                ListRow(label: .default(title: L10n.commonAnalytics,
                                        icon: \.chart),
                        kind: .navigationLink {
                            context.send(viewAction: .analytics)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.analytics)
            }
        }
    }
    
    private var storageSection: some View {
        Section(header: Text(SL10n.settingsStorage)) {
            ListRow(label: .default(title: SL10n.settingsCacheAndData,
                                    icon: \.host),
                    kind: .navigationLink {
                        context.send(viewAction: .cacheAndStorage)
                    })
        }
    }

    private var signOutSection: some View {
        Section {
            ListRow(label: .action(title: L10n.screenSignoutPreferenceItem,
                                   icon: \.signOut,
                                   role: .destructive),
                    kind: .button {
                        context.send(viewAction: .logout)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.logout)
            
            if context.viewState.showAccountDeactivation {
                ListRow(label: .action(title: L10n.actionDeactivateAccount,
                                       icon: \.warning,
                                       role: .destructive),
                        kind: .navigationLink {
                            context.send(viewAction: .deactivateAccount)
                        })
            }
        } footer: {
            if !context.viewState.showDeveloperOptions {
                versionSection
            }
        }
    }
    
    private var developerOptionsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.commonDeveloperOptions,
                                    icon: \.code),
                    kind: .navigationLink {
                        context.send(viewAction: .developerOptions)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.developerOptions)
        } footer: {
            versionSection
        }
    }
    
    private var versionSection: some View {
        VStack(spacing: 0) {
            versionText
                .frame(maxWidth: .infinity)
            
            if let deviceID = context.viewState.deviceID {
                Text(deviceID)
            }
        }
        .compoundListSectionFooter()
        .textSelection(.enabled)
        .padding(.top, 24)
        .onTapGesture(count: 7) {
            context.send(viewAction: .enableDeveloperOptions)
        }
    }
    
    private var versionText: Text {
        Text(L10n.settingsVersionNumber(InfoPlistReader.main.bundleShortVersionString, InfoPlistReader.main.bundleVersion))
    }
    
    @ViewBuilder
    private var securitySectionBadge: some View {
        if context.viewState.showSecuritySectionBadge {
            BadgeView(size: 10)
        }
    }
}

// MARK: - Previews

struct SettingsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let bugReportDisabledViewModel = makeViewModel(isBugReportServiceEnabled: false)
    
    static var previews: some View {
        NavigationStack {
            SettingsScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.accountSessionsListURL).map { $0 != nil })
        .previewDisplayName("Default")
        
        NavigationStack {
            SettingsScreen(context: bugReportDisabledViewModel.context)
        }
        .snapshotPreferences(expect: bugReportDisabledViewModel.context.observe(\.viewState.accountSessionsListURL).map { $0 != nil })
        .previewDisplayName("Bug report disabled")
    }
    
    static func makeViewModel(isBugReportServiceEnabled: Bool = true) -> SettingsScreenViewModel {
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: "@userid:example.com",
                                                                                   deviceID: "AAAAAAAAAAA"))))
        return SettingsScreenViewModel(userSession: userSession,
                                       appSettings: ServiceLocator.shared.settings,
                                       isBugReportServiceEnabled: isBugReportServiceEnabled)
    }
}
