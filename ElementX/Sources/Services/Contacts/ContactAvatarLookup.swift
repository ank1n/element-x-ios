//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Аватарка по matrix-идентификатору из уже собранного списка контактов.
///
/// Списку контактов известны и `matrixUserID`, и `avatarURL`, и он кэшируется в
/// `UserDefaults` между запусками. Значит ссылку на аватар можно получить без
/// единого сетевого запроса — и не тянуть профиль ради кружка в 17 точек.
///
/// Нужно там, где на руках только идентификатор: карточка «поделился файлом»
/// (STMOB-275) знает получателей по `user`, аватарок в событии нет.
enum ContactAvatarLookup {
    private static let cacheKeyPrefix = "ru.implica.stalk.cachedContacts."

    /// Разобранный кэш. Держим в памяти, потому что разбор JSON на каждую ячейку
    /// ленты был бы дороже самой отрисовки.
    private static var index: [String: URL] = [:]
    private static var indexedForUserID: String?

    /// Ссылка на аватар, если такой человек есть в контактах.
    ///
    /// `ownUserID` нужен потому, что кэш контактов свой у каждого аккаунта: общий
    /// индекс после смены пользователя показывал бы чужие аватарки.
    ///
    /// Возвращает `nil` молча: для незнакомого пользователя компонент аватара сам
    /// нарисует букву на цветном фоне, и это правильный вид, а не ошибка.
    static func avatarURL(for matrixUserID: String, ownUserID: String) -> URL? {
        if indexedForUserID != ownUserID {
            rebuildIndex(ownUserID: ownUserID)
        }
        return index[matrixUserID]
    }

    /// Сбросить разбор — например, после обновления списка контактов.
    static func invalidate() {
        indexedForUserID = nil
        index = [:]
    }

    private static func rebuildIndex(ownUserID: String) {
        indexedForUserID = ownUserID
        index = [:]

        guard let data = UserDefaults.standard.data(forKey: cacheKeyPrefix + ownUserID),
              let contacts = try? JSONDecoder().decode([ContactItem].self, from: data) else {
            return
        }

        for contact in contacts {
            guard let avatarURL = contact.avatarURL else { continue }
            // У контакта из комнаты `id` — идентификатор комнаты, а не человека,
            // поэтому ключом берём именно matrixUserID.
            if let matrixUserID = contact.matrixUserID {
                index[matrixUserID] = avatarURL
            }
        }
    }
}
