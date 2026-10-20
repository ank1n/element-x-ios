//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension NSItemProvider {
    struct PreferredContentType {
        let type: UTType
        let fileExtension: String
    }
    
    func loadTransferable<T: Transferable>(type transferableType: T.Type) async -> T? {
        try? await withCheckedContinuation { continuation in
            _ = loadTransferable(type: T.self) { result in
                continuation.resume(returning: result)
            }
        }
        .get()
    }
    
    func loadString() async -> String? {
        try? await loadItem(forTypeIdentifier: UTType.text.identifier) as? String
    }
    
    /// Stores the item's data from the provider within the temporary directory, returning the URL on success.
    /// - Parameter withinAppGroupContainer: Whether the data needs to be shared between bundles.
    /// If passing `true` you will need to manually clean up the file once you have the data in the receiving bundle.
    func storeData(withinAppGroupContainer: Bool = false) async -> URL? {
        guard let contentType = preferredContentType else {
            MXLog.error("Invalid NSItemProvider: \(self)")
            return nil
        }
        
        if contentType.type.identifier == UTType.image.identifier {
            return await generateURLForUIImage(contentType, withinAppGroupContainer: withinAppGroupContainer)
        } else {
            return await generateURLForGenericData(contentType, withinAppGroupContainer: withinAppGroupContainer)
        }
    }
    
    private func generateURLForUIImage(_ contentType: PreferredContentType, withinAppGroupContainer: Bool) async -> URL? {
        guard let uiImage = try? await loadItem(forTypeIdentifier: contentType.type.identifier) as? UIImage else {
            MXLog.error("Failed casting UIImage, invalid NSItemProvider: \(self)")
            return nil
        }
        
        guard let pngData = uiImage.pngData() else {
            MXLog.error("Failed extracting PNG data out of the UIImage")
            return nil
        }
        
        let filename = if let suggestedName = suggestedName as NSString?,
                          // Suggestions are nice but their extension is `jpeg`
                          let filename = (suggestedName.deletingPathExtension as NSString).appendingPathExtension(contentType.fileExtension) {
            filename
        } else {
            "\(UUID().uuidString).\(contentType.fileExtension)"
        }
        
        do {
            return try FileManager.default.writeDataToTemporaryDirectory(data: pngData,
                                                                         fileName: filename,
                                                                         withinAppGroupContainer: withinAppGroupContainer)
        } catch {
            MXLog.error("Failed storing NSItemProvider data \(self) with error: \(error)")
            return nil
        }
    }
    
    private func generateURLForGenericData(_ contentType: PreferredContentType, withinAppGroupContainer: Bool) async -> URL? {
        // The provider owns this URL only for the duration of its completion handler.
        // Copy inside that handler; awaiting the URL first can lose Mail/Word's file.
        if let file = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
            _ = loadFileRepresentation(forTypeIdentifier: contentType.type.identifier) { url, _ in
                continuation.resume(returning: url.flatMap {
                    try? SharedFileImport.copy($0, suggestedName: self.suggestedName,
                                               fileExtension: contentType.fileExtension,
                                               withinAppGroupContainer: withinAppGroupContainer)
                })
            }
        }) { return file }

        // Some sources only implement loadItem, with either the content type or file-url.
        var itemTypes = [contentType.type.identifier]
        if hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { itemTypes.append(UTType.fileURL.identifier) }
        for identifier in itemTypes {
            if let file = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                _ = loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    guard let url = item as? URL else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: try? SharedFileImport.copy(url, suggestedName: self.suggestedName,
                                                                              fileExtension: contentType.fileExtension, withinAppGroupContainer: withinAppGroupContainer))
                }
            }) { return file }
        }

        let providerDescription = description
        let shareData: Data? = await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(for: contentType.type) { data, error in
                if let error {
                    MXLog.error("Failed processing NSItemProvider: \(providerDescription) with error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let data else {
                    MXLog.error("Invalid NSItemProvider data: \(providerDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                continuation.resume(returning: data)
            }
        }
        
        guard let shareData else {
            MXLog.error("Invalid share data")
            return nil
        }
        
        do {
            return try SharedFileImport.write(shareData, suggestedName: suggestedName,
                                              fileExtension: contentType.fileExtension,
                                              withinAppGroupContainer: withinAppGroupContainer)
        } catch {
            MXLog.error("Failed storing shared file: \(error)")
            return nil
        }
    }

    var isSupportedForPasteOrDrop: Bool {
        preferredContentType != nil
    }
    
    var preferredContentType: PreferredContentType? {
        let supportedContentTypes = registeredContentTypes
            .filter { isMimeTypeSupported($0.preferredMIMEType) || isIdentifierSupported($0.identifier) }
        
        // If we can't find any supported types but we do find a fileURL, use
        // the sibling type that provides a correct file extension for it.
        // Return nil otherwise which will make it be inserted into the composer as text.
        guard !supportedContentTypes.isEmpty else {
            guard registeredContentTypes.contains(where: { $0.conforms(to: .fileURL) }) else {
                return nil
            }
                        
            for type in registeredContentTypes {
                if let fileExtension = type.preferredFilenameExtension {
                    return .init(type: type, fileExtension: fileExtension)
                }
            }
            
            return nil
        }
        
        // Have .jpeg take priority over .heic
        if supportedContentTypes.contains(.jpeg) {
            guard let fileExtension = preferredFileExtension(for: .jpeg) else {
                return nil
            }
            
            return .init(type: .jpeg, fileExtension: fileExtension)
        }
        
        guard let preferredContentType = supportedContentTypes.first,
              let fileExtension = preferredFileExtension(for: preferredContentType) else {
            return nil
        }
        
        return .init(type: preferredContentType, fileExtension: fileExtension)
    }
    
    private func preferredFileExtension(for contentType: UTType) -> String? {
        if let fileExtension = contentType.preferredFilenameExtension {
            return fileExtension
        }
        
        switch contentType.identifier {
        case UTType.image.identifier:
            return "png"
        default:
            return nil
        }
    }
    
    private func isIdentifierSupported(_ identifier: String?) -> Bool {
        // Don't filter out generic public.image content as screenshots are in this format
        // and we can convert them to a PNG ourselves.
        identifier == UTType.image.identifier
    }
    
    private func isMimeTypeSupported(_ mimeType: String?) -> Bool {
        guard let mimeType else {
            return false
        }
        
        // Prevents media upload triggering for text copied from Notes.app #1247
        if mimeType == "application/x-webarchive" {
            return false
        }
        
        return mimeType.hasPrefix("application/") ||
            mimeType.hasPrefix("audio/") ||
            mimeType.hasPrefix("image/") ||
            mimeType.hasPrefix("video/")
    }
}

