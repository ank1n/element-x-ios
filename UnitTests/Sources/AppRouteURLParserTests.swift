//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

class AppRouteURLParserTests: XCTestCase {
    var appSettings: AppSettings!
    var appRouteURLParser: AppRouteURLParser!
    
    // STMOB-310: ребрендинг форка (580ba8863) сменил адреса ссылок: звонок —
    // call.stalk.implica.ru и схема URL Type «sTalk Call» из Info.plist,
    // веб-клиент — AppSettings.elementWebHosts. Хосты Element форк не обрабатывает.
    private let callScheme = "ru.implica.stalk.call"
    private let webHost = "stalk.implica.ru"
    
    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        appRouteURLParser = AppRouteURLParser(appSettings: appSettings)
    }
    
    func testElementCallRoutes() {
        guard let url = URL(string: "https://call.stalk.implica.ru/test") else {
            XCTFail("URL invalid")
            return
        }
        
        XCTAssertEqual(appRouteURLParser.route(from: url), AppRoute.genericCallLink(url: url))
        
        guard let customSchemeURL = URL(string: "\(callScheme):/?url=https%3A%2F%2Fcall.stalk.implica.ru%2Ftest") else {
            XCTFail("URL invalid")
            return
        }
        
        XCTAssertEqual(appRouteURLParser.route(from: customSchemeURL), AppRoute.genericCallLink(url: url))
    }
    
    func testCustomDomainUniversalLinkCallRoutes() {
        guard let url = URL(string: "https://somecustomdomain.element.io/test") else {
            XCTFail("URL invalid")
            return
        }
        
        XCTAssertEqual(appRouteURLParser.route(from: url), nil)
    }
    
    func testCustomSchemeLinkCallRoutes() {
        let urlString = "https://somecustomdomain.element.io/test?param=123"
        guard let url = URL(string: urlString) else {
            XCTFail("URL invalid")
            return
        }
        
        guard let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            XCTFail("Could not encode URL string")
            return
        }
        
        guard let customSchemeURL = URL(string: "\(callScheme):/?url=\(encodedURLString)") else {
            XCTFail("URL invalid")
            return
        }
        
        XCTAssertEqual(appRouteURLParser.route(from: customSchemeURL), AppRoute.genericCallLink(url: url))
    }
    
    func testHttpCustomSchemeLinkCallRoutes() {
        guard let customSchemeURL = URL(string: "\(callScheme):/?url=http%3A%2F%2Fcall.stalk.implica.ru%2Ftest") else {
            XCTFail("URL invalid")
            return
        }
        
        XCTAssertEqual(appRouteURLParser.route(from: customSchemeURL), nil)
    }
    
    func testMatrixUserURL() {
        let userID = "@test:matrix.org"
        guard let url = URL(string: "https://matrix.to/#/\(userID)") else {
            XCTFail("Invalid url")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .userProfile(userID: userID))
    }
    
    func testMatrixRoomIdentifierURL() {
        let id = "!abcdefghijklmnopqrstuvwxyz1234567890:matrix.org"
        guard let url = URL(string: "https://matrix.to/#/\(id)") else {
            XCTFail("Invalid url")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .room(roomID: id, via: []))
    }
    
    func testWebRoomIDURL() {
        let id = "!abcdefghijklmnopqrstuvwxyz1234567890:matrix.org"
        guard let url = URL(string: "https://\(webHost)/#/room/\(id)") else {
            XCTFail("URL invalid")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .room(roomID: id, via: []))
    }
    
    func testWebUserIDURL() {
        let id = "@alice:matrix.org"
        guard let url = URL(string: "https://\(webHost)/#/user/\(id)") else {
            XCTFail("URL invalid")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .userProfile(userID: id))
    }
}
