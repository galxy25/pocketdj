import XCTest
@testable import PocketDJ

/// FOR YOU IS CACHED, NOT RECOMPUTED — and the owner's own 👍/👎 is the one exception.
///
/// Owner, verbatim: *"history for you should cache the last result and only refresh when you hit a
/// refresh button in the menu."* The failure this file exists to prevent is the pair of opposite
/// bugs that a change like this invites:
///
///  1. THE FEED KEEPS MOVING. A play, an add, a catalog load bumps something and the ranking
///     re-runs under the reader. That is what the store's "nothing but `refresh` writes the
///     snapshot" property is about.
///  2. THE FEED FREEZES THE USER'S HANDS. A thumbs-down is filed but the row does not sink and the
///     tile's count does not drop until a manual refresh — which makes the controls look broken.
///     That is what the `RecFeedbackOrder.sink`-over-frozen-ids tests are about.
@MainActor
final class ForYouFeedCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-foryou-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ name: String = "feed.json") -> URL { tempDir.appendingPathComponent(name) }

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(
            withJSONObject: ["id": id, "name": id.uppercased(), "artist": artist, "year": 2020]))
    }

    private func snapshot(_ zone: [String] = ["z1", "z2", "z3"],
                          crates: [ForYouFeedSnapshot.Crate] = [],
                          at ms: Double = 1_700_000_000_000) -> ForYouFeedSnapshot {
        ForYouFeedSnapshot(refreshedAtMs: ms, zoneIds: zone, zoneBuriedIds: [], crates: crates)
    }

    // ========================================================================
    // MARK: - It survives relaunch (a cold launch shows the cached tiles)
    // ========================================================================

    func testSnapshotSurvivesRelaunch() {
        let file = url()
        let crate = ForYouFeedSnapshot.Crate(id: "pkt_gym", kind: "pocket", name: "Gym",
                                             songIds: ["a", "b"])
        let first = ForYouFeedStore(fileURL: file)
        XCTAssertFalse(first.snapshot.hasResult, "a cold install has nothing cached")
        first.commit(snapshot(["z1", "z2"], crates: [crate]))

        // A whole new process would do exactly this: decode on init, with no task and no network.
        let reborn = ForYouFeedStore(fileURL: file)
        XCTAssertTrue(reborn.snapshot.hasResult)
        XCTAssertEqual(reborn.snapshot.zoneIds, ["z1", "z2"])
        XCTAssertEqual(reborn.snapshot.crates.first?.name, "Gym")
        XCTAssertEqual(reborn.songIds(forTileId: "col-pkt_gym"), ["a", "b"])
    }

    func testCorruptDocumentDegradesToNoCacheRatherThanTrapping() throws {
        let file = url("bad.json")
        try Data("{ this is not json".utf8).write(to: file)
        let store = ForYouFeedStore(fileURL: file)
        XCTAssertFalse(store.snapshot.hasResult)
        XCTAssertTrue(store.snapshot.zoneIds.isEmpty)
    }

    func testDocumentFromAnUnknownShapeDecodesLeniently() throws {
        // Only `zoneIds` is recognisable. A strict decode would throw the whole thing away and the
        // grid would silently re-rank, which is the behaviour being removed.
        try Data(#"{"zoneIds":["a","b"],"somethingNew":42,"refreshedAtMs":123}"#.utf8)
            .write(to: url("partial.json"))
        let store = ForYouFeedStore(fileURL: url("partial.json"))
        XCTAssertEqual(store.snapshot.zoneIds, ["a", "b"])
        XCTAssertEqual(store.snapshot.refreshedAtMs, 123)
    }

    // ========================================================================
    // MARK: - Only a refresh changes it
    // ========================================================================

    func testTileIdLookupMatchesTheIdsForYouTilesMints() {
        // The tile card's id and the snapshot key must be the SAME string, or the list behind a
        // card is a different array from the one the card counted.
        let crate = ForYouFeedSnapshot.Crate(id: "pl_x", kind: "playlist", name: "X",
                                             songIds: ["s1"])
        let tiles = ForYouTiles.build(newReleaseCount: 0, zone: ["z"],
                                      collections: [(id: "pl_x", kind: "playlist", name: "X",
                                                     suggestions: ["s1"])])
        let colTile = try! XCTUnwrap(tiles.first { $0.id.hasPrefix("col-") })
        XCTAssertEqual(colTile.id, colTile.route.tileId,
                       "the card's id IS the snapshot key")
        let snap = snapshot(["z"], crates: [crate])
        XCTAssertEqual(snap.songIds(forTileId: colTile.route.tileId), ["s1"])
        XCTAssertEqual(snap.songIds(forTileId: ForYouTileRoute(kind: .zone, title: "In Da Zone").tileId),
                       ["z"])
    }

    func testUnknownTileFallsThroughRatherThanReturningAnEmptyList() {
        // nil ⇒ "this snapshot knows nothing about that tile", which is what tells the list view
        // to compute one. Returning `[]` would render a permanently empty screen instead.
        XCTAssertNil(snapshot().songIds(forTileId: "col-never-refreshed"))
        XCTAssertNil(ForYouFeedSnapshot().songIds(forTileId: "zone"),
                     "a never-refreshed snapshot has no zone answer either")
    }

    func testRefreshIsTheOnlyThingThatWritesTheSnapshot() async {
        let store = ForYouFeedStore(fileURL: url())
        let songs = [song("s1", artist: "A"), song("s2", artist: "B")]
        let now = 1_800_000_000_000.0
        var inputs = ForYouFeedInputs(songs: songs,
                                      plays: [.init(songId: "s1", playedAtMs: now - 3_600_000)],
                                      nowMs: now)
        await store.refresh(inputs)
        let firstRevision = store.revision
        let frozen = store.snapshot

        // The world moves: a new play, a new catalog. NOTHING re-ranks on its own — the store has
        // no observers of its own and the grid never calls `refresh` off a signature any more.
        inputs.plays.append(.init(songId: "s2", playedAtMs: now))
        XCTAssertEqual(store.snapshot, frozen)
        XCTAssertEqual(store.revision, firstRevision)

        // Only the explicit refresh moves it.
        inputs.nowMs = now + 60_000
        await store.refresh(inputs)
        XCTAssertGreaterThan(store.revision, firstRevision)
        XCTAssertEqual(store.snapshot.refreshedAtMs, now + 60_000)
    }

    func testBuilderRunsBothPassesAndStampsTheClock() {
        let songs = (1...6).map { song("s\($0)", artist: "Artist \($0 % 3)") }
        let tracks = songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                  artistName: $0.artist, genre: "house") }
        let now = 1_900_000_000_000.0
        let built = ForYouFeedBuilder.build(ForYouFeedInputs(
            songs: songs, tracks: tracks,
            plays: [.init(songId: "s1", playedAtMs: now - 1_000)],
            crates: [.init(id: "pkt_a", kind: "pocket", name: "A", songIds: ["s1", "s2"])],
            nowMs: now))
        XCTAssertEqual(built.refreshedAtMs, now)
        XCTAssertFalse(built.zoneIds.isEmpty, "the zone pass ran")
        XCTAssertEqual(built.crates.count, 1, "one entry per suggestible collection")
        XCTAssertEqual(built.crates[0].name, "A")
        XCTAssertFalse(built.crates[0].songIds.contains("s1"),
                       "a crate's own member is never suggested back to it")
    }

    // ========================================================================
    // MARK: - THE EXCEPTION: feedback still lands immediately
    // ========================================================================

    func testAThumbsDownSinksTheRowWithoutTouchingTheFrozenRanking() {
        let feedback = RecFeedbackStore(fileURL: url("fb.json"))
        let store = ForYouFeedStore(fileURL: url())
        store.commit(snapshot(["z1", "z2", "z3"]))
        let frozen = store.snapshot
        let zone = ForYouTileRoute.Kind.zone.rawValue

        feedback.toggle(songId: "z2", to: .rejected, scope: zone, surface: .tile)

        // The CACHE is untouched — nothing re-ranked.
        XCTAssertEqual(store.snapshot, frozen)
        XCTAssertEqual(store.snapshot.zoneIds, ["z1", "z2", "z3"])

        // But what the reader SEES changed on the spot: the row sank and the count dropped.
        let p = feedback.partition(frozen.zoneIds, scope: zone)
        XCTAssertEqual(p.live, ["z1", "z3"])
        XCTAssertEqual(p.sunk, ["z2"], "sunk, never removed — the lit 👎 is the undo")
        XCTAssertEqual(feedback.rankedIds(frozen.zoneIds, scope: zone), ["z1", "z3", "z2"])
        XCTAssertEqual(feedback.visibleCount(frozen.zoneIds, scope: zone), 2)
    }

    func testAThumbsUpLeavesTheRowInPlaceAndDoesNotSinkIt() {
        let feedback = RecFeedbackStore(fileURL: url("fb.json"))
        let zone = ForYouTileRoute.Kind.zone.rawValue
        let ids = ["z1", "z2", "z3"]
        feedback.toggle(songId: "z2", to: .accepted, scope: zone, surface: .tile)
        XCTAssertEqual(feedback.rankedIds(ids, scope: zone), ids, "an accept never re-orders")
        XCTAssertEqual(feedback.visibleCount(ids, scope: zone), 3)
        XCTAssertEqual(feedback.verdict(songId: "z2", scope: zone), .accepted,
                       "and the control is lit, so the row reads as accepted")
    }

    func testUndoingARejectPutsTheRowStraightBack() {
        let feedback = RecFeedbackStore(fileURL: url("fb.json"))
        let zone = ForYouTileRoute.Kind.zone.rawValue
        let ids = ["z1", "z2", "z3"]
        feedback.toggle(songId: "z2", to: .rejected, scope: zone, surface: .tile)
        XCTAssertEqual(feedback.rankedIds(ids, scope: zone), ["z1", "z3", "z2"])
        feedback.toggle(songId: "z2", to: .rejected, scope: zone, surface: .tile)   // tap it again
        XCTAssertEqual(feedback.rankedIds(ids, scope: zone), ids,
                       "no recompute needed — the frozen order simply un-sinks")
    }

    func testSuppressionStaysScopedAcrossTheFrozenTiles() {
        let feedback = RecFeedbackStore(fileURL: url("fb.json"))
        feedback.toggle(songId: "s1", to: .rejected, scope: "pkt_gym", surface: .tile)
        XCTAssertEqual(feedback.partition(["s1", "s2"], scope: "pkt_gym").sunk, ["s1"])
        XCTAssertEqual(feedback.partition(["s1", "s2"], scope: "pkt_chill").sunk, [],
                       "a reject in one crate must not sink the song in another crate's tile")
    }

    // ========================================================================
    // MARK: - RecFeedbackOrder — the one partition
    // ========================================================================

    func testSinkIsAStablePartitionAndReInjectsDroppedTombstones() {
        let out = RecFeedbackOrder.sink(["a", "b", "c"], tombstones: ["b": 10, "z": 5])
        XCTAssertEqual(out.live, ["a", "c"], "survivors keep the engine's order exactly")
        XCTAssertEqual(out.sunk, ["z", "b"],
                       "reject order, oldest first — and `z`, which the engine had dropped, is "
                       + "re-added so its lit 👎 stays reachable")
    }

    /// No tombstones ⇒ the frozen order is handed back UNTOUCHED, allocation and all. That is the
    /// common case (nothing thumbed down), and it is what makes rendering a cached list free.
    func testSinkWithNoTombstonesIsTheIdentity() {
        let out = RecFeedbackOrder.sink(["a", "b", "a"], tombstones: [:])
        XCTAssertEqual(out.live, ["a", "b", "a"])
        XCTAssertTrue(out.sunk.isEmpty)
    }

    /// Once it IS partitioning, a duplicate id must collapse — a song cannot be both live and
    /// sunk, and two rows with the same id make the 👎 ambiguous.
    func testSinkDedupesOnceItIsPartitioning() {
        let out = RecFeedbackOrder.sink(["a", "a", "b", "b"], tombstones: ["b": 1])
        XCTAssertEqual(out.live, ["a"])
        XCTAssertEqual(out.sunk, ["b"])
    }

    // ========================================================================
    // MARK: - The staleness readout
    // ========================================================================

    func testUpdatedLabelSaysWhenAndSaysWhenItNeverHas() {
        let now = 1_700_000_000_000.0
        XCTAssertEqual(ForYouFeedStore.updatedLabel(refreshedAtMs: 0, nowMs: now),
                       "Not refreshed yet")
        XCTAssertEqual(ForYouFeedStore.updatedLabel(refreshedAtMs: now - 10_000, nowMs: now),
                       "Updated just now")
        XCTAssertEqual(ForYouFeedStore.updatedLabel(refreshedAtMs: now - 600_000, nowMs: now),
                       "Updated 10 min ago")
        XCTAssertEqual(ForYouFeedStore.updatedLabel(refreshedAtMs: now - 3 * 3_600_000, nowMs: now),
                       "Updated 3 hours ago")
        XCTAssertEqual(ForYouFeedStore.updatedLabel(refreshedAtMs: now - 86_400_000, nowMs: now),
                       "Updated 1 day ago")
    }

    // ========================================================================
    // MARK: - A deleted collection's cached tile
    // ========================================================================

    /// The regression a "cache the result" change invites: a refresh that lands while the catalog
    /// is empty (a reload, a source toggled off) stamping a BLANK feed as the cached answer, and
    /// leaving the owner with a permanently empty For You.
    func testARefreshAgainstAnEmptyCatalogNeverClobbersTheCache() async {
        let store = ForYouFeedStore(fileURL: url())
        store.commit(snapshot(["z1", "z2"]))
        let good = store.snapshot
        await store.refresh(ForYouFeedInputs(songs: [], nowMs: 2_000_000_000_000))
        XCTAssertEqual(store.snapshot, good, "a ranking of nothing is not an answer")
        XCTAssertEqual(store.snapshot.zoneIds, ["z1", "z2"])
    }

    func testDeletedCollectionsCachedIdsAreStillReadableSoTheGridCanFilterThem() {
        // The snapshot keeps them (it is a record of what was computed); the grid drops the tile
        // by checking the live store. Asserting the snapshot does NOT self-heal is the point —
        // self-healing would be a recompute by another name.
        let snap = snapshot([], crates: [.init(id: "gone", kind: "pocket", name: "Gone",
                                               songIds: ["x"])])
        XCTAssertEqual(snap.songIds(forTileId: "col-gone"), ["x"])
    }
}
