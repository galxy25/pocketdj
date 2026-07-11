import XCTest
@testable import PocketDJ

/// Spec §8 — the per-consumer resolution policy for STUDIO ids (`smp_`/`lp_`/`ptn_`)
/// riding collections' existing string arrays:
///   • playNow / playableIds(...)  → studio rows KEPT (resolved via `studioLookup`,
///     real lengths — never the engine's 210 s fallback);
///   • songIds(...)                → studio rows EXCLUDED (rip/burn/CSV/Browse/Storage
///     stay catalog-only);
///   • CollectionCatalog stats     → studio items INCLUDED (count + real runtime);
///   • makeCtx (realize)           → synthetic entries injected into ctx.songsById for
///     REFERENCED ids only, and NEVER into ctx.candidates (the autofill fence).
///
/// Runs against the shared TestData catalog (sng_1 = 222 000 ms) with a stubbed
/// `studioLookup` standing in for StudioStore.
@MainActor
final class CollectionsStudioTests: XCTestCase {

    /// `CollectionsStore.app` is a WEAK ref — retain the AppModel for the store's lifetime.
    private var heldApp: AppModel?

    override func tearDown() { heldApp = nil; super.tearDown() }

    /// The StudioStore stand-in: two resolvable items + everything else unresolvable
    /// (deleted / unknown), mirroring `StudioStore.displayInfo`'s nil contract.
    /// `lp_b` deliberately carries bpm AND camelot so the autofill-fence test proves
    /// the fence isn't just "no harmonic data" filtering.
    private static func stubLookup(_ id: String)
        -> (title: String, lengthMs: Int, bpm: Double?, camelot: String?)? {
        switch id {
        case "smp_a": return ("Air Stab", 2_000, 120, nil)
        case "lp_b":  return ("Bass Groove", 4_000, 124, "8A")
        case "ptn_c": return ("Kick Pattern", 2_000, 120, nil)
        default: return nil
        }
    }

    private func wiredStore(withLookup: Bool = true) async -> CollectionsStore {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        heldApp = app
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-studio-collections-\(UUID().uuidString).json"))
        s.app = app
        if withLookup { s.studioLookup = Self.stubLookup }
        return s
    }

    // MARK: playNow — studio ids resolve into snapshotted Now Playing rows

    func testPlayNowKeepsResolvedStudioIds() async {
        let s = await wiredStore()
        let set = s.playNow(songIds: ["sng_1", "lp_b", "smp_a", "smp_ghost"])
        XCTAssertEqual(set?.tracks.map(\.songId), ["sng_1", "lp_b", "smp_a"],
                       "resolvable studio ids stay in order; the unresolvable one drops like an unknown catalog id")

        let loop = set?.tracks[1]
        XCTAssertEqual(loop?.name, "Bass Groove")
        XCTAssertEqual(loop?.artist, "Studio")
        XCTAssertEqual(loop?.lengthMs, 4_000, "REAL length from the lookup")
        XCTAssertEqual(loop?.shownMs, 4_000, "no 210 s defaultTrackMs fallback for a 4 s loop")
        XCTAssertEqual(loop?.bpm, 124)
        XCTAssertEqual(loop?.camelot, "8A")
        // totalMs sums the real studio lengths too (222 000 + 4 000 + 2 000).
        XCTAssertEqual(set?.totalMs, 228_000)
    }

    func testPlayNowWithoutLookupDropsStudioIds() async {
        let s = await wiredStore(withLookup: false)
        let set = s.playNow(songIds: ["sng_1", "lp_b"])
        XCTAssertEqual(set?.tracks.map(\.songId), ["sng_1"],
                       "nil seam ⇒ pre-Studio behavior: studio ids silently drop")
    }

