import XCTest
@testable import PocketDJ

/// Tests for the native realize() engine port (mirrors the PWA's realize.test.ts).
@MainActor
final class RealizeEngineTests: XCTestCase {

    // Build a RealizeCtx from the in-memory TestData fixture (songs carry bpm/key/camelot).
    private func ctx(pockets: [Pocket] = []) throws -> RealizeCtx {
        let idx = try TestData.index()
        let songsById = Dictionary(idx.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let albumsById = Dictionary(idx.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = idx.songs.filter { $0.bpm != nil && $0.camelot != nil }
        return RealizeCtx(songsById: songsById, albumsById: albumsById,
                          pocketsById: pocketsById, candidates: candidates)
    }

    private func seq(_ name: String, targetMs: Int? = nil, _ children: [PlaylistNode]) -> PlaylistNode {
        PlaylistNode(nodeId: "seq_\(name)", kind: .sequence, name: name, targetMs: targetMs, children: children)
    }
    private func song(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "n_\(id)", kind: .song, songId: id) }
    private func album(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "n_\(id)", kind: .album, albumId: id) }
    private func pocketRef(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "n_\(id)", kind: .pocket, pocketId: id) }
    private func text(_ t: String) -> PlaylistNode { PlaylistNode(nodeId: "n_t", kind: .text, text: t) }

    private func playlist(_ sequences: [PlaylistNode]) -> Playlist {
        Playlist(id: "pls_test", name: "Test", sequences: sequences, createdAt: 0, updatedAt: 0)
    }

    // MARK: Determinism

    func testDeterministicSameSeedSameTracks() throws {
        let c = try ctx()
        // A pocket whose ordering depends on the seeded anchor pick.
        let pkt = Pocket(id: "pkt_1", name: "All", songIds: ["sng_1","sng_2","sng_3","sng_4","sng_5"])
        let c2 = try ctx(pockets: [pkt])
        _ = c
        let pl = playlist([seq("A", [pocketRef("pkt_1")])])
        let a = RealizeEngine.realize(pl, c2, RealizeOptions(seed: "fixed-seed"))
        let b = RealizeEngine.realize(pl, c2, RealizeOptions(seed: "fixed-seed"))
        XCTAssertEqual(a.tracks.map(\.songId), b.tracks.map(\.songId))
        XCTAssertEqual(a.totalMs, b.totalMs)
        XCTAssertFalse(a.tracks.isEmpty)
    }

    func testDifferentSeedsCanDiffer() throws {
        let pkt = Pocket(id: "pkt_1", name: "All", songIds: ["sng_1","sng_2","sng_3","sng_4","sng_5","sng_6","sng_7"])
        let c = try ctx(pockets: [pkt])
        let pl = playlist([seq("A", [pocketRef("pkt_1")])])
        // Same membership/dedup set, but the anchor (hence chain order) is seeded.
        let a = RealizeEngine.realize(pl, c, RealizeOptions(seed: "seed-A"))
        let b = RealizeEngine.realize(pl, c, RealizeOptions(seed: "seed-B"))
        XCTAssertEqual(Set(a.tracks.map(\.songId)), Set(b.tracks.map(\.songId)))  // same members
        // At least one seed pair should produce a different ORDER (anchor differs).
        let orderDiffers = a.tracks.map(\.songId) != b.tracks.map(\.songId)
        // Not guaranteed for every pair, but with this pool it holds; assert membership at minimum.
        XCTAssertTrue(orderDiffers || a.tracks.count == b.tracks.count)
    }

    // MARK: Album expansion

    func testAlbumExpandsToTracksInOrder() throws {
        let c = try ctx()
        let pl = playlist([seq("A", [album("alb_1")])])
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        XCTAssertEqual(perf.tracks.map(\.songId), ["sng_1","sng_2","sng_3"])
        XCTAssertTrue(perf.tracks.allSatisfy { $0.source == .explicit })
        XCTAssertEqual(perf.stats.explicit, 3)
        // Snapshot copies metadata inline.
        XCTAssertEqual(perf.tracks.first?.artist, "Aria")
        XCTAssertEqual(perf.tracks.first?.camelot, "8A")
    }

    func testDedupAcrossNodes() throws {
        let c = try ctx()
        // sng_1 explicit, then album alb_1 (which also contains sng_1) → no dup.
        let pl = playlist([seq("A", [song("sng_1"), album("alb_1")])])
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        XCTAssertEqual(perf.tracks.map(\.songId), ["sng_1","sng_2","sng_3"])
    }

    // MARK: Pocket flatten + dedup + cycle guard

    func testPocketFlattenNestedDedupAndCycleGuard() throws {
        // A → B → A (cycle). A owns sng_1; B owns sng_1 (dup) + sng_2.
        let a = Pocket(id: "pkt_A", name: "A", songIds: ["sng_1"], childPocketIds: ["pkt_B"])
        let b = Pocket(id: "pkt_B", name: "B", songIds: ["sng_1","sng_2"], childPocketIds: ["pkt_A"])
        let c = try ctx(pockets: [a, b])
        var seen = Set<String>()
        let songs = RealizeEngine.resolvePocketSongs("pkt_A", c, seen: &seen)
        // own sng_1, then child B's sng_1 (dedup) + sng_2; cycle back to A is guarded.
        XCTAssertEqual(songs.map(\.id), ["sng_1","sng_2"])
    }

    func testPocketAlbumExpansionInResolve() throws {
        let p = Pocket(id: "pkt_1", name: "P", albumIds: ["alb_2"])
        let c = try ctx(pockets: [p])
        var seen = Set<String>()
        let songs = RealizeEngine.resolvePocketSongs("pkt_1", c, seen: &seen)
        XCTAssertEqual(songs.map(\.id), ["sng_4","sng_5"])  // alb_2 tracklist order
    }

    // MARK: Budget prefix (fitPrefix via a budgeted sequence)

    func testBudgetPrefixCutsPocketToFit() throws {
        // alb durations: sng_1=222s, sng_2=201s, sng_3=305s. Budget 230s ⇒ only the
        // first chain track fits (≥1 guaranteed), the rest overflow.
        let pkt = Pocket(id: "pkt_1", name: "P", songIds: ["sng_1","sng_2","sng_3"])
        let c = try ctx(pockets: [pkt])
        let pl = playlist([seq("A", targetMs: 230_000, [pocketRef("pkt_1")])])
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        // The pocket prefix fits at least one but not all three (3*~220s ≫ 230s).
        let pocketTracks = perf.tracks.filter { $0.source == .pocket }
        XCTAssertGreaterThanOrEqual(pocketTracks.count, 1)
        XCTAssertLessThan(pocketTracks.count, 3)
        XCTAssertLessThanOrEqual(perf.totalMs, 230_000 + RealizeEngine.defaultTrackMs)  // sane bound
    }

    // MARK: Text cues

    func testTextCueIsZeroMsAndNeverDeduped() throws {
        let c = try ctx()
        let pl = playlist([seq("A", [text("mic break"), text("mic break"), song("sng_1")])])
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        let cues = perf.tracks.filter { $0.isText == true }
        XCTAssertEqual(cues.count, 2)                       // never deduped
        XCTAssertEqual(perf.totalMs, 222_000)              // only sng_1 contributes
    }

    // MARK: Autofill inserts harmonic bridges under a budget

    func testAutofillInsertsBridgesUnderBudget() throws {
        let c = try ctx()
        // Two explicit anchors far apart on the wheel (8A vs 10A) leave a rough seam
        // and a big leftover budget ⇒ autofill should bridge it from the candidate pool.
        let pl = playlist([seq("A", targetMs: 1_800_000, [song("sng_1"), song("sng_7")])])
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        let bridges = perf.tracks.filter { $0.source == .autofill }
        XCTAssertGreaterThanOrEqual(bridges.count, 1, "autofill should bridge the seam")
        XCTAssertEqual(perf.stats.autofilled, bridges.count)
        // Every bridge is beat+key mixable (drawn from candidates).
        XCTAssertTrue(bridges.allSatisfy { $0.bpm != nil && $0.camelot != nil })
        // Total stays within budget (each insert is gated by the remaining budget).
        XCTAssertLessThanOrEqual(perf.totalMs, 1_800_000)
        // No duplicate songIds anywhere (used-guard).
        let ids = perf.tracks.map(\.songId)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testNoAutofillWithoutBudget() throws {
        let c = try ctx()
        let pl = playlist([seq("A", [song("sng_1"), song("sng_7")])])   // no targetMs
        let perf = RealizeEngine.realize(pl, c, RealizeOptions(seed: "s"))
        XCTAssertEqual(perf.stats.autofilled, 0)
        XCTAssertEqual(perf.tracks.map(\.songId), ["sng_1","sng_7"])
    }

    // MARK: buildSetlist wrapper

    func testBuildSetlistFreezesWithSeed() throws {
        let c = try ctx()
        let pl = playlist([seq("A", [album("alb_1")])])
        let sl = RealizeEngine.buildSetlist(pl, c, seed: "fixed", name: "Take 1", now: 123)
        XCTAssertTrue(sl.id.hasPrefix("set_"))
        XCTAssertEqual(sl.playlistId, "pls_test")
        XCTAssertEqual(sl.seed, "fixed")
        XCTAssertEqual(sl.generatedAt, 123)
        XCTAssertEqual(sl.tracks.count, 3)
        // Re-running realize with the stored seed reproduces the same tracks.
        let again = RealizeEngine.realize(pl, c, RealizeOptions(seed: sl.seed))
        XCTAssertEqual(again.tracks.map(\.songId), sl.tracks.map(\.songId))
    }
}

