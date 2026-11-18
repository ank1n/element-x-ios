//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
@testable import ElementX
import XCTest

/// Карты OpenFreeMap (решение dp 18.11): стили без ключа, стиль сервера из well-known приоритетнее.
final class MapTilerURLBuilderTests: XCTestCase {
    func testOpenFreeMapStyles() {
        let builder: MapTilerURLBuilderProtocol = MapTilerConfiguration.openFreeMap
        
        XCTAssertEqual(builder.interactiveMapURL(for: .light), "https://tiles.openfreemap.org/styles/liberty")
        XCTAssertEqual(builder.interactiveMapURL(for: .dark), "https://tiles.openfreemap.org/styles/dark")
    }
    
    func testServerStyleOverridesBothSchemes() {
        let serverStyleURL: URL = "https://tiles.example.org/styles/custom/style.json"
        let builder: MapTilerURLBuilderProtocol = MapTilerConfiguration.withServerStyleURL(serverStyleURL)
        
        XCTAssertEqual(builder.interactiveMapURL(for: .light), serverStyleURL)
        XCTAssertEqual(builder.interactiveMapURL(for: .dark), serverStyleURL)
    }
    
    func testMissingServerStyleFallsBackToOpenFreeMap() {
        let builder: MapTilerURLBuilderProtocol = MapTilerConfiguration.withServerStyleURL(nil)
        
        XCTAssertEqual(builder.interactiveMapURL(for: .light), MapTilerConfiguration.openFreeMap.lightStyleURL)
        XCTAssertEqual(builder.interactiveMapURL(for: .dark), MapTilerConfiguration.openFreeMap.darkStyleURL)
    }
    
    func testAppSettingsUseOpenFreeMapAndServerStyle() {
        let appSettings = AppSettings()
        XCTAssertEqual(appSettings.mapTilerConfiguration.lightStyleURL, MapTilerConfiguration.openFreeMap.lightStyleURL)
        
        let serverStyleURL: URL = "https://tiles.example.org/styles/custom/style.json"
        appSettings.applyServerMapStyleURL(serverStyleURL)
        XCTAssertEqual(appSettings.mapTilerConfiguration.darkStyleURL, serverStyleURL)
        
        appSettings.applyServerMapStyleURL(nil)
        XCTAssertEqual(appSettings.mapTilerConfiguration.darkStyleURL, MapTilerConfiguration.openFreeMap.darkStyleURL)
    }
}
