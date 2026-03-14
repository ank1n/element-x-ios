//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import Kingfisher
import SwiftUI

struct CacheAndStorageScreen: View {
    let onClearAllCache: () -> Void

    @State private var apiCacheSize: String = "..."
    @State private var imageCacheSize: String = "..."
    @State private var downloadedRecordingsSize: String = "..."
    @State private var totalSize: String = "..."
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section(header: Text(SL10n.cacheUsage)) {
                HStack {
                    Label(SL10n.cacheApiData, systemImage: "doc.text")
                    Spacer()
                    Text(apiCacheSize)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label(SL10n.cacheImages, systemImage: "photo")
                    Spacer()
                    Text(imageCacheSize)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label(SL10n.cacheRecordings, systemImage: "waveform")
                    Spacer()
                    Text(downloadedRecordingsSize)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label(SL10n.cacheTotal, systemImage: "internaldrive")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(totalSize)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                }
            }

            Section {
                Button(role: .destructive) {
                    clearAPIAndRecordingsCache()
                } label: {
                    Label(SL10n.cacheClearApi, systemImage: "trash")
                }

                Button(role: .destructive) {
                    clearImageCache()
                } label: {
                    Label(SL10n.cacheClearImages, systemImage: "photo.on.rectangle.angled")
                }

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(SL10n.cacheClearAll, systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text(SL10n.cacheActions)
            } footer: {
                Text(SL10n.cacheClearAllWarning)
            }
        }
        .compoundList()
        .navigationTitle(SL10n.settingsCacheAndData)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(SL10n.cacheClearAllConfirm, isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button(SL10n.cacheClearAndRestart, role: .destructive) {
                onClearAllCache()
            }
            Button(SL10n.actionCancel, role: .cancel) { }
        } message: {
            Text(SL10n.cacheClearConfirmMessage)
        }
        .task {
            await calculateSizes()
        }
    }

    // MARK: - Private

    private func calculateSizes() async {
        guard let cacheService = ServiceLocator.shared.cacheService else {
            apiCacheSize = "0 Б"
            imageCacheSize = "0 Б"
            downloadedRecordingsSize = "0 Б"
            totalSize = "0 Б"
            return
        }

        let apiSize = await cacheService.diskSize()
        let imageSize = await cacheService.imageCacheDiskSize()

        // Calculate downloaded recordings separately
        let recordingsDir = FileManager.default.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
        var recSize: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: recordingsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    recSize += UInt64(size)
                }
            }
        }

        // apiSize includes recordings dir, subtract to show separately
        let pureApiSize = apiSize > recSize ? apiSize - recSize : 0

        await MainActor.run {
            apiCacheSize = formatBytes(pureApiSize)
            imageCacheSize = formatBytes(imageSize)
            downloadedRecordingsSize = formatBytes(recSize)
            totalSize = formatBytes(pureApiSize + imageSize + recSize)
        }
    }

    private func clearAPIAndRecordingsCache() {
        Task {
            await ServiceLocator.shared.cacheService?.clearAll()
            await ServiceLocator.shared.cacheService?.clearDownloadedRecordings()
            await calculateSizes()
        }
    }

    private func clearImageCache() {
        ImageCache.default.clearDiskCache()
        ImageCache.default.clearMemoryCache()
        Task {
            await calculateSizes()
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
