//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NotificationConstants {
    enum UserInfoKey {
        static let roomIdentifier = "room_id"
        static let eventIdentifier = "event_id"
        static let threadRootEventIdentifier = "thread_root_event_id"
        static let unreadCount = "unread_count"
        static let pusherNotificationClientIdentifier = "pusher_notification_client_identifier"
        static let receiverIdentifier = "receiver_id"
        /// Маркер «пустышки» от NSE: событие распознано как хвост звонка/служебное
        /// и показывать его нечего. Полностью отменить доставку из NSE нельзя,
        /// поэтому приложение по этому ключу не презентует уведомление и убирает
        /// его из Центра уведомлений (STMOB-234, лог 144).
        static let suppressed = "stalk_suppressed"
        /// STMOB-266: баннер «начался звонок», собранный NSE из payload тихого
        /// notify (intent=silent). Это НЕ заглушка: показывать можно и нужно,
        /// а тап ведёт в комнату, где есть кнопка присоединиться.
        static let callNotice = "stalk_call_notice"
    }

    enum Category {
        static let message = "message"
        static let invite = "invite"
        /// Информационный баннер о звонке — без quick-reply, в отличие от message.
        static let call = "call"
    }

    enum Action {
        static let inlineReply = "inline-reply"
    }
}
