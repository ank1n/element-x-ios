//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@preconcurrency import Combine
import CryptoKit
import Foundation
import MatrixRustSDK
import OrderedCollections
import UIKit

class ClientProxy: ClientProxyProtocol {
    private let client: ClientProtocol
    private let networkMonitor: NetworkMonitorProtocol
    private let appSettings: AppSettings
    
    let mediaLoader: MediaLoaderProtocol
    private let clientQueue: DispatchQueue
    
    private var roomListService: RoomListService
    // periphery: ignore - only for retain
    private var roomListStateUpdateTaskHandle: TaskHandle?
    // periphery: ignore - only for retain
    private var roomListStateLoadingStateUpdateTaskHandle: TaskHandle?

    private var syncService: SyncService
    // periphery: ignore - only for retain
    private var syncServiceStateUpdateTaskHandle: TaskHandle?
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var ignoredUsersListenerTaskHandle: TaskHandle?
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var verificationStateListenerTaskHandle: TaskHandle?
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var sendQueueListenerTaskHandle: TaskHandle?
    
    // periphery:ignore - required for instance retention in the rust codebase
    private var mediaPreviewConfigListenerTaskHandle: TaskHandle?
    
    private var delegateHandle: TaskHandle?
    
    // These following summary providers both operate on the same allRooms() list but
    // can apply their own filtering and pagination
    private(set) var roomSummaryProvider: RoomSummaryProviderProtocol
    private(set) var alternateRoomSummaryProvider: RoomSummaryProviderProtocol
    
    private(set) var staticRoomSummaryProvider: StaticRoomSummaryProviderProtocol
    
    let notificationSettings: NotificationSettingsProxyProtocol

    let secureBackupController: SecureBackupControllerProtocol
    
    private(set) var sessionVerificationController: SessionVerificationControllerProxyProtocol?
    
    let spaceService: SpaceServiceProxyProtocol
    
    private static var roomCreationPowerLevelOverrides: PowerLevels {
        .init(usersDefault: nil,
              eventsDefault: nil,
              stateDefault: nil,
              ban: nil,
              kick: nil,
              redact: nil,
              invite: Int32(0),
              notifications: nil,
              users: [:],
              events: [
                  "m.call.member": Int32(0),
                  "org.matrix.msc3401.call.member": Int32(0)
              ])
    }
    
    private static var knockingRoomCreationPowerLevelOverrides: PowerLevels {
        .init(usersDefault: nil,
              eventsDefault: nil,
              stateDefault: nil,
              ban: nil,
              kick: nil,
              redact: nil,
              invite: Int32(50),
              notifications: nil,
              users: [:],
              events: [
                  "m.call.member": Int32(0),
                  "org.matrix.msc3401.call.member": Int32(0)
              ])
    }
    
    private static var standardSpaceCreationPowerLevelOverrides: PowerLevels {
        .init(usersDefault: nil,
              eventsDefault: Int32(100),
              stateDefault: nil,
              ban: nil,
              kick: nil,
              redact: nil,
              invite: Int32(50),
              notifications: nil,
              users: [:],
              events: [:])
    }
    
    private static var publicSpaceCreationPowerLevelOverrides: PowerLevels {
        .init(usersDefault: nil,
              eventsDefault: Int32(100),
              stateDefault: nil,
              ban: nil,
              kick: nil,
              redact: nil,
              invite: Int32(0),
              notifications: nil,
              users: [:],
              events: [:])
    }

    private var loadCachedAvatarURLTask: Task<Void, Never>?
    private let userAvatarURLSubject = CurrentValueSubject<URL?, Never>(nil)
    var userAvatarURLPublisher: CurrentValuePublisher<URL?, Never> {
        userAvatarURLSubject.asCurrentValuePublisher()
    }
    
    private let userDisplayNameSubject = CurrentValueSubject<String?, Never>(nil)
    var userDisplayNamePublisher: CurrentValuePublisher<String?, Never> {
        userDisplayNameSubject.asCurrentValuePublisher()
    }
    
