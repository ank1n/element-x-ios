// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import SwiftUI

// STMOB-333: задачи комнаты — паритет с вебом (STALK-1374). Сервер общий с вебом:
// recording-api `/api/recording/room-tasks`, авторизация Matrix-токеном пользователя.

extension Notification.Name {
    /// Задачи комнаты изменились (object — идентификатор комнаты): таймлайн обновляет значки «Задача».
    static let stalkRoomTasksChanged = Notification.Name("stalkRoomTasksChanged")
}

struct RoomTask: Identifiable, Hashable {
    enum Status: String, CaseIterable {
        case new, inProgress = "in_progress", done, cancelled

        var title: String {
            switch self {
            case .new: SL10n.roomTasksStatusNew
            case .inProgress: SL10n.roomTasksStatusInProgress
            case .done: SL10n.roomTasksStatusDone
            case .cancelled: SL10n.roomTasksStatusCancelled
            }
        }
    }

    struct Basis: Hashable, Identifiable {
        let eventID: String
        var sender: String?
        var ts: Int64?
        var quote: String?
        var id: String {
            eventID
        }
    }

    let id: Int
    var title: String
    var description: String
    var assignee: String?
    var status: Status
    var version: Int
    var createdBy: String?
    var dueDate: String?
    var basis: [Basis]
    var trackitIssueID: String?
    var trackitURL: URL?
    var trackitKey: String?
    var trackitStateName: String?
    var remoteAssigneeNames: [String]
    var assignedToMe: Bool

    var isLinked: Bool {
        trackitIssueID != nil
    }

    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        title = json["title"] as? String ?? json["task_text"] as? String ?? ""
        description = json["description"] as? String ?? ""
        assignee = json["assignee"] as? String
        status = (json["status"] as? String).flatMap(Status.init) ?? .new
        version = (json["version"] as? NSNumber)?.intValue ?? 1
        createdBy = json["created_by"] as? String
        dueDate = (json["due_date"] as? String).map { String($0.prefix(10)) }
        basis = (json["basis"] as? [[String: Any]] ?? []).compactMap { item in
            guard let eventID = item["eventId"] as? String else { return nil }
            return Basis(eventID: eventID, sender: item["sender"] as? String, ts: (item["ts"] as? NSNumber)?.int64Value, quote: item["quote"] as? String)
        }
        trackitIssueID = json["trackit_issue_id"] as? String
        trackitURL = (json["trackit_url"] as? String).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme) ? $0 : nil }
        if let identifier = json["trackit_project_identifier"] as? String, let sequence = (json["trackit_sequence_id"] as? NSNumber)?.intValue {
            trackitKey = "\(identifier)-\(sequence)"
        }
        trackitStateName = json["trackit_state_name"] as? String
        remoteAssigneeNames = json["remote_assignee_names"] as? [String] ?? []
        assignedToMe = json["assigned_to_me"] as? Bool ?? false
    }
}

struct RoomTaskMember: Hashable, Identifiable {
    let id: String
    let name: String
}

struct RoomTaskProject: Hashable, Identifiable {
    let id: String
    let name: String
    let identifier: String
}

/// Отметка «Задача» на сообщении-основании.
struct RoomTaskBasisMark: Hashable {
    let taskID: Int
    let title: String?
    let status: RoomTask.Status?
    let linked: Bool
}

/// Черновик новой задачи (в том числе из сообщения).
struct RoomTaskDraft {
    struct BasisMessage: Hashable, Identifiable {
        let eventID: String
        /// «Имя: текст» — строка в списке оснований.
        let label: String
        /// «Имя (дата): текст» — строка описания, как на вебе.
        var line = ""
        /// Первая строка текста — название задачи по первому сообщению.
        var firstLine = ""
        var id: String {
            eventID
        }
    }

    /// Не больше 20 сообщений-оснований (ограничение сервера и веба).
    static let basisLimit = 20

    var title = ""
    var description = ""
    var basis: [BasisMessage] = []
    /// Соседние сообщения чата по порядку — из них можно добрать основания.
    var candidates: [BasisMessage] = []

    static func title(for basis: [BasisMessage]) -> String {
        String((basis.first?.firstLine ?? "").prefix(80))
    }

