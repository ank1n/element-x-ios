// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum DiskPhotoEditError: LocalizedError {
    case unsupported, memoryLimit(megapixels: String), unsafeDimensions, invalidName
    var errorDescription: String? {
        switch self {
        case .unsupported: NSLocalizedString("Не удалось открыть статический оригинал JPEG, PNG или WebP.", comment: "Photo editor source error")
        case let .memoryLimit(megapixels): String(format: NSLocalizedString("stalk_photos_edit_memory_limit", comment: "Export memory limit in megapixels, %@"), megapixels)
        case .unsafeDimensions: NSLocalizedString("Оригинал превышает безопасный предел открытия: 100 Мп или 65535 px. Создайте уменьшенную копию вне мобильного редактора.", comment: "Photo editor opening limit")
        case .invalidName: NSLocalizedString("Введите имя копии.", comment: "Photo editor filename error")
        }
    }
}

enum DiskPhotoEditFormat: String, CaseIterable {
    case png, jpeg
    var mime: String {
        self == .png ? "image/png" : "image/jpeg"
    }

    var identifier: String {
        self == .png ? UTType.png.identifier : UTType.jpeg.identifier
    }

    var suffix: String {
        self == .png ? ".png" : ".jpg"
    }

    func filename(_ name: String) throws -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = String(clean.unicodeScalars.map { scalar -> Character in
            scalar.value < 32 || scalar.value == 127 || scalar == "/" || scalar == "\\" ? "_" : Character(scalar)
        })
        for ext in [".jpeg", ".jpg", ".png"] where clean.lowercased().hasSuffix(ext) {
            clean.removeLast(ext.count); break
        }
        guard !clean.isEmpty, clean != ".", clean != ".." else { throw DiskPhotoEditError.invalidName }
        return String(clean.prefix(120)) + suffix
    }
}

enum DiskPhotoEditResolution: String, CaseIterable {
    case original, edge4096, edge2048
    var label: String {
        switch self {
        case .original: NSLocalizedString("Исходные пиксели", comment: "Photo export resolution")
        case .edge4096: NSLocalizedString("До 4096 px · уменьшенная копия", comment: "Photo export resolution")
        case .edge2048: NSLocalizedString("До 2048 px · уменьшенная копия", comment: "Photo export resolution")
        }
    }

    var edge: CGFloat {
        switch self { case .original: .greatestFiniteMagnitude; case .edge4096: 4096; case .edge2048: 2048 }
    }
}

struct DiskPhotoEditSource {
    let url: URL
    let size: CGSize // Oriented original dimensions, never thumbnail dimensions.

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw DiskPhotoEditError.unsupported }
        guard width.doubleValue * height.doubleValue <= 100_000_000,
              max(width.doubleValue, height.doubleValue) <= 65535 else { throw DiskPhotoEditError.unsafeDimensions }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = [5, 6, 7, 8].contains(orientation)
        size = CGSize(width: swapped ? height.doubleValue : width.doubleValue, height: swapped ? width.doubleValue : height.doubleValue)
        self.url = url
    }

    func allowsOriginal(budget: DiskPhotoEditMemoryBudget = .current) -> Bool {
        budget.allows(size)
    }

    func rasterSize(resolution: DiskPhotoEditResolution) -> CGSize {
        let ratio = min(1, resolution.edge / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * ratio).rounded()), height: max(1, (size.height * ratio).rounded()))
    }

    func image(maxEdge: CGFloat) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(min(maxEdge, max(size.width, size.height))),
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DiskPhotoEditError.unsupported }
        if maxEdge >= max(size.width, size.height) {
            guard image.width == Int(size.width), image.height == Int(size.height) else { throw DiskPhotoEditError.unsupported }
        }
        return UIImage(cgImage: image)
    }

    func preview(_ edits: DiskPhotoEdits) throws -> UIImage {
        try DiskPhotoEditRenderer.render(image(maxEdge: 1400), logicalSize: size, operations: edits.operations, maxEdge: 1400)
    }

    func outputSize(_ edits: DiskPhotoEdits, resolution: DiskPhotoEditResolution) -> CGSize {
        let logical = DiskPhotoEditRenderer.size(size, operations: edits.operations)
        let scale = min(1, resolution.edge / max(size.width, size.height))
        return CGSize(width: max(1, (logical.width * scale).rounded()), height: max(1, (logical.height * scale).rounded()))
    }

    func export(_ edits: DiskPhotoEdits, format: DiskPhotoEditFormat, resolution: DiskPhotoEditResolution,
                keepCaptureMetadata: Bool, memoryBudget: DiskPhotoEditMemoryBudget = .current) throws -> Data {
        // The default budget samples the OS again here, immediately before full-size decoding.
        // Even a tiny final crop needs the source decoded first, so budget SOURCE raster pixels.
        guard memoryBudget.allows(rasterSize(resolution: resolution)) else {
            throw DiskPhotoEditError.memoryLimit(megapixels: memoryBudget.megapixelLabel)
        }
        var output = try DiskPhotoEditRenderer.render(image(maxEdge: resolution.edge), logicalSize: size,
                                                      operations: edits.operations, maxEdge: resolution.edge)
        if format == .jpeg {
            let base = output
            output = DiskPhotoEditRenderer.canvas(base.size) { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: base.size)); base.draw(at: .zero)
            }
        }
        guard let cg = output.cgImage else { throw DiskPhotoEditError.unsupported }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { throw DiskPhotoEditError.unsupported }
        var properties = metadata(keepCaptureMetadata: keepCaptureMetadata, outputSize: output.size)
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DiskPhotoEditError.unsupported }
        return data as Data
    }

    /// Whitelist capture data. Never copy stale thumbnails, GPS, maker notes, orientation or source dimensions.
    func metadata(keepCaptureMetadata: Bool, outputSize: CGSize) -> [CFString: Any] {
        var result: [CFString: Any] = [kCGImagePropertyOrientation: 1,
                                       kCGImagePropertyPixelWidth: Int(outputSize.width), kCGImagePropertyPixelHeight: Int(outputSize.height)]
        guard keepCaptureMetadata,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        if let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var safe: [CFString: Any] = [:]
            for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                        kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifSubsecTimeOriginal,
                        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
                        kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel] {
                safe[key] = exif[key]
            }
            safe[kCGImagePropertyExifPixelXDimension] = Int(outputSize.width)
            safe[kCGImagePropertyExifPixelYDimension] = Int(outputSize.height)
            result[kCGImagePropertyExifDictionary] = safe
        }
        if let tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var safe: [CFString: Any] = [:]
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] {
                safe[key] = tiff[key]
            }
            result[kCGImagePropertyTIFFDictionary] = safe
        }
        return result
    }

    /// Default downloads live in a unique disk-original-UUID directory. Custom loaders
    /// explicitly transfer one owned copy. Remove only the file; never recurse into
    /// directories, or delete an SDK cache original. Only remove a recognized EMPTY parent.
    static func cleanupDownload(_ url: URL, appOwnedCopy: Bool = false) {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "disk-original-"
        let recognizedDirectory = parent.deletingLastPathComponent() == temp && parent.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(parent.lastPathComponent.dropFirst(prefix.count))) != nil
            && url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == parent
        guard recognizedDirectory || appOwnedCopy,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
        try? FileManager.default.removeItem(at: url)
        if recognizedDirectory, (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
