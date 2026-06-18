//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

#if IS_MAIN_APP
import EmbeddedElementCall
#endif

import Foundation
import SwiftUI

/// Common settings between app and NSE
protocol CommonSettingsProtocol {
    var logLevel: LogLevel { get }
    var traceLogPacks: Set<TraceLogPack> { get }
    var bugReportRageshakeURL: RemotePreference<RageshakeConfiguration> { get }
    
    var enableOnlySignedDeviceIsolationMode: Bool { get }
    var enableKeyShareOnInvite: Bool { get }
    var threadsEnabled: Bool { get }
    var hideQuietNotificationAlerts: Bool { get }
}

/// Store Element specific app settings.
final class AppSettings {
    private enum UserDefaultsKeys: String {
        case lastVersionLaunched
        case seenInvites
        case hasSeenSpacesAnnouncement
        case hasSeenNewSoundBanner
        case acknowledgedHistoryVisibleRooms
        case appLockNumberOfPINAttempts
        case appLockNumberOfBiometricAttempts
        case timelineStyle
        
        case analyticsConsentState
        case hasRunNotificationPermissionsOnboarding
        case hasRunIdentityConfirmationOnboarding
        
        case frequentlyUsedSystemEmojis
        
        case enableNotifications
        case enableInAppNotifications
        case pusherProfileTag
        case logLevel
        case traceLogPacks
        case viewSourceEnabled
        case optimizeMediaUploads
        case appAppearance
        case sharePresence
        
        case elementCallBaseURLOverride
        case recordingAPIBaseURL

        // Feature flags
        case publicSearchEnabled
        case fuzzyRoomListSearchEnabled
        case lowPriorityFilterEnabled
        case enableOnlySignedDeviceIsolationMode
        case enableKeyShareOnInvite
        case knockingEnabled
        case threadsEnabled
        case developerOptionsEnabled
        case linkPreviewsEnabled
        case focusEventOnNotificationTap
        case linkNewDeviceEnabled
        
        // Spaces
        case spaceSettingsEnabled
        case createSpaceEnabled
        
        /// Search
        case recentSearchQueries

        // Doug's tweaks 🔧
        case hideUnreadMessagesBadge
        case hideQuietNotificationAlerts

        /// Interface language override (STMOB-183): nil = follow system
        case appLanguageIdentifier
    }
    
    private static var suiteName: String = InfoPlistReader.main.appGroupIdentifier

    /// UserDefaults to be used on reads and writes.
    private static var store: UserDefaults! = UserDefaults(suiteName: suiteName)
    
    /// Whether or not the app is a development build that isn't in production.
    static var isDevelopmentBuild: Bool = {
        #if DEBUG
        true
        #else
        let apps = ["ru.implica.stalk.nightly", "ru.implica.stalk.pr"]
        return apps.contains(InfoPlistReader.main.baseBundleIdentifier)
        #endif
    }()
        
    static func resetAllSettings() {
        MXLog.warning("Resetting the AppSettings.")
        store.removePersistentDomain(forName: suiteName)
    }
    
    static func resetSessionSpecificSettings() {
        MXLog.warning("Resetting the user session specific AppSettings.")
        store.removeObject(forKey: UserDefaultsKeys.hasRunIdentityConfirmationOnboarding.rawValue)
    }
    
    static func configureWithSuiteName(_ name: String) {
        suiteName = name
        
        guard let userDefaults = UserDefaults(suiteName: name) else {
            fatalError("Fail to load shared UserDefaults")
        }
        
        store = userDefaults
    }
    
    // MARK: - Hooks
    