    func testPlayNowForPlaylistIncludesStudioRows() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addSong("lp_b", toPlaylist: pl.id)   // studio ids ride addSong verbatim (spec §8)
        let set = s.playNow(playlistId: pl.id)
        XCTAssertEqual(set?.tracks.map(\.songId), ["sng_1", "lp_b"],
                       "playNow(playlistId:) resolves via playableIds — studio rows reach Now Playing")
    }

    // MARK: songIds vs playableIds — the catalog-only / playback split

    func testSetlistResolverExcludesStudioRowsButPlayableKeepsFrozenOrder() async {
        let s = await wiredStore()
        guard let set = s.playNow(songIds: ["sng_1", "lp_b", "smp_a"]) else {
            return XCTFail("playNow returned nil")
        }
        XCTAssertEqual(s.songIds(forSetlist: set.id), ["sng_1"],
                       "rip/CSV/storage resolver: studio rows excluded like text cues")
        XCTAssertEqual(s.playableIds(forSetlist: set.id), ["sng_1", "lp_b", "smp_a"],
                       "playback resolver: frozen order, studio rows kept")
    }

    func testPlaylistResolversSplitStudioIds() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_4", toPlaylist: pl.id)
        s.addSong("lp_b", toPlaylist: pl.id)
        s.addSong("sng_5", toPlaylist: pl.id)
        XCTAssertEqual(s.songIds(forPlaylist: pl.id), ["sng_4", "sng_5"],
                       "catalog-only: the studio-aware catalog must not leak lp_ ids to rip/burn/CSV")
        XCTAssertEqual(s.playableIds(forPlaylist: pl.id), ["sng_4", "lp_b", "sng_5"],
                       "playable: order-preserving, studio kept")
    }

    func testPocketResolversSplitStudioIds() async {
        let s = await wiredStore()
        let pkt = s.createPocket("Crate")
        s.addSong("smp_a", toPocket: pkt.id)
        s.addSong("sng_1", toPocket: pkt.id)
        XCTAssertEqual(s.songIds(forPocket: pkt.id), ["sng_1"])
        XCTAssertEqual(s.playableIds(forPocket: pkt.id), ["smp_a", "sng_1"])
    }

    // MARK: CollectionCatalog stats — studio items counted with REAL lengths

    func testCatalogStatsIncludeStudioLengths() async {
        let s = await wiredStore()
        let pkt = s.createPocket("Crate")
        s.addSong("sng_1", toPocket: pkt.id)       // 222 000 ms
        s.addSong("lp_b", toPocket: pkt.id)        // 4 000 ms (real, from the lookup)
        s.addSong("smp_ghost", toPocket: pkt.id)   // unresolvable → contributes nothing
        let stats = s.catalog().stats(forPocket: pkt.id)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.runtimeMs, 226_000, "runtime uses the loop's REAL 4 s, not 0 and not 210 s")

        let pl = s.createPlaylist("Set")
        s.addSong("smp_a", toPlaylist: pl.id)      // 2 000 ms
        s.addSong("sng_4", toPlaylist: pl.id)      // 240 000 ms
        guard let playlist = s.playlist(pl.id) else { return XCTFail("playlist gone") }
        let plStats = s.catalog().stats(forPlaylist: playlist)
        XCTAssertEqual(plStats.count, 2)
        XCTAssertEqual(plStats.runtimeMs, 242_000)
    }

    // MARK: makeCtx — referenced-only injection + the autofill candidates fence

    func testMakeCtxInjectsReferencedStudioIdsOnly() async {
        let s = await wiredStore()
        let a = s.createPlaylist("A")
        s.addSong("lp_b", toPlaylist: a.id)
        let b = s.createPlaylist("B")
        s.addSong("smp_a", toPlaylist: b.id)   // referenced by B, NOT by A

        guard let pl = s.playlist(a.id), let ctx = s.makeCtx(for: pl) else {
            return XCTFail("makeCtx returned nil")
        }
        let injected = ctx.songsById["lp_b"]
        XCTAssertNotNil(injected, "A's referenced studio id gets a synthetic entry")
        XCTAssertEqual(injected?.name, "Bass Groove")
        XCTAssertEqual(injected?.artist, "Studio")
        XCTAssertEqual(injected?.length, 4_000, "length is MANDATORY on synthetic entries")
        XCTAssertEqual(injected?.bpm, 124)
        XCTAssertEqual(injected?.camelot, "8A")
        XCTAssertNil(ctx.songsById["smp_a"],
                     "referenced-only: another playlist's studio id is NOT injected into A's ctx")
    }

    func testMakeCtxNeverAdmitsStudioIdsToCandidates() async {
        let s = await wiredStore()
        let a = s.createPlaylist("A")
        s.addSong("lp_b", toPlaylist: a.id)   // has bpm AND camelot — WOULD qualify if leaked
        guard let pl = s.playlist(a.id), let ctx = s.makeCtx(for: pl) else {
            return XCTFail("makeCtx returned nil")
        }
        XCTAssertNotNil(ctx.songsById["lp_b"], "injected for placement…")
        XCTAssertTrue(ctx.candidates.allSatisfy { !StudioFactory.isStudioId($0.id) },
                      "…but NEVER a bridge candidate: user loops must not autofill arbitrary setlists")
    }

    func testMakeCtxReachesStudioIdsThroughPocketDAG() async {
        let s = await wiredStore()
        let inner = s.createPocket("Inner")
        s.addSong("smp_a", toPocket: inner.id)
        let outer = s.createPocket("Outer")
        s.addChildPocket(inner.id, toPocket: outer.id)
        let pl = s.createPlaylist("Set")
        s.addPocketRef(outer.id, toPlaylist: pl.id)

        guard let playlist = s.playlist(pl.id), let ctx = s.makeCtx(for: playlist) else {
            return XCTFail("makeCtx returned nil")
        }
        XCTAssertNotNil(ctx.songsById["smp_a"],
                        "a pocket-held sample (even nested) is 'referenced by the playlist'")
    }

    // MARK: realize — placement with real lengths + engine dedupe

    func testRealizePlacesStudioNodeOnceWithRealLength() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("sng_1", toPlaylist: pl.id)
        s.addSong("lp_b", toPlaylist: pl.id)
        s.addSong("lp_b", toPlaylist: pl.id)   // duplicate node — engine dedupes by songId

        guard let set = s.realize(playlistId: pl.id, seed: "studio-test") else {
            return XCTFail("realize returned nil")
        }
        let loopRows = set.tracks.filter { $0.songId == "lp_b" }
        XCTAssertEqual(loopRows.count, 1, "engine dedupe: the same loop places ONCE per set")
        XCTAssertEqual(loopRows.first?.lengthMs, 4_000)
        XCTAssertEqual(loopRows.first?.shownMs, 4_000)
        XCTAssertNotEqual(loopRows.first?.shownMs, RealizeEngine.defaultTrackMs,
                          "a 4 s loop must never realize as the 210 s default track")
        XCTAssertEqual(set.totalMs, 226_000, "totalMs = sng_1 (222 000) + lp_b (4 000)")
    }

    func testRealizeExplicitSongIdsKeepsStudio() async {
        let s = await wiredStore()
        guard let set = s.realize(songIds: ["sng_1", "smp_a"], name: "Explicit") else {
            return XCTFail("realize returned nil")
        }
        XCTAssertEqual(set.tracks.map(\.songId), ["sng_1", "smp_a"],
                       "the transient-playlist path injects explicit studio ids too")
        XCTAssertEqual(set.tracks.last?.lengthMs, 2_000)
    }

    // MARK: Repeat count flows into the Now Playing snapshot

    func testPlayNowPlaylistCarriesRepeatCount() async {
        let s = await wiredStore()
        let pl = s.createPlaylist("Set")
        s.addSong("lp_b", to: AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences[0].nodeId),
                  repeatCount: 3)
        let set = s.playNow(playlistId: pl.id)
        let track = set?.tracks.first { $0.songId == "lp_b" }
        XCTAssertEqual(track?.repeatCount, 3)
        XCTAssertEqual(track?.perPlayMs, 4_000, "the per-play boundary is ONE play")
        XCTAssertEqual(track?.shownMs, 12_000, "totals count all 3 plays")
    }

    func testPlayNowPocketCarriesRepeatCount() async {
        let s = await wiredStore()
        let pkt = s.createPocket("Pkt")
        s.addSong("smp_a", to: AddTarget(kind: .pocket, id: pkt.id), repeatCount: 2)
        let set = s.playNow(pocketId: pkt.id)
        XCTAssertEqual(set?.tracks.first { $0.songId == "smp_a" }?.repeatCount, 2)
    }

    // MARK: Performer name stamps the studio-item artist

    func testStudioArtistUsesPerformerNameElseStudio() async {
        let s = await wiredStore()
        XCTAssertEqual(s.studioArtist, "Studio", "unset performer name ⇒ the generic label")
        let set1 = s.playNow(songIds: ["smp_a"])
        XCTAssertEqual(set1?.tracks.first?.artist, "Studio")

        s.performerName = "Levi Schoen"
        XCTAssertEqual(s.studioArtist, "Levi Schoen")
        let set2 = s.playNow(songIds: ["smp_a"])
        XCTAssertEqual(set2?.tracks.first?.artist, "Levi Schoen",
                       "the performer name is stamped as the studio item's artist")
    }
}