    private let ignoredUsersSubject = CurrentValueSubject<[String]?, Never>(nil)
    var ignoredUsersPublisher: CurrentValuePublisher<[String]?, Never> {
        ignoredUsersSubject
            .asCurrentValuePublisher()
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    /// Will be `true` whilst the app cleans up and forces a logout. Prevents the sync service from restarting
    /// before the client is released which ends up running in a loop. This is a workaround until the sync service
    /// can tell us *what* error occurred so we can handle restarts more gracefully.
    private var hasEncounteredAuthError = false
    
    deinit {
        stopSync { [delegateHandle] in
            // The delegate handle needs to be cancelled always after the sync stops
            delegateHandle?.cancel()
        }
    }
    
    private let actionsSubject = PassthroughSubject<ClientProxyAction, Never>()
    var actionsPublisher: AnyPublisher<ClientProxyAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private let loadingStateSubject = CurrentValueSubject<ClientProxyLoadingState, Never>(.notLoading)
    var loadingStatePublisher: CurrentValuePublisher<ClientProxyLoadingState, Never> {
        loadingStateSubject.asCurrentValuePublisher()
    }
    
    private let verificationStateSubject = CurrentValueSubject<SessionVerificationState, Never>(.unknown)
    var verificationStatePublisher: CurrentValuePublisher<SessionVerificationState, Never> {
        verificationStateSubject.asCurrentValuePublisher()
    }
    
    private let homeserverReachabilitySubject = CurrentValueSubject<NetworkMonitorReachability, Never>(.reachable)
    var homeserverReachabilityPublisher: CurrentValuePublisher<NetworkMonitorReachability, Never> {
        homeserverReachabilitySubject.asCurrentValuePublisher()
    }
    
    private let timelineMediaVisibilitySubject = CurrentValueSubject<TimelineMediaVisibility, Never>(.always)
    var timelineMediaVisibilityPublisher: CurrentValuePublisher<TimelineMediaVisibility, Never> {
        timelineMediaVisibilitySubject.asCurrentValuePublisher()
    }
    
    private let hideInviteAvatarsSubject = CurrentValueSubject<Bool, Never>(false)
    var hideInviteAvatarsPublisher: CurrentValuePublisher<Bool, Never> {
        hideInviteAvatarsSubject.asCurrentValuePublisher()
    }
    
    var roomsToAwait: Set<String> = []
    
    private let sendQueueStatusSubject = CurrentValueSubject<Bool, Never>(false)
    
    init(client: ClientProtocol,
         networkMonitor: NetworkMonitorProtocol,
         appSettings: AppSettings) async throws {
        self.client = client
        self.networkMonitor = networkMonitor
        self.appSettings = appSettings
        
        clientQueue = .init(label: "ClientProxyQueue", attributes: .concurrent)
        
        mediaLoader = MediaLoader(client: client)
        
        notificationSettings = await NotificationSettingsProxy(notificationSettings: client.getNotificationSettings())
        
        secureBackupController = SecureBackupController(encryption: client.encryption())
        
        spaceService = await SpaceServiceProxy(spaceService: client.spaceService())
        
        let configuredAppService = try await ClientProxyServices(client: client,
                                                                 actionsSubject: actionsSubject,
                                                                 notificationSettings: notificationSettings,
                                                                 appSettings: appSettings)
        
        syncService = configuredAppService.syncService
        roomListService = configuredAppService.roomListService
        roomSummaryProvider = configuredAppService.roomSummaryProvider
        alternateRoomSummaryProvider = configuredAppService.alternateRoomSummaryProvider
        staticRoomSummaryProvider = configuredAppService.staticRoomSummaryProvider
        
        syncServiceStateUpdateTaskHandle = createSyncServiceStateObserver(syncService)
        roomListStateUpdateTaskHandle = createRoomListServiceObserver(roomListService)
        roomListStateLoadingStateUpdateTaskHandle = createRoomListLoadingStateUpdateObserver(roomListService)
                
        delegateHandle = try client.setDelegate(delegate: ClientDelegateWrapper { [weak self] isSoftLogout in
            self?.hasEncounteredAuthError = true
            self?.actionsSubject.send(.receivedAuthError(isSoftLogout: isSoftLogout))
        })
        
        try await client.setUtdDelegate(utdDelegate: ClientDecryptionErrorDelegate(actionsSubject: actionsSubject))
        
        networkMonitor.reachabilityPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachability in
                if reachability == .reachable {
                    self?.startSync()
                }
            }
            .store(in: &cancellables)

        loadUserAvatarURLFromCache()
        
        ignoredUsersListenerTaskHandle = client.subscribeToIgnoredUsers(listener: SDKListener { [weak self] ignoredUsers in
            self?.ignoredUsersSubject.send(ignoredUsers)
        })
        
        await updateVerificationState(client.encryption().verificationState())
        
        verificationStateListenerTaskHandle = client.encryption().verificationStateListener(listener: SDKListener { [weak self] verificationState in
            Task { await self?.updateVerificationState(verificationState) }
        })
        
        sendQueueListenerTaskHandle = client.subscribeToSendQueueStatus(listener: SDKListener { [weak self] roomID, error in
            MXLog.error("Send queue failed in room: \(roomID) with error: \(error)")
            self?.sendQueueStatusSubject.send(false)
        })
        
        sendQueueStatusSubject
            .combineLatest(homeserverReachabilityPublisher)
            .debounce(for: 1.0, scheduler: DispatchQueue.main)
            .sink { enabled, reachability in
                MXLog.info("Send queue status changed to enabled: \(enabled), homeserver reachability: \(reachability)")
                
                if enabled == false, reachability == .reachable {
                    MXLog.info("Enabling all send queues")
                    Task {
                        await client.enableAllSendQueues(enable: true)
                    }
                }
            }
            .store(in: &cancellables)
        
        Task {
            do {
                try await client.setMediaRetentionPolicy(policy: .init(maxCacheSize: nil,
                                                                       maxFileSize: nil,
                                                                       // 30 days in seconds
                                                                       lastAccessExpiry: 30 * 24 * 60 * 60,
                                                                       // 1 day in seconds
                                                                       cleanupFrequency: 24 * 60 * 60))
            } catch {
                MXLog.error("Failed setting media retention policy with error: \(error)")
            }
        }
        
        Task {
            mediaPreviewConfigListenerTaskHandle = await createMediaPreviewConfigObserver()
        }
    }
    
    var userID: String {
        do {
            return try client.userId()
        } catch {
            MXLog.error("Failed retrieving room info with error: \(error)")
            return "Unknown user identifier"
        }
    }

    var deviceID: String? {
        do {
            return try client.deviceId()
        } catch {
            MXLog.error("Failed retrieving deviceID with error: \(error)")
            return nil
        }
    }

    var homeserver: String {
        client.homeserver()
    }

    /// sTalk: Access token for direct Matrix REST API calls (e.g. clearing MatrixRTC state)
    func matrixAccessToken() throws -> String {
        try client.session().accessToken
    }

    /// sTalk: Force token refresh by making a lightweight SDK request.
    /// Call this when custom API endpoints return 401 (expired OIDC token).
    /// MAS tokens expire every 15 min — SDK refreshes automatically for its own calls,
    /// but our custom API calls (meetings, recordings) need fresh tokens too.
    func forceTokenRefresh() async {
        // 0xDEAD10CC (крашы 250/254): в фоне refresh НЕ делаем — OIDC-refresh
        // персистит токены в sqlite; в фоновом CPU-окне без bg task ре-суспенд
        // ловит WAL-коммит → kill. 401 в фоне тихо фейлится, ретрай на форграунде.
        let state = await MainActor.run { UIApplication.shared.applicationState }
        guard state != .background else {
            DiagLog.write("ClientProxy", "forceTokenRefresh skipped (background)")
            return
        }
        // displayName() makes a real server request (/profile/{userId}/displayname)
        // which triggers SDK's internal OIDC token refresh if expired.
        // After this call, client.session().accessToken returns the fresh token.
        _ = try? await client.displayName()
    }

    var canDeactivateAccount: Bool {
        client.canDeactivateAccount()
    }
    
    var userIDServerName: String? {
        do {
            return try client.userIdServerName()
        } catch {
            MXLog.error("Failed retrieving userID server name with error: \(error)")
            return nil
        }
    }
    
    var isReportRoomSupported: Bool {
        get async {
            do {
                return try await client.isReportRoomApiSupported()
            } catch {
                MXLog.error("Failed checking report room support with error: \(error)")
                return false
            }
        }
    }
    
    var isLiveKitRTCSupported: Bool {
        get async {
            do {
                return try await client.isLivekitRtcSupported()
            } catch {
                MXLog.error("Failed checking LiveKit RTC support with error: \(error)")
                return false
            }
        }
    }
    
    var isLoginWithQRCodeSupported: Bool {
        get async {
            do {
                return try await client.isLoginWithQrCodeSupported()
            } catch {
                MXLog.error("Failed checking QR code support with error: \(error)")
                return false
            }
        }
    }
    
    var maxMediaUploadSize: Result<UInt, ClientProxyError> {
        get async {
            do {
                return try await .success(UInt(client.getMaxMediaUploadSize()))
            } catch {
                MXLog.error("Failed checking the max media upload size with error: \(error)")
                return .failure(.sdkError(error))
            }
        }
    }

    private(set) lazy var pusherNotificationClientIdentifier: String? = {
        // NOTE: The result is stored as part of the restoration token. Any changes
        // here would require a migration to correctly match incoming notifications.
        guard let data = userID.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }()
    
