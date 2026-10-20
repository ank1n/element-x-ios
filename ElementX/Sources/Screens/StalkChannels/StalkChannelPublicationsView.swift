// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StalkChannelPublicationsView: View {
    @ObservedObject var service: StalkChannelService
    let roomID: String
    @State private var items: [StalkPublication] = []
    @State private var selected: StalkPublication?
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            List {
                if let access = service.snapshots[roomID], access.encrypted {
                    Text(StalkChannelStrings.text("encrypted_drafts"))
                } else {
                    Button(StalkChannelStrings.text("new_publication")) { selected = StalkPublication(room_id: roomID) }
                        .disabled(service.snapshots[roomID]?.canPublish != true || service.snapshots[roomID]?.capabilities?.publications?.drafts != true)
                    ForEach(items) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.content.body).lineLimit(3)
                                Text(StalkChannelStrings.text("status_" + item.status)).font(.caption)
                                if let date = item.send_at { Text(Date(timeIntervalSince1970: date / 1000), format: .dateTime).font(.caption) }
                                if item.error_code == "channel_archived" { Text(StalkChannelStrings.text("archived_draft")).font(.caption) }
                            }
                        }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error); Button(L10n.actionRetry) { Task { await load() } } }
            }
            .navigationTitle(StalkChannelStrings.text("publications"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
            .sheet(item: $selected, onDismiss: { Task { await load() } }) { item in
                StalkChannelPublicationEditor(service: service, item: item)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await load()
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                } while !Task.isCancelled
            }
        }
    }

    private func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { items = try await service.publications(roomID: roomID); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct StalkChannelPublicationEditor: View {
    @ObservedObject var service: StalkChannelService
    @State var item: StalkPublication
    @State private var text = ""
    @State private var data: Data?
    @State private var previewData: Data?
    @State private var imageName = "image.png"
    @State private var mime = "image/png"
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var scheduled = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var preview = false
    @State private var formatting = false
    @State private var initialized = false
    @State private var busy = false
    @State private var dirty = false
    @State private var conflict = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var access: StalkChannelSnapshot? {
        service.snapshots[item.room_id]
    }

    private var editable: Bool {
        item.editable && access?.verified == true && access?.joined == true && (access?.level ?? 0) >= 50 && access?.encrypted == false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(StalkChannelStrings.text("status_" + item.status))
                    if item.status == "uncertain" { Text(StalkChannelStrings.text("uncertain")) }
                    if item.error_code == "channel_archived" { Text(StalkChannelStrings.text("archived_draft")) }
                    if let bytes = data ?? previewData, let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        Text(imageName).font(.caption)
                    } else if let name = item.content.filename { Label(name, systemImage: "photo") }
                    if preview {
                        Text((try? AttributedString(markdown: text)) ?? AttributedString(text)).frame(maxWidth: .infinity, alignment: .leading)
                    } else { TextEditor(text: $text).frame(minHeight: 150).disabled(!editable || busy) }
                    Toggle(StalkChannelStrings.text("preview"), isOn: $preview)
                    if editable {
                        if access?.capabilities?.publications?.formattedBody == true {
                            DisclosureGroup(StalkChannelStrings.text("formatting"), isExpanded: $formatting) {
                                ScrollView(.horizontal) {
                                    HStack {
                                        formatButton("B", prefix: "**", suffix: "**")
                                        formatButton("I", prefix: "*", suffix: "*")
                                        formatButton("</>", prefix: "`", suffix: "`")
                                        formatButton("H", prefix: "\n## ", suffix: "")
                                        formatButton("•", prefix: "\n- ", suffix: "")
                                        formatButton("❞", prefix: "\n> ", suffix: "")
                                    }
                                }
                            }
                        }
                        PhotosPicker(selection: $photo, matching: .images) { Label(StalkChannelStrings.text("choose_image"), systemImage: "photo") }
                        Button(StalkChannelStrings.text("image_file")) { importing = true }
                        Button(StalkChannelStrings.text("paste_image")) {
                            if let png = UIPasteboard.general.image?.pngData() { data = png; imageName = "image.png"; mime = "image/png"; dirty = true }
                        }
                        if data != nil || item.content.msgtype == "m.image" {
                            Button(StalkChannelStrings.text("remove_image")) { data = nil; previewData = nil; item.content = StalkPublicationContent(); dirty = true }
                        }
                    }
                }
                if editable {
                    Section {
                        if access?.capabilities?.publications?.scheduling == true {
                            Toggle(StalkChannelStrings.text("schedule"), isOn: $scheduled).disabled(access?.archived == true)
                            if scheduled { DatePicker(StalkChannelStrings.text("send_at"), selection: $date, in: Date()...) }
                        }
                        Text(TimeZone.current.identifier).font(.caption)
                        Button(L10n.actionSave) { Task { await save(publish: false) } }.disabled(busy || conflict)
                        Button(StalkChannelStrings.text("publish_now")) { Task { await save(publish: true) } }.disabled(busy || conflict || access?.archived == true || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && data == nil && item.content.msgtype != "m.image")
                        if item.revision > 0 {
                            if item.status == "scheduled" { Button(StalkChannelStrings.text("unschedule")) { Task { await action("unschedule") } }.disabled(busy || conflict) }
                            Button(L10n.actionRemove, role: .destructive) { Task { await action("delete") } }.disabled(busy || conflict)
                        }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if conflict {
                    Text(StalkChannelStrings.text("changed"))
                    Button(StalkChannelStrings.text("reload_publication")) { Task { await reload() } }.disabled(busy)
                }
            }
            .navigationTitle(StalkChannelStrings.text("publication"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { if dirty { confirmDiscard = true } else { dismiss() } } } }
            .interactiveDismissDisabled(dirty || busy)
            .confirmationDialog(StalkChannelStrings.text("discard"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(L10n.actionRemove, role: .destructive) { dismiss() }
            }
            .onAppear {
                guard !initialized else { return }
                text = item.content.editableText; scheduled = item.send_at != nil
                if let time = item.send_at { date = Date(timeIntervalSince1970: time / 1000) }
                initialized = true
            }
            .onChange(of: text) { dirty = text != item.content.editableText || data != nil }
            .onChange(of: scheduled) { if initialized { dirty = true } }
            .onChange(of: date) { if initialized { dirty = true } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .gif, .webP]) { result in
                do {
                    let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 20 * 1024 * 1024 else { throw StalkChannelOperationError.invalid }
                    let bytes = try Data(contentsOf: url); guard UIImage(data: bytes) != nil else { throw StalkChannelOperationError.invalid }
                    data = bytes; imageName = url.lastPathComponent; mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""; dirty = true
                } catch { self.error = error.localizedDescription }
            }
            .task(id: item.id) {
                if item.content.msgtype == "m.image", item.content.url != nil {
                    do {
                        let bytes = try await service.publicationImage(item)
                        guard !Task.isCancelled else { return }
                        previewData = bytes; imageName = item.content.filename ?? "image.png"
                    } catch { self.error = error.localizedDescription }
                }
            }
            .task(id: photo) {
                guard let photo else { return }
                do {
                    guard let bytes = try await photo.loadTransferable(type: Data.self), bytes.count <= 20 * 1024 * 1024, let image = UIImage(data: bytes), let png = image.pngData() else { throw StalkChannelOperationError.invalid }
                    data = png; imageName = "image.png"; mime = "image/png"; dirty = true
                } catch { self.error = error.localizedDescription }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    _ = await service.refresh(roomID: item.room_id)
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                } while !Task.isCancelled
            }
        }
    }

    private func formatButton(_ title: String, prefix: String, suffix: String) -> some View {
        Button(title) { text += prefix + StalkChannelStrings.text("text") + suffix }.buttonStyle(.bordered)
    }

    private func save(publish: Bool) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            var candidate = item
            if let data {
                let mxc = try await service.uploadPublicationImage(roomID: item.room_id, data: data, name: imageName, mime: mime)
                candidate.content = .init(msgtype: "m.image", filename: imageName, url: mxc, info: .init(mimetype: mime, size: data.count))
            }
            candidate.content.setText(text, formatted: access?.capabilities?.publications?.formattedBody == true || item.content.format != nil)
            candidate.time_zone = TimeZone.current.identifier
            candidate.send_at = !publish && scheduled ? date.timeIntervalSince1970 * 1000 : nil
            item = try await service.savePublication(candidate)
            if let data { previewData = data }
            data = nil; dirty = false
            if publish { item = try await service.publicationAction(item, action: "publish") }
        } catch { self.error = error.localizedDescription; if case StalkChannelOperationError.changed = error { conflict = true } }
    }

    private func action(_ name: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { item = try await service.publicationAction(item, action: name); scheduled = item.send_at != nil; if name == "delete" { dismiss() } }
        catch { self.error = error.localizedDescription; if case StalkChannelOperationError.changed = error { conflict = true } }
    }

    private func reload() async {
        do {
            let values = try await service.publications(roomID: item.room_id)
            guard let remote = values.first(where: { $0.id == item.id }) else { throw StalkChannelOperationError.changed }
            // Keep local text/image for manual reconciliation; adopt the new revision only after explicit reload.
            item = remote; conflict = false
        } catch { self.error = error.localizedDescription }
    }
}
