//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

public extension Bundle {
    /// The top-level bundle that contains the entire app.
    static var app: Bundle {
        var bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            // Peel off two directory levels - MY_APP.app/PlugIns/MY_APP_EXTENSION.appex
            let url = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let otherBundle = Bundle(url: url) {
                bundle = otherBundle
            }
        }
        return bundle
    }
    
    // MARK: - Localisation

    /// Overrides `Bundle.app.preferredLocalizations` for testing translations
    /// and for the in-app language picker (STMOB-183).
    static var overrideLocalizations: [String]?

    /// Force the whole app's UI language at runtime (STMOB-183).
    ///
    /// `language` is a language code (`"en"`, `"ru"`) or `nil` to follow the system.
    /// Drives both `L10n.tr` (via `overrideLocalizations`) and every raw
    /// `NSLocalizedString` call (by redirecting `Bundle.main`'s localized lookup to a
    /// specific `.lproj` bundle) so custom `stalk_*` strings switch too.
    static func setAppLanguage(_ language: String?) {
        // STMOB-183: resolve the effective language explicitly. For "system" (nil) we do
        // NOT rely on `preferredLocalizations` — with 30+ bundled localizations it can
        // resolve to ru even when the device is English. Instead we read the device's
        // preferred language and clamp it to a supported one (ru/en, default en), then
        // pin that. This guarantees: system EN → English, system RU → Russian,
        // anything else → English. Explicit ru/en from the picker is used as-is.
        let effective = language ?? resolveSystemLanguage()
        overrideLocalizations = [effective]

        if !(Bundle.main is StalkLanguageBundle) {
            object_setClass(Bundle.main, StalkLanguageBundle.self)
        }

        let languageBundle = lprojBundle(for: effective)
        objc_setAssociatedObject(Bundle.main, &StalkLanguageBundle.associatedBundleKey, languageBundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Map the device's preferred language to a supported app language (`ru`/`en`),
    /// defaulting to English for anything else (STMOB-183).
    private static func resolveSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ru") ? "ru" : "en"
    }

    private static let cacheDispatchQueue = DispatchQueue(label: "ru.implica.stalk.localization_bundle_cache")
    private static var cachedBundles = [String: Bundle]()
    
    /// Get an lproj language bundle from the receiver bundle.
    /// - Parameter language: The language to try to load.
    /// - Returns: The lproj bundle if found otherwise nil.
    static func lprojBundle(for language: String) -> Bundle? {
        if let bundle = cachedValue(forKey: language) {
            return bundle
        }
        
        guard let lprojURL = Bundle.app.url(forResource: language, withExtension: "lproj") else {
            return nil
        }
        
        let bundle = Bundle(url: lprojURL)
        
        cacheValue(bundle, forKey: language)
        
        return bundle
    }
    
    // MARK: - Private
    
    private static func cacheValue(_ value: Bundle?, forKey key: String) {
        cacheDispatchQueue.sync {
            cachedBundles[key] = value
        }
    }
    
    private static func cachedValue(forKey key: String) -> Bundle? {
        var result: Bundle?
        cacheDispatchQueue.sync {
            result = cachedBundles[key]
        }

        return result
    }
}

/// `Bundle.main` is reclassed to this at runtime by `Bundle.setAppLanguage(_:)` so that
/// every `NSLocalizedString` lookup can be redirected to a forced-language `.lproj` bundle.
/// When no language is forced the associated bundle is `nil` and lookups fall through to
/// the default system behaviour. (STMOB-183)
private final class StalkLanguageBundle: Bundle, @unchecked Sendable {
    static var associatedBundleKey: UInt8 = 0

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let languageBundle = objc_getAssociatedObject(self, &StalkLanguageBundle.associatedBundleKey) as? Bundle {
            return languageBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
