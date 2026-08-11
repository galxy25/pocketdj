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

    // ========================================================================
    // MARK: - THE CLOUD RANKER FOR In Da Zone
    // ========================================================================
    //
    // Owner, verbatim: "new and in da zone should use the recommendation engine if available,
    // only doing on device when not enabled." The two halves of that sentence are two properties,
    // and both of them are failures the other way round: a cloud answer that never reaches the
    // tile, and a cloud FAILURE that empties it.

    /// One play, ten days back, so BOTH rankers have something real to say: it seeds the local
    /// taste profile (without it `inDaZone` scores every candidate zero and the local half of
    /// these tests would be vacuously empty) and it makes exactly one row `.familiar` on the
    /// cloud path, which is what the blend is made of.
    private func cloudInputs(now: Double = 2_100_000_000_000) -> ForYouFeedInputs {
        let songs = [song("s1", artist: "Aria"), song("s2", artist: "Aria"),
                     song("s3", artist: "Bento"), song("s4", artist: "Cobalt")]
        return ForYouFeedInputs(
            songs: songs,
            tracks: songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                 artistName: $0.artist, genre: "house") },
            genreBySongId: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, "house") }),
            plays: [.init(songId: "s1", playedAtMs: now - 10 * 86_400_000)],
            nowMs: now)
    }

    func testACloudAnswerReplacesTheZoneAndSaysSo() async {
        let store = ForYouFeedStore(fileURL: url())
        await store.refresh(cloudInputs(), cloudZone: {
            [.init(songId: "s4"), .init(songId: "s3"), .init(songId: "s1")]
        })
        XCTAssertEqual(store.snapshot.zoneSource, .cloud)
        XCTAssertEqual(Set(store.snapshot.zoneIds), ["s4", "s3", "s1"],
                       "the tile is built from the SERVER's rows, not the local ranking's")
        // The server's relative order survives WITHIN a pool. Across pools the local blend
        // interleaves (that is the tile's ≥50%-rediscovery contract, which the server knows
        // nothing about), so the whole array is deliberately not asserted equal.
        let ids = store.snapshot.zoneIds
        XCTAssertLessThan(ids.firstIndex(of: "s4") ?? .max, ids.firstIndex(of: "s3") ?? .max,
                          "s4 outranked s3 server-side and still does")
        XCTAssertEqual(Set(store.snapshot.zoneBuriedIds), ["s4", "s3"],
                       "the Buried badge is re-derived locally — the server does not know which "
                       + "rows are dormant on THIS device")
        XCTAssertTrue(store.snapshot.crates.isEmpty,
                      "the cloud pass touches In Da Zone and nothing else")
    }

    /// THE ORDER IS THE FALLBACK. The local ranking must be committed BEFORE the network is
    /// awaited, or every refresh is as slow as the slowest Lambda cold start and a timeout looks
    /// like a hung refresh.
    func testTheLocalRankingIsCommittedBeforeTheCloudIsEvenAsked() async {
        let store = ForYouFeedStore(fileURL: url())
        var zoneWhenAsked: [String]?
        var revisionWhenAsked: Int?
        await store.refresh(cloudInputs(), cloudZone: {
            zoneWhenAsked = store.snapshot.zoneIds
            revisionWhenAsked = store.revision
            return [.init(songId: "s4")]
        })
        XCTAssertFalse(zoneWhenAsked?.isEmpty ?? true,
                       "a complete on-device feed is already on screen when the request goes out")
        XCTAssertEqual(revisionWhenAsked, 1, "…and it was committed, not merely computed")
        XCTAssertEqual(store.revision, 2, "the cloud answer is a SECOND commit")
    }

    /// Every way the cloud can fail to be useful is the same outcome: the on-device feed stands.
    /// Offline, 5xx, unenrolled, an empty list and a list of ids this catalog cannot resolve all
    /// arrive here as "nothing usable".
    func testEveryCloudFailureLeavesTheOnDeviceFeedExactlyAsItWas() async {
        for (label, answer) in [("empty answer", [ForYouCloudZoneRow]()),
                                ("ids this catalog cannot resolve",
                                 [ForYouCloudZoneRow(songId: "nope_1"),
                                  ForYouCloudZoneRow(songId: "nope_2")])] {
            let store = ForYouFeedStore(fileURL: url("fallback-\(label).json"))
            let inputs = cloudInputs()
            await store.refresh(inputs)                    // the reference: local only
            let local = store.snapshot
            let localRevision = store.revision

            let cloudStore = ForYouFeedStore(fileURL: url("cloudy-\(label).json"))
            await cloudStore.refresh(inputs, cloudZone: { answer })
            XCTAssertEqual(cloudStore.snapshot.zoneIds, local.zoneIds, "\(label): same ids")
            XCTAssertEqual(cloudStore.snapshot.zoneSource, .onDevice,
                           "\(label): and it does not claim the cloud produced them")
            XCTAssertEqual(cloudStore.revision, localRevision,
                           "\(label): no second commit for a non-answer")
            XCTAssertFalse(cloudStore.snapshot.zoneIds.isEmpty,
                           "\(label): a cloud problem NEVER empties the tile")
        }
    }

    /// A disabled engine hands `refresh` no closure at all — the store must then behave exactly as
    /// it did before this feature existed, which is what makes the default-OFF path un-regressed.
    func testNoCloudClosureIsByteForByteTheOldBehaviour() async {
        let inputs = cloudInputs()
        let a = ForYouFeedStore(fileURL: url("a.json"))
        let b = ForYouFeedStore(fileURL: url("b.json"))
        await a.refresh(inputs)
        await b.refresh(inputs, cloudZone: nil)
        XCTAssertEqual(a.snapshot, b.snapshot)
        XCTAssertEqual(a.revision, b.revision)
    }

    /// The cloud list goes through the SAME local rules the device ranking does. A server that has
    /// not yet seen a 👎 (it was given seconds ago, or on a device that has not flushed) must not
    /// be able to put that row back on the tile.
    func testAServerListCannotBypassTheLocalTombstonesOrTheArtistCap() async {
        let store = ForYouFeedStore(fileURL: url())
        var inputs = cloudInputs()
        inputs.zoneFeedback = ZoneEngine.Feedback(suppressed: ["s3"])
        // Four Aria rows offered; the cap is 3 per artist and it is not negotiable.
        let extra = [song("s5", artist: "Aria"), song("s6", artist: "Aria")]
        inputs.songs += extra
        await store.refresh(inputs, cloudZone: {
            ["s1", "s2", "s5", "s6", "s3", "s4"].map { ForYouCloudZoneRow(songId: $0) }
        })
        XCTAssertFalse(store.snapshot.zoneIds.contains("s3"),
                       "a thumbed-down row stays down even when the server offers it")
        XCTAssertEqual(store.snapshot.zoneIds.filter { ["s1", "s2", "s5", "s6"].contains($0) }.count,
                       ZoneEngine.Tuning().maxPerArtist,
                       "the 3-per-artist cap holds against a server list")
        XCTAssertTrue(store.snapshot.zoneIds.contains("s4"),
                      "and the capped artist does not cost the queue its other rows")
    }

    /// The attribution is FROZEN WITH THE IDS. Deriving it at render from "is the engine on right
    /// now" would let a toggle flip re-label a cached list the local engine produced.
    func testTheAttributionSurvivesRelaunchAlongsideTheIdsItDescribes() async {
        let file = url("attr.json")
        let store = ForYouFeedStore(fileURL: file)
        await store.refresh(cloudInputs(), cloudZone: {
            [.init(songId: "s4"), .init(songId: "s1")]
        })
        XCTAssertEqual(ForYouFeedStore(fileURL: file).snapshot.zoneSource, .cloud)

        // …and a document written before the cloud path existed decodes as what produced it.
        try? Data(#"{"zoneIds":["a"],"refreshedAtMs":9}"#.utf8).write(to: url("old.json"))
        XCTAssertEqual(ForYouFeedStore(fileURL: url("old.json")).snapshot.zoneSource, .onDevice)
    }

    // ========================================================================
    // MARK: - THE ONE-LINE WHY rides the frozen model
    // ========================================================================
    //
    // Owner report: "i dont see the why string in any tile list" — the engine computed reasons
    // (`ZoneEngine.suggestionsExplained`) and the Lambda sent them, but neither survived to a
    // rendered row. These tests pin the PLUMBING: the reason rides the suggestion model itself,
    // round-trips the disk cache, and is nil — never "" — when absent.

    func testReasonSurvivesSnapshotRoundTrip() throws {
        let crate = ForYouFeedSnapshot.Crate(id: "pkt_gym", kind: "pocket", name: "Gym",
                                             songIds: ["a", "b"],
                                             reasons: ["a": "Mostly house, like this collection"])
        let snap = ForYouFeedSnapshot(refreshedAtMs: 9, zoneIds: ["z1"], zoneSource: .cloud,
                                      zoneReasons: ["z1": "Same genre as recent plays"],
                                      crates: [crate])
        let reborn = try JSONDecoder().decode(ForYouFeedSnapshot.self,
                                              from: JSONEncoder().encode(snap))
        XCTAssertEqual(reborn, snap, "the reasons are part of the frozen answer, not a sidecar")
        XCTAssertEqual(reborn.reasons(forTileId: "col-pkt_gym"),
                       ["a": "Mostly house, like this collection"])
        XCTAssertEqual(reborn.reasons(forTileId: "zone"), ["z1": "Same genre as recent plays"])
        XCTAssertNil(reborn.crates[0].reasons?["b"],
                     "a row the engine attached no reason to stays reason-less through the trip")
    }

    /// A cached snapshot written BEFORE reasons existed must decode with `nil` reasons — never
    /// `[:]`-pretending-to-be-something, and never a failed decode (which would re-rank the grid).
    func testAbsentReasonsDecodeAsNilNotEmpty() throws {
        try Data(#"""
        {"refreshedAtMs":9,"zoneIds":["z"],
         "crates":[{"id":"c1","kind":"pocket","name":"C","songIds":["x"]}]}
        """#.utf8).write(to: url("pre-reasons.json"))
        let snap = ForYouFeedStore(fileURL: url("pre-reasons.json")).snapshot
        XCTAssertEqual(snap.zoneIds, ["z"], "the pre-reasons document still decodes whole")
        XCTAssertNil(snap.zoneReasons, "absent ⇒ nil, not empty")
        XCTAssertNil(snap.crates.first?.reasons, "absent ⇒ nil, not empty")
        XCTAssertEqual(snap.reasons(forTileId: "zone"), [:],
                       "…and the accessor degrades to no-captions rather than trapping")
        XCTAssertEqual(snap.reasons(forTileId: "col-c1"), [:])
    }

    /// The DEVICE-RANKED path: the builder now asks `suggestionsExplained`, so every crate row
    /// arrives with the engine's why — same ids, same order as the unexplained ranking.
    func testBuilderAttachesTheEnginesReasonToEveryCrateRow() {
        let songs = (1...6).map { song("s\($0)", artist: "Artist \($0 % 3)") }
        let tracks = songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                  artistName: $0.artist, genre: "house") }
        let now = 1_900_000_000_000.0
        let inputs = ForYouFeedInputs(
            songs: songs, tracks: tracks,
            plays: [.init(songId: "s1", playedAtMs: now - 1_000)],
            crates: [.init(id: "pkt_a", kind: "pocket", name: "A", songIds: ["s1", "s2"])],
            nowMs: now)
        let built = ForYouFeedBuilder.build(inputs)
        let crate = built.crates[0]
        XCTAssertFalse(crate.songIds.isEmpty, "the fixture must actually suggest something")
        for id in crate.songIds {
            let why = crate.reasons?[id]
            XCTAssertNotNil(why, "\(id): every device-ranked row carries the engine's why")
            XCTAssertFalse(why?.isEmpty ?? true, "\(id): and it is never the empty string")
        }
        XCTAssertNil(built.zoneReasons,
                     "the on-device zone ranking supplies no reason strings — nil, not [:]")
        // The explained ranking IS the ranking — ids and order byte-identical.
        XCTAssertEqual(crate.songIds,
                       ZoneEngine.suggestions(memberSongIds: ["s1", "s2"], tracks: tracks,
                                              playCount: { _ in 0 },
                                              versions: ZoneEngine.versionKeys(tracks)))
    }

    /// The CLOUD-RANKED path: the Lambda's why lands in `zoneReasons` for the rows that survive
    /// the local shaping — and ONLY those. A reason for a dropped id would be an orphan; a row
    /// the server sent without one stays caption-less rather than becoming "".
    func testCloudReasonsRideOnlyTheSurvivingZoneRows() async {
        let store = ForYouFeedStore(fileURL: url())
        await store.refresh(cloudInputs(), cloudZone: {
            [.init(songId: "s4", why: "Same genre as recent plays"),
             .init(songId: "s3"),                                   // no reason from the server
             .init(songId: "nope_1", why: "Orphan"),                // unresolvable — shaped away
             .init(songId: "s1", why: "")]                          // "" arrives as absence
        })
        XCTAssertEqual(store.snapshot.zoneSource, .cloud)
        XCTAssertEqual(store.snapshot.zoneReasons, ["s4": "Same genre as recent plays"])
        XCTAssertEqual(store.snapshot.reasons(forTileId: "zone")["s4"],
                       "Same genre as recent plays",
                       "…readable through the same accessor the tile screen uses")
    }
}
