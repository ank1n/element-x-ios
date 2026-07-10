//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct OIDCConfiguration {
    let clientName: String
    let redirectURI: URL
    let clientURI: URL
    let logoURI: URL
    let tosURI: URL
    let policyURI: URL
    let staticRegistrations: [String: String]
}

#if canImport(MatrixRustSDK)
import MatrixRustSDK

extension OIDCConfiguration {
    /// SDK 26.06.03: the FFI type was renamed OidcConfiguration → OAuthConfiguration (same fields).
    /// We keep the app-side OIDCConfiguration name — the whole fork references it.
    var rustValue: MatrixRustSDK.OAuthConfiguration {
        MatrixRustSDK.OAuthConfiguration(clientName: clientName,
                                         redirectUri: redirectURI.absoluteString,
                                         clientUri: clientURI.absoluteString,
                                         logoUri: logoURI.absoluteString,
                                         tosUri: tosURI.absoluteString,
                                         policyUri: policyURI.absoluteString,
                                         staticRegistrations: staticRegistrations)
    }
}
#endif
