// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

/// A pre-allocation estimate, not a promise that iOS will grant a large allocation.
/// Allow 32 bytes per source pixel (eight RGBA-sized surfaces) for the decoded
/// source, current/next raster, ONE cropped mask patch, oriented/colour-conversion
/// scratch, renderer readback, and encoder/data-copy headroom. Adjustment buffers
/// and encoding run in separate phases. Mask patches drain in a nested autorelease
/// pool after each draw; mask count must not multiply retained pixel storage.
/// Use at most 1/4 of device RAM and 70% of the app's CURRENT remaining dirty-memory
/// allowance. Reserve the rest for Matrix, previews and concurrent system work.
struct DiskPhotoEditMemoryBudget: Equatable {
    static let bytesPerPixel: UInt64 = 32
    static let hardPixelLimit: UInt64 = 64_000_000
    static let hardEdgeLimit: CGFloat = 16384
    let physicalMemory: UInt64
    let availableMemory: UInt64

    static var current: Self {
        Self(physicalMemory: ProcessInfo.processInfo.physicalMemory, availableMemory: UInt64(os_proc_available_memory()))
    }

    var pixelLimit: UInt64 {
        // Divide before multiplying to avoid overflow on malformed/injected values.
        min(Self.hardPixelLimit, min(physicalMemory / 4, availableMemory / 10 * 7) / Self.bytesPerPixel)
    }

    var megapixelLabel: String {
        String(format: "%.1f", locale: Locale.current, Double(pixelLimit) / 1_000_000)
    }

    func allows(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && max(size.width, size.height) <= Self.hardEdgeLimit
            && Double(size.width) * Double(size.height) <= Double(pixelLimit)
    }
}
