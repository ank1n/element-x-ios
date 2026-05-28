//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

extension ClientBuilder {
    /// A helper method that applies the common builder modifiers needed for the app.
    static func baseBuilder(setupEncryption: Bool = true,
                            httpProxy: String? = nil,
                            slidingSync: ClientBuilderSlidingSync,
                            sessionDelegate: ClientSessionDelegate,
                            appHooks: AppHooks,
                            enableOnlySignedDeviceIsolationMode: Bool,
                            enableKeyShareOnInvite: Bool,
                            requestTimeout: UInt64? = 30000,
                            maxRequestRetryTime: UInt64? = nil,
                            threadsEnabled: Bool) -> ClientBuilder {
        var builder = ClientBuilder()
            .crossProcessStoreLocksHolderName(holderName: InfoPlistReader.main.bundleIdentifier)
            .enableOidcRefreshLock()
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
            .threadsEnabled(enabled: threadsEnabled, threadSubscriptions: threadsEnabled)
            .requestConfig(config: .init(retryLimit: 0,
                                         timeout: requestTimeout,
                                         maxConcurrentRequests: nil,
                                         maxRetryTime: maxRequestRetryTime))
        
        builder = switch slidingSync {
        case .restored: builder
        case .discover: builder.slidingSyncVersionBuilder(versionBuilder: .discoverNative)
        }
        
        if setupEncryption {
            builder = builder
                // STMOB-180 build 182: autoEnableCrossSigning DISABLED.
                // Раньше SDK автоматически bootstrap'ил cross-signing identity
                // при первом sync если detect missing self-sig для current device.
                // У Алёны (build 26.04.05): после `confirmRecoveryKey` SUCCESS
                // (existing master восстановлен) → app в background → первый sync
                // → SDK detect missing self-sig для нового deviceID →
                // autoEnableCrossSigning bootstraps fresh identity → destructive
                // override existing keys → `m.secret_storage.default_key={}`,
                // recovery_state=disabled. Симметричная история с
                // autoEnableBackups (STMOB-144 build 172).
                //
                // Cross-signing setup теперь делается вручную в
                // bootstrapRecoveryForFirstDevice / selfVerifyDevice — ПОСЛЕ
                // wait_verified loop и ТОЛЬКО если recovery+backup отсутствуют
                // на сервере (true first-time setup). Existing identity
                // preserved через confirmRecoveryKey без rotation.
                .autoEnableCrossSigning(autoEnableCrossSigning: false)
                // sTalk: oneShot — после получения recovery key (через 4S confirmRecoveryKey)
                // SDK сам скачивает ВСЕ room keys из backup. Это нужно для StalkAutoE2EE
                // flow когда identity restored через server-stored recovery key —
                // user не должен ловить «Ожидание ключа расшифровки» при открытии чата.
                // С .afterDecryptionFailure (default) iPhone show'ит «Ожидание ключа»
                // потому что backup state остаётся .unknown пока user не откроет message.
                .backupDownloadStrategy(backupDownloadStrategy: .oneShot)
                .enableShareHistoryOnInvite(enableShareHistoryOnInvite: enableKeyShareOnInvite)
                // STMOB-144 build 172: autoEnableBackups DISABLED.
                // Раньше при login SDK сразу создавал backup до того как cross-signing
                // master был ready локально → backup signed device key (не master) →
                // backup unrecoverable (см. dp.bondar архив 129-141, окончательно
                // потеряно). Теперь backup enable вручную в bootstrapRecoveryForFirstDevice
                // ПОСЛЕ wait_verified loop — гарантирует signed master.
                .autoEnableBackups(autoEnableBackups: false)
        }

        // Set recipient strategy and trust requirement even if `setupEncryption` is false to ensure messages
        // from insecure devices aren't displayed in push notifications.
        // See https://github.com/element-hq/element-x-ios/issues/4702.
        // sTalk: use AllDevices recipient strategy regardless of isolation mode.
        // identityBasedStrategy / errorOnVerifiedUserProblem refuse to encrypt
        // when a verified user has unsigned devices (zombies from DB churn,
        // stale sessions etc.) — making it impossible to send messages until
        // the device list is perfectly clean. AllDevices encrypts to whatever
        // device list /keys/query returns; unsigned zombies just receive the
        // m.room_key but can't decrypt anything anyway. See STALK-210.
        builder = builder
            .roomKeyRecipientStrategy(strategy: .allDevices)
            .decryptionSettings(decryptionSettings: .init(senderDeviceTrustRequirement:
                enableOnlySignedDeviceIsolationMode ? .crossSignedOrLegacy : .untrusted))
        
        if let httpProxy {
            builder = builder.proxy(url: httpProxy)
        }
        
        return appHooks.clientBuilderHook.configure(builder)
    }
}

enum ClientBuilderSlidingSync {
    /// Sliding sync will be configured when restoring the Session.
    case restored
    /// Sliding sync must be discovered whilst building the session.
    case discover
}
