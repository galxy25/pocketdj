import XCTest
@testable import PocketDJ

/// **RECOMMENDATIONS, OFF FOR ONE COLLECTION.**
///
/// Owner, verbatim: *"support ability to turn off recommendations for a collection (eg comfort
/// zone, favorite songs, OTG) as an option in the … menu of the tile."*
///
/// This file pins the four things that make that a real switch rather than a hidden tile:
///
///  1. **OFF COSTS NOTHING.** `ForYouFeedBuilder.build` must not run `ZoneEngine.suggestions` for a
///     switched-off crate — that call is a catalog sweep, and the whole point of closing a crate is
///     to stop paying for suggestions nobody wants.
///  2. **IT SURVIVES A RELAUNCH**, without a schema bump. A bump discards user documents in this
///     app, so the field is additive-optional and an older document decodes to "on".
///  3. **IT IS FINDABLE AGAIN.** The ⋯ that switched it off lived on a tile that no longer exists,
///     so the store has to be able to enumerate the opt-out set — INCLUDING for a collection that
///     is empty and could never have had a tile at all.
///  4. **IT DOES NOT DAMAGE In Da Zone.** A closed crate's membership is still co-membership
///     evidence ("you file these together"), which is a fact about the library, not a suggestion
///     about the crate.
@MainActor
final class ForYouRecsOptOutTests: XCTestCase {

    /// `CollectionsStore.app` is a WEAK ref, so the AppModel must be retained by the test for the
    /// store's lifetime (the `CollectionsResolverTests` idiom).
    private var heldApp: AppModel?

    override func tearDown() { heldApp = nil; super.tearDown() }

    private func makeStore(_ name: String = #function) -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recsoff-\(name)-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        return CollectionsStore(fileURL: url)
    }

