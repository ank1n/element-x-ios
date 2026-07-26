//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// Координатор для отслеживания звонков и записи их в локальную историю
class CallHistoryCoordinator {
    private let elementCallService: ElementCallServiceProtocol
    private let localCallHistoryService: LocalCallHistoryServiceProtocol
    private weak var clientProxy: ClientProxyProtocol?

    private var cancellables = Set<AnyCancellable>()

    /// Текущий активный звонок (если есть)
    private var currentCallRoomID: String?
    private var currentCallDirection: LocalCallHistoryItem.CallDirection = .outgoing
    private var pendingIncomingCall = false

    init(elementCallService: ElementCallServiceProtocol,
         localCallHistoryService: LocalCallHistoryServiceProtocol) {
        self.elementCallService = elementCallService
        self.localCallHistoryService = localCallHistoryService

        setupSubscriptions()
    }

    func setClientProxy(_ clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
        // Scope call history to this account so entries from other accounts/servers don't leak in.
        localCallHistoryService.setUserID(clientProxy.userID)
    }

    private func setupSubscriptions() {
        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.handleCallAction(action)
            }
            .store(in: &cancellables)
    }

    private func handleCallAction(_ action: ElementCallServiceAction) {
        switch action {
        case .receivedIncomingCallRequest:
            // Помечаем что следующий startCall будет входящим
            pendingIncomingCall = true
            MXLog.info("📞 CallHistory: Received incoming call request")

        case .startCall(let roomID):
            // Предотвращаем дублирование - если уже есть активный звонок в этой комнате, игнорируем
            if currentCallRoomID == roomID {
                MXLog.info("📞 CallHistory: Ignoring duplicate startCall for room \(roomID)")
                pendingIncomingCall = false
                return
            }

            // Запись о состоявшемся звонке — и входящем, и исходящем — создаёт
            // UserSessionFlowCoordinator.presentCallScreen(), он же знает направление
            // (isJoiningExistingCall) и он же её закрывает на .dismiss. Здесь только
            // помечаем, что звонок с экраном идёт: чтобы не завести на него дубль
            // «пропущенного» (раньше запись создавали оба места → каждый принятый
            // входящий звонок попадал в историю дважды: «входящий» + «исходящий»).
            currentCallDirection = pendingIncomingCall ? .incoming : .outgoing
            pendingIncomingCall = false
            currentCallRoomID = roomID

            MXLog.info("📞 CallHistory: Call on screen tracked (\(currentCallDirection), entry managed by UserSessionFlowCoordinator)")

        case .endCall(let roomID):
            guard currentCallRoomID == roomID else {
                MXLog.warning("📞 CallHistory: End call for unknown room \(roomID)")
                return
            }

            // Запись закрывает UserSessionFlowCoordinator на .dismiss — здесь только
            // снимаем метку активного звонка, чтобы поздний missedCall снова стал валиден.
            MXLog.info("📞 CallHistory: Call ended (entry managed by UserSessionFlowCoordinator)")
            currentCallRoomID = nil

        case .missedCall(let roomID):
            // Пропущенный входящий звонок
            handleMissedCall(roomID: roomID)

        case .setAudioEnabled:
            // Игнорируем изменения аудио
            break
        }
    }

    private func enrichCallInfo(callID: String, roomID: String) async {
        guard let clientProxy else {
            MXLog.warning("📞 CallHistory: No client proxy to enrich call info")
            return
        }

        guard case .joined(let roomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            MXLog.warning("📞 CallHistory: Could not find room \(roomID)")
            return
        }

        // Получаем имя комнаты из info
        let roomDisplayName = roomProxy.infoPublisher.value.displayName

        // Получаем участников
        var participants: [String: String] = [:]

        if let members = await roomProxy.members() {
            for member in members where member.isActive && member.userID != clientProxy.userID {
                let displayName = member.displayName ?? member.userID
                participants[member.userID] = displayName
            }
        }

        // Обновляем информацию о звонке
        localCallHistoryService.updateCallInfo(id: callID,
                                               roomDisplayName: roomDisplayName,
                                               participants: participants)

        MXLog.info("📞 CallHistory: Enriched call \(callID) with room '\(roomDisplayName ?? "nil")' and \(participants.count) participants")
    }

    /// Обрабатывает пропущенный входящий звонок
    func handleMissedCall(roomID: String) {
        // Звонок с экраном (принятый) пропущенным быть не может — его запись ведёт
        // UserSessionFlowCoordinator. Иначе принятый звонок помечался «пропущенным»,
        // когда фаза «звонит» доносила remoteEnded уже после ответа.
        if currentCallRoomID == roomID {
            MXLog.info("📞 CallHistory: Ignoring missedCall for active on-screen call in \(roomID)")
            return
        }

        // Экрана не было — запись пропущенного целиком наша
        let callID = localCallHistoryService.startCall(roomID: roomID, direction: .incoming)
        localCallHistoryService.endCall(id: callID, missed: true)

        Task {
            await enrichCallInfo(callID: callID, roomID: roomID)
        }

        MXLog.info("📞 CallHistory: Created missed call record: \(callID)")
    }
}
