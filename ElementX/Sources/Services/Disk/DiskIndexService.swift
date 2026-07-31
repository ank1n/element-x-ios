//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.log
import UniformTypeIdentifiers

private let indexLog = OSLog(subsystem: "ru.implica.stalk", category: "DiskIndex")

// MARK: - Запись индекса

/// Метаданные одного файла для индекса «Диска».
///
/// Формат снят живыми пробами прода, а не выведен из документации — её у files-api
/// нет. Ключи именно camelCase: тот же набор полей в snake_case сервер принимает
/// молча и отвечает `{"indexed":0,"skipped":1}`, то есть неверное имя не ошибка,
/// а тихая потеря записи. Проверено переотправкой уже проиндексированного файла:
/// camelCase → `indexed:1`, snake_case → `skipped:1`.
struct DiskIndexRecord: Encodable, Hashable {
    let eventID: String
    let roomID: String
    let sender: String
    let filename: String
    let mimetype: String
    let size: Int64
    /// Индексируются только m.file / m.image / m.video / m.audio.
    let msgtype: String
    let mxcURL: String
    /// Время события, миллисекунды.
    let ts: Int64
    let isEncrypted: Bool

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case roomID = "roomId"
        case sender, filename, mimetype, size, msgtype
        case mxcURL = "mxcUrl"
        case ts, isEncrypted
    }
}

private struct DiskIndexRequest: Encodable {
    let files: [DiskIndexRecord]
}

private struct DiskIndexResponse: Decodable {
    let indexed: Int
    let skipped: Int
}

// MARK: - Сервис

