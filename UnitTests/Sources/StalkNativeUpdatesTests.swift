// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import SwiftUI
import UIKit
import UserNotifications
import XCTest

@MainActor
final class StalkNativeUpdatesTests: XCTestCase {
    private var sessions: [URLSession] = []
    override func tearDown() {
        sessions.forEach { $0.invalidateAndCancel() }; sessions.removeAll()
        NativeUpdatesProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativeUpdatesProtocol.self]
        let session = URLSession(configuration: config); sessions.append(session); return session
    }

    private func client() -> ClientProxyMock {
        .init(.init(homeserver: "https://native.example.invalid:8448", userID: "@reader:example.invalid"))
    }

    private func record(status: String = "ended", end: Double? = nil, recording: Bool = false, transcript: String = "none", room: String = "!room") throws -> CallTimelineRecord {
        let now = Date().timeIntervalSince1970
        let raw: [String: Any] = ["call_key": "key", "room_id": room, "status": status, "started_at": (now - 1000) * 1000,
                                  "ended_at": end.map { $0 * 1000 } as Any? ?? NSNull(), "recording": ["present": recording], "transcription": ["state": transcript]]
        return try JSONDecoder().decode(CallTimelineRecord.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testPollAgeNotFoundAndSettlingBounds() throws {
        let now = Date()
        XCTAssertEqual(CallTimelineRecord.nextPoll(record: nil, marker: now.addingTimeInterval(-30), now: now), 30)
        XCTAssertNil(CallTimelineRecord.nextPoll(record: nil, marker: now.addingTimeInterval(-601), now: now))
        XCTAssertNil(try CallTimelineRecord.nextPoll(record: record(status: "active"), marker: now.addingTimeInterval(-31 * 86400), now: now))
        XCTAssertEqual(try CallTimelineRecord.nextPoll(record: record(end: now.addingTimeInterval(-20).timeIntervalSince1970), marker: now.addingTimeInterval(-100), now: now), 60)
        XCTAssertNil(try CallTimelineRecord.nextPoll(record: record(end: now.addingTimeInterval(-901).timeIntervalSince1970), marker: now.addingTimeInterval(-1000), now: now))
        XCTAssertEqual(try CallTimelineRecord.nextPoll(record: record(end: now.addingTimeInterval(-1000).timeIntervalSince1970, recording: true, transcript: "pending"), marker: now.addingTimeInterval(-1200), now: now), 60)
        XCTAssertNil(try CallTimelineRecord.nextPoll(record: record(end: now.addingTimeInterval(-10801).timeIntervalSince1970, recording: true), marker: now.addingTimeInterval(-12000), now: now))
    }

    func testActiveAndInvalidEndAreNeverShownAsFinished() throws {
        XCTAssertFalse(try record(status: "active", end: Date().timeIntervalSince1970).ended)
        XCTAssertFalse(try record().ended)
        XCTAssertTrue(try record(end: Date().timeIntervalSince1970).ended)
    }

    func testCallForbiddenStopsAndDoesNotRetryOnSecondAppearance() async {
        var requests = 0
        NativeUpdatesProtocol.handler = { _ in requests += 1; return (403, [:]) }
        let service = CallTimelineSummaryService(roomID: "!room", client: client(), session: session())
        let marker = CallInitiateMarker(eventID: "$event", timestamp: Date(), video: true)
        await service.observe(marker); await service.observe(marker)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(service.summary(for: marker))
    }

    func testThirtyDayOldCallDoesNotRequest() async {
        var requests = 0
        NativeUpdatesProtocol.handler = { _ in requests += 1; return (404, [:]) }
        let service = CallTimelineSummaryService(roomID: "!room", client: client(), session: session())
        await service.observe(.init(eventID: "$old", timestamp: Date().addingTimeInterval(-31 * 86400), video: false))
        XCTAssertEqual(requests, 0)
    }

    func testCallOwnershipMovesToEarliestMarkerAndAuthenticatesCorrectOrigin() async {
        let end = Date().addingTimeInterval(-12000).timeIntervalSince1970
        NativeUpdatesProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "native.example.invalid")
            XCTAssertEqual(request.url?.port, 8448)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock_access_token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "room_id" }?.value, "!opaque")
            return (200, ["call_key": "same", "room_id": "!opaque", "status": "ended", "started_at": end - 100, "ended_at": end])
        }
        let service = CallTimelineSummaryService(roomID: "!opaque", client: client(), session: session())
        let later = CallInitiateMarker(eventID: "$later", timestamp: Date().addingTimeInterval(-11000), video: true)
        let earlier = CallInitiateMarker(eventID: "$earlier", timestamp: Date().addingTimeInterval(-11001), video: true)
        await service.observe(later); XCTAssertNotNil(service.summary(for: later))
        await service.observe(earlier)
        XCTAssertNil(service.summary(for: later)); XCTAssertNotNil(service.summary(for: earlier))
    }

    func testReaderModeratorEditorAdminPermissionsAreDistinct() {
        var state = StalkChannelSnapshot(verified: true, isChannel: true, joined: true, level: 0, comments: true, capability: true)
        XCTAssertFalse(state.canPublish); XCTAssertTrue(state.canComment(root: "$root")); XCTAssertFalse(state.canModerate)
        state.level = 25
        XCTAssertFalse(state.canPublish); XCTAssertTrue(state.canModerate)
        state.level = 50
        XCTAssertTrue(state.canPublish); XCTAssertFalse(state.canModerate)
        state.level = 100
        XCTAssertTrue(state.canPublish); XCTAssertTrue(state.canModerate)
        state.archived = true
        XCTAssertFalse(state.canPublish); XCTAssertFalse(state.canComment(root: "$root"))
        state.archived = false; state.closed = ["$root"]
        XCTAssertFalse(state.canComment(root: "$root"))
        state.closed = []; state.blocked = true
        XCTAssertFalse(state.canComment(root: "$root"))
        state.blocked = false; state.capability = false
        XCTAssertFalse(state.canComment(root: "$root"))
    }

    private func events(level: Int, archived: Bool = false, closed: Bool = false, blocked: Bool = false) -> [[String: Any]] {
        func event(_ type: String, _ content: [String: Any], _ key: String = "") -> [String: Any] {
            ["type": type, "state_key": key, "content": content]
        }
        return [event("m.room.create", ["type": "io.stalk.channel", "m.federate": false]),
                event("m.room.member", ["membership": "join"], "@reader:example.invalid"),
                event("m.room.power_levels", ["users": ["@reader:example.invalid": level], "users_default": 0, "events_default": 50, "unrelated": "keep", "events": ["org.example.state": 99, "m.room.message": 0, "m.room.encrypted": 0]]),
                event("io.stalk.channel.policy", ["schemaVersion": 3, "mode": "announcements", "comments": "threads"]),
                event("io.stalk.channel.lifecycle", ["archived": archived]),
                event("io.stalk.channel.thread", ["closed": closed], "$root"),
                event("io.stalk.channel.commenter", ["blocked": blocked], "user/@reader:example.invalid")]
    }

    func testReaderCannotPublishWithNativeMessagePowerZeroButCanUseCanonicalRoot() async {
        let state = events(level: 0)
        NativeUpdatesProtocol.handler = { request in
            let p = request.url!.path
            if p.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if p.hasSuffix("/state") { return (200, state) }
            if p.hasSuffix("capabilities") { return (200, ["policyVersion": 3, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"]]) }
            if p.contains("/event/") { return (200, ["event_id": "$root", "type": "m.room.message", "content": ["body": "Root"]]) }
            return (404, [:])
        }
        let service = StalkChannelService(client: client(), session: session())
        let main = await service.canSend(roomID: "!opaque", root: nil)
        let reply = await service.canSend(roomID: "!opaque", root: "$root")
        XCTAssertFalse(main); XCTAssertTrue(reply)
    }

    func testUnsupportedCapabilityAndDeletedRootDenyComments() async {
        let state = events(level: 0)
        var capability = false
        NativeUpdatesProtocol.handler = { request in
            let p = request.url!.path
            if p.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if p.hasSuffix("/state") { return (200, state) }
            if p.hasSuffix("capabilities") { return (200, ["policyVersion": capability ? 3 : 2, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"]]) }
            return (200, ["event_id": "$root", "type": "m.room.message", "content": [:], "unsigned": ["redacted_because": ["type": "m.room.redaction"]]])
        }
        let service = StalkChannelService(client: client(), session: session())
        let unsupported = await service.canSend(roomID: "!room", root: "$root")
        capability = true
        let removed = await service.canSend(roomID: "!room", root: "$root")
        XCTAssertFalse(unsupported); XCTAssertFalse(removed)
    }

    func testFormerV11CreatorIsNotElevatedAndMembershipFailureRevokesSending() async {
        let state = events(level: 0)
        var forbidden = false
        NativeUpdatesProtocol.handler = { request in
            if forbidden { return (403, [:]) }
            let path = request.url!.path
            if path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel", "room_version": "11"]) }
            if path.hasSuffix("/state") { return (200, state) }
            return (200, ["policyVersion": 3, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"]])
        }
        let service = StalkChannelService(client: client(), session: session())
        let allowed = await service.canSend(roomID: "!opaque", root: nil, creators: ["@reader:example.invalid"])
        XCTAssertFalse(allowed)
        forbidden = true
        let after = await service.canSend(roomID: "!opaque", root: "$root")
        XCTAssertFalse(after)
        XCTAssertFalse(service.snapshots["!opaque"]?.joined ?? true)
    }

    func testCommentToggleChecksGuardAndOrdersWritesWithoutReplacingOtherPowers() async throws {
        let state = events(level: 100)
        var writes: [(String, [String: Any])] = []
        var capability = true
        NativeUpdatesProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "PUT" {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var all = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; all.append(buffer, count: count)
                    }
                    body = all
                }
                let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                writes.append((path, object))
                return (200, ["event_id": "$written"])
            }
            if path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel", "m.federate": false]) }
            if path.hasSuffix("/state") { return (200, state) }
            if path.hasSuffix("/capabilities") { return (200, ["policyVersion": capability ? 3 : 2, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"]]) }
            if path.contains("/state/m.room.history_visibility") { return (200, ["history_visibility": "joined"]) }
            if let event = state.first(where: { path.contains("/state/" + ($0["type"] as! String)) }) { return (200, event["content"]!) }
            return (404, [:])
        }
        let service = StalkChannelService(client: client(), session: session())
        try await service.setComments(roomID: "!opaque", enabled: true)
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes[0].0.contains("m.room.power_levels"))
        XCTAssertTrue(writes[1].0.contains("io.stalk.channel.policy"))
        XCTAssertEqual(writes[0].1["unrelated"] as? String, "keep")
        XCTAssertEqual((writes[0].1["events"] as? [String: Any])?["org.example.state"] as? Int, 99)
        writes.removeAll()
        try await service.setComments(roomID: "!opaque", enabled: false)
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes[0].0.contains("io.stalk.channel.policy"))
        XCTAssertTrue(writes[1].0.contains("m.room.power_levels"))
        writes.removeAll(); capability = false
        do { try await service.setComments(roomID: "!opaque", enabled: true); XCTFail("Unsupported server must deny") } catch { }
        XCTAssertTrue(writes.isEmpty)
    }

    func testMenuAllowsChannelDiscussionWithoutMainReplyOrEditorModeration() {
        var item = TextRoomTimelineItem(id: .randomEvent, timestamp: Date(), isOutgoing: false, isEditable: false,
                                        canBeRepliedTo: true, sender: .init(id: "@author:example.invalid"), content: .init(body: "Post"))
        var access = StalkChannelSnapshot(verified: true, isChannel: true, joined: true, level: 0, comments: true, capability: true)
        func menu() -> TimelineItemMenuActions? {
            TimelineItemMenuActionProvider(timelineItem: item, canCurrentUserSendMessage: false,
                                           canCurrentUserRedactSelf: true, canCurrentUserRedactOthers: true, canCurrentUserPin: true,
                                           pinnedEventIDs: [], isDM: false, isViewSourceEnabled: false, areThreadsEnabled: true,
                                           timelineKind: .live, emojiProvider: EmojiProvider(appSettings: AppSettings()), bookmarkService: nil,
                                           channel: access).makeActions()
        }
        XCTAssertTrue(menu()?.actions.contains(.replyInThread) == true)
        XCTAssertFalse(menu()?.actions.contains(.reply(isThread: false)) == true)
        item.properties.isThreaded = true; access.level = 50
        XCTAssertFalse(menu()?.secondaryActions.contains(.redact) == true)
        access.level = 25
        XCTAssertTrue(menu()?.secondaryActions.contains(.redact) == true)
        item.properties.isThreaded = false
        XCTAssertFalse(menu()?.secondaryActions.contains(.redact) == true)
        access.archived = true
        XCTAssertFalse(menu()?.actions.contains(.replyInThread) == true)
        XCTAssertTrue(menu()?.reactions.isEmpty == true)
    }

    func testRenderedNativeCardAndChannelControls() async throws {
        let state = events(level: 100)
        let end = Date().addingTimeInterval(-12000).timeIntervalSince1970
        NativeUpdatesProtocol.handler = { request in
            let path = request.url!.path
            if path.contains("/api/recording/calls") {
                return (200, ["call_key": "key", "room_id": "!room", "status": "ended", "started_at": end - 120,
                              "ended_at": end, "duration_s": 120, "participants": ["guest-1"], "recording": ["present": true],
                              "transcription": ["state": "ready"], "tasks": ["total": 7, "by_group": ["backlog": 6, "started": 1]]])
            }
            if path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if path.hasSuffix("/state") { return (200, state) }
            if path.hasSuffix("/capabilities") { return (200, ["policyVersion": 3, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"]]) }
            return (200, ["mode": "muted"])
        }
        let call = CallTimelineSummaryService(roomID: "!room", client: client(), session: session())
        let marker = CallInitiateMarker(eventID: "$visual", timestamp: Date().addingTimeInterval(-11000), video: true)
        await call.observe(marker)
        XCTAssertNotNil(call.summary(for: marker))
        let channels = StalkChannelService(client: client(), session: session())
        _ = await channels.refresh(roomID: "!room")
        for size in [DynamicTypeSize.large, .xxxLarge] {
            try await capture(CallTimelineSummaryView(marker: marker, service: call)
                .frame(width: 320).environment(\.dynamicTypeSize, size), name: "Call statistics 320 \(size)", height: 700)
            try await capture(StalkChannelControlsView(service: channels, roomID: "!room", rootID: "$root")
                .frame(width: 390, height: 844).environment(\.dynamicTypeSize, size), name: "Channel controls \(size)", height: 844)
        }
    }

    private func capture<V: View>(_ view: V, name: String, height: CGFloat) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view.background(Color(uiColor: .systemBackground)).environment(\.scenePhase, .active))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: name.hasPrefix("Call") ? 320 : 390, height: height)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImmutableOrdinaryTypeSurvivesRestartWithoutNetworkOrCachingRights() async throws {
        let name = "channel-types-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        NativeUpdatesProtocol.handler = { _ in requests += 1; return (200, ["creator": "@owner:example.invalid", "room_version": "11"]) }
        let first = StalkChannelService(client: client(), session: session(), defaults: defaults)
        let initial = await first.canSend(roomID: "!ordinary", root: nil)
        XCTAssertTrue(initial)
        let before = requests
        NativeUpdatesProtocol.handler = { _ in requests += 1; return (503, [:]) }
        let reopened = StalkChannelService(client: client(), session: session(), defaults: defaults)
        let offline = await reopened.canSend(roomID: "!ordinary", root: nil)
        XCTAssertTrue(offline)
        XCTAssertEqual(requests, before)
        XCTAssertTrue(reopened.snapshots["!ordinary"]?.verified == true)
        let otherClient = ClientProxyMock(.init(homeserver: "https://other.example.invalid", userID: "@reader:example.invalid"))
        let other = StalkChannelService(client: otherClient, session: session(), defaults: defaults)
        let otherAllowed = await other.canSend(roomID: "!ordinary", root: nil)
        XCTAssertFalse(otherAllowed)
        XCTAssertGreaterThan(requests, before)
    }

    func testCallBackoffIsBoundedAndHonoursServerDelay() {
        XCTAssertEqual(CallTimelineSummaryService.failureDelay(attempt: 1), 30)
        XCTAssertEqual(CallTimelineSummaryService.failureDelay(attempt: 2), 60)
        XCTAssertEqual(CallTimelineSummaryService.failureDelay(attempt: 1, retryAfter: 120), 120)
        XCTAssertNil(CallTimelineSummaryService.failureDelay(attempt: 4, retryAfter: 999))
        XCTAssertNil(CallTimelineSummaryService.failureDelay(attempt: 1, retryAfter: .nan))
        XCTAssertNil(CallTimelineSummaryService.failureDelay(attempt: 5))
    }

    func testMembershipRevocationClearsCallAndStopsRequests() async throws {
        var count = 0
        let end = Date().addingTimeInterval(-12000).timeIntervalSince1970
        NativeUpdatesProtocol.handler = { _ in
            count += 1
            return (200, ["call_key": "key", "room_id": "!room", "status": "ended", "started_at": end - 100, "ended_at": end,
                          "participants": ["guest", "guest", "other"]])
        }
        let service = CallTimelineSummaryService(roomID: "!room", client: client(), session: session())
        let marker = CallInitiateMarker(eventID: "$revoked", timestamp: Date().addingTimeInterval(-11000), video: true)
        await service.observe(marker)
        XCTAssertEqual(service.summary(for: marker)?.uniqueParticipants, ["guest", "other"])
        service.setMembership(joined: false)
        XCTAssertNil(service.summary(for: marker))
        await service.observe(marker)
        XCTAssertEqual(count, 1)
        do { _ = try await service.detail("key"); XCTFail("Revoked detail must not load") }
        catch { XCTAssertEqual((error as? StalkNativeHTTPError)?.status, 403) }
    }

    private var administrationCaps: [String: Any] {
        ["policyVersion": 3, "threadedComments": true, "commentEventTypes": ["m.room.message", "m.room.encrypted", "m.sticker"],
         "publications": ["drafts": true, "preview": true, "scheduling": true, "formattedBody": true, "encryptedRooms": false],
         "lifecycle": ["schemaVersion": 1, "archive": true, "management": true], "historyVisibility": ["modes": ["joined", "shared"]]]
    }

    func testAdminArchiveUsesCurrentCASAndDoesNotInventEpoch() async throws {
        var state = events(level: 100)
        for i in state.indices where state[i]["type"] as? String == "io.stalk.channel.lifecycle" {
            state[i]["event_id"] = "$lifecycle"
        }
        let caps = administrationCaps
        var writes: [[String: Any]] = []
        NativeUpdatesProtocol.handler = { request in
            let p = request.url!.path
            if request.httpMethod == "POST" {
                XCTAssertTrue(p.hasSuffix("/lifecycle"))
                guard let bytes = request.httpBody, let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { XCTFail("Missing CAS payload"); return (400, [:]) }
                writes.append(json); return (200, [:])
            }
            if p.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if p.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        try await service.archive(roomID: "!room", archived: true)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["expected_event_id"] as? String, "$lifecycle")
        XCTAssertNil(writes.first?["archiveEpoch"])
    }

    func testEncryptedDraftAndSharedHistoryAreDeniedBeforeMutation() async {
        var state = events(level: 100)
        state.append(["type": "m.room.encryption", "state_key": "", "content": [:]])
        let caps = administrationCaps
        var mutations = 0; var publicationRequests = 0
        NativeUpdatesProtocol.handler = { request in
            if request.httpMethod != "GET" { mutations += 1 }
            if request.url!.path.hasSuffix("/publications") { publicationRequests += 1 }
            if request.url!.path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if request.url!.path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        do { _ = try await service.publications(roomID: "!room"); XCTFail("No plaintext drafts") } catch { }
        do { try await service.setHistory(roomID: "!room", mode: "shared"); XCTFail("No shared encrypted history") } catch { }
        XCTAssertEqual(mutations, 0); XCTAssertEqual(publicationRequests, 0)
    }

    func testUncertainPublicationNeverTriggersAnotherSendAndMarkdownEscapesHTML() async {
        let state = events(level: 50); let caps = administrationCaps
        var mutations = 0
        NativeUpdatesProtocol.handler = { request in
            if request.httpMethod != "GET" { mutations += 1 }
            if request.url!.path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if request.url!.path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        var item = StalkPublication(room_id: "!room"); item.status = "uncertain"
        do { _ = try await service.publicationAction(item, action: "publish"); XCTFail("No resend") } catch { }
        XCTAssertEqual(mutations, 0)
        item.content.setText("**Title** <script>alert(1)</script>", formatted: true)
        XCTAssertEqual(item.content.body, "**Title** <script>alert(1)</script>")
        XCTAssertFalse(item.content.formatted_body?.contains("<script>") == true)
        XCTAssertEqual(item.content.format, "org.matrix.custom.html")
    }

    func testPublicationSaveCarriesRevisionTimezoneAndExplicitNullSchedule() async throws {
        let state = events(level: 50); let caps = administrationCaps
        var written: [String: Any] = [:]
        NativeUpdatesProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/publications"), request.httpMethod == "PUT" {
                guard let bytes = request.httpBody, var body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { XCTFail(); return (400, [:]) }
                written = body; body["revision"] = 1; body["status"] = "draft"; return (200, body)
            }
            if path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        var item = StalkPublication(room_id: "!room")
        item.content.setText("**Original source**", formatted: true)
        let saved = try await service.savePublication(item)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(written["revision"] as? Int, 0)
        XCTAssertEqual(written["time_zone"] as? String, TimeZone.current.identifier)
        XCTAssertTrue(written["send_at"] is NSNull)
        XCTAssertNil(written["status"])
        XCTAssertEqual((written["content"] as? [String: Any])?["body"] as? String, "**Original source**")
    }

    func testDemotionPreventsSettingsAndPublicationMutations() async {
        let state = events(level: 0); let caps = administrationCaps
        var writes = 0
        NativeUpdatesProtocol.handler = { request in
            if request.httpMethod != "GET" { writes += 1 }
            if request.url!.path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if request.url!.path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        do { try await service.archive(roomID: "!room", archived: true); XCTFail() } catch { }
        do { try await service.setAppearance(roomID: "!room", preset: "sky"); XCTFail() } catch { }
        do { _ = try await service.savePublication(.init(room_id: "!room")); XCTFail() } catch { }
        XCTAssertEqual(writes, 0)
    }

    func testVenueAPIShowsConflictDetailsAndDoesNotLoseRequestName() async throws {
        NativeUpdatesProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer venue-token")
            XCTAssertEqual(request.url!.host, "venue.example.invalid")
            return (409, ["error": "room_busy", "conflicts": [["start": "2026-10-21T10:00:00Z", "end": "2026-10-21T11:00:00Z"]]])
        }
        let service = MeetingsService(homeserver: "https://venue.example.invalid", accessTokenProvider: { "venue-token" }, session: session())
        do {
            _ = try await service.createMeeting(.init(title: "Keep my meeting", startTime: Date(), endTime: Date().addingTimeInterval(3600), roomID: 42))
            XCTFail()
        } catch let error as MeetingVenueError {
            XCTAssertEqual(error.code, "room_busy"); XCTAssertEqual(error.conflicts.count, 1)
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertEqual(error.conflicts.first?.start, "2026-10-21T10:00:00Z")
        }
    }

    func testRenderedPublicationEditorAndVenueForm() async throws {
        let state = events(level: 100); let caps = administrationCaps
        NativeUpdatesProtocol.handler = { request in
            let p = request.url!.path
            if p.hasSuffix("/rooms/offices") { return (200, ["offices": [["id": 1, "name": "Office"]]]) }
            if p.hasSuffix("/rooms") { return (200, ["rooms": [["id": 42, "name": "Room with a long descriptive name", "office_name": "Office", "floor": "2", "capacity": 8, "equipment": ["Display"], "can_book": true, "busy": []]]]) }
            if p.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if p.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        _ = await service.refresh(roomID: "!room")
        var item = StalkPublication(room_id: "!room"); item.content.setText("**Publication**\n\nText for a channel.", formatted: true)
        let meetings = MeetingsService(homeserver: "https://venue.example.invalid", accessTokenProvider: { "token" }, session: session())
        let model = MeetingEditViewModel(service: meetings)
        model.context.venueWanted = true
        model.context.send(viewAction: .loadVenues)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.context.viewState.venuesAvailable)
        for size in [DynamicTypeSize.large, .xxxLarge] {
            try await capture(StalkChannelPublicationEditor(service: service, item: item).environment(\.dynamicTypeSize, size), name: "Publication editor \(size)", height: 844)
            try await capture(MeetingVenuePickerView(context: model.context).padding().environment(\.dynamicTypeSize, size), name: "Meeting venue form \(size)", height: 844)
        }
    }

    func testChannelForwardPreservesImageAndSourceButDropsMentionsAndRelations() throws {
        let raw = #"{"content":{"msgtype":"m.image","body":"Caption","filename":"Original.png","url":"mxc://example.invalid/image","m.mentions":{"room":true},"m.relates_to":{"rel_type":"m.thread","event_id":"$secret"}}}"#
        let json = try XCTUnwrap(StalkChannelForwarding.content(originalJSON: raw, latestEditJSON: nil, roomID: "!source:example.invalid", eventID: "$post"))
        let content = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(content["filename"] as? String, "Original.png")
        XCTAssertEqual((content[StalkChannelForwarding.key] as? [String: String])?["event_id"], "$post")
        XCTAssertNil(content["m.mentions"]); XCTAssertNil(content["m.relates_to"])
        XCTAssertNotNil(StalkChannelForwarding.sourceURL(roomID: "!" + String(repeating: "a", count: 43), eventID: "$opaque"))
        XCTAssertNil(StalkChannelForwarding.sourceURL(roomID: "https://evil.invalid", eventID: "$post"))
    }

    func testNativeDemotionAndKickRevokeOpenFormsWithoutClientSidePromotion() async {
        let state = events(level: 100); let caps = administrationCaps
        NativeUpdatesProtocol.handler = { request in
            if request.url!.path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if request.url!.path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        _ = await service.refresh(roomID: "!room")
        XCTAssertTrue(service.snapshots["!room"]?.canAdminister == true)
        service.restrictNativeAccess(roomID: "!room", joined: true, level: 0)
        XCTAssertFalse(service.snapshots["!room"]?.canAdminister == true)
        XCTAssertFalse(service.snapshots["!room"]?.canPublish == true)
        service.restrictNativeAccess(roomID: "!room", joined: true, level: 100)
        XCTAssertEqual(service.snapshots["!room"]?.level, 0)
        service.restrictNativeAccess(roomID: "!room", joined: false, level: nil)
        XCTAssertFalse(service.snapshots["!room"]?.verified == true)
    }

    func testChannelStateWatchRefreshesAppearanceAndStopsOnRevocation() async {
        var state = events(level: 100)
        state.append(["type": "io.stalk.channel.appearance", "state_key": "", "content": ["schemaVersion": 1, "preset": "sky"]])
        let caps = administrationCaps
        var syncs = 0
        NativeUpdatesProtocol.handler = { request in
            let p = request.url!.path
            if p.hasSuffix("/sync") {
                syncs += 1
                if syncs > 1 { return (403, [:]) }
                return (200, ["next_batch": "next", "rooms": ["join": ["!room": ["state": ["events": [["type": "io.stalk.channel.appearance"]]]]]],
                              "account_data": ["events": [["content": ["room_id": "!room", "root_id": "$root", "mode": "muted"]]]]])
            }
            if p.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if p.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        _ = await service.refresh(roomID: "!room")
        await service.watch(roomID: "!room")
        XCTAssertEqual(syncs, 2)
        XCTAssertEqual(service.snapshots["!room"]?.background, "sky")
        XCTAssertFalse(service.snapshots["!room"]?.joined == true)
        XCTAssertEqual(service.subscriptionRevision, 1)
    }

    func testUnchangedNativeCacheDoesNotUndoFreshServerPromotion() async {
        let state = events(level: 100); let caps = administrationCaps
        NativeUpdatesProtocol.handler = { request in
            if request.url!.path.contains("/state/m.room.create") { return (200, ["type": "io.stalk.channel"]) }
            if request.url!.path.hasSuffix("/state") { return (200, state) }
            return (200, caps)
        }
        let service = StalkChannelService(client: client(), session: session())
        service.restrictNativeAccess(roomID: "!room", joined: true, level: 0)
        _ = await service.refresh(roomID: "!room")
        service.restrictNativeAccess(roomID: "!room", joined: true, level: 0)
        XCTAssertTrue(service.snapshots["!room"]?.canAdminister == true)
        service.restrictNativeAccess(roomID: "!room", joined: false, level: 0)
        XCTAssertFalse(service.snapshots["!room"]?.canAdminister == true)
    }

    private func venueMeeting(now: Date) throws -> Meeting {
        let f = ISO8601DateFormatter()
        let start = now.addingTimeInterval(1200); let end = now.addingTimeInterval(4800)
        let body: [String: Any] = ["id": 42, "title": "Room meeting", "creator_id": "@owner:example.invalid",
                                   "start_time": f.string(from: start), "end_time": f.string(from: end),
                                   "room": ["id": 9, "name": "Room", "status": "confirmed", "start": f.string(from: start), "end": f.string(from: end),
                                            "checkin_deadline": f.string(from: start.addingTimeInterval(600)),
                                            "checkin": ["opens_at": f.string(from: start.addingTimeInterval(-900)), "deadline": f.string(from: start.addingTimeInterval(600))]]]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testCheckinWindowReleaseAuthorityAndReminderIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = try venueMeeting(now: now)
        let room = try XCTUnwrap(meeting.room)
        XCTAssertFalse(room.canCheckIn(now: now, meeting: meeting))
        XCTAssertTrue(room.canCheckIn(now: now.addingTimeInterval(300), meeting: meeting))
        XCTAssertFalse(room.canCheckIn(now: now.addingTimeInterval(5000), meeting: meeting))
        XCTAssertTrue(room.canRelease(now: now, meeting: meeting, userID: meeting.creatorId))
        XCTAssertFalse(room.canRelease(now: now, meeting: meeting, userID: "@other:example.invalid"))
        let requests = MeetingVenueReminder.requests(meetings: [meeting], userID: meeting.creatorId, now: now)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.categoryIdentifier, NotificationConstants.Category.venueCheckin)
        XCTAssertEqual(requests.first?.content.userInfo[NotificationConstants.UserInfoKey.meetingIdentifier] as? Int, 42)
        XCTAssertEqual((requests.first?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 900)
        XCTAssertTrue(MeetingVenueReminder.requests(meetings: [meeting], userID: "@other:example.invalid", now: now).isEmpty)
        let id = try XCTUnwrap(requests.first?.identifier)
        XCTAssertTrue(MeetingVenueReminder.identifiersToKeep(meetings: [meeting], userID: meeting.creatorId, now: now.addingTimeInterval(901)).contains(id))
        meeting.room?.checked_in_at = ISO8601DateFormatter().string(from: now)
        XCTAssertTrue(MeetingVenueReminder.requests(meetings: [meeting], userID: meeting.creatorId, now: now).isEmpty)
    }

    func testVenueActionUsesCurrentSessionAndRejectsUnknownActions() async throws {
        var requests = 0
        NativeUpdatesProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/42/room/checkin"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer venue-token")
            return (200, ["room": NSNull(), "room_released": NSNull()])
        }
        let service = MeetingsService(homeserver: "https://venue.example.invalid", accessTokenProvider: { "venue-token" }, session: session())
        _ = try await service.venueAction(meetingID: 42, action: "checkin")
        do { _ = try await service.venueAction(meetingID: 42, action: "other"); XCTFail() } catch { }
        XCTAssertEqual(requests, 1)
    }

    func testNumericBooleanIsNotAPowerLevel() {
        XCTAssertNil(StalkChannelService.integer(true))
        XCTAssertNil(StalkChannelService.integer(25.5))
        XCTAssertEqual(StalkChannelService.integer(25), 25)
    }
}

private final class NativeUpdatesProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            request.httpBody = body
        }
        let (code, object) = Self.handler?(request) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
