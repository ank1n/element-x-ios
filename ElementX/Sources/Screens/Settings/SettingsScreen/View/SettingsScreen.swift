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
    @State private var showLanguageRestartAlert = false

    /// STMOB-183: применяет выбор языка и просит перезапустить (UIKit-навигация
    /// не перелокализуется на лету — язык вступает в силу при следующем запуске).
    private func selectLanguage(_ identifier: String?) {
        guard identifier != context.viewState.appLanguageIdentifier else { return }
        context.send(viewAction: .setLanguage(identifier))
        showLanguageRestartAlert = true
    }

    private var isCosmos: Bool {
        settingsDesignTheme == "cosmos"
    }

    /// URL of NSE persistent diagnostic log в AppGroup container, если файл существует.
    /// NSE пишет туда события push-обработки; user может расшарить через ShareLink.
    private func nseDiagLogURL() -> URL? {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let url = container
            .appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
            .appending(component: "nse-events.log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

                languageSection

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
        .alert(NSLocalizedString("stalk_settings_language_restart_title", tableName: "Localizable", value: "Перезапустите приложение", comment: "Language change restart alert title"),
               isPresented: $showLanguageRestartAlert) {
            Button(NSLocalizedString("stalk_settings_language_restart_ok", tableName: "Localizable", value: "Понятно", comment: "OK"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("stalk_settings_language_restart_message", tableName: "Localizable", value: "Язык интерфейса изменится после перезапуска приложения.", comment: "Language change restart alert message"))
        }
    }
    
    private let accentBlue = StalkTheme.accent

    // MARK: - Interface language (STMOB-183)

    private var currentLanguageName: String {
        switch context.viewState.appLanguageIdentifier {
        case "ru": return "Русский"
        case "en": return "English"
        default: return NSLocalizedString("stalk_settings_language_system", tableName: "Localizable", value: "Системный", comment: "Interface language: follow system")
        }
    }

    private var languageSection: some View {
        Section(header: Text(NSLocalizedString("stalk_settings_language", tableName: "Localizable", value: "Язык интерфейса", comment: "Interface language setting title"))) {
            Menu {
                Button { selectLanguage(nil) } label: {
                    Label(NSLocalizedString("stalk_settings_language_system", tableName: "Localizable", value: "Системный", comment: "Interface language: follow system"),
                          systemImage: context.viewState.appLanguageIdentifier == nil ? "checkmark" : "globe")
                }
                Button { selectLanguage("ru") } label: {
                    Label("Русский", systemImage: context.viewState.appLanguageIdentifier == "ru" ? "checkmark" : "character.bubble")
                }
                Button { selectLanguage("en") } label: {
                    Label("English", systemImage: context.viewState.appLanguageIdentifier == "en" ? "checkmark" : "character.bubble")
                }
            } label: {
                HStack {
                    Image(systemName: "globe").foregroundColor(StalkTheme.accent).frame(width: 24)
                    Text(currentLanguageName).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundColor(.secondary).font(.system(size: 12))
                }
            }
        }
    }

    /// STALK-586: единый sTalk-стиль строки настроек (цветная SF-иконка, текст,
    /// шеврон) — вместо смеси Compound ListRow (серые монохромные) и наших секций.
    private func stalkSettingsRow(title: String,
                                  systemImage: String,
                                  color: Color,
                                  isDestructive: Bool = false,
                                  showsChevron: Bool = true,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundColor(isDestructive ? .red : color)
                    .frame(width: 24)
                Text(title)
                    .foregroundColor(isDestructive ? .red : .primary)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
        }
    }

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
            stalkSettingsRow(title: L10n.screenNotificationSettingsTitle,
                             systemImage: "bell.badge.fill",
                             color: .red) {
                context.send(viewAction: .notifications)
            }
            .accessibilityIdentifier(A11yIdentifiers.settingsScreen.notifications)
            
            stalkSettingsRow(title: L10n.commonScreenLock,
                             systemImage: "lock.fill",
                             color: .teal) {
                context.send(viewAction: .appLock)
            }
            .accessibilityIdentifier(A11yIdentifiers.settingsScreen.screenLock)
            
            // sTalk: hide encryption settings entry — StalkAutoE2EE manages
            // recovery+backup automatically. Exposing UI lets user reset
            // recovery key or disable backup, breaking the consistent chain
            // (see STALK-210 incident 2026-04-29). Keep state machine but
            // make navigation unreachable.
            EmptyView()
        }
    }
    
    private var manageAccountSection: some View {
        Section(header: Text(SL10n.settingsPrivacy)) {
            if context.viewState.showLinkNewDeviceButton {
                stalkSettingsRow(title: L10n.commonLinkNewDevice,
                                 systemImage: "qrcode",
                                 color: .green) {
                    context.send(viewAction: .linkNewDevice)
                }
            }
            
            if let url = context.viewState.accountProfileURL {
                stalkSettingsRow(title: L10n.actionManageAccount,
                                 systemImage: "person.crop.circle.fill",
                                 color: accentBlue) {
                    context.send(viewAction: .manageAccount(url: url))
                }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.account)
            }
            
            if let url = context.viewState.accountSessionsListURL {
                stalkSettingsRow(title: L10n.actionManageDevices,
                                 systemImage: "laptopcomputer.and.iphone",
                                 color: .indigo) {
                    context.send(viewAction: .manageAccount(url: url))
                }
            }

            // sTalk: STMOB-87 — нативный экран активных сессий (parity с web)
            stalkSettingsRow(title: NSLocalizedString("stalk_sessions_title", tableName: "Localizable", value: "Активные сессии", comment: "Active sessions screen title"),
                             systemImage: "shield.lefthalf.filled",
                             color: .mint) {
                context.send(viewAction: .activeSessions)
            }

            if context.viewState.showBlockedUsers {
                stalkSettingsRow(title: L10n.commonBlockedUsers,
                                 systemImage: "hand.raised.fill",
                                 color: .orange) {
                    context.send(viewAction: .blockedUsers)
                }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.blockedUsers)
            }
        }
    }
    
    // MARK: - User Status

    @AppStorage("stalk_user_status_text") private var userStatusText = ""
    @AppStorage("stalk_user_status_preset") private var userStatusPreset = ""

    private var statusSection: some View {
        // sTalk: STMOB-XX UI compact — статус через Menu picker (одна строка),
        // вместо списка из 4 кнопок + текст-поле + clear. Меньше места занимает.
        let presets: [(icon: String, title: String, key: String, color: Color)] = [
            ("checkmark.circle", SL10n.statusAvailable, "available", .green),
            ("clock.fill", SL10n.statusBusy, "busy", .red),
            ("video.fill", SL10n.statusInMeeting, "meeting", StalkTheme.accent),
            ("airplane", SL10n.statusOnVacation, "vacation", .orange)
        ]
        let current = presets.first(where: { $0.key == userStatusPreset })

        return Section(header: Text(SL10n.statusTitle)) {
            Menu {
                ForEach(presets, id: \.key) { preset in
                    Button {
                        userStatusPreset = preset.key
                        userStatusText = preset.title
                    } label: {
                        Label(preset.title, systemImage: preset.icon)
                    }
                }
                if !userStatusPreset.isEmpty || !userStatusText.isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        userStatusPreset = ""
                        userStatusText = ""
                    } label: {
                        Label(SL10n.statusClear, systemImage: "xmark.circle")
                    }
                }
            } label: {
                HStack {
                    if let current {
                        Image(systemName: current.icon).foregroundColor(current.color).frame(width: 24)
                        Text(current.title).foregroundColor(.primary)
                    } else {
                        Image(systemName: "face.smiling").foregroundColor(.secondary).frame(width: 24)
                        Text(userStatusText.isEmpty ? SL10n.statusPlaceholder : userStatusText)
                            .foregroundColor(userStatusText.isEmpty ? .secondary : .primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundColor(.secondary).font(.system(size: 12))
                }
            }

            // Кастомный текст — одна строка под Menu (не показываем если выбран preset)
            if userStatusPreset.isEmpty {
                HStack {
                    Image(systemName: "pencil").foregroundColor(.secondary).frame(width: 24)
                    TextField(SL10n.statusPlaceholder, text: $userStatusText)
                        .font(.system(size: 16))
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

    /// Режим фона в звонке: off / blur_light / blur_medium / blur_strong / wallpaper
    @AppStorage("stalk_call_background_mode") private var callBackgroundMode = "off"
    @AppStorage("stalk_call_wallpaper_index") private var callWallpaperIndex = 1
    /// NS строго opt-in: дефолт «вкл» менял бы обработку микрофона всем против shipped-звука
    @AppStorage("stalk_noise_suppression_enabled") private var noiseSuppressionEnabled = false
    // Native calls always enabled — no toggle needed

    /// Свич вкл/выкл: off ↔ последний выбранный режим (дефолт — среднее размытие)
    private var callBackgroundEnabledBinding: Binding<Bool> {
        Binding(get: { callBackgroundMode != "off" },
                set: { isOn in
                    if isOn {
                        callBackgroundMode = UserDefaults.standard.string(forKey: "stalk_call_background_last") ?? "blur_medium"
                    } else {
                        UserDefaults.standard.set(callBackgroundMode, forKey: "stalk_call_background_last")
                        callBackgroundMode = "off"
                    }
                })
    }

    private var callsSettingsSection: some View {
        Section(header: Text(SL10n.tabCalls)) {
            Toggle(isOn: callBackgroundEnabledBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SL10n.callBackground)
                        Text(SL10n.callBackgroundHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.fill.viewfinder")
                        .foregroundColor(StalkTheme.accent)
                }
            }
            .tint(StalkTheme.accent)

            if callBackgroundMode != "off" {
                // Одна лента карточек: 3 интенсивности размытия + 6 обоев
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        blurCard(mode: "blur_light", title: SL10n.callBgLightShort, radius: 2)
                        blurCard(mode: "blur_medium", title: SL10n.callBgMediumShort, radius: 4.5)
                        blurCard(mode: "blur_strong", title: SL10n.callBgStrongShort, radius: 8)
                        ForEach(1..<9) { index in
                            wallpaperCard(index: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

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

    /// Карточка интенсивности размытия: мини-сценка «человек чёткий, фон мылится»
    private func blurCard(mode: String, title: String, radius: CGFloat) -> some View {
        let isSelected = callBackgroundMode == mode
        return ZStack(alignment: .bottom) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.45, green: 0.5, blue: 0.75), Color(red: 0.25, green: 0.28, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.65)).frame(width: 16, height: 16).offset(x: -16, y: -30)
                Circle().fill(.yellow.opacity(0.55)).frame(width: 11, height: 11).offset(x: 16, y: -14)
                Circle().fill(.white.opacity(0.45)).frame(width: 9, height: 9).offset(x: 10, y: 12)
            }
            .blur(radius: radius)

            Image(systemName: "person.fill")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.95))
                .offset(y: 6)

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(.bottom, 5)
        }
        .frame(width: 64, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? StalkTheme.accent : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            callBackgroundMode = mode
        }
    }

    /// Карточка обоев (ассеты в namespace `images/`)
    private func wallpaperCard(index: Int) -> some View {
        let isSelected = callBackgroundMode == "wallpaper" && callWallpaperIndex == index
        return Image("images/call_wallpaper_\(index)")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? StalkTheme.accent : .clear, lineWidth: 3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                callWallpaperIndex = index
                callBackgroundMode = "wallpaper"
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
            stalkSettingsRow(title: L10n.commonAdvancedSettings,
                             systemImage: "gearshape.2.fill",
                             color: .gray) {
                context.send(viewAction: .advancedSettings)
            }
            .accessibilityIdentifier(A11yIdentifiers.settingsScreen.advancedSettings)
            
            // sTalk: hidden Labs (опасные эксперимент-флаги для пользователей).
            // sTalk: hidden About (STMOB-94) — Legal Information ссылки сейчас все ведут на
            // https://stalk.implica.ru (placeholder), пользы пока нет. Вернём когда появятся
            // реальные Privacy Policy / Terms / Copyright.

            if context.viewState.isBugReportServiceEnabled {
                stalkSettingsRow(title: L10n.commonReportAProblem,
                                 systemImage: "exclamationmark.bubble.fill",
                                 color: .orange) {
                    context.send(viewAction: .reportBug)
                }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.reportBug)
            }

            // STMOB-111: NSE diag log — только если включены developer options
            // (toggle 7 тапами по версии в самом низу Settings).
            if context.viewState.showDeveloperOptions, let nseLogURL = nseDiagLogURL() {
                ListRow(kind: .custom {
                    ShareLink(item: nseLogURL) {
                        HStack(spacing: 16) {
                            CompoundIcon(\.shareIos)
                                .foregroundStyle(.compound.iconPrimary)
                            Text("Share NSE diagnostic log")
                                .foregroundStyle(.compound.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                })
            }
            
            // sTalk: hidden Analytics (не показываем тогглы аналитики пользователю —
            // sTalk не собирает аналитику в production).
        }
    }
    
    private var storageSection: some View {
        Section(header: Text(SL10n.settingsStorage)) {
            stalkSettingsRow(title: SL10n.settingsCacheAndData,
                             systemImage: "internaldrive.fill",
                             color: .blue) {
                context.send(viewAction: .cacheAndStorage)
            }
        }
    }

    private var signOutSection: some View {
        Section {
            stalkSettingsRow(title: L10n.screenSignoutPreferenceItem,
                             systemImage: "rectangle.portrait.and.arrow.right",
                             color: .red,
                             isDestructive: true,
                             showsChevron: false) {
                context.send(viewAction: .logout)
            }
            .accessibilityIdentifier(A11yIdentifiers.settingsScreen.logout)
            
            if context.viewState.showAccountDeactivation {
                stalkSettingsRow(title: L10n.actionDeactivateAccount,
                                 systemImage: "person.crop.circle.badge.xmark",
                                 color: .red,
                                 isDestructive: true) {
                    context.send(viewAction: .deactivateAccount)
                }
            }
        } footer: {
            if !context.viewState.showDeveloperOptions {
                versionSection
            }
        }
    }
    
    private var developerOptionsSection: some View {
        Section {
            stalkSettingsRow(title: L10n.commonDeveloperOptions,
                             systemImage: "hammer.fill",
                             color: .gray) {
                context.send(viewAction: .developerOptions)
            }
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
