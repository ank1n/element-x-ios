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
    /// sTalk: были ли мы инициатором звонка (в комнате не было активного звонка на
    /// старте). Захватываем при init ДО того как подписки на участников выставят
    /// callParticipantsCount в 1 (=себя). Гудки играют ТОЛЬКО у инициатора.
    private let startedAsInitiator: Bool
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

    /// Гудки исходящего вызова: играют, пока МЫ инициатор (в комнате никого не
    /// было на старте) и ни один участник ещё не подключился.
    private let ringbackPlayer = RingbackTonePlayer()
    private var shouldPlayRingback = false
        
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
        var roomAvatar: RoomAvatar?
        var isDirect = false
        var totalMembersCount = 0
        var callParticipantsCount = 0
        if case .roomCall(let roomProxy, _, _, _, _, _) = configuration.kind {
            let roomInfo = roomProxy.infoPublisher.value
            roomDisplayName = roomInfo.displayName
            roomAvatar = roomInfo.avatar
            isDirect = roomInfo.isDirect
            totalMembersCount = roomInfo.activeMembersCount
            callParticipantsCount = roomInfo.activeRoomCallParticipants.count
        }

        // sTalk: инициатор = в комнате на старте не было активного звонка. Захват
        // ДО super.init/подписок (иначе callParticipantsCount станет 1 = себя).
        startedAsInitiator = (callParticipantsCount == 0)

        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript,
                                                         isGenericCallLink: isGenericCallLink,
                                                         certificateValidator: appHooks.certificateValidatorHook,
                                                         roomDisplayName: roomDisplayName,
                                                         roomAvatar: roomAvatar,
                                                         isDirect: isDirect,
                                                         totalMembersCount: totalMembersCount,
                                                         callParticipantsCount: callParticipantsCount,
                                                         mediaProvider: mediaProvider,
                                                         isVideoEnabled: startWithVideoEnabled))

        // Блюр-тумблер в меню ••• доступен и ДО connect — засеваем из настроек,
        // чтобы не показывать «выкл» при включённой настройке (менеджер прочитает
        // тот же ключ в makeRoomOptions при connect).
        state.callBackgroundMode = UserDefaults.standard.string(forKey: "stalk_call_background_mode")
            .flatMap(CallBackgroundMode.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "stalk_background_blur_enabled") ? .blurMedium : .off)

        MXLog.info("sTalk CallScreenVM init: startWithVideoEnabled=\(startWithVideoEnabled), isDirect=\(isDirect), participants=\(callParticipantsCount), room=\(roomDisplayName ?? "nil")")

        // STMOB-261: аудио-движок поднимаем по СОСТОЯНИЮ активной сессии, а не по
        // разовому событию: система активирует её сразу после ответа, до создания этой
        // модели, и событие терялось — входящий оставался без звука. Повтор последнего
        // значения решает гонку, сверка комнаты — чужие звонки.
        elementCallService.callKitAudioRoomIDPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeRoomID in
                guard let self else { return }
                if activeRoomID == configuration.callRoomID {
                    liveKitRoomManager.handleCallKitAudioActivated(systemOwnsSession: true)
                    // Гудки исходящего играет ПРИЛОЖЕНИЕ — CallKit звучит только на
                    // входящих. До активации сессии движок гудков стартовать нельзя.
                    if shouldPlayRingback {
                        ringbackPlayer.start()
                    }
                } else if activeRoomID == nil {
                    liveKitRoomManager.handleCallKitAudioDeactivated()
                }
            }
            .store(in: &cancellables)

        // Система отказала в CallKit-звонке — забираем владение сессией себе, иначе
        // звонок останется немым: движок ждёт активации, которой не будет.
        elementCallService.callKitUnavailableRoomIDPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomID in
                guard let self, roomID == configuration.callRoomID else { return }
                liveKitRoomManager.handleCallKitAudioActivated(systemOwnsSession: false)
            }
            .store(in: &cancellables)

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
                        // STMOB-261: в нативном режиме WebView нет, и сообщение виджету
                        // уходило в никуда — системная кнопка «Без звука» показывала
                        // выключённый микрофон, а звук продолжал идти.
                        try? await self.liveKitRoomManager.setMicrophone(enabled: enabled)
                        self.state.isMuted = !enabled
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
                    // NOTE: do NOT feed route changes back into LiveKit's isSpeakerOutputPreferred.
                    // Doing so (build 221) made every transient route notification trigger a mid-call
                    // audio-session reconfigure inside LiveKit — the session ended up dead ("Нет
                    // аудио" in the route picker, no sound at all). The preference is set once at
                    // connect; the picker performs pure system routing on top.
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
                    // sTalk-фикс (скрин dp 00:29 «Участники (1)» + сам в «не в сети»):
                    // activeRoomCallParticipants (m.call.member) может НЕ содержать себя
                    // (лаг sync / SDK не кладёт self) → локальный юзер падал в секцию
                    // «не в сети» в CallParticipantsSheet, хотя он в звонке. Счётчик шапки
                    // уже делает +1 за себя — приводим список активных в соответствие:
                    // сам ВСЕГДА активен в звонке, который смотрит.
                    var activeIDs = callParticipants
                    if !activeIDs.contains(roomProxy.ownUserID) {
                        activeIDs.append(roomProxy.ownUserID)
                    }
                    self.state.activeCallParticipantIDs = activeIDs
                    if callParticipants.count != prevCount {
                        MXLog.info("sTalk: MatrixRTC participants changed: \(prevCount) → \(callParticipants.count), users=\(callParticipants), liveKit remote=\(self.liveKitRoomManager.displayParticipants.count)")
                    }

                    // sTalk-фикс (STALK-610/лог получателя): для ИНИЦИАТОРА НЕ переходить
                    // в .connected по MatrixRTC call.member — веб-получатель постит
                    // call.member в лобби ДО нажатия «Принять», и count>=2 срабатывал
                    // преждевременно («принято» пока абонент ещё звонит). Для инициатора
                    // «принято» ставит ТОЛЬКО реальный вход remote в SFU (подписка
                    // remoteParticipants ниже). Отвечающий/join (!startedAsInitiator) —
                    // remote уже есть, эти пути корректны.
                    if !self.startedAsInitiator,
                       self.state.isDirect,
                       self.state.callStatus != .connected,
                       callParticipants.count >= 2 {
                        self.state.callStatus = .connected
                        self.startCallTimer()
                        MXLog.info("sTalk: 1:1 call connected — both participants present")
                    }

                    // sTalk: For group — start timer when we see ourselves in call
                    if !self.startedAsInitiator,
                       !self.state.isDirect,
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
                        // STMOB-262: пустой LiveKit во время переподключения ничего не
                        // значит — полный реконнект на секунду обнуляет участников.
                        let reconnecting = self.liveKitRoomManager.isRecovering
                            || self.liveKitRoomManager.sdkReconnectMode != nil
                            || self.liveKitRoomManager.connectionState == .reconnecting
                        if matrixRTCEmpty, liveKitEmpty, !reconnecting {
                            MXLog.info("sTalk: Remote party left 1:1 call (both MatrixRTC and LiveKit empty) — auto-ending")
                            Task { await self.endCall() }
                        } else if matrixRTCEmpty, liveKitEmpty {
                            DiagLog.write("CallUI", "1:1 авто-энд отложен — идёт переподключение")
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
                // Собеседник подключился — гудки исходящего вызова умолкают
                if realUsersCount > 0 {
                    self.stopRingback()
                    // STMOB-261: первый реальный участник в SFU = собеседник ответил.
                    // Это же момент, когда система должна начать считать длительность.
                    self.elementCallService.reportOutgoingCallConnected()
                    // sTalk-фикс (лог 132): для ИНИЦИАТОРА переход в .connected происходит
                    // ЗДЕСЬ — когда собеседник реально ответил (вошёл в медиа-сессию), а не
                    // при нашем LiveKit-connect. До этого экран показывает «Вызов…» + гудки.
                    if self.state.callStatus != .connected {
                        self.state.callStatus = .connected
                        self.startCallTimer()
                        MXLog.info("sTalk: callStatus=connected — remote answered (\(realUsersCount) real)")
                    }
                }
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
        case .toggleCallBackground:
            // В звонке только вкл/выкл: режим (интенсивность/обои) настраивается в Настройках
            let newMode: CallBackgroundMode
            if state.callBackgroundMode != .off {
                newMode = .off
            } else {
                let defaults = UserDefaults.standard
                let configured = defaults.string(forKey: "stalk_call_background_mode").flatMap(CallBackgroundMode.init(rawValue:))
                let last = defaults.string(forKey: "stalk_call_background_last").flatMap(CallBackgroundMode.init(rawValue:))
                newMode = [configured, last].compactMap { $0 }.first { $0 != .off } ?? .blurMedium
            }
            liveKitRoomManager.setCallBackground(newMode)
            state.callBackgroundMode = newMode
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
        stopRingback()
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
            await performStopCleanup()
        }

        // Teardown immediately (как upstream — вне Task)
        elementCallService.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    /// Подмена звонка вторым: тот же останов, но с ОЖИДАНИЕМ полного disconnect
    /// (bounded 8s) — иначе старый LiveKit-менеджер живёт параллельно с новым:
    /// зомби-аудио, драка за аудио-сессию, SFU кикает дубль identity (лог dp 128).
    func stopAndWaitCleanup() async {
        stopSyncParts()
        elementCallService.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.performStopCleanup() }
            group.addTask { try? await Task.sleep(for: .seconds(8)) }
            await group.next()
            group.cancelAll()
        }
        DiagLog.write("Call", "stopAndWaitCleanup DONE (LiveKit=\(liveKitRoomManager.connectionState))")
    }

    /// Синхронные части stop() (таймеры/стейт) — общие для stop и stopAndWaitCleanup.
    private func stopSyncParts() {
        stopRingback()
        callTimerTask = nil
        recordingPollingTask?.cancel()
        recordingPollingTask = nil
        state.layoutOverride = nil
        state.pinnedParticipantSID = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func performStopCleanup() async {
        // Очистить MatrixRTC state event через REST API
        if case .roomCall(let roomProxy, let clientProxy, _, _, _, _) = configuration.kind {
            await sendLeaveCallStateEventViaREST(roomProxy: roomProxy, clientProxy: clientProxy)
        }
        await sendDirectlyToWidgetDriver(.hangup)
        await sendDirectlyToWidgetDriver(.close)

        // NativeCallSession.stop() сам отключает LiveKit-менеджер + гасит
        // таймеры (rebroadcast) и наблюдателей; без сессии — прямой disconnect
        let sessionToStop = nativeCallSession
        nativeCallSession = nil
        if let sessionToStop {
            await sessionToStop.stop()
        } else if liveKitRoomManager.connectionState != .disconnected {
            await liveKitRoomManager.disconnect()
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
                                                    roomProxy: roomProxy,
                                                    enableCameraOnConnect: startWithVideoEnabled)
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
                                // Блюр-интент из настроек прочитан менеджером при connect — синк в UI
                                self.state.callBackgroundMode = self.liveKitRoomManager.callBackgroundMode
                                self.startRingbackIfInitiator()
                                // sTalk-фикс (лог 132): раньше callStatus=.connected ставился
                                // при НАШЕМ LiveKit-connect — до того как собеседник поднял
                                // трубку. Исходящий показывал «принято»+таймер, пока на той
                                // стороне ещё звонит. Теперь: ИНИЦИАТОР остаётся в «Вызов…»
                                // (+гудки) до входа первого remote-участника (см. подписку
                                // remoteParticipants → там переход в .connected). Отвечающий/
                                // входящий в идущий звонок — remote уже есть → connected сразу.
                                if !self.startedAsInitiator, self.state.callStatus != .connected {
                                    self.state.callStatus = .connected
                                    self.startCallTimer()
                                    MXLog.info("sTalk: callStatus=connected (joiner) via NativeCallSession")
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
                    elementCallService.markNativeCallActive(roomID: roomProxy.id, displayName: roomProxy.infoPublisher.value.displayName)
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
            // Default = SPEAKER for every call (the shipped 26.04.06 behaviour users know).
            // The earpiece-by-default experiment for 1:1 read as "no sound at all" on device —
            // switching to the earpiece is done explicitly via the route picker.
            let useSpeaker = true
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
        // Блюр-интент из настроек прочитан менеджером при connect — синк в UI
        state.callBackgroundMode = liveKitRoomManager.callBackgroundMode
        startRingbackIfInitiator()

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

    /// Гудки: только если на старте звонка в комнате никого не было (мы звоним
    /// первыми). Ответ на входящий / вход в идущий звонок — без гудков.
    private func startRingbackIfInitiator() {
        // sTalk-фикс: раньше проверяли `state.callParticipantsCount == 0`, но этот
        // счётчик считается как max(membership, displayParticipants+1) — включает
        // себя (+1) и выставляется в 1 подпиской почти сразу при connect, поэтому
        // гудки НИКОГДА не играли (лог 130: ни одного ringback START). Теперь гейт —
        // захваченный при init `startedAsInitiator` (в комнате не было звонка на старте)
        // + нет удалённых участников. Уже играющие — не перезапускаем.
        guard startedAsInitiator, !shouldPlayRingback, liveKitRoomManager.displayParticipants.isEmpty else { return }
        shouldPlayRingback = true
        ringbackPlayer.start()
        // потолок 60с — дальше тишина (UI продолжает «Вызов…»)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.stopRingback()
        }
    }

    private func stopRingback() {
        guard shouldPlayRingback else { return }
        shouldPlayRingback = false
        ringbackPlayer.stop()
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

        // STMOB-234: до этого на $isScreenSharing никто не был подписан — UI знал о
        // демонстрации только из собственного тапа. Если шаринг гасили снаружи
        // (системная запись экрана отбирает ReplayKit, ошибка SDK), кнопка так и
        // оставалась «активной», а повторный тап пытался ВЫКЛЮЧИТЬ уже мёртвый шаринг.
        // STMOB-262: ремонт доставки — в UI. Показываем сразу, снимаем сразу:
        // «связь чинится» лучше увидеть с запасом, чем пропустить.
        liveKitRoomManager.$isRecovering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recovering in
                guard let self, self.state.isRecoveringConnection != recovering else { return }
                self.state.isRecoveringConnection = recovering
                DiagLog.write("CallUI", "connection recovering → \(recovering)")
            }
            .store(in: &cancellables)

        liveKitRoomManager.$isScreenSharing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sharing in
                guard let self, self.state.isScreenSharing != sharing else { return }
                self.state.isScreenSharing = sharing
                MXLog.info("sTalk: LiveKit isScreenSharing changed — \(sharing)")
            }
            .store(in: &cancellables)

        // Демонстрацию оборвали снаружи — объясняем пользователю, почему она погасла.
        liveKitRoomManager.screenShareInterruptedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: NSLocalizedString("stalk_call_share_interrupted_title",
                                                                          tableName: "Localizable",
                                                                          value: "Демонстрация остановлена",
                                                                          comment: "Screen share was interrupted by the system"),
                                                 message: NSLocalizedString("stalk_call_share_interrupted_message",
                                                                            tableName: "Localizable",
                                                                            value: "iPhone передал захват экрана другой функции — например, системной записи экрана. Демонстрацию можно включить снова.",
                                                                            comment: "Screen share interrupted explanation"),
                                                 primaryButton: .init(title: L10n.actionOk) { })
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
                    // STMOB-80: Fallback initial connected — но ТОЛЬКО для НЕ-инициатора.
                    // ⚠️ Этот fallback срабатывал на НАШЕМ подключении к SFU (~4с), т.е.
                    // раньше всех прочих путей → у ИНИЦИАТОРА экран показывал «в звонке»,
                    // пока абонент ещё не поднял трубку (баг «принято до ответа», лог 134).
                    // Для инициатора «принято» ставит только реальный вход remote в SFU
                    // (подписка remoteParticipants). Для отвечающего/join — remote уже
                    // есть, fallback корректен (MatrixRTC мог опоздать → не застреваем в «Вызов…»).
                    if !self.startedAsInitiator, self.state.callStatus == .connecting {
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

        // sTalk (лог 130): экран висел ~5с пока идёт очистка (leave REST 3.7с и т.д.),
        // юзер тыкал «Завершить» 8 раз от нетерпения. Закрываем UI СРАЗУ, а очистка
        // (leave/hangup/disconnect) доигрывает в фоне: `Task { await endCall() }`
        // держит self сильно, поэтому VM жива до конца очистки даже после того как
        // координатор убрал оверлей. Это не отменяет очистку — она гарантирована.
        UIDevice.current.isProximityMonitoringEnabled = false
        DiagLog.write("CallUI", "endCall: dismiss NOW (cleanup continues in background)")
        actionsSubject.send(.dismiss)

        // STMOB-115 build 139: каждый шаг с timeout. Если любой await зависает
        // (network/SDK deadlock), переходим дальше. Финальный teardown через defer.
        defer {
            DiagLog.write("CallUI", "endCall: cleanup done — teardown")
            elementCallService.tearDownCallSession()
            // STMOB-130: очистить native call marker (для native path tearDown
            // не выставляет ongoingCallID=nil, нужно отдельно).
            elementCallService.markNativeCallActive(roomID: nil)
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
                            // Предупреждение при УДАЛЁННОМ старте записи: помимо красной
                            // пилюли — модальное окно с текстом + ОК (dp 2026-07-16).
                            // Срабатывает один раз на переход idle→recording (гард !=).
                            self.state.bindings.alertInfo = .init(id: UUID(),
                                                                  title: SL10n.remoteRecordingTitle,
                                                                  message: SL10n.remoteRecordingMessage,
                                                                  primaryButton: .init(title: L10n.actionOk, action: nil))
                        } else {
                            MXLog.info("sTalk: Remote recording stopped for room \(matrixRoomId)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Ringback (гудки исходящего вызова)

/// Синтезатор стандартных гудков (425 Гц, 1с сигнал / 4с пауза) через AVAudioEngine.
/// Ассета нет и не нужно: тон генерируется source-нодой, играет через уже
/// сконфигурированную звонковую AVAudioSession (ухо/динамик по текущему роуту).
@MainActor
final class RingbackTonePlayer {
    /// Фиксированный внутренний рейт генерации. Лог 137: рестарт движка в момент
    /// транзиента реконфига (публикация камеры в видео-звонке) читал промежуточный
    /// HW-рейт → тон другой высоты/тембра («гудок совсем не похож на системный»).
    /// Генерим всегда под 48к с явным форматом — миксер сам ресемплит в HW.
    private static let toneSampleRate: Double = 48000
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    /// Позиция в периоде (1с тон / 4с пауза) — переживает пересборку движка,
    /// чтобы рестарт продолжал ритм, а не начинал гудок заново с нуля.
    private var periodOffset: Double = 0
    private var engineStartDate: Date?

    func start() {
        guard engine == nil else { return }
        periodOffset = 0
        startEngine()
        guard engine != nil else { return }
        DiagLog.write("Call", "ringback START")
        // Лог 136: публикация камеры (или смена роута) реконфигурирует AVAudioSession —
        // AVAudioEngine молча останавливается и гудки глохнут при живом экране набора.
        // Система шлёт AVAudioEngineConfigurationChange — пересобираем движок и продолжаем.
        // Дебаунс 250мс: реконфиг приходит пачкой (камера+роут+режим) — одна пересборка,
        // а не серия рестартов с гудком на каждом (лог 137: «рваные не-системные гудки»).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: nil,
                                                                queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let current = self.engine,
                      (notification.object as? AVAudioEngine) === current else { return }
                self.restartTask?.cancel()
                self.restartTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled, let running = self.engine else { return }
                    self.rememberPeriodPosition()
                    running.stop()
                    self.engine = nil
                    self.startEngine()
                    DiagLog.write("Call", "ringback RESTART after audio config change (engine=\(self.engine != nil ? "ok" : "failed"))")
                }
            }
        }
    }

    /// Сохраняет текущую позицию ритма по wall-clock, чтобы новый движок продолжил период.
    private func rememberPeriodPosition() {
        guard let engineStartDate else { return }
        let period = Self.toneSampleRate * 5.0
        let elapsed = Date().timeIntervalSince(engineStartDate) * Self.toneSampleRate
        periodOffset = (periodOffset + elapsed).truncatingRemainder(dividingBy: period)
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        let sampleRate = Self.toneSampleRate
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        var sampleIndex = periodOffset
        let sourceNode = AVAudioSourceNode(format: toneFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let period = sampleRate * 5.0 // 1с тон + 4с тишина
            let toneLength = sampleRate * 1.0
            for frame in 0..<Int(frameCount) {
                let posInPeriod = sampleIndex.truncatingRemainder(dividingBy: period)
                var value: Float = 0
                if posInPeriod < toneLength {
                    // плавные фронты 20мс, чтобы не щёлкало
                    let ramp = min(posInPeriod / (sampleRate * 0.02),
                                   (toneLength - posInPeriod) / (sampleRate * 0.02),
                                   1.0)
                    let phase = 2.0 * Double.pi * 425.0 * (posInPeriod / sampleRate)
                    value = Float(sin(phase)) * Float(max(0, ramp)) * 0.25
                }
                sampleIndex += 1
                for buffer in ablPointer {
                    let buf = UnsafeMutableBufferPointer<Float>(buffer)
                    buf[frame] = value
                }
            }
            _ = self
            return noErr
        }
        engine.attach(sourceNode)
        // Явный формат 48к на коннекте: миксер ресемплит в текущий HW-рейт,
        // высота тона не зависит от состояния сессии в момент старта движка.
        engine.connect(sourceNode, to: engine.mainMixerNode, format: toneFormat)
        do {
            try engine.start()
            self.engine = engine
            engineStartDate = Date()
        } catch {
            MXLog.error("sTalk: ringback engine start failed: \(error)")
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        DiagLog.write("Call", "ringback STOP")
    }
}