    // swiftlint:disable:next function_parameter_count
    func override(accountProviders: [String],
                  allowOtherAccountProviders: Bool,
                  hideBrandChrome: Bool,
                  pushGatewayBaseURL: URL,
                  oidcRedirectURL: URL,
                  websiteURL: URL,
                  logoURL: URL,
                  copyrightURL: URL,
                  acceptableUseURL: URL,
                  privacyURL: URL,
                  encryptionURL: URL,
                  deviceVerificationURL: URL,
                  chatBackupDetailsURL: URL,
                  identityPinningViolationDetailsURL: URL,
                  historySharingDetailsURL: URL,
                  elementWebHosts: [String],
                  accountProvisioningHost: String,
                  bugReportApplicationID: String,
                  analyticsTermsURL: URL?,
                  mapTilerConfiguration: MapTilerConfiguration) {
        self.accountProviders = accountProviders
        self.allowOtherAccountProviders = allowOtherAccountProviders
        self.hideBrandChrome = hideBrandChrome
        self.pushGatewayBaseURL = pushGatewayBaseURL
        self.oidcRedirectURL = oidcRedirectURL
        self.websiteURL = websiteURL
        self.logoURL = logoURL
        self.copyrightURL = copyrightURL
        self.acceptableUseURL = acceptableUseURL
        self.privacyURL = privacyURL
        self.encryptionURL = encryptionURL
        self.deviceVerificationURL = deviceVerificationURL
        self.chatBackupDetailsURL = chatBackupDetailsURL
        self.identityPinningViolationDetailsURL = identityPinningViolationDetailsURL
        self.historySharingDetailsURL = historySharingDetailsURL
        self.elementWebHosts = elementWebHosts
        self.accountProvisioningHost = accountProvisioningHost
        self.bugReportApplicationID = bugReportApplicationID
        self.analyticsTermsURL = analyticsTermsURL
        self.mapTilerConfiguration = mapTilerConfiguration
    }
    
    // MARK: - Application
    
    /// The last known version of the app that was launched on this device, which is
    /// used to detect when migrations should be run. When `nil` the app may have been
    /// deleted between runs so should clear data in the shared container and keychain.
    @UserPreference(key: UserDefaultsKeys.lastVersionLaunched, storageType: .userDefaults(store))
    var lastVersionLaunched: String?
        
    /// The Set of room identifiers of invites that the user already saw in the invites list.
    /// This Set is being used to implement badges for unread invites.
    @UserPreference(key: UserDefaultsKeys.seenInvites, defaultValue: [], storageType: .userDefaults(store))
    var seenInvites: Set<String>
    
    @UserPreference(key: UserDefaultsKeys.hasSeenSpacesAnnouncement, defaultValue: false, storageType: .userDefaults(store))
    var hasSeenSpacesAnnouncement
    
    /// Defaults to `true` for new users, and we use a migration to set it to `false` for existing users.
    @UserPreference(key: UserDefaultsKeys.hasSeenNewSoundBanner, defaultValue: true, storageType: .userDefaults(store))
    var hasSeenNewSoundBanner
    
    /// The Set of room identifiers that the user has acknowledged have visible history.
    @UserPreference(key: UserDefaultsKeys.acknowledgedHistoryVisibleRooms, defaultValue: [], storageType: .userDefaults(store))
    var acknowledgedHistoryVisibleRooms: Set<String>

    /// Recent search queries (last 5)
    @UserPreference(key: UserDefaultsKeys.recentSearchQueries, defaultValue: [], storageType: .userDefaults(store))
    var recentSearchQueries: [String]
    
    /// The initial set of account providers shown to the user in the authentication flow.
    ///
    /// Account provider is the friendly term for the server name. It should not contain an `https` prefix and should
    /// match the last part of the user ID. For example `example.com` and not `https://matrix.example.com`.
    private(set) var accountProviders = ["stalk.implica.ru"]
    /// STMOB-202: allow entering any Matrix server. stalk.implica.ru is default and uses the
    /// custom headless-OIDC flow; other servers fall back to the standard Element X login.
    /// Makes the app a general-purpose Matrix client → addresses App Store Guideline 3.2.
    private(set) var allowOtherAccountProviders = true
    /// Whether the components surrounding the app brand/logo should be hidden or not
    private(set) var hideBrandChrome = true
    
    /// The task identifier used for background app refresh. Also used in main target's the Info.plist
    let backgroundAppRefreshTaskIdentifier = "ru.implica.stalk.background.refresh"

