//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import CallKit
import Combine
import LiveKit
import os.log
import SwiftUI

private let callLog = OSLog(subsystem: "ru.implica.stalk", category: "CallScreen")

/// sTalk: Debug log to file (os_log doesn't work on simulator)
private func stalkLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    NSLog("sTalk: %@", message)
    let dir = FileManager.default.temporaryDirectory
    let file = dir.appendingPathComponent("stalk_call_debug.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: file)
        }
    }
}

typealias CallScreenViewModelType = StateStoreViewModel<CallScreenViewState, CallScreenViewAction>

class CallScreenViewModel: CallScreenViewModelType, CallScreenViewModelProtocol {
    private let elementCallService: ElementCallServiceProtocol
    private let configuration: ElementCallConfiguration
    private let isPictureInPictureAllowed: Bool
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let recordingService: RecordingServiceProtocol?
    private let localCallHistoryService: LocalCallHistoryServiceProtocol?
    private let currentCallID: String?

    private let startWithVideoEnabled: Bool
    private let widgetDriver: ElementCallWidgetDriverProtocol

    /// sTalk: Native LiveKit room manager
    private let liveKitRoomManager = LiveKitRoomManager()

    /// sTalk: LiveKit room name extracted from JWT token (for recording-api)
    private var interceptedLiveKitRoomName: String?

    /// sTalk: Tracks whether the call is currently minimized (prevents spurious dismiss on opacity:0)
    private(set) var isMinimized = false
    /// sTalk: Guard against cascade endCall() — infoPublisher fires multiple times
    private var isEndingCall = false

    /// sTalk: Native call session (replaces WebView when enabled)
    private var nativeCallSession: NativeCallSession?
    /// sTalk: Feature flag for native calls
    private var useNativeCall: Bool {
        true // sTalk: native calls always enabled (LiveKit SDK, no WebView)
    }

    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    @CancellableTask
    private var timeoutTask: Task<Void, Never>?

    @CancellableTask
    private var callTimerTask: Task<Void, Never>?

    /// sTalk: Polling task for remote recording detection
    private var recordingPollingTask: Task<Void, Never>?
        