    static func description(for basis: [BasisMessage]) -> String {
        basis.map(\.line).joined(separator: "\n")
    }
}

enum RoomTasksEntry {
    case list
    case create(RoomTaskDraft)
    case task(id: Int)
}

@MainActor
final class RoomTasksAPI {
    private let api: StalkNativeAPI
    private static var enabledByHost: [String: (value: Bool, at: Date)] = [:]

    init(client: ClientProxyProtocol) {
        api = StalkNativeAPI(client: client)
    }

    /// Выключатель веба: `features.feature_stalk_room_tasks` в `/config.json` того же сервера.
    static func isEnabled(client: ClientProxyProtocol) async -> Bool {
        guard let host = URL(string: client.homeserver)?.host else { return false }
        // Ответ (и сбой) помним 5 минут, чтобы не спрашивать при каждом открытии комнаты.
        if let cached = enabledByHost[host], Date().timeIntervalSince(cached.at) < 300 { return cached.value }
        var request = URLRequest(url: URL(string: "https://\(host)/config.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        var enabled = false
        if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            enabled = (json["features"] as? [String: Any])?["feature_stalk_room_tasks"] as? Bool ?? false
        }
        enabledByHost[host] = (enabled, Date())
        return enabled
    }

    private let base = ["api", "recording", "room-tasks"]

    func list(roomID: String, mine: Bool, completed: Bool, before: Int?) async throws -> (tasks: [RoomTask], members: [RoomTaskMember], next: Int?) {
        var query: [URLQueryItem] = [.init(name: "roomId", value: roomID), .init(name: "filter", value: mine ? "mine" : "all"),
                                     .init(name: "completed", value: completed ? "true" : "false"),
                                     // Предложения из звонков здесь не показываем — только задачи.
                                     .init(name: "beforeSuggestions", value: "end")]
        if let before { query.append(.init(name: "before", value: String(before))) }
        let json = try await api.object(base, query: query)
        let tasks = (json["tasks"] as? [[String: Any]] ?? []).compactMap(RoomTask.init(json:))
        let members = (json["members"] as? [[String: Any]] ?? []).compactMap { item -> RoomTaskMember? in
            guard let id = item["id"] as? String else { return nil }
            return .init(id: id, name: (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
        return (tasks, members, (json["next"] as? NSNumber)?.intValue)
    }

    func create(roomID: String, requestID: String, title: String, description: String, assignee: String?,
                dueDate: String?, basis: [String], allowUnencryptedStorage: Bool) async throws -> RoomTask {
        var body: [String: Any] = ["roomId": roomID, "requestId": requestID, "title": title, "description": description,
                                   "status": "new", "basis": basis, "allowUnencryptedStorage": allowUnencryptedStorage]
        body["assignee"] = assignee
        body["dueDate"] = dueDate
        return try await task(from: api.object(base, method: "POST", body: body))
    }

    /// `fields`: только изменённые поля; `NSNull()` снимает значение (срок, исполнитель).
    func update(taskID: Int, version: Int, fields: [String: Any]) async throws -> RoomTask {
        var body = fields
        body["version"] = version
        return try await task(from: api.object(base + [String(taskID)], method: "PATCH", body: body))
    }

    func sendToTrackit(taskID: Int, version: Int, projectID: String) async throws -> RoomTask {
        try await task(from: api.object(base + [String(taskID), "trackit"], method: "POST", body: ["version": version, "projectId": projectID]))
    }

    func basis(roomID: String) async throws -> [String: RoomTaskBasisMark] {
        let json = try await api.object(base + ["basis"], query: [.init(name: "roomId", value: roomID)])
        var result: [String: RoomTaskBasisMark] = [:]
        // Ответ упорядочен от новых задач к старым: на сообщении показываем самую свежую.
        for item in json["items"] as? [[String: Any]] ?? [] {
            guard let eventID = item["eventId"] as? String, let taskID = (item["taskId"] as? NSNumber)?.intValue, result[eventID] == nil else { continue }
            result[eventID] = .init(taskID: taskID, title: item["title"] as? String,
                                    status: (item["status"] as? String).flatMap(RoomTask.Status.init), linked: item["linked"] as? Bool ?? false)
        }
        return result
    }

    func projects(roomID: String) async throws -> [RoomTaskProject] {
        let json = try await api.object(base + ["projects"], query: [.init(name: "roomId", value: roomID)])
        return (json["projects"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return .init(id: id, name: name, identifier: item["identifier"] as? String ?? "")
        }
    }

    private func task(from json: [String: Any]) throws -> RoomTask {
        guard let task = (json["task"] as? [String: Any]).flatMap(RoomTask.init(json:)) else { throw URLError(.cannotParseResponse) }
        return task
    }

    /// Текст ошибки для человека: русское `message` сервера, иначе по коду.
    static func message(for error: Error) -> String {
        guard let error = error as? StalkNativeHTTPError else { return SL10n.roomTasksError }
        if let message = error.message, !message.isEmpty { return message }
        switch error.status {
        case 403: return SL10n.roomTasksForbidden
        case 409: return SL10n.roomTasksConflict
        default: return SL10n.roomTasksError
        }
    }

    /// Срок — календарный день без времени, в часовом поясе устройства на момент вызова.
    static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func displayDate(_ day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Model

@MainActor
final class RoomTasksModel: ObservableObject {
    struct Editor: Identifiable {
        enum Mode { case create, edit(RoomTask) }
        let id = UUID()
        var mode: Mode
        var title = ""
        var description = ""
        var assignee: String?
        var hasDueDate = false
        var dueDate = Date()
        var status: RoomTask.Status = .new
        var projectID: String?
        var basis: [RoomTaskDraft.BasisMessage] = []
        var candidates: [RoomTaskDraft.BasisMessage] = []
        var allowUnencrypted = false
        let requestID = UUID().uuidString.lowercased()
        /// Срок при открытии редактора: отправляем срок, только если пользователь его изменил.
        var initialDue: String?
        /// Нижняя граница выбора даты, зафиксированная при открытии.
        var minimumDate = Calendar.current.startOfDay(for: Date())

        var isCreate: Bool {
            if case .create = mode { true } else { false }
        }
    }

    @Published var tasks: [RoomTask] = []
    @Published var members: [RoomTaskMember] = []
    @Published var projects: [RoomTaskProject] = []
    @Published var mine = false {
        didSet { if mine != oldValue { reload() } }
    }

    @Published var showCompleted = false {
        didSet { if showCompleted != oldValue { reload() } }
    }

    @Published var isLoading = false
    @Published var errorText: String?
    @Published var editor: Editor?
    @Published var isSaving = false
    @Published var editorError: String?

    let roomID: String
    let ownUserID: String
    /// Неизвестное состояние считаем шифрованием: согласие лучше спросить лишний раз.
    @Published private(set) var isEncrypted = true
    private let roomProxy: JoinedRoomProxyProtocol
    private let api: RoomTasksAPI
    private var loadGeneration = 0
    private let openEvent: (String) -> Void
    private var next: Int?
    private var loadTask: Task<Void, Never>?
    private var pendingTaskID: Int?

    init(roomProxy: JoinedRoomProxyProtocol, clientProxy: ClientProxyProtocol, entry: RoomTasksEntry, openEvent: @escaping (String) -> Void) {
        roomID = roomProxy.id
        ownUserID = roomProxy.ownUserID
        self.roomProxy = roomProxy
        // Пока список не пришёл, исполнителей берём из участников комнаты.
        members = roomProxy.membersPublisher.value.filter { $0.membership == .join }.map { .init(id: $0.userID, name: $0.displayName ?? $0.userID) }
        api = RoomTasksAPI(client: clientProxy)
        self.openEvent = openEvent
        switch entry {
        case .list: break
        case .create(let draft): startCreate(draft)
        case .task(let id): pendingTaskID = id; showCompleted = true
        }
        reload()
        Task { projects = await (try? api.projects(roomID: roomID)) ?? [] }
        Task {
            if let joined = roomProxy as? JoinedRoomProxy {
                isEncrypted = await joined.encryptionStateForCall()
            } else {
                isEncrypted = roomProxy.infoPublisher.value.isEncrypted
            }
        }
    }

    /// Права админа (уровень 100) по текущему списку участников; сервер проверяет их сам.
    var isAdmin: Bool {
        (roomProxy.membersPublisher.value.first { $0.userID == ownUserID }?.powerLevel ?? .value(0)) >= .value(100)
    }

    var sortedMembers: [RoomTaskMember] {
        members.sorted { lhs, rhs in
            if lhs.id == ownUserID { return true }
            if rhs.id == ownUserID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func memberName(_ id: String?) -> String? {
        guard let id else { return nil }
        let name = members.first { $0.id == id }?.name ?? id
        return id == ownUserID ? "\(name) \(SL10n.roomTasksMe)" : name
    }

    func reload() {
        loadTask?.cancel()
        next = nil
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { await load(before: nil, generation: generation) }
    }

    func loadMore() {
        guard let next, loadTask == nil else { return }
        let generation = loadGeneration
        loadTask = Task { await load(before: next, generation: generation) }
    }

    private func load(before: Int?, generation: Int) async {
        isLoading = true
        defer {
            // Отменённая загрузка не трогает состояние новой.
            if generation == loadGeneration { isLoading = false; loadTask = nil }
        }
        do {
            var cursor = before
            var pages = 0
            repeat {
                let page = try await api.list(roomID: roomID, mine: mine, completed: showCompleted, before: cursor)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                tasks = cursor == nil ? page.tasks : tasks + page.tasks
                if !page.members.isEmpty { members = page.members }
                next = page.next
                cursor = page.next
                pages += 1
                // Задачу из значка «Задача» ищем дальше первой страницы (но не бесконечно).
            } while pendingTaskID != nil && !tasks.contains {
                $0.id == pendingTaskID
            } && cursor != nil && pages < 10
            errorText = nil
            if let pendingTaskID {
                self.pendingTaskID = nil
                if let task = tasks.first(where: { $0.id == pendingTaskID }) { startEdit(task) }
            }
            // После 409 редактор получает свежую версию задачи, правки пользователя остаются.
            if case .edit(let open) = editor?.mode, let fresh = tasks.first(where: { $0.id == open.id }), fresh.version != open.version {
                editor?.mode = .edit(fresh)
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorText = RoomTasksAPI.message(for: error)
        }
    }

    // MARK: Editing

    func startCreate(_ draft: RoomTaskDraft = .init()) {
        editorError = nil
        var editor = Editor(mode: .create, title: draft.title, description: draft.description, basis: draft.basis)
        editor.candidates = draft.candidates
        self.editor = editor
    }

    /// Новый набор оснований (в порядке чата). Название и описание пересобираются,
    /// только если человек их ещё не правил.
    func setBasis(_ ids: Set<String>) {
        guard var editor else { return }
        let pool = editor.candidates.isEmpty ? editor.basis : editor.candidates
        let basis = Array(pool.filter { ids.contains($0.eventID) }.prefix(RoomTaskDraft.basisLimit))
        if editor.title == RoomTaskDraft.title(for: editor.basis) { editor.title = RoomTaskDraft.title(for: basis) }
        if editor.description == RoomTaskDraft.description(for: editor.basis) { editor.description = RoomTaskDraft.description(for: basis) }
        editor.basis = basis
        self.editor = editor
    }

    func startEdit(_ task: RoomTask) {
        editorError = nil
        var editor = Editor(mode: .edit(task), title: task.title, description: task.description, assignee: task.assignee, status: task.status)
        if let due = task.dueDate, let date = RoomTasksAPI.dayFormatter.date(from: due) {
            editor.hasDueDate = true
            editor.dueDate = date
            editor.minimumDate = min(editor.minimumDate, date)
        }
        editor.initialDue = editor.hasDueDate ? RoomTasksAPI.dayFormatter.string(from: editor.dueDate) : nil
        self.editor = editor
    }

    func canEditAll(_ task: RoomTask) -> Bool {
        task.createdBy == ownUserID || isAdmin
    }

    func canEditStatus(_ task: RoomTask) -> Bool {
        canEditAll(task) || task.assignee == ownUserID
    }

    func open(_ basis: String) {
        openEvent(basis)
    }

    func save() async {
        guard let editor, !isSaving else { return }
        let title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let description = editor.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = editor.hasDueDate ? RoomTasksAPI.dayFormatter.string(from: editor.dueDate) : nil
        isSaving = true
        editorError = nil
        defer { isSaving = false }
        do {
            switch editor.mode {
            case .create:
                var task = try await api.create(roomID: roomID, requestID: editor.requestID, title: String(title.prefix(250)),
                                                description: String(description.prefix(20000)), assignee: editor.assignee, dueDate: due,
                                                basis: editor.basis.map(\.eventID), allowUnencryptedStorage: isEncrypted && editor.allowUnencrypted)
                if let projectID = editor.projectID {
                    do {
                        task = try await api.sendToTrackit(taskID: task.id, version: task.version, projectID: projectID)
                    } catch {
                        // Задача уже в чате: показываем частичный успех, как на вебе.
                        finishSave()
                        errorText = String(format: SL10n.roomTasksTrackitPartial, RoomTasksAPI.message(for: error))
                        return
                    }
                }
                mine = false
                finishSave()
            case .edit(let task):
                var fields: [String: Any] = [:]
                if canEditAll(task) {
                    if title != task.title.trimmingCharacters(in: .whitespacesAndNewlines) { fields["title"] = String(title.prefix(250)) }
                    if description != task.description.trimmingCharacters(in: .whitespacesAndNewlines) { fields["description"] = String(description.prefix(20000)) }
                    if editor.assignee != task.assignee { fields["assignee"] = editor.assignee ?? NSNull() }
                    if due != editor.initialDue { fields["dueDate"] = due ?? NSNull() }
                }
                if !task.isLinked, editor.status != task.status, canEditStatus(task) { fields["status"] = editor.status.rawValue }
                var version = task.version
                if !fields.isEmpty { version = try await api.update(taskID: task.id, version: task.version, fields: fields).version }
                // Отправка в TrackIT — после сохранения правок, с новой версией задачи.
                if let projectID = editor.projectID, !task.isLinked, canEditAll(task) {
                    do {
                        _ = try await api.sendToTrackit(taskID: task.id, version: version, projectID: projectID)
                    } catch {
                        finishSave()
                        errorText = String(format: SL10n.roomTasksTrackitPartial, RoomTasksAPI.message(for: error))
                        return
                    }
                }
                finishSave()
            }
        } catch {
            editorError = RoomTasksAPI.message(for: error)
            if (error as? StalkNativeHTTPError)?.status == 409 { reload() }
        }
    }

    private func finishSave() {
        editor = nil
        reload()
        NotificationCenter.default.post(name: .stalkRoomTasksChanged, object: roomID)
    }
}

// MARK: - Views

struct RoomTasksScreen: View {
    @ObservedObject var model: RoomTasksModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(SL10n.roomTasksTitle, selection: $model.mine) {
                        Text(SL10n.roomTasksFilterAll).tag(false)
                        Text(SL10n.roomTasksFilterMine).tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle(SL10n.roomTasksShowCompleted, isOn: $model.showCompleted)
                }
                if let error = model.errorText {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ForEach(model.tasks) { task in
                        Button { model.startEdit(task) } label: { RoomTaskRow(task: task, assignee: model.memberName(task.assignee)) }
                            .buttonStyle(.plain)
                            .onAppear { if task.id == model.tasks.last?.id { model.loadMore() } }
                    }
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if model.tasks.isEmpty, model.errorText == nil {
                        Text(SL10n.roomTasksEmpty).foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { model.reload() }
            .navigationTitle(SL10n.roomTasksTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionClose) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.startCreate() } label: { Label(SL10n.roomTasksNew, systemImage: "plus") }
                }
            }
            .sheet(item: $model.editor) { _ in
                RoomTaskEditorView(model: model)
            }
        }
    }
}

private struct RoomTaskRow: View {
    let task: RoomTask
    let assignee: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(2)
                Spacer()
                Text(task.isLinked ? (task.trackitStateName ?? task.status.title) : task.status.title)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            HStack(spacing: 8) {
                if let key = task.trackitKey { Text(key) }
                if let name = assignee ?? task.remoteAssigneeNames.first { Label(name, systemImage: "person") }
                if let due = task.dueDate { Label(RoomTasksAPI.displayDate(due), systemImage: "calendar") }
                if !task.basis.isEmpty { Label("\(task.basis.count)", systemImage: "text.bubble") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct RoomTaskEditorView: View {
    @ObservedObject var model: RoomTasksModel
    @Environment(\.openURL) private var openURL
    @State private var showsMessagePicker = false

    private var editor: Binding<RoomTasksModel.Editor> {
        Binding { model.editor ?? .init(mode: .create) } set: { value in
            // Пока шторка закрывается, поля не должны «воскресить» закрытый редактор.
            if model.editor?.id == value.id { model.editor = value }
        }
    }

    private var task: RoomTask? {
        if case .edit(let task) = model.editor?.mode { task } else { nil }
    }

    private var canEditAll: Bool {
        task.map(model.canEditAll) ?? true
    }

    private var canSave: Bool {
        guard let editor = model.editor else { return false }
        if editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving { return false }
        return !(editor.isCreate && model.isEncrypted && !editor.allowUnencrypted)
    }

    private var today: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(SL10n.roomTasksFieldTitle, text: editor.title, axis: .vertical)
                        .lineLimit(1...3)
                    TextField(SL10n.roomTasksFieldDescription, text: editor.description, axis: .vertical)
                        .lineLimit(3...10)
                }
                .disabled(!canEditAll)

                Section {
                    Picker(SL10n.roomTasksFieldAssignee, selection: editor.assignee) {
                        Text(SL10n.roomTasksUnassigned).tag(String?.none)
                        ForEach(model.sortedMembers) { member in
                            Text(model.memberName(member.id) ?? member.name).tag(Optional(member.id))
                        }
                    }
                    .disabled(!canEditAll)
                    Toggle(SL10n.roomTasksFieldDue, isOn: editor.hasDueDate)
                        .disabled(!canEditAll)
                    if model.editor?.hasDueDate == true {
                        DatePicker(SL10n.roomTasksFieldDue, selection: editor.dueDate,
                                   in: (model.editor?.minimumDate ?? today)...today.addingTimeInterval(5 * 365 * 86400),
                                   displayedComponents: .date)
                            .disabled(!canEditAll)
                    }
                    if let task {
                        if task.isLinked {
                            LabeledContent(SL10n.roomTasksFieldStatus, value: task.trackitStateName ?? task.status.title)
                        } else {
                            Picker(SL10n.roomTasksFieldStatus, selection: editor.status) {
                                ForEach(RoomTask.Status.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .disabled(!model.canEditStatus(task))
                        }
                    }
                }

                if !model.projects.isEmpty, model.editor?.isCreate == true || (task.map { !$0.isLinked && model.canEditAll($0) } ?? false) {
                    Section {
                        Picker(SL10n.roomTasksFieldProject, selection: editor.projectID) {
                            Text(SL10n.roomTasksNoProject).tag(String?.none)
                            ForEach(model.projects) { project in
                                Text(project.identifier.isEmpty ? project.name : "\(project.identifier) — \(project.name)").tag(Optional(project.id))
                            }
                        }
                    } footer: {
                        if task != nil, model.editor?.projectID != nil { Text(SL10n.roomTasksSendToTrackit) }
                    }
                }

                if let task, task.isLinked, let url = task.trackitURL {
                    Section {
                        Button { openURL(url) } label: { Label(task.trackitKey.map { "\(SL10n.roomTasksOpenInTrackit) · \($0)" } ?? SL10n.roomTasksOpenInTrackit, systemImage: "arrow.up.right.square") }
                    }
                }

                basisSection

                if model.editor?.isCreate == true, model.isEncrypted {
                    Section {
                        Toggle(SL10n.roomTasksUnencryptedConsent, isOn: editor.allowUnencrypted)
                    } footer: {
                        Text(SL10n.roomTasksUnencryptedNotice)
                    }
                }

                if let error = model.editorError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            // Шторка выбора — на уровне окна: вложенная в секцию формы закрывала само окно задачи.
            .sheet(isPresented: $showsMessagePicker) {
                if let editor = model.editor {
                    RoomTaskMessagePicker(candidates: editor.candidates, selected: Set(editor.basis.map(\.eventID))) { model.setBasis($0) }
                }
            }
            .navigationTitle(model.editor?.isCreate == true ? SL10n.roomTasksNew : SL10n.roomTasksEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { model.editor = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button(model.editor?.isCreate == true ? SL10n.roomTasksCreate : L10n.actionSave) { Task { await model.save() } }
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var basisSection: some View {
        if let editor = model.editor, editor.isCreate, !editor.basis.isEmpty || editor.candidates.count > 1 {
            Section(String(format: SL10n.roomTasksBasis, editor.basis.count)) {
                ForEach(editor.basis) { item in
                    Text(item.label).lineLimit(3).font(.callout)
                }
                .onDelete { offsets in
                    let removed = Set(offsets.map { editor.basis[$0].eventID })
                    model.setBasis(Set(editor.basis.map(\.eventID)).subtracting(removed))
                }
                if editor.candidates.count > 1 {
                    Button { showsMessagePicker = true } label: { Label(SL10n.roomTasksPickMessages, systemImage: "checklist") }
                }
            }
        } else if let task, !task.basis.isEmpty {
            Section(String(format: SL10n.roomTasksBasis, task.basis.count)) {
                ForEach(task.basis) { item in
                    Button { model.open(item.eventID) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text([item.sender.flatMap { model.memberName($0) }, item.ts.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.quote ?? SL10n.savedMessagesOpenSource).lineLimit(3).font(.callout)
                        }
                    }
                }
            }
        }
    }
}

/// Выбор нескольких сообщений-оснований (на вебе — режим выбора в ленте).
private struct RoomTaskMessagePicker: View {
    let candidates: [RoomTaskDraft.BasisMessage]
    @State var selected: Set<String>
    let done: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates) { item in
                let isOn = selected.contains(item.eventID)
                Button {
                    if isOn { selected.remove(item.eventID) } else if selected.count < RoomTaskDraft.basisLimit { selected.insert(item.eventID) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                        Text(item.line).lineLimit(4).font(.callout).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(isOn ? Color.accentColor.opacity(0.08) : nil)
            }
            .navigationTitle(String(format: SL10n.roomTasksSelected, selected.count))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if selected.count >= RoomTaskDraft.basisLimit {
                    Text(SL10n.roomTasksPickLimit).font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone) { done(selected); dismiss() }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// Отметки оснований отдельно от состояния ленты: строки перерисовываются только при их обновлении.
@MainActor
final class RoomTaskBasisStore: ObservableObject {
    @Published var marks: [String: RoomTaskBasisMark] = [:]
}

/// Значок под строкой ленты, если сообщение — основание задачи.
struct RoomTaskBasisBadgeHost: View {
    @ObservedObject var store: RoomTaskBasisStore
    let eventID: String
    let open: (Int) -> Void

    var body: some View {
        if let mark = store.marks[eventID] {
            RoomTaskBasisBadge(mark: mark) { open(mark.taskID) }
        }
    }
}

/// Значок «Задача» под сообщением-основанием.
struct RoomTaskBasisBadge: View {
    let mark: RoomTaskBasisMark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(mark.title.map { "\(SL10n.roomTasksBadge): \($0)" } ?? SL10n.roomTasksBadge, systemImage: "checklist")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mark.title.map { "\(SL10n.roomTasksBadge): \($0)" } ?? SL10n.roomTasksBadge)
    }
}

final class RoomTasksCoordinator: CoordinatorProtocol {
    private let model: RoomTasksModel

    @MainActor
    init(roomProxy: JoinedRoomProxyProtocol, clientProxy: ClientProxyProtocol, entry: RoomTasksEntry, openEvent: @escaping (String) -> Void) {
        model = RoomTasksModel(roomProxy: roomProxy, clientProxy: clientProxy, entry: entry, openEvent: openEvent)
    }

    func toPresentable() -> AnyView {
        AnyView(RoomTasksScreen(model: model))
    }
}
