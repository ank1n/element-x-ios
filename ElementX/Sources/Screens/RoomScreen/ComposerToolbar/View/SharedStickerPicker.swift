// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct SharedStickerPicker: View {
    @ObservedObject var service: SharedStickerService
    let mediaProvider: MediaProviderProtocol?
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "recent"
    @State private var query = ""

    private var items: [SharedSticker] {
        let all = service.packs.flatMap(\.items)
        let search = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            return all.filter { $0.label.localizedStandardContains(search) }
        }
        if selected == "recent" {
            return service.preferences.recent.compactMap { mxc in all.first { $0.mxc == mxc } }
        }
        return service.packs.first { $0.id == selected }?.items ?? []
    }

    private var orderedPacks: [SharedStickerPack] {
        service.packs.enumerated().sorted {
            let a = service.preferences.favorites.contains($0.element.id)
            let b = service.preferences.favorites.contains($1.element.id)
            return a == b ? $0.offset < $1.offset : a
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView(.horizontal) {
                    HStack {
                        Button { selected = "recent"; query = "" } label: {
                            Label(String(localized: "stalk_stickers_recent", defaultValue: "Недавние"), systemImage: "clock")
                        }
                        .buttonStyle(.bordered)
                        .tint(selected == "recent" ? StalkTheme.accent : .secondary)
                        ForEach(orderedPacks) { pack in
                            Button { selected = pack.id; query = "" } label: {
                                HStack {
                                    if service.preferences.favorites.contains(pack.id) { Image(systemName: "star.fill") }
                                    Text(pack.title)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(selected == pack.id ? StalkTheme.accent : .secondary)
                            .contextMenu {
                                Button {
                                    service.toggleFavorite(pack.id)
                                } label: {
                                    Label(service.preferences.favorites.contains(pack.id)
                                        ? String(localized: "stalk_stickers_unfavorite", defaultValue: "Убрать из избранного")
                                        : String(localized: "stalk_stickers_favorite", defaultValue: "В избранное"), systemImage: "star")
                                }
                            }
                        }
                    }
                }
                if let error = service.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button(L10n.actionRetry) { Task { await service.load() } }
                }
                if service.syncFailed {
                    Text(String(localized: "stalk_stickers_sync_error", defaultValue: "Настройки сохранены на устройстве. Синхронизация будет повторена."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if service.loading, service.packs.isEmpty { ProgressView() }
                if items.isEmpty, !service.loading {
                    ContentUnavailableView(String(localized: "stalk_stickers_empty", defaultValue: "Нет стикеров"), systemImage: "face.smiling",
                                           description: Text(selected == "recent" && query.isEmpty
                                               ? String(localized: "stalk_stickers_recent_hint", defaultValue: "Здесь появятся 10 последних отправленных стикеров. Выберите набор выше.")
                                               : String(localized: "stalk_stickers_empty_hint", defaultValue: "Попробуйте другой запрос или набор.")))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 16) {
                            ForEach(items, id: \.mxc) { item in
                                Button {
                                    Task { if await service.send(item) { dismiss() } }
                                } label: {
                                    if let builtin = SharedStickerPack.capybaras.items.first(where: { $0.mxc == item.mxc }) {
                                        Image("stalk-capy-" + builtin.id).resizable().scaledToFit().frame(width: 85, height: 85)
                                    } else if let url = URL(string: item.thumbnailMxc ?? item.mxc),
                                              let source = try? MediaSourceProxy(url: url, mimeType: item.thumbnailMxc == nil ? item.mimetype : "image/png") {
                                        LoadableImage(mediaSource: source, mediaType: .generic, size: .init(width: 96, height: 96), mediaProvider: mediaProvider) {
                                            ProgressView()
                                        }
                                        .frame(width: 85, height: 85)
                                        .clipped()
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.label)
                                .disabled(service.sending)
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle(String(localized: "stalk_stickers_title", defaultValue: "Стикеры"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(String(localized: "stalk_stickers_search", defaultValue: "Поиск стикеров")))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
            .task { selected = "recent"; await service.load() }
        }
    }
}
