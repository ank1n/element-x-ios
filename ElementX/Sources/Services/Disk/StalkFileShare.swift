//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Карточка «поделился файлом» — кастомное поле `io.stalk.file_share` на обычном
/// `m.notice`.
///
/// Событие устроено так намеренно: тело `m.notice` содержит читаемый текст со
/// ссылкой, поэтому клиент, который поля не понимает, показывает осмысленное
/// сообщение, а не «неподдерживаемое событие». Мы разбираем поле и рисуем
/// карточку, а при любой неудаче разбора остаёмся на этом же тексте — деградация
/// тихая и в худшую сторону не ломает ничего.
///
/// Состав полей подтверждён Molly (#ops, 30.07, п.6), сверен ей по коду веба.
struct StalkFileShare: Hashable {
    /// Право, выданное получателю. Незнакомые значения не отбрасываем — показываем
    /// как есть: сервер может завести новое, и молча спрятать его хуже.
    enum Permission: Hashable {
        case read
        case write
        case full
        case other(String)

        init(raw: String) {
            switch raw {
            case "read": self = .read
            case "write": self = .write
            case "full": self = .full
            default: self = .other(raw)
            }
        }

        var title: String {
            switch self {
            case .read: NSLocalizedString("stalk_file_share_permission_read", tableName: "Localizable", value: "Чтение", comment: "File share permission")
            case .write: NSLocalizedString("stalk_file_share_permission_write", tableName: "Localizable", value: "Редактирование", comment: "File share permission")
            case .full: NSLocalizedString("stalk_file_share_permission_full", tableName: "Localizable", value: "Полный доступ", comment: "File share permission")
            case .other(let raw): raw
            }
        }
    }

    /// Кому выдан доступ. Показываем только для собственных карточек — получателю
    /// чужой список прав не нужен и он же может содержать незнакомых людей.
    struct Recipient: Hashable {
        let user: String
        let displayName: String?

        var title: String {
            displayName ?? user
        }
    }

    /// Идентификатор блоба: содержимое достаётся `GET /api/files/blob/:id`.
    let blobID: String
    let name: String
    let size: Int64
    let mimetype: String
    /// `true` — Диск-нативный документ (редактируется через Collabora),
    /// `false` — копия файла. Различие важно для действия по тапу: документ
    /// осмысленно открывать в редакторе, копию — в просмотрщике.
    let isDiskDocument: Bool
    let permission: Permission
    let sharedWith: [Recipient]

    // MARK: - Разбор

    /// Достать карточку из сырого JSON события.
    ///
    /// Кастомные поля Rust SDK наружу не отдаёт — до них добираемся только через
    /// `debugInfo().originalJson`. Он ленивый, поэтому дёргаем его лишь для
    /// `m.notice`: на остальных типах поля всё равно не бывает.
    static func parse(originalJSON: String?) -> StalkFileShare? {
        guard let originalJSON,
              // Дешёвая отсечка до разбора JSON: событий-уведомлений в чате много,
              // а карточек среди них единицы.
              originalJSON.contains("io.stalk.file_share"),
              let data = originalJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Поле лежит внутри content; на всякий случай смотрим и в корне — форма
        // originalJson у SDK менялась между версиями.
        let content = root["content"] as? [String: Any] ?? root
        guard let share = content["io.stalk.file_share"] as? [String: Any],
              let blobID = share["blobId"] as? String, !blobID.isEmpty else {
            return nil
        }

        let recipients = (share["sharedWith"] as? [[String: Any]] ?? []).compactMap { entry -> Recipient? in
            guard let user = entry["user"] as? String else { return nil }
            return Recipient(user: user, displayName: entry["display"] as? String)
        }

        return StalkFileShare(blobID: blobID,
                              name: share["name"] as? String ?? "",
                              // Размер приходит числом, но JSON не гарантирует тип —
                              // читаем терпимо, иначе карточка пропадёт из-за строки.
                              size: (share["size"] as? NSNumber)?.int64Value ?? 0,
                              mimetype: share["mimetype"] as? String ?? "",
                              isDiskDocument: share["disk"] as? Bool ?? false,
                              permission: Permission(raw: share["permission"] as? String ?? ""),
                              sharedWith: recipients)
    }
}