/// Отправка метаданных файлов в индекс «Диска».
///
/// **Зачем это вообще нужно.** Архитектура files-api непривычная, и в ней здесь всё
/// дело: сами файлы лежат в Matrix-медиа, а в базе сервиса — только метаданные, и
/// наполняет их КЛИЕНТ. Сервер шифртекст не видит и видеть не может, поэтому
/// расшифровать событие и отдать «что это за файл» способен лишь тот, у кого есть
/// ключи комнаты. Пока iOS этого не делал, в «Диске» был виден только срез,
/// проиндексированный вебом: файл, отправленный с айфона в зашифрованную комнату,
/// не появлялся там никогда.
///
/// Контракт подтверждён Molly (#ops, 30.07) и проверен запросами:
/// `POST /api/files/index`, Matrix-токен, тело `{"files":[…]}`, ответ
/// `{"indexed":N,"skipped":N}`. Батч 200 записей (серверный кэп 500, тело JSON до
/// 2 МБ). Сервер сам отбрасывает комнаты, в которых отправитель запроса не состоит.
actor DiskIndexService {
    /// Размер батча. Меньше серверного кэпа (500) намеренно: при 2 МБ на тело
    /// длинные имена файлов способны раздуть запрос, а обрезание батча сервером
    /// выглядело бы как молча пропавшие файлы.
    private static let batchSize = 200

    /// Пауза перед отправкой. Таймлайн обновляется пачками (пагинация, дозагрузка,
    /// каждое новое сообщение), и без задержки один заход в комнату дал бы десяток
    /// запросов подряд.
    private static let flushDelay: Duration = .seconds(2)

    private let baseURL: String
    private let accessTokenProvider: () throws -> String
    private let seen: DiskIndexSeenStore

    private var pending: [String: DiskIndexRecord] = [:]
    private var flushTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init(baseURL: String, accessTokenProvider: @escaping () throws -> String, seen: DiskIndexSeenStore) {
        self.baseURL = baseURL
        self.accessTokenProvider = accessTokenProvider
        self.seen = seen
    }

    /// Принять записи к отправке. Уже отправленные отсеиваются здесь же, поэтому
    /// звать можно на каждое обновление таймлайна.
    func note(_ records: [DiskIndexRecord]) {
        let fresh = records.filter { !seen.contains($0.eventID) && pending[$0.eventID] == nil }
        guard !fresh.isEmpty else { return }

        for record in fresh {
            pending[record.eventID] = record
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Отправить накопленное. Неудачный батч НЕ помечается отправленным — записи
    /// останутся в очереди и уйдут со следующим обновлением таймлайна.
    func flush() async {
        guard !pending.isEmpty else { return }

        let batch = Array(pending.values.prefix(Self.batchSize))
        do {
            let response = try await push(batch)
            for record in batch {
                pending.removeValue(forKey: record.eventID)
                seen.insert(record.eventID)
            }
            DiagLog.write("DiskIndex", "отправлено \(batch.count): проиндексировано \(response.indexed), пропущено \(response.skipped)")

            // Осталась ещё пачка — дошлём, не дожидаясь следующего обновления.
            if !pending.isEmpty {
                scheduleFlush()
            }
        } catch {
            // Отмена — не сбой: запрос обрывается при уходе приложения в фон или
            // при смене комнаты. Записи остаются в очереди и уйдут со следующим
            // обновлением ленты, поэтому пугать этим выгрузку незачем. В логе
            // dp такая строка стояла рядом с успешными и читалась как потеря.
            let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            guard !isCancelled else { return }

            os_log(.error, log: indexLog, "не отправилось %{public}d записей: %{public}@", batch.count, "\(error)")
            DiagLog.write("DiskIndex", "батч из \(batch.count) не ушёл: \(error.localizedDescription)")
        }
    }

    private func push(_ records: [DiskIndexRecord]) async throws -> DiskIndexResponse {
        guard let url = URL(string: "\(baseURL)/api/files/index") else {
            throw DiskServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        try request.setValue("Bearer \(accessTokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DiskIndexRequest(files: records))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw status == 401 ? DiskServiceError.unauthorized : DiskServiceError.http(status)
        }
        return try JSONDecoder().decode(DiskIndexResponse.self, from: data)
    }
}

// MARK: - Разбор элементов таймлайна

extension DiskIndexService {
    /// Выбрать из элементов таймлайна то, что индексируется.
    ///
    /// Индексируем то, что ОТРИСОВАЛИ, — тем же способом, что и веб. Индексировать
    /// «на отправке» не выходит: `sendFile` возвращает `Void`, ни идентификатора
    /// события, ни mxc-адреса у нас в этот момент ещё нет.
    static func records(from items: [RoomTimelineItemProtocol],
                        roomID: String,
                        isRoomEncrypted: Bool) -> [DiskIndexRecord] {
        items.compactMap { item -> DiskIndexRecord? in
            guard let message = item as? EventBasedMessageTimelineItemProtocol,
                  let eventID = item.id.eventID else {
                return nil
            }

            let filename: String
            let source: MediaSourceProxy?
            let fileSize: UInt?
            let contentType: UTType?
            let msgtype: String

            switch message.contentType {
            case .file(let content):
                filename = content.filename
                source = content.source
                fileSize = content.fileSize
                contentType = content.contentType
                msgtype = "m.file"
            case .image(let content):
                filename = content.filename
                source = content.imageInfo.source
                fileSize = content.imageInfo.fileSize
                contentType = content.contentType
                msgtype = "m.image"
            case .video(let content):
                filename = content.filename
                source = content.videoInfo.source
                fileSize = content.videoInfo.fileSize
                contentType = content.contentType
                msgtype = "m.video"
            case .audio(let content):
                filename = content.filename
                source = content.source
                fileSize = content.fileSize
                contentType = content.contentType
                msgtype = "m.audio"
            case .voice(let content):
                // Голосовое — тот же m.audio, отдельного типа у сервера нет.
                filename = content.filename
                source = content.source
                fileSize = content.fileSize
                contentType = content.contentType
                msgtype = "m.audio"
            case .emote, .notice, .text, .location:
                return nil
            }

            guard let mxcURL = source?.url?.absoluteString, !mxcURL.isEmpty else {
                return nil
            }

            // Тип берём из события, а не угадываем по расширению: у отправителя он
            // уже посчитан, и он переживает незнакомые нам форматы.
            let mimetype = source?.mimeType ?? contentType?.preferredMIMEType ?? "application/octet-stream"

            return DiskIndexRecord(eventID: eventID,
                                   roomID: roomID,
                                   sender: message.sender.id,
                                   filename: filename,
                                   mimetype: mimetype,
                                   size: Int64(fileSize ?? 0),
                                   msgtype: msgtype,
                                   mxcURL: mxcURL,
                                   ts: Int64(message.timestamp.timeIntervalSince1970 * 1000),
                                   isEncrypted: isRoomEncrypted)
        }
    }
}

// MARK: - Память об отправленном

/// Что уже ушло в индекс. Без неё каждое обновление таймлайна переотправляло бы
/// всю комнату: сервер такие записи молча схлопывает в upsert, но трафик и батчи
/// были бы бессмысленными.
///
/// Ключ привязан к пользователю: на другом аккаунте набор файлов свой, а общий
/// список заставил бы думать, что чужие файлы уже проиндексированы.
final class DiskIndexSeenStore {
    private static let maxEntries = 5000

    private let key: String
    private let store: UserDefaults
    private var ids: [String]
    private var lookup: Set<String>

    init(userID: String, store: UserDefaults = .standard) {
        key = "ru.implica.stalk.diskIndexed.\(userID)"
        self.store = store
        ids = store.stringArray(forKey: key) ?? []
        lookup = Set(ids)
    }

    func contains(_ eventID: String) -> Bool {
        lookup.contains(eventID)
    }

    func insert(_ eventID: String) {
        guard lookup.insert(eventID).inserted else { return }
        ids.append(eventID)
        // Порядок = порядок отправки, поэтому вытесняем самые старые. Вытесненное
        // может уйти повторно — это upsert, данные от этого не портятся.
        if ids.count > Self.maxEntries {
            let dropped = ids.prefix(ids.count - Self.maxEntries)
            lookup.subtract(dropped)
            ids.removeFirst(ids.count - Self.maxEntries)
        }
        store.set(ids, forKey: key)
    }
}
