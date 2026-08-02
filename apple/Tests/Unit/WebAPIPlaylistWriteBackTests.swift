import XCTest
@testable import PocketDJ

/// The macOS Apple Music write-back transport — driven end to end against a fake sender (no
/// account, no entitlement, no network). Every test here pins one of the traps that make the Web
/// API path different from the MusicKit one.
@MainActor
final class WebAPIPlaylistWriteBackTests: XCTestCase {

    /// Records every request and replies from a scripted table keyed by "METHOD path".
    final class FakeSender: AppleMusicWebSender {
        var canSend = true
        var sent: [URLRequest] = []
        /// key → (status, body). Missing key ⇒ 200 with an empty `data` list.
        var replies: [String: (Int, Data)] = [:]

        static func key(_ r: URLRequest) -> String {
            "\(r.httpMethod ?? "GET") \(r.url?.path ?? "")"
        }
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            sent.append(request)
            if let (status, body) = replies[Self.key(request)] { return (body, status) }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }
        var posts: [URLRequest] { sent.filter { $0.httpMethod == "POST" } }
    }

    private func make() -> (WebAPIPlaylistWriteBackTransport, FakeSender) {
        let s = FakeSender()
        return (WebAPIPlaylistWriteBackTransport(sender: s), s)
    }

    private func playlistsJSON(_ rows: [(String, String, Bool?)]) -> Data {
        let data = rows.map { id, name, canEdit -> [String: Any] in
            var attrs: [String: Any] = ["name": name]
            if let canEdit { attrs["canEdit"] = canEdit }
            return ["id": id, "attributes": attrs]
        }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    private func tracksJSON(_ catalogIds: [String]) -> Data {
        let data = catalogIds.map { ["attributes": ["playParams": ["catalogId": $0]]] }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    // MARK: Trap 1 — 404 on the tracks GET means EMPTY, not gone

    /// The most common case this transport serves: the FIRST add to a playlist that has no tracks
    /// yet. Apple answers the tracks route with 404 for an empty playlist, and the app's own Lambda
    /// documents the same. Mapping that to `playlistGone` would brick exactly this path.
    func testFirstAddToAnEmptyPlaylistSucceedsDespiteA404OnTracks() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists/p.1/tracks"] = (404, Data())

        try await t.addSong(appleMusicId: "1234", toPlaylistId: "p.1")

        XCTAssertEqual(s.posts.count, 1, "an empty playlist must still receive the add")
        XCTAssertEqual(s.posts.first?.url?.path, "/v1/me/library/playlists/p.1/tracks")
    }

    /// …but a 404 from the POST itself DOES mean the playlist is gone, so the queue can drop its
    /// cached id and re-resolve by name.
    func testPostReturning404IsPlaylistGone() async {
        let (t, s) = make()
        s.replies["POST /v1/me/library/playlists/p.1/tracks"] = (404, Data())
        do {
            try await t.addSong(appleMusicId: "1234", toPlaylistId: "p.1")
            XCTFail("expected playlistGone")
        } catch let e as PlaylistWriteBackError {
            guard case .playlistGone = e else { return XCTFail("expected playlistGone, got \(e)") }
        } catch { XCTFail("expected playlistGone, got \(error)") }
    }

    // MARK: Idempotency — never append a second copy

    func testAlreadyPresentSongIsNotPosted() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists/p.1/tracks"] = (200, tracksJSON(["1234", "9999"]))

        try await t.addSong(appleMusicId: "1234", toPlaylistId: "p.1")

        XCTAssertTrue(s.posts.isEmpty,
                      "the POST is not idempotent — a re-delivery would append a SECOND copy")
    }

    func testAbsentSongIsPostedWithTheExactBodyAppleExpects() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists/p.1/tracks"] = (200, tracksJSON(["9999"]))

        try await t.addSong(appleMusicId: "1234", toPlaylistId: "p.1")

        let post = try XCTUnwrap(s.posts.first)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: Any]
        let rows = try XCTUnwrap(body?["data"] as? [[String: String]])
        XCTAssertEqual(rows, [["id": "1234", "type": "songs"]])
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: Paging — a short read here means a DUPLICATE in the user's real playlist

    /// The membership scan must page on the ROW count, not on the deduped id set. A full page whose
    /// rows contain one repeated track yields 99 distinct ids; terminating on that stopped the walk
    /// with tracks unread, and `addSong` then appended a second copy of a song that WAS already
    /// there — which macOS cannot remove, because the Web API has no remove route.
    func testFullPageWithADuplicateRowStillPagesOn() async throws {
        let (t, s) = make()
        // Page 1: 100 rows, but only 99 distinct ids (one track appears twice).
        var firstPageIds = (1...99).map(String.init)
        firstPageIds.append("1")
        XCTAssertEqual(firstPageIds.count, 100)
        XCTAssertEqual(Set(firstPageIds).count, 99, "precondition: the page is full but dedupes to 99")

        var callCount = 0
        final class Paging: AppleMusicWebSender {
            var canSend = true
            var bodies: [Data] = []
            var calls = 0
            var posts: [URLRequest] = []
            func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
                if request.httpMethod == "POST" { posts.append(request); return (Data(), 200) }
                defer { calls += 1 }
                return (calls < bodies.count ? bodies[calls] : Data(#"{"data":[]}"#.utf8), 200)
            }
        }
        let pager = Paging()
        func rows(_ ids: [String]) -> Data {
            try! JSONSerialization.data(withJSONObject:
                ["data": ids.map { ["attributes": ["playParams": ["catalogId": $0]]] }])
        }
        // Page 1 (100 rows / 99 ids), page 2 contains the song we're about to add.
        pager.bodies = [rows(firstPageIds), rows(["target"])]
        let transport = WebAPIPlaylistWriteBackTransport(sender: pager)

        try await transport.addSong(appleMusicId: "target", toPlaylistId: "p.1")

        callCount = pager.calls
        XCTAssertGreaterThanOrEqual(callCount, 2, "the walk must not stop on a deduped page")
        XCTAssertTrue(pager.posts.isEmpty,
                      "the song was already in the playlist on page 2 — appending it would duplicate it")
    }

    /// The API's own `next` cursor also keeps the walk going, even when a page looks short.
    func testNextCursorKeepsPagingEvenOnAShortPage() {
        let withNext = try! JSONSerialization.data(withJSONObject: [
            "data": [["attributes": ["playParams": ["catalogId": "1"]]]],
            "next": "/v1/me/library/playlists/p.1/tracks?offset=100",
        ])
        let page = AppleMusicWebAPI.parseTrackPage(withNext)
        XCTAssertTrue(page.hasNext)
        XCTAssertEqual(page.rowCount, 1)
        XCTAssertEqual(page.catalogIds, ["1"])
    }

    /// A row with no `playParams` must still count toward paging, or the same truncation returns.
    func testRowWithoutPlayParamsStillCountsAsARow() {
        let mixed = try! JSONSerialization.data(withJSONObject: ["data": [
            ["attributes": ["playParams": ["catalogId": "1"]]],
            ["attributes": [:]],
        ]])
        let page = AppleMusicWebAPI.parseTrackPage(mixed)
        XCTAssertEqual(page.rowCount, 2, "row count is rows, not resolvable ids")
        XCTAssertEqual(page.catalogIds, ["1"])
    }

    // MARK: A transient failure must never become "this song isn't on Apple Music"

    /// `resolveCatalogId` returning nil is TERMINAL: the queue settles the job `.unresolvable` with
    /// "this song isn't on Apple Music", and `retry` won't re-arm that state. So a momentarily
    /// expired token must THROW (retryable), never answer nil.
    func testStorefrontAuthFailureThrowsRatherThanReportingNoMatch() async {
        let (t, s) = make()
        s.replies["GET /v1/me/storefront"] = (403, Data())
        do {
            _ = try await t.resolveCatalogId(
                for: WriteBackSong(appleMusicId: "", title: "Neon", artist: "Aria",
                                   album: nil, durationMs: nil))
            XCTFail("expected a throw — nil would permanently mark the song as not on Apple Music")
        } catch let e as PlaylistWriteBackError {
            guard case .notAuthorized = e else { return XCTFail("expected notAuthorized, got \(e)") }
        } catch { XCTFail("expected notAuthorized, got \(error)") }
    }

    func testStorefrontServerErrorThrowsRatherThanReportingNoMatch() async {
        let (t, s) = make()
        s.replies["GET /v1/me/storefront"] = (503, Data())
        do {
            _ = try await t.resolveCatalogId(
                for: WriteBackSong(appleMusicId: "", title: "Neon", artist: "Aria",
                                   album: nil, durationMs: nil))
            XCTFail("expected a throw on a 5xx")
        } catch { /* any throw is correct — the queue retries */ }
    }

    // MARK: Trap 2 — an absent `canEdit` means EDITABLE

    /// `attributes.canEdit` is optional in the API. Defaulting a missing value to false would
    /// filter out every candidate — on the one platform this transport exists to serve.
    func testPlaylistWithNoCanEditFieldIsTreatedAsEditable() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists"] = (200, playlistsJSON([("p.7", "Road Trip", nil)]))

        let id = try await t.resolvePlaylistId(name: "Road Trip", expectedAppleMusicIds: [])

        XCTAssertEqual(id, "p.7", "absent canEdit must not exclude the playlist")
    }

    func testExplicitlyUneditablePlaylistIsExcluded() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists"] = (200, playlistsJSON([("p.8", "Smart List", false)]))

        let id = try await t.resolvePlaylistId(name: "Smart List", expectedAppleMusicIds: [])

        XCTAssertNil(id, "a playlist Apple says we cannot edit is not a candidate")
    }

    // MARK: Name matching — the same three tiers the MusicKit transport uses

    func testNameMatchFallsBackFromExactToTrimmedToFolded() {
        let rows = [AppleMusicWebAPI.LibraryPlaylist(id: "a", name: "Sap ", canEdit: true),
                    AppleMusicWebAPI.LibraryPlaylist(id: "b", name: "sap", canEdit: true)]
        // Tier 1: exact.
        XCTAssertEqual(WriteBackPlaylistMatcher.candidates(named: "Sap ", in: rows).map(\.id), ["a"])
        // Tier 2: whitespace-trimmed — the real "Sweet Thing" bug, where Library.xml carried a
        // trailing space the live library did not.
        XCTAssertEqual(WriteBackPlaylistMatcher.candidates(named: "Sap", in: rows).map(\.id), ["a"])
        // Tier 3: case/diacritic folded.
        let onlyLower = [AppleMusicWebAPI.LibraryPlaylist(id: "b", name: "sap", canEdit: true)]
        XCTAssertEqual(WriteBackPlaylistMatcher.candidates(named: "SAP", in: onlyLower).map(\.id), ["b"])
    }

    /// Duplicate names are arbitrated by track overlap; with none, the answer is a GUESS and must
    /// say so — a rename off a guess is unrecoverable.
    func testDuplicateNamesArbitrateOnOverlapAndOtherwiseFlagAGuess() async throws {
        let (t, s) = make()
        s.replies["GET /v1/me/library/playlists"] =
            (200, playlistsJSON([("p.1", "Mix", true), ("p.2", "Mix", true)]))
        s.replies["GET /v1/me/library/playlists/p.2/tracks"] = (200, tracksJSON(["777"]))

        let id = try await t.resolvePlaylistId(name: "Mix", expectedAppleMusicIds: ["777"])
        XCTAssertEqual(id, "p.2", "the one that actually shares tracks wins")
        XCTAssertNil(t.lastResolutionNote, "an arbitrated answer is not a guess")

        let (t2, s2) = make()
        s2.replies["GET /v1/me/library/playlists"] =
            (200, playlistsJSON([("p.1", "Mix", true), ("p.2", "Mix", true)]))
        _ = try await t2.resolvePlaylistId(name: "Mix", expectedAppleMusicIds: [])
        XCTAssertNotNil(t2.lastResolutionNote, "no overlap to arbitrate ⇒ the caller must know it's a guess")
    }

    // MARK: Authorization — a job must stay QUEUED, not be discarded

    func testUnauthorizedThrowsNotAuthorizedAndSendsNothing() async {
        let (t, s) = make()
        s.canSend = false
        XCTAssertFalse(t.canWrite)
        do {
            try await t.addSong(appleMusicId: "1", toPlaylistId: "p.1")
            XCTFail("expected notAuthorized")
        } catch let e as PlaylistWriteBackError {
            guard case .notAuthorized = e else { return XCTFail("expected notAuthorized, got \(e)") }
        } catch { XCTFail("expected notAuthorized, got \(error)") }
        XCTAssertTrue(s.sent.isEmpty)
    }

    // MARK: Capability — supported, but append-only

    func testSupportedButReconcileReportsUnsupported() async throws {
        let (t, _) = make()
        XCTAssertTrue(t.isSupported,
                      "the Web API has no platform restriction — jobs must not settle as notApplicable")
        let result = try await t.reconcile(playlistId: "p.1", orderedAppleMusicIds: ["1"])
        XCTAssertEqual(result, .unsupported,
                       "removals and reorders have no Web API route — say so rather than no-op silently")
    }

    // MARK: Request building

    func testPlaylistIdIsPercentEscapedIntoThePath() {
        let r = AppleMusicWebAPI.addTracksRequest(playlistId: "p.1/../evil", catalogIds: ["1"])
        // Assert on the ENCODED string: `URL.path` percent-DECODES, so it shows the separators back
        // again even when they were correctly escaped. What matters is that the slashes went out as
        // %2F, so the server sees one path component rather than a traversal.
        XCTAssertEqual(r.url!.absoluteString,
                       "https://api.music.apple.com/v1/me/library/playlists/p.1%2F..%2Fevil/tracks",
                       "the id is escaped into ONE path component — no traversal, no extra segments")
    }

    // MARK: Parsing

    func testParseTrackCatalogIdsReadsPlayParams() {
        XCTAssertEqual(AppleMusicWebAPI.parseTrackCatalogIds(tracksJSON(["1", "2"])), ["1", "2"])
        XCTAssertTrue(AppleMusicWebAPI.parseTrackCatalogIds(Data("not json".utf8)).isEmpty,
                      "a malformed body degrades to empty, never throws")
    }

    func testParseCatalogSongsMapsMillisecondsToSeconds() {
        let json = try! JSONSerialization.data(withJSONObject: ["results": ["songs": ["data": [
            ["id": "42", "attributes": ["name": "Neon", "artistName": "Aria",
                                        "albumName": "Night Drive", "durationInMillis": 200_000]]
        ]]]])
        let out = AppleMusicWebAPI.parseCatalogSongs(json)
        XCTAssertEqual(out.first?.id, "42")
        XCTAssertEqual(out.first?.title, "Neon")
        XCTAssertEqual(out.first?.durationSec ?? 0, 200, accuracy: 0.001)
    }
}