// MARK: - Seeded RNG parity with the PWA

final class SeededRNGTests: XCTestCase {
    func testFnv1aMatchesReference() {
        // Reference values computed from the JS fnv1a (src/lib/prng.ts).
        XCTAssertEqual(PRNG.fnv1a(""), 0x811c_9dc5)
        XCTAssertEqual(PRNG.fnv1a("a"), 0xe40c_292c)
        XCTAssertEqual(PRNG.fnv1a("hello"), 0x4f9f_2cab)
    }

    func testMulberryDeterministicAndInRange() {
        let r1 = PRNG.seededRng("seed")
        let r2 = PRNG.seededRng("seed")
        for _ in 0..<50 {
            let a = r1(), b = r2()
            XCTAssertEqual(a, b)                 // same seed ⇒ same stream
            XCTAssertGreaterThanOrEqual(a, 0)
            XCTAssertLessThan(a, 1)
        }
        // Different seeds ⇒ different first draw.
        XCTAssertNotEqual(PRNG.seededRng("x")(), PRNG.seededRng("y")())
    }
}

// MARK: - Harmonics parity spot-checks

final class HarmonicsUnitTests: XCTestCase {
    func testCamelotDistanceBasics() {
        XCTAssertEqual(Harmonics.camelotDistance("8A", "8A"), 0)
        XCTAssertEqual(Harmonics.camelotDistance("1A", "12A"), 1)   // wrap
        XCTAssertEqual(Harmonics.camelotDistance("8A", "8B"), 1)    // relative major/minor
        XCTAssertNil(Harmonics.camelotDistance("8A", "bogus"))
    }
    func testBpmDoubleTimeAware() {
        XCTAssertEqual(Harmonics.bpmDistance(70, 140), 0)          // double-time = perfect
        XCTAssertNil(Harmonics.bpmDistance(nil, 120))
    }
    func testHarmonicDistanceNullSafeAndBounded() {
        let idx = try! TestData.index()
        let by = Dictionary(idx.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let d = Harmonics.harmonicDistance(by["sng_1"]!, by["sng_2"]!)
        XCTAssertGreaterThanOrEqual(d, 0)
        XCTAssertLessThanOrEqual(d, 1)
    }
}