    /// A URL where users can go read more about the app.
    private(set) var websiteURL: URL = "https://stalk.implica.ru"
    /// A URL that contains the app's logo that may be used when showing content in a web view.
    private(set) var logoURL: URL = "https://stalk.implica.ru/mobile-icon.png"
    /// A URL that contains that app's copyright notice.
    private(set) var copyrightURL: URL = "https://stalk.implica.ru"
    /// A URL that contains the app's Terms of use.
    private(set) var acceptableUseURL: URL = "https://stalk.implica.ru"
    /// A URL that contains the app's Privacy Policy.
    private(set) var privacyURL: URL = "https://stalk.implica.ru"
    /// A URL where users can go read more about encryption in general.
    private(set) var encryptionURL: URL = "https://stalk.implica.ru"
    /// A URL where users can go read more about device verification..
    private(set) var deviceVerificationURL: URL = "https://stalk.implica.ru"
    /// A URL where users can go read more about the chat backup.
    private(set) var chatBackupDetailsURL: URL = "https://stalk.implica.ru"
    /// A URL where users can go read more about identity pinning violations
    private(set) var identityPinningViolationDetailsURL: URL = "https://stalk.implica.ru"
    /// A URL describing how history sharing works
    private(set) var historySharingDetailsURL: URL = "https://stalk.implica.ru"
    /// Any domains that sTalk web may be hosted on - used for handling links.
    private(set) var elementWebHosts = ["stalk.implica.ru"]
    /// The domain that account provisioning links will be hosted on - used for handling the links.
    private(set) var accountProvisioningHost = "stalk.implica.ru"
    /// The App Store URL for Element Pro, shown to the user when a homeserver requires that app.
    /// **Note:** This property isn't overridable as it in unexpected for forks to come across the error (or to even have a "Pro" app).
    let elementProAppStoreURL: URL = "https://apps.apple.com/app/element-pro-for-work/id6502951615"
    
    @UserPreference(key: UserDefaultsKeys.appAppearance, defaultValue: .system, storageType: .userDefaults(store))
    var appAppearance: AppAppearance
    
    // MARK: - Security
    
    /// The app must be locked with a PIN code as part of the authentication flow.
    let appLockIsMandatory = false
    /// The amount of time the app can remain in the background for without requesting the PIN/TouchID/FaceID.
    let appLockGracePeriod: TimeInterval = 0
    /// Any codes that the user isn't allowed to use for their PIN.
    let appLockPINCodeBlockList = ["0000", "1234"]
    /// The number of attempts the user has made to unlock the app with a PIN code (resets when unlocked).
    @UserPreference(key: UserDefaultsKeys.appLockNumberOfPINAttempts, defaultValue: 0, storageType: .userDefaults(store))
    var appLockNumberOfPINAttempts: Int
    
    // MARK: - Authentication
    
    /// Any pre-defined static client registrations for OIDC issuers.
    /// STMOB-186/STALK-354: stalk uses a STATIC client_id instead of dynamic
    /// registration. Dynamic reg let anyone (incl. upstream Element X) self-declare
    /// an arbitrary client_name and log in to our server with a stock client that
    /// rotates cross-signing identity (autoEnableCrossSigning=true) — this broke
    /// real testers' E2EE keys. With a static client_id the server (MAS) accepts
    /// only our pre-registered app; upstream Element X (client_id io.element) is
    /// rejected at the OAuth layer. The client_id is a Crockford-Base32 ULID
    /// `000000000000000000STAK0APP` (26 chars; "STAK0IOS" is invalid — I/O are
    /// forbidden in Crockford). Issuer key MUST match MAS discovery byte-for-byte
    /// (https://auth.stalk.implica.ru/ with trailing slash). Deploy is synchronized
    /// with Rusty's mas-config `clients:` allowlist (STALK-412) — both must carry
    /// the same client_id + redirect_uri or login breaks for everyone.
    /// NOTE: client_id ≠ device_id. Each login still gets its own per-session
    /// device_id from MAS, so device distinction / active-sessions / E2EE are
    /// unaffected — only the *app* identity is shared, as with any native OAuth app.
    let oidcStaticRegistrations: [URL: String] = [
        "https://id.thirdroom.io/realms/thirdroom": "elementx",
        "https://auth.stalk.implica.ru/": "000000000000000000STAK0APP"
    ]
    /// The redirect URL used for OIDC. Server redirects HTTPS → custom scheme for Personal Team compatibility.
    private(set) var oidcRedirectURL: URL = "https://stalk.implica.ru/oidc/login"
    