    /// Designated initialiser
    /// - Parameters:
    ///   - elementCallService: service responsible for setting up CallKit
    ///   - roomProxy: The room in which the call should be created
    ///   - callBaseURL: Which Element Call instance should be used
    ///   - clientID: Something to identify the current client on the Element Call side
    ///   - recordingService: Optional service for call recording
    init(elementCallService: ElementCallServiceProtocol,
         configuration: ElementCallConfiguration,
         allowPictureInPicture: Bool,
         appHooks: AppHooks,
         appSettings: AppSettings,
         analyticsService: AnalyticsService,
         recordingService: RecordingServiceProtocol? = nil,
         mediaProvider: MediaProviderProtocol? = nil,
         localCallHistoryService: LocalCallHistoryServiceProtocol? = nil,
         currentCallID: String? = nil,
         startWithVideoEnabled: Bool = true) {
        self.elementCallService = elementCallService
        self.configuration = configuration
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.recordingService = recordingService
        self.localCallHistoryService = localCallHistoryService
        self.currentCallID = currentCallID
        self.startWithVideoEnabled = startWithVideoEnabled
        isPictureInPictureAllowed = allowPictureInPicture

        // Сбрасываем состояние записи от предыдущего звонка
        recordingService?.forceReset()

        // sTalk: Pass access token to recording service for Authorization header.
        // STMOB-231: даём провайдер свежего токена + refresher вместо одноразового
        // кэша — MAS ротирует access_token каждые 15 мин, статичный токен протухал
        // → recording-api 401 при старте записи. Provider тянет текущий токен из SDK
        // на каждый запрос, refresher форсит ротацию + retry (паттерн PresenceService).
        if let concreteRecording = recordingService as? RecordingService {
            if case .roomCall(_, let clientProxy, _, _, _, _) = configuration.kind,
               let concreteProxy = clientProxy as? ClientProxy {
                concreteRecording.tokenProvider = { [weak concreteProxy] in try? concreteProxy?.matrixAccessToken() }
                concreteRecording.tokenRefresher = { [weak concreteProxy] in await concreteProxy?.forceTokenRefresh() }
                if let token = try? concreteProxy.matrixAccessToken() {
                    concreteRecording.updateAccessToken(token)
                }
            }
        }

        var isGenericCallLink = false
        switch configuration.kind {
        case .genericCallLink(let url):
            widgetDriver = GenericCallLinkWidgetDriver(url: url)
            isGenericCallLink = true
        case .roomCall(let roomProxy, let clientProxy, _, _, _, _):
            guard let deviceID = clientProxy.deviceID else { fatalError("Missing device ID for the call.") }
            widgetDriver = roomProxy.elementCallWidgetDriver(deviceID: deviceID)
        }
        
        // sTalk: get room display name and info for call header
        var roomDisplayName: String?
        var isDirect = false
        var totalMembersCount = 0
        var callParticipantsCount = 0
        if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
            let roomInfo = roomProxy.infoPublisher.value
            roomDisplayName = roomInfo.displayName
            isDirect = roomInfo.isDirect
            totalMembersCount = roomInfo.activeMembersCount
            callParticipantsCount = roomInfo.activeRoomCallParticipants.count
        }

        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript,
                                                         isGenericCallLink: isGenericCallLink,
                                                         certificateValidator: appHooks.certificateValidatorHook,
                                                         roomDisplayName: roomDisplayName,
                                                         isDirect: isDirect,
                                                         totalMembersCount: totalMembersCount,
                                                         callParticipantsCount: callParticipantsCount,
                                                         mediaProvider: mediaProvider,
                                                         isVideoEnabled: startWithVideoEnabled))

        MXLog.info("sTalk CallScreenVM init: startWithVideoEnabled=\(startWithVideoEnabled), isDirect=\(isDirect), participants=\(callParticipantsCount), room=\(roomDisplayName ?? "nil")")

        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case let .setAudioEnabled(enabled, roomID):
                    guard roomID == configuration.callRoomID else {
                        MXLog.error("Received mute request for a different room: \(roomID) != \(configuration.callRoomID)")
                        return
                    }
                    
                    Task {
                        await self.setAudioEnabled(enabled)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        // In native mode, don't forward widget messages to non-existent WebView
        if !useNativeCall {
            widgetDriver.messagePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] receivedMessage in
                    guard let self else { return }

                    Task {
                        await self.postJSONToWidget(receivedMessage)
                    }
                }
                .store(in: &cancellables)
        }
        
        if !useNativeCall {
            widgetDriver.actions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] action in
                    guard let self else { return }

                    switch action {
                    case .callEnded:
                        // sTalk: Guard against bounce-back.
                        if self.isEndingCall {
                            MXLog.info("sTalk: .callEnded ignored — endCall() is already in progress")
                            return
                        }
                        actionsSubject.send(.dismiss)
                    case .mediaStateChanged(let audioEnabled, let videoEnabled):
                        elementCallService.setAudioEnabled(audioEnabled, roomID: configuration.callRoomID)
                        // sTalk: Sync native button state with WebView state
                        self.state.isMuted = !audioEnabled
                        // Don't let WebView override video state for voice calls before our explicit disable
                        if self.startWithVideoEnabled || self.state.wasConnected {
                            self.state.isVideoEnabled = videoEnabled
                        }
                        // sTalk: Mark media as ready (for video state sync),
                        // but DON'T start timer or set connected — wait for remote to join via infoPublisher.
                        self.state.wasConnected = true
                    }
                }
                .store(in: &cancellables)
        } // end if !useNativeCall

        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                // sTalk: Update speaker button state + proximity sensor for earpiece
                let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first
                let isSpeaker = currentOutput?.portType == .builtInSpeaker
                let isEarpiece = currentOutput?.portType == .builtInReceiver
                Task { @MainActor in
                    self.state.isSpeakerOn = isSpeaker
                    UIDevice.current.isProximityMonitoringEnabled = isEarpiece
                }
            }
            .store(in: &cancellables)

        // sTalk: Subscribe to room info for live participant count updates
        if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
            roomProxy.infoPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] roomInfo in
                    guard let self else { return }
                    self.state.totalMembersCount = roomInfo.activeMembersCount
                    let callParticipants = roomInfo.activeRoomCallParticipants
                    let prevCount = self.state.callParticipantsCount
                    // STMOB: показываем максимум из двух источников. activeRoomCallParticipants
                    // — это m.call.member state events в Synapse, может отставать или не
                    // содержать участников чьи события застряли в sync. liveKit.remoteParticipants
                    // — реальное состояние медиа-сессии (видишь ли ты людей на экране). +1 за себя.
                    let liveKitTotal = self.liveKitRoomManager.displayParticipants.count + 1
                    self.state.callParticipantsCount = max(callParticipants.count, liveKitTotal)
                    self.state.activeCallParticipantIDs = callParticipants.map { $0 }
                    if callParticipants.count != prevCount {
                        MXLog.info("sTalk: MatrixRTC participants changed: \(prevCount) → \(callParticipants.count), users=\(callParticipants), liveKit remote=\(self.liveKitRoomManager.displayParticipants.count)")
                    }

                    // sTalk: For 1:1 — start timer only when BOTH participants are in the call.
                    // This prevents the timer from running during the lobby/connecting phase.
                    if self.state.isDirect,
                       self.state.callStatus != .connected,
                       callParticipants.count >= 2 {
                        self.state.callStatus = .connected
                        self.startCallTimer()
                        MXLog.info("sTalk: 1:1 call connected — both participants present")
                    }

                    // sTalk: For group — start timer when we see ourselves in call
                    if !self.state.isDirect,
                       self.state.callStatus != .connected,
                       callParticipants.contains(roomProxy.ownUserID) {
                        self.state.callStatus = .connected
                        self.startCallTimer()
                    }

                    // sTalk: Auto-end 1:1 call when remote party leaves.
                    // Check BOTH MatrixRTC (callParticipants) AND LiveKit (remoteParticipants).
                    // Grace period: 30 seconds to avoid race conditions with state sync.
                    if self.state.isDirect,
                       self.state.callStatus == .connected,
                       self.state.callElapsedTime > 30 {
                        let matrixRTCEmpty = callParticipants.isEmpty ||
                            (callParticipants.count == 1 && callParticipants.contains(roomProxy.ownUserID))
                        let liveKitEmpty = self.liveKitRoomManager.displayParticipants.isEmpty
                        MXLog.info("sTalk: Auto-end check — matrixRTC participants=\(callParticipants.count), liveKit remote=\(self.liveKitRoomManager.displayParticipants.count), elapsed=\(self.state.callElapsedTime)")
                        if matrixRTCEmpty, liveKitEmpty {
                            MXLog.info("sTalk: Remote party left 1:1 call (both MatrixRTC and LiveKit empty) — auto-ending")
                            Task { await self.endCall() }
                        }
                    }
                }
                .store(in: &cancellables)
        }

        // STMOB: дублируем апдейт callParticipantsCount при изменении LiveKit
        // remote participants — иначе counter застывает на значениях из последнего
        // Matrix roomInfo sync, а LiveKit может опережать sync (новый участник
        // появился медиа-сессии до того как m.call.member дошёл).
        //
        // STMOB-163 build 181: фильтруем .standard kind внутри closure — без
        // этого counter показывал "4 из 3" в звонке с recording (2 real users
        // + 2 EG_ egress). displayParticipants — computed property, через
        // Combine не emits, поэтому подписываемся на raw $remoteParticipants
        // и применяем filter здесь.
        liveKitRoomManager.$remoteParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                let realUsersCount = participants.filter { $0.kind == .standard }.count
                let liveKitTotal = realUsersCount + 1
                if liveKitTotal > self.state.callParticipantsCount {
                    self.state.callParticipantsCount = liveKitTotal
                }
            }
            .store(in: &cancellables)

        setupRecordingObserver()
        setupCall()
        loadParticipants()
    }
    
    override func process(viewAction: CallScreenViewAction) {
        switch viewAction {
        case .urlChanged(let url):
            guard let url else { return }
            MXLog.info("URL changed to: \(url)")
        case .pictureInPictureIsAvailable(let controller):
            actionsSubject.send(.pictureInPictureIsAvailable(controller))
        case .navigateBack:
            Task { await handleBackwardsNavigation() }
        case .pictureInPictureWillStop:
            isMinimized = false
            state.isMinimized = false
            // Same keyboard-overlap glitch as .restoreFromMinimized (see below) — system PiP restore.
            dismissKeyboard()
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            stalkLog(">>> .endCall viewAction received, isEndingCall=\(isEndingCall)")
            Task { await endCall() }
        case .mediaCapturePermissionGranted:
            // sTalk: Don't set wasConnected/timer here — wait for first mediaStateChanged
            // (the actual call connection signal). This prevents premature lobby detection.
            // sTalk: If voice call, explicitly disable camera in WebView
            // (don't use toggleVideo() — it inverts current state which is already false)
            if !startWithVideoEnabled {
                Task {
                    let message = ElementCallWidgetMessage(direction: .toWidget,
                                                           action: .mediaState,
                                                           data: .init(videoEnabled: false),
                                                           widgetId: self.widgetDriver.widgetID)
                    await self.postMessageToWidget(message)
                }
            }
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        case .toggleRecording:
            handleToggleRecording()
        case .confirmStartRecording:
            Task { await startRecording() }
        case .toggleMute:
            Task { await toggleMute() }
        case .toggleDeafen:
            toggleDeafen()
        case .toggleVideo:
            Task { await toggleVideo() }
        case .showSpeakerPicker:
            state.bindings.showSpeakerPickerHandler?()
        case .toggleSpeaker:
            toggleSpeaker()
        case .toggleHandRaise:
            Task { await toggleHandRaise() }
        case .toggleScreenShare:
            Task { await toggleScreenShare() }
        case .toggleBackgroundBlur:
            toggleBackgroundBlur()
        case .handRaiseStateChanged(let raised):
            state.isHandRaised = raised
        case .restoreFromMinimized:
            isMinimized = false
            state.isMinimized = false
            // If the user was typing in a chat beneath the mini call window, the keyboard stays up
            // when the call goes fullscreen again and overlaps the restored call UI. Resign whatever
            // is first responder app-wide before restoring (the composer draft is preserved).
            dismissKeyboard()
            actionsSubject.send(.pictureInPictureStopped)
        case .toggleLayoutMode:
            // STMOB-113: ручной toggle Grid ↔ Speaker. Override побеждает auto-логику
            // (>8 участников → speaker по умолчанию). При hangup сбрасывается в `stop()`.
            let current = state.effectiveLayoutMode
            state.layoutOverride = (current == .grid) ? .speaker : .grid
            MXLog.info("STMOB-113 layoutOverride → \(state.layoutOverride == .speaker ? "speaker" : "grid")")
        case .togglePinParticipant(let sid):
            // STMOB-113: pin/unpin в Speaker mode. Если pin совпадает с текущим
            // — сбрасываем (unpin); иначе закрепляем нового.
            if state.pinnedParticipantSID == sid {
                state.pinnedParticipantSID = nil
                MXLog.info("STMOB-113 unpin")
            } else {
                state.pinnedParticipantSID = sid
                MXLog.info("STMOB-113 pin → \(sid)")
            }
        case .requestPortraitOrientation:
            // STMOB-218: leave the landscape fullscreen-share view back to portrait.
            actionsSubject.send(.requestPortraitOrientation)
        case .liveKitCredentialsIntercepted(let url, let token):
            MXLog.info("sTalk: LiveKit credentials intercepted (pass-through) — url=\(url.prefix(80))..., token length=\(token.count)")
            // sTalk: Extract LiveKit room name from JWT for recording-api
            if let roomName = extractRoomNameFromJWT(token) {
                interceptedLiveKitRoomName = roomName
                MXLog.info("sTalk: Extracted LiveKit room name from JWT: \(roomName)")
            }
            state.wasConnected = true
        }
    }
    
    func stop() {
        callTimerTask = nil
        recordingPollingTask?.cancel()
        recordingPollingTask = nil
        // STMOB-113: per-call layout override / pin сбрасываем при hangup.
        state.layoutOverride = nil
        state.pinnedParticipantSID = nil
        MXLog.info("sTalk: stop() called — safety net cleanup")
        // Re-allow auto-lock now that call is ending.
        UIApplication.shared.isIdleTimerDisabled = false

        // Safety net: вызывается координатором при удалении.
        Task {
            // Очистить MatrixRTC state event через REST API
            if case .roomCall(let roomProxy, let clientProxy, _, _, _, _) = configuration.kind {
                await sendLeaveCallStateEventViaREST(roomProxy: roomProxy, clientProxy: clientProxy)
            }
            await sendDirectlyToWidgetDriver(.hangup)
            await sendDirectlyToWidgetDriver(.close)

            if liveKitRoomManager.connectionState != .disconnected {
                await liveKitRoomManager.disconnect()
            }
        }

        // Teardown immediately (как upstream — вне Task)
        elementCallService.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false
    }
    
    // MARK: - Private

    private func handleWidgetAction(message: String) async {
        if timeoutTask != nil,
           let decodedMessage = try? DecodedWidgetMessage.decode(message: message),
           decodedMessage.hasLoaded {
            // This means that the call room was joined succesfully, we can stop the timeout task
            timeoutTask = nil
        }
        await widgetDriver.handleMessage(message)
    }
    
    private func setupCall() {
        // Prevent iOS auto-lock during active call. Resets in stop().
        UIApplication.shared.isIdleTimerDisabled = true
        switch configuration.kind {
        case .genericCallLink(let url):
            state.url = url
            // We need widget messaging to work before enabling CallKit, otherwise mute, hangup etc do nothing.
            
        case .roomCall(let roomProxy, let clientProxy, let clientID, let elementCallBaseURL, let elementCallBaseURLOverride, let colorScheme):
            Task { [weak self] in
                guard let self else { return }

                let baseURL = if let elementCallBaseURLOverride {
                    elementCallBaseURLOverride
                } else {
                    elementCallBaseURL
                }

                // sTalk: Native call mode — no WebView, WidgetDriver + native LiveKit SDK
                if useNativeCall {
                    MXLog.info("sTalk: Starting NATIVE call mode")
                    let isEncrypted = roomProxy.infoPublisher.value.isEncrypted
                    let token = (try? (clientProxy as? ClientProxy)?.matrixAccessToken()) ?? ""
                    let session = NativeCallSession(widgetDriver: widgetDriver,
                                                    liveKitRoomManager: liveKitRoomManager,
                                                    isEncrypted: isEncrypted,
                                                    userId: clientProxy.userID,
                                                    // STMOB-232: своё имя в LiveKit JWT, чтобы другие видели имя, не userID
                                                    displayName: clientProxy.userDisplayNamePublisher.value,
                                                    deviceId: clientProxy.deviceID ?? "unknown",
                                                    matrixRoomId: roomProxy.id,
                                                    homeserverURL: clientProxy.homeserver,
                                                    accessToken: token,
                                                    roomProxy: roomProxy)
                    self.nativeCallSession = session

                    // Observe session state
                    session.$sessionState
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] sessionState in
                            guard let self else { return }
                            switch sessionState {
                            case .connected:
                                self.state.liveKitRoomManager = self.liveKitRoomManager
                                self.state.wasConnected = true
                                // STMOB-80: header «Вызов...» застревал — нужен явный
                                // переход в connected + старт таймера. Раньше зависело
                                // только от MatrixRTC infoPublisher, который опаздывал.
                                if self.state.callStatus != .connected {
                                    self.state.callStatus = .connected
                                    self.startCallTimer()
                                    MXLog.info("sTalk: callStatus=connected via NativeCallSession")
                                }
                                // STMOB-80: subscribe на LiveKit localVideoTrack чтобы
                                // icon камеры всегда отражал реальность. Раньше observe
                                // подключалось только в старом connectNativeLiveKit пути.
                                self.observeLiveKitState()
                                // NativeCallSession always enables camera on connect.
                                // Sync UI state and disable if incoming call (startWithVideoEnabled=false)
                                if self.startWithVideoEnabled {
                                    self.state.isVideoEnabled = true
                                } else {
                                    Task {
                                        try? await self.liveKitRoomManager.setCamera(enabled: false)
                                        self.state.isVideoEnabled = false
                                    }
                                }
                            case .failed:
                                self.actionsSubject.send(.dismiss)
                            case .disconnected:
                                self.actionsSubject.send(.dismiss)
                            default:
                                break
                            }
                        }
                        .store(in: &cancellables)

                    // Start native session
                    await session.start(baseURL: baseURL,
                                        clientID: clientID,
                                        colorScheme: colorScheme)

                    // Note: NOT calling elementCallService.setupCallSession —
                    // CallKit would kill the call when WidgetDriver times out.
                    // Native SDK manages call lifecycle independently.
                    // STMOB-130 build 153: но публикуем roomID для RoomScreen
                    // (чтобы «Присоединиться к звонку» плашка скрывалась когда
                    // юзер уже в native звонке этой комнаты) — БЕЗ CallKit.
                    elementCallService.markNativeCallActive(roomID: roomProxy.id)
                    return
                }

                // WebView mode (default)
                // We only set the analytics configuration if analytics are enabled
                let analyticsConfiguration: ElementCallAnalyticsConfiguration? = if analyticsService.isEnabled {
                    .init(posthogAPIHost: appSettings.elementCallPosthogAPIHost,
                          posthogAPIKey: appSettings.elementCallPosthogAPIKey,
                          sentryDSN: appSettings.elementCallPosthogSentryDSN)
                } else {
                    nil
                }
                let rageshakeURL: String? = if case let .url(baseURL) = appSettings.bugReportRageshakeURL.publisher.value {
                    baseURL.absoluteString
                } else {
                    nil
                }

                switch await widgetDriver.start(baseURL: baseURL,
                                                clientID: clientID,
                                                colorScheme: colorScheme,
                                                rageshakeURL: rageshakeURL,
                                                analyticsConfiguration: analyticsConfiguration) {
                case .success(let url):
                    state.url = url
                case .failure(let error):
                    MXLog.error("Failed starting ElementCall Widget Driver with error: \(error)")
                    state.bindings.alertInfo = .init(id: UUID(),
                                                     title: L10n.errorUnknown,
                                                     primaryButton: .init(title: L10n.actionOk) {
                                                         self.actionsSubject.send(.dismiss)
                                                     })
                    return
                }

                await elementCallService.setupCallSession(roomID: roomProxy.id,
                                                          roomDisplayName: roomProxy.infoPublisher.value.displayName ?? roomProxy.id)
            }
            
            // No timeout in native mode — native SDK manages lifecycle
            guard !useNativeCall else { return }

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                MXLog.error("Failed to join Element Call: Timeout")
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: L10n.commonError,
                                                 message: L10n.errorUnknown,
                                                 primaryButton: .init(title: L10n.actionDismiss) { [weak self] in self?.actionsSubject.send(.dismiss) })
                timeoutTask = nil
            }
        }
    }
    
    private func handleBackwardsNavigation() async {
        // sTalk: WebView is 0×0 for Widget API only — PiP via WebView won't work.
        // Always use the minimize overlay (SwiftUI mini-window with native video).
        isMinimized = true
        state.isMinimized = true
        actionsSubject.send(.minimizeCall)
    }
    
    private func setAudioEnabled(_ enabled: Bool) async {
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .mediaState,
                                               data: .init(audioEnabled: enabled),
                                               widgetId: widgetDriver.widgetID)
        await postMessageToWidget(message)
    }
    
    func hangup() async {
        let message = ElementCallWidgetMessage(direction: .fromWidget,
                                               action: .hangup,
                                               widgetId: widgetDriver.widgetID)
        
        await postMessageToWidget(message)
    }
    
    private func postMessageToWidget(_ message: ElementCallWidgetMessage) async {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            MXLog.error("Failed encoding widget message with error: \(error)")
            return
        }
        
        guard let json = String(data: data, encoding: .utf8) else {
            MXLog.error("Invalid data for widget message")
            return
        }
        
        await postJSONToWidget(json)
    }
    
    private func postJSONToWidget(_ json: String) async {
        do {
            let message = "postMessage(\(json), '*')"
            let result = try await state.bindings.javaScriptEvaluator?(message)
            MXLog.debug("Evaluated javascript: \(json) with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
    
    // MARK: - Native LiveKit

    /// sTalk: Decode JWT token payload to extract LiveKit room name
    private func extractRoomNameFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        // Fix base64 padding
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let video = json["video"] as? [String: Any],
              let roomName = video["room"] as? String else {
            // Fallback: try top-level "room" claim
            if let data = Data(base64Encoded: base64),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let roomName = json["room"] as? String {
                return roomName
            }
            return nil
        }
        return roomName
    }

    private func connectNativeLiveKit(wsURL: String, token: String) async {
        MXLog.info("sTalk: connectNativeLiveKit called, wsURL prefix=\(wsURL.prefix(60))")
        // Only connect once
        guard liveKitRoomManager.connectionState == .disconnected else {
            MXLog.info("sTalk: Already connected, skipping")
            MXLog.info("sTalk LiveKit: Already connected or connecting, skipping")
            return
        }

        // sTalk: Отменить 10-секундный таймаут — LiveKit credentials получены,
        // значит EC загрузился достаточно для Widget API. С фейковым WebSocket
        // EC не отправит content_loaded, но нативный SDK берёт контроль.
        timeoutTask = nil

        // Step 1: Connect to SFU (critical — if this fails, we can't proceed)
        do {
            // 1:1 calls → earpiece (like Telegram), group calls → speaker
            let useSpeaker = !state.isDirect
            try await liveKitRoomManager.connect(wsURL: wsURL, token: token, speakerByDefault: useSpeaker)
            state.isSpeakerOn = useSpeaker
            MXLog.info("sTalk LiveKit: Native connection established")
        } catch {
            MXLog.error("sTalk LiveKit: Failed to connect to SFU: \(error)")
            return
        }

        // Connection succeeded — expose room manager to UI
        state.liveKitRoomManager = liveKitRoomManager
        state.wasConnected = true

        // Ring notification is now sent by NativeCallSession.sendCallNotification()
        // immediately after sendJoinViaREST(), with proper user_ids and m.relates_to.

        // Small delay to let audio session stabilize
        try? await Task.sleep(for: .milliseconds(200))

        // Step 2: Enable microphone (non-fatal — may fail on simulator)
        do {
            try await liveKitRoomManager.setMicrophone(enabled: true)
            MXLog.info("sTalk LiveKit: Microphone enabled")
        } catch {
            MXLog.error("sTalk LiveKit: Microphone enable failed (non-fatal): \(error)")
        }

        // Step 3: Enable camera
        // On simulator: ALWAYS publish fake video to verify pipeline (color-cycling track)
        // On device: only if video call was requested
        #if targetEnvironment(simulator)
        do {
            try await liveKitRoomManager.setCamera(enabled: true)
            state.isVideoEnabled = true
            MXLog.info("sTalk LiveKit: Camera enabled (simulator — fake video track)")
        } catch {
            MXLog.error("sTalk LiveKit: Simulator camera failed: \(error)")
        }
        #else
        if startWithVideoEnabled {
            do {
                try await liveKitRoomManager.setCamera(enabled: true)
                MXLog.info("sTalk LiveKit: Camera enabled")
            } catch {
                MXLog.error("sTalk LiveKit: Camera enable failed (non-fatal): \(error)")
                state.isVideoEnabled = false
            }
        }
        #endif

        // Diagnostic: verify tracks were actually published
        liveKitRoomManager.logTrackDiagnostics()

        // Observe native LiveKit connection state for call lifecycle
        observeLiveKitState()
    }

    private func observeLiveKitState() {
        // STMOB-80: sync icon камеры с реальным состоянием LiveKit local video track.
        // Раньше state.isVideoEnabled зависел только от startWithVideoEnabled / widget
        // mediaStateChanged. Для incoming video call iOS получает startWithVideoEnabled=false
        // (default voice), но widget сам включает камеру → reality video, icon перечёркнут.
        // localVideoTrack == nil → camera off, != nil → camera on.
        liveKitRoomManager.$localVideoTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                let cameraOn = track != nil
                if self.state.isVideoEnabled != cameraOn {
                    self.state.isVideoEnabled = cameraOn
                    MXLog.info("sTalk: LiveKit localVideoTrack changed — isVideoEnabled=\(cameraOn)")
                }
            }
            .store(in: &cancellables)

        liveKitRoomManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connectionState in
                guard let self else { return }
                switch connectionState {
                case .connected:
                    MXLog.info("sTalk LiveKit: Connected state observed")
                    // Restore from reconnecting state
                    if self.state.callStatus == .reconnecting {
                        self.state.callStatus = .connected
                        MXLog.info("sTalk LiveKit: Reconnected successfully")
                    }
                    // STMOB-80: Fallback initial connected. roomProxy.infoPublisher
                    // (MatrixRTC participants) может задержаться или не emit'ить
                    // — header застревает на «Вызов...», timer не запускается.
                    // Если LiveKit подключился — звонок реально идёт, переключаем
                    // status даже без MatrixRTC update.
                    if self.state.callStatus == .connecting {
                        self.state.callStatus = .connected
                        self.state.wasConnected = true
                        self.startCallTimer()
                        MXLog.info("sTalk: Initial connected via LiveKit (MatrixRTC infoPublisher fallback)")
                    }
                case .reconnecting:
                    self.state.callStatus = .reconnecting
                    MXLog.info("sTalk LiveKit: Reconnecting...")
                case .disconnected:
                    if self.state.wasConnected {
                        MXLog.info("sTalk LiveKit: Disconnected after being connected — remote may have ended call")
                        // NativeCallSession handles auto-end via its own connectionState/participants observers
                        // which triggers sessionState → .disconnected → dismiss in setupCall()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Native Call Controls

    private func toggleMute() async {
        let oldMuted = state.isMuted
        let newMuted = !oldMuted
        state.isMuted = newMuted
        DiagLog.write("CallUI", "toggleMute tap: state.isMuted \(oldMuted) → \(newMuted), callStatus=\(state.callStatus)")

        // sTalk: Use native LiveKit SDK for mute control
        if state.liveKitRoomManager != nil {
            do {
                try await liveKitRoomManager.setMicrophone(enabled: !newMuted)
                DiagLog.write("CallUI", "  toggleMute: LiveKit setMicrophone(\(!newMuted)) ok")
            } catch {
                MXLog.error("sTalk LiveKit: Failed to toggle microphone: \(error)")
                DiagLog.write("CallUI", "  toggleMute: LiveKit setMicrophone FAILED: \(error.localizedDescription)")
            }
        }

        // Also notify Widget API for MatrixRTC state sync
        await setAudioEnabled(!newMuted)
    }

    /// STMOB-219: deafen — mute/unmute all incoming audio (does not touch the mic).
    private func toggleDeafen() {
        let newDeafened = !state.isDeafened
        state.isDeafened = newDeafened
        liveKitRoomManager.setDeafened(newDeafened)
        MXLog.info("sTalk: Deafen toggled to \(newDeafened ? "ON" : "OFF")")
        DiagLog.write("CallUI", "toggleDeafen tap: state.isDeafened → \(newDeafened), callStatus=\(state.callStatus)")
    }

    /// Resigns the app-wide first responder. Used when the call returns to fullscreen: a keyboard
    /// opened in the chat beneath the mini call window would otherwise stay up over the call UI.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func toggleSpeaker() {
        let oldSpeakerOn = state.isSpeakerOn
        let newSpeakerOn = !oldSpeakerOn
        state.isSpeakerOn = newSpeakerOn
        liveKitRoomManager.setSpeaker(enabled: newSpeakerOn)
        MXLog.info("sTalk: Speaker toggled to \(newSpeakerOn ? "ON (speaker)" : "OFF (earpiece)")")
        DiagLog.write("CallUI", "toggleSpeaker tap: state.isSpeakerOn \(oldSpeakerOn) → \(newSpeakerOn), callStatus=\(state.callStatus)")
    }

    private func toggleVideo() async {
        let oldVideoEnabled = state.isVideoEnabled
        let newVideoEnabled = !oldVideoEnabled
        state.isVideoEnabled = newVideoEnabled
        let liveKitTrack = liveKitRoomManager.localVideoTrack != nil
        DiagLog.write("CallUI", "toggleVideo tap: state.isVideoEnabled \(oldVideoEnabled) → \(newVideoEnabled), liveKit.localVideoTrack=\(liveKitTrack), callStatus=\(state.callStatus)")

        // sTalk: Use native LiveKit SDK for camera control
        if state.liveKitRoomManager != nil {
            do {
                try await liveKitRoomManager.setCamera(enabled: newVideoEnabled)
                let trackAfter = liveKitRoomManager.localVideoTrack != nil
                DiagLog.write("CallUI", "  toggleVideo: LiveKit setCamera(\(newVideoEnabled)) ok, track=\(trackAfter)")
            } catch {
                MXLog.error("sTalk LiveKit: Failed to toggle camera: \(error)")
                DiagLog.write("CallUI", "  toggleVideo: LiveKit setCamera FAILED: \(error.localizedDescription)")
            }
        }

        // Also notify Widget API for MatrixRTC state sync
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .mediaState,
                                               data: .init(videoEnabled: newVideoEnabled),
                                               widgetId: widgetDriver.widgetID)
        await postMessageToWidget(message)
    }

    private func endCall() async {
        DiagLog.write("CallUI", "endCall tap: isEndingCall=\(isEndingCall) callStatus=\(state.callStatus) elapsed=\(state.callElapsedTime)")
        // sTalk: Guard against cascade — infoPublisher fires multiple times
        guard !isEndingCall else {
            stalkLog("endCall — already ending, skipping duplicate")
            DiagLog.write("CallUI", "  endCall: already ending, skip")
            return
        }
        isEndingCall = true
        recordingPollingTask?.cancel()
        recordingPollingTask = nil
        stalkLog("endCall — начинаю завершение звонка")

        // STMOB-115 build 139: каждый шаг с timeout. Если любой await зависает
        // (network/SDK deadlock), переходим дальше. Финальный dismiss гарантирован
        // через defer — иначе UI не закрывается, юзер тыкает endCall, watchdog
        // убивает app (наблюдалось 13 endCall taps + 0xDEADBEEC через 36 мин).
        defer {
            DiagLog.write("CallUI", "endCall: dismiss (forced after timeout-bounded cleanup)")
            elementCallService.tearDownCallSession()
            // STMOB-130: очистить native call marker (для native path tearDown
            // не выставляет ongoingCallID=nil, нужно отдельно).
            elementCallService.markNativeCallActive(roomID: nil)
            UIDevice.current.isProximityMonitoringEnabled = false
            actionsSubject.send(.dismiss)
        }

        // 1. Остановить запись (до закрытия звонка, иначе ABORTED)
        if let recordingService, recordingService.state.isRecording {
            await Self.withDeadline(5, label: "[1] stopRecording") {
                do {
                    try await recordingService.stopRecording()
                } catch {
                    stalkLog("[1] Recording cleanup error: \(error)")
                }
            }
        }

        // 2. Очистить MatrixRTC state event через REST API (основной метод)
        if case .roomCall(let roomProxy, let clientProxy, _, _, _, _) = configuration.kind {
            await Self.withDeadline(5, label: "[2] sendLeaveCallStateEventViaREST") {
                await self.sendLeaveCallStateEventViaREST(roomProxy: roomProxy, clientProxy: clientProxy)
            }
        }

        // 3. Отправить .hangup + .close через Widget API (для Rust SDK cleanup)
        await Self.withDeadline(3, label: "[3a] widgetDriver hangup") {
            await self.sendDirectlyToWidgetDriver(.hangup)
        }
        await Self.withDeadline(3, label: "[3b] widgetDriver close") {
            await self.sendDirectlyToWidgetDriver(.close)
        }

        // 4. Отключить нативный LiveKit SDK
        let nativeSessionToStop = nativeCallSession
        nativeCallSession = nil
        await Self.withDeadline(5, label: "[4] LiveKit disconnect") { [weak liveKitRoomManager] in
            if let nativeSessionToStop {
                await nativeSessionToStop.stop()
            } else {
                await liveKitRoomManager?.disconnect()
            }
        }
        // CallKit teardown + dismiss — в defer выше (гарантированно).
    }

    /// STMOB-115: запускает async-операцию с дедлайном. Если operation не успел
    /// закончиться за `seconds` — логируем и проваливаемся дальше. Использует
    /// withTaskGroup для race operation vs sleep, без бросания exceptions
    /// (cleanup не должен ломаться на любом единичном шаге).
    private static func withDeadline(_ seconds: TimeInterval,
                                     label: String,
                                     operation: @escaping @Sendable () async -> Void) async {
        DiagLog.write("CallUI", "\(label) start (deadline=\(Int(seconds))s)")
        let timedOut: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        DiagLog.write("CallUI", "\(label) \(timedOut ? "TIMEOUT" : "done")")
    }

    /// Send a widget message directly to the Rust SDK widget driver, bypassing the WebView JS bridge.
    /// postMessageToWidget() goes through WebView → JS postMessage() → async handler chain,
    /// which fails if WebView is 1x1 or deallocated. This calls widgetDriver.handleMessage() directly.
    private func sendDirectlyToWidgetDriver(_ action: ElementCallWidgetMessage.Action) async {
        let msg = ElementCallWidgetMessage(direction: .fromWidget,
                                           action: action,
                                           widgetId: widgetDriver.widgetID)
        guard let data = try? JSONEncoder().encode(msg),
              let json = String(data: data, encoding: .utf8) else {
            stalkLog("FAILED to encode \(action.rawValue) message")
            return
        }
        stalkLog("Sending \(action.rawValue) directly to Rust SDK, json=\(json.prefix(200))")
        let result = await widgetDriver.handleMessage(json)
        stalkLog("\(action.rawValue) sent to Rust SDK, result = \(result)")
    }

    /// sTalk: Send Widget API `send_event` to clear the MatrixRTC call.member state event.
    /// In upstream, Element Call sends this automatically when it processes hangup.
    /// Since our EC is hidden (1x1), it never processes hangup, so we send it manually.
    private func sendLeaveCallStateEvent() async {
        guard case .roomCall(_, let clientProxy, _, _, _, _) = configuration.kind else {
            stalkLog("sendLeaveCallStateEvent: not a room call, skipping")
            return
        }

        let userID = clientProxy.userID
        let deviceID = clientProxy.deviceID ?? "unknown"
        let widgetId = widgetDriver.widgetID

        // Try both event types and state key formats
        let eventTypes = ["org.matrix.msc3401.call.member"]
        // Per-device state key (MSC4143): _@user:server_DEVICEID
        // Legacy state key (MSC3401): @user:server
        let stateKeys = ["_\(userID)_\(deviceID)", userID]

        for eventType in eventTypes {
            for stateKey in stateKeys {
                let json = """
                {"api":"fromWidget","requestId":"\(UUID().uuidString)","action":"send_event","widgetId":"\(widgetId)","data":{"type":"\(eventType)","state_key":"\(stateKey)","content":{"memberships":[]}}}
                """
                stalkLog("send_event: type=\(eventType) state_key=\(stateKey)")
                let result = await widgetDriver.handleMessage(json)
                stalkLog("send_event result: \(result)")
            }
        }
    }

    /// sTalk: Fallback — clear call.member state event directly via Matrix REST API.
    /// First GET all call.member state events to find the real state keys, then PUT empty memberships.
    private func sendLeaveCallStateEventViaREST(roomProxy: JoinedRoomProxyProtocol, clientProxy: ClientProxyProtocol) async {
        let userID = clientProxy.userID
        let homeserver = clientProxy.homeserver

        // Get room ID
        let roomID = roomProxy.id

        // Get access token
        guard let concreteProxy = clientProxy as? ClientProxy else {
            stalkLog("REST fallback: cannot cast to ClientProxy")
            return
        }

        let accessToken: String
        do {
            accessToken = try concreteProxy.matrixAccessToken()
        } catch {
            stalkLog("REST fallback: failed to get access token: \(error)")
            return
        }

        // Fix trailing slash in homeserver URL
        let baseURL = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        stalkLog("REST fallback: token len=\(accessToken.count), baseURL=\(baseURL), roomID=\(roomID)")

        // Step 1: GET all room state to find actual call.member events and their state keys
        let encodedRoom = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        let stateURL = "\(baseURL)/_matrix/client/v3/rooms/\(encodedRoom)/state"
        stalkLog("REST GET: \(stateURL)")

        var stateKeysToClean: [(eventType: String, stateKey: String)] = []

        do {
            var req = URLRequest(url: URL(string: stateURL)!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            stalkLog("REST GET state: status=\(statusCode)")

            if statusCode == 200, let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for event in events {
                    guard let type = event["type"] as? String,
                          type == "org.matrix.msc3401.call.member" || type == "m.call.member",
                          let sk = event["state_key"] as? String else { continue }

                    let content = event["content"] as? [String: Any] ?? [:]
                    let memberships = content["memberships"] as? [[String: Any]] ?? []
                    stalkLog("Found call.member: type=\(type) state_key=\(sk) memberships=\(memberships.count)")

                    // Only clear events that have our user ID in the state key or have non-empty memberships for our user
                    if sk.contains(userID) || memberships.contains(where: { ($0["user_id"] as? String) == userID }) {
                        stateKeysToClean.append((eventType: type, stateKey: sk))
                        stalkLog("  → will clear this one (matches our userID)")
                    } else if sk == userID || sk.hasPrefix("_\(userID)") {
                        stateKeysToClean.append((eventType: type, stateKey: sk))
                        stalkLog("  → will clear this one (state_key matches)")
                    } else {
                        stalkLog("  → skipping (not ours)")
                    }
                }
            }
        } catch {
            stalkLog("REST GET state error: \(error)")
        }

        stalkLog("REST: found \(stateKeysToClean.count) call.member events to clear")

        // Step 2: PUT empty memberships for each found state key
        for item in stateKeysToClean {
            let encodedType = item.eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.eventType
            let encodedKey = item.stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.stateKey
            let urlString = "\(baseURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedKey)"

            guard let url = URL(string: urlString) else {
                stalkLog("REST PUT: invalid URL: \(urlString)")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{\"memberships\":[]}".data(using: .utf8)

            stalkLog("REST PUT: \(urlString)")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "nil"
                stalkLog("REST PUT result: status=\(statusCode) body=\(body.prefix(200))")
            } catch {
                stalkLog("REST PUT error: \(error)")
            }
        }

        // If we didn't find any events to clear, log the full state for debugging
        if stateKeysToClean.isEmpty {
            stalkLog("REST: NO call.member events found for our user! Check state dump above.")
        }
    }

    private func toggleHandRaise() async {
        // Native LiveKit mode: use participant metadata
        if state.liveKitRoomManager != nil {
            let newValue = !state.isHandRaised
            do {
                try await liveKitRoomManager.setHandRaise(enabled: newValue)
                state.isHandRaised = newValue
                // STMOB-154 build 178: параллельно отправляем Matrix m.reaction.
                // LiveKit metadata path покрывает iOS↔iOS и iOS↔guest. Web Element
                // Call widget слушает только Matrix m.reaction, не LK metadata —
                // без этого Web участники не видят руку iOS host.
                await nativeCallSession?.sendHandRaiseReaction(raised: newValue)
            } catch {
                MXLog.error("sTalk: Failed to toggle hand raise: \(error)")
            }
            return
        }
        // Fallback: WebView JS
        do {
            _ = try await state.bindings.javaScriptEvaluator?("window.stalkToggleHandRaise()")
        } catch {
            MXLog.error("Failed to toggle hand raise: \(error)")
        }
    }

    // Ring notification is now handled by NativeCallSession.sendCallNotification()
    // which sends it right after sendJoinViaREST() with the event_id from the response.

    private func toggleScreenShare() async {
        let newValue = !state.isScreenSharing
        do {
            try await liveKitRoomManager.setScreenShare(enabled: newValue)
            state.isScreenSharing = newValue
            MXLog.info("sTalk: Screen sharing \(newValue ? "started" : "stopped")")
        } catch {
            MXLog.error("sTalk: Failed to toggle screen share: \(error)")
        }
    }

    private func toggleBackgroundBlur() {
        let newValue = !state.isBackgroundBlurEnabled
        liveKitRoomManager.setBackgroundBlur(enabled: newValue)
        state.isBackgroundBlurEnabled = newValue
    }

    // MARK: - Recording

    private func setupRecordingObserver() {
        guard let recordingService else {
            state.isRecordingEnabled = false
            MXLog.warning("sTalk: Recording service is nil — recording button disabled")
            return
        }

        MXLog.info("sTalk: Recording service available, button enabled")

        recordingService.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordingState in
                MXLog.info("sTalk: Recording state changed: \(recordingState)")
                self?.state.recordingState = recordingState
            }
            .store(in: &cancellables)
    }

    private func handleToggleRecording() {
        guard let recordingService else {
            MXLog.error("sTalk: Recording toggle failed — service is nil")
            return
        }

        if recordingService.state.isRecording {
            Task { await stopRecording() }
        } else {
            // Show consent dialog before starting
            actionsSubject.send(.showRecordingConsent)
        }
    }

    private func startRecording() async {
        guard let recordingService else {
            MXLog.error("sTalk: startRecording failed — service is nil")
            return
        }

        // Get room info and participant metadata from configuration
        let roomName: String
        var matrixRoomId: String?
        var participants: [(userId: String, displayName: String)]?
        var initiatedBy: String?

        switch configuration.kind {
        case .genericCallLink(let url):
            roomName = url.lastPathComponent

        case .roomCall(let roomProxy, let clientProxy, _, _, _, _):
            // sTalk: Use LiveKit room name for recording-api (not Matrix room ID)
            roomName = liveKitRoomManager.roomName ?? interceptedLiveKitRoomName ?? roomProxy.id
            matrixRoomId = roomProxy.id
            initiatedBy = clientProxy.userID

            // Get participant info from room members
            if let members = await roomProxy.members() {
                participants = members
                    .filter(\.isActive)
                    .map { ($0.userID, $0.displayName ?? $0.userID) }
            }
        }

        do {
            let egressId = try await recordingService.startRecording(roomName: roomName,
                                                                     matrixRoomId: matrixRoomId,
                                                                     participants: participants,
                                                                     initiatedBy: initiatedBy)
            MXLog.info("Recording started with egress ID: \(egressId)")

            // sTalk: Link recording to call history
            if let currentCallID {
                localCallHistoryService?.linkRecording(callID: currentCallID, egressId: egressId)
            }
        } catch {
            MXLog.error("Failed to start recording: \(error)")
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: L10n.commonError,
                                             message: error.localizedDescription,
                                             primaryButton: .init(title: L10n.actionOk, action: nil))
        }
    }

    private func stopRecording() async {
        guard let recordingService else { return }

        // Get recording duration before stopping
        let recordingDuration = recordingService.state.recordingDuration ?? 0

        do {
            try await recordingService.stopRecording()
            MXLog.info("Recording stopped")
        } catch {
            MXLog.error("Failed to stop recording: \(error)")
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: L10n.commonError,
                                             message: error.localizedDescription,
                                             primaryButton: .init(title: L10n.actionOk, action: nil))
        }
    }

    // MARK: - Participants

    private func loadParticipants() {
        guard case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind else { return }

        Task { [weak self] in
            guard let members = await roomProxy.members() else { return }
            guard let self else { return }

            let participants = members
                .filter(\.isActive)
                .map { CallParticipantInfo(userID: $0.userID, displayName: $0.displayName, avatarURL: $0.avatarURL) }

            await MainActor.run {
                self.state.participants = participants
            }
        }
    }

    // MARK: - Call Timer

    private func startCallTimer() {
        callTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.state.callElapsedTime += 1
                }
            }
        }

        // sTalk: Start polling for remote recording
        startRecordingPolling()
    }

    // MARK: - Remote Recording Polling

    /// sTalk: Poll recording-api every 5 seconds to detect if another participant started recording
    private func startRecordingPolling() {
        recordingPollingTask?.cancel()
        stalkLog("startRecordingPolling: starting, callRoomID=\(configuration.callRoomID)")
        recordingPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }

                // Skip if we're recording locally — we already show indicator
                if self.state.recordingState.isRecording { continue }

                guard let recordingService = self.recordingService else { continue }

                let matrixRoomId = self.configuration.callRoomID
                let hasRemote = await recordingService.hasActiveRecordingInRoom(matrixRoomId: matrixRoomId)
                stalkLog("recordingPoll: matrixRoomId=\(matrixRoomId.prefix(30)), hasRemote=\(hasRemote)")
                await MainActor.run {
                    if self.state.isRemoteRecording != hasRemote {
                        self.state.isRemoteRecording = hasRemote
                        if hasRemote {
                            MXLog.info("sTalk: Remote recording detected for room \(matrixRoomId)")
                        } else {
                            MXLog.info("sTalk: Remote recording stopped for room \(matrixRoomId)")
                        }
                    }
                }
            }
        }
    }
}
