//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class ServerConfirmationScreenViewStateTests: XCTestCase {
    func testLoginMessageString() {
        let matrixDotOrgLogin = ServerConfirmationScreenViewState(mode: .confirmation(LoginHomeserver.mockMatrixDotOrg.address),
                                                                  authenticationFlow: .login)
        XCTAssertEqual(matrixDotOrgLogin.message, L10n.screenServerConfirmationMessageLoginMatrixDotOrg, "matrix.org should have a custom message.")
        
        // STMOB-310: ребрендинг STMOB-30 (580ba8863) отдал «свою» подпись серверу stalk.implica.ru вместо element.io.
        let elementDotIoLogin = ServerConfirmationScreenViewState(mode: .confirmation("stalk.implica.ru"),
                                                                  authenticationFlow: .login)
        XCTAssertEqual(elementDotIoLogin.message, L10n.screenServerConfirmationMessageLoginElementDotIo, "stalk.implica.ru should have a custom message.")
        
        let upstreamElementDotIoLogin = ServerConfirmationScreenViewState(mode: .confirmation("element.io"),
                                                                          authenticationFlow: .login)
        XCTAssertEqual(upstreamElementDotIoLogin.message, "", "element.io is an ordinary server in sTalk.")
        
        let otherLogin = ServerConfirmationScreenViewState(mode: .confirmation(LoginHomeserver.mockOIDC.address),
                                                           authenticationFlow: .login)
        XCTAssertEqual(otherLogin.message, "", "Other servers should not show a message.")
        
        let pickerLogin = ServerConfirmationScreenViewState(mode: .picker(["element.io", "matrix.org"]),
                                                            authenticationFlow: .login)
        XCTAssertNil(pickerLogin.message, "The picker mode should not show a message.")
    }
    
    func testRegisterMessageString() {
        let matrixDotOrgRegister = ServerConfirmationScreenViewState(mode: .confirmation(LoginHomeserver.mockMatrixDotOrg.address),
                                                                     authenticationFlow: .register)
        XCTAssertEqual(matrixDotOrgRegister.message, L10n.screenServerConfirmationMessageRegister, "The registration message should always be the same.")
        
        let oidcRegister = ServerConfirmationScreenViewState(mode: .confirmation(LoginHomeserver.mockOIDC.address),
                                                             authenticationFlow: .register)
        XCTAssertEqual(oidcRegister.message, L10n.screenServerConfirmationMessageRegister, "The registration message should always be the same.")
    }
}
