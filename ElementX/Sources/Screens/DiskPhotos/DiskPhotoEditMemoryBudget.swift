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
        #if targetEnvironment(simulator)
        let available = simulatorAvailableMemory()
        #else
        // A real device's zero allowance is authoritative. Never substitute physical RAM.
        let available = UInt64(os_proc_available_memory())
        #endif
        return Self(physicalMemory: ProcessInfo.processInfo.physicalMemory, availableMemory: available)
    }

    /// Simulator has no reliable iOS dirty-memory allowance. Count free host pages plus
    /// only one quarter of inactive pages, then cap at 512 MiB. pixelLimit still applies
    /// its separate 70% allowance factor and the full per-pixel working-memory estimate.
    static func computeSimulatorAllowance(freePages: UInt64, inactivePages: UInt64, pageSize: UInt64) -> UInt64 {
        guard pageSize > 0 else { return 0 }
        let cap: UInt64 = 512 * 1024 * 1024
        let (pages, sumOverflow) = freePages.addingReportingOverflow(inactivePages / 4)
        guard !sumOverflow else { return cap }
        let (bytes, productOverflow) = pages.multipliedReportingOverflow(by: pageSize)
        return productOverflow ? cap : min(bytes, cap)
    }

    #if targetEnvironment(simulator)
    private static func simulatorAvailableMemory() -> UInt64 {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return 0 }
        var statistics = vm_statistics64()
        let expectedCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var count = expectedCount
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, count >= expectedCount else { return 0 }
        return computeSimulatorAllowance(freePages: UInt64(statistics.free_count), inactivePages: UInt64(statistics.inactive_count), pageSize: UInt64(pageSize))
    }
    #endif

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