private extension NSString {
    var hasPathExtension: Bool {
        !pathExtension.isEmpty
    }
}

/// Preserve a document's filename while isolating same-named attachments in separate directories.
enum SharedFileImport {
    static func filename(original: String?, suggested: String?, fileExtension: String) -> String {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let name = (value as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\0"), !name.contains("/"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return name
        }
        let source = clean(original)
        let suggestion = clean(suggested)
        let systemName = source.map { UUID(uuidString: ($0 as NSString).deletingPathExtension) != nil || ($0 as NSString).deletingPathExtension.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil } ?? false
        let name = source.flatMap { systemName && suggestion != nil ? nil : $0 } ?? suggestion ?? UUID().uuidString
        return (name as NSString).pathExtension.isEmpty ? name + "." + fileExtension : name
    }

    private static func destination(name: String, withinAppGroupContainer: Bool) throws -> URL {
        let base: URL = withinAppGroupContainer ? .appGroupTemporaryDirectory : .temporaryDirectory
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    static func copy(_ source: URL, suggestedName: String?, fileExtension: String,
                     withinAppGroupContainer: Bool) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        let target = try destination(name: filename(original: source.lastPathComponent, suggested: suggestedName,
                                                    fileExtension: fileExtension), withinAppGroupContainer: withinAppGroupContainer)
        do { try FileManager.default.copyItem(at: source, to: target); return target }
        catch { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); throw error }
    }

    static func write(_ data: Data, suggestedName: String?, fileExtension: String,
                      withinAppGroupContainer: Bool) throws -> URL {
        let target = try destination(name: filename(original: nil, suggested: suggestedName, fileExtension: fileExtension),
                                     withinAppGroupContainer: withinAppGroupContainer)
        do { try data.write(to: target, options: .atomic); return target }
        catch { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); throw error }
    }
}