    /// STMOB-202/237: OIDC config with a redirect_uri derived from the chosen homeserver,
    /// so login works on any server (not only stalk.implica.ru). Falls back to the default
    /// redirect when no server is given.
    func oidcConfiguration(for homeserverAddress: String? = nil) -> OIDCConfiguration {
        // stalk.implica.ru has a static client registration (STMOB-186) with the HTTPS
        // redirect_uri below. Other servers use dynamic client registration (DCR); the MAS
        // DCR endpoint REQUIRES an HTTPS redirect_uri and rejects a custom scheme with
        // 400 invalid_redirect_uri (verified on mas-stalk:v4 — STMOB-237; the earlier claim
        // that a custom scheme was required was wrong). The server then 302-bounces the HTTPS
        // callback to ru.implica.stalk://oidc/callback, which the app catches via its custom
        // URL scheme (see OIDCAuthenticationPresenter / rewritingCustomSchemeToHTTPS).
        let redirectURI: URL = if let homeserverAddress, !homeserverAddress.isEmpty,
                                  homeserverAddress != "stalk.implica.ru" {
            URL(string: "https://\(homeserverAddress)/oidc/callback") ?? oidcRedirectURL
        } else {
            oidcRedirectURL
        }
        // STMOB-245: the MAS DCR endpoint requires client_uri AND logo_uri/tos_uri/policy_uri to
        // all share the same host as the redirect_uri. These were hardcoded to stalk.implica.ru,
        // so DCR on any other homeserver (e.g. stalk.implica.uz) was rejected first with
        // "missing client_uri" and then "tos_uri/logo_uri/policy_uri not on the same host as the
        // client_uri". Android/Web work because they register with matching-domain URIs. Build all
        // OIDC metadata URIs on the chosen homeserver host for non-default servers.
        let isCustomServer = (homeserverAddress.map { !$0.isEmpty && $0 != "stalk.implica.ru" }) ?? false
        let oidcHost = isCustomServer ? (homeserverAddress ?? "stalk.implica.ru") : "stalk.implica.ru"
        let clientURI = isCustomServer ? (URL(string: "https://\(oidcHost)") ?? websiteURL) : websiteURL
        let logoURI = isCustomServer ? (URL(string: "https://\(oidcHost)/mobile-icon.png") ?? logoURL) : logoURL
        let tosURI = isCustomServer ? (URL(string: "https://\(oidcHost)") ?? acceptableUseURL) : acceptableUseURL
        let policyURI = isCustomServer ? (URL(string: "https://\(oidcHost)") ?? privacyURL) : privacyURL
        return OIDCConfiguration(clientName: InfoPlistReader.main.bundleDisplayName,
                                 redirectURI: redirectURI,
                                 clientURI: clientURI,
                                 logoURI: logoURI,
                                 tosURI: tosURI,
                                 policyURI: policyURI,
                                 staticRegistrations: oidcStaticRegistrations.mapKeys { $0.absoluteString })
    }
    
    /// Whether or not the Create Account button is shown on the start screen.
    ///
    /// **Note:** Setting this to false doesn't prevent someone from creating an account when the selected homeserver's MAS allows registration.
    let showCreateAccountButton = false
    
    // MARK: - Notifications
    
    var pusherAppID: String {
        #if DEBUG
        InfoPlistReader.main.baseBundleIdentifier + ".ios.dev"
        #else
        InfoPlistReader.main.baseBundleIdentifier + ".ios.prod"
        #endif
    }
    
    private(set) var pushGatewayBaseURL: URL = "https://stalk.implica.ru"
    var pushGatewayNotifyEndpoint: URL {
        pushGatewayBaseURL.appending(path: "_matrix/push/v1/notify")
    }
    
    @UserPreference(key: UserDefaultsKeys.enableNotifications, defaultValue: true, storageType: .userDefaults(store))
    var enableNotifications

    @UserPreference(key: UserDefaultsKeys.enableInAppNotifications, defaultValue: true, storageType: .userDefaults(store))
    var enableInAppNotifications
    
    @UserPreference(key: UserDefaultsKeys.hideQuietNotificationAlerts, defaultValue: false, storageType: .userDefaults(store))
    var hideQuietNotificationAlerts

    /// Tag describing which set of device specific rules a pusher executes.
    @UserPreference(key: UserDefaultsKeys.pusherProfileTag, storageType: .userDefaults(store))
    var pusherProfileTag: String?
    
