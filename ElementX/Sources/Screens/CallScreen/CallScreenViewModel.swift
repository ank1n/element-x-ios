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
import SwiftUI

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

    /// sTalk: Tracks whether the call is currently minimized (prevents spurious dismiss on opacity:0)
    private(set) var isMinimized = false

    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    @CancellableTask
    private var timeoutTask: Task<Void, Never>?

    @CancellableTask
    private var callTimerTask: Task<Void, Never>?
        
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
        
        widgetDriver.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedMessage in
                guard let self else { return }
                
                Task {
                    await self.postJSONToWidget(receivedMessage)
                }
            }
            .store(in: &cancellables)
        
        widgetDriver.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .callEnded:
                    // sTalk: WebView is now always visible (mini window or fullscreen),
                    // so .callEnded is only fired when the call actually ends.
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
        
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                // sTalk: Update speaker button state
                let isSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType == .builtInSpeaker
                Task { @MainActor in
                    self.state.isSpeakerOn = isSpeaker
                }
                Task { await self.updateOutputsListOnWeb() }
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
                    self.state.callParticipantsCount = callParticipants.count

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
                    // Grace period: 5+ seconds after connection to avoid race conditions.
                    if self.state.isDirect,
                       self.state.callStatus == .connected,
                       self.state.callElapsedTime > 5 {
                        if callParticipants.isEmpty ||
                           (callParticipants.count == 1 && callParticipants.contains(roomProxy.ownUserID)) {
                            MXLog.info("sTalk: Remote party left 1:1 call — auto-ending")
                            Task { await self.endCall() }
                        }
                    }
                }
                .store(in: &cancellables)
        }

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
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            Task { await endCall() }
        case .mediaCapturePermissionGranted:
            // sTalk: Don't set wasConnected/timer here — wait for first mediaStateChanged
            // (the actual call connection signal). This prevents premature lobby detection.
            Task { await updateOutputsListOnWeb() }
            // sTalk: Set body class for conditional CSS (direct vs group)
            Task {
                let bodyClass = self.state.isDirect ? "stalk-direct" : "stalk-group"
                _ = try? await self.state.bindings.javaScriptEvaluator?("document.body.classList.add('\(bodyClass)')")
            }
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
        case .outputDeviceSelected(deviceID: let deviceID):
            handleOutputDeviceSelected(deviceID: deviceID)
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        case .toggleRecording:
            handleToggleRecording()
        case .confirmStartRecording:
            Task { await startRecording() }
        case .toggleMute:
            Task { await toggleMute() }
        case .toggleVideo:
            Task { await toggleVideo() }
        case .showSpeakerPicker:
            state.bindings.showSpeakerPickerHandler?()
        case .toggleHandRaise:
            Task { await toggleHandRaise() }
        case .handRaiseStateChanged(let raised):
            state.isHandRaised = raised
        case .restoreFromMinimized:
            isMinimized = false
            state.isMinimized = false
            actionsSubject.send(.pictureInPictureStopped)
        case .liveKitCredentialsIntercepted(let url, let token):
            MXLog.info("sTalk: LiveKit credentials intercepted — url=\(url.prefix(80))..., token length=\(token.count)")
            Task { await connectNativeLiveKit(wsURL: url, token: token) }
        }
    }
    
    func stop() {
        callTimerTask = nil
        // Safety net: endCall() выполняет полную очистку до dismiss.
        // stop() вызывается координатором при удалении — подстраховка на случай
        // если endCall() не был вызван (PiP dismiss, crash).
        Task {
            if liveKitRoomManager.connectionState != .disconnected {
                MXLog.info("sTalk: stop() safety — disconnecting LiveKit")
                await liveKitRoomManager.disconnect()
            }
            await MainActor.run {
                elementCallService.tearDownCallSession()
                UIDevice.current.isProximityMonitoringEnabled = false
            }
        }
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
        switch configuration.kind {
        case .genericCallLink(let url):
            state.url = url
            // We need widget messaging to work before enabling CallKit, otherwise mute, hangup etc do nothing.
            
        case .roomCall(let roomProxy, _, let clientID, let elementCallBaseURL, let elementCallBaseURLOverride, let colorScheme):
            Task { [weak self] in
                guard let self else { return }
                
                let baseURL = if let elementCallBaseURLOverride {
                    elementCallBaseURLOverride
                } else {
                    elementCallBaseURL
                }
                
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
    
    // This should always match the web app value
    private static let earpieceID = "earpiece-id"
    
    private func handleOutputDeviceSelected(deviceID: String) {
        let isEarpiece = deviceID == Self.earpieceID
        MXLog.info("Is earpiece: \(isEarpiece)")
        UIDevice.current.isProximityMonitoringEnabled = isEarpiece
    }
    
    private func handleBackwardsNavigation() async {
        // Try PiP first if available
        if state.url != nil,
           isPictureInPictureAllowed,
           let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler {
            let result = await requestPictureInPictureHandler()
            if case .success = result {
                isMinimized = true
                state.isMinimized = true
                actionsSubject.send(.pictureInPictureStarted)
                return
            }
        }
        // Fallback: minimize overlay (call continues in mini-window)
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
    
    /// This function updates the list of available audio outputs on the web side
    /// however since we actually handle switching the audio output through the OS,
    /// this is only used to inform the webview when the speaker is selected,
    /// so that the option to use the earpiece can be displayed.
    private func updateOutputsListOnWeb() async {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }
        
        let deviceList = if currentOutput.portType == .builtInSpeaker {
            // This allows the webview to display the earpiece option
            "{id: '\(currentOutput.uid)', name: '\(currentOutput.portName)', forEarpiece: true, isSpeaker: true}"
        } else {
            // Doesn't matter because the switch is handled through the OS
            "{id: 'dummy', name: 'dummy'}"
        }
        
        let javaScript = "window.controls.setAvailableOutputDevices([\(deviceList)])"
        do {
            let result = try await state.bindings.javaScriptEvaluator?(javaScript)
            MXLog.debug("Evaluated  with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }

    // MARK: - Native LiveKit

    private func connectNativeLiveKit(wsURL: String, token: String) async {
        // Only connect once
        guard liveKitRoomManager.connectionState == .disconnected else {
            MXLog.info("sTalk LiveKit: Already connected or connecting, skipping")
            return
        }

        // sTalk: Отменить 10-секундный таймаут — LiveKit credentials получены,
        // значит EC загрузился достаточно для Widget API. С фейковым WebSocket
        // EC не отправит content_loaded, но нативный SDK берёт контроль.
        timeoutTask = nil

        // Step 1: Connect to SFU (critical — if this fails, we can't proceed)
        do {
            try await liveKitRoomManager.connect(wsURL: wsURL, token: token)
            MXLog.info("sTalk LiveKit: Native connection established")
        } catch {
            MXLog.error("sTalk LiveKit: Failed to connect to SFU: \(error)")
            return
        }

        // Connection succeeded — expose room manager to UI
        state.liveKitRoomManager = liveKitRoomManager
        state.wasConnected = true

        // Small delay to let audio session stabilize
        try? await Task.sleep(for: .milliseconds(200))

        // Step 2: Enable microphone (non-fatal — may fail on simulator)
        do {
            try await liveKitRoomManager.setMicrophone(enabled: true)
            MXLog.info("sTalk LiveKit: Microphone enabled")
        } catch {
            MXLog.error("sTalk LiveKit: Microphone enable failed (non-fatal): \(error)")
        }

        // Step 3: Enable camera if video call (non-fatal — no camera on simulator)
        if startWithVideoEnabled {
            do {
                try await liveKitRoomManager.setCamera(enabled: true)
                MXLog.info("sTalk LiveKit: Camera enabled")
            } catch {
                MXLog.error("sTalk LiveKit: Camera enable failed (non-fatal, e.g. simulator): \(error)")
                state.isVideoEnabled = false
            }
        }

        // Observe native LiveKit connection state for call lifecycle
        observeLiveKitState()
    }

    private func observeLiveKitState() {
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
                case .reconnecting:
                    self.state.callStatus = .reconnecting
                    MXLog.info("sTalk LiveKit: Reconnecting...")
                case .disconnected:
                    if self.state.wasConnected {
                        MXLog.info("sTalk LiveKit: Disconnected after being connected — remote may have ended call")
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Native Call Controls

    private func toggleMute() async {
        let newMuted = !state.isMuted
        state.isMuted = newMuted

        // sTalk: Use native LiveKit SDK for mute control
        if state.liveKitRoomManager != nil {
            do {
                try await liveKitRoomManager.setMicrophone(enabled: !newMuted)
            } catch {
                MXLog.error("sTalk LiveKit: Failed to toggle microphone: \(error)")
            }
        }

        // Also notify Widget API for MatrixRTC state sync
        await setAudioEnabled(!newMuted)
    }

    private func toggleVideo() async {
        let newVideoEnabled = !state.isVideoEnabled
        state.isVideoEnabled = newVideoEnabled

        // sTalk: Use native LiveKit SDK for camera control
        if state.liveKitRoomManager != nil {
            do {
                try await liveKitRoomManager.setCamera(enabled: newVideoEnabled)
            } catch {
                MXLog.error("sTalk LiveKit: Failed to toggle camera: \(error)")
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
        MXLog.info("sTalk: endCall — начинаю завершение звонка")

        // 1. Остановить запись (до закрытия звонка, иначе ABORTED)
        if let recordingService, recordingService.state.isRecording {
            let duration = recordingService.state.recordingDuration ?? 0
            do {
                try await recordingService.stopRecording()
                MXLog.info("sTalk: Recording stopped before call end")
                await sendRecordingInfoMessage(duration: duration)
            } catch {
                MXLog.error("sTalk: Recording cleanup: \(error)")
            }
        }

        // 2. Отправить .hangup → Widget API (EC покидает звонок)
        let hangupMsg = ElementCallWidgetMessage(direction: .fromWidget,
                                                  action: .hangup,
                                                  widgetId: widgetDriver.widgetID)
        if let data = try? JSONEncoder().encode(hangupMsg),
           let json = String(data: data, encoding: .utf8) {
            await widgetDriver.handleMessage(json)
            MXLog.info("sTalk: Sent .hangup to Widget API")
        }

        // 3. Отправить .close → Widget API (Rust SDK удаляет MatrixRTC state event)
        let closeMsg = ElementCallWidgetMessage(direction: .fromWidget,
                                                 action: .close,
                                                 widgetId: widgetDriver.widgetID)
        if let data = try? JSONEncoder().encode(closeMsg),
           let json = String(data: data, encoding: .utf8) {
            await widgetDriver.handleMessage(json)
            MXLog.info("sTalk: Sent .close to Widget API")
        }

        // 4. Дать Rust SDK время обработать удаление state event
        try? await Task.sleep(for: .seconds(2))

        // 5. Отключить нативный LiveKit SDK (после очистки state)
        await liveKitRoomManager.disconnect()
        MXLog.info("sTalk LiveKit: Disconnected on endCall")

        // 6. Закрыть CallKit сессию
        elementCallService.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false

        // 7. Dismiss экран звонка
        actionsSubject.send(.dismiss)
    }

    /// sTalk: Click Element Call's hangup button in the WebView DOM.
    /// Returns true if button was found and clicked.
    private func clickElementCallHangup() async -> Bool {
        let js = """
        (function() {
            var btn = document.querySelector('[data-testid="incall_leave"]')
                   || document.querySelector('button[class*="_endCall"]');
            if (btn) { btn.click(); return true; }
            return false;
        })()
        """
        let result = try? await state.bindings.javaScriptEvaluator?(js)
        let clicked = (result as? Bool) == true
        MXLog.info("sTalk: clickElementCallHangup — clicked: \(clicked)")
        return clicked
    }

    private func toggleHandRaise() async {
        do {
            _ = try await state.bindings.javaScriptEvaluator?("window.stalkToggleHandRaise()")
        } catch {
            MXLog.error("Failed to toggle hand raise: \(error)")
        }
    }

    // MARK: - Recording

    private func setupRecordingObserver() {
        guard let recordingService else {
            state.isRecordingEnabled = false
            return
        }

        recordingService.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordingState in
                self?.state.recordingState = recordingState
            }
            .store(in: &cancellables)
    }

    private func handleToggleRecording() {
        guard let recordingService else { return }

        if recordingService.state.isRecording {
            Task { await stopRecording() }
        } else {
            // Show consent dialog before starting
            actionsSubject.send(.showRecordingConsent)
        }
    }

    private func startRecording() async {
        guard let recordingService else { return }

        // Get room info and participant metadata from configuration
        let roomName: String
        var matrixRoomId: String?
        var participants: [(userId: String, displayName: String)]?
        var initiatedBy: String?

        switch configuration.kind {
        case .genericCallLink(let url):
            roomName = url.lastPathComponent

        case .roomCall(let roomProxy, let clientProxy, _, _, _, _):
            roomName = roomProxy.id
            matrixRoomId = roomProxy.id
            initiatedBy = clientProxy.userID

            // Get participant info from room members
            if let members = await roomProxy.members() {
                participants = members
                    .filter { $0.isActive }
                    .map { ($0.userID, $0.displayName ?? $0.userID) }
            }
        }

        do {
            let egressId = try await recordingService.startRecording(
                roomName: roomName,
                matrixRoomId: matrixRoomId,
                participants: participants,
                initiatedBy: initiatedBy
            )
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

            // sTalk: Send recording info message to the room chat
            await sendRecordingInfoMessage(duration: recordingDuration)
        } catch {
            MXLog.error("Failed to stop recording: \(error)")
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: L10n.commonError,
                                             message: error.localizedDescription,
                                             primaryButton: .init(title: L10n.actionOk, action: nil))
        }
    }

    private func sendRecordingInfoMessage(duration: TimeInterval) async {
        guard case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind else { return }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let durationText = String(format: "%d:%02d", minutes, seconds)
        let message = "Запись звонка завершена (длительность: \(durationText))"

        let result = await roomProxy.timeline.sendMessage(message,
                                                          html: nil,
                                                          inReplyToEventID: nil,
                                                          intentionalMentions: .empty)
        switch result {
        case .success:
            MXLog.info("Recording info message sent to room")
        case .failure(let error):
            MXLog.error("Failed to send recording info message: \(error)")
        }
    }

    // MARK: - Participants

    private func loadParticipants() {
        guard case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind else { return }

        Task { [weak self] in
            guard let members = await roomProxy.members() else { return }
            guard let self else { return }

            let participants = members
                .filter { $0.isActive }
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
    }
}
