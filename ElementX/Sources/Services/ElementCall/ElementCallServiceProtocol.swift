//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

enum ElementCallServiceAction {
    case receivedIncomingCallRequest
    case startCall(roomID: String)
    case endCall(roomID: String)
    case missedCall(roomID: String)
    case setAudioEnabled(_ enabled: Bool, roomID: String)
}

// sourcery: AutoMockable
protocol ElementCallServiceProtocol {
    var actions: AnyPublisher<ElementCallServiceAction, Never> { get }

    var ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> { get }

    /// STMOB-261: комната, чью аудио-сессию активировал CallKit (состояние, не событие).
    var callKitAudioRoomIDPublisher: CurrentValuePublisher<String?, Never> { get }
    /// Комната, для которой система отказала в CallKit-звонке (сессией владеет приложение).
    var callKitUnavailableRoomIDPublisher: CurrentValuePublisher<String?, Never> { get }

    func setClientProxy(_ clientProxy: ClientProxyProtocol)

    func setupCallSession(roomID: String, roomDisplayName: String) async

    func tearDownCallSession()

    func setAudioEnabled(_ enabled: Bool, roomID: String)

    /// Помечает следующий звонок как входящий (используется когда VoIP push недоступен)
    func markNextCallAsIncoming()

    /// STMOB-130: для native LiveKit call path. Публикует roomID в
    /// `ongoingCallRoomIDPublisher` БЕЗ запуска CallKit lifecycle.
    /// Используется RoomScreen чтобы скрыть «Присоединиться» плашку
    /// когда юзер уже участвует в native звонке этой комнаты.
    /// Передать nil при leave call чтобы очистить.
    /// Сообщить системе фактический тип звонка (аудио/видео) после ответа.
    func setCallHasVideo(_ hasVideo: Bool)

    func markNativeCallActive(roomID: String?, displayName: String?)

    /// STMOB-261: собеседник ответил — система начинает отсчёт длительности.
    func reportOutgoingCallConnected()
}

/// STMOB-130 build 153: default no-op чтобы старые Sourcery-generated mocks
/// не падали в compile. Реальный impl в ElementCallService.swift.
extension ElementCallServiceProtocol {
    func markNativeCallActive(roomID: String?, displayName: String? = nil) { }
    func reportOutgoingCallConnected() { }
}