    func isOnlyDeviceLeft() async -> Result<Bool, ClientProxyError> {
        do {
            let result = try await client.encryption().isLastDevice()
            return .success(result)
        } catch {
            MXLog.error("Failed checking isLastDevice with error: \(error)")
            return .failure(.sdkError(error))
        }
    }

    func hasDevicesToVerifyAgainst() async -> Result<Bool, ClientProxyError> {
        do {
            let result = try await client.encryption().hasDevicesToVerifyAgainst()
            return .success(result)
        } catch {
            MXLog.error("Failed checking hasDevicesToVerifyAgainst with error: \(error)")
            return .failure(.sdkError(error))
        }
    }

    func startSync() {
        guard !hasEncounteredAuthError else {
            MXLog.warning("Ignoring request, this client has an unknown token.")
            return
        }
        
        guard networkMonitor.reachabilityPublisher.value == .reachable else {
            MXLog.warning("Ignoring request, network unreachable.")
            return
        }
        
        MXLog.info("Starting sync")

        // 0xDEAD10CC: переходы stop→pause / resume→start сериализованы цепочкой
        // (upstream serviceStateTask-паттерн) — resume не может влезть посреди pause.
        let previousTransition = serviceTransitionTask
        serviceTransitionTask = Task { [syncService, client, appSettings] in
            await previousTransition?.value
            if appSettings.clientPauseInBackgroundEnabled {
                let started = Date()
                do {
                    try await client.resume()
                    DiagLog.write("ClientProxy", "client.resume() OK took \(Int(-started.timeIntervalSinceNow * 1000))ms")
                } catch {
                    // resume-фейл НЕ блокирует синк — фолбэк на обычный start
                    DiagLog.write("ClientProxy", "client.resume() FAILED after \(Int(-started.timeIntervalSinceNow * 1000))ms: \(error) — startSync продолжаем")
                }
            }
            await syncService.start()
        }

        Task { [serviceTransitionTask] in
            await serviceTransitionTask?.value

            // If we are using OIDC we want to cache the account management URL in volatile memory on the SDK side.
            // To avoid the cache being invalidated while the app is backgrounded, we cache at every sync start.
            await cacheAccountURL()
        }
    }

    /// 0xDEAD10CC: цепочка сериализации переходов sync-сервиса (stop→pause / resume→start).
    /// Быстрое сворачивание/разворачивание не даёт resume() влезть посреди pause().
    private var serviceTransitionTask: Task<Void, Never>?
    
    /// A stored task for restarting the sync after a failure. This is stored so that we can cancel
    /// it when `stopSync` is called (e.g. when signing out) to prevent an otherwise infinite
    /// loop that was triggered by trying to sync a signed out session.
    @CancellableTask private var restartTask: Task<Void, Never>?
    
    func restartSync() {
        guard restartTask == nil else { return }
        
        restartTask = Task { [weak self] in
            do {
                // Until the SDK can tell us the failure, we add a small
                // delay to avoid generating multi-gigabyte log files.
                try await Task.sleep(for: .milliseconds(250))
                self?.startSync()
            } catch {
                MXLog.error("Restart cancelled.")
            }
            self?.restartTask = nil
        }
    }
    
    func stopSync() {
        stopSync(completion: nil)
    }

    func forceRefresh() async {
        MXLog.info("sTalk: force refresh — restarting sync service")
        // Stop the sync service and wait for it to actually stop before restarting, so the
        // sliding-sync connection is fully re-established and pulls fresh data from the server.
        await withCheckedContinuation { continuation in
            stopSync { continuation.resume() }
        }
        startSync()
        // Give the restarted sync a moment to fetch the first batch before we drop the spinner.
        try? await Task.sleep(for: .seconds(1))
    }

    func stopSync(completion: (() -> Void)?) {
        MXLog.info("Stopping sync")
        
        if restartTask != nil {
            MXLog.warning("Removing the sync service restart task.")
            restartTask = nil
        }
        
        // Capture the sync service strongly as this method is called on deinit and so the
        // existence of self when the Task executes is questionable and would sometimes crash.
        // Note: This isn't strictly necessary now given the unwrap above, but leaving the code as
        // documentation. SE-0371 will allow us to fix this by using an async deinit.
        let previousTransition = serviceTransitionTask
        serviceTransitionTask = Task { [syncService, client, appSettings] in
            await previousTransition?.value
            defer {
                completion?()
            }

            await syncService.stop()
            MXLog.info("Sync stopped")

            // 0xDEAD10CC (крашы 250/254/256): stop() гасит только sync-циклы, сторы и
            // файловые локи остаются открытыми → любое фоновое CPU-окно докатывает
            // WAL-коммит и ре-суспенд убивает процесс. pause() отпускает коннекции и
            // локи (док SDK: «to avoid 0xdead10cc kills… after stopping the SyncService»).
            // За флагом до device-замеров длительности (гейт включения <2-3с стабильно).
            if appSettings.clientPauseInBackgroundEnabled {
                let started = Date()
                do {
                    try await client.pause()
                    DiagLog.write("ClientProxy", "client.pause() OK took \(Int(-started.timeIntervalSinceNow * 1000))ms")
                } catch {
                    DiagLog.write("ClientProxy", "client.pause() FAILED after \(Int(-started.timeIntervalSinceNow * 1000))ms: \(error)")
                }
            }
        }
    }
    
    func expireSyncSessions() async {
        await syncService.expireSessions()
    }
    
    func accountURL(action: AccountManagementAction) async -> URL? {
        try? await client.accountUrl(action: action).flatMap(URL.init(string:))
    }
    