    /// A store whose members actually RESOLVE. `suggestibleCollections()` runs membership through
    /// the catalog (a pocket's DAG, a playlist's album members), so without a wired AppModel every
    /// collection resolves to zero songs and reads as "empty" — which is a different property than
    /// the one under test.
    private func wiredStore() async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = makeStore("wired")
        s.app = app
        return s
    }

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(
            withJSONObject: ["id": id, "name": id.uppercased(), "artist": artist, "year": 2020]))
    }

    // ========================================================================
    // MARK: - 1. The ranker skips it (no tile, and no work)
    // ========================================================================

    /// The load-bearing one. A switched-off crate produces NO crate in the snapshot — which is both
    /// "no tile" and (because the filter runs BEFORE the map) "no suggestion sweep".
    func testBuilderComputesNothingForASwitchedOffCrate() {
        let songs = (1...8).map { song("s\($0)", artist: "Artist \($0 % 3)") }
        let tracks = songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                  artistName: $0.artist, genre: "house") }
        let now = 1_900_000_000_000.0
        let crates: [ForYouFeedSnapshot.Crate] = [
            .init(id: "pkt_open", kind: "pocket", name: "Open", songIds: ["s1", "s2"]),
            .init(id: "pkt_closed", kind: "pocket", name: "Comfort Zone", songIds: ["s3", "s4"]),
        ]
        var inputs = ForYouFeedInputs(songs: songs, tracks: tracks,
                                      plays: [.init(songId: "s1", playedAtMs: now - 1_000)],
                                      crates: crates, nowMs: now)

        // Baseline: both crates rank.
        XCTAssertEqual(ForYouFeedBuilder.build(inputs).crates.map(\.id),
                       ["pkt_open", "pkt_closed"])

        inputs.recsOffCrateIds = ["pkt_closed"]
        let built = ForYouFeedBuilder.build(inputs)
        XCTAssertEqual(built.crates.map(\.id), ["pkt_open"],
                       "a switched-off crate is absent from the snapshot entirely — not present-but-empty")
        XCTAssertNil(built.songIds(forTileId: "col-pkt_closed"),
                     "so the frozen feed cannot hand a tile a list for it")
    }

    /// A switched-off crate STILL feeds In Da Zone. The zone pass reads `inputs.crates` whole; only
    /// the suggestion pass consults `recsOffCrateIds`. Turning off a tile must not quietly degrade
    /// the ranking of what to play.
    func testSwitchingACrateOffDoesNotChangeInDaZone() {
        let songs = (1...8).map { song("s\($0)", artist: "Artist \($0 % 3)") }
        let tracks = songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                  artistName: $0.artist, genre: "house") }
        let now = 1_900_000_000_000.0
        var inputs = ForYouFeedInputs(
            songs: songs, tracks: tracks,
            plays: [.init(songId: "s1", playedAtMs: now - 1_000)],
            crates: [.init(id: "pkt_closed", kind: "pocket", name: "Comfort Zone",
                           songIds: ["s3", "s4"])],
            nowMs: now)
        let zoneBefore = ForYouFeedBuilder.build(inputs).zoneIds

        inputs.recsOffCrateIds = ["pkt_closed"]
        let after = ForYouFeedBuilder.build(inputs)
        XCTAssertEqual(after.zoneIds, zoneBefore,
                       "co-membership is a fact about the library, not a suggestion about the crate")
        XCTAssertTrue(after.crates.isEmpty)
    }

    /// An empty opt-out set — the default and the common case — must leave the build EXACTLY as it
    /// was before this feature existed.
    func testEmptyOptOutSetChangesNothing() {
        let songs = (1...6).map { song("s\($0)", artist: "Artist \($0 % 2)") }
        let tracks = songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist,
                                                  artistName: $0.artist, genre: "house") }
        let now = 1_900_000_000_000.0
        let inputs = ForYouFeedInputs(
            songs: songs, tracks: tracks,
            plays: [.init(songId: "s1", playedAtMs: now - 1_000)],
            crates: [.init(id: "pkt_a", kind: "pocket", name: "A", songIds: ["s1", "s2"])],
            nowMs: now)
        XCTAssertEqual(ForYouFeedBuilder.build(inputs).crates.count, 1)
        XCTAssertTrue(inputs.recsOffCrateIds.isEmpty, "off by default")
    }

    // ========================================================================
    // MARK: - 2. It persists, additively (NO schema bump)
    // ========================================================================

    func testOptOutPersistsAcrossRelaunchForBothKinds() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recsoff-relaunch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let seed = CollectionsStore(fileURL: url)
        let pocket = seed.createPocket("Comfort Zone")
        let playlist = seed.createPlaylist("OTG")
        seed.setRecommendationsEnabled(false, forPocket: pocket.id)
        seed.setRecommendationsEnabled(false, forPlaylist: playlist.id)
        seed.flushDocumentNow()   // save() encodes+writes async now; land it before re-reading

        let reborn = CollectionsStore(fileURL: url)
        XCTAssertFalse(reborn.recommendationsEnabled(forCollection: pocket.id))
        XCTAssertFalse(reborn.recommendationsEnabled(forCollection: playlist.id))
        XCTAssertEqual(reborn.recommendationsOffIds(), [pocket.id, playlist.id])
    }

    /// Stored `false`/nil, never `true` — so an untouched collection's serialized bytes are
    /// unchanged and CloudSync's byte-compare stays quiet (the `cleanOnly` idiom, inverted).
    func testTurningItBackOnClearsTheFieldRatherThanWritingTrue() {
        let store = makeStore()
        let p = store.createPocket("Favorite Songs")
        XCTAssertNil(store.pocket(p.id)?.recsEnabled, "untouched ⇒ absent")

        store.setRecommendationsEnabled(false, forPocket: p.id)
        XCTAssertEqual(store.pocket(p.id)?.recsEnabled, false)

        store.setRecommendationsEnabled(true, forPocket: p.id)
        XCTAssertNil(store.pocket(p.id)?.recsEnabled,
                     "back to absent — never `true`, so the bytes match a collection never touched")
        XCTAssertTrue(store.recommendationsEnabled(forCollection: p.id))
    }

    /// A document written BEFORE the field existed decodes to "recommendations on", and the schema
    /// version is untouched by this feature.
    func testAPreFeatureDocumentDecodesToRecommendationsOn() throws {
        let old = """
        { "schemaVersion": \(collectionsSchemaVersion), "pockets": [
            { "id": "pkt_old", "name": "Soul", "kind": "harmonic",
              "songIds": ["sng_1"], "albumIds": [], "childPocketIds": [],
              "createdAt": 0, "updatedAt": 0 }
        ], "playlists": [] }
        """
        let doc = try CollectionsCodec.decode(Data(old.utf8))
        XCTAssertNil(doc.pockets.first?.recsEnabled)
        XCTAssertTrue(doc.pockets.first?.wantsRecommendations ?? false)
    }

    /// A GARBLED value must cost the flag, never the collection. The lossy `[Playlist]` decode
    /// drops any playlist that throws, so a strict decode here would delete a whole crate over one
    /// bad byte.
    func testAMalformedFlagDegradesToOnAndKeepsTheCollection() throws {
        let bad = """
        { "schemaVersion": \(collectionsSchemaVersion), "pockets": [
            { "id": "pkt_bad", "name": "Soul", "kind": "harmonic", "recsEnabled": "nope",
              "songIds": ["sng_1"], "albumIds": [], "childPocketIds": [],
              "createdAt": 0, "updatedAt": 0 }
        ], "playlists": [] }
        """
        let doc = try CollectionsCodec.decode(Data(bad.utf8))
        XCTAssertEqual(doc.pockets.count, 1, "the collection survives")
        XCTAssertTrue(doc.pockets.first?.wantsRecommendations ?? false)
    }

    func testTheFlagRoundTripsThroughTheCodec() throws {
        var doc = CollectionsDocument()
        doc.pockets = [Pocket(id: "pkt_1", name: "Comfort Zone", songIds: ["sng_1"],
                              recsEnabled: false)]
        let back = try CollectionsCodec.decode(CollectionsCodec.encode(doc))
        XCTAssertEqual(back.pockets.first?.recsEnabled, false)
        XCTAssertFalse(back.pockets.first?.wantsRecommendations ?? true)
        XCTAssertEqual(back.schemaVersion, collectionsSchemaVersion, "additive — NO bump")
    }

    // ========================================================================
    // MARK: - 3. It is findable again once the tile is gone
    // ========================================================================

    /// The discoverability property. An EMPTY collection can be switched off from its own ⋯ menu
    /// and could never have had a tile — so if the roll-up were built from the suggestible set it
    /// would be unreachable from the only screen that lists the opt-outs.
    func testAnEmptyCollectionStillAppearsInTheTurnItBackOnList() async {
        // WIRED deliberately: on an unwired store everything resolves to empty, so this test
        // would pass without ever exercising the emptiness rule it claims to be about.
        let store = await wiredStore()
        let empty = store.createPocket("Comfort Zone")          // no members at all
        store.setRecommendationsEnabled(false, forPocket: empty.id)

        XCTAssertTrue(store.suggestibleCollections().isEmpty,
                      "an empty collection is never suggestible — so it can never earn a tile")
        XCTAssertEqual(store.recommendationsOffCollections().map(\.id), [empty.id],
                       "…and yet it is listed, which is the only way back on")
        XCTAssertEqual(store.recommendationsOffCollections().first?.kind, "pocket")
    }

    func testTheTurnItBackOnListNamesBothKindsAndSortsByName() {
        let store = makeStore()
        let z = store.createPocket("Zed")
        let a = store.createPlaylist("Alpha")
        let m = store.createPocket("Middle")
        for id in [z.id, a.id, m.id] { store.setRecommendationsEnabled(false, forCollection: id) }

        XCTAssertEqual(store.recommendationsOffCollections().map(\.name), ["Alpha", "Middle", "Zed"])
        XCTAssertEqual(store.recommendationsOffCollections().map(\.kind),
                       ["playlist", "pocket", "pocket"])

        // …and it empties as they come back on, so the Settings section disappears when it should.
        store.setRecommendationsEnabled(true, forCollection: m.id)
        XCTAssertEqual(store.recommendationsOffCollections().map(\.name), ["Alpha", "Zed"])
    }

    /// A switched-off collection is STILL suggestible-set material, because that set is also In Da
    /// Zone's co-membership corpus. This is the store-level twin of
    /// `testSwitchingACrateOffDoesNotChangeInDaZone`.
    func testSwitchingOffDoesNotRemoveACollectionFromTheCoMembershipCorpus() async {
        let store = await wiredStore()
        let p = store.createPocket("Comfort Zone")
        store.addSong("sng_1", toPocket: p.id)
        store.setRecommendationsEnabled(false, forPocket: p.id)

        XCTAssertEqual(store.suggestibleCollections().map(\.id), [p.id],
                       "still in the corpus — the opt-out is applied by the BUILDER, not here")
        XCTAssertEqual(store.recommendationsOffIds(), [p.id])
    }

    // ========================================================================
    // MARK: - 4. The unknown-kind id (all a tile carries)
    // ========================================================================

    func testUnknownKindSetterResolvesEitherStoreAndReportsAMissingId() {
        let store = makeStore()
        let pocket = store.createPocket("Crate")
        let playlist = store.createPlaylist("Set")

        XCTAssertTrue(store.setRecommendationsEnabled(false, forCollection: pocket.id))
        XCTAssertTrue(store.setRecommendationsEnabled(false, forCollection: playlist.id))
        XCTAssertFalse(store.setRecommendationsEnabled(false, forCollection: "pkt_ghost"),
                       "a since-deleted collection writes nothing and says so")
        XCTAssertEqual(store.recommendationsOffIds(), [pocket.id, playlist.id])
    }

    /// An id that resolves to NOTHING answers "on". A tile for a since-deleted collection is
    /// already dropped by the existence filter in `deriveTiles`; answering "off" here would make
    /// this method double as a delete detector and hide the wrong thing.
    func testAnUnresolvableIdIsTreatedAsRecommendationsOn() {
        let store = makeStore()
        XCTAssertTrue(store.recommendationsEnabled(forCollection: "pkt_never_existed"))
        XCTAssertTrue(store.recommendationsOffIds().isEmpty)
    }
}
