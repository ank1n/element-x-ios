//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class RoomListFiltersStateTests: XCTestCase {
    var appSettings: AppSettings!
    
    var state: RoomListFiltersState!
    // STMOB-310: в sTalk фильтр lowPriority включён по умолчанию (lowPriorityFilterEnabled = true,
    // коммит 5a1ffdba6 — на нём держится «Архив»), поэтому в тестах ниже .lowPriority входит
    // в доступные фильтры. Ветку с выключенным флагом проверяет testWithoutLowPriorityFeature.
    var allCasesWithoutLowPriority = RoomListFilter.allCases.filter { $0 != .lowPriority }
    
    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        state = RoomListFiltersState(appSettings: appSettings)
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    func testInitialState() {
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
    }
    
    func testSetAndUnsetFilters() {
        state.activateFilter(.unreads)
        XCTAssertTrue(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [.unreads])
        XCTAssertEqual(state.availableFilters, [.people, .rooms, .favourites, .lowPriority])
        state.deactivateFilter(.unreads)
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
    }
    
    func testMutuallyExclusiveFilters() {
        state.activateFilter(.people)
        XCTAssertTrue(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [.people])
        XCTAssertEqual(state.availableFilters, [.unreads, .favourites, .lowPriority])
        
        state.deactivateFilter(.people)
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
        
        state.activateFilter(.rooms)
        XCTAssertTrue(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [.rooms])
        XCTAssertEqual(state.availableFilters, [.unreads, .favourites, .lowPriority])
        
        state.activateFilter(.unreads)
        XCTAssertTrue(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [.rooms, .unreads])
        XCTAssertEqual(state.availableFilters, [.favourites, .lowPriority])
    }
    
    func testClearFilters() {
        state.activateFilter(.people)
        XCTAssertEqual(state.activeFilters, [.people])
        XCTAssertEqual(state.availableFilters, [.unreads, .favourites, .lowPriority])

        state.activateFilter(.unreads)
        XCTAssertEqual(state.activeFilters, [.people, .unreads])
        XCTAssertEqual(state.availableFilters, [.favourites, .lowPriority])

        state.activateFilter(.favourites)
        XCTAssertEqual(state.activeFilters, [.people, .unreads, .favourites])
        XCTAssertEqual(state.availableFilters, [])
        
        state.clearFilters()
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
    }
    
    func testOrder() {
        state.activateFilter(.favourites)
        XCTAssertEqual(state.activeFilters, [.favourites])
        XCTAssertEqual(state.availableFilters, [.unreads, .people, .rooms])

        state.deactivateFilter(.favourites)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
        
        state.activateFilter(.rooms)
        XCTAssertEqual(state.activeFilters, [.rooms])
        XCTAssertEqual(state.availableFilters, [.unreads, .favourites, .lowPriority])

        state.activateFilter(.unreads)
        XCTAssertEqual(state.activeFilters, [.rooms, .unreads])
        XCTAssertEqual(state.availableFilters, [.favourites, .lowPriority])
        
        state.deactivateFilter(.unreads)
        XCTAssertEqual(state.activeFilters, [.rooms])
        XCTAssertEqual(state.availableFilters, [.unreads, .favourites, .lowPriority])
    }
    
    // MARK: Low Priority feature flag
    
    /// Don't forget to add .lowPriority into the mix above when enabling the feature.
    func testWithLowPriorityFeature() {
        enableLowPriorityFeature()
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, RoomListFilter.allCases)
        
        state.activateFilter(.lowPriority)
        XCTAssertEqual(state.activeFilters, [.lowPriority])
        XCTAssertEqual(state.availableFilters, [.unreads, .people, .rooms])
    }
    
    /// STMOB-310: флаг выключен (умолчание апстрима) — .lowPriority не предлагается совсем.
    func testWithoutLowPriorityFeature() {
        disableLowPriorityFeature()
        XCTAssertFalse(state.isFiltering)
        XCTAssertEqual(state.activeFilters, [])
        XCTAssertEqual(state.availableFilters, allCasesWithoutLowPriority)
        
        state.activateFilter(.unreads)
        XCTAssertEqual(state.activeFilters, [.unreads])
        XCTAssertEqual(state.availableFilters, [.people, .rooms, .favourites])
        
        state.activateFilter(.rooms)
        XCTAssertEqual(state.activeFilters, [.unreads, .rooms])
        XCTAssertEqual(state.availableFilters, [.favourites])
    }
    
    // MARK: - Helpers
    
    private func enableLowPriorityFeature() {
        appSettings.lowPriorityFilterEnabled = true
        state = RoomListFiltersState(appSettings: appSettings)
    }
    
    private func disableLowPriorityFeature() {
        appSettings.lowPriorityFilterEnabled = false
        state = RoomListFiltersState(appSettings: appSettings)
    }
}
