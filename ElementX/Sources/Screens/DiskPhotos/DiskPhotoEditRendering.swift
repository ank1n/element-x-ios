// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Points are normalized in the image as it existed when the operation was added.
/// Geometry and annotations are replayed in order, matching photoEditorModel.ts.
enum DiskPhotoEditOperation: Equatable {
    case rotate(clockwise: Bool)
    case flip(vertical: Bool)
    case crop(from: CGPoint, to: CGPoint)
    case adjust(brightness: Double, contrast: Double)
    case arrow(from: CGPoint, to: CGPoint, color: String)
    case rectangle(from: CGPoint, to: CGPoint, color: String)
    case redact(from: CGPoint, to: CGPoint)
    case text(at: CGPoint, text: String, color: String, size: Double)
}

struct DiskPhotoEdits: Equatable {
    // Keep the original API for existing callers and tests. New edits use ordered operations.
    var turns = 0
    var crop: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var caption = ""
    var x = 0.5
    var y = 0.8
    var operations: [DiskPhotoEditOperation] = []

    func image(from original: UIImage, maxEdge: CGFloat = 2048) throws -> UIImage {
        let sourceSize = CGSize(width: original.size.width * original.scale, height: original.size.height * original.scale)
        let ordered = legacyGeometry(size: sourceSize) + operations
        let finalSize = DiskPhotoEditRenderer.size(sourceSize, operations: ordered)
        // The legacy API bounds the final cropped image, rather than the source.
        let sourceEdge = max(sourceSize.width, sourceSize.height)
        let rasterEdge = sourceEdge * min(1, maxEdge / max(finalSize.width, finalSize.height))
        var image = try DiskPhotoEditRenderer.render(original, logicalSize: sourceSize,
                                                     operations: ordered, maxEdge: rasterEdge)
        if brightness != 0 || contrast != 1 {
            image = try DiskPhotoEditRenderer.legacyAdjust(image, brightness: brightness, contrast: contrast)
        }
        if !caption.isEmpty {
            let font = UIFont.boldSystemFont(ofSize: max(18, image.size.width / 20))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white,
                                                             .strokeColor: UIColor.black, .strokeWidth: -3]
            let textSize = (caption as NSString).size(withAttributes: attributes)
            let point = CGPoint(x: min(max(0, image.size.width * x - textSize.width / 2), max(0, image.size.width - textSize.width)),
                                y: min(max(0, image.size.height * y - textSize.height / 2), max(0, image.size.height - textSize.height)))
            let base = image
            image = DiskPhotoEditRenderer.canvas(image.size) { _ in
                base.draw(at: .zero)
                (caption as NSString).draw(at: point, withAttributes: attributes)
            }
        }
        return image
    }

    private func legacyGeometry(size: CGSize) -> [DiskPhotoEditOperation] {
        var result: [DiskPhotoEditOperation] = []
        for _ in 0..<((turns % 4 + 4) % 4) {
            result.append(.rotate(clockwise: true))
        }
        let rotated = DiskPhotoEditRenderer.size(size, operations: result)
        if crop > 0 {
            let ratio = CGFloat(crop)
            let w = min(1, rotated.height * ratio / rotated.width)
            let h = min(1, rotated.width / ratio / rotated.height)
            result.append(.crop(from: CGPoint(x: (1 - w) / 2, y: (1 - h) / 2), to: CGPoint(x: (1 + w) / 2, y: (1 + h) / 2)))
        }
        return result
    }
}

struct DiskPhotoEditHistory {
    private(set) var undoItems: [DiskPhotoEdits] = []
    private(set) var redoItems: [DiskPhotoEdits] = []
    mutating func record(_ edits: DiskPhotoEdits) {
        undoItems.append(edits)
        if undoItems.count > 60 { undoItems.removeFirst() }
        redoItems.removeAll()
    }

    mutating func undo(_ edits: inout DiskPhotoEdits) {
        guard let previous = undoItems.popLast() else { return }
        redoItems.append(edits); edits = previous
    }

    mutating func redo(_ edits: inout DiskPhotoEdits) {
        guard let next = redoItems.popLast() else { return }
        undoItems.append(edits); edits = next
    }
}

enum DiskPhotoEditRenderer {
    private struct ProtectedRedaction {
        let logical: CGRect
        let pixels: CGRect
    }