    // MARK: - Logging
        
    @UserPreference(key: UserDefaultsKeys.logLevel, defaultValue: LogLevel.info, storageType: .userDefaults(store))
    var logLevel
    
    @UserPreference(key: UserDefaultsKeys.traceLogPacks, defaultValue: [], storageType: .userDefaults(store))
    var traceLogPacks: Set<TraceLogPack>
    
    // MARK: - Bug report
    
    let bugReportRageshakeURL: RemotePreference<RageshakeConfiguration> = .init(Secrets.rageshakeURL.map { .url(URL(string: $0)!) } ?? .disabled) // swiftlint:disable:this force_unwrapping
    let bugReportSentryURL: URL? = Secrets.sentryDSN.map { URL(string: $0)! } // swiftlint:disable:this force_unwrapping
    let bugReportSentryRustURL: URL? = Secrets.sentryRustDSN.map { URL(string: $0)! } // swiftlint:disable:this force_unwrapping
    /// The name allocated by the bug report server
    private(set) var bugReportApplicationID = "element-x-ios"
    /// The maximum size of the upload request. Default value is just below CloudFlare's max request size.
    let bugReportMaxUploadSize = 50 * 1024 * 1024
    
    // MARK: - Analytics
    
    /// The configuration to use for analytics. Set to `nil` to disable analytics.
    let analyticsConfiguration: AnalyticsConfiguration? = AppSettings.makeAnalyticsConfiguration()
    /// The URL to open with more information about analytics terms. When this is `nil` the "Learn more" link will be hidden.
    private(set) var analyticsTermsURL: URL?
    /// Whether or not there the app is able ask for user consent to enable analytics or sentry reporting.
    var canPromptForAnalytics: Bool {
        analyticsConfiguration != nil || bugReportSentryURL != nil
    }
    
    private static func makeAnalyticsConfiguration() -> AnalyticsConfiguration? {
        guard let host = Secrets.postHogHost, let apiKey = Secrets.postHogAPIKey else { return nil }
        return AnalyticsConfiguration(host: host, apiKey: apiKey)
    }
    
    /// Whether the user has opted in to send analytics.
    @UserPreference(key: UserDefaultsKeys.analyticsConsentState, defaultValue: AnalyticsConsentState.unknown, storageType: .userDefaults(store))
    var analyticsConsentState
    
    @UserPreference(key: UserDefaultsKeys.hasRunNotificationPermissionsOnboarding, defaultValue: false, storageType: .userDefaults(store))
    var hasRunNotificationPermissionsOnboarding
    
    @UserPreference(key: UserDefaultsKeys.hasRunIdentityConfirmationOnboarding, defaultValue: false, storageType: .userDefaults(store))
    var hasRunIdentityConfirmationOnboarding
    
    @UserPreference(key: UserDefaultsKeys.frequentlyUsedSystemEmojis, defaultValue: [FrequentlyUsedEmoji](), storageType: .userDefaults(store))
    var frequentlyUsedSystemEmojis
    
    // MARK: - Home Screen
    
    @UserPreference(key: UserDefaultsKeys.hideUnreadMessagesBadge, defaultValue: false, storageType: .userDefaults(store))
    var hideUnreadMessagesBadge
    
    // MARK: - Room Screen
    
    @UserPreference(key: UserDefaultsKeys.viewSourceEnabled, defaultValue: isDevelopmentBuild, storageType: .userDefaults(store))
    var viewSourceEnabled
    
    @UserPreference(key: UserDefaultsKeys.optimizeMediaUploads, defaultValue: true, storageType: .userDefaults(store))
    var optimizeMediaUploads
    
    /// Whether or not to show a warning on the media caption composer so the user knows
    /// that captions might not be visible to users who are using other Matrix clients.
    let shouldShowMediaCaptionWarning = true

    // MARK: - Element Call
    
    #if IS_MAIN_APP
    // swiftlint:disable:next force_unwrapping
    let elementCallBaseURL: URL = EmbeddedElementCall.appURL!
    #endif
    
    // Analytics disabled for sTalk fork
    let elementCallPosthogAPIHost = ""
    let elementCallPosthogAPIKey = ""
    let elementCallPosthogSentryDSN = ""
    
