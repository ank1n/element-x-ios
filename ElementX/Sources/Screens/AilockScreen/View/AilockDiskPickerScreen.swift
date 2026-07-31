//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Выбор файла из «Диска» для вложения в Айлок.
///
/// STMOB-274. Отдельного клиента не пишем — берём тот же `DiskService`, что и само
/// приложение «Диск». Показываем сеткой пиктограмм: у изображений — настоящее
/// превью, у остального — глиф по типу файла. Выбор ровно один: тап по плитке
/// прикладывает файл и закрывает экран (решение dp).
///
/// Зашифрованные вложения в список не попадают: их содержимое доступно только
/// владельцу ключей комнаты, приложить их нельзя, а показывать невыбираемое —
/// вводить в заблуждение.
struct AilockDiskPickerScreen: View {
    let service: DiskService
    let baseURL: String
    let accessTokenProvider: () throws -> String
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var files: [DiskFile] = []
    @State private var isLoading = true
    @State private var loadingFileID: String?
    @State private var errorMessage: String?
    @State private var searchQuery = ""
    @State private var thumbnails: [String: UIImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(SL10n.ailockDiskPickerTitle)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchQuery, prompt: SL10n.ailockDiskSearch)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(SL10n.ailockCancel) { dismiss() }
                    }
                }
        }
        .task { await load() }
    }

    private var visibleFiles: [DiskFile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { $0.filename.lowercased().contains(query) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, files.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            errorView(errorMessage)
        } else if visibleFiles.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(visibleFiles) { file in
                        tile(file)
                    }
                }
                .padding(16)
            }
        }
    }

    private func tile(_ file: DiskFile) -> some View {
        Button {
            Task { await pick(file) }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))

                    if let image = thumbnails[file.id] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Image(systemName: icon(for: file))
                            .font(.system(size: 26))
                            .foregroundStyle(StalkTheme.accent)
                    }

                    if loadingFileID == file.id {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black.opacity(0.35))
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                Text(file.filename)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(Self.sizeFormatter.string(fromByteCount: file.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingFileID != nil)
        .task { await loadThumbnail(for: file) }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(SL10n.ailockDiskEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(SL10n.ailockRetry) {
                Task { await load() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Данные

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await service.fetchFiles()
            // Зашифрованное и то, у чего нечем достать содержимое, в выбор не попадает.
            files = page.files.filter { !$0.isEncrypted && (!$0.mxcURL.isEmpty || !($0.blobID ?? "").isEmpty) }
        } catch {
            MXLog.error("sTalk Ailock: список Диска не загрузился: \(error)")
            errorMessage = SL10n.ailockDiskLoadFailed
        }
        isLoading = false
    }

    /// Превью только для изображений и только по mxc-миниатюре: тянуть ради плитки
    /// полный файл (а тем более блоб на мегабайты) нельзя.
    private func loadThumbnail(for file: DiskFile) async {
        guard thumbnails[file.id] == nil,
              file.mimetype.hasPrefix("image/"),
              !file.mxcURL.isEmpty,
              let image = await AilockDiskAttachment.thumbnail(mxcURL: file.mxcURL,
                                                               baseURL: baseURL,
                                                               accessToken: try? accessTokenProvider()) else {
            return
        }
        thumbnails[file.id] = image
    }

    private func pick(_ file: DiskFile) async {
        loadingFileID = file.id
        defer { loadingFileID = nil }

        do {
            let url = try await AilockDiskAttachment.fetch(file: file,
                                                           baseURL: baseURL,
                                                           diskService: service,
                                                           accessToken: try? accessTokenProvider())
            onPick(url)
            dismiss()
        } catch {
            MXLog.error("sTalk Ailock: файл из Диска не скачался: \(error)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? SL10n.ailockDiskFileFailed
        }
    }

    private func icon(for file: DiskFile) -> String {
        if file.mimetype.hasPrefix("image/") { return "photo" }
        if file.mimetype.hasPrefix("video/") { return "film" }
        if file.mimetype.hasPrefix("audio/") { return "waveform" }
        if file.mimetype.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
