// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DiskPhotoDetailScreen: View {
    let initialPhoto: DiskPhoto
    let sequence: [DiskPhoto]
    let mediaProvider: MediaProviderProtocol?
    let openMatrix: ((DiskFile) -> Void)?
    let resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)?
    @State private var currentID: String
    @State private var playback = DiskPhotoSlideshow()
    private var slideshow: Bool {
        playback.playing
    }

    private var slideshowPhotoID: String? {
        playback.canAdvance(photo.id) && image != nil && !loading && error == nil && !paused && !editor && !originalLoading && preview == nil && scenePhase == .active ? photo.id : nil
    }

    @Environment(\.scenePhase) private var scenePhase
    private var photo: DiskPhoto {
        sequence.first { $0.id == currentID } ?? initialPhoto
    }

    private var editor: Bool {
        editingPhoto != nil
    }

    private var canEditPhoto: Bool {
        guard image != nil, DiskPhotoMatrixMedia.supportsEditing(mimetype: photo.mimetype) else { return false }
        if photo.matrixFile != nil { return matrixSourceResolved && mediaProvider != nil && resolveMatrixSource != nil }
        return photo.canDownload
    }

    private var index: Int {
        sequence.firstIndex { $0.id == photo.id } ?? 0
    }

    init(photo: DiskPhoto, service: DiskPhotoService, paused: Bool,
         resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)? = nil, saved: @escaping () -> Void) {
        self.init(photo: photo, service: service, paused: paused, saved: saved, sequence: [photo], resolveMatrixSource: resolveMatrixSource)
    }

    init(photo: DiskPhoto, service: DiskPhotoService, paused: Bool, saved: @escaping () -> Void,
         sequence: [DiskPhoto], mediaProvider: MediaProviderProtocol? = nil, openMatrix: ((DiskFile) -> Void)? = nil,
         resolveMatrixSource: ((DiskFile) async -> MediaSourceProxy?)? = nil) {
        initialPhoto = photo; self.sequence = sequence.contains(where: { $0.id == photo.id }) ? sequence : [photo] + sequence
        self.service = service; self.paused = paused; self.saved = saved
        self.mediaProvider = mediaProvider; self.openMatrix = openMatrix; self.resolveMatrixSource = resolveMatrixSource
        _currentID = State(initialValue: photo.id)
    }

    let service: DiskPhotoService
    let paused: Bool
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var matrixSourceResolved = false
    @State private var error: String?
    @State private var loading = false
    @State private var retryRevision = 0
    @State private var originalLoading = false
    @State private var editingPhoto: DiskPhoto?
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
                if loading || originalLoading { ProgressView() }
                if !photo.canDownload, photo.matrixFile == nil { Text("Доступен только просмотр миниатюры. Скачивание и создание копии запрещены владельцем.").font(.caption).foregroundStyle(.secondary) }
                if paused { Text("Новые загрузки приостановлены на время звонка.").font(.caption) }
                if let error { Text(error).foregroundStyle(.red).padding() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.name).font(.headline)
                    Text(photo.exif?.takenAt.map { String(format: NSLocalizedString("stalk_photos_taken_at", comment: "Photo capture date"), $0) } ?? NSLocalizedString("Дата съёмки неизвестна; используется дата добавления.", comment: "Photo capture date unavailable")).font(.caption).foregroundStyle(.secondary)
                    if let camera = photo.exif?.model { Text(camera).font(.caption) }
                }.padding(.horizontal)
                if let snippet = photo.snippet, !snippet.isEmpty { DiskPhotoSnippet(photo: photo).padding(.horizontal) }
                if let matrix = photo.matrixFile {
                    if image != nil, !matrixSourceResolved, !loading {
                        Text(NSLocalizedString("Редактирование недоступно: SDK не подтвердил доступ к исходному сообщению. Повторите загрузку или откройте фото в чате.", comment: "Matrix photo preview available without confirmed SDK editing access")).font(.caption).foregroundStyle(.secondary)
                    }
                    if error != nil || image == nil || !matrixSourceResolved, !loading {
                        Button("Повторить загрузку") { retryRevision += 1 }.disabled(paused || originalLoading)
                    }
                    Button("Открыть в чате") { openMatrix?(matrix) }.disabled(openMatrix == nil)
                }
                HStack {
                    Button("Открыть оригинал") { Task { await original() } }.disabled(loading || originalLoading || paused || (photo.matrixFile == nil ? !photo.canDownload : mediaProvider == nil))
                    Button("Редактировать копию") { playback.playing = false; editingPhoto = photo }.disabled(paused || loading || originalLoading || !canEditPhoto)
                }.padding()
                if sequence.count > 1 {
                    HStack {
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(NSLocalizedString("Предыдущее фото", comment: "Photo navigation")).disabled(index == 0 || editor || originalLoading)
                        Text("\(index + 1) / \(sequence.count)").font(.caption)
                            .accessibilityLabel(String(format: NSLocalizedString("stalk_photos_position", comment: "Photo position and total count"), Int64(index + 1), Int64(sequence.count)))
                        Button { move(1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel(NSLocalizedString("Следующее фото", comment: "Photo navigation")).disabled(index == sequence.count - 1 || editor || originalLoading)
                        Button(slideshow ? NSLocalizedString("Пауза", comment: "Pause photo slideshow") : NSLocalizedString("Слайд-шоу", comment: "Start photo slideshow")) { playback.playing.toggle() }.disabled(paused || editor || originalLoading || error != nil || (!loading && image == nil))
                    }
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(sequence) { item in
                                Button { selectPhoto(item) } label: {
                                    DiskPhotoThumbnail(photo: item, service: service, mediaProvider: mediaProvider, paused: paused, resolveMatrixSource: resolveMatrixSource)
                                        .frame(width: 56, height: 56).clipped()
                                        .overlay { if item.id == photo.id { Rectangle().stroke(StalkTheme.accent, lineWidth: 2) } }
                                }.accessibilityLabel(item.name)
                            }
                        }.padding(.horizontal)
                    }.frame(height: 64).disabled(editor || originalLoading)
                }
            }
            .navigationTitle("Просмотр фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
            .task(id: photo.id + String(paused) + ":" + String(retryRevision)) { await loadPhoto() }
            .task(id: slideshowPhotoID) {
                guard let id = slideshowPhotoID else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled, slideshowPhotoID == id else { return }
                if index + 1 < sequence.count { move(1) } else { playback.playing = false }
            }
            .interactiveQuickLook(item: $preview, allowEditing: false)
            .sheet(item: $editingPhoto) { target in
                if let file = target.matrixFile {
                    DiskPhotoEditor(photo: photoForMatrixEditor(target), service: service, saved: saved,
                                    loadOriginal: {
                                        try await DiskPhotoMatrixMedia.editableOriginal(for: file, mediaProvider: mediaProvider, resolveMatrixSource: resolveMatrixSource)
                                    },
                                    verifySourceAccess: {
                                        await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: resolveMatrixSource)
                                    })
                } else { DiskPhotoEditor(photo: target, service: service, saved: saved) }
            }
        }
    }

    private func photoForMatrixEditor(_ target: DiskPhoto) -> DiskPhoto {
        var copy = target
        // The index's encrypted-file flag is not an ACL. The mandatory SDK verifier below
        // authorizes opening/saving this editor copy; leave the catalog model unchanged.
        if target.matrixFile != nil { copy.canDownload = true }
        return copy
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard sequence.indices.contains(next) else { return }
        selectPhoto(sequence[next])
    }

    private func selectPhoto(_ selected: DiskPhoto) {
        guard selected.id != currentID else { return }
        playback.beginLoading(selected.id)
        image = nil; matrixSourceResolved = false; error = nil; loading = true
        currentID = selected.id
    }

    private func loadPhoto() async {
        image = nil; matrixSourceResolved = false; error = nil; zoom = 1; lastZoom = 1
        let target = photo
        playback.beginLoading(target.id)
        guard !paused else { loading = false; return }
        loading = true
        defer { if !Task.isCancelled, target.id == photo.id { loading = false } }
        if let file = target.matrixFile {
            do {
                let loaded = try await DiskPhotoMatrixMedia.preview(for: file, mediaProvider: mediaProvider, resolveMatrixSource: resolveMatrixSource)
                guard !Task.isCancelled, target.id == photo.id else { return }
                image = loaded.image; matrixSourceResolved = loaded.sdkSourceAvailable; playback.loaded(target.id)
            } catch {
                if !Task.isCancelled, target.id == photo.id { self.error = DiskPhotoMatrixMedia.Failure.unavailable.localizedDescription; playback.failed(target.id) }
            }
            return
        }
        let thumbnail = try? await service.thumbnail(target)
        guard !Task.isCancelled, target.id == photo.id else { return }
        image = thumbnail
        guard target.canDownload, target.mimetype.hasPrefix("image/") else {
            if thumbnail != nil { playback.loaded(target.id) }
            else { playback.failed(target.id) }
            return
        }
        do {
            let loaded = try await service.image(target)
            guard !Task.isCancelled, target.id == photo.id else { return }
            image = loaded; playback.loaded(target.id)
        } catch { if !Task.isCancelled, target.id == photo.id { self.error = error.localizedDescription; playback.failed(target.id) } }
    }

    private func original() async {
        playback.playing = false
        let target = photo
        originalLoading = true; error = nil
        defer { originalLoading = false }
        do {
            if let file = target.matrixFile {
                let handle = try await DiskPhotoMatrixMedia.original(for: file, mediaProvider: mediaProvider, resolveMatrixSource: resolveMatrixSource)
                guard !Task.isCancelled, target.id == photo.id else { return }
                preview = MediaPreviewItem(file: handle, title: target.name)
                return
            }
            let url = try await service.originalFile(target)
            temporaryFiles.urls.append(url)
            guard target.id == photo.id else { return }
            preview = MediaPreviewItem(file: .unmanaged(url: url), title: target.name)
        } catch {
            if !Task.isCancelled, target.id == photo.id {
                self.error = target.matrixFile == nil ? error.localizedDescription : DiskPhotoMatrixMedia.Failure.unavailable.localizedDescription
            }
        }
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
