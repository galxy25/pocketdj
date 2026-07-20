import XCTest
@testable import PocketDJ

/// A minimal `GET /v1/me/ratings/songs` response body. Only `data[].id` and
/// `attributes.value` are load-bearing; the rest is what Apple actually sends alongside.
private func ratingsPayload(loved: [String], disliked: [String] = []) -> Data {
    let rows: [[String: Any]] =
        loved.map { ["id": $0, "type": "ratings", "attributes": ["value": 1]] }
        + disliked.map { ["id": $0, "type": "ratings", "attributes": ["value": -1]] }
    return (try? JSONSerialization.data(withJSONObject: ["data": rows])) ?? Data()
}

/// The ids query value of a request, or nil. The two endpoints spell the parameter
/// differently: the ★ POST is type-scoped (`ids[songs]`, per Apple's "follow the ids with
/// one of the allowed values"), while the ratings GET takes a bare `ids`.
private func idsQuery(_ req: URLRequest, name: String = "ids") -> String? {
    guard let url = req.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

/// `FavoritesSyncService` — the OWNER-ONLY bridge between local ♥ and Apple Music, driven
/// end-to-end against a recording transport (no MusicKit, no account, no network) with both
/// the owner gate and the seed fetch stubbed.
///
/// The two properties worth breaking a build over: a NON-OWNER install must emit literally
/// zero Apple Music traffic, and a failed write must leave the toggle pending rather than
/// silently dropping it.
@MainActor
final class FavoritesSyncServiceTests: XCTestCase {

    /// Records every request and lets a test script the reply (or a rejection) per request.
    @MainActor
    private final class RecordingTransport: AppleMusicFavoritesTransport {
        var canSync = true
        private(set) var requests: [URLRequest] = []
        var responder: (URLRequest) throws -> Data = { _ in Data() }

        func send(_ request: URLRequest) async throws -> Data {
            requests.append(request)
            return try responder(request)
        }

        /// "METHOD /path" per request, in order — the shape the ordering assertions read.
        var trace: [String] { requests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "?")" } }
    }

    private struct Rejected: Error {}

    private func makeFavorites(_ json: String? = nil) -> FavoritesStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-favsync-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        if let json { try? Data(json.utf8).write(to: url, options: .atomic) }
        return FavoritesStore(fileURL: url)
    }

    private func makeService(owner: Bool,
                             favorites: FavoritesStore,
                             transport: RecordingTransport?,
                             seed: FavoritesSyncService.Seed? = nil) -> FavoritesSyncService {
        let svc = FavoritesSyncService(favorites: favorites, transport: transport)
        svc.ownerCheck = { owner }
        svc.fetchSeed = {
            guard let seed else { throw URLError(.fileDoesNotExist) }
            return try JSONEncoder().encode(seed)
        }
        return svc
    }

    // MARK: - The gate

    func testNonOwnerAppliesTheSeedAndSendsNothing() async {
        let favs = makeFavorites()
        let t = RecordingTransport()
        let svc = makeService(owner: false, favorites: favs, transport: t,
                              seed: FavoritesSyncService.Seed(version: 4,
                                                              songIds: ["sng_a", "sng_b"],
                                                              appleMusicIds: ["sng_a": "1"]))
        svc.catalogAppleMusicIds = { [("sng_a", "1"), ("sng_b", "2")] }

        await svc.run()

        XCTAssertEqual(svc.isOwner, false)
        XCTAssertNil(svc.lastError)
        XCTAssertTrue(favs.isFavorite("sng_a"))
        XCTAssertTrue(favs.isFavorite("sng_b"), "a seeded song with no catalog id still seeds locally")
        XCTAssertEqual(favs.seedVersion, 4)
        XCTAssertTrue(t.requests.isEmpty,
                      "a tester's install NEVER touches Apple Music — not even to READ")
        XCTAssertTrue(favs.pendingPushes.isEmpty,
                      "and the seed queues nothing that could leak upstream later")

        // A later un-♥ plus another pass: still no traffic, and no reseed over the tombstone.
        favs.toggle("sng_a", appleMusicId: "1")
        await svc.run()
        XCTAssertFalse(favs.isFavorite("sng_a"))
        XCTAssertTrue(t.requests.isEmpty)
    }

    // MARK: - Outbound

    func testOwnerPushesStarAndRatingThenPulls() async {
        let favs = makeFavorites()
        favs.toggle("sng_a", appleMusicId: "1")
        favs.toggle("sng_vinyl", appleMusicId: nil)      // local-only: nothing to mirror

        let t = RecordingTransport()
        t.responder = { req in req.httpMethod == "GET" ? ratingsPayload(loved: ["1"]) : Data() }
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [("sng_a", "1")] }

        await svc.run()

        XCTAssertEqual(svc.isOwner, true)
        XCTAssertEqual(t.trace, ["POST /v1/me/favorites",
                                 "PUT /v1/me/ratings/songs/1",
                                 "GET /v1/me/ratings/songs"],
                       "the ★ batch, then the reversible per-song rating, then the read-back")
        XCTAssertEqual(idsQuery(t.requests[0], name: "ids[songs]"), "1",
                       "the vinyl ♥ has no Apple Music identity and never leaves the device")
        XCTAssertEqual(String(decoding: t.requests[1].httpBody ?? Data(), as: UTF8.self),
                       #"{"type":"rating","attributes":{"value":1}}"#)
        XCTAssertEqual(idsQuery(t.requests[2]), "1")

        XCTAssertTrue(favs.pendingPushes.isEmpty, "a successful push drains the queue")
        XCTAssertNotNil(favs.entry("sng_a")?.pushedAtMs)
        XCTAssertTrue(favs.isFavorite("sng_vinyl"), "the local-only ♥ is untouched by the sync")
        XCTAssertNotNil(svc.lastSyncedAtMs)
        XCTAssertNil(svc.lastError)
    }

    func testFailedRatingWriteLeavesTheEntryPendingForTheNextPass() async {
        let favs = makeFavorites()
        favs.toggle("sng_a", appleMusicId: "1")

        let t = RecordingTransport()
        t.responder = { req in
            if req.httpMethod == "PUT" { throw Rejected() }     // Apple rejects the rating
            return Data()
        }
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [("sng_a", "1")] }

        await svc.run()

        XCTAssertNotNil(svc.lastError)
        XCTAssertNil(svc.lastSyncedAtMs, "a thrown pass is not a completed sync")
        XCTAssertNil(favs.entry("sng_a")?.pushedAtMs, "a failed write must never be marked pushed")
        XCTAssertEqual(favs.pendingPushes.map(\.songId), ["sng_a"], "so the next pass retries it")
        XCTAssertTrue(favs.isFavorite("sng_a"), "a transport failure never changes local state")
        XCTAssertFalse(t.trace.contains("GET /v1/me/ratings/songs"),
                       "the pass aborts before the pull rather than reconciling against a half-written account")

        // The next pass succeeds and drains it.
        t.responder = { req in req.httpMethod == "GET" ? ratingsPayload(loved: ["1"]) : Data() }
        await svc.run()
        XCTAssertTrue(favs.pendingPushes.isEmpty)
        XCTAssertTrue(favs.isFavorite("sng_a"))
        XCTAssertNil(svc.lastError)
        XCTAssertNotNil(svc.lastSyncedAtMs)
    }

    func testUnfavoriteDeletesTheRatingAndNeverTriesToRetractTheStar() async {
        let favs = makeFavorites()
        favs.applySeed(songIds: ["sng_a"], appleMusicIds: ["sng_a": "1"], version: 1)   // ♥ already upstream
        XCTAssertTrue(favs.isFavorite("sng_a"))
        favs.toggle("sng_a", appleMusicId: "1")                                        // un-♥

        let t = RecordingTransport()
        let svc = makeService(owner: true, favorites: favs, transport: t)
        // No catalog ids ⇒ the pull is a no-op; this test is about the outbound half only.

        await svc.run()

        XCTAssertEqual(t.trace, ["DELETE /v1/me/ratings/songs/1"],
                       "un-♥ removes the reversible RATING only — Apple ships no delete for the ★, so we never call /v1/me/favorites here")
        XCTAssertNil(t.requests[0].httpBody)
        XCTAssertTrue(favs.pendingPushes.isEmpty)
        XCTAssertEqual(favs.entry("sng_a")?.favorited, false)
    }

    // MARK: - Inbound

    func testPullDoesNotUnfavoriteAnUntouchedUnratedSong() async {
        let favs = makeFavorites()
        let t = RecordingTransport()
        t.responder = { _ in ratingsPayload(loved: ["2"], disliked: ["3"]) }
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [("sng_untouched", "1"), ("sng_loved", "2"), ("sng_disliked", "3")] }

        await svc.run()

        XCTAssertNil(favs.entry("sng_untouched"),
                     "absence of a rating is not a decision to un-♥ — the song stays UNTOUCHED, not tombstoned")
        XCTAssertNil(favs.entry("sng_disliked"), "a dislike upstream is likewise not a local tombstone")
        XCTAssertTrue(favs.isFavorite("sng_loved"), "a ♥ made in the Music app lands in the app")
        XCTAssertTrue(favs.pendingPushes.isEmpty, "adopted upstream state is never echoed back")
        XCTAssertEqual(t.trace, ["GET /v1/me/ratings/songs"],
                       "nothing pending ⇒ no outbound writes at all, not even an empty ★ batch")
    }

    func testNewerLocalToggleSurvivesAPullReportingTheOldUpstreamState() async {
        // A ♥ whose timestamp is NEWER than the pull's observation — the real race, since
        // `pull()` stamps `now` once up front and then walks hundreds of batched GETs, so a
        // toggle made mid-pull is genuinely newer than the reading. Injected through the
        // document so the ordering is deterministic instead of a wall-clock coin flip.
        let future = Date().timeIntervalSince1970 * 1000 + 60_000
        let favs = makeFavorites("""
        { "schemaVersion": 1, "entries": [
            { "songId": "sng_a", "favorited": true, "atMs": \(future), "appleMusicId": "1" }
          ] }
        """)
        XCTAssertTrue(favs.isFavorite("sng_a"))

        let t = RecordingTransport()
        t.responder = { req in req.httpMethod == "GET" ? ratingsPayload(loved: []) : Data() }
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [("sng_a", "1")] }

        await svc.run()

        XCTAssertTrue(favs.isFavorite("sng_a"),
                      "the pull saw the OLD upstream state (unrated); the newer local ♥ wins")
        XCTAssertEqual(favs.entry("sng_a")?.atMs, future, "and its timestamp is not restamped by the pull")
        XCTAssertTrue(t.trace.contains("PUT /v1/me/ratings/songs/1"),
                      "the ♥ is pushed upstream rather than being reconciled away")
    }

    // MARK: - Immediate push (the ♥-tap path)

    func testPushNowIsGatedOnOwnerAndOnAnAppleMusicIdentity() async {
        let am = FavoritesStore.Entry(songId: "sng_a", favorited: true, atMs: 1,
                                      appleMusicId: "1", pushedAtMs: nil)
        let vinyl = FavoritesStore.Entry(songId: "sng_v", favorited: true, atMs: 1,
                                         appleMusicId: nil, pushedAtMs: nil)

        // Non-owner: the ♥ tap never reaches Apple Music.
        let tester = RecordingTransport()
        let testerSvc = makeService(owner: false, favorites: makeFavorites(), transport: tester,
                                    seed: FavoritesSyncService.Seed(version: 1, songIds: [],
                                                                    appleMusicIds: nil))
        await testerSvc.pushNow(am)
        XCTAssertTrue(tester.requests.isEmpty, "the gate is unresolved ⇒ nothing leaves the device")
        await testerSvc.run()                                   // resolves isOwner = false
        await testerSvc.pushNow(am)
        XCTAssertTrue(tester.requests.isEmpty)

        // Owner: an Apple-Music-backed ♥ goes now; a vinyl ♥ has nothing to send.
        let owner = RecordingTransport()
        let ownerSvc = makeService(owner: true, favorites: makeFavorites(), transport: owner)
        await ownerSvc.run()
        XCTAssertTrue(owner.requests.isEmpty, "an empty queue and no catalog ⇒ an idle pass")
        await ownerSvc.pushNow(vinyl)
        XCTAssertTrue(owner.requests.isEmpty, "no Apple Music identity ⇒ nothing upstream to write")
        await ownerSvc.pushNow(am)
        XCTAssertEqual(owner.trace, ["POST /v1/me/favorites", "PUT /v1/me/ratings/songs/1"])
    }

    func testTransportThatCannotSyncIsSkippedWithoutLosingTheToggle() async {
        let favs = makeFavorites()
        favs.toggle("sng_a", appleMusicId: "1")

        let t = RecordingTransport()
        t.canSync = false                                   // MusicKit unauthorized / integration off
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [("sng_a", "1")] }

        await svc.run()

        XCTAssertTrue(t.requests.isEmpty)
        XCTAssertEqual(favs.pendingPushes.map(\.songId), ["sng_a"],
                       "the toggle waits for authorization rather than being dropped")
        XCTAssertTrue(favs.isFavorite("sng_a"))
    }

    // MARK: - Seed export (owner-only)

    func testExportSeedShipsAppleMusicFavoritesOnly() {
        let favs = makeFavorites()
        favs.toggle("sng_am2", appleMusicId: "2")
        favs.toggle("sng_am1", appleMusicId: "1")
        favs.toggle("sng_vinyl", appleMusicId: nil)                  // personal — must never ship
        favs.set("sng_dead", favorited: false, appleMusicId: "9")    // a tombstone is not a ♥

        let seed = makeService(owner: true, favorites: favs, transport: nil).exportSeed(version: 7)

        XCTAssertEqual(seed.version, 7)
        XCTAssertEqual(seed.songIds, ["sng_am1", "sng_am2"],
                       "sorted, Apple-Music-sourced ♥ only — the owner's vinyl / My Digital ♥ stay personal")
        XCTAssertEqual(seed.appleMusicIds, ["sng_am1": "1", "sng_am2": "2"])
    }

    // MARK: - The in-flight re-toggle race

    /// A ♥ flipped WHILE its own push is in flight must stay pending. `markPushed` is
    /// therefore keyed to the timestamp of the state that was actually transmitted, not to
    /// the wall clock at completion — a fresh clock reading is newer than the re-toggle and
    /// would mark it clean, permanently discarding a change that never left the device.
    func testAReToggleDuringAnInFlightPushStaysPending() async {
        let favs = makeFavorites()
        let t = RecordingTransport()
        let svc = makeService(owner: true, favorites: favs, transport: t)
        svc.catalogAppleMusicIds = { [] }          // no pull work; this test is about push

        favs.set("sng_1", favorited: true, appleMusicId: "111")
        let sent = try? XCTUnwrap(favs.entry("sng_1"))

        // The user un-♥s it while the love request is still outstanding. Its `atMs` is now
        // strictly newer than the state the in-flight request carries.
        favs.set("sng_1", favorited: false, appleMusicId: "111")
        XCTAssertGreaterThan(favs.entry("sng_1")?.atMs ?? 0, sent?.atMs ?? .infinity)

        // The in-flight push now completes and reports success for the OLD state.
        favs.markPushed(songId: "sng_1", pushedAtMs: sent?.atMs ?? 0)

        XCTAssertEqual(favs.pendingPushes.map(\.songId), ["sng_1"],
                       "the newer un-♥ was never transmitted, so it must still be owed a write")
        XCTAssertFalse(favs.isFavorite("sng_1"))

        // And the next full pass actually sends it: a DELETE of the rating, never a ★.
        await svc.run()
        XCTAssertEqual(t.trace, ["DELETE /v1/me/ratings/songs/111"])
        XCTAssertTrue(favs.pendingPushes.isEmpty, "settled once the real state is upstream")
    }
}
