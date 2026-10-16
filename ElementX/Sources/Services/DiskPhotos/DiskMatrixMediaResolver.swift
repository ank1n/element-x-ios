// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MatrixRustSDK

/// Resolves protected photo sources through the signed-in SDK room. Encryption keys never
/// enter files-api or a plain MXC request; mediaProvider receives the Rust source unchanged.
@MainActor
final class DiskMatrixMediaResolver {
    private let client: ClientProxyProtocol
    private let session: URLSession
    private let diagnostic: (String) -> Void
    private var diagnosticCounts: [String: Int] = [:]
    private var diagnosticTotal = 0

    private func note(_ message: String) {
        let count = diagnosticCounts[message, default: 0]
        guard count < 3, diagnosticTotal < 30 else { return }
        diagnosticCounts[message] = count + 1; diagnosticTotal += 1
        diagnostic(message)
    }

    init(client: ClientProxyProtocol, session: URLSession = .shared, diagnostic: @escaping (String) -> Void = { DiagLog.write("DiskPhotoSDK", $0) }) {
        self.client = client; self.session = session; self.diagnostic = diagnostic
    }

    func source(for file: DiskFile) async -> MediaSourceProxy? {
        guard let roomID = file.roomID, let eventID = file.eventID else {
            note("room=missing_identity event=not_requested content=unavailable"); return nil
        }
        guard !Task.isCancelled else { return nil }
        guard let relationship = await client.roomForIdentifier(roomID) else {
            note("room=not_found event=not_requested content=unavailable"); return nil
        }
        guard !Task.isCancelled else { return nil }
        let room: JoinedRoomProxyProtocol
        switch relationship {
        case .joined(let joined): room = joined
        case .invited: note("room=invited event=not_requested content=unavailable"); return nil
        case .knocked: note("room=knocked event=not_requested content=unavailable"); return nil
        case .banned: note("room=banned event=not_requested content=unavailable"); return nil
        case .left: note("room=left event=not_requested content=unavailable"); return nil
        }
        let result = await room.loadOrFetchEventDetails(for: eventID)
        guard !Task.isCancelled else { return nil }
        let event: TimelineEvent
        switch result {
        case .success(let fetched): event = fetched
        case .failure(.eventNotFound): note("room=joined event=not_found content=unavailable"); return nil
        case .failure(.sdkError): note("room=joined event=fetch_failed_sdk content=unavailable"); return nil
        case .failure: note("room=joined event=fetch_failed_other content=unavailable"); return nil
        }
        guard event.eventId() == eventID else {
            note("room=joined event=identity_mismatch content=unavailable"); return nil
        }
        do {
            let content = try event.content()
            guard case .messageLike(let message) = content else {
                note("room=joined event=matched content=non_message"); return nil
            }
            if case .roomEncrypted = message {
                note("room=joined event=matched content=encrypted_unresolved"); return nil
            }
            guard case .roomMessage(let type, _) = message else {
                note("room=joined event=matched content=non_room_message"); return nil
            }
            switch type {
            case .image(let image):
                note("room=joined event=matched content=image")
                return MediaSourceProxy(source: image.source, mimeType: image.info?.mimetype ?? file.mimetype)
            case .file(let attachment):
                guard let mime = Self.imageFileMIME(sdkMIME: attachment.info?.mimetype, filename: attachment.filename, indexedMIME: file.mimetype) else {
                    note(attachment.info?.mimetype == nil ? "room=joined event=matched content=file_missing_mime" : "room=joined event=matched content=file_non_image")
                    return nil
                }
                note("room=joined event=matched content=image_file")
                return MediaSourceProxy(source: attachment.source, mimeType: mime)
            default:
                note("room=joined event=matched content=unsupported_message"); return nil
            }
        } catch {
            note("room=joined event=matched content=decode_failed")
            return await sourceFromAuthenticatedEvent(file: file, roomID: roomID, eventID: eventID)
        }
    }

    /// The SDK event object has no raw-JSON accessor. Only after its joined-room and event-ID
    /// checks succeed, fetch that same event using the current Matrix session. Never use
    /// files-api metadata as a replacement for event content or decryption.
    private func sourceFromAuthenticatedEvent(file: DiskFile, roomID: String, eventID: String) async -> MediaSourceProxy? {
        guard !file.isEncrypted, !Task.isCancelled else {
            note("raw_fallback=encrypted_or_cancelled"); return nil
        }
        guard let url = Self.eventURL(homeserver: client.homeserver, roomID: roomID, eventID: eventID) else { return nil }
        do {
            for attempt in 0...1 {
                try Task.checkCancellation()
                let token = try client.matrixAccessToken()
                guard !token.isEmpty else { return nil }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request, delegate: DiskPhotoEventNoRedirectDelegate())
                try Task.checkCancellation()
                guard Self.isExpectedEventURL(response.url, expected: url), (try? client.matrixAccessToken()) == token else {
                    note("raw_fallback=response_identity_rejected"); return nil
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401, attempt == 0 { await client.forceTokenRefresh(); continue }
                guard status == 200, data.count <= 2 * 1024 * 1024 else {
                    note("raw_fallback=request_rejected"); return nil
                }
                // Recheck membership after the HTTP await; the cached preview is not authorization.
                guard case .joined = await client.roomForIdentifier(roomID), !Task.isCancelled else {
                    note("raw_fallback=room_no_longer_joined"); return nil
                }
                switch Self.parseVerifiedEventJSON(data, roomID: roomID, eventID: eventID) {
                case .success(let source):
                    note("raw_fallback=verified_plain_image"); return source
                case .failure(let reason):
                    // Enum constants only: never interpolate event fields, URLs, IDs, keys or errors.
                    note("raw_fallback=content_rejected reason=" + reason.rawValue); return nil
                }
            }
        } catch {
            if !Task.isCancelled { note("raw_fallback=request_failed") }
        }
        return nil
    }

