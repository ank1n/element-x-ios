//
// NativeCallSession.swift
// sTalk — Native call session: WidgetDriver signaling + LiveKit native SDK
//
// Replaces WebView for calls. Uses WidgetDriver for MatrixRTC signaling,
// native LiveKit SDK for media (camera, microphone, video, audio, E2EE).
//

import Combine
import CryptoKit
import Foundation
import LiveKit
import MatrixRustSDK
import Network
import os.log
import SwiftUI

private let callLog = OSLog(subsystem: "ru.implica.stalk", category: "Call")

@MainActor
final class NativeCallSession: ObservableObject {
    // MARK: - Published State

    @Published private(set) var sessionState: NativeCallSessionState = .starting
    @Published private(set) var roomManager: LiveKitRoomManager?

    // MARK: - Dependencies

    private let widgetDriver: ElementCallWidgetDriverProtocol
    private let liveKitRoomManager: LiveKitRoomManager
    /// Match EC JS parameters: ratchetWindowSize: 10, keyringSize: 256, HKDF derivation
    private let keyProvider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: false,
                                                                          ratchetWindowSize: 10,
                                                                          keyRingSize: 256,
                                                                          useHKDF: true // CRITICAL: JS uses HKDF, native default is PBKDF2
        ))
    private let isEncrypted: Bool
    private let userId: String
    /// STMOB-232: own display name для LiveKit JWT `name` claim. Раньше в JWT
    /// клали `name = userId` → другие участники видели нас сырым Matrix ID
    /// (@dp.bondar:...) вместо имени. Теперь шлём display name (fallback userId).
    private let ownDisplayName: String?
    private let deviceId: String
    private let matrixRoomId: String
    private let homeserverURL: String
    /// STMOB-284: токен берём СВЕЖИЙ перед каждым запросом, а не снимком при
    /// создании сессии.
    ///
    /// MAS вращает access token примерно раз в четверть часа. Пока здесь лежал
    /// снимок, ровно на пятнадцатой минуте разговора ВСЕ матричные запросы сессии
    /// начинали отвечать 401 — и навсегда: обновить токен было нечем. Продление
    /// отложенного выхода переставало проходить, сервер снимал участие, а попытка
    /// сверщика переопубликовать его падала тем же 401. Медиа при этом идёт своим
    /// путём (у LiveKit собственный JWT) — отсюда «человека слышно, а в списке
    /// участников нет». В логе 25.08: вход 15:04:14, первый 401 в 15:19:15.
    ///
    /// Presence лечили этим же способом в STMOB-109/132, здесь тот же дефект.
    private let accessTokenProvider: () -> String
    /// Принудительное обновление токена в SDK — зовём при 401 и повторяем запрос.
    private let tokenRefresher: () async -> Void
    private var accessToken: String {
        accessTokenProvider()
    }

    private let roomProxy: JoinedRoomProxyProtocol?

    /// Единая URLSession для всех MatrixRTC REST-запросов. Request/resource timeout = 15с
    /// (дефолт URLSession.shared = 60с) — мёртвый/медленный homeserver (в частности .uz
    /// cold-start) падает быстро, а не вешает путь подключения к звонку.
    /// waitsForConnectivity=false обязателен: иначе timeoutIntervalForRequest НЕ тикает пока
    /// система «ждёт связи» — на reachable-но-немом .uz-хосте это и даёт многоминутный висяк.
    private let restSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - LiveKit Config

    // LiveKit credentials are NOT hardcoded anymore: they are fetched per-call from the
    // homeserver's own lk-jwt-service (POST {jwt.<domain>}/sfu/get) — the api key/secret is
    // per-install, so embedding stalk.implica.ru's key only worked on .ru-shared infra and
    // broke calls on independent installs (stalk.pics etc.). See fetchLiveKitCredentials().

    // MARK: - E2EE Key Management

    private var participantKeys: [String: Bool] = [:]
    private var pendingParticipants: [String: RemoteParticipant] = [:]
    private var credentialsReceived = false
    private var hasSeenRemoteParticipant = false

    // MARK: - Delayed Leave (STMOB-211)

    /// MSC4140 delay_id запланированного на сервере отложенного leave.
    private var delayedLeaveID: String?
    /// Heartbeat-таск, продлевающий отложенный leave пока мы в звонке.
    private var delayedLeaveHeartbeat: Task<Void, Never>?

    // MARK: - Hand Raise (STMOB-154)

    /// event_id своего org.matrix.msc3401.call.member state event. Используется как
    /// `m.relates_to.event_id` в m.reaction events для hand raise (Element Call widget
    /// в Web фильтрует reactions по этому ID для определения чьё это hand raise).
    private(set) var callMemberEventID: String?
    /// event_id текущего активного m.reaction hand raise. Сохраняется чтобы при опускании
    /// руки можно было его redact'нуть. nil если рука сейчас опущена.
    private var handReactionEventID: String?
    /// STMOB-96: tracks remote participant identities seen so far. When a new
    /// identity appears (reconnect → новый pID, или newcomer), мы триггерим
    /// rebroadcast текущего encryption key — иначе он не сможет расшифровать
    /// audio после того как ratchet ушёл вперёд изначально розданного ключа.
    private var knownRemoteIdentities: Set<String> = []
    /// STMOB-246/247: active MatrixRTC call membership device-set — canonical source for
    /// E2EE key RECIPIENTS (addressed to-device) and the re-advertise trigger (membership-settled),
    /// per STALK-505 (source = call.member memberships, NOT LiveKit presence). Egress is not a
    /// call-member → naturally excluded. Key = "userId|deviceId", value = expiry epoch-ms
    /// (0 = unknown expiry → treated active). Built from incoming call.member events; exact field
    /// names validated on the STALK-506 stand. Excludes our own (userId|deviceId).
    private var callMemberDeviceExpiry: [String: Double] = [:]
    /// STMOB-269: момент появления каждой удалённой идентичности в звонке —
    /// точка отсчёта для сторожа «ключ не пришёл».
    private var remoteFirstSeenAt: [String: Date] = [:]
    /// О ком уже отчитались и на какой стадии (1 — предупреждение, 2 — разбор).
    private var keyGapReported: [String: Int] = [:]
    private var keyGapWatchdog: Task<Void, Never>?
    /// STMOB-96 v2 / STMOB-101 v3: foreground observer to rebroadcast same key
    /// when app возвращается в foreground (на случай если новые participant'ы
    /// подключились пока iOS suspended app).
    private var foregroundObserver: NSObjectProtocol?
    private var livekitBaseURL: String?
    /// Resolved per-domain lk-jwt-service base URL (e.g. https://jwt.stalk.pics) for THIS call,
    /// taken from the homeserver's MSC4143 rtc_foci. Used both to fetch LiveKit creds (/sfu/get)
    /// and to advertise our own foci_preferred so remote clients agree on the same focus.
    private var resolvedJWTServiceURL: String?

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var heartbeatTask: Task<Void, Never>?

    // STMOB-126: периодический re-broadcast текущего E2EE-ключа.
    /// Ключ рассылается по Matrix to-device — на деградировавшем (но не
    /// сменившемся) канале эта отправка может молча отвалиться, и другие
    /// перестают расшифровывать наш звук (мы слышим всех, нас — нет; mute/unmute
    /// не помогает, только полный rejoin). on-event триггеров (foreground / JOIN /
    /// смена сетевого интерфейса) недостаточно: канал тот же, новых участников нет.
    /// Низкочастотный rebroadcast ТОГО ЖЕ ключа (без ротации) самозалечивает
    /// desync в пределах интервала. Тот же подход, что в Element Call web.
    private var keyRebroadcastTimer: Task<Void, Never>?
    private static let keyRebroadcastInterval: UInt64 = 15_000_000_000 // 15s

    /// STMOB-269. Расклиненная (wedged) Olm-сессия — отправитель шлёт ключ, сервер
    /// доставляет, а расшифровать мы не можем, потому что храповик разъехался.
    /// Чинится только пересозданием сессии со стороны ОТПРАВИТЕЛЯ. Снаружи это
    /// выглядит как чёрное видео собеседника, а в логе нет ни строчки: ошибка
    /// остаётся внутри SDK и наружу не выставлена. 28.07 на это ушёл день перебора
    /// сборок, хотя признак был однозначный — ноль входящих ключей от участника.
    /// Сторож делает провал явным.
    ///
    /// Порог на порядок больше нормы: в здоровом звонке ключ приходит через
    /// 0.7-1.5с после появления участника (лог 180: JOIN 22:59:15.867 → ключ .581).
    private static let keyGapWarnAfter: TimeInterval = 10
    private static let keyGapEscalateAfter: TimeInterval = 30
    private static let keyGapCheckInterval: UInt64 = 2_000_000_000 // 2s
    /// STMOB-126: предыдущее состояние LiveKit-соединения — для детекта
    /// восстановления (.reconnecting → .connected) и немедленного rebroadcast.
    private var lastConnectionState: ConnectionState = .disconnected

    // Network change monitoring — triggers E2EE key resend on wifi/cellular/none transitions.
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkInterface = ""

    // STMOB-256: диагностика латентности подключения. callStartTime ставится в start(),
    // elapsedMs() даёт мс от старта — DiagLog каждой фазы, чтобы видеть где уходят
    // секунды (особенно на .uz с высоким RTT). capabilitiesNegotiated поднимается
    // после ответа на toWidget capabilities — заменяет глухой sleep(5s) событийным
    // ожиданием с потолком.
    private var callStartTime: Date?
    private var capabilitiesNegotiated = false
    private func elapsedMs() -> Int {
        guard let callStartTime else { return -1 }
        return Int(Date().timeIntervalSince(callStartTime) * 1000)
    }

    // MARK: - Init

    /// Включать ли камеру сразу после connect. false для АУДИО-звонков:
    /// раньше камера включалась безусловно и гасла постфактум в VM — вспышка
    /// индикатора камеры + первые кадры в эфир (тот же баг Molly чинила на web:
    /// enable_video=true по умолчанию у виджета). Вопрос Molly 15.07.
    private let enableCameraOnConnect: Bool

    init(widgetDriver: ElementCallWidgetDriverProtocol,
         liveKitRoomManager: LiveKitRoomManager,
         isEncrypted: Bool,
         userId: String,
         displayName: String? = nil,
         deviceId: String,
         matrixRoomId: String,
         homeserverURL: String,
         accessTokenProvider: @escaping () -> String,
         tokenRefresher: @escaping () async -> Void,
         roomProxy: JoinedRoomProxyProtocol? = nil,
         enableCameraOnConnect: Bool = true) {
        self.enableCameraOnConnect = enableCameraOnConnect
        self.widgetDriver = widgetDriver
        self.liveKitRoomManager = liveKitRoomManager
        self.isEncrypted = isEncrypted
        self.userId = userId
        ownDisplayName = displayName
        self.deviceId = deviceId
        self.matrixRoomId = matrixRoomId
        self.homeserverURL = homeserverURL.hasSuffix("/") ? String(homeserverURL.dropLast()) : homeserverURL
        self.accessTokenProvider = accessTokenProvider
        self.tokenRefresher = tokenRefresher
        self.roomProxy = roomProxy
    }

    // MARK: - Start

    func start(baseURL: URL,
               clientID: String,
               colorScheme: SwiftUI.ColorScheme) async {
        MXLog.info("sTalk NativeCall: Starting session, encrypted=\(isEncrypted), user=\(userId)")
        os_log(.info, log: callLog, "Starting session encrypted=%{public}@ user=%{public}@", "\(isEncrypted)", userId)
        sessionState = .starting
        callStartTime = Date() // STMOB-256: точка отсчёта для диагностики латентности
        DiagLog.write("CallPerf", "start() begin — connecting to call")
        setupNetworkMonitor()

        // Start WidgetDriver in background for E2EE key exchange only
        // WidgetDriver uses different state_key format, won't conflict with our REST join
        let driverResult = await widgetDriver.start(baseURL: baseURL,
                                                    clientID: clientID,
                                                    colorScheme: colorScheme,
                                                    rageshakeURL: nil,
                                                    analyticsConfiguration: nil)
        DiagLog.write("CallPerf", "widgetDriver.start done @\(elapsedMs())ms")
        if case .success = driverResult {
            widgetDriver.messagePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.processWidgetMessage(message)
                }
                .store(in: &cancellables)

            // Step 1: Request capabilities (same as Element Call JS does)
            let capabilities = [
                "org.matrix.msc3819.send.to_device:io.element.call.encryption_keys",
                "org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys",
                // Ключи звонка ходят ДВУМЯ путями: адресно через устройства и обычными
                // событиями в комнату. Мы просили только первый, поэтому ключ веба до нас
                // не доходил ни по какому каналу — своё эхо видели, чужого ключа нет,
                // расшифровать чужое видео нечем. Симптом: с веба на iOS видео не идёт,
                // обратно идёт (разбор Molly по логам обеих сторон, 28.07).
                "org.matrix.msc2762.send.event:io.element.call.encryption_keys",
                "org.matrix.msc2762.receive.event:io.element.call.encryption_keys",
                "org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member",
                "org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member",
                "org.matrix.msc2762.send.state_event:org.matrix.msc4075.rtc.notification",
                "org.matrix.msc2762.receive.state_event:org.matrix.msc4075.rtc.notification",
                "org.matrix.msc2762.send.delayed_event",
                "org.matrix.msc2762.update.delayed_event",
                "requires_client"
            ]
            let capsJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let capRequest = """
            {"api":"fromWidget","action":"org.matrix.msc2974.request_capabilities","widgetId":"\(widgetDriver.widgetID)","requestId":"native-cap-\(UUID().uuidString)","data":{"capabilities":[\(capsJSON)]}}
            """
            await widgetDriver.handleMessage(capRequest)
            MXLog.info("sTalk NativeCall: WidgetDriver — capabilities requested")

            // STMOB-256: раньше здесь был глухой sleep(1s) — драйверу нужно лишь
            // локально принять fromWidget request_capabilities, это быстро. 400мс с
            // запасом; настоящее ожидание — событийное на шаге negotiation ниже.
            try? await Task.sleep(for: .milliseconds(400))

            // Step 2: content_loaded
            let contentLoaded = """
            {"api":"fromWidget","action":"content_loaded","widgetId":"\(widgetDriver.widgetID)","requestId":"native-\(UUID().uuidString)","data":{}}
            """
            await widgetDriver.handleMessage(contentLoaded)
            MXLog.info("sTalk NativeCall: WidgetDriver — content_loaded sent")

            // STMOB-256: раньше глухой sleep(5s) «ждём негоциацию capabilities» —
            // это была самая большая фиксированная задержка на КАЖДЫЙ звонок (тестеры
            // .uz: «долго подключаешься»). Теперь ждём РЕАЛЬНОГО завершения (флаг
            // capabilitiesNegotiated поднимается в processWidgetMessage после ответа
            // на toWidget capabilities) с потолком 5s — worst case не хуже прежнего,
            // типично < 1s. Поллинг 50мс.
            await waitForCapabilitiesNegotiation(ceilingMs: 5000)

            // Step 3: io.element.join — trigger MatrixRTC
            let joinCall = """
            {"api":"fromWidget","action":"io.element.join","widgetId":"\(widgetDriver.widgetID)","requestId":"native-join-\(UUID().uuidString)","data":{}}
            """
            await widgetDriver.handleMessage(joinCall)
            DiagLog.write("CallPerf", "io.element.join sent @\(elapsedMs())ms")
            MXLog.info("sTalk NativeCall: WidgetDriver — io.element.join sent")
        }

        // E2EE key exchange
        if isEncrypted {
            // Listen to room timeline for incoming encryption keys.
            // IMPORTANT: timeline.subscribeForUpdates must complete before we access
            // timelineItemProvider (force-unwraps innerTimelineItemProvider otherwise).
            // At VoIP cold-start the timeline isn't yet subscribed — без await => CRASH.
            Task { [weak self] in
                await self?.listenForEncryptionKeysFromTimeline()
            }

            // STMOB-101 v3: упростили rebroadcast стратегию.
            //
            // v1 (build 99/100): for-loop 12×10s regenerate + while-loop 30s
            //   rebroadcast. Каждый sendOurEncryptionKey() RE-GENERATES random
            //   key → rotate KID в SFrame у Element Call widget.
            // v2 (build 101): same loop + DiagLog + foreground observer.
            //
            // Регрессия: ВСЕ участники ratchet'ат KID на каждом нашем
            // m.room.encrypted event. Egress / Key Server / KS-Bridge
            // не успевают синхронизироваться, cipher auth fail на 99%
            // последующих frames (Molly STMOB-101: tymbay 99.7% fail в
            // recording, ms.implica decrypted OK case-by-case).
            //
            // v3 — близко к Element Call upstream + минимально необходимый
            // расход на iOS-specific scenarios:
            //
            //   - Initial: sendOurEncryptionKey ОДИН РАЗ (3s после start).
            //     Generate + setKey + broadcast — это база.
            //   - НЕ ratchet'ить KID каждые N секунд. Никакого таймера.
            //   - On member JOIN (новый remote identity в $remoteParticipants):
            //     rebroadcastCurrentEncryptionKey — ТОТ ЖЕ key, no rotation,
            //     чтобы newcomer/reconnect мог расшифровать. Это hook ниже.
            //   - On member LEAVE (identity исчезла из $remoteParticipants):
            //     sendOurEncryptionKey — RE-generate (security — leaving peer
            //     не должен decrypt'ить future frames). Hook ниже.
            //   - On foreground entry: rebroadcastCurrentEncryptionKey — same
            //     key. Покрывает случай когда iOS-side стейт мог отстать от
            //     room state пока app был в background.
            //
            // С таким набором rotations происходят только при реальных
            // membership events — egress / KS-Bridge успевают догнать.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let s = self, s.sessionState != .disconnected else {
                    DiagLog.write("E2EE", "initial sendOurEncryptionKey EXIT — self=nil or disconnected")
                    return
                }
                DiagLog.write("E2EE", "initial sendOurEncryptionKey")
                await s.sendOurEncryptionKey()
            }

            // STMOB-101 v3: foreground entry — rebroadcast same key (no rotation).
            // Iff stay long in background и iOS suspended app — на возврат
            // дёргаем rebroadcast чтобы новые participant'ы которые подключились
            // пока we were sleeping получили текущий ключ (тот же KID).
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                        object: nil,
                                                                        queue: .main) { [weak self] _ in
                guard let self, self.sessionState != .disconnected else { return }
                DiagLog.write("E2EE", "foreground entry — rebroadcast same key")
                Task { [weak self] in
                    await self?.rebroadcastCurrentEncryptionKey()
                }
            }
        }

        // Observe LiveKit disconnect → auto-end call
        liveKitRoomManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let previous = self.lastConnectionState
                self.lastConnectionState = state
                if state == .disconnected, self.sessionState == .connected {
                    // STMOB-262: окно грации. Пока идёт ремонт доставки, сессию не
                    // закрываем — иначе экран звонка исчезает раньше, чем ремонт
                    // успевает отработать, а собственный авто-реконнект вдобавок
                    // самоотменяется (disconnect() уже обнулил сохранённые креды).
                    if self.liveKitRoomManager.isRecovering {
                        DiagLog.write("Call", "LiveKit disconnected, но идёт ремонт доставки — держим сессию")
                        self.startRecoveryGraceTimer()
                    } else {
                        MXLog.info("sTalk NativeCall: LiveKit disconnected while connected — ending session")
                        self.sessionState = .disconnected
                    }
                }
                // STMOB-126: транспорт восстановился после деградации канала —
                // немедленно пере-рассылаем ключ (быстрый путь, не дожидаясь
                // периодического таймера). Раньше на .connected ничего не
                // пересылалось → других держало в desync до ручного rejoin.
                if previous == .reconnecting, state == .connected, self.sessionState == .connected {
                    DiagLog.write("E2EE", "connection recovered (reconnecting → connected) → rebroadcast same key")
                    MXLog.info("sTalk NativeCall E2EE: connection recovered — rebroadcasting key")
                    Task { [weak self] in await self?.rebroadcastCurrentEncryptionKey() }
                }
            }
            .store(in: &cancellables)

        // STMOB-262: SDK переподключился — ключ на той стороне мог не пережить
        // переподключение, рассылаем заново. Тот же путь используют ступени ремонта.
        liveKitRoomManager.encryptionKeyRebroadcastSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                if isEncrypted, ourEncryptionKey != nil {
                    Task { [weak self] in await self?.rebroadcastCurrentEncryptionKey() }
                }
                // STMOB-264: переподключение — момент, когда участие в комнате могло
                // не пережить обрыв. Сверяем инвариант; если всё на месте — no-op.
                Task { [weak self] in await self?.reconcileCallMembership(trigger: "reconnect") }
            }
            .store(in: &cancellables)

        // Observe remote participants leaving (auto-end when last one leaves).
        // STMOB-101 v3: detect JOIN (newcomer/reconnect) и LEAVE (security
        // rotation). Реакция:
        //   - JOIN: rebroadcastCurrentEncryptionKey — same KID, иначе newcomer
        //     не сможет decrypt'ить audio.
        //   - LEAVE: sendOurEncryptionKey — regenerate KID (security: leaving
        //     peer не должен decrypt'ить future frames). Это standard E2EE
        //     behavior для media rotation.
        // Никакого периодического timer — только on-event triggers.
        liveKitRoomManager.$remoteParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self, self.sessionState == .connected else { return }
                if !participants.isEmpty {
                    self.hasSeenRemoteParticipant = true

                    let currentIdentities = Set(participants.map { $0.identity?.stringValue ?? "" })
                    let newIdentities = currentIdentities.subtracting(self.knownRemoteIdentities)
                    let leftIdentities = self.knownRemoteIdentities.subtracting(currentIdentities)

                    if !leftIdentities.isEmpty {
                        // STMOB-101: security rotation на leave. Не должны
                        // оставлять прошлого peer'а с возможностью decrypt'ить
                        // future audio (он уже не в room, но может прослушивать
                        // SFU stream если cached его old subscription).
                        // STMOB-262: во время переподключения LEAVE фантомный — SDK на
                        // полном реконнекте шлёт disconnect на всех участников, а через
                        // секунду они возвращаются. Ротировать ключ на этом нельзя:
                        // получим churn индексов и провалы расшифровки на ровном месте.
                        let reconnecting = self.liveKitRoomManager.isRecovering
                            || self.liveKitRoomManager.sdkReconnectMode != nil
                            || self.liveKitRoomManager.connectionState == .reconnecting
                        if reconnecting {
                            DiagLog.write("E2EE", "remote LEAVE \(leftIdentities) во время реконнекта → НЕ ротирую, только re-advertise")
                            Task { [weak self] in await self?.rebroadcastCurrentEncryptionKey() }
                        } else {
                            MXLog.info("sTalk NativeCall E2EE: remote left \(leftIdentities) — regenerating key")
                            DiagLog.write("E2EE", "remote LEAVE \(leftIdentities) → regenerate key")
                            Task { [weak self] in
                                await self?.sendOurEncryptionKey()
                            }
                        }
                    } else if !newIdentities.isEmpty {
                        MXLog.info("sTalk NativeCall E2EE: new remote participant(s) — \(newIdentities) — rebroadcasting same key")
                        DiagLog.write("E2EE", "remote JOIN \(newIdentities) → rebroadcast same key")
                        self.registerRecipients(fromLiveKitIdentities: newIdentities)
                        Task { [weak self] in
                            await self?.rebroadcastCurrentEncryptionKey()
                        }
                    }
                    // STMOB-269: момент появления фиксируем ВНЕ ветки newIdentities —
                    // снимок, где кто-то ушёл и кто-то пришёл одновременно, идёт по
                    // ветке leftIdentities и мимо неё бы проскочил.
                    for identity in currentIdentities where self.remoteFirstSeenAt[identity] == nil {
                        self.remoteFirstSeenAt[identity] = Date()
                    }
                    self.startKeyGapWatchdogIfNeeded()
                    self.knownRemoteIdentities = currentIdentities
                } else if self.hasSeenRemoteParticipant {
                    // STMOB-262: пустой список — НЕ всегда «все ушли». Полный реконнект
                    // (наш ремонт доставки или последняя попытка лестницы SDK) делает
                    // cleanUp(isFullReconnect:), который шлёт participantDidDisconnect на
                    // каждого и обнуляет remoteParticipants — а через секунду они
                    // возвращаются. Раньше на этом звонок завершался сам, с REST-leave,
                    // то есть собеседник видел наш выход посреди переподключения.
                    let reconnecting = self.liveKitRoomManager.isRecovering
                        || self.liveKitRoomManager.sdkReconnectMode != nil
                        || self.liveKitRoomManager.connectionState == .reconnecting
                    if reconnecting {
                        DiagLog.write("Call", "все участники исчезли, но идёт переподключение — звонок НЕ завершаю")
                    } else {
                        MXLog.info("sTalk NativeCall: All remote participants left after being connected — ending session")
                        Task { [weak self] in await self?.confirmAllRemotesLeftAndStop() }
                    }
                }
            }
            .store(in: &cancellables)

        // Generate JWT and connect to LiveKit
        sessionState = .waitingForCredentials
        await connectWithGeneratedJWT()
    }

    /// STMOB-256: событийное ожидание завершения negotiation capabilities с потолком.
    /// Возвращается сразу как только `capabilitiesNegotiated` поднят в
    /// processWidgetMessage (ответ на toWidget capabilities), иначе — по истечении
    /// ceilingMs. Заменяет прежний глухой sleep(5s): worst case не хуже, типично много
    /// быстрее. Поллинг 50мс — дёшево и без continuation-гонок.
    private func waitForCapabilitiesNegotiation(ceilingMs: Int) async {
        let stepMs = 50
        var waited = 0
        while !capabilitiesNegotiated, waited < ceilingMs {
            try? await Task.sleep(for: .milliseconds(stepMs))
            waited += stepMs
        }
        if capabilitiesNegotiated {
            DiagLog.write("CallPerf", "capabilities wait resolved after \(waited)ms (@\(elapsedMs())ms)")
        } else {
            DiagLog.write("CallPerf", "capabilities wait CEILING \(ceilingMs)ms hit (@\(elapsedMs())ms) — proceeding")
        }
    }

    // sTalk: sendJoinMembership() удалён (ревью 2026-07-17) — мёртвый код (join идёт
    // через sendJoinViaREST() REST-путём; widget-based join был вытеснен). При
    // воскрешении вызвал бы второй connectWithGeneratedJWT() без гарда credentialsReceived.

    private func connectWithGeneratedJWT() async {
        // LiveKit room name = the matrix room ID (the call's livekit_alias). Element Call web sends
        // exactly this to /sfu/get, and the upstream lk-jwt-service uses `room` VERBATIM (never
        // hashes — byte-identical image on every install, confirmed by Molly/STALK). So iOS and Web
        // land in the SAME LiveKit room on ANY server. The old base64(SHA256(roomId|m.call#ROOM))
        // hash is the meet-api guest scheme, NOT widget/room calls → it put us in a different room.
        guard !matrixRoomId.isEmpty else {
            MXLog.error("sTalk NativeCall: empty matrixRoomId")
            sessionState = .failed(NativeCallError.noCredentials)
            return
        }
        let roomName = matrixRoomId

        // Resolve THIS homeserver's per-domain lk-jwt-service (rtc_foci) up front so we advertise
        // the correct focus in our own call.member and fetch creds from the right service.
        let jwtService = await resolveLiveKitServiceURL()
        resolvedJWTServiceURL = jwtService
        DiagLog.write("CallPerf", "jwt service resolved @\(elapsedMs())ms")

        // Send MatrixRTC join via REST API so remote participants see us
        let joinEventID = await sendJoinViaREST()
        DiagLog.write("CallPerf", "join via REST done @\(elapsedMs())ms")
        // STMOB-154 build 178: сохраняем для использования в m.reaction events
        // (hand raise iOS → Web bridge). Web Element Call widget читает m.reaction
        // с m.relates_to.event_id равным call.member event_id для отображения hand raise.
        callMemberEventID = joinEventID

        // STMOB-211: подстраховка от зависшего membership — серверный отложенный leave.
        await scheduleDelayedLeave()

        // STMOB-200: ring ТОЛЬКО если мы инициатор — в комнате нет других
        // активных участников звонка. Заход в уже идущую встречу не должен
        // ре-звонить: раньше отправлялся CallKit-пуш «входящий» ВСЕМ active-членам
        // комнаты, включая тех, кто уже в звонке (напр. Сергей с веба) — он жал
        // «Ответить» и не мог войти, т.к. уже был в встрече.
        let alreadyInCall = await fetchActiveCallMemberUserIDs()
        if alreadyInCall.isEmpty {
            await sendCallNotification(callMemberEventID: joinEventID)
        } else {
            MXLog.info("sTalk NativeCall: joining ongoing call (\(alreadyInCall.count) already in) — skip ring")
            DiagLog.write("Call", "join ongoing call: \(alreadyInCall.count) members already in → NO ring (STMOB-200)")
        }

        // STMOB-256: debugReadCallMemberState() удалён с критического пути — это был
        // чистый DEBUG-round-trip (read state events «to compare formats»), который
        // задерживал fetch creds на целый сетевой запрос без пользы в проде.

        // Fetch LiveKit creds from the per-domain lk-jwt-service (correct SFU wss url + a valid JWT
        // signed with THIS install's api secret). Replaces the old local generation with a
        // hardcoded stalk.implica.ru key/SFU that broke calls on any other install.
        guard let creds = await fetchLiveKitCredentials(jwtServiceURL: jwtService, roomName: roomName) else {
            MXLog.error("sTalk NativeCall: Failed to fetch LiveKit credentials from \(jwtService)")
            sessionState = .failed(NativeCallError.noCredentials)
            return
        }
        DiagLog.write("CallPerf", "livekit creds fetched @\(elapsedMs())ms sfu=\(creds.url)")
        MXLog.info("sTalk NativeCall: LiveKit creds room=\(roomName) identity=\(userId):\(deviceId) sfu=\(creds.url)")
        await connectToLiveKit(url: creds.url, token: creds.jwt)
    }

    private func generateLiveKitRoomName() -> String? {
        guard !matrixRoomId.isEmpty else { return nil }
        let raw = "\(matrixRoomId)|m.call#ROOM"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - LiveKit auth (per-domain lk-jwt-service)

    /// Bare host of the current homeserver (e.g. "stalk.pics"). Fallback keeps legacy behaviour.
    private var homeserverHost: String {
        URL(string: homeserverURL)?.host ?? "stalk.implica.ru"
    }

    /// Resolve the lk-jwt-service base URL for the current homeserver from its MSC4143
    /// `org.matrix.msc4143.rtc_foci` well-known entry (what Web uses). Falls back to the
    /// `jwt.<host>` convention. This is per-install: each domain (stalk.implica.ru / .uz /
    /// stalk.pics / any client) has its OWN LiveKit service + api key/secret (Molly, STALK),
    /// so the old hardcoded stalk.implica.ru URL + embedded key only worked on .ru-shared infra.
    private func resolveLiveKitServiceURL() async -> String {
        if let wellKnownURL = URL(string: "\(homeserverURL)/.well-known/matrix/client"),
           let (data, _) = try? await restSession.data(from: wellKnownURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let foci = json["org.matrix.msc4143.rtc_foci"] as? [[String: Any]],
           let url = foci.first(where: { ($0["type"] as? String) == "livekit" })?["livekit_service_url"] as? String,
           !url.isEmpty {
            return url
        }
        let fallback = "https://jwt.\(homeserverHost)"
        MXLog.warning("sTalk NativeCall: rtc_foci not found in well-known, falling back to \(fallback)")
        return fallback
    }

    /// Request a Matrix OpenID token — the lk-jwt-service validates it against the homeserver to
    /// authenticate us, then mints a LiveKit JWT signed with THAT install's api secret.
    private func requestOpenIDToken() async -> [String: Any]? {
        let encodedUser = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUser)/openid/request_token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await restSession.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            MXLog.error("sTalk NativeCall: failed to obtain Matrix OpenID token")
            return nil
        }
        return json
    }

    /// Fetch LiveKit credentials from the per-domain lk-jwt-service (`POST {service}/sfu/get`),
    /// exactly like Element Call web. Returns the ACTUAL SFU websocket url + a valid JWT.
    /// `roomName` must match what other clients use (the hashed room name) so we land in the
    /// same LiveKit room.
    private func fetchLiveKitCredentials(jwtServiceURL: String, roomName: String) async -> (url: String, jwt: String)? {
        guard let openIDToken = await requestOpenIDToken() else { return nil }
        let base = jwtServiceURL.hasSuffix("/") ? String(jwtServiceURL.dropLast()) : jwtServiceURL
        guard let url = URL(string: "\(base)/sfu/get") else { return nil }
        let body: [String: Any] = [
            "room": roomName,
            "openid_token": openIDToken,
            "device_id": deviceId
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sfu = json["url"] as? String, let jwt = json["jwt"] as? String else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "?"
                MXLog.error("sTalk NativeCall: /sfu/get failed \(status) body=\(bodyStr.prefix(200))")
                return nil
            }
            MXLog.info("sTalk NativeCall: /sfu/get OK → sfu=\(sfu) service=\(base)")
            return (sfu, jwt)
        } catch {
            MXLog.error("sTalk NativeCall: /sfu/get error: \(error)")
            return nil
        }
    }

    // MARK: - MatrixRTC Join via REST API

    /// Send MatrixRTC join via REST API. Returns the event_id of the call.member state event.
    @discardableResult
    private func sendJoinViaREST() async -> String? {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        // State key format: _@user:server_deviceId_m.call
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        let eventType = "org.matrix.msc3401.call.member"
        let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)"

        // Flat format matching Element Call web client
        let body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "scope": "m.room",
            "device_id": deviceId,
            "expires": 7_200_000,
            "foci_preferred": [[
                "type": "livekit",
                "livekit_alias": matrixRoomId,
                "livekit_service_url": resolvedJWTServiceURL ?? "https://jwt.\(homeserverHost)"
            ]],
            "focus_active": [
                "type": "livekit",
                "focus_selection": "oldest_membership"
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        guard let requestURL = URL(string: url) else {
            MXLog.error("sTalk NativeCall: invalid join URL: \(url)")
            return nil
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            MXLog.info("sTalk NativeCall: REST join \(eventType) → \(status) url=\(url) body=\(respBody.prefix(200))")

            // Extract event_id from response: {"event_id": "$xxx"}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let eventID = json["event_id"] as? String {
                return eventID
            }
        } catch {
            MXLog.error("sTalk NativeCall: REST join failed: \(error)")
        }
        return nil
    }

    // MARK: - Hand Raise Matrix Reaction (STMOB-154)

    /// Send или redact Matrix `m.reaction` event для hand raise.
    /// Web Element Call widget слушает только Matrix m.reaction, не LiveKit metadata —
    /// без этого Web участники не видят руку iOS host. Параллельный путь к
    /// `LiveKitRoomManager.setHandRaise` (LiveKit metadata, для iOS↔iOS и iOS↔guest).
    func sendHandRaiseReaction(raised: Bool) async {
        guard let callMemberEventID, !callMemberEventID.isEmpty else {
            DiagLog.write("Call", "sendHandRaiseReaction ABORT — нет callMemberEventID (call не joined через REST?)")
            return
        }
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId

        if raised {
            // PUT /rooms/{room}/send/m.reaction/{txn}
            let body: [String: Any] = [
                "m.relates_to": [
                    "rel_type": "m.annotation",
                    "event_id": callMemberEventID,
                    "key": "🖐️"
                ]
            ]
            let txn = "hand-raise-\(UUID().uuidString)"
            let encodedTxn = txn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? txn
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/send/m.reaction/\(encodedTxn)"
            if let eventID = await sendMatrixEvent(url: url, body: body, method: "PUT") {
                handReactionEventID = eventID
                DiagLog.write("Call", "hand raise m.reaction SENT eventID=\(eventID) relates_to=\(callMemberEventID)")
            } else {
                DiagLog.write("Call", "hand raise m.reaction SEND FAILED relates_to=\(callMemberEventID)")
            }
        } else {
            guard let prevEventID = handReactionEventID, !prevEventID.isEmpty else {
                DiagLog.write("Call", "hand raise redact SKIP — нет handReactionEventID (рука уже опущена)")
                return
            }
            // PUT /rooms/{room}/redact/{eventID}/{txn}
            let encodedEventID = prevEventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prevEventID
            let txn = "hand-redact-\(UUID().uuidString)"
            let encodedTxn = txn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? txn
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/redact/\(encodedEventID)/\(encodedTxn)"
            if let eventID = await sendMatrixEvent(url: url, body: [:], method: "PUT") {
                DiagLog.write("Call", "hand raise REDACTED \(prevEventID) → \(eventID)")
            } else {
                DiagLog.write("Call", "hand raise REDACT FAILED for \(prevEventID)")
            }
            handReactionEventID = nil
        }
    }

    /// Generic helper: PUT/POST Matrix event с access token, parse event_id из response.
    private func sendMatrixEvent(url: String, body: [String: Any], method: String) async -> String? {
        guard let urlObj = URL(string: url) else { return nil }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200, status < 300,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let eventID = json["event_id"] as? String {
                return eventID
            } else {
                let respBody = String(data: data, encoding: .utf8) ?? ""
                MXLog.error("sTalk NativeCall: sendMatrixEvent \(method) \(url) → \(status) body=\(respBody.prefix(200))")
                return nil
            }
        } catch {
            MXLog.error("sTalk NativeCall: sendMatrixEvent failed: \(error)")
            return nil
        }
    }

    // MARK: - Raw Key Provider Access

    /// Set raw bytes key in BaseKeyProvider, bypassing UTF-8 string conversion
    /// BaseKeyProvider.rtcKeyProvider is internal, so we use KVC to access it
    /// Set key using the same raw bytes that EC JS uses
    /// Converts raw Data to a String where each byte maps 1:1 (ISO Latin-1)
    /// LiveKit SDK will .utf8 encode this — for ASCII-range bytes it's identical
    private func setRawKeyInProvider(_ provider: BaseKeyProvider, key: Data, participantId: String, index: Int32) {
        // webrtc 144 with useHKDF:true does HKDF internally — pass RAW bytes only
        provider.setRawKey(key, participantId: participantId, index: index)
        MXLog.info("sTalk E2EE: Raw key (\(key.count) bytes) for \(participantId) idx=\(index)")
    }

    // MARK: - E2EE Key Exchange

    private var ourEncryptionKey: String? // base64
    private var ourEncryptionKeyRaw: Data? // raw 16 bytes

    /// STMOB-246: build an ADDRESSED send_to_device payload (messages:{user:{device:content}})
    /// targeting only the active call participants (incl. egress — it must decrypt for recording),
    /// instead of the wildcard messages:{"*":{"*":…}} broadcast that leaked the key into every
    /// device_inbox of every room member (~182 stray keys per Molly's misty analysis). Recipients =
    /// current LiveKit remoteParticipants (identity "@user:server:DEVICE", split on the LAST ':').
    /// Returns nil when there are no recipients (alone in the call) — caller then skips the to-device
    /// send; the room-event channel still carries the key as interim fallback.
    /// NOTE: keys shape kept as the current object form; canonical array shape + recipient source
    /// are finalised per Molly's STALK-505 spec and validated on the STALK-506 stand before merge.
    private func buildAddressedToDeviceMessage(key: String, requestIdPrefix: String, nowMs: Int) -> String? {
        // STMOB-246: recipients from call.member memberships (canon, STALK-505) — NOT LiveKit
        // presence. Egress is not a call-member → naturally excluded (recording goes via Key Server).
        var messages: [String: [String: Any]] = [:]
        for recipient in activeMemberRecipients() {
            guard recipient.user.hasPrefix("@"), !recipient.device.isEmpty else { continue }
            let content: [String: Any] = [
                "keys": ["index": 0, "key": key],
                "room_id": matrixRoomId,
                "member": ["claimed_device_id": deviceId],
                "session": ["call_id": "", "application": "m.call", "scope": "m.room"],
                "sent_ts": nowMs
            ]
            messages[recipient.user, default: [:]][recipient.device] = content
        }
        guard !messages.isEmpty else {
            DiagLog.write("E2EE", "addressed to-device SKIP — no active recipients (alone in call)")
            return nil
        }
        let envelope: [String: Any] = [
            "api": "fromWidget",
            "action": "send_to_device",
            "widgetId": widgetDriver.widgetID,
            "requestId": "\(requestIdPrefix)-\(UUID().uuidString)",
            "data": ["type": "io.element.call.encryption_keys", "encrypted": true, "messages": messages]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            DiagLog.write("E2EE", "addressed to-device BUILD FAILED — skip (room-event fallback carries key)")
            return nil
        }
        let deviceCount = messages.values.reduce(0) { $0 + $1.count }
        DiagLog.write("E2EE", "addressed to-device → \(messages.count) users / \(deviceCount) devices")
        return json
    }

    private func sendOurEncryptionKey() async {
        // Generate random 16-byte key (base64). Matches build-34 behavior: regenerate per call,
        // use setKey(string) — changing either broke web decryption (build 35 regression).
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let rawData = Data(keyBytes)
        let key = rawData.base64EncodedString()
        ourEncryptionKey = key
        ourEncryptionKeyRaw = rawData // keep in sync so connectToLiveKit has raw bytes

        // Set our own key in keyProvider
        let ourIdentity = "\(userId):\(deviceId)"
        keyProvider.setKey(key: key, participantId: ourIdentity, index: 0)
        MXLog.info("sTalk NativeCall E2EE: Generated our key, identity=\(ourIdentity)")
        os_log(.info, log: callLog, "E2EE key generated identity=%{public}@", ourIdentity)

        let widgetId = widgetDriver.widgetID
        let devId = deviceId
        let driver = widgetDriver
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        // Send via Widget API send_to_device — ADDRESSED to active participants (STMOB-246),
        // with retry on transient failures. nil = no recipients yet → skip (room-event carries it).
        if let toDeviceMsg = buildAddressedToDeviceMessage(key: key, requestIdPrefix: "native-key", nowMs: nowMs) {
            Task.detached {
                await Self.sendWidgetMessageWithRetry(label: "send_to_device", message: toDeviceMsg, driver: driver)
            }
        }

        // Send as room event — with retry. STMOB-246: gated; canon = to-device-only SEND.
        if Self.kSendKeyViaRoomEvent {
            let roomEventMsg = """
            {"api":"fromWidget","action":"send_event","widgetId":"\(widgetId)","requestId":"native-roomkey-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","content":{"keys":[{"index":0,"key":"\(key)"}],"device_id":"\(devId)","call_id":"","sent_ts":\(nowMs)}}}
            """
            Task.detached {
                await Self.sendWidgetMessageWithRetry(label: "send_event", message: roomEventMsg, driver: driver)
            }
        }

        // Publish key to key-server so recording-api can decrypt
        Task.detached { [weak self] in
            await self?.publishKeyToKeyServer(key: key)
        }

        MXLog.info("sTalk NativeCall E2EE: Key send tasks launched (with retry)")
    }

    /// STMOB-96: Re-broadcast current encryption key WITHOUT regenerating it.
    /// Используется в continuous loop после первых 2 минут жизни звонка чтобы
    /// reconnect'нувшийся web-участник (новый pID) или late newcomer мог
    /// получить актуальный ключ. Не трогает keyProvider (ключ уже выставлен)
    /// и не публикует на key-server заново — только три рассылочных канала.
    private func rebroadcastCurrentEncryptionKey() async {
        guard let key = ourEncryptionKey, !key.isEmpty else {
            MXLog.warning("sTalk NativeCall E2EE: rebroadcast skipped — no current key")
            DiagLog.write("E2EE", "rebroadcast SKIPPED — no current key (state=\(sessionState))")
            return
        }
        // ⚠️ БЕЗОПАСНОСТЬ: НЕ логировать даже фрагмент ключа — DiagLog шарится
        // тестерами («Share NSE diagnostic log»). Логируем только длину.
        DiagLog.write("E2EE", "rebroadcast START keyLen=\(key.count) (state=\(sessionState))")

        let widgetId = widgetDriver.widgetID
        let devId = deviceId
        let driver = widgetDriver
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        MXLog.info("sTalk NativeCall E2EE: rebroadcast current key (no rotation)")
        os_log(.info, log: callLog, "E2EE rebroadcast current key")

        // STMOB-246: addressed to-device (active participants only) instead of "*" wildcard.
        if let toDeviceMsg = buildAddressedToDeviceMessage(key: key, requestIdPrefix: "native-key-rb", nowMs: nowMs) {
            Task.detached {
                await Self.sendWidgetMessageWithRetry(label: "send_to_device(rb)", message: toDeviceMsg, driver: driver)
            }
        }

        // STMOB-246: gated room-event SEND (canon = to-device-only).
        if Self.kSendKeyViaRoomEvent {
            let roomEventMsg = """
            {"api":"fromWidget","action":"send_event","widgetId":"\(widgetId)","requestId":"native-roomkey-rb-\(UUID().uuidString)","data":{"type":"io.element.call.encryption_keys","content":{"keys":[{"index":0,"key":"\(key)"}],"device_id":"\(devId)","call_id":"","sent_ts":\(nowMs)}}}
            """
            Task.detached {
                await Self.sendWidgetMessageWithRetry(label: "send_event(rb)", message: roomEventMsg, driver: driver)
            }
        }

        // STMOB-101 v2: re-publish в KS на каждом rebroadcast — резерв против
        // KS pod restart / cache eviction. Идемпотентно (тот же ключ).
        Task.detached { [weak self] in
            await self?.publishKeyToKeyServer(key: key, label: "rebroadcast")
        }
    }

    /// Send widget driver message with exponential backoff retry and explicit result parsing.
    /// Backoff: 1s → 2s → 4s (3 attempts, ~7s total). Exits early on success.
    private static func sendWidgetMessageWithRetry(label: String,
                                                   message: String,
                                                   driver: ElementCallWidgetDriverProtocol) async {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            let result = await driver.handleMessage(message)
            switch result {
            case .success(true):
                os_log(.info, log: callLog, "%{public}@ OK attempt=%d", label, attempt)
                return
            case .success(false):
                os_log(.error, log: callLog, "%{public}@ returned false attempt=%d — retrying", label, attempt)
            case .failure(let err):
                os_log(.error, log: callLog, "%{public}@ FAIL attempt=%d: %{public}@", label, attempt, "\(err)")
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        os_log(.error, log: callLog, "%{public}@ FAILED after 3 attempts — key not delivered", label)
    }

    // MARK: - Network monitoring (iOS)

    /// Start monitoring wifi/cellular/none transitions. On change we re-send E2EE keys
    /// because a dropped long-poll can cause peers to miss previously sent to_device events.
    private func setupNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                await self.handleNetworkPathChange(path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// STMOB-262: перед завершением звонка по «все ушли» перепроверяем через 3с.
    /// Пустой список бывает транзиентным: SDK опустошает участников на время полного
    /// реконнекта, а признаки переподключения (isRecovering/sdkReconnectMode/
    /// connectionState) могут не успеть подняться к моменту публикации пустого списка.
    private func confirmAllRemotesLeftAndStop() async {
        try? await Task.sleep(for: .seconds(3))
        let stillEmpty = await MainActor.run { liveKitRoomManager.displayParticipants.isEmpty }
        let reconnecting = await MainActor.run {
            liveKitRoomManager.isRecovering
                || liveKitRoomManager.sdkReconnectMode != nil
                || liveKitRoomManager.connectionState == .reconnecting
        }
        guard stillEmpty, !reconnecting else {
            DiagLog.write("Call", "«все ушли» не подтвердилось через 3с (empty=\(stillEmpty) reconnecting=\(reconnecting)) — звонок живёт")
            return
        }
        DiagLog.write("Call", "«все ушли» подтверждено — завершаю звонок")
        await stop()
    }

    /// Потолок окна грации: дольше держать «восстанавливаем» бессмысленно —
    /// если ремонт не поднял доставку, звонок надо честно закрыть, а не оставлять
    /// пользователя перед замороженным экраном.
    private var recoveryGraceTask: Task<Void, Never>?

    private func startRecoveryGraceTimer() {
        guard recoveryGraceTask == nil else { return }
        recoveryGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.recoveryGraceTask = nil
                guard self.sessionState == .connected,
                      self.liveKitRoomManager.connectionState == .disconnected else { return }
                DiagLog.write("Call", "окно грации истекло — закрываю сессию")
                self.sessionState = .disconnected
            }
        }
    }

    private func handleNetworkPathChange(_ path: NWPath) async {
        let iface: String
        if path.status != .satisfied {
            iface = "none"
        } else if path.usesInterfaceType(.wifi) {
            iface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            iface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            iface = "ethernet"
        } else {
            iface = "other"
        }

        guard iface != lastNetworkInterface else { return }
        let previous = lastNetworkInterface
        lastNetworkInterface = iface

        os_log(.info, log: callLog, "Network change %{public}@ → %{public}@ (encrypted=%{public}@)",
               previous.isEmpty ? "initial" : previous, iface, "\(isEncrypted)")
        // STMOB-262: путь сети — ключевая улика при разборе «медиа не ожило».
        // os_log в выгрузку с устройства не попадает, DiagLog попадает.
        DiagLog.write("Call", "network path \(previous.isEmpty ? "initial" : previous) → \(iface)")
        liveKitRoomManager.noteNetworkPath(interface: iface)

        // Skip the very first path update (no prior state).
        guard !previous.isEmpty else { return }

        // Re-send E2EE key — to_device events may have been lost during the
        // long-poll gap. Build 41/42 did full reconnect here and created cascading loops;
        // build 44 trials .quickReconnect (ICE restart on live transports, no teardown).
        //
        // STMOB-246: re-advertise the SAME key (no rotation) on network change, to match
        // the other re-advertise triggers (foreground / reconnect / JOIN) and Molly/Andy's
        // canon (resend local key by index, not rotate). sendOurEncryptionKey() regenerated
        // a NEW random key on every Wi-Fi↔LTE flip → index-0 churn: peers overwrote slot 0,
        // in-flight frames under the old key-0 briefly failed to decrypt. rebroadcast keeps
        // the same key/index → no disruption. (Sending stays "*"-wildcard for now; addressed
        // recipients are the separate targeting change validated on STALK-506.)
        if isEncrypted, ourEncryptionKey != nil {
            os_log(.info, log: callLog, "Re-advertising SAME E2EE key after network change")
            await rebroadcastCurrentEncryptionKey()
        }

        // STMOB-262: переподключаемся на ВОССТАНОВЛЕНИИ пути, а не на его пропадании.
        // Раньше quick reconnect уходил в том числе на переход «→ none»: на мёртвой
        // сети он взводит внутреннюю лестницу SDK (десяток попыток с паузами, суммарно
        // ~45-50с) и на всё это время глушит собственные детекторы SDK — то есть
        // делает ровно противоположное тому, зачем задумывался. При пропадании пути
        // теперь только фиксируем факт (он же признак для ватчдога доставки).
        guard Self.kEnableQuickReconnectOnNetworkChange else { return }
        guard iface != "none" else {
            DiagLog.write("Call", "network lost — quick reconnect НЕ дёргаем (ждём восстановления пути)")
            return
        }
        await liveKitRoomManager.attemptQuickReconnect(trigger: "network:\(previous)→\(iface)")
    }

    /// Build 44 experiment — toggle to fall back to previous build 43 behaviour.
    private static let kEnableQuickReconnectOnNetworkChange = true

    /// STMOB-246 / STALK-505: gate the room-event channel for SENDING the E2EE key.
    /// Canon = to-device-only SEND (room-event SEND deprecated — it persists key material in
    /// room state, weak forward secrecy, and makes Web flip to broadcast). RECEIVE of room-event
    /// stays on (fallback for legacy senders) — this flag ONLY affects our outgoing send_event.
    /// Default TRUE keeps current behaviour (no-op); the STALK-506 stand flips it false to verify
    /// to-device-only decrypts across Web/iOS/Android/guest before we remove room-event SEND.
    /// STALK-506 stand run (2026-06-24): temporarily FALSE for a to-device-only experiment.
    /// 2026-07-08: reverted to TRUE — current Web still consumes the room-event key; with SEND off
    /// Web can't obtain our key → SFrame "maximum ratchet attempts exceeded" → no iOS video in
    /// encrypted iOS↔web calls. to-device-only SEND stays gated on Molly's Web/Android/guest cross-test.
    private static let kSendKeyViaRoomEvent = true

    #if targetEnvironment(simulator)
    /// DEBUG: симулирует смену сети (wifi → cellular) без Mac WiFi toggle.
    /// Вызывается автоматически через 20s после connect в simulator-сборке.
    func debugSimulateNetworkChange() async {
        os_log(.info, log: callLog, "DEBUG: simulating network change wifi → cellular (for Quick reconnect test)")
        let previous = lastNetworkInterface
        lastNetworkInterface = "cellular"
        if isEncrypted, ourEncryptionKey != nil {
            os_log(.info, log: callLog, "Resending E2EE key after network change")
            await sendOurEncryptionKey()
        }
        if Self.kEnableQuickReconnectOnNetworkChange {
            await liveKitRoomManager.attemptQuickReconnect(trigger: "debug:\(previous)→cellular")
        }
    }
    #endif

    /// STMOB-101 v2: Publish our E2EE key to key-server so recording-api egress
    /// может расшифровывать наши audio/video frames. Молли подтвердила (2026-05-04)
    /// что её server-side KS-Bridge подход не работает — encryption_keys идут
    /// через olm-encrypted to_device (msc3819), Synapse не может прочитать
    /// содержимое. Решение возможно ТОЛЬКО на iOS.
    ///
    /// Format (per Molly):
    /// POST https://stalk.implica.ru/api/keys/pp/{lkRoom}/{userId:deviceId}
    ///   X-Service-Key: key-server-service-secret-2026   (fallback, всегда работает)
    ///   Authorization: Bearer <Matrix access token>     (предпочтительно)
    /// Body: {"key": "<base64url-no-padding>", "keyIndex": <int>}
    private func publishKeyToKeyServer(key: String, label: String = "init") async {
        guard let roomName = generateLiveKitRoomName() else {
            DiagLog.write("E2EE", "KS publish[\(label)] SKIP — no lkRoomName")
            return
        }
        let identity = "\(userId):\(deviceId)"

        // Build 110: STRICT RFC 3986 unreserved encoding (per Molly).
        // urlPathAllowed разрешает `/` `@` `:` — это ломает routing когда lkRoom
        // содержит `/` или identity содержит `@dp.bondar:stalk:device_id`.
        // Encode всё кроме alphanumerics и `-._~`.
        var pathSegmentAllowed = CharacterSet.alphanumerics
        pathSegmentAllowed.insert(charactersIn: "-._~")
        let encodedRoom = roomName.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? roomName
        let encodedIdentity = identity.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? identity

        // Per-domain: recording-api key-server lives on the same host as the homeserver.
        // (X-Service-Key secret may also be per-install — pending confirmation from Molly.)
        let keyServerURL = "https://\(homeserverHost)/api/keys/pp/\(encodedRoom)/\(encodedIdentity)"
        guard let url = URL(string: keyServerURL) else { return }

        // base64 → base64url-no-padding (per Molly's spec)
        let keyBase64URL = key
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let body: [String: Any] = ["key": keyBase64URL, "keyIndex": 0]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // STALK-679: заголовок X-Service-Key УБРАН. Секрет был захардкожен здесь и
        // уезжал в App Store внутри бинарника — то есть доставался из сборки командой
        // strings. С ним можно было прочитать ключи ЛЮБОГО звонка на сервере: проверено
        // живым запросом 28.07, ответ 200 с полной историей чужой комнаты.
        // Молли закрыла авторизацию (key-server e9ee801): Bearer пользователя теперь
        // проверяется на членство в комнате (чтение) и на владение идентичностью
        // (запись), и одного его достаточно — проверено тем же способом.
        // Секрет остаётся на сервере для серверных клиентов (egress записи) и должен
        // быть ротирован, потому что старый уже разошёлся в выпущенных сборках.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200, status < 300 {
                DiagLog.write("E2EE", "KS publish[\(label)] OK \(status) host=\(homeserverHost) room=\(roomName) identity=\(identity)")
                MXLog.info("sTalk NativeCall E2EE: KS publish[\(label)] → \(status) host=\(homeserverHost)")
            } else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "?"
                DiagLog.write("E2EE", "KS publish[\(label)] FAIL \(status) body=\(bodyStr.prefix(200))")
                MXLog.error("sTalk NativeCall E2EE: KS publish[\(label)] HTTP \(status) body=\(bodyStr)")
            }
        } catch {
            DiagLog.write("E2EE", "KS publish[\(label)] ERR \(error)")
            MXLog.error("sTalk NativeCall E2EE: Key publish to key-server failed: \(error)")
        }
    }

    // MARK: - E2EE Key from Room Timeline

    private func listenForEncryptionKeysFromTimeline() async {
        guard let roomProxy else {
            MXLog.warning("sTalk NativeCall E2EE: No roomProxy — can't listen to timeline")
            return
        }

        // Ensure timelineItemProvider готов — на VoIP cold-start его ещё нет,
        // и force-unwrap в getter крашит app. subscribeForUpdates идемпотентен.
        await roomProxy.timeline.subscribeForUpdates()

        roomProxy.timeline.timelineItemProvider.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, _ in
                guard let self else { return }
                for item in items {
                    guard case .event(let eventItem) = item else { continue }

                    // Check if it's a custom event (encryption_keys)
                    if case .msgLike(let msgContent) = eventItem.content,
                       case .other(let eventType) = msgContent.kind {
                        if case .other(let typeStr) = eventType, typeStr.contains("encryption_keys") {
                            // Parse key from debugInfo originalJSON
                            let debugInfo = eventItem.debugInfo
                            if let json = debugInfo.originalJSON,
                               let data = json.data(using: .utf8),
                               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let content = dict["content"] as? [String: Any],
                               let sender = dict["sender"] as? String,
                               sender != self.userId {
                                let deviceId = content["device_id"] as? String ?? ""
                                let participantId = "\(sender):\(deviceId)"

                                if let keys = content["keys"] as? [[String: Any]] {
                                    for keyObj in keys {
                                        if let key = keyObj["key"] as? String,
                                           let index = keyObj["index"] as? Int,
                                           let rawKey = Data(base64Encoded: key) {
                                            self.setRawKeyInProvider(self.keyProvider, key: rawKey, participantId: participantId, index: Int32(index))
                                            self.participantKeys[participantId] = true
                                            MXLog.info("sTalk NativeCall E2EE: 🔑 KEY FROM TIMELINE! \(participantId) index=\(index)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        MXLog.info("sTalk NativeCall E2EE: Listening to room timeline for encryption_keys")
    }

    // sTalk: pollForEncryptionKeys() удалён (ревью 2026-07-17) — мёртвый код (приём
    // ключей идёт через listenForEncryptionKeysFromTimeline; этот polling бы ещё
    // ставил ключи через keyProvider.setKey строкой вместо setRawKeyInProvider).

    // sTalk: debugReadCallMemberState() удалён (ревью 2026-07-17) — мёртвый debug-код
    // (читал call.member state и логировал content в MXLog), содержал force-unwrap URL.

    // MARK: - Call Notification

    /// STMOB-200: user_ids участников с АКТИВНЫМ call.member state (уже в звонке),
    /// кроме себя. По нему решаем: мы инициатор (звоним) или просто заходим в
    /// идущую встречу (НЕ звоним — иначе CallKit-пуш «входящий» прилетает тем,
    /// кто уже в звонке, напр. с веба, и «Ответить» не срабатывает — они уже там).
    ///
    /// Hardened (Molly/STALK-572 joiner-re-ring): the original check both missed real members and
    /// counted phantom ones —
    ///  - only matched `org.matrix.msc3401.call.member`, not the stable `m.call.member`
    ///    (both occur on the wire, see handleSendEvent);
    ///  - treated ANY non-empty content as active, so a legacy leave (`{"memberships": []}`)
    ///    or an expired membership blocked the ring for every later call in the room;
    ///  - a single failed /state request fell open to "nobody in call" → joiner re-ring.
    /// Parsing now mirrors updateCallMembers (legacy memberships[] + flat per-device content,
    /// expiry via expires_ts / created_ts+expires) and the request retries once.
    private func fetchActiveCallMemberUserIDs() async -> Set<String> {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state"

        var events: [[String: Any]]?
        for attempt in 1...2 {
            guard let requestURL = URL(string: url) else {
                MXLog.error("sTalk NativeCall: invalid state URL: \(url)")
                continue
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await restSession.data(for: request),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                events = parsed
                break
            }
            MXLog.warning("sTalk NativeCall: /state fetch attempt \(attempt) failed (ring guard)")
            if attempt == 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard let events else {
            DiagLog.write("Call", "ring guard: /state unavailable after retry — assuming initiator")
            return []
        }

        let callMemberTypes: Set = ["org.matrix.msc3401.call.member", "m.call.member", "m.rtc.member"]
        let nowMs = Date().timeIntervalSince1970 * 1000
        var result: Set<String> = []

        for event in events {
            guard let type = event["type"] as? String, callMemberTypes.contains(type),
                  let sender = event["sender"] as? String, sender != userId else { continue }
            let content = event["content"] as? [String: Any] ?? [:]
            guard !content.isEmpty else { continue } // empty content = left

            // Legacy: memberships[] (empty array = left). Per-device flat content: the content
            // itself is the single membership (has device_id).
            var memberships = (content["memberships"] as? [[String: Any]]) ?? []
            if memberships.isEmpty, content["device_id"] != nil { memberships = [content] }
            guard !memberships.isEmpty else { continue }

            let originServerTs = (event["origin_server_ts"] as? Double) ?? (event["origin_server_ts"] as? Int).map(Double.init)
            let hasActiveMembership = memberships.contains { membership in
                if let expiresTs = (membership["expires_ts"] as? Double) ?? (membership["expires_ts"] as? Int).map(Double.init) {
                    return expiresTs > nowMs
                }
                let createdTs = (membership["created_ts"] as? Double) ?? (membership["created_ts"] as? Int).map(Double.init) ?? originServerTs
                if let createdTs,
                   let expires = (membership["expires"] as? Double) ?? (membership["expires"] as? Int).map(Double.init) {
                    return createdTs + expires > nowMs
                }
                return true // no expiry info — assume active
            }
            if hasActiveMembership {
                result.insert(sender)
            }
        }
        return result
    }

    /// Send ring notification with proper user_ids and m.relates_to referencing our call.member event.
    /// Web client requires m.relates_to.rel_type="m.reference" + event_id of call.member to show incoming call toast.
    private func sendCallNotification(callMemberEventID: String?) async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId

        // Collect other room members for m.mentions.user_ids
        var otherUserIDs: [String] = []
        if let members = await roomProxy?.members() {
            otherUserIDs = members
                .filter { $0.isActive && $0.userID != userId }
                .map(\.userID)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)

        // Build notification body
        var body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "m.mentions": ["user_ids": otherUserIDs],
            "sender_ts": timestamp,
            "lifetime": 90000,
            "notification_type": "ring"
        ]

        // Add m.relates_to if we have the call.member event_id
        if let eventID = callMemberEventID {
            body["m.relates_to"] = [
                "rel_type": "m.reference",
                "event_id": eventID
            ]
        }

        // Send via REST API
        let txnId = UUID().uuidString
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/send/org.matrix.msc4075.rtc.notification/\(txnId)"

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        guard let requestURL = URL(string: url) else {
            MXLog.error("sTalk NativeCall: invalid notification URL: \(url)")
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            MXLog.info("sTalk NativeCall: Ring notification → \(status) users=\(otherUserIDs.count) ref=\(callMemberEventID ?? "none") resp=\(respBody.prefix(100))")
        } catch {
            MXLog.error("sTalk NativeCall: Ring notification failed: \(error)")
        }
    }

    // MARK: - Stop

    /// STMOB-126: периодический rebroadcast текущего ключа пока идёт E2EE-звонок.
    /// Самозалечивает key-desync, возникший когда Matrix to-device отправка
    /// ключа отвалилась на деградировавшем канале (без смены интерфейса / без
    /// reconnect транспорта — то, что не ловят on-event триггеры).
    private func startKeyRebroadcastTimer() {
        keyRebroadcastTimer?.cancel()
        guard isEncrypted else { return }
        keyRebroadcastTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keyRebroadcastInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.sessionState == .connected else { continue }
                await self.rebroadcastCurrentEncryptionKey()
            }
        }
    }

    /// STMOB-269: сторож «ключ не пришёл». Запускается при первом появлении
    /// удалённого участника и живёт до конца звонка. Ничего не чинит — только
    /// называет вслух то, что раньше было видно лишь по чёрному экрану.
    private func startKeyGapWatchdogIfNeeded() {
        guard isEncrypted, keyGapWatchdog == nil else { return }
        keyGapWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keyGapCheckInterval)
                guard let self, !Task.isCancelled else { return }
                self.reportMissingKeys()
            }
        }
    }

    private func reportMissingKeys() {
        guard sessionState == .connected else { return }
        let ourIdentity = "\(userId):\(deviceId)"
        let now = Date()

        for identity in knownRemoteIdentities.sorted() where identity != ourIdentity {
            guard participantKeys[identity] != true,
                  let seenAt = remoteFirstSeenAt[identity] else { continue }

            let waiting = now.timeIntervalSince(seenAt)
            let stage = keyGapReported[identity] ?? 0

            if stage < 1, waiting >= Self.keyGapWarnAfter {
                keyGapReported[identity] = 1
                DiagLog.write("E2EE", "КЛЮЧА НЕТ: от \(identity) ключ не пришёл за \(Int(waiting))с — его видео будет чёрным")
                MXLog.warning("sTalk NativeCall E2EE: no key from \(identity) after \(Int(waiting))s")
            } else if stage < 2, waiting >= Self.keyGapEscalateAfter {
                keyGapReported[identity] = 2
                let received = knownRemoteIdentities
                    .filter { $0 != ourIdentity && participantKeys[$0] == true }
                    .sorted()
                DiagLog.write("E2EE", """
                КЛЮЧА НЕТ \(Int(waiting))с от \(identity). Похоже на расклиненную Olm-сессию \
                у отправителя: он шлёт, мы не расшифровываем, ошибка остаётся внутри SDK. \
                Лечится пересозданием сессии с ЕГО стороны. Ключ за этот звонок получен от: \
                \(received.isEmpty ? "никого" : received.joined(separator: ", "))
                """)
            }
        }
    }

    /// Итог по ключам на конец звонка — чтобы ответ на вопрос «ключи-то пришли?»
    /// был в логе всегда, а не только когда сторож успел сработать.
    private func logCallKeySummary() {
        guard isEncrypted else { return }
        let ourIdentity = "\(userId):\(deviceId)"
        let remotes = remoteFirstSeenAt.keys.filter { $0 != ourIdentity }.sorted()
        guard !remotes.isEmpty else { return }

        let missing = remotes.filter { participantKeys[$0] != true }
        let summary = "итог по ключам: участников \(remotes.count), ключ получен от \(remotes.count - missing.count)"
        DiagLog.write("E2EE", missing.isEmpty ? summary : summary + ", НЕ получен от: " + missing.joined(separator: ", "))
    }

    /// Про рассинхрон «ключ есть, шифрования нет» сообщаем один раз за звонок.
    private var didWarnAboutKeyWithoutEncryption = false

    /// Мы намеренно выходим из звонка — сверщику участия трогать состояние нельзя.
    private var isLeavingCall = false
    /// Когда намерение объявлено. Нужно, чтобы отличить нормальный выход (доли
    /// секунды до `stop()`) от застрявшего (STALK-901: девятнадцать минут).
    private var leaveIntentAt: Date?
    /// Сколько ждём завершения выхода, прежде чем считать его не состоявшимся.
    /// Заметно больше нормальных 0.5-1 с, но много меньше длины разговора.
    private static let leaveIntentGrace: TimeInterval = 20

    /// Объявить намерение выйти из звонка. Вызывается ПЕРВЫМ действием завершения,
    /// до любой очистки состояния: UI закрывается сразу, а `tearDownCallSession`
    /// снимает наше `m.call.member` в фоне — и до `stop()` проходит ~0.5-1с
    /// (лог 149, 17:42:27.2 очистка → 17:42:28.0 stop). В этом окне эхо нашего же
    /// удаления читалось сверщиком как «нас сняли» и он возвращал участие обратно
    /// вместе с новым отложенным выходом: для собеседника мы висели в звонке ещё
    /// до 30 секунд после того, как положили трубку.
    func beginLeaving() {
        guard !isLeavingCall else { return }
        isLeavingCall = true
        leaveIntentAt = Date()
        DiagLog.write("Call", "leave intent: сверщик участия отключён")
    }

    /// Отменить объявленное намерение: выход НЕ состоялся, а звонок продолжается.
    ///
    /// STMOB-284 (STALK-901): признак ставился и там, где человек ничего не нажимал — снос
    /// экрана звонка и «подмена звонка», — а снять его было нечем: обратно в
    /// `false` он не возвращался нигде. Уборку обрывало по таймауту на плохой
    /// связи после того, как участие уже снято, но до того, как заглушено медиа,
    /// и сверщик оставался выключен до конца сессии. На проде это дало человека,
    /// которого слышали 19 минут, а в списке участников не было.
    func cancelLeaving(reason: String) {
        guard isLeavingCall, sessionState == .connected else { return }
        isLeavingCall = false
        leaveIntentAt = nil
        DiagLog.write("Call", "leave intent СНЯТ (\(reason)) — выход не состоялся, сверщик снова включён")
        Task { [weak self] in await self?.reconcileCallMembership(trigger: "leave-aborted", force: true) }
    }

    /// Страховка от намерения, которое некому снять.
    ///
    /// Явную отмену зовут те места, что сами знают об обрыве уборки. Но путь,
    /// приведший к инциденту на проде, по логам восстановить не удалось, поэтому
    /// одного явного вызова мало: если намерение висит дольше отведённого срока,
    /// а сессия при этом жива и медиа идёт — выход не состоялся, чем бы он ни был
    /// вызван. Возвращаем себя в звонок сами.
    private func healStuckLeaveIntentIfNeeded() {
        guard isLeavingCall, sessionState == .connected, let since = leaveIntentAt else { return }
        guard Date().timeIntervalSince(since) > Self.leaveIntentGrace else { return }
        guard liveKitRoomManager.connectionState != .disconnected else { return }
        cancelLeaving(reason: "медиа живо \(Int(Date().timeIntervalSince(since)))с спустя")
    }

    func stop() async {
        MXLog.info("sTalk NativeCall: Stopping session")
        isLeavingCall = true
        sessionState = .disconnecting

        heartbeatTask?.cancel()
        heartbeatTask = nil
        keyRebroadcastTimer?.cancel()
        keyRebroadcastTimer = nil
        logCallKeySummary()
        keyGapWatchdog?.cancel()
        keyGapWatchdog = nil
        stopNetworkMonitor()

        // STMOB-101 v3: remove foreground observer (rebroadcast loop удалён)
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }

        // STMOB-284: СНАЧАЛА рвём медиа, и только потом объявляем выход.
        //
        // Раньше порядок был обратный, и между двумя шагами стоял сетевой запрос.
        // На плохой связи он растягивается или не проходит вовсе — и всё это время
        // человека уже нет в списке участников, но его слышно, потому что LiveKit
        // ещё публикует. Это худший из возможных исходов: собеседники разговаривают
        // с тем, кого «нет».
        //
        // В новом порядке такого состояния не существует: сперва замолкаем, потом
        // исчезаем. Если сеть отвалится между шагами и объявить выход не удастся,
        // серверная отсрочка (30 с) снимет участие сама — уже при мёртвом медиа,
        // то есть безопасно.
        await liveKitRoomManager.disconnect()
        await sendLeaveViaREST()

        cancellables.removeAll()
        sessionState = .disconnected
        MXLog.info("sTalk NativeCall: Session stopped")
    }

    private func sendLeaveViaREST() async {
        // STMOB-211: штатный выход — отменяем серверный отложенный leave и шлём обычный.
        await cancelDelayedLeave()

        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        for eventType in ["org.matrix.msc3401.call.member"] {
            let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
            let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)"

            // Empty content = leave
            let body: [String: Any] = [:]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { continue }

            guard let requestURL = URL(string: url) else {
                MXLog.error("sTalk NativeCall: invalid leave URL: \(url)")
                continue
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            do {
                let (_, response) = try await restSession.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                MXLog.info("sTalk NativeCall: REST leave \(eventType) → \(status)")
            } catch {
                MXLog.error("sTalk NativeCall: REST leave failed: \(error)")
            }
        }
    }

    // MARK: - MSC4140 Delayed Leave (STMOB-211)

    /// Delay until the server auto-sends our leave if we stop refreshing (app killed/crashed).
    /// STMOB-264 (dp): 30с вместо 20с. При рестартах раз в 8с это запас в три
    /// пропущенных тика — короткий провал связи больше не приводит к тому, что
    /// сервер снимает наше membership и мы становимся невидимы для собеседника
    /// (треки идут, а сопоставить их с участником звонка не с чем).
    private static let delayedLeaveMs = 30000
    /// Refresh cadence — well under `delayedLeaveMs`, so one missed tick isn't fatal.
    private static let delayedLeaveRestartSeconds: UInt64 = 8

    /// STMOB-211: schedule a server-side delayed leave (MSC4140). If the app dies
    /// without a clean hangup the homeserver sends the empty call.member state for us
    /// after `delayedLeaveMs` — no more stuck memberships re-ringing participants for
    /// hours (phantom "silent" calls). Servers without MSC4140 → graceful skip,
    /// legacy expires-only behavior stays.
    private func scheduleDelayedLeave() async {
        let encodedRoom = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matrixRoomId
        let stateKey = "_\(userId)_\(deviceId)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey
        let eventType = "org.matrix.msc3401.call.member"
        let encodedType = eventType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventType
        let url = "\(homeserverURL)/_matrix/client/v3/rooms/\(encodedRoom)/state/\(encodedType)/\(encodedStateKey)?org.matrix.msc4140.delay=\(Self.delayedLeaveMs)"

        guard let requestURL = URL(string: url) else {
            MXLog.error("sTalk NativeCall: invalid delayed-leave URL: \(url)")
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delayID = json["delay_id"] as? String else {
                DiagLog.write("Call", "delayed leave NOT scheduled (status=\(status)) — MSC4140 unsupported?")
                return
            }
            delayedLeaveID = delayID
            DiagLog.write("Call", "delayed leave scheduled delay_id=\(delayID) delay=\(Self.delayedLeaveMs)ms")
            startDelayedLeaveHeartbeat(delayID: delayID)
        } catch {
            DiagLog.write("Call", "delayed leave schedule FAILED: \(error.localizedDescription)")
        }
    }

    private func startDelayedLeaveHeartbeat(delayID: String) {
        delayedLeaveHeartbeat?.cancel()
        delayedLeaveHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.delayedLeaveRestartSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                // STMOB-284: единственный периодический таск за весь звонок, поэтому
                // страховка от застрявшего намерения выйти живёт здесь.
                self.healStuckLeaveIntentIfNeeded()
                let status = await self.delayedLeaveAction("restart", delayID: delayID)
                guard !Task.isCancelled else { return }
                // Сетевые ошибки во время обрыва — это НЕ повод что-то делать: delay
                // ещё жив на сервере, продолжаем стучаться.
                guard status == 404 else { continue }
                // STMOB-264: 404 = отложенный leave уже СРАБОТАЛ, сервер снял наше
                // membership. Для всех остальных нас в звонке больше нет: собеседник
                // получает наши треки из SFU, но не может сопоставить их с участником
                // звонка и не показывает ни видео, ни звук — при живом медиа. Именно
                // так выглядит «веб перестал видеть iOS после переподключения».
                //
                // Это АВТОРИТЕТНЫЙ признак, сильнее нашего кэша участников: кэш во
                // время обрыва как раз и протух (событие о снятии могло не дойти).
                // Поэтому форсим сверку, а heartbeat НЕ прерываем — иначе, если сверка
                // не пройдёт (сети ещё нет), периодического детектора не останется
                // вовсе. Петля умрёт сама, когда scheduleDelayedLeave заведёт новую.
                Task { [weak self] in await self?.reconcileCallMembership(trigger: "delayed-leave-404", force: true) }
            }
        }
    }

    /// Приводит состояние комнаты к инварианту «пока мы в звонке — наше
    /// `m.call.member` опубликовано».
    ///
    /// Это НЕ обработчик конкретной ошибки, а сверка желаемого с фактическим:
    /// вызывается из всех мест, где мы можем узнать о расхождении (событие о нашем
    /// участии из комнаты, 404 от отложенного leave, завершённое переподключение).
    /// Поэтому чинится любой способ потерять участие, а не только сработавший
    /// delayed leave: ресет состояния, редакция события, рестарт сервера.
    ///
    /// Идемпотентна: если участие на месте — ничего не делает.
    private func reconcileCallMembership(trigger: String, force: Bool = false) async {
        // STMOB-261 (лог 148): при завершении звонка мы САМИ убираем своё участие
        // (clearCallMember), а сверщик расценивал это как «нас сняли» и возвращал
        // участие обратно вместе с новым отложенным выходом — для остальных юзер
        // оставался в звонке до 30с после того, как положил трубку.
        // sessionState на этот момент ещё .connected: endCall закрывает UI сразу, а
        // очистка доигрывает в фоне. Поэтому нужен явный признак «мы уходим».
        guard !isLeavingCall else {
            DiagLog.write("Call", "membership recon пропущен — звонок завершается")
            return
        }
        guard sessionState == .connected else { return }
        guard !isReconcilingMembership else { return }
        if let last = lastMembershipReconcileAt, Date().timeIntervalSince(last) < 5 {
            return
        }
        isReconcilingMembership = true
        defer { isReconcilingMembership = false }

        let selfKey = "\(userId)|\(deviceId)"
        if force {
            // Сервер сказал прямо, что участия нет — кэш тут не судья.
            callMemberDeviceExpiry.removeValue(forKey: selfKey)
        }
        // Факт: есть ли наше участие в комнате прямо сейчас.
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let expiry = callMemberDeviceExpiry[selfKey], expiry == 0 || expiry > nowMs {
            return // инвариант соблюдён
        }

        guard membershipReconcileAttempts < Self.maxMembershipReconcileAttempts else {
            DiagLog.write("Call", "membership: лимит восстановлений исчерпан (\(membershipReconcileAttempts)) — не долблю сервер")
            return
        }
        lastMembershipReconcileAt = Date()
        membershipReconcileAttempts += 1
        DiagLog.write("Call", "membership recon #\(membershipReconcileAttempts) (\(trigger)) → переотправляю join")

        // Старый отложенный leave гасим ЯВНО, а не забываем: переотправка участия его
        // не отменяет, и уцелевший таймер снял бы нас снова через 30с. На уже
        // сработавшем delay это безобидный 404.
        await cancelDelayedLeave()
        guard let eventID = await sendJoinViaREST() else {
            // Сеть ещё не вернулась — следующий триггер (heartbeat/событие/реконнект)
            // попробует снова, отдельной петли ретраев для этого не нужно.
            DiagLog.write("Call", "membership recon: join не прошёл, ждём следующего триггера")
            lastMembershipReconcileAt = nil
            membershipReconcileAttempts -= 1
            return
        }
        // Звонок мог завершиться, пока шёл join (до 15с на плохой сети): без этой
        // проверки мы бы завели новый серверный таймер и heartbeat уже после выхода.
        guard sessionState == .connected else {
            DiagLog.write("Call", "membership recon: звонок завершился во время join — откатываю")
            await cancelDelayedLeave()
            return
        }
        callMemberEventID = eventID
        callMemberDeviceExpiry[selfKey] = 0
        DiagLog.write("Call", "membership восстановлено, event=\(eventID)")
        await scheduleDelayedLeave()
        // Для собеседника мы теперь «новый участник» — ключ надо раздать заново.
        if isEncrypted, ourEncryptionKey != nil {
            await rebroadcastCurrentEncryptionKey()
        }
    }

    private var lastMembershipReconcileAt: Date?
    private var isReconcilingMembership = false
    private var membershipReconcileAttempts = 0
    /// Потолок на звонок: если участие снимают снова и снова, это уже не наш обрыв,
    /// а что-то на сервере — молчим в лог, а не устраиваем шторм state-событий.
    private static let maxMembershipReconcileAttempts = 5

    /// Возвращает HTTP-статус (0 — сетевая ошибка). Именно статус, а не Bool:
    /// 404 («delay уже сработал») и обрыв сети требуют разного поведения.
    @discardableResult
    private func delayedLeaveAction(_ action: String, delayID: String, isRetry: Bool = false) async -> Int {
        let url = "\(homeserverURL)/_matrix/client/unstable/org.matrix.msc4140/delayed_events/\(delayID)"
        guard let requestURL = URL(string: url) else {
            MXLog.error("sTalk NativeCall: invalid delayed-action URL: \(url)")
            return 0
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"action\":\"\(action)\"}".utf8)
        do {
            let (_, response) = try await restSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // STMOB-284: 401 — токен протух посреди разговора. Раньше мы просто
            // продолжали долбиться протухшим и через 30 с сервер снимал участие;
            // в логе 25.08 это три 401 подряд, а потом «join не прошёл».
            // Теперь просим SDK обновить токен и повторяем ОДИН раз.
            if status == 401, !isRetry {
                DiagLog.write("Call", "delayed leave \(action) → 401 — обновляю токен и повторяю")
                await tokenRefresher()
                return await delayedLeaveAction(action, delayID: delayID, isRetry: true)
            }
            if status != 200 {
                // 404 = delay_id больше нет, т.е. сервер УЖЕ выполнил отложенный leave
                // и снял наше membership (STMOB-264).
                let hint = status == 404 ? " (delay уже сработал — membership снято)" : ""
                DiagLog.write("Call", "delayed leave \(action) → \(status)\(hint)")
            }
            return status
        } catch {
            DiagLog.write("Call", "delayed leave \(action) FAILED: \(error.localizedDescription)")
            return 0
        }
    }

    private func cancelDelayedLeave() async {
        delayedLeaveHeartbeat?.cancel()
        delayedLeaveHeartbeat = nil
        if let delayID = delayedLeaveID {
            await delayedLeaveAction("cancel", delayID: delayID)
            delayedLeaveID = nil
        }
    }

    // MARK: - Message Processing

    private func processWidgetMessage(_ messageString: String) {
        guard let message = WidgetAPIMessage(jsonString: messageString) else {
            MXLog.info("sTalk NativeCall: Unparseable message: \(messageString.prefix(200))")
            return
        }

        // Log all messages
        MXLog.info("sTalk NativeCall: \(message.api) action=\(message.action) type=\(message.eventType ?? "-") reqId=\(message.requestId)")

        // Process toWidget messages
        if message.api == "toWidget" {
            if message.action == "capabilities" {
                // Driver sent toWidget capabilities request.
                // Response must be toWidget (not fromWidget!) — driver expects toWidget response.
                Task {
                    let response = """
                    {"api":"toWidget","action":"capabilities","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","data":{},"response":{"capabilities":["org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys","org.matrix.msc3819.send.to_device:io.element.call.encryption_keys","org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member","org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member","org.matrix.msc2762.send.delayed_event","org.matrix.msc2762.update.delayed_event","io.element.requires_client"]}}
                    """
                    MXLog.info("sTalk NativeCall: Sending toWidget response: \(String(response.prefix(200)))")
                    let result = await widgetDriver.handleMessage(response)
                    MXLog.info("sTalk NativeCall: toWidget response result=\(result)")
                    // STMOB-256: негоциация capabilities завершена — снимаем событийное
                    // ожидание в start() (вместо глухого sleep(5s)).
                    self.capabilitiesNegotiated = true
                    DiagLog.write("CallPerf", "capabilities negotiated @\(self.elapsedMs())ms")
                }
            } else {
                Task {
                    let ack = """
                    {"api":"fromWidget","action":"\(message.action)","widgetId":"\(message.widgetId)","requestId":"\(message.requestId)","response":{}}
                    """
                    await widgetDriver.handleMessage(ack)
                }
            }

            switch message.action {
            case "send_event":
                handleSendEvent(message)
            case "send_to_device":
                if messageString.contains("encryption_keys") {
                    handleEncryptionKeys(message)
                }
            default:
                break
            }
        }

        // E2EE keys: parse ONLY incoming (toWidget) messages.
        // STMOB-246: previously this fired for ANY direction, so our OWN outgoing
        // fromWidget relays (native-key-* send_to_device with messages.*.* shape, and
        // native-roomkey-* send_event without a `sender`) were re-fed into the incoming
        // parser → 6× "EXTRACT FAILED" noise per NSE log. Those are our own sends, not
        // remote keys; real remote keys arrive as toWidget send_event (content.keys[] +
        // sender) and still parse. Gating to toWidget removes the noise, no behaviour change.
        if message.api == "toWidget", messageString.contains("encryption_keys") {
            // ⚠️ БЕЗОПАСНОСТЬ: НЕ логировать сырое сообщение — оно содержит base64
            // E2EE-ключ удалённых участников, а MXLog/DiagLog персистятся и DiagLog
            // шарится тестерами. Диагностическая ценность (факт прихода key-события
            // для верификации fan-out Molly, STALK-303) сохраняется по api/action/длине;
            // разбор конкретного ключа — в handleEncryptionKeys (там keyLen, не ключ).
            MXLog.info("sTalk NativeCall E2EE: incoming encryption_keys message (len=\(messageString.count))")
            DiagLog.write("E2EE", "incoming widget message api=\(message.api) action=\(message.action) len=\(messageString.count)")
            handleEncryptionKeys(message)
        }
    }

    // MARK: - Event Handlers

    private func handleSendEvent(_ message: WidgetAPIMessage) {
        guard let eventType = message.eventType else { return }

        switch eventType {
        case "org.matrix.msc3401.call.member", "m.call.member":
            handleCallMemberEvent(message)
        default:
            break
        }
    }

    /// STMOB-246/247: update the active call-membership device-set from an incoming call.member
    /// state event, and re-advertise our key when a NEW device appears (membership-settled — robust
    /// to fast re-join of the SAME device that the LiveKit identity-diff misses). Defensive field
    /// parsing; exact shape validated on the STALK-506 stand.
    private func updateCallMembers(from message: WidgetAPIMessage) {
        guard let content = message.callMemberContent else { return }
        let sender = (message.data?["sender"] as? String) ?? ""
        guard sender.hasPrefix("@") else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000

        // STMOB-264: state_key вида `_@user:server_DEVICE_m.call` говорит, о ЧЬЁМ
        // устройстве событие. Без него мы вычищали ВСЕ устройства отправителя по
        // одному событию: второе устройство того же аккаунта затирало запись первого.
        // Раньше это стоило лишь лишней рассылки ключей, а с инвариантом ниже
        // приводило бы к ложному «нас сняли» и переотправке участия.
        let stateKey = (message.data?["state_key"] as? String) ?? ""
        let deviceFromStateKey: String? = {
            let prefix = "_\(sender)_"
            let suffix = "_m.call"
            guard stateKey.hasPrefix(prefix), stateKey.hasSuffix(suffix) else { return nil }
            let device = String(stateKey.dropFirst(prefix.count).dropLast(suffix.count))
            return device.isEmpty ? nil : device
        }()
        let beforeForSender: Set<String> = {
            if let deviceFromStateKey {
                let key = "\(sender)|\(deviceFromStateKey)"
                return callMemberDeviceExpiry[key] != nil ? [key] : []
            }
            return Set(callMemberDeviceExpiry.keys.filter { $0.hasPrefix("\(sender)|") })
        }()

        // A call.member event carries this user's current memberships. memberships[] (legacy) or a
        // single-membership content (per-device model). Empty content {} → user left.
        var rawMemberships = (content["memberships"] as? [[String: Any]]) ?? []
        if rawMemberships.isEmpty, content["device_id"] != nil { rawMemberships = [content] }

        var senderKeysNow = Set<String>()
        for m in rawMemberships {
            guard let device = m["device_id"] as? String, !device.isEmpty else { continue }
            let expiry: Double = {
                if let ts = (m["expires_ts"] as? Double) ?? (m["expires_ts"] as? Int).map(Double.init) { return ts }
                let created = (m["created_ts"] as? Double) ?? (m["created_ts"] as? Int).map(Double.init)
                let rel = (m["expires"] as? Double) ?? (m["expires"] as? Int).map(Double.init)
                if let created, let rel { return created + rel }
                return 0 // unknown expiry → treat active
            }()
            let key = "\(sender)|\(device)"
            senderKeysNow.insert(key)
            callMemberDeviceExpiry[key] = expiry
        }
        for stale in beforeForSender.subtracting(senderKeysNow) {
            callMemberDeviceExpiry.removeValue(forKey: stale)
        }
        callMemberDeviceExpiry = callMemberDeviceExpiry.filter { $0.value == 0 || $0.value > nowMs }

        let selfKey = "\(userId)|\(deviceId)"
        DiagLog.write("E2EE", "call.member from \(sender): active recipients=\(callMemberDeviceExpiry.keys.filter { $0 != selfKey }.count)")

        // STMOB-264: ИНВАРИАНТ — пока сессия в звонке, наше membership обязано быть в
        // состоянии комнаты. Здесь единственный авторитетный источник правды: событие
        // о НАШЕМ же участии. Если оно говорит, что нас нет, значит нас сняли — неважно
        // кем и почему (сработал отложенный leave MSC4140, ресет состояния, редакция
        // события, рестарт сервера). Медиа при этом продолжает идти, и снаружи это
        // выглядит как «собеседник перестал видеть iOS» — треки приходят, а
        // сопоставить их с участником звонка не с чем.
        let isAboutOurDevice = sender == userId && (deviceFromStateKey == nil || deviceFromStateKey == deviceId)
        if isAboutOurDevice, !senderKeysNow.contains(selfKey), sessionState == .connected, !isLeavingCall {
            DiagLog.write("Call", "membership: наше участие пропало из состояния комнаты → восстанавливаю")
            Task { [weak self] in await self?.reconcileCallMembership(trigger: "state-event") }
        }

        // STMOB-247: re-advertise on membership-settled (new device of any peer appeared).
        let newDevices = senderKeysNow.subtracting(beforeForSender).filter { $0 != selfKey }
        if !newDevices.isEmpty, sessionState == .connected, isEncrypted, ourEncryptionKey != nil {
            DiagLog.write("E2EE", "membership-settled new=\(newDevices) → re-advertise key")
            Task { [weak self] in await self?.rebroadcastCurrentEncryptionKey() }
        }
    }

    /// Записать участников, известных от SFU, как получателей ключа.
    ///
    /// Список получателей строился ТОЛЬКО из событий участия, приходящих через виджет,
    /// и только из НОВЫХ: при входе в уже идущий звонок событие собеседника лежит в
    /// состоянии комнаты с прошлого момента и заново не приходит. Отсюда «участника
    /// вижу, получателей ноль» — две соседние строки лога с разницей в 19 мс.
    ///
    /// Последствие было не косметическим: не имея кому отправить адресно, мы слали ключ
    /// комнатным событием, а веб, получив такой ключ, у себя навсегда выключал адресный
    /// канал и дальше рассылал ключи только комнатными событиями — которых мы не
    /// принимаем. Итог: чёрный экран у обеих сторон (разбор Molly, 28.07).
    ///
    /// Идентификатор участника в SFU имеет вид `@user:server:DEVICE` — этого достаточно,
    /// и это авторитетнее состояния комнаты: человек прямо сейчас в звонке.
    private func registerRecipients(fromLiveKitIdentities identities: Set<String>) {
        var added: [String] = []
        for identity in identities {
            let parts = identity.split(separator: ":").map(String.init)
            // `@user`, `server`, `DEVICE` — устройство отделено последним двоеточием.
            guard parts.count >= 3, identity.hasPrefix("@"),
                  let device = parts.last, !device.isEmpty else { continue }
            let user = identity.dropLast(device.count + 1)
            let key = "\(user)|\(device)"
            guard key != "\(userId)|\(deviceId)", callMemberDeviceExpiry[key] == nil else { continue }
            callMemberDeviceExpiry[key] = 0 // 0 = активен, срок неизвестен
            added.append(key)
        }
        guard !added.isEmpty else { return }
        DiagLog.write("E2EE", "получатели из SFU: \(added.joined(separator: ", "))")
    }

    /// Active call.member recipients (userId, deviceId) excluding self — source for addressed to-device.
    private func activeMemberRecipients() -> [(user: String, device: String)] {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let selfKey = "\(userId)|\(deviceId)"
        return callMemberDeviceExpiry.compactMap { key, expiry -> (user: String, device: String)? in
            guard key != selfKey, expiry == 0 || expiry > nowMs else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (user: parts[0], device: parts[1])
        }
    }

    private func handleCallMemberEvent(_ message: WidgetAPIMessage) {
        updateCallMembers(from: message)
        guard let content = message.callMemberContent else { return }

        // Extract LiveKit SFU URL from focus config
        var sfuURL: String?
        var roomAlias: String?

        // Try memberships → foci_preferred
        if let memberships = content["memberships"] as? [[String: Any]] {
            for membership in memberships {
                if let foci = membership["foci_preferred"] as? [[String: Any]] {
                    for focus in foci where (focus["type"] as? String) == "livekit" {
                        sfuURL = focus["livekit_service_url"] as? String
                        roomAlias = focus["livekit_alias"] as? String
                    }
                }
                if let foci = membership["foci_active"] as? [[String: Any]] {
                    for focus in foci where (focus["type"] as? String) == "livekit" {
                        sfuURL = sfuURL ?? (focus["livekit_service_url"] as? String)
                        roomAlias = roomAlias ?? (focus["livekit_alias"] as? String)
                    }
                }
            }
        }

        // Try direct focus_active
        if sfuURL == nil, let focus = content["focus_active"] as? [String: Any],
           (focus["type"] as? String) == "livekit" {
            sfuURL = focus["livekit_service_url"] as? String
            roomAlias = focus["livekit_alias"] as? String
        }

        guard let url = sfuURL else { return }

        MXLog.info("sTalk NativeCall: LiveKit focus — URL=\(url), alias=\(roomAlias ?? "nil")")
        livekitBaseURL = url

        // `url` here is the lk-jwt-service advertised by the room's focus (per-domain). Fetch
        // creds from it (correct SFU wss + valid per-install JWT) instead of generating locally.
        if !credentialsReceived {
            resolvedJWTServiceURL = url
            // Room = the focus's livekit_alias (matrix roomId), same as Web sends to /sfu/get.
            let roomName = roomAlias ?? matrixRoomId
            Task {
                guard let creds = await fetchLiveKitCredentials(jwtServiceURL: url, roomName: roomName) else {
                    MXLog.error("sTalk NativeCall: Failed to fetch LiveKit creds from focus \(url)")
                    return
                }
                MXLog.info("sTalk NativeCall: connecting via focus service \(url) → sfu=\(creds.url)")
                await connectToLiveKit(url: creds.url, token: creds.jwt)
            }
        }
    }

    private func handleEncryptionKeys(_ message: WidgetAPIMessage) {
        guard let keyInfo = message.extractEncryptionKeys(), !keyInfo.participantId.isEmpty else {
            // STMOB-152 build 176: incoming event пришёл но extract failed —
            // вероятно payload format mismatch (array vs object keys field).
            DiagLog.write("E2EE", "handleEncryptionKeys EXTRACT FAILED action=\(message.action)")
            return
        }

        MXLog.info("sTalk NativeCall: E2EE key from \(keyInfo.participantId) index=\(keyInfo.index)")
        // STMOB-152 build 176: каждый успешно parsed incoming key —
        // подтверждение что Molly fan-out (STALK-303) работает.
        DiagLog.write("E2EE", "incoming key parsed from=\(keyInfo.participantId) index=\(keyInfo.index) keyLen=\(keyInfo.key.count)")

        // Рассинхрон сторон: комната не шифрована (мы публикуем открытые кадры), а
        // собеседник прислал ключ — значит он кадры ШИФРУЕТ. Соединение при этом
        // полностью «зелёное», и картинки нет ни у кого. Снаружи неотличимо от
        // поломки камеры, поэтому говорим об этом прямо и один раз за звонок.
        if !isEncrypted, !didWarnAboutKeyWithoutEncryption {
            didWarnAboutKeyWithoutEncryption = true
            MXLog.error("sTalk NativeCall: peer sent an E2EE key in a non-encrypted room — media will not decode")
            DiagLog.write("E2EE", "РАССИНХРОН: комната без шифрования, а от \(keyInfo.participantId) пришёл ключ — собеседник шифрует, мы нет")
        }

        // STMOB-152 build 177: normalize base64url → standard padded base64.
        // Guest meet-app использует Node `crypto.randomBytes(16).toString("base64url")`
        // (meet-api-index.js:348) — это URL-safe base64 БЕЗ padding (RFC 4648 §5).
        // 16 bytes → 22 chars, '-' вместо '+', '_' вместо '/'.
        //
        // Swift Data(base64Encoded:) strict — требует standard alphabet +
        // правильное padding. Без normalization returns nil → silent fallback
        // на else branch → keyProvider.setKey с base64 STRING вместо raw bytes
        // → LiveKit SFrame decrypt fails → черный экран для guest video.
        //
        // Лог 85 dp.bondar (01:28): guest key "IV9NRa02nGPGQwxjMlAnkA" (22 chars)
        // vs iOS local "gKcCiyjfzfuOCZN76ObkVg==" (24 chars). Random key мог бы
        // содержать '-' / '_' → ещё один уровень failure.
        let paddedKey: String = {
            // base64url → standard base64
            var normalized = keyInfo.key
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            // padding до multiple of 4
            let mod = normalized.count % 4
            if mod != 0 {
                normalized += String(repeating: "=", count: 4 - mod)
            }
            return normalized
        }()

        // Decode base64 → raw bytes
        if let rawKey = Data(base64Encoded: paddedKey) {
            // STMOB-77/201: set ONLY the announced slot. The old `0...index` backfill
            // overwrote previous slots with the NEW key — on web key rotation
            // (join/leave bumps the index) this destroyed the still-in-use old key,
            // in-flight frames stopped decrypting and remote video went black.
            // Backfilling can't help missed keys anyway (they were different keys).
            setRawKeyInProvider(keyProvider, key: rawKey, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
            DiagLog.write("E2EE", "incoming key DECODED rawBytes=\(rawKey.count) for \(keyInfo.participantId) index=\(keyInfo.index)")
        } else {
            DiagLog.write("E2EE", "incoming key BASE64 DECODE FAILED (even padded keyLen=\(paddedKey.count)) for \(keyInfo.participantId)")
            keyProvider.setKey(key: keyInfo.key, participantId: keyInfo.participantId, index: Int32(keyInfo.index))
        }
        participantKeys[keyInfo.participantId] = true

        if let participant = pendingParticipants.removeValue(forKey: keyInfo.participantId) {
            subscribeToAllTracks(of: participant)
        }
    }

    private func handleWidgetAction(_ action: ElementCallWidgetDriverAction) {
        switch action {
        case .callEnded:
            // Ignore widget driver hangup — it times out because we don't do delayed_leave.
            // Native SDK manages call lifecycle independently.
            MXLog.info("sTalk NativeCall: Widget driver hangup IGNORED — native SDK manages lifecycle")
        case .mediaStateChanged(let audioEnabled, let videoEnabled):
            MXLog.info("sTalk NativeCall: Media state — audio=\(audioEnabled), video=\(videoEnabled)")
        }
    }

    // MARK: - LiveKit Connection

    private func connectToLiveKit(url: String, token: String) async {
        guard !credentialsReceived else { return }
        credentialsReceived = true
        sessionState = .connecting

        do {
            if isEncrypted {
                // Generate our E2EE key BEFORE connect
                if ourEncryptionKey == nil {
                    // Generate 16 random bytes, BUT encode as ASCII-safe string
                    // so that .utf8 encoding gives predictable bytes
                    var keyBytes = [UInt8](repeating: 0, count: 32)
                    _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
                    // Use hex string as key — .utf8 gives same bytes, and we send hex to remote
                    ourEncryptionKey = keyBytes.map { String(format: "%02x", $0) }.joined()
                    // But EC expects base64... Send base64 to remote, use same decoded bytes locally
                    let rawData = Data(keyBytes.prefix(16))
                    ourEncryptionKey = rawData.base64EncodedString()
                    ourEncryptionKeyRaw = rawData
                }

                // Race condition safety: sendOurEncryptionKey (fires 3s after start) can set
                // ourEncryptionKey without touching ourEncryptionKeyRaw. Derive raw from base64
                // to keep both in sync before force-unwrapping.
                if ourEncryptionKeyRaw == nil, let key = ourEncryptionKey {
                    ourEncryptionKeyRaw = Data(base64Encoded: key)
                }
                guard let rawKey = ourEncryptionKeyRaw else {
                    MXLog.error("sTalk NativeCall: Cannot resolve raw E2EE key — aborting connect")
                    sessionState = .failed(NativeCallError.noCredentials)
                    return
                }

                let ourIdentity = "\(userId):\(deviceId)"
                setRawKeyInProvider(keyProvider, key: rawKey, participantId: ourIdentity, index: 0)
                MXLog.info("sTalk NativeCall E2EE: Our key set for \(ourIdentity)")

                try await liveKitRoomManager.connectWithE2EE(wsURL: url, token: token, keyProvider: keyProvider, speakerByDefault: false)
            } else {
                try await liveKitRoomManager.connect(wsURL: url, token: token, speakerByDefault: false)
            }

            sessionState = .connected
            roomManager = liveKitRoomManager
            DiagLog.write("CallPerf", "LiveKit CONNECTED @\(elapsedMs())ms — audio/video path up")
            MXLog.info("sTalk NativeCall: Connected to LiveKit")

            // STMOB-126: запускаем периодический rebroadcast ключа (E2EE only).
            startKeyRebroadcastTimer()

            // Publish media
            try? await liveKitRoomManager.setMicrophone(enabled: true)
            if enableCameraOnConnect {
                try? await liveKitRoomManager.setCamera(enabled: true)
            }
            MXLog.info("sTalk NativeCall: mic enabled, camera=\(enableCameraOnConnect)")
            DiagLog.write("Call", "publish media: mic=on camera=\(enableCameraOnConnect ? "on" : "OFF (audio call)")")

            #if targetEnvironment(simulator)
            // DEBUG: через 20s после connect триггерим fake network switch
            // чтобы тестировать Quick reconnect на симуляторе без Mac WiFi toggle.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.debugSimulateNetworkChange()
            }
            #endif

            // Subscribe pending participants
            for (identity, participant) in pendingParticipants where participantKeys[identity] == true || !isEncrypted {
                subscribeToAllTracks(of: participant)
                pendingParticipants.removeValue(forKey: identity)
            }
        } catch {
            MXLog.error("sTalk NativeCall: LiveKit connect failed: \(error)")
            sessionState = .failed(error)
        }
    }

    // MARK: - Participant Management

    // sTalk: handleRemoteParticipantConnected удалён (ревью 2026-07-17) — был мёртвым
    // кодом И ловушкой: при воскрешении вызывал sendOurEncryptionKey() (ротация KID)
    // на каждый JOIN, что противоречит v3-политике (rebroadcast без ротации). Приём
    // участников идёт через $remoteParticipants sink (rebroadcast) + subscribeToAllTracks.

    private func subscribeToAllTracks(of participant: RemoteParticipant) {
        Task {
            for pub in participant.trackPublications.values {
                if let remotePub = pub as? RemoteTrackPublication, !remotePub.isSubscribed {
                    try? await remotePub.set(subscribed: true)
                    MXLog.info("sTalk NativeCall: Subscribed \(String(describing: remotePub.kind)) from \(participant.identity?.stringValue ?? "?")")
                }
            }
        }
    }
}

// MARK: - Errors

enum NativeCallError: Error {
    case widgetDriverFailed
    case noCredentials
    case connectionFailed
}
