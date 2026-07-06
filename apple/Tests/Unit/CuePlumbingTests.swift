import XCTest
@testable import PocketDJ

/// Cue-offset plumbing (spec §9) + the studio-id rip fence (spec §8) — the PURE/derivable
/// halves only. Hermetic: every path exercised here returns/throws BEFORE any network
/// (guards precede the POSTs; no-server fallbacks never call out), so no URLSession stubbing.
@MainActor
final class CuePlumbingTests: XCTestCase {

    // MARK: cueSeekMs — the spec-§9 offset math (RipsStore.cueSeekMs, pure)

    /// No cue → the pre-cue behavior bit-for-bit: the shared-file start passes through.
    func testNoCuePassesSharedStartThrough() {
        XCTAssertEqual(RipsStore.cueSeekMs(sharedFileStartMs: 61_000, atMs: nil, live: false), 61_000)
        XCTAssertNil(RipsStore.cueSeekMs(sharedFileStartMs: nil, atMs: nil, live: false))
    }

    /// Digital per-song file (no shared start): the cue IS the absolute position.
    func testDigitalCueIsDirect() {
        XCTAssertEqual(RipsStore.cueSeekMs(sharedFileStartMs: nil, atMs: 20_000, live: false), 20_000)
    }

    /// Shared analog album file: PlayerEngine.load must get song-start + cue (spec §9's
    /// "cue ms + startMs-for-shared-analog"), driven from a real manifest entry.
    func testAnalogSharedFileCueAddsEntryStart() {
        // An analog album-side entry: this song starts 61 s into the shared mp3.
        let entry = RipsStore.ManifestEntry(key: "rips/album-side-a.mp3", startMs: 61_000)
        let seek = RipsStore.cueSeekMs(sharedFileStartMs: entry.startMs, atMs: 20_000, live: false)
        XCTAssertEqual(seek, 81_000)
    }

    /// A cue at 0:00 on an analog track still lands on the SONG's start, not the album's.
    func testAnalogCueAtZeroIsSongStart() {
        XCTAssertEqual(RipsStore.cueSeekMs(sharedFileStartMs: 61_000, atMs: 0, live: false), 61_000)
    }

    /// Live in-flight HLS can NEVER seek — nil regardless of cue/shared start, so a caller
    /// can't accidentally schedule a seek on an unseekable stream.
    func testLiveAlwaysNil() {
        XCTAssertNil(RipsStore.cueSeekMs(sharedFileStartMs: 61_000, atMs: 20_000, live: true))
        XCTAssertNil(RipsStore.cueSeekMs(sharedFileStartMs: nil, atMs: 5_000, live: true))
        XCTAssertNil(RipsStore.cueSeekMs(sharedFileStartMs: 61_000, atMs: nil, live: true))
    }

    /// A (corrupt/hand-edited) negative cue clamps to the song's start — never seeks into
    /// the PREVIOUS track of a shared album file.
    func testNegativeCueClampsToSongStart() {
        XCTAssertEqual(RipsStore.cueSeekMs(sharedFileStartMs: 61_000, atMs: -5_000, live: false), 61_000)
        XCTAssertEqual(RipsStore.cueSeekMs(sharedFileStartMs: nil, atMs: -5_000, live: false), 0)
    }

    // MARK: Studio-id fence — pure filter (RipsStore.excludingStudioIds, spec §8)

    /// Every collection-riding studio prefix is dropped; catalog ids survive in order.
    func testExcludingStudioIdsDropsAllStudioPrefixes() {
        let mixed = ["sng_1", "smp_a", "lp_b", "am:123", "ptn_c", "tk_d", "sng_2"]
        XCTAssertEqual(RipsStore.excludingStudioIds(mixed), ["sng_1", "am:123", "sng_2"])
    }

    /// `cue_` ids pass through ON PURPOSE: cues never ride collection arrays, so the fence
    /// must not treat them as routable studio items (StudioFactory.newCueId's contract).
    func testCueIdsAreNotFenced() {
        XCTAssertEqual(RipsStore.excludingStudioIds(["cue_x", "sng_1"]), ["cue_x", "sng_1"])
    }

    /// The filter routes on StudioFactory.isStudioId — the single source of truth — so a
    /// lookalike id that merely CONTAINS a prefix isn't dropped.
    func testFenceIsPrefixAnchored() {
        XCTAssertFalse(StudioFactory.isStudioId("song_smp_1"))
        XCTAssertTrue(StudioFactory.isStudioId("smp_" + StudioFactory.uid()))
        XCTAssertEqual(RipsStore.excludingStudioIds(["song_smp_1"]), ["song_smp_1"])
    }

    // MARK: Studio-id fence — guard-returns on the single-song entry points (no network:
    // every studio-id guard fires before the first URLSession touch)

    /// `requestRip` classifies a studio id as `.unknown` (not a rippable catalog song),
    /// which stops every caller's completion polling.
    func testRequestRipGuardReturnsUnknownForStudioId() async {
        let rips = RipsStore()
        let outcome = await rips.requestRip(songId: "smp_abc", title: "My Sample", artist: "Me")
        XCTAssertEqual(outcome, .unknown)
        XCTAssertNil(rips.jobs["smp_abc"], "a fenced id must never gain a job entry")
    }

    /// The fire-and-forget paths guard-return silently — no job/stem-job state appears.
    func testFireAndForgetPathsGuardReturn() async {
        let rips = RipsStore()
        await rips.requestRipIfNeeded("lp_abc")
        await rips.stemify("ptn_abc")
        XCTAssertNil(rips.jobs["lp_abc"])
        XCTAssertNil(rips.stemJobs["ptn_abc"])
    }

    /// `ensureURL` (the play/download choke point that POSTs `/rip`) throws the explicit
    /// `.studioItem` error for a studio id instead of hitting the server.
    func testEnsureURLThrowsStudioItem() async {
        let rips = RipsStore()
        do {
            _ = try await rips.ensureURL("tk_abc", allowLive: true)
            XCTFail("expected RipError.studioItem")
        } catch let e as RipsStore.RipError {
            guard case .studioItem = e else { return XCTFail("expected .studioItem, got \(e)") }
        } catch {
            XCTFail("expected RipError.studioItem, got \(error)")
        }
    }

    /// Batch rip: studio ids are fenced BEFORE the request is even shaped — the per-song
    /// results contain only catalog ids (no-server fallback classifies them "unknown",
    /// which is fine: the assertion is about WHICH ids are present at all).
    func testRipCollectionFiltersStudioIdsFromResults() async {
        let rips = RipsStore()
        let result = await rips.ripCollection(["smp_a", "sng_1", "lp_b", "sng_2", "tk_c"])
        XCTAssertEqual(result.results.map(\.songId), ["sng_1", "sng_2"])
        XCTAssertEqual(result.total, 2)
    }

    /// An all-studio list collapses to the empty-input no-op (zero counts, no results).
    func testRipCollectionAllStudioIsNoop() async {
        let rips = RipsStore()
        let result = await rips.ripCollection(["smp_a", "ptn_b"])
        XCTAssertEqual(result.results, [])
        XCTAssertEqual(result.total, 0)
    }

    /// Batch stemify mirrors the batch-rip fence.
    func testStemifyCollectionFiltersStudioIds() async {
        let rips = RipsStore()
        let result = await rips.stemifyCollection(["lp_a", "sng_1"])
        XCTAssertEqual(result.results.map(\.songId), ["sng_1"])
        XCTAssertEqual(result.total, 1)
    }
}
