//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Kingfisher

/// Actor-based cache service with in-memory + JSON disk persistence.
/// Uses Library/Caches/ so iOS can reclaim space automatically.
actor STalkCacheService {
    private var memory: [String: CacheEntry] = [:]
    private let cacheDir: URL
    private let fileManager = FileManager.default

    private struct CacheEntry {
        let data: Data
        let expiry: Date
    }

    init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("ru.implica.stalk/api-cache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        // 1. Check memory
        if let entry = memory[key], entry.expiry > Date() {
            return try? JSONDecoder().decode(T.self, from: entry.data)
        }

        // 2. Check disk
        let fileURL = fileURL(for: key)
        guard let wrapper = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: wrapper),
              envelope.expiry > Date() else {
            // Expired or missing — clean up
            memory[key] = nil
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        // Promote to memory
        memory[key] = CacheEntry(data: envelope.payload, expiry: envelope.expiry)
        return try? JSONDecoder().decode(T.self, from: envelope.payload)
    }

    func save<T: Encodable>(_ value: T, forKey key: String, ttl: TimeInterval) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let expiry = Date().addingTimeInterval(ttl)

        // Memory
        memory[key] = CacheEntry(data: data, expiry: expiry)

        // Disk
        let envelope = CacheEnvelope(payload: data, expiry: expiry)
        if let envelopeData = try? JSONEncoder().encode(envelope) {
            try? envelopeData.write(to: fileURL(for: key), options: .atomic)
        }
    }

    func invalidate(forKey key: String) {
        memory[key] = nil
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    func clearAll() {
        memory.removeAll()
        try? fileManager.removeItem(at: cacheDir)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Total size of disk cache in bytes
    func diskSize() -> UInt64 {
        var total: UInt64 = 0

        // API cache files
        if let enumerator = fileManager.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }

        // Downloaded recordings in tmp/recordings/
        let recordingsDir = fileManager.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
        if let enumerator = fileManager.enumerator(at: recordingsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }

        return total
    }

    /// Size of Kingfisher disk cache (avatars & images)
    nonisolated func imageCacheDiskSize() async -> UInt64 {
        await withCheckedContinuation { continuation in
            Kingfisher.ImageCache.default.calculateDiskStorageSize { result in
                switch result {
                case .success(let size):
                    continuation.resume(returning: UInt64(size))
                case .failure:
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Clear downloaded recordings
    func clearDownloadedRecordings() {
        let recordingsDir = fileManager.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
        try? fileManager.removeItem(at: recordingsDir)
        try? fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func fileURL(for key: String) -> URL {
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return cacheDir.appendingPathComponent("\(safeKey).json")
    }
}

/// Envelope for persisting cache entries to disk with TTL
private struct CacheEnvelope: Codable {
    let payload: Data
    let expiry: Date
}
