// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StalkChannelCreationView: View {
    let service: StalkChannelService
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var approval = false
    @State private var symbol = "megaphone.fill"
    @State private var color = 0
    @State private var photo: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var busy = false
    @State private var uncertain = false
    @State private var error: String?
    private let colors: [UIColor] = [.systemIndigo, .systemBlue, .systemGreen, .systemOrange, .systemPink]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14)) }
                        else { Image(systemName: symbol).font(.title).foregroundStyle(.white).frame(width: 64, height: 64).background(Color(colors[color]), in: RoundedRectangle(cornerRadius: 14)) }
                        TextField(StalkUpdateStrings.text("channel_name"), text: $name)
                    }
                    TextField(StalkUpdateStrings.text("channel_topic"), text: $topic, axis: .vertical).lineLimit(2...5)
                    Picker(StalkUpdateStrings.text("channel_icon"), selection: $symbol) {
                        ForEach(["megaphone.fill", "newspaper.fill", "briefcase.fill", "lightbulb.fill", "star.fill"], id: \.self) { Image(systemName: $0).accessibilityLabel(StalkUpdateStrings.text("icon_" + $0.replacingOccurrences(of: ".fill", with: ""))).tag($0) }
                    }
                    Picker(StalkUpdateStrings.text("channel_color"), selection: $color) {
                        ForEach(Array(colors.indices), id: \.self) { Image(systemName: "circle.fill").foregroundStyle(Color(colors[$0])).accessibilityLabel(StalkUpdateStrings.text("color_" + String($0))).tag($0) }
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label(StalkUpdateStrings.text("channel_photo"), systemImage: "photo") }
                    if image != nil { Button(StalkUpdateStrings.text("remove_photo")) { image = nil; photo = nil } }
                }
                Section {
                    Picker(StalkUpdateStrings.text("channel_access"), selection: $approval) {
                        Text(StalkUpdateStrings.text("channel_open")).tag(false)
                        Text(StalkUpdateStrings.text("channel_approval")).tag(true)
                    }
                    Text(StalkUpdateStrings.text("channel_local_access")).font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle(StalkUpdateStrings.text("create_channel"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(StalkUpdateStrings.text("create")) { Task { await create() } }.disabled(busy || uncertain || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .interactiveDismissDisabled(busy)
            .task(id: photo) {
                guard let photo else { return }
                do {
                    guard let bytes = try await photo.loadTransferable(type: Data.self), bytes.count <= 5 * 1024 * 1024, let value = UIImage(data: bytes) else { throw StalkChannelOperationError.invalid }
                    guard !Task.isCancelled else { return }; image = value; error = nil
                } catch { self.error = StalkUpdateStrings.text("channel_photo_error") }
            }
        }
    }

    @MainActor private func create() async {
        guard !busy, !uncertain else { return }; busy = true; error = nil; defer { busy = false }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let avatar = renderer.image { _ in
            if let image { image.draw(in: CGRect(x: 0, y: 0, width: 256, height: 256)) }
            else {
                colors[color].setFill(); UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256), cornerRadius: 48).fill()
                UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 130, weight: .medium))?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 64, y: 64, width: 128, height: 128))
            }
        }.pngData()
        do {
            let room = try await service.createChannel(name: name, topic: topic, approval: approval, avatar: avatar)
            uncertain = true // Never issue a second create if presentation/navigation is delayed.
            created(room); dismiss()
        } catch is URLError { uncertain = true; self.error = StalkUpdateStrings.text("channel_create_uncertain") }
        catch let error as StalkNativeHTTPError { self.error = StalkUpdateStrings.text(error.status == 401 ? "login_required" : error.status == 413 ? "channel_photo_error" : error.status == 403 ? "channel_create_forbidden" : "channel_create_failed") }
        catch { self.error = error.localizedDescription }
    }
}
