// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import ImageIO
import SwiftUI

struct AilockAuthenticatedImage: View {
    let file: AilockFile
    let load: ((AilockFile) async throws -> URL)?
    @State private var image: UIImage?
    @StateObject private var temporaryFiles = StalkTemporaryFiles()
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary).frame(height: 80)
            } else { ProgressView().frame(height: 80) }
        }
        .accessibilityLabel(file.filename)
        .task(id: file.identity) {
            guard let load, file.isDownloadable else { failed = true; return }
            do {
                let url = try await load(file)
                temporaryFiles.urls.append(url)
                try Task.checkCancellation()
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary) {
                    image = UIImage(cgImage: thumbnail)
                }
                failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
