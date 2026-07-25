//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

class ServiceLocator {
    private(set) static var shared = ServiceLocator()
    
    private init() { }
    
    private(set) var userIndicatorController: UserIndicatorControllerProtocol!
    
    func register(userIndicatorController: UserIndicatorControllerProtocol) {
        self.userIndicatorController = userIndicatorController
    }
    
    private(set) var settings: AppSettings!
    
    func register(appSettings: AppSettings) {
        settings = appSettings
    }
    
    private(set) var analytics: AnalyticsService!

    func register(analytics: AnalyticsService) {
        self.analytics = analytics
    }

    private(set) var recordingService: RecordingServiceProtocol?

    func register(recordingService: RecordingServiceProtocol) {
        self.recordingService = recordingService
    }

    /// Creates and registers the recording service.
    ///
    /// STMOB-246: recording-api lives on the session's own homeserver. When a `homeserver` is
    /// provided (after login) the base URL is derived from it so recording works on any server
    /// (stalk.implica.uz / arbitrary) instead of the hardcoded recording-api setting. Falls back
    /// to the configured `recordingAPIBaseURL` when called at launch with no session.
    func setupRecordingService(homeserver: String? = nil) {
        guard let settings else { return }
        let baseURL: URL
        if let homeserver,
           let url = URL(string: homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"),
           let scheme = url.scheme, let host = url.host,
           let derived = URL(string: "\(scheme)://\(host)") {
            baseURL = derived
        } else {
            baseURL = settings.recordingAPIBaseURL
        }
        let service = RecordingService(baseURL: baseURL)
        register(recordingService: service)
    }

    // MARK: - Voice transcription (STMOB-265)

    private(set) var voiceTranscriptionStore: VoiceTranscriptionStore?

    /// Создаём ТОЛЬКО при живой сессии: домен берётся из её homeserver (мультидомен
    /// .ru/.uz), а фолбэк на настроечный URL здесь недопустим — он захардкожен на .ru
    /// и запрос ушёл бы на чужой сервер с нашим токеном.
    @MainActor
    func setupVoiceTranscription(homeserver: String,
                                 userID: String,
                                 accessTokenProvider: @escaping () throws -> String,
                                 forceTokenRefresh: @escaping () async -> Void) {
        guard let url = URL(string: homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"),
              let scheme = url.scheme, let host = url.host,
              let baseURL = URL(string: "\(scheme)://\(host)") else {
            voiceTranscriptionStore = nil
            return
        }
        let service = VoiceTranscriptionService(baseURL: baseURL,
                                                accessTokenProvider: accessTokenProvider,
                                                forceTokenRefresh: forceTokenRefresh)
        voiceTranscriptionStore = VoiceTranscriptionStore(service: service,
                                                          cache: VoiceTranscriptionCache(userID: userID))
    }

    @MainActor
    func teardownVoiceTranscription() {
        voiceTranscriptionStore = nil
    }

    // MARK: - Cache Service

    private(set) var cacheService: STalkCacheService?

    func register(cacheService: STalkCacheService) {
        self.cacheService = cacheService
    }

    func setupCacheService() {
        let service = STalkCacheService()
        register(cacheService: service)
    }

    // MARK: - Local Call History

    private(set) var localCallHistoryService: LocalCallHistoryServiceProtocol!

    func register(localCallHistoryService: LocalCallHistoryServiceProtocol) {
        self.localCallHistoryService = localCallHistoryService
    }

    func setupLocalCallHistoryService() {
        let service = LocalCallHistoryService()
        register(localCallHistoryService: service)
    }

    // MARK: - Bookmark Service

    private(set) var bookmarkService: BookmarkServiceProtocol!

    func register(bookmarkService: BookmarkServiceProtocol) {
        self.bookmarkService = bookmarkService
    }

    func setupBookmarkService() {
        let service = BookmarkService()
        register(bookmarkService: service)
    }
}