    func directRoomForUserID(_ userID: String) -> Result<String?, ClientProxyError> {
        do {
            let roomID = try client.getDmRoom(userId: userID)?.id()
            return .success(roomID)
        } catch {
            MXLog.error("Failed retrieving direct room for userID: \(userID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func createDirectRoom(with userID: String, expectedRoomName: String?) async -> Result<String, ClientProxyError> {
        do {
            // STMOB-71: reuse the existing DM room if there is one. `createRoom`
            // always creates a NEW room, so callers that don't pre-check (User
            // Profile, Room Member Details) were producing duplicate 1:1 rooms with
            // the same user. Centralising the check here covers every caller — the
            // per-screen checks in StartChat/Contacts become a harmless fast path.
            if let existingRoomID = try client.getDmRoom(userId: userID)?.id() {
                MXLog.info("Reusing existing direct room \(existingRoomID) for userID: \(userID)")
                return .success(existingRoomID)
            }

            // Optional encryption: DMs are NOT force-encrypted anymore — like Web they follow the
            // server's e2ee default (io.element.e2ee.default:false on our servers → plaintext DM,
            // user enables encryption manually). Previously hardcoded true, which diverged from Web.
            let parameters = CreateRoomParameters(name: nil,
                                                  topic: nil,
                                                  isEncrypted: false,
                                                  isDirect: true,
                                                  visibility: .private,
                                                  preset: .trustedPrivateChat,
                                                  invite: [userID],
                                                  avatar: nil,
                                                  powerLevelContentOverride: Self.roomCreationPowerLevelOverrides)
            let roomID = try await client.createRoom(request: parameters)
            
            await waitForRoomToSync(roomID: roomID)
            
            return .success(roomID)
        } catch {
            MXLog.error("Failed creating direct room for userID: \(userID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func createRoom(name: String,
                    topic: String?,
                    accessType: CreateRoomAccessType,
                    isEncrypted: Bool,
                    isSpace: Bool,
                    userIDs: [String],
                    avatarURL: URL?,
                    aliasLocalPart: String?) async -> Result<String, ClientProxyError> {
        do {
            let powerLevelContentOverride = if isSpace {
                if accessType == .public {
                    Self.publicSpaceCreationPowerLevelOverrides
                } else {
                    Self.standardSpaceCreationPowerLevelOverrides
                }
            } else {
                if accessType == .askToJoin {
                    Self.knockingRoomCreationPowerLevelOverrides
                } else {
                    Self.roomCreationPowerLevelOverrides
                }
            }
            
            // Public rooms are never encrypted (matches Web); private/askToJoin use the caller's
            // choice (the create-room encryption toggle).
            let parameters = CreateRoomParameters(name: name,
                                                  topic: topic,
                                                  isEncrypted: accessType.isPrivate ? isEncrypted : false,
                                                  isDirect: false,
                                                  visibility: accessType.visibility,
                                                  preset: accessType.preset,
                                                  invite: userIDs,
                                                  avatar: avatarURL?.absoluteString,
                                                  powerLevelContentOverride: powerLevelContentOverride,
                                                  joinRuleOverride: accessType.joinRuleOverride,
                                                  historyVisibilityOverride: accessType.historyVisibilityOverride,
                                                  // This is an FFI naming mistake, what is required is the `aliasLocalPart` not the whole alias
                                                  canonicalAlias: aliasLocalPart,
                                                  isSpace: isSpace)
            let roomID = try await client.createRoom(request: parameters)
            
            await waitForRoomToSync(roomID: roomID)
            
            return .success(roomID)
        } catch {
            MXLog.error("Failed creating room with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func joinRoom(_ roomID: String, via: [String]) async -> Result<Void, ClientProxyError> {
        do {
            let _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: roomID, serverNames: via)
                        
            await waitForRoomToSync(roomID: roomID, timeout: .seconds(30))
            
            return .success(())
        } catch ClientError.MatrixApi(.unknown, _, _, _) {
            MXLog.error("Failed joining roomID: \(roomID) invalid invite")
            return .failure(.invalidInvite)
        } catch ClientError.MatrixApi(.forbidden, _, _, _) {
            MXLog.error("Failed joining roomID: \(roomID) forbidden")
            return .failure(.forbiddenAccess)
        } catch {
            MXLog.error("Failed joining roomID: \(roomID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func joinRoomAlias(_ roomAlias: String) async -> Result<Void, ClientProxyError> {
        do {
            let room = try await client.joinRoomByIdOrAlias(roomIdOrAlias: roomAlias, serverNames: [])
            
            await waitForRoomToSync(roomID: room.id(), timeout: .seconds(30))
            
            return .success(())
        } catch ClientError.MatrixApi(.unknown, _, _, _) {
            MXLog.error("Failed joining roomAlias: \(roomAlias) invalid invite")
            return .failure(.invalidInvite)
        } catch ClientError.MatrixApi(.forbidden, _, _, _) {
            MXLog.error("Failed joining roomAlias: \(roomAlias) forbidden")
            return .failure(.forbiddenAccess)
        } catch {
            MXLog.error("Failed joining roomAlias: \(roomAlias) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func knockRoom(_ roomID: String, via: [String], message: String?) async -> Result<Void, ClientProxyError> {
        do {
            let _ = try await client.knock(roomIdOrAlias: roomID, reason: message, serverNames: via)
            await waitForRoomToSync(roomID: roomID, timeout: .seconds(30))
            return .success(())
        } catch {
            MXLog.error("Failed knocking roomID: \(roomID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func knockRoomAlias(_ roomAlias: String, message: String?) async -> Result<Void, ClientProxyError> {
        do {
            let room = try await client.knock(roomIdOrAlias: roomAlias, reason: message, serverNames: [])
            await waitForRoomToSync(roomID: room.id(), timeout: .seconds(30))
            return .success(())
        } catch {
            MXLog.error("Failed knocking roomAlias: \(roomAlias) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func canJoinRoom(with rules: [AllowRule]) -> Bool {
        for rule in rules {
            if case let .roomMembership(roomID) = rule,
               let room = try? client.getRoom(roomId: roomID),
               room.membership() == .joined {
                return true
            }
        }
        return false
    }
    
    func uploadMedia(_ media: MediaInfo) async -> Result<String, ClientProxyError> {
        guard let mimeType = media.mimeType else {
            MXLog.error("Failed uploading media, invalid mime type: \(media)")
            return .failure(ClientProxyError.invalidMedia)
        }
        
        do {
            let data = try Data(contentsOf: media.url)
            let matrixUrl = try await client.uploadMedia(mimeType: mimeType, data: data, progressWatcher: nil)
            return .success(matrixUrl)
        } catch let ClientError.MatrixApi(errorKind, _, _, _) {
            MXLog.error("Failed uploading media with error kind: \(errorKind)")
            return .failure(ClientProxyError.failedUploadingMedia(errorKind))
        } catch {
            MXLog.error("Failed uploading media with error: \(error)")
            return .failure(ClientProxyError.sdkError(error))
        }
    }
        
    func roomForIdentifier(_ identifier: String) async -> RoomProxyType? {
        let shouldAwait = roomsToAwait.remove(identifier) != nil
        
        // Try fetching the room from the cold cache (if available) first
        if let room = await buildRoomForIdentifier(identifier) {
            return room
        }
        
        if !staticRoomSummaryProvider.statePublisher.value.isLoaded {
            _ = await staticRoomSummaryProvider.statePublisher.values.first { $0.isLoaded }
        }
        
        if shouldAwait {
            await waitForRoomToSync(roomID: identifier)
        }
        
        return await buildRoomForIdentifier(identifier)
    }
    
    func roomPreviewForIdentifier(_ identifier: String, via: [String]) async -> Result<RoomPreviewProxyProtocol, ClientProxyError> {
        do {
            let roomPreview = try await client.getRoomPreviewFromRoomId(roomId: identifier, viaServers: via)
            return .success(RoomPreviewProxy(roomPreview: roomPreview))
        } catch ClientError.MatrixApi(.forbidden, _, _, _) {
            MXLog.error("Failed retrieving preview for room: \(identifier) is private")
            return .failure(.roomPreviewIsPrivate)
        } catch {
            MXLog.error("Failed retrieving preview for room: \(identifier) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func roomSummaryForIdentifier(_ identifier: String) -> RoomSummary? {
        staticRoomSummaryProvider.roomListPublisher.value.first { $0.id == identifier }
    }
    
    func roomSummaryForAlias(_ alias: String) -> RoomSummary? {
        staticRoomSummaryProvider.roomListPublisher.value.first { $0.canonicalAlias == alias || $0.alternativeAliases.contains(alias) }
    }
    
    func reportRoomForIdentifier(_ identifier: String, reason: String) async -> Result<Void, ClientProxyError> {
        do {
            guard let room = try client.getRoom(roomId: identifier) else {
                MXLog.error("Failed reporting room with identifier: \(identifier), room not in local store")
                return .failure(.roomNotInLocalStore)
            }
            try await room.reportRoom(reason: reason)
            return .success(())
        } catch {
            MXLog.error("Failed reporting room with identifier: \(identifier), with error: \(error)")
            return .failure(.sdkError(error))
        }
    }

    func loadUserDisplayName() async -> Result<Void, ClientProxyError> {
        do {
            let displayName = try await client.displayName()
            userDisplayNameSubject.send(displayName)
            return .success(())
        } catch {
            MXLog.error("Failed loading user display name with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func setUserDisplayName(_ name: String) async -> Result<Void, ClientProxyError> {
        do {
            try await client.setDisplayName(name: name)
            Task {
                await self.loadUserDisplayName()
            }
            return .success(())
        } catch {
            MXLog.error("Failed setting user display name with error: \(error)")
            return .failure(.sdkError(error))
        }
    }

    func loadUserAvatarURL() async -> Result<Void, ClientProxyError> {
        do {
            let urlString = try await client.avatarUrl()
            loadCachedAvatarURLTask?.cancel()
            userAvatarURLSubject.send(urlString.flatMap(URL.init))
            return .success(())
        } catch {
            MXLog.error("Failed loading user avatar URL with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func setUserAvatar(media: MediaInfo) async -> Result<Void, ClientProxyError> {
        guard case let .image(imageURL, _, _) = media, let mimeType = media.mimeType else {
            MXLog.error("Failed uploading, invalid media: \(media)")
            return .failure(.invalidMedia)
        }
            
        do {
            let data = try Data(contentsOf: imageURL)
            try await client.uploadAvatar(mimeType: mimeType, data: data)
            Task {
                await self.loadUserAvatarURL()
            }
            return .success(())
        } catch {
            MXLog.error("Failed setting user avatar with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func removeUserAvatar() async -> Result<Void, ClientProxyError> {
        do {
            try await client.removeAvatar()
            Task {
                await self.loadUserAvatarURL()
            }
            return .success(())
        } catch {
            MXLog.error("Failed removing user avatar with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func linkNewDeviceService() -> LinkNewDeviceServiceProtocol {
        LinkNewDeviceService(handler: client.newGrantLoginWithQrCodeHandler())
    }
    
    func deactivateAccount(password: String?, eraseData: Bool) async -> Result<Void, ClientProxyError> {
        do {
            try await client.deactivateAccount(authData: password.map { .password(passwordDetails: .init(identifier: userID, password: $0)) },
                                               eraseData: eraseData)
            return .success(())
        } catch {
            return .failure(.sdkError(error))
        }
    }
    
    func logout() async {
        do {
            try await client.logout()
        } catch {
            MXLog.error("Failed logging out with error: \(error)")
        }
    }
    
    func setPusher(with configuration: PusherConfiguration) async throws {
        try await client.setPusher(identifiers: configuration.identifiers,
                                   kind: configuration.kind,
                                   appDisplayName: configuration.appDisplayName,
                                   deviceDisplayName: configuration.deviceDisplayName,
                                   profileTag: configuration.profileTag,
                                   lang: configuration.lang,
                                   append: false)
    }

    func deletePusher(pushkey: String, appId: String) async throws {
        try await client.deletePusher(identifiers: .init(pushkey: pushkey, appId: appId))
    }

    // sTalk: STMOB-87 — Active sessions screen helpers.
    func fetchActiveDevices() async -> Result<[MatrixActiveDevice], ClientProxyError> {
        let homeserverString = homeserver
        let base = homeserverString.hasSuffix("/") ? String(homeserverString.dropLast()) : homeserverString
        let urlString = base + "/_matrix/client/v3/devices"
        MXLog.info("STMOB-87: fetchActiveDevices URL=\(urlString) (base=\(base))")
        guard let url = URL(string: urlString) else {
            return .failure(.httpError(status: 0, body: "invalid URL: \(urlString)"))
        }
        let token: String
        do {
            token = try matrixAccessToken()
        } catch {
            MXLog.error("STMOB-87: matrixAccessToken failed: \(error)")
            return .failure(.sdkError(error))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            guard status == 200 else {
                MXLog.error("STMOB-87: GET /devices status=\(status) body=\(bodyStr.prefix(500))")
                return .failure(.httpError(status: status, body: String(bodyStr.prefix(500))))
            }
            struct Wrapper: Decodable { let devices: [MatrixActiveDevice] }
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
            return .success(wrapper.devices)
        } catch {
            MXLog.error("STMOB-87: fetchActiveDevices failed: \(error)")
            return .failure(.sdkError(error))
        }
    }

    func signOutDevice(deviceID: String) async -> Result<Void, ClientProxyError> {
        // STMOB-87: native sign out flow (без Safari fallback).
        // Phase 1 attempt: DELETE с auth dict содержащим access_token (msc3861/MAS).
        // Если Synapse возвращает UIA challenge — для MAS deployment первая
        // попытка может вернуть 401 с session+flows. Тогда повторяем DELETE
        // включая `auth: {session: ..., type: "m.login.token", token: <access_token>}`
        // или `m.login.application_service`. Простейшее: для msc3861 deployments
        // Synapse делегирует auth МАСу — DELETE с Bearer token должен работать.
        // Если 401 без UIA — токен не имеет прав / scope.
        let encodedID = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        let homeserverString = homeserver
        let base = homeserverString.hasSuffix("/") ? String(homeserverString.dropLast()) : homeserverString
        let urlString = "\(base)/_matrix/client/v3/devices/\(encodedID)"
        guard let url = URL(string: urlString) else { return .failure(.invalidResponse) }
        let token: String
        do {
            token = try matrixAccessToken()
        } catch {
            return .failure(.sdkError(error))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // STMOB-87: empty auth dict body — Matrix spec для UIA, Synapse с msc3861/MAS
        // принимает {"auth": {}} вместо требования полного UIA challenge.
        // Существующий cleanupOldDevicesByIDFV в UserSession.swift использует тот же
        // паттерн и успешно удаляет devices.
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["auth": [:]])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            MXLog.info("STMOB-87: DELETE /devices/\(deviceID) status=\(status) body=\(bodyStr.prefix(500))")

            switch status {
            case 200, 204:
                return .success(())
            default:
                MXLog.error("STMOB-87: DELETE /devices/\(deviceID) status=\(status) body=\(bodyStr.prefix(500))")
                return .failure(.httpError(status: status, body: String(bodyStr.prefix(800))))
            }
        } catch {
            MXLog.error("STMOB-87: signOutDevice failed: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func searchUsers(searchTerm: String, limit: UInt) async -> Result<SearchUsersResultsProxy, ClientProxyError> {
        do {
            return try await .success(.init(sdkResults: client.searchUsers(searchTerm: searchTerm, limit: UInt64(limit))))
        } catch {
            MXLog.error("Failed searching users with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func profile(for userID: String) async -> Result<UserProfileProxy, ClientProxyError> {
        do {
            return try await .success(.init(sdkUserProfile: client.getProfile(userId: userID)))
        } catch {
            MXLog.error("Failed retrieving profile for userID: \(userID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func roomDirectorySearchProxy() -> RoomDirectorySearchProxyProtocol {
        RoomDirectorySearchProxy(roomDirectorySearch: client.roomDirectorySearch(), appSettings: appSettings)
    }
    
    func resolveRoomAlias(_ alias: String) async -> Result<ResolvedRoomAlias, ClientProxyError> {
        do {
            guard let resolvedAlias = try await client.resolveRoomAlias(roomAlias: alias) else {
                MXLog.error("Failed resolving room alias, is nil")
                return .failure(.failedResolvingRoomAlias)
            }
            
            // Resolving aliases is done through the directory/room API which returns too many / all known
            // vias, which in turn results in invalid join requests. Trim them to something manageable
            // https://github.com/element-hq/synapse/issues/17298
            let limitedAlias = ResolvedRoomAlias(roomId: resolvedAlias.roomId, servers: Array(resolvedAlias.servers.prefix(50)))
            
            return .success(limitedAlias)
        } catch {
            MXLog.error("Failed resolving room alias: \(alias) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func isAliasAvailable(_ alias: String) async -> Result<Bool, ClientProxyError> {
        do {
            let result = try await client.isRoomAliasAvailable(alias: alias)
            return .success(result)
        } catch {
            MXLog.error("Failed checking if alias: \(alias) is available with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func clearCaches() async -> Result<Void, ClientProxyError> {
        do {
            return try await .success(client.clearCaches(syncService: syncService))
        } catch {
            MXLog.error("Failed clearing client caches with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func optimizeStores() async -> Result<Void, ClientProxyError> {
        do {
            return try await .success(client.optimizeStores())
        } catch {
            MXLog.error("Failed optimizing client stores with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func storeSizes() async -> Result<StoreSizes, ClientProxyError> {
        do {
            return try await .success(client.getStoreSizes())
        } catch {
            MXLog.error("Failed optimizing client stores with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func fetchMediaPreviewConfiguration() async -> Result<MediaPreviewConfig?, ClientProxyError> {
        do {
            let config = try await client.fetchMediaPreviewConfig()
            return .success(config)
        } catch {
            MXLog.error("Failed fetching media preview config with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
        
    // MARK: Ignored users
    
    func ignoreUser(_ userID: String) async -> Result<Void, ClientProxyError> {
        do {
            try await client.ignoreUser(userId: userID)
            return .success(())
        } catch {
            MXLog.error("Failed ignoring user with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func unignoreUser(_ userID: String) async -> Result<Void, ClientProxyError> {
        do {
            try await client.unignoreUser(userId: userID)
            return .success(())
        } catch {
            MXLog.error("Failed unignoring user with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    // MARK: Recently visited rooms
    
    func trackRecentlyVisitedRoom(_ roomID: String) async -> Result<Void, ClientProxyError> {
        do {
            try await client.trackRecentlyVisitedRoom(room: roomID)
            return .success(())
        } catch {
            MXLog.error("Failed tracking recently visited room: \(roomID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func recentlyVisitedRooms(filter: (JoinedRoomProxyProtocol) -> Bool) async -> [JoinedRoomProxyProtocol] {
        let maxResultsToReturn = 5
        
        guard case let .success(roomIdentifiers) = await recentlyVisitedRoomIDs() else {
            return []
        }
        
        var rooms: [JoinedRoomProxyProtocol] = []
        
        for roomID in roomIdentifiers {
            guard case let .joined(roomProxy) = await roomForIdentifier(roomID),
                  filter(roomProxy) else {
                continue
            }
            
            rooms.append(roomProxy)
            
            if rooms.count >= maxResultsToReturn {
                return rooms
            }
        }
        
        return rooms
    }
    
    func recentConversationCounterparts() async -> [UserProfileProxy] {
        let maxResultsToReturn = 5
        
        guard case let .success(roomIdentifiers) = await recentlyVisitedRoomIDs() else {
            return []
        }
        
        var users: OrderedSet<UserProfileProxy> = []
        
        for roomID in roomIdentifiers {
            guard case let .joined(roomProxy) = await roomForIdentifier(roomID),
                  roomProxy.infoPublisher.value.isDirect,
                  let members = await roomProxy.members() else {
                continue
            }
            
            for member in members where member.isActive && member.userID != userID {
                users.append(.init(userID: member.userID, displayName: member.displayName, avatarURL: member.avatarURL))
                
                // Return early to avoid unnecessary work
                if users.count >= maxResultsToReturn {
                    return users.elements
                }
            }
        }
        
        return users.elements
    }
    
    private func recentlyVisitedRoomIDs() async -> Result<[String], ClientProxyError> {
        do {
            let result = try await client.getRecentlyVisitedRooms()
            return .success(result)
        } catch {
            MXLog.error("Failed retrieving recently visited rooms with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    // MARK: Moderation & Safety
    
    func setTimelineMediaVisibility(_ value: TimelineMediaVisibility) async -> Result<Void, ClientProxyError> {
        do {
            try await client.setMediaPreviewDisplayPolicy(policy: value.rustValue)
            return .success(())
        } catch {
            MXLog.error("Failed to set timeline media visibility: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func setHideInviteAvatars(_ value: Bool) async -> Result<Void, ClientProxyError> {
        do {
            try await client.setInviteAvatarsDisplayPolicy(policy: value ? .off : .on)
            return .success(())
        } catch {
            MXLog.error("Failed to set hide invite avatars: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    // MARK: - Private
    
    private func cacheAccountURL() async {
        // Calling this function for the first time will cache the account URL in volatile memory for 24 hrs on the SDK.
        _ = try? await client.accountUrl(action: nil)
    }
    
    private func updateVerificationState(_ verificationState: VerificationState) async {
        let verificationState: SessionVerificationState = switch verificationState {
        case .unknown:
            .unknown
        case .unverified:
            .unverified
        case .verified:
            .verified
        }
        
        // The session verification controller requires the user's identity which
        // isn't available before a keys query response. Use the verification
        // state updates as an aproximation for when that happens.
        await buildSessionVerificationControllerProxyIfPossible(verificationState: verificationState)
        
        // Only update the session verification state after creating a session
        // verification proxy to avoid race conditions
        verificationStateSubject.send(verificationState)
    }
    
    private func buildSessionVerificationControllerProxyIfPossible(verificationState: SessionVerificationState) async {
        guard sessionVerificationController == nil, verificationState != .unknown else {
            return
        }
        
        do {
            let sessionVerificationController = try await client.getSessionVerificationController()
            self.sessionVerificationController = SessionVerificationControllerProxy(sessionVerificationController: sessionVerificationController)
        } catch {
            MXLog.error("Failed retrieving session verification controller proxy with error: \(error)")
        }
    }

    private func loadUserAvatarURLFromCache() {
        loadCachedAvatarURLTask = Task {
            do {
                let urlString = try await self.client.cachedAvatarUrl()
                guard !Task.isCancelled else { return }
                self.userAvatarURLSubject.value = urlString.flatMap(URL.init)
            } catch {
                MXLog.error("Failed to look for the avatar url in the cache: \(error)")
            }
        }
    }
    
    private func createSyncServiceStateObserver(_ syncService: SyncService) -> TaskHandle {
        syncService.state(listener: SDKListener { [weak self] state in
            guard let self else { return }
            
            MXLog.info("Received sync service update: \(state)")
            
            switch state {
            case .running, .terminated, .idle:
                homeserverReachabilitySubject.send(.reachable)
            case .offline:
                homeserverReachabilitySubject.send(.unreachable)
            case .error:
                restartSync()
            }
        })
    }
    
    private func createMediaPreviewConfigObserver() async -> TaskHandle? {
        do {
            return try await client.subscribeToMediaPreviewConfig(listener: SDKListener { [weak self] config in
                guard let self else { return }
                
                if let config {
                    timelineMediaVisibilitySubject.send(config.mediaPreviewVisibility)
                    hideInviteAvatarsSubject.send(config.hideInviteAvatars)
                } else {
                    // return default values
                    timelineMediaVisibilitySubject.send(.always)
                    hideInviteAvatarsSubject.send(false)
                }
            })
        } catch {
            MXLog.error("Failed creating media preview config observer: \(error)")
            return nil
        }
    }

    private func createRoomListServiceObserver(_ roomListService: RoomListService) -> TaskHandle {
        roomListService.state(listener: SDKListener { [weak self] state in
            guard let self else { return }
            
            MXLog.info("Received room list update: \(state)")
            
            guard state != .error,
                  state != .terminated else {
                // The sync service is responsible of handling error and termination
                return
            }
            
            // Hide the sync spinner as soon as we get any update back
            actionsSubject.send(.receivedSyncUpdate)
            
            if ignoredUsersSubject.value == nil {
                updateIgnoredUsers()
            }
        })
    }
    
    private func createRoomListLoadingStateUpdateObserver(_ roomListService: RoomListService) -> TaskHandle {
        roomListService.syncIndicator(delayBeforeShowingInMs: 1000, delayBeforeHidingInMs: 0, listener: SDKListener { [weak self] state in
            guard let self else { return }
            
            switch state {
            case .show:
                loadingStateSubject.send(.loading)
            case .hide:
                loadingStateSubject.send(.notLoading)
            }
        })
    }
    
    private func buildRoomForIdentifier(_ roomID: String) async -> RoomProxyType? {
        if let result = await buildRoomForIdentifierOnce(roomID) {
            return result
        }
        // Сага «нужно приглашение» (20.07): тап по пушу резолвил комнату на
        // ЗАПАУЗЕННОМ сторе (client.pause) — getRoom кидал store-closed → nil →
        // экран «нужно приглашение» при живом membership. Дожидаемся конца
        // pause/resume-перехода и пробуем ещё раз.
        guard let transition = serviceTransitionTask else {
            return nil
        }
        await transition.value
        MXLog.info("Room \(roomID) not resolved on first try — retrying after service transition")
        return await buildRoomForIdentifierOnce(roomID)
    }

    private func buildRoomForIdentifierOnce(_ roomID: String) async -> RoomProxyType? {
        do {
            guard let room = try client.getRoom(roomId: roomID) else {
                return nil
            }
            
            switch room.membership() {
            case .invited:
                return try await .invited(InvitedRoomProxy(room: room))
            case .knocked:
                guard appSettings.knockingEnabled else {
                    return nil
                }
                
                return try await .knocked(KnockedRoomProxy(room: room))
            case .joined:
                let roomProxy = try await JoinedRoomProxy(roomListService: roomListService,
                                                          room: room,
                                                          appSettings: appSettings)
                
                return .joined(roomProxy)
            case .left:
                return .left
            case .banned:
                return try await .banned(BannedRoomProxy(room: room))
            }
        } catch {
            MXLog.error("Failed retrieving room: \(roomID), with error: \(error)")
            return nil
        }
    }
    
    private func waitForRoomToSync(roomID: String, timeout: Duration = .seconds(10)) async {
        MXLog.info("Wait for \(roomID)")
        let runner = ExpiringTaskRunner { [weak self] in
            guard let self else { return }
            
            do {
                _ = try await client.awaitRoomRemoteEcho(roomId: roomID)
                MXLog.info("Wait for \(roomID) got remote echo.")
            } catch {
                MXLog.info("Failed waiting for remote echo in \(roomID): \(error)")
            }
        }
        
        do {
            try await runner.run(timeout: timeout)
        } catch {
            MXLog.info("Wait for \(roomID) failed: \(error)")
        }
    }

    private func updateIgnoredUsers() {
        Task {
            do {
                let ignoredUsers = try await client.ignoredUsers()
                ignoredUsersSubject.send(ignoredUsers)
            } catch {
                MXLog.error("Failed fetching ignored users with error: \(error)")
            }
        }
    }
    
    // MARK: - Crypto
    
    func ed25519Base64() async -> String? {
        await client.encryption().ed25519Key()
    }
    
    func curve25519Base64() async -> String? {
        await client.encryption().curve25519Key()
    }
    
    func pinUserIdentity(_ userID: String) async -> Result<Void, ClientProxyError> {
        MXLog.info("Pinning current identity for user: \(userID)")
        
        do {
            guard let userIdentity = try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) else {
                MXLog.error("Failed retrieving identity for user: \(userID)")
                return .failure(.failedRetrievingUserIdentity)
            }
            
            return try await .success(userIdentity.pin())
        } catch {
            MXLog.error("Failed pinning current identity for user: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func withdrawUserIdentityVerification(_ userID: String) async -> Result<Void, ClientProxyError> {
        MXLog.info("Withdrawing current identity verification for user: \(userID)")
        
        do {
            guard let userIdentity = try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) else {
                MXLog.error("Failed retrieving identity for user: \(userID)")
                return .failure(.failedRetrievingUserIdentity)
            }
            
            return try await .success(userIdentity.withdrawVerification())
        } catch {
            MXLog.error("Failed withdrawing current identity verification for user: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func resetIdentity() async -> Result<IdentityResetHandle?, ClientProxyError> {
        do {
            return try await .success(client.encryption().resetIdentity())
        } catch {
            return .failure(.sdkError(error))
        }
    }
    
    func userIdentity(for userID: String, fallBackToServer: Bool) async -> Result<UserIdentityProxyProtocol?, ClientProxyError> {
        do {
            return try await .success(client.encryption().userIdentity(userId: userID, fallbackToServer: fallBackToServer).map(UserIdentityProxy.init))
        } catch {
            MXLog.error("Failed retrieving user identity: \(error)")
            return .failure(.sdkError(error))
        }
    }
}

private final class ClientDelegateWrapper: ClientDelegate {
    private let authErrorCallback: @Sendable (Bool) -> Void
    
    init(authErrorCallback: @escaping @Sendable (Bool) -> Void) {
        self.authErrorCallback = authErrorCallback
    }
    
    // MARK: - ClientDelegate

    func didReceiveAuthError(isSoftLogout: Bool) {
        MXLog.error("Received authentication error, softlogout=\(isSoftLogout)")
        authErrorCallback(isSoftLogout)
    }

    func didRefreshTokens() {
        MXLog.info("Delegating session updates to the ClientSessionDelegate.")
    }

    /// SDK 26.06.03: new ClientDelegate requirement — the SDK reports background task failures
    /// (panics/errors/early termination). Log-only here; STMOB-133 diagnostics benefit from these.
    func onBackgroundTaskErrorReport(taskName: String, error: MatrixRustSDK.BackgroundTaskFailureReason) {
        MXLog.error("SDK background task '\(taskName)' failed: \(error)")
    }
}

private final class ClientDecryptionErrorDelegate: UnableToDecryptDelegate {
    private let actionsSubject: PassthroughSubject<ClientProxyAction, Never>
    
    init(actionsSubject: PassthroughSubject<ClientProxyAction, Never>) {
        self.actionsSubject = actionsSubject
    }
    
    func onUtd(info: UnableToDecryptInfo) {
        actionsSubject.send(.receivedDecryptionError(info))
    }
}

private struct ClientProxyServices {
    let syncService: SyncService
    let roomListService: RoomListService
    let roomSummaryProvider: RoomSummaryProviderProtocol
    let alternateRoomSummaryProvider: RoomSummaryProviderProtocol
    let staticRoomSummaryProvider: StaticRoomSummaryProviderProtocol
    
    init(client: ClientProtocol,
         actionsSubject: PassthroughSubject<ClientProxyAction, Never>,
         notificationSettings: NotificationSettingsProxyProtocol,
         appSettings: AppSettings) async throws {
        let syncService = try await client
            .syncService() // SDK 26.06.03: cross-process lock moved to ClientBuilder.crossProcessLockConfig
            .withOfflineMode()
            .withSharePos(enable: true)
            .finish()
        
        let roomListService = syncService.roomListService()
        
        let roomMessageEventStringBuilder = RoomMessageEventStringBuilder(attributedStringBuilder: AttributedStringBuilder(cacheKey: "roomList",
                                                                                                                           mentionBuilder: PlainMentionBuilder()), destination: .roomList)
        let eventStringBuilder = try RoomEventStringBuilder(stateEventStringBuilder: RoomStateEventStringBuilder(userID: client.userId(), shouldDisambiguateDisplayNames: false),
                                                            messageEventStringBuilder: roomMessageEventStringBuilder,
                                                            shouldDisambiguateDisplayNames: false,
                                                            shouldPrefixSenderName: true)
        
        roomSummaryProvider = RoomSummaryProvider(roomListService: roomListService,
                                                  eventStringBuilder: eventStringBuilder,
                                                  name: "AllRooms",
                                                  shouldUpdateVisibleRange: true,
                                                  notificationSettings: notificationSettings,
                                                  appSettings: appSettings)
        try await roomSummaryProvider.setRoomList(roomListService.allRooms())
        
        alternateRoomSummaryProvider = RoomSummaryProvider(roomListService: roomListService,
                                                           eventStringBuilder: eventStringBuilder,
                                                           name: "AlternateAllRooms",
                                                           notificationSettings: notificationSettings,
                                                           appSettings: appSettings)
        try await alternateRoomSummaryProvider.setRoomList(roomListService.allRooms())
        
        staticRoomSummaryProvider = RoomSummaryProvider(roomListService: roomListService,
                                                        eventStringBuilder: eventStringBuilder,
                                                        name: "StaticAllRooms",
                                                        roomListPageSize: .max,
                                                        notificationSettings: notificationSettings,
                                                        appSettings: appSettings)
        try await staticRoomSummaryProvider.setRoomList(roomListService.allRooms())
        
        self.syncService = syncService
        self.roomListService = roomListService
    }
}

private extension MediaPreviewConfig {
    var mediaPreviewVisibility: TimelineMediaVisibility {
        switch mediaPreviews {
        case .on:
            .always
        case .private:
            .privateOnly
        case .off:
            .never
        case .none:
            .always
        }
    }
    
    var hideInviteAvatars: Bool {
        switch inviteAvatars {
        case .off:
            true
        case .on:
            false
        case .none:
            true
        }
    }
}

private extension TimelineMediaVisibility {
    var rustValue: MediaPreviews {
        switch self {
        case .always:
            .on
        case .never:
            .off
        case .privateOnly:
            .private
        }
    }
}

private extension CreateRoomAccessType {
    var isEncrypted: Bool {
        switch self {
        case .public:
            false
        case .askToJoin, .private:
            true
        }
    }
    
    var visibility: RoomVisibility {
        isPrivate ? .private : .public
    }
    
    var preset: RoomPreset {
        isPrivate ? .privateChat : .publicChat
    }
    
    var historyVisibilityOverride: RoomHistoryVisibility? {
        isPrivate ? .invited : nil
    }
    
    var joinRuleOverride: JoinRule? {
        switch self {
        case .askToJoin:
            .knock
        case .private, .public:
            nil
        }
    }
}
