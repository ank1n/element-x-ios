//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import os.log

/// Persistent diagnostic log shared между всеми targets (NSE, ElementX, ShareExt, etc)
/// через один файл в AppGroup container.
/// Цель — debug push/CallKit flow без подключения iPhone к Mac.
/// File: <AppGroup>/Library/Caches/nse-events.log, ring buffer ~500 KB.
/// User шарит через Settings → Share NSE diagnostic log.
/// Размещён в InfoPlistReader.swift потому что этот файл уже включён во все targets.
enum DiagLog {
    private static let queue = DispatchQueue(label: "ru.implica.stalk.diag", qos: .utility)
    private static let maxBytes = 500_000
    private static let logger = OSLog(subsystem: "ru.implica.stalk", category: "DiagLog")

    static var fileURL: URL? {
        let groupID = InfoPlistReader.main.appGroupIdentifier
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = container.appending(component: "Library", directoryHint: .isDirectory)
            .appending(component: "Caches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(component: "nse-events.log")
    }

    static func write(_ tag: String, _ message: String) {
        guard let url = fileURL else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        let line = "[\(f.string(from: Date()))] \(tag) \(message)\n"
        queue.async {
            do {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int, size > maxBytes {
                    try? FileManager.default.removeItem(at: url)
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    let h = try FileHandle(forWritingTo: url)
                    try h.seekToEnd()
                    if let d = line.data(using: .utf8) { try h.write(contentsOf: d) }
                    try h.close()
                } else {
                    try line.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                os_log(.error, log: logger, "DiagLog write failed: %{public}@", error.localizedDescription)
            }
        }
    }
}

struct InfoPlistReader {
    private enum Keys {
        static let appGroupIdentifier = "appGroupIdentifier"
        static let baseBundleIdentifier = "baseBundleIdentifier"
        static let keychainAccessGroupIdentifier = "keychainAccessGroupIdentifier"
        static let bundleShortVersion = "CFBundleShortVersionString"
        static let bundleDisplayName = "CFBundleDisplayName"
        static let productionAppName = "productionAppName"
        static let utExportedTypeDeclarationsKey = "UTExportedTypeDeclarations"
        static let utTypeIdentifierKey = "UTTypeIdentifier"
        static let utDescriptionKey = "UTTypeDescription"
        
        static let bundleURLTypes = "CFBundleURLTypes"
        static let bundleURLName = "CFBundleURLName"
        static let bundleURLSchemes = "CFBundleURLSchemes"
    }
    
    private enum Values {
        static let mentionPills = "Mention Pills"
    }

    /// Info.plist reader on the bundle object that contains the current executable.
    static let main = InfoPlistReader(bundle: .main)

    /// Info.plist reader on the bundle object that contains the main app executable.
    static let app = InfoPlistReader(bundle: .app)

    private let bundle: Bundle

    /// Initializer
    /// - Parameter bundle: bundle to read values from
    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// App group identifier set in Info.plist of the target
    var appGroupIdentifier: String {
        infoPlistValue(forKey: Keys.appGroupIdentifier)
    }

    /// Base bundle identifier set in Info.plist of the target
    var baseBundleIdentifier: String {
        infoPlistValue(forKey: Keys.baseBundleIdentifier)
    }
    
    /// Keychain access group identifier set in Info.plist of the target
    var keychainAccessGroupIdentifier: String {
        infoPlistValue(forKey: Keys.keychainAccessGroupIdentifier)
    }

    /// Bundle executable of the target
    var bundleExecutable: String {
        infoPlistValue(forKey: kCFBundleExecutableKey as String)
    }

    /// Bundle identifier of the target
    var bundleIdentifier: String {
        infoPlistValue(forKey: kCFBundleIdentifierKey as String)
    }

    /// Bundle short version string of the target
    var bundleShortVersionString: String {
        infoPlistValue(forKey: Keys.bundleShortVersion)
    }

    /// Bundle version of the target
    var bundleVersion: String {
        infoPlistValue(forKey: kCFBundleVersionKey as String)
    }

    /// Bundle display name of the target
    var bundleDisplayName: String {
        infoPlistValue(forKey: Keys.bundleDisplayName)
    }
    
    /// The name of the non-X app when it becomes production ready.
    var productionAppName: String {
        infoPlistValue(forKey: Keys.productionAppName)
    }
    
    // MARK: - Custom App Scheme
    
    var appScheme: String {
        customSchemeForName("Application")
    }
    
    var elementCallScheme: String {
        // sTalk: URL Type renamed "Element Call" → "sTalk Call" during fork rebranding
        // (see CFBundleURLTypes in Info.plist). Hardcoded upstream name was crashing
        // any openURL with fatalError on first tap (Legal Information / chat links).
        customSchemeForName("sTalk Call")
    }
    
    // MARK: - Mention Pills

    /// Mention Pills UTType
    var pillsUTType: String {
        let exportedTypes: [[String: Any]] = infoPlistValue(forKey: Keys.utExportedTypeDeclarationsKey)
        guard let mentionPills = exportedTypes.first(where: { $0[Keys.utDescriptionKey] as? String == Values.mentionPills }),
              let utType = mentionPills[Keys.utTypeIdentifierKey] as? String else {
            fatalError("Add properly \(Values.mentionPills) exported type into your target's Info.plist")
        }
        
        // The pills type is formed from the baseBundleIdentifier, however weirdly, if a fork sets that with a value
        // that includes one or more uppercase characters, pill rendering breaks. If we lowercase the type identifier
        // the bug is fixed, even though the value used in the fork's Info.plist no longer matches the value returned.
        // Maybe in the future the fork should set their own PILLS_UT_TYPE_IDENTIFIER, but for now this works 🤷‍♂️🤷‍♂️🤷‍♂️
        return utType.lowercased()
    }
    
    // MARK: - Private
    
    private func infoPlistValue<T>(forKey key: String) -> T {
        guard let result = bundle.object(forInfoDictionaryKey: key) as? T else {
            fatalError("Add \(key) into your target's Info.plst")
        }
        return result
    }
    
    private func customSchemeForName(_ name: String) -> String {
        let urlTypes: [[String: Any]] = infoPlistValue(forKey: Keys.bundleURLTypes)
        
        guard let urlType = urlTypes.first(where: { $0[Keys.bundleURLName] as? String == name }),
              let urlSchemes = urlType[Keys.bundleURLSchemes] as? [String],
              let scheme = urlSchemes.first else {
            fatalError("Invalid custom application scheme configuration")
        }
        
        return scheme
    }
}
