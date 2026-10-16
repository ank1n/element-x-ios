// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import XCTest

@MainActor
final class MeetingCardParityTests: XCTestCase {
    private let origin = URL(string: "https://meeting.invalid:8443")!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingCardParityURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        MeetingCardParityURLProtocol.handler = nil
        super.tearDown()
    }

    private func service(token: @escaping () throws -> String = { "session-token" },
                         refresh: (() async -> Void)? = nil) -> MeetingsService {
        MeetingsService(homeserver: origin.absoluteString + "/matrix/", accessTokenProvider: token,
                        forceTokenRefresh: refresh, session: session)
    }

    private nonisolated static func info(guest: Bool = true, extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["title": "Planning", "start_time": "2026-10-16T09:00:00Z",
                                    "end_time": NSNull(), "creator_id": "@owner:test", "guest_allowed": guest,
                                    "status": "scheduled", "encrypted": true]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testHostIsolationAndSupportedLinkForms() {
        for href in ["/meet/s/a-2", "https://meeting.invalid:8443/meet/s/a-2?from=chat#join", "vector://vector/meet/s/a-2/"] {
            let link = StalkMeetingLink.link(href, homeserver: origin)
            XCTAssertEqual(link?.code, "a-2", href)
            XCTAssertEqual(link?.url.absoluteString, "https://meeting.invalid:8443/meet/s/a-2")
        }
        for href in ["https://meeting.invalid.evil:8443/meet/s/a", "https://other.invalid/meet/s/a",
                     "https://meeting.invalid/meet/s/a", "https://user@meeting.invalid:8443/meet/s/a",
                     "//meeting.invalid:8443/meet/s/a", "vector://evil/meet/s/a", "javascript:/meet/s/a",
                     "/meet/s/a/extra", "/meet/s/a%2Fb", "/meet/s/a b"] {
            XCTAssertNil(StalkMeetingLink.link(href, homeserver: origin), href)
        }
        XCTAssertNil(StalkMeetingLink.code(in: "https://other.invalid/meet/s/a"))
        XCTAssertEqual(StalkMeetingLink.code(in: " /meet/s/a \n"), "a")
        XCTAssertNil(StalkMeetingLink.code(in: "Before /meet/s/a"))
    }

    func testBodyExtractionPreservesUnicodeTextOrderAndRepeatedLinks() {
        let body = "👋 Before /meet/s/one, between https://meeting.invalid:8443/meet/s/two. /meet/s/one after"
        let parts = StalkMeetingLink.parts(in: body, homeserver: origin)
        XCTAssertEqual(codes(parts), ["one", "two", "one"])
        XCTAssertEqual(reconstructed(parts), body)
        XCTAssertEqual(StalkMeetingLink.parts(in: "https://other.invalid/meet/s/one", homeserver: origin),
                       [.text(AttributedString("https://other.invalid/meet/s/one"))])
        for invalid in ["/meet/s/one/extra", "/meet/s/one%2Ftwo", "//other.invalid/meet/s/one"] {
            XCTAssertTrue(codes(StalkMeetingLink.parts(in: invalid, homeserver: origin)).isEmpty)
        }
    }

    func testFormattedLabelledAnchorsKeepSurroundingAttributesAndFallback() throws {
        let builder = AttributedStringBuilder(cacheKey: "meeting-parity", mentionBuilder: MentionBuilder())
        let rich = try XCTUnwrap(builder.fromHTML("<strong>Before</strong> <a href=\"/meet/s/one\">Join planning</a> <em>Between</em> <a href=\"https://meeting.invalid:8443/meet/s/two\">Second</a> After"))
        let parts = StalkMeetingLink.parts(in: "Duplicate fallback /meet/s/ignored", formattedBody: rich, homeserver: origin)
        XCTAssertEqual(codes(parts), ["one", "two"])
        XCTAssertEqual(reconstructed(parts), String(rich.characters))
        guard case let .text(before)? = parts.first else { return XCTFail("Missing prefix") }
        XCTAssertEqual(before, AttributedString(rich[rich.startIndex..<rich.characters.index(rich.startIndex, offsetBy: 7)]))
        guard case let .meeting(link) = parts[1] else { return XCTFail("Missing labelled card") }
        XCTAssertEqual(String(link.fallback.characters), "Join planning")
        XCTAssertEqual(link.url.absoluteString, "https://meeting.invalid:8443/meet/s/one")
    }

    func testCodeExamplesAndForeignAnchorsRemainText() throws {
        let builder = AttributedStringBuilder(cacheKey: "meeting-code-parity", mentionBuilder: MentionBuilder())
        let rich = try XCTUnwrap(builder.fromHTML("<code><a href=\"/meet/s/one\">Code</a></code><pre>/meet/s/two</pre><a href=\"https://other.invalid/meet/s/three\">External</a>"))
        let parts = StalkMeetingLink.parts(in: "", formattedBody: rich, homeserver: origin)
        XCTAssertTrue(codes(parts).isEmpty)
        XCTAssertEqual(parts, [.text(rich)])
    }

    func testGuestOutsideCalendarUsesOnlyPublicInfoOnSessionOrigin() async {
        MeetingCardParityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://meeting.invalid:8443/api/meetings/public-info/guest")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            XCTAssertEqual(request.timeoutInterval, 10)
            return try (200, Self.info())
        }
        let result = await service().fetchMeetingLinkPreview(code: "guest", userID: "@reader:test")
        guard case let .available(meeting) = result else { return XCTFail("Guest must not require a calendar entry") }
        XCTAssertEqual(meeting.title, "Planning")
        XCTAssertTrue(meeting.allowsGuests)
        XCTAssertTrue(meeting.isIndefinite)
        XCTAssertTrue(meeting.isEncrypted)
        XCTAssertEqual(meeting.meetingCode, "guest")
    }

    func testOwnerAndParticipantAdmissionWithBestEffortEnrichment() async {
        for owner in [true, false] {
            MeetingCardParityURLProtocol.handler = { request in
                if request.url?.path == "/_matrix/client/v3/account/whoami" {
                    return (200, Data(#"{"user_id":"@reader:test"}"#.utf8))
                }
                if request.url?.path == "/api/meetings/42" {
                    return (200, Data(#"{"attachments":[{"id":7,"filename":"Agenda"}],"color_label":"purple","title":"Must not replace public title"}"#.utf8))
                }
                return try (200, Self.info(guest: false, extra: ["id": 42,
                                                                 "creator_id": owner ? "@reader:test" : "@owner:test",
                                                                 "participants": owner ? [] : [["user_id": "@reader:test"]]]))
            }
            let result = await service().fetchMeetingLinkPreview(code: "private", userID: "@reader:test")
            guard case let .available(meeting) = result else { return XCTFail("Owner and participant are admitted") }
            XCTAssertEqual(meeting.title, "Planning")
            XCTAssertEqual(meeting.colorLabel, "purple")
            XCTAssertEqual(meeting.attachments?.count, 1)
        }
    }

    func testForbiddenDoesNotExposePrivateMetadataOrFetchDetails() async {
        MeetingCardParityURLProtocol.handler = { request in
            if request.url?.path == "/_matrix/client/v3/account/whoami" {
                return (200, Data(#"{"user_id":"@outsider:test"}"#.utf8))
            }
            XCTAssertTrue(request.url!.path.hasPrefix("/api/meetings/public-info/"))
            return try (200, Self.info(guest: false, extra: ["id": 42]))
        }
        let result = await service().fetchMeetingLinkPreview(code: "private", userID: "@outsider:test")
        XCTAssertEqual(result, .forbidden)
    }

    func testAnonymousGuestOmitsAuthorization() async {
        MeetingCardParityURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/api/meetings/public-info/guest")
            return try (200, Self.info())
        }
        let result = await service(token: { "" }).fetchMeetingLinkPreview(code: "guest")
        guard case .available = result else { return XCTFail("Guest preview may be anonymous") }
    }

    func testGuestAdmissionRequiresLiteralJSONTrueLikeWeb() async {
        let invalidFlags: [Any] = [1, "true", NSNull()]
        for flag in invalidFlags {
            MeetingCardParityURLProtocol.handler = { request in
                if request.url?.path == "/_matrix/client/v3/account/whoami" {
                    return (200, Data(#"{"user_id":"@outsider:test"}"#.utf8))
                }
                return try (200, Self.info(extra: ["guest_allowed": flag]))
            }
            let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@outsider:test")
            XCTAssertEqual(result, .forbidden)
        }
    }

    func testEnrichmentFailureKeepsMinimalAuthorisedPreview() async {
        for malformed in [false, true] {
            MeetingCardParityURLProtocol.handler = { request in
                if request.url?.path == "/_matrix/client/v3/account/whoami" {
                    return (200, Data(#"{"user_id":"@owner:test"}"#.utf8))
                }
                if request.url?.path == "/api/meetings/42" {
                    return malformed ? (200, Data(#"{"attachments":[{"bad":"attachment"}]}"#.utf8)) : (500, Data())
                }
                return try (200, Self.info(guest: false, extra: ["id": 42]))
            }
            let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@owner:test")
            guard case let .available(meeting) = result else { return XCTFail("Enrichment must be best effort") }
            XCTAssertEqual(meeting.title, "Planning")
            XCTAssertEqual(meeting.attachments, [])
        }
    }

    func testDistinctHTTPFailures() async {
        for (status, expected) in [(401, MeetingLinkPreview.unauthenticated), (403, .forbidden),
                                   (404, .missing), (410, .expired), (500, .networkError)] {
            MeetingCardParityURLProtocol.handler = { _ in (status, Data()) }
            let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
            XCTAssertEqual(result, expected)
        }
    }

    func testNetworkFailureCanBeRetriedWithoutCachedFailure() async {
        let lookup = MeetingLookupService(service: service())
        MeetingCardParityURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let failure = await lookup.preview(code: "one", userID: "@reader:test")
        XCTAssertEqual(failure, .networkError)
        MeetingCardParityURLProtocol.handler = { _ in try (200, Self.info()) }
        let retried = await lookup.preview(code: "one", userID: "@reader:test")
        guard case .available = retried else { return XCTFail("Retry must issue a fresh lookup") }
        MeetingCardParityURLProtocol.handler = { _ in (403, Data()) }
        let revoked = await lookup.preview(code: "one", userID: "@reader:test")
        XCTAssertEqual(revoked, .forbidden, "A successful preview must not mask revoked access")
    }

    func testSimultaneousIdenticalPreviewsShareOnlyTheActiveRequest() async {
        let started = expectation(description: "Shared request started")
        let gate = MeetingCardPreviewGate { started.fulfill() }
        let lookup = MeetingLookupService(service: MeetingCardSuspendedService(gate: gate))
        let first = Task { await lookup.preview(code: "one", userID: "@reader:test") }
        await fulfillment(of: [started], timeout: 2)

        let duplicates = (0..<8).map { _ in
            Task { await lookup.preview(code: "one", userID: "@reader:test") }
        }
        // These main-actor tasks enter the lookup while the underlying request is suspended.
        // A separate, immediately answered code lets their actor work proceed before release.
        let checkpoint = Task { await lookup.preview(code: "checkpoint") }
        _ = await checkpoint.value
        first.cancel() // One disappearing card must not cancel the other cards' request.
        await gate.release(.networkError)
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .networkError)
        for duplicate in duplicates {
            let result = await duplicate.value
            XCTAssertEqual(result, .networkError)
        }
        let sharedCalls = await gate.calls
        XCTAssertEqual(sharedCalls, 1)

        await gate.release(.forbidden)
        let retry = await lookup.preview(code: "one", userID: "@reader:test")
        XCTAssertEqual(retry, .forbidden)
        let callsAfterRetry = await gate.calls
        XCTAssertEqual(callsAfterRetry, 2, "A completed request must never satisfy an explicit retry")
    }

    func testInFlightRequestsAreIsolatedByCodeUserAndServiceInstance() async {
        let started = expectation(description: "Five independent requests started")
        started.expectedFulfillmentCount = 5
        let gate = MeetingCardPreviewGate { started.fulfill() }
        let lookup = MeetingLookupService(service: MeetingCardSuspendedService(gate: gate))
        let otherLookup = MeetingLookupService(service: MeetingCardSuspendedService(gate: gate))
        let tasks = [
            Task { await lookup.preview(code: "one", userID: "@alice:test") },
            Task { await lookup.preview(code: "one", userID: "@bob:test") },
            Task { await lookup.preview(code: "two", userID: "@alice:test") },
            Task { await lookup.preview(code: "one", userID: nil) },
            Task { await otherLookup.preview(code: "one", userID: "@alice:test") }
        ]
        await fulfillment(of: [started], timeout: 2)
        await gate.release(.missing)
        for task in tasks {
            let result = await task.value
            XCTAssertEqual(result, .missing)
        }
        let calls = await gate.calls
        XCTAssertEqual(calls, 5)
    }

    func testTentativeWebParticipantDoesNotBreakPreviewAdmission() async {
        MeetingCardParityURLProtocol.handler = { request in
            if request.url?.path == "/_matrix/client/v3/account/whoami" {
                return (200, Data(#"{"user_id":"@reader:test"}"#.utf8))
            }
            return try (200, Self.info(guest: false, extra: [
                "participants": [["user_id": "@reader:test", "rsvp": "tentative"]]
            ]))
        }
        let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
        guard case let .available(meeting) = result else { return XCTFail("Web tentative RSVP is a valid participant") }
        XCTAssertEqual(meeting.participants.first?.userId, "@reader:test")
    }

    func testTokenRefreshUsesFreshAuthorization() async {
        var token = "expired"
        let service = service(token: { token }, refresh: { token = "fresh" })
        MeetingCardParityURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" { return (401, Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return try (200, Self.info())
        }
        let result = await service.fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
        guard case .available = result else { return XCTFail("Expected refreshed lookup") }
    }

    func testChangedSessionDiscardsResponse() async {
        var token = "old-session"
        let service = service(token: { token })
        MeetingCardParityURLProtocol.handler = { _ in
            token = "new-session"
            return try (200, Self.info())
        }
        let result = await service.fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
        XCTAssertEqual(result, .unauthenticated)
    }

    func testOldTimelineIdentityCannotAdmitNewAccount() async {
        MeetingCardParityURLProtocol.handler = { request in
            if request.url?.path == "/_matrix/client/v3/account/whoami" {
                return (200, Data(#"{"user_id":"@new-account:test"}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/meetings/public-info/private")
            return try (200, Self.info(guest: false))
        }
        let result = await service().fetchMeetingLinkPreview(code: "private", userID: "@owner:test")
        XCTAssertEqual(result, .unauthenticated)
    }

    func testLegacyOptionalAPIResolvesIdentityWithoutLoadingCalendar() async {
        MeetingCardParityURLProtocol.handler = { request in
            if request.url?.path == "/_matrix/client/v3/account/whoami" {
                return (200, Data(#"{"user_id":"@owner:test"}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/meetings/public-info/one")
            return try (200, Self.info(guest: false))
        }
        let meeting = await MeetingLookupService(service: service()).meeting(code: "one")
        XCTAssertEqual(meeting?.title, "Planning")
    }

    func testMalformedInfoIsRetryableAndCancelledInfoStaysAvailable() async throws {
        for data in try [Data(#"{"guest_allowed":true}"#.utf8), Self.info(extra: ["start_time": "invalid"])] {
            MeetingCardParityURLProtocol.handler = { _ in (200, data) }
            let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
            XCTAssertEqual(result, .networkError)
        }
        MeetingCardParityURLProtocol.handler = { _ in try (200, Self.info(extra: ["status": "cancelled"])) }
        let result = await service().fetchMeetingLinkPreview(code: "one", userID: "@reader:test")
        guard case let .available(meeting) = result else { return XCTFail("Cancelled card must remain visible") }
        XCTAssertEqual(meeting.status, .cancelled)
    }

    func testInvalidCodeAndUnavailableTokenNeverSendRequests() async {
        MeetingCardParityURLProtocol.handler = { _ in XCTFail("No request expected"); return (500, Data()) }
        let invalid = await service().fetchMeetingLinkPreview(code: "../other", userID: "@reader:test")
        XCTAssertEqual(invalid, .networkError)
        let signedOut = await service(token: { throw URLError(.userAuthenticationRequired) }).fetchMeetingLinkPreview(code: "one")
        XCTAssertEqual(signedOut, .unauthenticated)
    }

    private func codes(_ parts: [StalkMeetingLink.Part]) -> [String] {
        parts.compactMap { if case let .meeting(link) = $0 { return link.code }; return nil }
    }

    private func reconstructed(_ parts: [StalkMeetingLink.Part]) -> String {
        parts.map {
            switch $0 {
            case let .text(text): String(text.characters)
            case let .meeting(link): String(link.fallback.characters)
            }
        }.joined()
    }
}

/// Holds service results until concurrent callers have had a chance to join. No HTTP or
/// timing sleeps are needed to inspect coalescing and independent waiter cancellation.
private actor MeetingCardPreviewGate {
    private let onFirstRequests: () -> Void
    private var released: MeetingLinkPreview?
    private var waiters: [CheckedContinuation<MeetingLinkPreview, Never>] = []
    private(set) var calls = 0

    init(onFirstRequests: @escaping () -> Void) {
        self.onFirstRequests = onFirstRequests
    }

    func fetch() async -> MeetingLinkPreview {
        calls += 1
        if let released { return released }
        onFirstRequests()
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ result: MeetingLinkPreview) {
        released = result
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }
}

private final class MeetingCardSuspendedService: MeetingsService {
    private let gate: MeetingCardPreviewGate

    init(gate: MeetingCardPreviewGate) {
        self.gate = gate
        super.init(homeserver: "https://meeting.invalid", accessTokenProvider: { "unused" })
    }

    override func fetchMeetingLinkPreview(code: String, userID: String? = nil) async -> MeetingLinkPreview {
        if code == "checkpoint" { return .missing }
        return await gate.fetch()
    }
}

private final class MeetingCardParityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
