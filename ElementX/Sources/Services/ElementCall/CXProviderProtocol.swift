//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CallKit

// sourcery: AutoMockable
protocol CXProviderProtocol {
    func setDelegate(_ delegate: CXProviderDelegate?, queue: DispatchQueue?)
    func reportNewIncomingCall(with uuid: UUID, update: CXCallUpdate, completion: @escaping @Sendable (Error?) -> Void)
    func reportCall(with uuid: UUID, endedAt: Date?, reason: CXCallEndedReason)
    /// STMOB-261: исходящий звонок в системе — «соединяемся» и «соединён»
    /// (последнее даёт длительность в «Недавних»).
    func reportOutgoingCall(with UUID: UUID, startedConnectingAt dateStartedConnecting: Date?)
    func reportOutgoingCall(with UUID: UUID, connectedAt dateConnected: Date?)
    /// Обновить карточку уже созданного звонка — нужен исходящему, чтобы в
    /// «Недавних» стояло имя собеседника, а в handle оставался machine-id комнаты
    /// (по нему перезвон из системного «Телефона» находит комнату).
    func reportCall(with UUID: UUID, updated update: CXCallUpdate)
}

extension CXProvider: CXProviderProtocol { }
