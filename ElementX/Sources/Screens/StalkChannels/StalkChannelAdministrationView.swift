// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StalkChannelAdministrationSections: View {
    @ObservedObject var service: StalkChannelService
    let roomID: String
    let access: StalkChannelSnapshot
    @State private var query = ""
    @State private var target = ""
    @State private var backgroundImage = ""
    @State private var confirmation: String?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Group {
            if access.canAdminister {
                Section(StalkChannelStrings.text("background")) {
                    Picker(StalkChannelStrings.text("background"), selection: Binding(get: { access.background }, set: { preset in Task { await perform { try await service.setAppearance(roomID: roomID, preset: preset) } } })) {
                        ForEach(["default", "sky", "mint", "sand", "dots", "grid"], id: \.self) { Text(StalkChannelStrings.text("background_" + $0)).tag($0) }
                    }
                    TextField(StalkChannelStrings.text("background_mxc"), text: $backgroundImage).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L10n.actionSave) {
                        Task { await perform { try await service.setAppearance(roomID: roomID, preset: access.background, image: backgroundImage.isEmpty ? nil : backgroundImage) } }
                    }
                }
                if access.capabilities?.lifecycle?.schemaVersion == 1, access.capabilities?.lifecycle?.archive == true {
                    Section(StalkChannelStrings.archived) {
                        Button(StalkChannelStrings.text(access.archived ? "restore" : "archive")) { confirmation = "archive" }
                        Text(StalkChannelStrings.text("archive_explanation")).font(.caption)
                    }
                }
                if let modes = access.capabilities?.historyVisibility?.modes, !modes.isEmpty {
                    Section(StalkChannelStrings.text("history")) {
                        ForEach(modes.filter { ["joined", "shared"].contains($0) }, id: \.self) { mode in
                            Button { confirmation = mode } label: {
                                HStack { Text(StalkChannelStrings.text("history_" + mode)); Spacer(); if access.history == mode { Image(systemName: "checkmark") } }
                            }.disabled(mode == "shared" && access.encrypted)
                        }
                        Text(StalkChannelStrings.text("history_explanation")).font(.caption)
                    }
                }
                if access.capabilities?.lifecycle?.management == true, access.canTransfer {
                    Section(StalkChannelStrings.text("management")) {
                        if let manager = access.manager { Text(manager).font(.caption) }
                        TextField(StalkChannelStrings.text("find_member"), text: $query)
                        ForEach(access.joinedPeople.filter { query.isEmpty || $0.userID.localizedCaseInsensitiveContains(query) || ($0.displayName ?? "").localizedCaseInsensitiveContains(query) }.prefix(30), id: \.userID) { person in
                            Button {
                                target = person.userID; confirmation = "transfer"
                            } label: { VStack(alignment: .leading) { Text(person.displayName ?? person.userID); Text(person.userID).font(.caption) } }
                        }
                        Text(StalkChannelStrings.text("transfer_explanation")).font(.caption)
                    }
                }
                if access.capabilities == nil { Section { Text(StalkChannelStrings.text("unsupported")) } }
            } else { Section { Text(StalkChannelError.readOnly.localizedDescription) } }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .disabled(busy || !access.canAdminister)
        .confirmationDialog(confirmation == "transfer" ? StalkChannelStrings.text("transfer_explanation") : confirmation == "archive" ? StalkChannelStrings.text("archive_explanation") : StalkChannelStrings.text("history_explanation"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            let action = confirmation ?? ""
            Button(L10n.actionConfirm) {
                Task { await perform {
                    switch action {
                    case "archive": try await service.archive(roomID: roomID, archived: !access.archived)
                    case "transfer": try await service.transfer(roomID: roomID, userID: target)
                    case "joined", "shared": try await service.setHistory(roomID: roomID, mode: action)
                    default: break
                    }
                } }
            }
        }
        .onChange(of: access.canAdminister) { if !access.canAdminister { confirmation = nil } }
        .onAppear { backgroundImage = access.backgroundImage?.absoluteString ?? "" }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
}

struct StalkChannelBackground: View {
    let access: StalkChannelSnapshot?
    var mediaProvider: MediaProviderProtocol?
    private var color: Color {
        switch access?.background {
        case "sky": Color(red: 0.88, green: 0.94, blue: 1)
        case "mint": Color(red: 0.89, green: 0.97, blue: 0.93)
        case "sand": Color(red: 0.98, green: 0.95, blue: 0.88)
        default: Color.compound.bgCanvasDefault
        }
    }

    var body: some View {
        color.overlay {
            if let url = access?.backgroundImage {
                LoadableImage(url: url, mediaType: .generic, size: nil, mediaProvider: mediaProvider) { $0.scaledToFill() } placeholder: { color }
                    .clipped()
            } else if access?.background == "dots" || access?.background == "grid" {
                Canvas { context, size in
                    var path = Path()
                    for x in stride(from: CGFloat(0), to: size.width, by: 24) {
                        for y in stride(from: CGFloat(0), to: size.height, by: 24) {
                            if access?.background == "dots" { path.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)) }
                        }
                        if access?.background == "grid" { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
                    }
                    if access?.background == "grid" {
                        for y in stride(from: CGFloat(0), to: size.height, by: 24) {
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(path, with: .color(.gray.opacity(0.16)), lineWidth: 1)
                    } else { context.fill(path, with: .color(.gray.opacity(0.2))) }
                }
            }
        }
    }
}
