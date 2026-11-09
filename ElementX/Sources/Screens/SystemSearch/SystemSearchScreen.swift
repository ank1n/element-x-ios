// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SystemSearchScreen: View {
    @StateObject private var model: SystemSearchViewModel
    let open: (SystemSearchTarget, String?) -> Void
    @State private var filters = false
    @State private var senders = false
    @State private var peopleExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.stalkBottomBarInset) private var bottomBarInset
    @Environment(\.setStalkBottomBarHidden) private var setBottomBarHidden
    @State private var screenVisible = false
    @State private var historyNow = Date()
    private let rooms: () -> [(id: String, name: String)]
    private let mediaProvider: MediaProviderProtocol?

    init(client: ClientProxyProtocol, mediaProvider: MediaProviderProtocol? = nil, isCallActive: @escaping () -> Bool = { false }, open: @escaping (SystemSearchTarget, String?) -> Void) {
        _model = StateObject(wrappedValue: SystemSearchViewModel(client: client, isCallActive: isCallActive))
        self.open = open
        self.mediaProvider = mediaProvider
        rooms = { client.staticRoomSummaryProvider.roomListPublisher.value.map { ($0.id, $0.name) } }
    }

    init(model: SystemSearchViewModel, open: @escaping (SystemSearchTarget, String?) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.open = open
        mediaProvider = nil
        rooms = { [] }
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
            if model.conditions.mode == "smart" { Text(String(format: NSLocalizedString("stalk_search_smart_topic", comment: "Smart search topic"), model.conditions.topic ?? model.conditions.query)).font(.caption).padding(4) }
            if model.conditions.pendingSenderQuery != nil {
                Button("Уточнить отправителя") { senders = true }.padding(8)
            }
            if let sender = model.conditions.senderName { Text(String(format: NSLocalizedString("stalk_search_sender_label", comment: "Selected search sender"), sender)).font(.caption) }
            if model.recording {
                HStack {
                    Text("Запись запроса… Нажмите стоп, чтобы вставить текст.").font(.footnote)
                    Button("Отменить") { model.cancelVoice() }
                }.padding(8)
            }
            if model.transcribing { ProgressView("Распознаём запрос…").padding(8) }
            if let voiceNotice = model.voiceNotice { Text(voiceNotice).font(.footnote).padding(8) }
            if let error = model.error { Text(error).foregroundStyle(.red).padding(8) }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(8) }
            if model.hasSubmittedSearch, !model.facets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(String(format: NSLocalizedString("stalk_search_all_count", comment: "All search result count"), Int64(model.total))) { model.browse(nil) }.buttonStyle(.bordered).tint(model.viewType == nil ? StalkTheme.accent : .secondary).disabled(model.loading)
                        ForEach(model.facets) { facet in
                            Button(String(format: NSLocalizedString("stalk_search_facet_count", comment: "Search result type and count"), Self.typeName(facet.entity_type), Int64(facet.count))) { model.browse(facet.entity_type) }
                                .buttonStyle(.bordered).tint(model.viewType == facet.entity_type ? StalkTheme.accent : .secondary).disabled(model.loading)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            List {
                if !model.hasSubmittedSearch {
                    savedSearches
                } else {
                    if model.viewType == nil, !model.people.isEmpty {
                        Section(String(format: NSLocalizedString("stalk_search_people_count", comment: "People and direct chat result count"), model.people.count > 30 ? "30+" : String(model.people.count))) {
                            ForEach(Array(model.people.prefix(peopleExpanded ? 30 : 6))) { person in
                                Button { open(person.target, person.name) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(person.name).foregroundStyle(.primary)
                                        Text(person.dmRoomID == nil ? person.id : NSLocalizedString("Личный чат", comment: "Direct chat search result")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                            if model.people.count > 6 {
                                Button(peopleExpanded ? NSLocalizedString("Свернуть", comment: "Collapse people search results") : String(format: NSLocalizedString("stalk_search_show_more_count", comment: "Additional people search result count"), Int64(min(model.people.count, 30) - 6))) { peopleExpanded.toggle() }
                            }
                            if let note = model.peopleNotice { Text(note).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    ForEach(model.hits) { hit in
                        Button {
                            if let target = hit.target { open(target, hit.isFileResult ? hit.fileDisplayName : hit.title ?? hit.meta?.filename) }
                        } label: {
                            SystemSearchResultRow(hit: hit, mediaProvider: mediaProvider, profileLoader: { await model.authorProfile(for: $0) })
                        }.buttonStyle(.plain).disabled(hit.target == nil)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if model.hasMore, !model.loading { Button("Показать ещё") { model.more() } }
                    if model.hits.isEmpty, !model.loading, model.error == nil, model.conditions.pendingSenderQuery == nil, model.viewType != nil || model.people.isEmpty {
                        Text(model.conditions.canSearch ? NSLocalizedString("По этим условиям ничего не найдено. Нажмите «Найти» для нового запроса.", comment: "System search placeholder") : NSLocalizedString("Введите запрос или выберите условия поиска.", comment: "System search placeholder")).foregroundStyle(.secondary)
                    }
                }
            }.listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            queryComposer
                .padding(.bottom, bottomBarInset)
                .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle(NSLocalizedString("stalk_search_app_title", comment: "Search application"))
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.hasSubmittedSearch {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.showHistory() } label: { Image(systemName: "clock") }
                        .accessibilityLabel(NSLocalizedString("История поиска", comment: "Search history"))
                    pinAction
                }
            }
        }
        .onChange(of: model.conditions.query) { peopleExpanded = false }
        .onChange(of: scenePhase) { if scenePhase != .active { model.cancelVoice() } else { historyNow = Date() } }
        .onSubmit(of: .search) { submitSearch() }
        .onAppear { screenVisible = true; historyNow = Date(); model.resume() }
        .onDisappear { screenVisible = false; setBottomBarHidden(false); model.stop() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            if screenVisible, scenePhase == .active { historyNow = now }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if screenVisible { setBottomBarHidden(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if screenVisible { setBottomBarHidden(false) }
        }
        .sheet(isPresented: $filters) { filterSheet }
        .sheet(isPresented: $senders) { senderSheet }
    }

    private var queryComposer: some View {
        VStack(spacing: 10) {
            StalkComposerTextField(placeholder: NSLocalizedString("stalk_search_query_placeholder", value: "Messages, files, meetings, tasks", comment: "System search input"),
                                   text: Binding(get: { model.conditions.query }, set: { model.updateQuery($0) }),
                                   isDisabled: model.transcribing, showsClearButton: true, minimumHeight: 56)
                .submitLabel(.search)
            HStack(spacing: 8) {
                filterAction
                Spacer(minLength: 0)
                Button { submitSearch(smart: true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .symbolEffect(.pulse, options: .repeating, isActive: model.smartSearchRunning)
                        Text("Айлок")
                    }.font(.footnote.weight(.semibold))
                        .foregroundStyle(model.smartSearchRunning ? Color.accentColor : Color.primary)
                        .padding(.horizontal, 10).frame(minHeight: 44)
                        .background(AilockPalette.skySoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.loading || model.recording || model.transcribing || model.conditions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(NSLocalizedString("stalk_search_via_ailock", value: "Search with Ailock", comment: "Explicit AI search"))
                voiceAction
                Button { submitSearch() } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .foregroundStyle(.white).frame(width: 36, height: 36)
                        .background(Color.accentColor, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.loading || model.recording || model.transcribing || !model.conditions.valid || !model.conditions.canSearch)
                .accessibilityLabel(NSLocalizedString("Найти", comment: "Run system search"))
            }
            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.smartSearchRunning
                        ? (model.planning ? NSLocalizedString("stalk_search_planning", value: "Ailock is understanding your request…", comment: "AI search progress")
                            : NSLocalizedString("stalk_search_smart_loading", value: "Searching with Ailock…", comment: "AI search progress"))
                        : NSLocalizedString("stalk_search_loading", value: "Searching…", comment: "Search progress"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : AilockPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(colorScheme == .dark ? Color(.separator) : AilockPalette.border, lineWidth: 1) }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var savedSearches: some View {
        if !model.pinned.isEmpty {
            Section(NSLocalizedString("Закреплённые", comment: "Pinned searches")) {
                ForEach(Array(model.pinned.enumerated()), id: \.offset) { _, value in
                    savedSearchRow(value, symbol: "star.fill")
                }
            }
        }
        Section {
            ForEach(SystemSearchHistorySection.grouped(model.recent.filter { value in !model.pinned.contains { $0 == value } },
                                                       date: { model.historySummary(for: $0)?.updatedAt }, now: historyNow)) { section in
                Text(section.period.title)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                ForEach(Array(section.queries.enumerated()), id: \.offset) { _, value in
                    savedSearchRow(value, symbol: "clock")
                }
            }
            if model.recent.isEmpty, model.pinned.isEmpty {
                Text(NSLocalizedString("stalk_search_history_empty", value: "Your recent searches will appear here", comment: "Empty search history"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: {
            HStack {
                Text(NSLocalizedString("Недавние", comment: "Recent searches"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !model.recent.isEmpty {
                    Button(NSLocalizedString("Очистить", comment: "Clear recent searches")) { model.forgetRecent() }
                }
            }.textCase(nil)
        }
    }

    private func savedSearchRow(_ value: SystemSearchConditions, symbol: String) -> some View {
        Button { model.restore(value) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(value.query.isEmpty ? NSLocalizedString("stalk_search_saved_conditions", value: "Search by filters", comment: "Saved search without text") : value.query)
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let summary = model.historySummary(for: value) {
                        HStack(spacing: 6) {
                            Text(String(format: NSLocalizedString("stalk_search_history_total", value: "Found: %lld", comment: "Last search result total"), Int64(summary.total)))
                            if summary.isPartial {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(NSLocalizedString("stalk_search_history_partial", value: "Partial results", comment: "Some search sources were unavailable"))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if !summary.facets.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                                ForEach(summary.facets) { facet in
                                    Label("\(Self.typeName(facet.type)) · \(facet.count)", systemImage: Self.historyIcon(facet.type))
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.06), in: Capsule())
                                }
                            }
                        }
                    } else {
                        Text(NSLocalizedString("stalk_search_history_unknown", value: "Run again to see result counts", comment: "History entry predates result summaries"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(colorScheme == .dark ? Color(.secondarySystemBackground) : AilockPalette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(colorScheme == .dark ? Color(.separator) : AilockPalette.border, lineWidth: 1) }
        }.buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private static func historyIcon(_ type: String) -> String {
        switch type {
        case "message", "comment": "bubble.left"
        case "attachment", "disk_doc": "doc"
        case "meeting": "calendar"
        case "transcript", "voice_transcript": "waveform"
        case "task": "checklist"
        case "page": "doc.text"
        default: "bubble.left.and.bubble.right"
        }
    }

    private var voiceAction: some View {
        Button { model.toggleVoice() } label: {
            Image(systemName: model.recording ? "stop.circle.fill" : "mic")
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(model.transcribing)
            .accessibilityLabel(model.recording ? NSLocalizedString("Остановить запись", comment: "Stop voice query and search") : NSLocalizedString("Продиктовать запрос", comment: "Dictate search query"))
    }

    private var filterAction: some View {
        Button { filters = true } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("Условия поиска")
    }

    private var pinAction: some View {
        Button { model.pin() } label: {
            Image(systemName: model.pinned.contains { $0.query == model.conditions.query } ? "star.fill" : "star")
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(model.conditions.query.count < 2).accessibilityLabel("Закрепить запрос с условиями")
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
                    if model.conditions.sender != nil || model.conditions.pendingSenderQuery != nil { Button("Любой отправитель") { model.conditions.sender = nil; model.conditions.senderName = nil; model.conditions.pendingSenderQuery = nil } }
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

    private var senderSheet: some View {
        NavigationStack {
            List {
                if let note = model.senderNotice { Text(note).font(.footnote).foregroundStyle(.secondary) }
                ForEach(model.senders) { person in
                    Button {
                        model.conditions.pendingSenderQuery = nil; model.conditions.sender = person.id; model.conditions.senderName = person.name; senders = false; model.search()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(person.name)
                            Text(person.id.hasPrefix("@meet-") ? String(format: NSLocalizedString("stalk_search_guest_label", comment: "Guest search sender"), person.id) : person.id).font(.caption).foregroundStyle(.secondary)
                        }
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
