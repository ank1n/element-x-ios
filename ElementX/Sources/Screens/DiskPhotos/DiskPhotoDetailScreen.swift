// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DiskPhotoDetailScreen: View {
    let photo: DiskPhoto
    let service: DiskPhotoService
    let paused: Bool
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = false
    @State private var editor = false
    @State private var preview: MediaPreviewItem?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @StateObject private var temporaryFiles = StalkTemporaryFiles()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 320 * zoom)
                            .gesture(MagnificationGesture().onChanged { zoom = min(8, max(1, lastZoom * $0)) }.onEnded { _ in lastZoom = zoom })
                            .onTapGesture(count: 2) { zoom = zoom == 1 ? 3 : 1; lastZoom = zoom }
                    }
                }
                if loading { ProgressView() }
                if !photo.canDownload { Text("Доступен только просмотр миниатюры. Скачивание и создание копии запрещены владельцем.").font(.caption).foregroundStyle(.secondary) }
                if paused { Text("Новые загрузки приостановлены на время звонка.").font(.caption) }
                if let error { Text(error).foregroundStyle(.red).padding() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.name).font(.headline)
                    Text(photo.exif?.takenAt.map { String(format: NSLocalizedString("stalk_photos_taken_at", comment: "Photo capture date"), $0) } ?? NSLocalizedString("Дата съёмки неизвестна; используется дата добавления.", comment: "Photo capture date unavailable")).font(.caption).foregroundStyle(.secondary)
                    if let camera = photo.exif?.model { Text(camera).font(.caption) }
                }.padding(.horizontal)
                HStack {
                    Button("Открыть оригинал") { Task { await original() } }.disabled(loading || paused || !photo.canDownload)
                    Button("Редактировать копию") { editor = true }.disabled(paused || !photo.canDownload || image == nil)
                }.padding()
            }
            .navigationTitle("Просмотр фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
            .task(id: paused) {
                guard !paused else { return }
                loading = true
                defer { loading = false }
                if image == nil { image = try? await service.thumbnail(photo) }
                guard photo.canDownload, photo.mimetype.hasPrefix("image/") else { return }
                do { image = try await service.image(photo) }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .interactiveQuickLook(item: $preview, allowEditing: false)
            .sheet(isPresented: $editor) { DiskPhotoEditor(photo: photo, service: service, saved: saved) }
        }
    }

    private func original() async {
        loading = true
        defer { loading = false }
        do {
            let url = try await service.originalFile(photo)
            temporaryFiles.urls.append(url)
            preview = MediaPreviewItem(file: .unmanaged(url: url), title: photo.name)
        } catch { self.error = error.localizedDescription }
    }
}

struct DiskPhotoAlbumAccessScreen: View {
    let album: DiskPhotoAlbum
    let service: DiskPhotoService
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var members: [DiskPhotoAlbumMember] = []
    @State private var user = ""
    @State private var role = "read"
    @State private var error: String?
    @State private var busy = false

    private func roleName(_ role: String) -> String {
        [
            "read": NSLocalizedString("Чтение", comment: "Photo album access role"),
            "add": NSLocalizedString("Добавление своих фото", comment: "Photo album access role"),
            "manage": NSLocalizedString("Управление альбомом", comment: "Photo album access role"),
            "owner": NSLocalizedString("Владелец", comment: "Photo album access role")
        ][role] ?? role
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                Section(album.name) {
                    ForEach(members) { member in
                        HStack { Text(member.display ?? member.user); Spacer(); Text(roleName(member.role)).foregroundStyle(.secondary) }
                            .swipeActions { Button("Отозвать", role: .destructive) { Task { await grant(member.user, role: nil) } } }
                    }
                }
                if album.isOwner {
                    Section("Добавить или изменить доступ") {
                        TextField("@пользователь:сервер", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Право", selection: $role) { Text("Чтение").tag("read"); Text("Добавление своих фото").tag("add"); Text("Управление альбомом").tag("manage") }
                        Button("Сохранить доступ") { Task { await grant(user.trimmingCharacters(in: .whitespacesAndNewlines), role: role) } }.disabled(busy || !user.hasPrefix("@"))
                        Text("Отзыв доступа к альбому не изменяет исходные файлы. Ранее выданные отдельные права на файл сохраняются.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Участники альбома").toolbar { Button(L10n.actionClose) { dismiss() } }
            .task { await reload() }
        }
    }

    private func reload() async {
        do { members = try await service.members(album.id) } catch { self.error = error.localizedDescription }
    }

    private func grant(_ user: String, role: String?) async {
        guard album.isOwner else { return }
        busy = true; defer { busy = false }
        do { try await service.grant(album.id, user: user, role: role); await reload(); changed() }
        catch { self.error = error.localizedDescription }
    }
}
