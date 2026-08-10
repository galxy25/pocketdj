import XCTest
@testable import PocketDJ

/// **New is playable** — owner, verbatim: *"we want to be able to play or shuffle New as well,
/// that is the equivalent of cloud mode for a collection."*
///
/// The decision that makes that true or false is `ReleaseStreaming.items`: what id each track of
/// an unowned release gets queued under. Get it wrong and ▶ either plays nothing (a catalog id
/// that resolves to no song is dropped by `playNow`) or parks the queue on a row with no audio.
/// The expansion around it is network; this is the part that has to be right, so it is pure.
final class ReleaseStreamingTests: XCTestCase {

    private func track(_ storeID: String, _ title: String = "T", _ artist: String = "A",
                       lengthMs: Int? = nil) -> ReleaseStreamTrack {
        ReleaseStreamTrack(storeID: storeID, title: title, artist: artist, lengthMs: lengthMs)
    }

    /// THE WHOLE POINT: a record he does not own queues under the `am:<storeID>` namespace, which
    /// `PlaybackCoordinator.providers(for:)` routes straight to MusicKit. Any other id would be
    /// dropped as unresolvable.
    func testUnownedTrackQueuesUnderTheAppleMusicNamespace() {
        let items = ReleaseStreaming.items([track("1440913170", "Fake Empire", "The National")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "am:1440913170")
        XCTAssertEqual(items[0].title, "Fake Empire")
        XCTAssertEqual(items[0].artist, "The National")
        XCTAssertNotNil(AppleMusicCatalog.storeID(fromSongID: items[0].id),
                        "the coordinator must be able to read the store id back out")
    }

    /// A track he ALREADY has plays under its own catalog id, so device mode can reach the burned
    /// file and history/stats key the real song rather than a parallel streaming identity.
    func testOwnedTrackQueuesUnderItsCatalogId() {
        let items = ReleaseStreaming.items([track("111"), track("222")],
                                           catalogSongId: { $0 == "111" ? "sng_owned" : nil })
        XCTAssertEqual(items.map(\.id), ["sng_owned", "am:222"])
    }

    /// DEGRADE, NEVER STALL: a row that can never resolve to audio is dropped rather than queued
    /// and skipped at play time.
    func testTrackWithNoStoreIdIsSkipped() {
        let items = ReleaseStreaming.items([track(""), track("   "), track("333")])
        XCTAssertEqual(items.map(\.id), ["am:333"])
    }

    /// A single is routinely also a track on the album released beside it, and one artist can
    /// appear twice in a 30-day feed. Queueing the same track twice would play it twice.
    func testDuplicatesCollapseAndOrderIsPreserved() {
        let items = ReleaseStreaming.items([track("1"), track("2"), track("1"), track("3")])
        XCTAssertEqual(items.map(\.id), ["am:1", "am:2", "am:3"])
    }

    /// Dedupe happens on the RESOLVED id: the same track reached once as a catalog song and once
    /// as a store id is still one track.
    func testDedupeIsOnTheResolvedId() {
        let items = ReleaseStreaming.items([track("1"), track("1")],
                                           catalogSongId: { _ in "sng_x" })
        XCTAssertEqual(items.map(\.id), ["sng_x"])
    }

    /// `lengthMs` rides along so the sequencer's per-track end boundary is right.
    func testLengthRidesAlong() {
        let items = ReleaseStreaming.items([track("9", lengthMs: 214_000)])
        XCTAssertEqual(items[0].lengthMs, 214_000)
    }

    func testEmptyInputYieldsEmptyQueue() {
        XCTAssertTrue(ReleaseStreaming.items([]).isEmpty)
    }

    // ========================================================================
    // MARK: - The UI fixture the New toolbar is driven against
    // ========================================================================

    /// The seam is DOUBLE-GATED so a stray `PDJ_REC_FIXTURE` can never light canned releases up in
    /// a real run — the same rule `RecommendationService.wantsFixture` follows.
    func testUIFixtureIsDoubleGated() {
        let env = ProcessInfo.processInfo.environment
        if env["PDJ_USE_FIXTURE"] == nil {
            XCTAssertFalse(ReleaseFeedService.wantsUIFixture)
        }
    }

    /// Two out-now and one pre-order, so the screen renders both sections — and so a test can
    /// assert that ▶ queues only the out-now half.
    @MainActor
    func testUIFixtureSplitsOutNowFromComingSoon() {
        let now: Double = 1_700_000_000_000
        let svc = ReleaseFeedService(transport: nil,
                                     fileURL: FileManager.default.temporaryDirectory
                                         .appendingPathComponent("rf-\(UUID().uuidString).json"))
        svc.seedForTesting(ReleaseFeedService.uiFixtureEntries(nowMs: now))
        XCTAssertEqual(svc.outNow(nowMs: now).count, 2)
        XCTAssertEqual(svc.comingSoon(nowMs: now).count, 1)
        XCTAssertEqual(svc.outNow(nowMs: now).compactMap(\.entry.releaseId),
                       ["9000000001", "9000000002"], "newest first")
    }
}
