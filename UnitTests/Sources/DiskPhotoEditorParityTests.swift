// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class DiskPhotoEditorParityTests: XCTestCase {
    private let roomyBudget = DiskPhotoEditMemoryBudget(physicalMemory: 8 * 1024 * 1024 * 1024, availableMemory: 4 * 1024 * 1024 * 1024)
    private func image(_ size: CGSize = CGSize(width: 120, height: 80), transparent: Bool = false) -> UIImage {
        DiskPhotoEditRenderer.canvas(size) { ctx in
            guard !transparent else { return }
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                                                  bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) throws -> [Int] {
        let bytes = try pixels(image)
        let width = try XCTUnwrap(image.cgImage).width
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<offset + 4]).map(Int.init)
    }

    private func withSource(_ image: UIImage, type: UTType = .png, properties: [CFString: Any] = [:],
                            run: (DiskPhotoEditSource) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-editor-test-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "png")")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try run(DiskPhotoEditSource(url: url))
    }

    func testLegacyAPIStillBoundsFinalCropAndPreservesOriginal() throws {
        let original = image(CGSize(width: 300, height: 100))
        var edits = DiskPhotoEdits()
        edits.turns = 1; edits.crop = 1; edits.caption = "Копия"; edits.brightness = 0.1; edits.contrast = 1.2
        let output = try edits.image(from: original, maxEdge: 80)
        XCTAssertEqual(output.cgImage?.width, 80)
        XCTAssertEqual(output.cgImage?.height, 80)
        XCTAssertEqual(original.cgImage?.width, 300)
        XCTAssertEqual(try pixel(original, 10, 10), [255, 0, 0, 255])
    }

    func testWebCropRoundingReversedAndClampedDrags() {
        let size = CGSize(width: 101, height: 53)
        let box = DiskPhotoEditRenderer.cropBox(size, from: CGPoint(x: 0.801, y: 0.8), to: CGPoint(x: 0.203, y: 0.2))
        XCTAssertEqual(box, CGRect(x: 20, y: 10, width: 61, height: 33))
        XCTAssertEqual(DiskPhotoEditRenderer.cropBox(size, from: CGPoint(x: -1, y: -1), to: CGPoint(x: 3, y: 3)), CGRect(origin: .zero, size: size))
        XCTAssertEqual(DiskPhotoEditRenderer.cropBox(size, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 1, y: 1)), CGRect(x: 100, y: 52, width: 1, height: 1))
    }

    func testRotateThenCropUsesCurrentImageCoordinates() throws {
        let original = image(CGSize(width: 120, height: 80))
        let operations: [DiskPhotoEditOperation] = [.rotate(clockwise: true), .crop(from: .zero, to: CGPoint(x: 1, y: 0.5))]
        let output = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: operations, maxEdge: 1000)
        XCTAssertEqual(output.size, CGSize(width: 80, height: 60))
        XCTAssertEqual(try pixel(output, 40, 30), [255, 0, 0, 255])
        let reverse = try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                                       operations: [.crop(from: .zero, to: CGPoint(x: 1, y: 0.5)), .rotate(clockwise: true)], maxEdge: 1000)
        XCTAssertEqual(reverse.size, CGSize(width: 40, height: 120))
    }

    func testHorizontalAndVerticalMirrorAndFourRotations() throws {
        let original = image()
        let flipped = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: [.flip(vertical: false)], maxEdge: 1000)
        XCTAssertEqual(try pixel(flipped, 10, 40), [0, 0, 255, 255])
        let both = try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                                    operations: [.flip(vertical: false), .flip(vertical: false), .flip(vertical: true), .flip(vertical: true)], maxEdge: 1000)
        let rotated = try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                                       operations: Array(repeating: .rotate(clockwise: true), count: 4), maxEdge: 1000)
        XCTAssertEqual(try pixel(both, 10, 40), try pixel(original, 10, 40))
        XCTAssertEqual(try pixel(rotated, 110, 40), try pixel(original, 110, 40))
        XCTAssertEqual(rotated.size, original.size)
    }

    func testPreviewAndExportShareCanonicalCropAndAnnotationGeometry() throws {
        let original = image(CGSize(width: 1000, height: 700), transparent: true)
        let operations: [DiskPhotoEditOperation] = [
            .crop(from: CGPoint(x: 0.123, y: 0.111), to: CGPoint(x: 0.877, y: 0.889)),
            .redact(from: CGPoint(x: 0.25, y: 0.25), to: CGPoint(x: 0.75, y: 0.75)),
            .rotate(clockwise: true), .flip(vertical: false)
        ]
        let full = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: operations, maxEdge: 1000)
        let preview = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: operations, maxEdge: 200)
        let logical = DiskPhotoEditRenderer.size(original.size, operations: operations)
        XCTAssertEqual(full.size, logical)
        XCTAssertEqual(preview.size.width, (logical.width * 0.2).rounded())
        XCTAssertEqual(preview.size.height, (logical.height * 0.2).rounded())
        for p in [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.9)] {
            XCTAssertEqual(try pixel(full, Int(p.x * full.size.width), Int(p.y * full.size.height)),
                           try pixel(preview, Int(p.x * preview.size.width), Int(p.y * preview.size.height)))
        }
    }

    func testPNGRedactionIsOpaqueIncludingBoundaryAndIgnoresColor() throws {
        try withSource(image(transparent: true)) { source in
            var edits = DiskPhotoEdits()
            edits.operations = [.redact(from: CGPoint(x: 0.25, y: 0.25), to: CGPoint(x: 0.75, y: 0.75))]
            let output = try XCTUnwrap(UIImage(data: source.export(edits, format: .png, resolution: .original, keepCaptureMetadata: false, memoryBudget: roomyBudget)))
            XCTAssertEqual(try pixel(output, 0, 0)[3], 0)
            for p in [(30, 20), (89, 59), (60, 40)] {
                XCTAssertEqual(try pixel(output, p.0, p.1), [17, 17, 17, 255])
            }
            XCTAssertEqual(try pixel(output, 90, 60)[3], 0)
        }
    }

    func testRedactionThenFractionalCropStaysOpaqueInActualPreviewAndReducedPNG() throws {
        // At 2048 px reduction the crop starts at x = 251.5 raster pixels. Replaying
        // that crop with normal interpolation used to feather the mask's two x edges.
        try withSource(image(CGSize(width: 4096, height: 3072), transparent: true)) { source in
            var edits = DiskPhotoEdits()
            edits.operations = [
                .redact(from: CGPoint(x: 0.25, y: 0.25), to: CGPoint(x: 0.75, y: 0.75)),
                .crop(from: CGPoint(x: 0.123, y: 0.111), to: CGPoint(x: 0.877, y: 0.889))
            ]
            // Exercise the actual source-backed paths, not a second test renderer.
            let preview = try source.preview(edits)
            let data = try source.export(edits, format: .png, resolution: .edge2048,
                                         keepCaptureMetadata: false, memoryBudget: roomyBudget)
            let exported = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(preview.size, CGSize(width: 1056, height: 818))
            XCTAssertEqual(exported.size, CGSize(width: 1545, height: 1196))
            // Canonical crop: (503,340)-(3593,2732). The retained mask is
            // (521,428)-(2569,1964). Round each projected edge OUTWARD, without
            // changing the logical crop or rounding a previous raster a second time.
            try assertRedactionPixels(preview, box: CGRect(x: 178, y: 146, width: 700, height: 526), transparentOutside: true)
            try assertRedactionPixels(exported, box: CGRect(x: 260, y: 214, width: 1025, height: 768), transparentOutside: true)
            try attachRedactionOutputs(preview: preview, exported: exported)
        }
    }

    func testRedactionProtectionKeepsLaterAnnotationsAndAdjustmentsThroughClippedRotateAndFlip() throws {
        // The source is opaque red/blue: alpha alone would miss source-colour leakage.
        let original = image(CGSize(width: 400, height: 300))
        let operations: [DiskPhotoEditOperation] = [
            .redact(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.9, y: 0.9)),
            .rectangle(from: CGPoint(x: 0.2, y: 0.3), to: CGPoint(x: 0.35, y: 0.55), color: "#ff0000"),
            .adjust(brightness: 10, contrast: 0),
            .rotate(clockwise: true), .flip(vertical: true),
            .crop(from: CGPoint(x: 0.123, y: 0.111), to: CGPoint(x: 0.877, y: 0.889))
        ]
        let output = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: operations, maxEdge: 200)
        XCTAssertEqual(output.size, CGSize(width: 114, height: 156))
        let bytes = try pixels(output)
        var minX = 114, minY = 156, maxX = -1, maxY = -1
        for y in 0..<156 {
            for x in 0..<114 {
                let offset = (y * 114 + x) * 4
                guard bytes[offset + 3] == 255 else { return XCTFail("Redaction lost opacity at \(x),\(y)") }
                if bytes[offset] > 150, bytes[offset + 1] < 120, bytes[offset + 2] < 120 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "A repair must preserve annotations drawn over the mask")
        // Red rectangle after CW rotation, vertical flip and crop: x=99...174,
        // y=216...276 logical pixels, with a 0.5 source raster scale.
        XCTAssertEqual(Double(minX + maxX) / 2, 68.25, accuracy: 2)
        XCTAssertEqual(Double(minY + maxY) / 2, 123, accuracy: 2)
        let background = try pixel(output, 5, 5)
        XCTAssertTrue(background.prefix(3).allSatisfy { abs($0 - 43) <= 1 }, "Keep the applied adjustment; do not repaint a fresh dark mask")
    }

    func testOpaqueOriginalCannotTintRedactionEdgesAfterFractionalCrop() throws {
        let original = image(CGSize(width: 400, height: 300))
        let output = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: [
            .redact(from: CGPoint(x: 0.25, y: 0.25), to: CGPoint(x: 0.75, y: 0.75)),
            .crop(from: CGPoint(x: 0.123, y: 0.111), to: CGPoint(x: 0.877, y: 0.889))
        ], maxEdge: 137)
        XCTAssertEqual(output.size, CGSize(width: 103, height: 80))
        // All alpha values in this fixture are already 255. Checking RGB at EVERY
        // protected pixel catches interpolation with red/blue source neighbours too.
        try assertRedactionPixels(output, box: CGRect(x: 17, y: 14, width: 69, height: 52), transparentOutside: false)
    }

    func testManyOverlappingRedactionsKeepOpaqueCoverageThroughGeometry() throws {
        let original = image(CGSize(width: 400, height: 300))
        var operations = Array(repeating: DiskPhotoEditOperation.redact(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.9, y: 0.9)), count: 12)
        operations += [.rotate(clockwise: true), .flip(vertical: true),
                       .crop(from: CGPoint(x: 0.123, y: 0.111), to: CGPoint(x: 0.877, y: 0.889))]
        let output = try DiskPhotoEditRenderer.render(original, logicalSize: original.size, operations: operations, maxEdge: 200)
        XCTAssertEqual(output.size, CGSize(width: 114, height: 156))
        // The final crop is wholly inside every mask. Each streamed repair must
        // read the previous raster, not a partially painted destination patch.
        try assertRedactionPixels(output, box: CGRect(origin: .zero, size: output.size), transparentOutside: false)
    }

    private func assertRedactionPixels(_ image: UIImage, box: CGRect, transparentOutside: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let cg = try XCTUnwrap(image.cgImage, file: file, line: line)
        let bytes = try pixels(image)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let offset = (y * cg.width + x) * 4
                let inside = x >= Int(box.minX) && x < Int(box.maxX) && y >= Int(box.minY) && y < Int(box.maxY)
                if inside {
                    if bytes[offset] != 17 || bytes[offset + 1] != 17 || bytes[offset + 2] != 17 || bytes[offset + 3] != 255 {
                        return XCTFail("Mask must contain only opaque redaction colour at \(x),\(y): \(Array(bytes[offset..<offset + 4]))", file: file, line: line)
                    }
                } else if transparentOutside, bytes[offset + 3] != 0 {
                    return XCTFail("Mask geometry/alpha fringe outside expected footprint at \(x),\(y)", file: file, line: line)
                }
            }
        }
    }

    private func attachRedactionOutputs(preview: UIImage, exported: UIImage) throws {
        // These are actual production-rendered outputs in a test-only contact sheet,
        // not a reimplementation of the editor or injection into its private @State.
        for dark in [false, true] {
            let backing = dark ? Color.black : Color.white
            let content = VStack(alignment: .leading, spacing: 12) {
                Text("Actual preview · source bound 1400 px").font(.caption)
                Image(uiImage: preview).resizable().interpolation(.none).scaledToFit()
                Text("Decoded PNG export · source bound 2048 px").font(.caption)
                Image(uiImage: exported).resizable().interpolation(.none).scaledToFit()
            }
            .padding(12).frame(width: 390).background(backing)
            .foregroundStyle(dark ? Color.white : Color.black)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(rendered.size.width, 390)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Redaction then fractional crop · \(dark ? "black" : "white") background"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for (name, output) in [("Raw production preview", preview), ("Decoded reduced PNG", exported)] {
            let attachment = XCTAttachment(image: output)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testJPEGExplicitlyFlattensTransparencyToWhite() throws {
        try withSource(image(transparent: true)) { source in
            let data = try source.export(DiskPhotoEdits(), format: .jpeg, resolution: .original, keepCaptureMetadata: false, memoryBudget: roomyBudget)
            let decoded = try XCTUnwrap(UIImage(data: data))
            let sample = try pixel(decoded, 60, 40)
            XCTAssertEqual(sample[3], 255)
            XCTAssertTrue(sample.prefix(3).allSatisfy { $0 >= 250 })
            XCTAssertEqual(decoded.size, source.size)
        }
    }

    func testArrowPointsFromStartToEndAndRectangleIsAnOutline() throws {
        let original = image(CGSize(width: 400, height: 400), transparent: true)
        let arrow = try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                                     operations: [.arrow(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), color: "#34c759")], maxEdge: 400)
        XCTAssertEqual(try pixel(arrow, 200, 200), [52, 199, 89, 255])
        // The arrowhead widens only near the end; the starting end has just the shaft.
        XCTAssertGreaterThan(try pixel(arrow, 350, 203)[3], 0)
        XCTAssertEqual(try pixel(arrow, 50, 203)[3], 0)
        let rectangle = try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                                         operations: [.rectangle(from: CGPoint(x: 0.8, y: 0.8), to: CGPoint(x: 0.2, y: 0.2), color: "#5266ff")], maxEdge: 400)
        XCTAssertGreaterThan(try pixel(rectangle, 80, 200)[3], 0)
        XCTAssertEqual(try pixel(rectangle, 200, 200)[3], 0)
    }

    func testTextColorSizeAndTopLeftPlacementAffectExport() throws {
        let original = image(CGSize(width: 400, height: 400), transparent: true)
        func render(_ size: Double) throws -> UIImage {
            try DiskPhotoEditRenderer.render(original, logicalSize: original.size,
                                             operations: [.text(at: CGPoint(x: 0.25, y: 0.25), text: "MMMM", color: "#34c759", size: size)], maxEdge: 400)
        }
        let small = try render(0.04), large = try render(0.12)
        func ink(_ image: UIImage) throws -> (count: Int, green: Bool) {
            var count = 0, green = false
            let bytes = try pixels(image)
            for y in 90..<180 {
                for x in 90..<300 {
                    let offset = (y * 400 + x) * 4
                    let value = bytes[offset..<offset + 4].map(Int.init)
                    if value[3] > 200 { count += 1; green = green || value[1] > value[0] * 2 }
                }
            }
            return (count, green)
        }
        let a = try ink(small), b = try ink(large)
        XCTAssertGreaterThan(a.count, 0)
        XCTAssertGreaterThan(b.count, a.count * 2)
        XCTAssertTrue(a.green && b.green)
        XCTAssertEqual(try pixel(large, 50, 50)[3], 0)
    }

    func testObjectMovementInvertsLaterRotateFlipAndCrop() throws {
        let operations: [DiskPhotoEditOperation] = [
            .rectangle(from: CGPoint(x: 0.3, y: 0.3), to: CGPoint(x: 0.5, y: 0.5), color: "#ffffff"),
            .rotate(clockwise: true), .flip(vertical: false),
            .crop(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.9, y: 0.9))
        ]
        let size = CGSize(width: 1000, height: 800)
        let object = try XCTUnwrap(DiskPhotoEditGeometry.objects(size: size, operations: operations).first)
        let delta = object.delta(CGPoint(x: 0.1, y: -0.05))
        var moved = operations
        moved[0] = DiskPhotoEditGeometry.moved(moved[0], by: delta)
        let next = try XCTUnwrap(DiskPhotoEditGeometry.objects(size: size, operations: moved).first)
        XCTAssertEqual(next.bounds.minX - object.bounds.minX, 0.1, accuracy: 0.00001)
        XCTAssertEqual(next.bounds.minY - object.bounds.minY, -0.05, accuracy: 0.00001)
        let clamped = object.delta(CGPoint(x: 100, y: -100))
        XCTAssertTrue(abs(clamped.x) <= 1 && abs(clamped.y) <= 1)
    }

    func testUndoRedoRestoresObjectsAndNewBranchClearsRedo() {
        var edits = DiskPhotoEdits(), history = DiskPhotoEditHistory()
        history.record(edits)
        edits.operations.append(.text(at: .zero, text: "A", color: "#ff3b30", size: 0.04))
        let first = edits
        history.record(edits)
        edits.operations[0] = DiskPhotoEditGeometry.moved(edits.operations[0], by: CGPoint(x: 0.2, y: 0.3))
        let moved = edits
        history.undo(&edits); XCTAssertEqual(edits, first)
        history.redo(&edits); XCTAssertEqual(edits, moved)
        history.undo(&edits)
        history.record(edits); edits.operations.append(.flip(vertical: true))
        XCTAssertTrue(history.redoItems.isEmpty)
        let branch = edits
        history.redo(&edits); XCTAssertEqual(edits, branch)
    }

    func testWebAdjustmentPreservesAlphaAndUsesWebContrastFormula() throws {
        let original = DiskPhotoEditRenderer.canvas(CGSize(width: 10, height: 10)) { ctx in
            UIColor(white: 128 / 255, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 5, height: 10))
        }
        let output = try DiskPhotoEditRenderer.adjust(original, brightness: 10, contrast: 50)
        let value = try pixel(output, 2, 2)
        // 128 is the web contrast pivot; +10 brightness adds 25.5, independent of contrast.
        XCTAssertLessThanOrEqual(abs(value[0] - 154), 2)
        XCTAssertEqual(value[3], 255)
        XCTAssertEqual(try pixel(output, 8, 8)[3], 0)
    }

    func testExportKeepsOrStripsCaptureMetadataAndRewritesOrientationAndDimensions() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:02:29 10:00:00", kCGImagePropertyExifPixelXDimension: 999],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera", kCGImagePropertyTIFFModel: "Model"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.7, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        try withSource(image(), type: .jpeg, properties: properties) { source in
            XCTAssertEqual(source.size, CGSize(width: 80, height: 120))
            var edits = DiskPhotoEdits()
            edits.operations = [.crop(from: .zero, to: CGPoint(x: 0.5, y: 0.5))]
            for keep in [true, false] {
                let data = try source.export(edits, format: .jpeg, resolution: .original, keepCaptureMetadata: keep, memoryBudget: roomyBudget)
                let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
                XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 40)
                XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 60)
                XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
                XCTAssertNil(props[kCGImagePropertyGPSDictionary])
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, keep ? "2020:02:29 10:00:00" : nil)
            }
        }
    }

    func testOriginalExportDoesNotUseBoundedPreviewAndHugeSourceRequiresChoice() throws {
        try withSource(image(CGSize(width: 2200, height: 100))) { source in
            XCTAssertEqual(try source.image(maxEdge: 1400).cgImage?.width, 1400)
            let original = try source.export(DiskPhotoEdits(), format: .png, resolution: .original, keepCaptureMetadata: false, memoryBudget: roomyBudget)
            XCTAssertEqual(UIImage(data: original)?.cgImage?.width, 2200)
            let smaller = try source.export(DiskPhotoEdits(), format: .png, resolution: .edge2048, keepCaptureMetadata: false, memoryBudget: roomyBudget)
            XCTAssertEqual(UIImage(data: smaller)?.cgImage?.width, 2048)
        }
        // A very long, narrow fixture exercises the dimension limit without allocating a huge raster.
        try withSource(image(CGSize(width: 17000, height: 2))) { source in
            XCTAssertFalse(source.allowsOriginal(budget: roomyBudget))
            XCTAssertThrowsError(try source.export(DiskPhotoEdits(), format: .png, resolution: .original, keepCaptureMetadata: false, memoryBudget: roomyBudget))
            let smaller = try source.export(DiskPhotoEdits(), format: .png, resolution: .edge2048, keepCaptureMetadata: false, memoryBudget: roomyBudget)
            XCTAssertEqual(UIImage(data: smaller)?.cgImage?.width, 2048)
        }
    }

    func testFilenameMatchesSelectedFormatAndSanitizesPaths() throws {
        XCTAssertEqual(try DiskPhotoEditFormat.png.filename("  a/b\\c.JPEG  "), "a_b_c.png")
        XCTAssertEqual(try DiskPhotoEditFormat.jpeg.filename("Picture.png"), "Picture.jpg")
        XCTAssertThrowsError(try DiskPhotoEditFormat.png.filename("  "))
        XCTAssertThrowsError(try DiskPhotoEditFormat.jpeg.filename(".."))
    }

    func testRAMBudgetSupportsNative24And48MPOnModernDevices() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let modern = DiskPhotoEditMemoryBudget(physicalMemory: 6 * gb, availableMemory: 9 * gb / 4)
        XCTAssertTrue(modern.allows(CGSize(width: 5712, height: 4284))) // Native 24 MP.
        XCTAssertTrue(modern.allows(CGSize(width: 8064, height: 6048))) // Native 48 MP, not 48,000,000 exactly.
        let fourGB = DiskPhotoEditMemoryBudget(physicalMemory: 4 * gb, availableMemory: 2 * gb)
        XCTAssertTrue(fourGB.allows(CGSize(width: 5712, height: 4284)))
        XCTAssertFalse(fourGB.allows(CGSize(width: 8064, height: 6048)))
    }

    func test48MPGateIncludesMaskPatchAndOrientationWorkingMemory() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let native48 = CGSize(width: 8064, height: 6048)
        XCTAssertEqual(DiskPhotoEditMemoryBudget.bytesPerPixel, 32, "Budget eight RGBA-sized surfaces, including mask replay scratch")
        let requiredBytes = UInt64(8064 * 6048) * 32
        // Smallest available-memory group of ten bytes whose 70% allowance
        // covers this source. Physical RAM is ample, so only current headroom gates it.
        let minimumAvailable = ((requiredBytes + 6) / 7) * 10
        XCTAssertTrue(DiskPhotoEditMemoryBudget(physicalMemory: 8 * gb, availableMemory: minimumAvailable).allows(native48))
        XCTAssertFalse(DiskPhotoEditMemoryBudget(physicalMemory: 8 * gb, availableMemory: minimumAvailable - 10).allows(native48))
        XCTAssertFalse(DiskPhotoEditMemoryBudget(physicalMemory: 6 * gb, availableMemory: 2 * gb).allows(native48),
                       "48 MP must not bypass the additional mask replay reserve")
    }

    func testRAMBudgetUsesRemainingAppAllowanceAndHasHardBounds() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let constrained = DiskPhotoEditMemoryBudget(physicalMemory: 8 * gb, availableMemory: 256 * 1024 * 1024)
        XCTAssertFalse(constrained.allows(CGSize(width: 5712, height: 4284)))
        XCTAssertTrue(constrained.allows(CGSize(width: 2048, height: 1536)))
        XCTAssertFalse(DiskPhotoEditMemoryBudget(physicalMemory: 8 * gb, availableMemory: 0).allows(CGSize(width: 1, height: 1)))
        XCTAssertEqual(roomyBudget.pixelLimit, 64_000_000)
        XCTAssertTrue(roomyBudget.allows(CGSize(width: 8000, height: 8000)))
        XCTAssertFalse(roomyBudget.allows(CGSize(width: 8001, height: 8000)))
        XCTAssertFalse(roomyBudget.allows(CGSize(width: 16385, height: 1)))
        XCTAssertFalse(roomyBudget.allows(CGSize(width: CGFloat.nan, height: 1)))
    }

    func testRAMBudgetBoundaryReservesEncoderAndAdjustmentWorkingMemory() {
        let bytes = UInt64(8064 * 6048) * DiskPhotoEditMemoryBudget.bytesPerPixel
        let enough = DiskPhotoEditMemoryBudget(physicalMemory: bytes * 4, availableMemory: bytes * 2)
        let short = DiskPhotoEditMemoryBudget(physicalMemory: bytes * 4 - 1, availableMemory: bytes * 2)
        XCTAssertTrue(enough.allows(CGSize(width: 8064, height: 6048)))
        XCTAssertFalse(short.allows(CGSize(width: 8064, height: 6048)))
    }

    func testLowMemoryExportNeverSilentlyReducesOriginalOrUsesFinalCropToBypassBudget() throws {
        try withSource(image(CGSize(width: 2200, height: 100))) { source in
            let lowBudget = DiskPhotoEditMemoryBudget(physicalMemory: 210_000 * DiskPhotoEditMemoryBudget.bytesPerPixel * 4, availableMemory: 100_000_000)
            var edits = DiskPhotoEdits()
            edits.operations = [.crop(from: .zero, to: CGPoint(x: 0.1, y: 0.1))]
            XCTAssertThrowsError(try source.export(edits, format: .png, resolution: .original,
                                                   keepCaptureMetadata: false, memoryBudget: lowBudget))
            let reduced = try source.export(DiskPhotoEdits(), format: .png, resolution: .edge2048,
                                            keepCaptureMetadata: false, memoryBudget: lowBudget)
            XCTAssertEqual(UIImage(data: reduced)?.cgImage?.width, 2048)
            XCTAssertEqual(source.outputSize(DiskPhotoEdits(), resolution: .original).width, 2200)
        }
    }

    func testCustomLoaderCleanupRemovesOnlyTransferredCopyAndNeverDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("copy.png"), cached = directory.appendingPathComponent("sdk-original.png")
        try Data([1]).write(to: copy); try Data([2]).write(to: cached)
        DiskPhotoEditSource.cleanupDownload(copy, appOwnedCopy: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        DiskPhotoEditSource.cleanupDownload(directory, appOwnedCopy: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    func testCleanupOnlyDeletesOwnedDownloadAndNeverRecurses() throws {
        let root = FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("disk-original-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = directory.appendingPathComponent("photo.png"), other = directory.appendingPathComponent("unrelated.txt")
        try Data([1]).write(to: download); try Data([2]).write(to: other)
        DiskPhotoEditSource.cleanupDownload(download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let arbitrary = root.appendingPathComponent("unowned-\(UUID().uuidString)")
        try Data([3]).write(to: arbitrary)
        defer { try? FileManager.default.removeItem(at: arbitrary) }
        DiskPhotoEditSource.cleanupDownload(arbitrary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: arbitrary.path))
        DiskPhotoEditSource.cleanupDownload(other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
