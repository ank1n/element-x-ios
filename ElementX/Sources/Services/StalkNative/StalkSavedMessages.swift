// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import MatrixRustSDK
import SwiftUI
import UIKit

/// Откуда сохранено сообщение. Контракт веба (STALK-1383): поле `ru.stalk.saved_from`
/// есть только у копий в комнате «Сохранённые»; при пересылке наружу оно не уходит.
struct StalkSavedFrom: Hashable {
    let sender: String
    let senderName: String?
    let roomID: String
    let roomName: String?
    let eventID: String?
    let ts: Int64

    static let key = "ru.stalk.saved_from"

    var title: String {
        [senderName ?? sender, roomName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    var permalink: URL? {
        eventID.flatMap { StalkChannelForwarding.sourceURL(roomID: roomID, eventID: $0) }
    }

    static func parse(originalJSON: String?) -> StalkSavedFrom? {
        // Дешёвая проверка до разбора JSON: поле встречается только в одной комнате.
        guard let originalJSON, originalJSON.contains(key), let bytes = originalJSON.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let content = event["content"] as? [String: Any],
              let value = content[key] as? [String: Any] else { return nil }
        return parse(value)
    }

    static func parse(_ value: [String: Any]) -> StalkSavedFrom? {
        func text(_ key: String) -> String? {
            (value[key] as? String).map { String($0.prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let sender = text("sender"), let room = text("room_id"), let ts = (value["ts"] as? NSNumber)?.int64Value else { return nil }
        return .init(sender: sender, senderName: text("sender_name"), roomID: room, roomName: text("room_name"), eventID: text("event_id"), ts: ts)
    }

    var json: [String: Any] {
        var result: [String: Any] = ["sender": sender, "room_id": roomID, "ts": ts]
        result["sender_name"] = senderName
        result["room_name"] = roomName
        result["event_id"] = eventID
        return result
    }
}

enum StalkSavedMessagesError: Error {
    case unavailable
}

/// Личная комната «Сохранённые» — общая с вебом (STALK-1383).
/// Комната ищется по account data `ru.stalk.saved_messages` и создаётся лениво при первом «Сохранить».
@MainActor
final class StalkSavedMessagesService: ObservableObject {
    // Сильная ссылка по учётке: сервис держит единственную попытку создания комнаты
    // и признак сверки за сессию; новый клиент той же учётки получает новый сервис.
    private static var stores: [String: StalkSavedMessagesService] = [:]
    static func shared(client: ClientProxyProtocol) -> StalkSavedMessagesService {
        if let value = stores[client.userID], (value.client as AnyObject) === (client as AnyObject) { return value }
        let service = StalkSavedMessagesService(client: client)
        stores[client.userID] = service
        return service
    }

    static let accountDataType = "ru.stalk.saved_messages"

    private let client: ClientProxyProtocol
    private let api: StalkNativeAPI
    private let cacheKey: String
    private var ensureTask: Task<JoinedRoomProxyProtocol, Error>?
    /// Лента «Сохранённых», по которой строится индекс копий (как на вебе — то, что загружено).
    private var trackedRoom: JoinedRoomProxyProtocol?
    private var trackingCancellable: AnyCancellable?
    private var copies: [String: String] = [:]
    /// Сохранённые исходные сообщения: ключ «комната|событие».
    @Published private(set) var savedSources = Set<String>()

    static func sourceKey(roomID: String, eventID: String) -> String {
        roomID + "|" + eventID
    }

    /// Последний известный идентификатор комнаты (кэш между запусками).
    private(set) var roomID: String? {
        didSet { UserDefaults.standard.set(roomID, forKey: cacheKey) }
    }

    private init(client: ClientProxyProtocol) {
        self.client = client
        api = StalkNativeAPI(client: client)
        cacheKey = "stalk.savedMessagesRoom." + client.userID
        roomID = UserDefaults.standard.string(forKey: cacheKey)
    }

    func isSavedRoom(_ id: String) -> Bool {
        roomID == id
    }

    private var didRefresh = false

    /// Сверить кэш с сервером один раз за сессию (комнату мог создать веб).
    func refresh() async {
        guard !didRefresh else { return }
        do {
            roomID = try await readAccountData()
            didRefresh = true
        } catch {
            MXLog.warning("Saved messages: account data unavailable")
        }
    }

    /// Найти или создать комнату. Одновременно идёт только одна попытка, чтобы не создать две комнаты.
    func ensureRoom() async throws -> JoinedRoomProxyProtocol {
        if let ensureTask { return try await ensureTask.value }
        let task = Task { try await self.resolveRoom() }
        ensureTask = task
        defer { ensureTask = nil }
        return try await task.value
    }

    /// Начать следить за копиями, если комната уже есть (сама комната здесь не создаётся).
    func startTracking() async {
        guard trackedRoom == nil, let roomID, client.roomMembership(roomID: roomID) == .joined,
              case let .joined(room) = await client.roomForIdentifier(roomID) else { return }
        await track(room)
        // Чуть глубже загруженного по умолчанию, чтобы «Сохранено» узнавалось и у недавних копий.
        _ = await room.timeline.paginateBackwards(requestSize: 50)
    }

    func savedCopyID(roomID: String, eventID: String) -> String? {
        copies[Self.sourceKey(roomID: roomID, eventID: eventID)]
    }

    /// «Убрать из сохранённых»: отзывается только копия, исходный чат не трогаем (как на вебе).
    func removeCopy(roomID: String, eventID: String) async throws {
        guard let room = trackedRoom, let copy = savedCopyID(roomID: roomID, eventID: eventID) else { throw StalkSavedMessagesError.unavailable }
        if case .failure(let error) = await room.timeline.redact(.eventID(copy), reason: nil) { throw error }
    }

    private func track(_ room: JoinedRoomProxyProtocol) async {
        trackedRoom = room
        // Без подписки у ленты ещё нет поставщика элементов (обращение к нему — падение).
        await room.subscribeForUpdates()
        guard trackedRoom?.id == room.id else { return }
        trackingCancellable = room.timeline.timelineItemProvider.updatePublisher
            .map(\.0)
            .prepend(room.timeline.timelineItemProvider.itemProxies)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.rebuildIndex(items) }
    }

    private func rebuildIndex(_ items: [TimelineItemProxy]) {
        var copies: [String: String] = [:]
        for case let .event(item) in items {
            guard let copyID = item.id.eventID, let from = StalkSavedFrom.parse(originalJSON: item.debugInfo.originalJSON),
                  let source = from.eventID else { continue }
            copies[Self.sourceKey(roomID: from.roomID, eventID: source)] = copyID
        }
        self.copies = copies
        let keys = Set(copies.keys)
        if keys != savedSources { savedSources = keys }
    }

    // MARK: - Private

    private func resolveRoom() async throws -> JoinedRoomProxyProtocol {
        let known = try await readAccountData()
        if let known {
            let membership = client.roomMembership(roomID: known)
            if membership != .left, membership != .banned {
                // Комната известна, но SDK её ещё не видит (холодный старт, пауза) — ошибка,
                // а не новая комната: иначе сохранённое осиротеет.
                guard let room = await joinedRoom(known) else { throw StalkSavedMessagesError.unavailable }
                roomID = known
                if trackedRoom?.id != room.id { await track(room) }
                return room
            }
        }
        // Комнаты нет или из неё вышли — новое хранилище, как на вебе.
        let created = try await createRoom()
        try await writeAccountData(created)
        roomID = created
        // Другое устройство могло создать комнату одновременно: побеждает записанная в account data.
        try? await Task.sleep(for: .milliseconds(1500))
        if let winner = try? await readAccountData(), winner != created, let room = await joinedRoom(winner) {
            roomID = winner
            if case let .joined(own) = await client.roomForIdentifier(created) { _ = await own.leaveRoom() }
            await track(room)
            return room
        }
        guard let room = await joinedRoom(created) else { throw StalkSavedMessagesError.unavailable }
        await track(room)
        return room
    }

    private func joinedRoom(_ id: String) async -> JoinedRoomProxyProtocol? {
        // Только что созданная комната может ещё не прийти синком: ждём её эха.
        client.addRoomsToAwait([id])
        guard case let .joined(room) = await client.roomForIdentifier(id) else { return nil }
        return room
    }

    private var accountDataPath: [String] {
        ["_matrix", "client", "v3", "user", client.userID, "account_data", Self.accountDataType]
    }

    private func readAccountData() async throws -> String? {
        do {
            let id = try await api.object(accountDataPath)["room_id"] as? String
            return id?.hasPrefix("!") == true ? id : nil
        } catch let error as StalkNativeHTTPError where error.status == 404 {
            return nil
        }
    }

    private func writeAccountData(_ id: String) async throws {
        _ = try await api.object(accountDataPath, method: "PUT", body: ["room_id": id])
    }

    private func createRoom() async throws -> String {
        var initialState: [[String: Any]] = [[
            "type": "m.room.encryption", "state_key": "",
            "content": ["algorithm": "m.megolm.v1.aes-sha2"]
        ]]
        if let avatar = try? await uploadAvatar() {
            initialState.append(["type": "m.room.avatar", "state_key": "", "content": ["url": avatar]])
        }
        let body: [String: Any] = [
            "name": "Сохранённые",
            "topic": "Ваше личное хранилище: сюда можно писать себе и пересылать сообщения из других чатов. Видно только вам.",
            "preset": "private_chat",
            "creation_content": [Self.accountDataType: true],
            "initial_state": initialState
        ]
        guard let id = try await api.object(["_matrix", "client", "v3", "createRoom"], method: "POST", body: body)["room_id"] as? String else {
            throw StalkSavedMessagesError.unavailable
        }
        MXLog.info("Saved messages: room created \(id)")
        return id
    }

    /// Аватар как на вебе: синий квадрат с белой закладкой.
    private func uploadAvatar() async throws -> String? {
        let size = CGSize(width: 192, height: 192)
        let png = UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "bookmark.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 88, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
        let data = try await api.request(["_matrix", "media", "v3", "upload"], query: [.init(name: "filename", value: "saved-messages.png")],
                                         method: "POST", body: png, contentType: "image/png")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content_uri"] as? String
    }
}

extension StalkSavedMessagesService {
    /// Копия содержимого сообщения для «Сохранённых» с полем `ru.stalk.saved_from`.
    /// У уже сохранённой копии исходное поле сохраняется, как на вебе.
    static func savedContent(originalJSON: String?, latestEditJSON: String?, source: StalkSavedFrom) -> String? {
        func body(_ raw: String?) -> [String: Any]? {
            guard let raw, let bytes = raw.data(using: .utf8), let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let content = event["content"] as? [String: Any] else { return nil }
            return content["m.new_content"] as? [String: Any] ?? content
        }
        guard let original = body(originalJSON) else { return nil }
        let current = body(latestEditJSON) ?? original
        guard let type = current["msgtype"] as? String,
              ["m.text", "m.image", "m.file", "m.video", "m.audio", "m.notice", "m.emote", "m.location"].contains(type) else { return nil }
        let allowed: Set = ["msgtype", "body", "format", "formatted_body", "filename", "url", "file", "info", "geo_uri",
                            "org.matrix.msc1767.audio", "org.matrix.msc3245.voice", StalkChannelForwarding.key]
        var content = current.filter { allowed.contains($0.key) }
        if let share = current["io.stalk.file_share"] as? [String: Any], let id = share["blobId"] as? String, !id.isEmpty {
            let fields: Set = ["blobId", "name", "size", "mimetype", "disk"]
            content["io.stalk.file_share"] = share.filter { fields.contains($0.key) }
        }
        let existing = (original[StalkSavedFrom.key] as? [String: Any]).flatMap(StalkSavedFrom.parse)
        content[StalkSavedFrom.key] = (existing ?? source).json
        guard let bytes = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

/// Строка «↪ Имя · Чат» над сохранённым сообщением; ведёт к исходному сообщению.
struct SavedFromHeader: View {
    let savedFrom: StalkSavedFrom
    @Environment(\.openURL) private var openURL

    var body: some View {
        let label = Label(savedFrom.title, systemImage: "arrowshape.turn.up.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if let url = savedFrom.permalink {
            Button { openURL(url) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint(SL10n.savedMessagesOpenSource)
        } else {
            label
        }
    }
}