    @UserPreference(key: UserDefaultsKeys.elementCallBaseURLOverride, defaultValue: nil, storageType: .userDefaults(store))
    var elementCallBaseURLOverride: URL?

    // MARK: - Recording API

    /// The base URL for the call recording API service
    @UserPreference(key: UserDefaultsKeys.recordingAPIBaseURL, defaultValue: URL(string: "https://stalk.implica.ru")!, storageType: .userDefaults(store))
    var recordingAPIBaseURL: URL

    // MARK: - Users
    
    /// Whether to hide the display name and avatar of ignored users as these may contain objectionable content.
    let hideIgnoredUserProfiles = true
    
    // MARK: - Maps
    
    /// maptiler base url
    private(set) var mapTilerConfiguration = MapTilerConfiguration(baseURL: "https://api.maptiler.com/maps",
                                                                   apiKey: Secrets.mapLibreAPIKey,
                                                                   lightStyleID: "9bc819c8-e627-474a-a348-ec144fe3d810",
                                                                   darkStyleID: "dea61faf-292b-4774-9660-58fcef89a7f3")
    
    // MARK: - Presence
    
    @UserPreference(key: UserDefaultsKeys.sharePresence, defaultValue: true, storageType: .userDefaults(store))
    var sharePresence
    
    // MARK: - Feature Flags
    
    /// Spaces
    @UserPreference(key: UserDefaultsKeys.spaceSettingsEnabled, defaultValue: false, storageType: .userDefaults(store))
    var spaceSettingsEnabled
    
    @UserPreference(key: UserDefaultsKeys.createSpaceEnabled, defaultValue: false, storageType: .userDefaults(store))
    var createSpaceEnabled
    
    /// Others
    @UserPreference(key: UserDefaultsKeys.publicSearchEnabled, defaultValue: false, storageType: .userDefaults(store))
    var publicSearchEnabled
    
    @UserPreference(key: UserDefaultsKeys.fuzzyRoomListSearchEnabled, defaultValue: false, storageType: .userDefaults(store))
    var fuzzyRoomListSearchEnabled
    
    @UserPreference(key: UserDefaultsKeys.lowPriorityFilterEnabled, defaultValue: true, storageType: .userDefaults(store))
    var lowPriorityFilterEnabled
    
    /// Configuration to enable only signed device isolation mode for  crypto. In this mode only devices signed by their owner will be considered in e2ee rooms.
    @UserPreference(key: UserDefaultsKeys.enableOnlySignedDeviceIsolationMode, defaultValue: false, storageType: .userDefaults(store))
    var enableOnlySignedDeviceIsolationMode
    
    /// Configuration to enable encrypted history sharing on invite, and accepting keys from inviters.
    @UserPreference(key: UserDefaultsKeys.enableKeyShareOnInvite, defaultValue: false, storageType: .userDefaults(store))
    var enableKeyShareOnInvite
    
    @UserPreference(key: UserDefaultsKeys.knockingEnabled, defaultValue: false, storageType: .userDefaults(store))
    var knockingEnabled
    
    @UserPreference(key: UserDefaultsKeys.threadsEnabled, defaultValue: false, storageType: .userDefaults(store))
    var threadsEnabled
    
    @UserPreference(key: UserDefaultsKeys.focusEventOnNotificationTap, defaultValue: false, storageType: .userDefaults(store))
    var focusEventOnNotificationTap
        
    @UserPreference(key: UserDefaultsKeys.linkPreviewsEnabled, defaultValue: false, storageType: .userDefaults(store))
    var linkPreviewsEnabled
    
    @UserPreference(key: UserDefaultsKeys.linkNewDeviceEnabled, defaultValue: false, storageType: .userDefaults(store))
    var linkNewDeviceEnabled
    
    @UserPreference(key: UserDefaultsKeys.developerOptionsEnabled, defaultValue: isDevelopmentBuild, storageType: .userDefaults(store))
    var developerOptionsEnabled

    /// Interface language override (STMOB-183). `nil` follows the system language;
    /// otherwise a language code such as `"en"` or `"ru"`.
    @UserPreference(key: UserDefaultsKeys.appLanguageIdentifier, defaultValue: nil, storageType: .userDefaults(store))
    var appLanguageIdentifier: String?
}

extension AppSettings: CommonSettingsProtocol { }
