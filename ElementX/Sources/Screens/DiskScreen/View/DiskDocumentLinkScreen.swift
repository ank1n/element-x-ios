// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Opens the exact ACL-protected blob, including documents shared with this user.
struct DiskDocumentLinkScreen: View {
    let link: StalkDiskLink
    let service: DiskService
    @State private var preview: MediaPreviewItem?
    @State private var loading = false
    @State private var error: String?
    @State private var fileURL: URL?
    @State private var documentText: String?
    @StateObject private var temporaryFiles = StalkTemporaryFiles()
    @State private var offersWebPreview = false

    var body: some View {
        VStack(spacing: 20) {
            if loading { ProgressView(L10n.commonLoading) }
            if let error { Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            if offersWebPreview, let browser = StalkServerLink(url: link.url)?.browserURL {
                Button("Открыть веб-просмотр") { UIApplication.shared.open(browser, options: [:], completionHandler: nil) }
            }
            if let documentText {
                ScrollView { Text(documentText).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else if let fileURL {
                Image(systemName: "doc.text").font(.system(size: 48)).foregroundStyle(StalkTheme.accent)
                Text(link.name.isEmpty ? String(localized: "stalk_disk_document", defaultValue: "Документ") : link.name)
                Button(String(localized: "stalk_disk_open_document", defaultValue: "Открыть документ")) {
                    preview = MediaPreviewItem(file: .unmanaged(url: fileURL), title: link.name)
                }.buttonStyle(.borderedProminent)
            } else if !loading {
                Button(L10n.actionRetry) { Task { await load() } }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(String(localized: "stalk_disk_title", defaultValue: "Диск"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveQuickLook(item: $preview, allowEditing: false)
        .onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        .task { await load() }
    }

    private func load() async {
        guard !loading, fileURL == nil else { return }
        loading = true
        error = nil
        offersWebPreview = false
        defer { loading = false }
        do {
            let url = try await service.downloadBlobFile(id: link.blobID, filename: link.name)
            temporaryFiles.urls.append(url)
            try Task.checkCancellation()
            fileURL = url
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            if size <= 2 * 1024 * 1024, let text = try? String(contentsOf: url, encoding: .utf8),
               !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) {
                documentText = text
            } else {
                preview = MediaPreviewItem(file: .unmanaged(url: url), title: link.name)
            }
        } catch is CancellationError { }
        catch DiskServiceError.unauthorized {
            error = String(localized: "stalk_disk_link_signin", defaultValue: "Войдите снова, чтобы открыть документ.")
        } catch DiskServiceError.http(let status) {
            offersWebPreview = status == 403
            error = status == 403 || status == 404
                ? String(localized: "stalk_disk_link_unavailable", defaultValue: "Документ удалён или у вас больше нет доступа.")
                : String(localized: "stalk_disk_error_download", defaultValue: "Не удалось загрузить файл")
        } catch {
            self.error = String(localized: "stalk_disk_link_network", defaultValue: "Не удалось соединиться с Диском. Попробуйте ещё раз.")
        }
    }
}

final class DiskDocumentLinkCoordinator: CoordinatorProtocol {
    let link: StalkDiskLink
    let service: DiskService
    init(link: StalkDiskLink, service: DiskService) {
        self.link = link; self.service = service
    }

    func toPresentable() -> AnyView {
        AnyView(DiskDocumentLinkScreen(link: link, service: service))
    }
}