    static func unit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    static func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: unit(point.x), y: unit(point.y))
    }

    /// Exactly the web floor/ceil crop convention, including reversed drags and one-pixel crops.
    static func cropBox(_ size: CGSize, from: CGPoint, to: CGPoint) -> CGRect {
        let x = min(size.width - 1, floor(unit(min(from.x, to.x)) * size.width))
        let y = min(size.height - 1, floor(unit(min(from.y, to.y)) * size.height))
        return CGRect(x: x, y: y, width: max(1, ceil(unit(max(from.x, to.x)) * size.width) - x),
                      height: max(1, ceil(unit(max(from.y, to.y)) * size.height) - y))
    }

    static func size(_ original: CGSize, operations: [DiskPhotoEditOperation]) -> CGSize {
        operations.reduce(original) { size, op in
            switch op {
            case .rotate: return CGSize(width: size.height, height: size.width)
            case let .crop(from, to): return cropBox(size, from: from, to: to).size
            default: return size
            }
        }
    }

    static func canvas(_ size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    static func color(_ hex: String) -> UIColor {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(raw, radix: 16) ?? 0xFF3B30
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static func geometryTransform(_ operation: DiskPhotoEditOperation, size: CGSize) -> CGAffineTransform? {
        switch operation {
        case let .rotate(clockwise):
            return clockwise ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
                : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case let .flip(vertical):
            return vertical ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        case let .crop(from, to):
            let box = cropBox(size, from: from, to: to)
            return CGAffineTransform(translationX: -box.minX, y: -box.minY)
        default: return nil
        }
    }

    /// Cover every touched output pixel, not just those whose centres fall inside the box.
    /// Keep canonical geometry separately, so outward rounding never accumulates across edits.
    private static func protectedPixels(_ rect: CGRect, logicalSize: CGSize, rasterSize: CGSize) -> CGRect {
        let sx = rasterSize.width / logicalSize.width, sy = rasterSize.height / logicalSize.height
        let box = CGRect(x: floor(rect.minX * sx), y: floor(rect.minY * sy),
                         width: ceil(rect.maxX * sx) - floor(rect.minX * sx),
                         height: ceil(rect.maxY * sy) - floor(rect.minY * sy))
        return box.intersection(CGRect(origin: .zero, size: rasterSize))
    }

    private static func patchOrientation(_ operation: DiskPhotoEditOperation) -> UIImage.Orientation {
        switch operation {
        case let .rotate(clockwise): clockwise ? .right : .left
        case let .flip(vertical): vertical ? .downMirrored : .upMirrored
        default: .up
        }
    }

    /// Logical geometry always uses ORIGINAL oriented pixels. Only raster allocation is bounded.
    /// In particular preview crop rounding never changes the export's coordinate system.
    static func render(_ source: UIImage, logicalSize: CGSize, operations: [DiskPhotoEditOperation], maxEdge: CGFloat) throws -> UIImage {
        try Task.checkCancellation()
        guard logicalSize.width > 0, logicalSize.height > 0, maxEdge > 0 else { throw DiskServiceError.http(415) }
        let ratio = min(1, maxEdge / max(logicalSize.width, logicalSize.height))
        func pixels(_ size: CGSize) -> CGSize {
            CGSize(width: max(1, (size.width * ratio).rounded()), height: max(1, (size.height * ratio).rounded()))
        }
        var logical = logicalSize
        var image = canvas(pixels(logical)) { _ in source.draw(in: CGRect(origin: .zero, size: pixels(logical))) }
        var redactions: [ProtectedRedaction] = []
        for op in operations {
            try Task.checkCancellation()
            let old = image
            let oldSize = logical
            let transform = geometryTransform(op, size: oldSize)
            let protectsRaster = transform != nil && !redactions.isEmpty
            logical = size(oldSize, operations: [op])
            var transfers: [(from: CGRect, to: CGRect)] = []
            if let transform {
                redactions = redactions.compactMap { previous in
                    let rect = previous.logical.applying(transform).intersection(CGRect(origin: .zero, size: logical))
                    guard !rect.isNull, !rect.isEmpty else { return nil }
                    let target = protectedPixels(rect, logicalSize: logical, rasterSize: pixels(logical))
                    // Crop a matching section of the safe old patch if the crop cuts through it.
                    // Both boxes contain only opaque, already redacted pixels.
                    let retained = rect.applying(transform.inverted()).intersection(previous.logical)
                    let from = protectedPixels(retained, logicalSize: oldSize, rasterSize: old.size).intersection(previous.pixels)
                    transfers.append((from: from, to: target))
                    return ProtectedRedaction(logical: rect, pixels: target)
                }
            }
            if case let .redact(from, to) = op {
                let rect = cropBox(logical, from: from, to: to)
                redactions.append(ProtectedRedaction(logical: rect, pixels: protectedPixels(rect, logicalSize: logical, rasterSize: pixels(logical))))
            }
            if case let .adjust(brightness, contrast) = op {
                image = try adjust(old, brightness: brightness, contrast: contrast)
                continue
            }
            var patchFailed = false
            image = autoreleasepool { canvas(pixels(logical)) { renderer in
                let ctx = renderer.cgContext
                // Draw in logical coordinates, with separate x/y scale for integer raster rounding.
                ctx.saveGState()
                // Initial photo downsampling still uses normal interpolation. Once masked,
                // geometry must not feather a mask into adjacent source/transparent pixels.
                if protectsRaster { ctx.interpolationQuality = .none }
                ctx.scaleBy(x: pixels(logical).width / logical.width, y: pixels(logical).height / logical.height)
                if let transform { ctx.concatenate(transform) }
                old.draw(in: CGRect(origin: .zero, size: oldSize))
                ctx.restoreGState()
                // A fractional crop/rescale can interpolate an opaque mask with transparent
                // or unredacted neighbours. Repair its whole pixel footprint using ONLY a
                // cropped safe patch, including any annotations/adjustments painted over it.
                // Nearest sampling and copy blending cannot mix in the original or lower alpha.
                // Keep only rectangle metadata for the other masks. Cropped CGImages can
                // allocate/copy pixels, and UIImage may cache an oriented representation:
                // never retain an array of those surfaces for overlapping large masks.
                for transfer in transfers {
                    let drawn = autoreleasepool { () -> Bool in
                        guard !Task.isCancelled, let patch = old.cgImage?.cropping(to: transfer.from) else { return false }
                        ctx.saveGState()
                        defer { ctx.restoreGState() }
                        ctx.setShouldAntialias(false); ctx.interpolationQuality = .none
                        UIImage(cgImage: patch, scale: 1, orientation: patchOrientation(op))
                            .draw(in: transfer.to, blendMode: .copy, alpha: 1)
                        return true
                    }
                    if !drawn { patchFailed = true; return }
                }
                ctx.saveGState()
                ctx.scaleBy(x: pixels(logical).width / logical.width, y: pixels(logical).height / logical.height)
                switch op {
                case let .text(at, text, hex, textSize):
                    let font = UIFont.systemFont(ofSize: max(8, min(logical.width, logical.height) * CGFloat(textSize)), weight: .semibold)
                    (text as NSString).draw(at: CGPoint(x: unit(at.x) * logical.width, y: unit(at.y) * logical.height),
                                            withAttributes: [.font: font, .foregroundColor: color(hex)])
                case let .arrow(from, to, hex), let .rectangle(from, to, hex):
                    let a = CGPoint(x: unit(from.x) * logical.width, y: unit(from.y) * logical.height)
                    let b = CGPoint(x: unit(to.x) * logical.width, y: unit(to.y) * logical.height)
                    let short = min(logical.width, logical.height)
                    ctx.setStrokeColor(color(hex).cgColor); ctx.setFillColor(color(hex).cgColor)
                    ctx.setLineWidth(max(1, short * 0.006)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    if case .rectangle = op {
                        ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                    } else {
                        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                        let angle = atan2(b.y - a.y, b.x - a.x), head = max(8, short * 0.045)
                        ctx.move(to: b)
                        ctx.addLine(to: CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45)))
                        ctx.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45)))
                        ctx.closePath(); ctx.fillPath()
                    }
                default: break
                }
                ctx.restoreGState()
                if case .redact = op, let mask = redactions.last {
                    ctx.setShouldAntialias(false); ctx.setBlendMode(.copy)
                    ctx.setFillColor(UIColor(white: 17 / 255, alpha: 1).cgColor)
                    ctx.fill(mask.pixels)
                }
            } }
            try Task.checkCancellation()
            guard !patchFailed else { throw DiskServiceError.http(415) }
        }
        return image
    }

    static func adjust(_ image: UIImage, brightness: Double, contrast: Double) throws -> UIImage {
        let c = min(100, max(-100, contrast)), light = min(100, max(-100, brightness)) * 2.55
        let factor = 259 * (c + 255) / (255 * (259 - c))
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw DiskServiceError.http(415) }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        // Canvas adjusts unpremultiplied sRGB bytes, not linear-light Core Image colors.
        return try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                          bytesPerRow: cg.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                let pixels = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw DiskServiceError.http(415) }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                if offset % (cg.width * 4) == 0 { try Task.checkCancellation() }
                let alpha = Double(pixels[offset + 3])
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    let value = Double(pixels[offset + channel]) * 255 / alpha
                    let adjusted = min(255, max(0, factor * (value - 128) + 128 + light)).rounded(.toNearestOrEven)
                    pixels[offset + channel] = UInt8((adjusted * alpha / 255).rounded(.toNearestOrEven))
                }
            }
            guard let output = context.makeImage() else { throw DiskServiceError.http(415) }
            return UIImage(cgImage: output)
        }
    }

    static func legacyAdjust(_ image: UIImage, brightness: Double, contrast: Double) throws -> UIImage {
        guard let input = CIImage(image: image), let cg = CIContext().createCGImage(input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast]), from: input.extent) else {
            throw DiskServiceError.http(415)
        }
        return UIImage(cgImage: cg)
    }
}
