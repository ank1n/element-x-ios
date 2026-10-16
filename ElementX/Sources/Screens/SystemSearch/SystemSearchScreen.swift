// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SystemSearchScreen: View {
    @StateObject private var model: SystemSearchViewModel
    let open: (SystemSearchTarget, String?) -> Void
    @State private var filters = false
    @State private var history = false
    @State private var senders = false
    private let rooms: () -> [(id: String, name: String)]

    init(client: ClientProxyProtocol, open: @escaping (SystemSearchTarget, String?) -> Void) {
        _model = StateObject(wrappedValue: SystemSearchViewModel(client: client))
        self.open = open
        rooms = { client.staticRoomSummaryProvider.roomListPublisher.value.map { ($0.id, $0.name) } }
    }

    static func typeName(_ type: String) -> String {
        [
            "message": NSLocalizedString("Сообщения", comment: "System search result type"),
            "room_name": NSLocalizedString("Комнаты", comment: "System search result type"),
            "room_topic": NSLocalizedString("Темы комнат", comment: "System search result type"),
            "task": NSLocalizedString("Задачи", comment: "System search result type"),
            "comment": NSLocalizedString("Комментарии", comment: "System search result type"),
            "page": NSLocalizedString("Страницы", comment: "System search result type"),
            "disk_doc": NSLocalizedString("Документы Диска", comment: "System search result type"),
            "attachment": NSLocalizedString("Вложения", comment: "System search result type"),
            "meeting": NSLocalizedString("Встречи", comment: "System search result type"),
            "transcript": NSLocalizedString("Записи встреч", comment: "System search result type"),
            "voice_transcript": NSLocalizedString("Голосовые сообщения", comment: "System search result type")
        ][type] ?? type
    }

    static func formatName(_ format: String) -> String {
        [
            "presentation": NSLocalizedString("Презентации", comment: "Search file format"),
            "spreadsheet": NSLocalizedString("Таблицы", comment: "Search file format"),
            "document": NSLocalizedString("Документы", comment: "Search file format"),
            "pdf": "PDF",
            "image": NSLocalizedString("Изображения", comment: "Search file format"),
            "archive": NSLocalizedString("Архивы", comment: "Search file format"),
            "text": NSLocalizedString("Текст", comment: "Search file format")
        ][format] ?? format
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Найти") { submitSearch() }.buttonStyle(.borderedProminent)
                Button("Умный поиск") { submitSearch(smart: true) }.disabled(model.loading || model.conditions.query.isEmpty)
                Spacer()
                Button { filters = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("Условия поиска")
                Button { history = true } label: { Image(systemName: "clock") }.accessibilityLabel("История и закреплённые")
                Button { model.pin() } label: {
                    Image(systemName: model.pinned.contains { $0.query == model.conditions.query } ? "star.fill" : "star")
                }.disabled(model.conditions.query.count < 2).accessibilityLabel("Закрепить запрос с условиями")
            }.padding(.horizontal).padding(.vertical, 8)
            if model.conditions.mode == "smart" { Text(String(format: NSLocalizedString("stalk_search_smart_topic", comment: "Smart search topic"), model.conditions.topic ?? model.conditions.query)).font(.caption).padding(4) }
            if let sender = model.conditions.senderName { Text(String(format: NSLocalizedString("stalk_search_sender_label", comment: "Selected search sender"), sender)).font(.caption) }
            if let error = model.error { Text(error).foregroundStyle(.red).padding(8) }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(8) }
            if !model.facets.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        Button(String(format: NSLocalizedString("stalk_search_all_count", comment: "All search result count"), Int64(model.total))) { model.browse(nil) }.buttonStyle(.bordered).tint(model.viewType == nil ? StalkTheme.accent : .secondary)
                        ForEach(model.facets) { facet in
                            Button(String(format: NSLocalizedString("stalk_search_facet_count", comment: "Search result type and count"), Self.typeName(facet.entity_type), Int64(facet.count))) { model.browse(facet.entity_type) }
                                .buttonStyle(.bordered).tint(model.viewType == facet.entity_type ? StalkTheme.accent : .secondary)
                        }
                    }.padding(.horizontal)
                }
            }
            List {
                ForEach(model.hits) { hit in
                    Button {
                        if let target = hit.target { open(target, hit.title ?? hit.meta?.filename) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(Self.typeName(hit.facetKind)).font(.caption).foregroundStyle(StalkTheme.accent)
                                Spacer()
                                if hit.by == "sense" || hit.by == "both" { Text("По смыслу").font(.caption).foregroundStyle(.secondary) }
                            }
                            if let title = hit.title { Text(title).font(.headline).foregroundStyle(.primary) }
                            Text(hit.text).lineLimit(5).foregroundStyle(.secondary)
                            if let room = hit.meta?.room { Text(room).font(.caption) }
                            if hit.target == nil { Text("Переход к этому объекту недоступен").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain).disabled(hit.target == nil || model.loading)
                }
                if model.loading { ProgressView().frame(maxWidth: .infinity) }
                if model.hasMore, !model.loading { Button("Показать ещё") { model.more() } }
                if model.hits.isEmpty, !model.loading, model.error == nil {
                    Text(model.conditions.canSearch ? NSLocalizedString("По этим условиям ничего не найдено. Нажмите «Найти» для нового запроса.", comment: "System search placeholder") : NSLocalizedString("Введите запрос или выберите условия поиска.", comment: "System search placeholder")).foregroundStyle(.secondary)
                }
            }.listStyle(.plain)
        }
        .navigationTitle("Поиск по системе")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: Binding(get: { model.conditions.query }, set: { model.updateQuery($0) }), placement: .navigationBarDrawer(displayMode: .always), prompt: "Сообщения, файлы, встречи, задачи")
        .onSubmit(of: .search) { submitSearch() }
        .onAppear { model.resume() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $filters) { filterSheet }
        .sheet(isPresented: $history) { historySheet }
        .sheet(isPresented: $senders) { senderSheet }
    }

    private func submitSearch(smart: Bool = false) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        model.search(smart: smart)
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Типы результатов") {
                    ForEach(SystemSearchConditions.allowedTypes, id: \.self) { type in
                        Toggle(Self.typeName(type), isOn: Binding(get: { model.conditions.types.contains(type) }, set: { enabled in
                            if enabled { model.conditions.types.append(type) } else { model.conditions.types.removeAll { $0 == type } }
                        }))
                    }
                }
                Section("Период и формат") {
                    Picker("Период", selection: $model.conditions.period) {
                        Text("Всё время").tag("all"); Text("Неделя").tag("week"); Text("Месяц").tag("month"); Text("Год").tag("year"); Text("Диапазон").tag("range")
                    }
                    if model.conditions.period == "range" {
                        TextField("С даты (yyyy-MM-dd)", text: $model.conditions.rangeFrom)
                        TextField("По дату включительно (yyyy-MM-dd)", text: $model.conditions.rangeTo)
                    }
                    Picker("Формат", selection: Binding(get: { model.conditions.format ?? "" }, set: { model.conditions.format = $0.isEmpty ? nil : $0 })) {
                        Text("Любой").tag("")
                        ForEach(SystemSearchConditions.allowedFormats, id: \.self) { Text(Self.formatName($0)).tag($0) }
                    }
                    Toggle("Сначала новые", isOn: Binding(get: { model.conditions.sort == "newest" }, set: { model.conditions.sort = $0 ? "newest" : nil }))
                    Toggle("С адресом email", isOn: Binding(get: { model.conditions.has.contains("email") }, set: { model.conditions.has = $0 ? ["email"] : [] }))
                }
                Section("Отправитель и комнаты") {
                    Button(model.conditions.senderName ?? NSLocalizedString("Выбрать отправителя", comment: "System search placeholder")) { filters = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { senders = true } }
                    if model.conditions.sender != nil { Button("Любой отправитель") { model.conditions.sender = nil; model.conditions.senderName = nil } }
                    ForEach(rooms(), id: \.id) { room in
                        Toggle(room.name, isOn: Binding(get: { model.conditions.roomIds.contains(room.id) }, set: { enabled in
                            if enabled { model.conditions.roomIds.append(room.id) } else { model.conditions.roomIds.removeAll { $0 == room.id } }
                        }))
                    }
                }
            }
            .navigationTitle("Условия поиска")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Сбросить") { let phrase = model.conditions.query; model.conditions = .init(); model.conditions.query = phrase } }
                ToolbarItem(placement: .confirmationAction) { Button("Применить") { filters = false; model.search() } }
            }
        }
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                Section("Закреплённые с условиями") {
                    ForEach(Array(model.pinned.enumerated()), id: \.offset) { _, value in
                        Button { model.restore(value); history = false } label: { Label(value.query, systemImage: "star.fill") }
                    }
                }
                Section("Недавние") {
                    ForEach(Array(model.recent.filter { value in !model.pinned.contains { $0.query == value.query } }.enumerated()), id: \.offset) { _, value in
                        Button(value.query) { model.restore(value); history = false }
                    }
                    Button("Очистить недавние", role: .destructive) { model.forgetRecent() }
                }
            }.navigationTitle("История поиска").toolbar { Button(L10n.actionClose) { history = false } }
        }
    }

    private var senderSheet: some View {
        NavigationStack {
            List(model.senders, id: \.id) { person in
                Button {
                    model.conditions.sender = person.id; model.conditions.senderName = person.name; senders = false; model.search()
                } label: {
                    VStack(alignment: .leading) {
                        Text(person.name)
                        Text(person.id.hasPrefix("@meet-") ? String(format: NSLocalizedString("stalk_search_guest_label", comment: "Guest search sender"), person.id) : person.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $model.senderQuery, prompt: "Имя или логин")
            .onChange(of: model.senderQuery) { model.lookupSenders() }
            .task { model.lookupSenders() }
            .navigationTitle("Отправитель").toolbar { Button(L10n.actionClose) { senders = false } }
        }
    }
}
