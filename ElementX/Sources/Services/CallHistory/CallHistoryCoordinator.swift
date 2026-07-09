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
    private var currentCallID: String?
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

            let direction: LocalCallHistoryItem.CallDirection = pendingIncomingCall ? .incoming : .outgoing
            pendingIncomingCall = false

            // Для исходящих звонков запись уже создана в UserSessionFlowCoordinator.presentCallScreen()
            // Создаём только для входящих звонков (через VoIP push)
            if direction == .outgoing {
                currentCallRoomID = roomID
                currentCallID = nil // Запись управляется UserSessionFlowCoordinator
                MXLog.info("📞 CallHistory: Outgoing call tracked (entry managed by UserSessionFlowCoordinator)")
                return
            }

            // Входящий звонок — создаём запись здесь
            let callID = localCallHistoryService.startCall(roomID: roomID, direction: direction)
            currentCallID = callID
            currentCallRoomID = roomID
            currentCallDirection = direction

            MXLog.info("📞 CallHistory: Started incoming call \(callID), room: \(roomID)")

            // Асинхронно получаем информацию о комнате и участниках
            Task {
                await enrichCallInfo(callID: callID, roomID: roomID)
            }

        case .endCall(let roomID):
            guard currentCallRoomID == roomID else {
                MXLog.warning("📞 CallHistory: End call for unknown room \(roomID)")
                return
            }

            // Завершаем только входящие звонки (у которых есть callID от нас)
            // Исходящие завершаются в UserSessionFlowCoordinator на .dismiss
            if let callID = currentCallID {
                localCallHistoryService.endCall(id: callID, missed: false)
                MXLog.info("📞 CallHistory: Ended incoming call \(callID)")
            } else {
                MXLog.info("📞 CallHistory: Outgoing call ended (managed by UserSessionFlowCoordinator)")
            }

            currentCallID = nil
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
        // Если есть текущий звонок с этим roomID, помечаем его как пропущенный
        if let callID = currentCallID, currentCallRoomID == roomID {
            localCallHistoryService.endCall(id: callID, missed: true)
            currentCallID = nil
            currentCallRoomID = nil
            MXLog.info("📞 CallHistory: Marked call as missed: \(callID)")
        } else {
            // Создаём новую запись для пропущенного звонка
            let callID = localCallHistoryService.startCall(roomID: roomID, direction: .incoming)
            localCallHistoryService.endCall(id: callID, missed: true)

            Task {
                await enrichCallInfo(callID: callID, roomID: roomID)
            }

            MXLog.info("📞 CallHistory: Created missed call record: \(callID)")
        }
    }
}
