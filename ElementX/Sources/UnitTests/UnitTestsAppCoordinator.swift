//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

class UnitTestsAppCoordinator: AppCoordinatorProtocol {
    private let targetConfiguration: Target.ConfigurationResult
    static let targetRageshakeURL = RemotePreference<RageshakeConfiguration>(.url("bugs.example.com/submit"))
    static let targetAppHooks = AppHooks()
    /// STMOB-310: отдельный набор UserDefaults для истории звонков в юнит-тестах.
    static let callHistorySuiteName = "ru.implica.stalk.unittests.callhistory"
    
    let windowManager: SecureWindowManagerProtocol
    
    init(appDelegate: AppDelegate) {
        windowManager = WindowManager(appDelegate: appDelegate)
        ServiceLocator.shared.register(userIndicatorController: UserIndicatorControllerMock.default)
        
        AppSettings.configureWithSuiteName("ru.implica.stalk.unittests")
        AppSettings.resetAllSettings()
        ServiceLocator.shared.register(appSettings: AppSettings())
        
        let analyticsClient = AnalyticsClientMock()
        analyticsClient.isRunning = false
        ServiceLocator.shared.register(analytics: AnalyticsService(client: analyticsClient,
                                                                   appSettings: ServiceLocator.shared.settings))
        
        // STMOB-310: localCallHistoryService в ServiceLocator неявно развёрнутый, в проде его
        // регистрирует AppCoordinator.setupServiceLocator. Без него вкладка «Звонки»
        // (CallsListScreenViewModel) роняла весь тестовый процесс в UserSessionFlowCoordinatorTests.
        // Хранилище — свой набор UserDefaults, очищаемый при старте: тесты не читают и не портят
        // историю звонков приложения на том же симуляторе. Остальные sTalk-сервисы
        // (recordingService, cacheService, bookmarkService, voiceTranscriptionStore) опциональны
        // и намеренно не регистрируются — с ними меняется поведение экранов в других тестах.
        guard let callHistoryDefaults = UserDefaults(suiteName: Self.callHistorySuiteName) else {
            fatalError("STMOB-310: не удалось открыть UserDefaults для истории звонков")
        }
        callHistoryDefaults.removePersistentDomain(forName: Self.callHistorySuiteName)
        ServiceLocator.shared.register(localCallHistoryService: LocalCallHistoryService(userDefaults: callHistoryDefaults))
        
        // As the tests take advantage of Rust's ability to redirect the log files, there is
        // often some debris left from the previous run, so we wipe the entire directory.
        // This is an NOT an advised way to delete logs in production, `Tracing.deleteLogFiles`
        // exists for that purpose.
        try? FileManager.default.removeItem(at: .appGroupLogsDirectory)
        targetConfiguration = Target.tests.configure(logLevel: .info,
                                                     traceLogPacks: [],
                                                     sentryURL: nil,
                                                     rageshakeURL: Self.targetRageshakeURL,
                                                     appHooks: Self.targetAppHooks)
    }
    
    func start() { }
    
    func toPresentable() -> AnyView {
        AnyView(ProgressView("Running Unit Tests"))
    }
    
    func handlePotentialPhishingAttempt(url: URL, openURLAction: @escaping (URL) -> Void) -> Bool {
        fatalError("Not implemented.")
    }
    
    func handleDeepLink(_ url: URL, isExternalURL: Bool) -> Bool {
        fatalError("Not implemented.")
    }
    
    func handleUserActivity(_ activity: NSUserActivity) {
        fatalError("Not implemented.")
    }
}