    static func eventURL(homeserver: String, roomID: String, eventID: String) -> URL? {
        let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))
        guard let encodedRoom = roomID.addingPercentEncoding(withAllowedCharacters: segment),
              let encodedEvent = eventID.addingPercentEncoding(withAllowedCharacters: segment),
              var components = URLComponents(string: homeserver),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix)
            + "/_matrix/client/v3/rooms/" + encodedRoom + "/event/" + encodedEvent
        components.query = nil; components.fragment = nil
        return components.url
    }

    static func isExpectedEventURL(_ actual: URL?, expected: URL) -> Bool {
        guard let actual, let lhs = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              lhs.user == nil, lhs.password == nil, lhs.fragment == nil else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port && lhs.percentEncodedPath == rhs.percentEncodedPath && lhs.percentEncodedQuery == rhs.percentEncodedQuery
    }

    static func imageFileMIME(sdkMIME: String?, filename: String, indexedMIME: String) -> String? {
        let mime = sdkMIME ?? indexedMIME
        let formats = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif", "image/avif", "image/svg+xml"]
        guard formats.contains(mime) else { return nil }
        if sdkMIME == nil {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "svg"].contains(ext) else { return nil }
        }
        return mime
    }

    enum RawEventRejection: String, Error {
        case identityEvent = "identity_event"
        case identityRoom = "identity_room"
        case eventType = "event_type"
        case contentShape = "content_shape"
        case contentState = "content_state"
        case contentRedacted = "content_redacted"
        case contentMediaType = "content_media_type"
        case encryptedEvent = "encrypted_event"
        case encryptedFile = "encrypted_file"
        case urlMissing = "url_missing"
        case urlInvalid = "url_invalid"
        case mime
        case mediaConstructor = "media_constructor"
    }

    static func sourceFromVerifiedEventJSON(_ data: Data, roomID: String, eventID: String) -> MediaSourceProxy? {
        try? parseVerifiedEventJSON(data, roomID: roomID, eventID: eventID).get()
    }

    /// Called only after the authenticated exact-path response and current membership checks.
    /// Missing room_id is contextual; an explicit mismatching room is always rejected.
    static func parseVerifiedEventJSON(_ data: Data, roomID: String, eventID: String) -> Result<MediaSourceProxy, RawEventRejection> {
        guard data.count <= 2 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.contentShape) }
        guard root["event_id"] as? String == eventID else { return .failure(.identityEvent) }
        guard root["room_id"] == nil || root["room_id"] as? String == roomID else { return .failure(.identityRoom) }
        if root["type"] as? String == "m.room.encrypted" { return .failure(.encryptedEvent) }
        guard root["type"] as? String == "m.room.message" else { return .failure(.eventType) }
        // Optional JSON null values represent absence, never a state key or encrypted file.
        guard root["state_key"] == nil || root["state_key"] is NSNull else { return .failure(.contentState) }
        let redaction = (root["unsigned"] as? [String: Any])?["redacted_because"]
        guard redaction == nil || redaction is NSNull else { return .failure(.contentRedacted) }
        guard let content = root["content"] as? [String: Any] else { return .failure(.contentShape) }
        guard let type = content["msgtype"] as? String, ["m.image", "m.file"].contains(type) else { return .failure(.contentMediaType) }
        guard content["file"] == nil || content["file"] is NSNull else { return .failure(.encryptedFile) }
        guard let rawURL = content["url"] as? String else { return .failure(.urlMissing) }
        guard let url = URL(string: rawURL), url.scheme == "mxc", url.host?.isEmpty == false,
              !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return .failure(.urlInvalid) }
        let mime = (content["info"] as? [String: Any])?["mimetype"] as? String
        guard type == "m.image" || mime?.hasPrefix("image/") == true else { return .failure(.mime) }
        // Lift only the original; optional thumbnail metadata never enters SDK conversion.
        guard let source = try? MediaSourceProxy(url: url, mimeType: mime?.hasPrefix("image/") == true ? mime : nil) else { return .failure(.mediaConstructor) }
        return .success(source)
    }
}

final class DiskPhotoEventNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
