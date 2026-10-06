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

    // STALK-968: scheduled/ad-hoc links and their server/session boundaries.
    func testMeetingLinksAndCustomSchemePreserveTheirCode() throws {
        for text in ["https://stalk.implica.ru/meet/s/code_1-A", "https://market.implica.ru/meet/code_1-A", "ru.implica.stalk://stalk.implica.ru/meet/s/code_1-A"] {
            XCTAssertEqual(try appRouteURLParser.route(from: XCTUnwrap(URL(string: text))), .meeting(code: "code_1-A"))
        }
    }

    func testMeetingAssetsAndInvalidCodesAreNotLinks() throws {
        for text in ["https://stalk.implica.ru/meet/app.js", "https://stalk.implica.ru/meet/style.css", "https://stalk.implica.ru/meet/s/a.b", "https://stalk.implica.ru/meet/s/a/extra", "http://stalk.implica.ru/meet/s/code"] {
            XCTAssertNil(try appRouteURLParser.route(from: XCTUnwrap(URL(string: text))))
            XCTAssertNil(try StalkServerLink(url: XCTUnwrap(URL(string: text))))
        }
    }

    func testChatCustomSchemeOpensTheSameRoom() throws {
        let id = "!room:stalk.implica.ru"
        for host in ["stalk.implica.ru", "market.implica.ru"] {
            XCTAssertEqual(try appRouteURLParser.route(from: XCTUnwrap(URL(string: "ru.implica.stalk://\(host)/#/room/\(id)"))), .room(roomID: id, via: []))
        }
    }

    func testMarketingRootAndUnknownHostsAreNotAppRoutes() throws {
        for text in ["https://stalk.implica.ru/", "https://unknown.example/meet/s/code", "https://unknown.example/#/room/!room:stalk.implica.ru"] {
            XCTAssertNil(try appRouteURLParser.route(from: XCTUnwrap(URL(string: text))))
        }
    }

    func testGuestMeetingOpensBrowserButRestoringSessionWaits() throws {
        let link = try XCTUnwrap(try StalkServerLink(url: XCTUnwrap(URL(string: "https://stalk.implica.ru/meet/s/code"))))
        XCTAssertTrue(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: nil, mayRestoreSession: false))
        XCTAssertFalse(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: nil, mayRestoreSession: true))
        XCTAssertFalse(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: "https://stalk.implica.ru", mayRestoreSession: false))
    }

    func testChatCanWaitForLoginAndRejectsWrongServerAfterLogin() throws {
        let link = try XCTUnwrap(try StalkServerLink(url: XCTUnwrap(URL(string: "ru.implica.stalk://market.implica.ru/#/room/!room:market.implica.ru"))))
        XCTAssertFalse(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: nil, mayRestoreSession: false))
        XCTAssertTrue(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: "https://stalk.implica.ru", mayRestoreSession: false))
        XCTAssertFalse(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: "market.implica.ru", mayRestoreSession: false))
        XCTAssertTrue(link.browserURL.absoluteString.contains("no_universal_links=true"))
        XCTAssertEqual(link.browserURL.fragment, "/room/!room:market.implica.ru")
    }

    func testUnknownMeetingHostFallsBackEvenDuringRestore() throws {
        let link = try XCTUnwrap(try StalkServerLink(url: XCTUnwrap(URL(string: "https://unknown.example/meet/code"))))
        XCTAssertTrue(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: nil, mayRestoreSession: true))
    }

    func testBrowserBypassCannotLoopBackIntoApp() throws {
        let url = try XCTUnwrap(URL(string: "https://stalk.implica.ru/meet/code?no_universal_links=true&other=1"))
        XCTAssertNil(appRouteURLParser.route(from: url))
        let link = try XCTUnwrap(StalkServerLink(url: url))
        XCTAssertTrue(link.shouldOpenInBrowser(knownHosts: appSettings.elementWebHosts, homeserver: "stalk.implica.ru", mayRestoreSession: false))
        let query = try XCTUnwrap(URLComponents(url: link.browserURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "no_universal_links" }.count, 1)
        XCTAssertTrue(query.contains(URLQueryItem(name: "other", value: "1")))
    }
}
