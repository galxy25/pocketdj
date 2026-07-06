import XCTest
@testable import PocketDJ

/// StudioMicRecorder — hermetic tests of the PURE seams: collision-free take naming, the
/// orphan-scan adoption decision, the stall-watchdog math, and the session-coexistence flag.
/// No real AVAudioSession / engine / microphone is touched (tests can't post as the shared
/// session — the *ForTesting doctrine); the realtime plumbing reuses MixTapSink, which the
/// recording-bulletproof suite already pins. These pin the logic that must not drift.
final class StudioMicRecorderTests: XCTestCase {

    // MARK: - Collision-free naming (mintSampleFile)

    /// Names already on disk are skipped; the winner is the family's exact deterministic shape
    /// and round-trips through the strict parser.
    func testMintSkipsTakenNamesAndMintsFamilyShape() {
        var served = 0
        let ids = ["smp_aaa", "smp_bbb", "smp_ccc"]
        let taken: Set<String> = [StudioFolders.fileName(.samples, id: "smp_aaa"),
                                  StudioFolders.fileName(.samples, id: "smp_bbb")]
        let got = StudioMicRecorder.mintSampleFile(
            isTaken: { taken.contains($0) },
            mintId: { defer { served += 1 }; return ids[min(served, ids.count - 1)] })
        XCTAssertEqual(got.id, "smp_ccc")
        XCTAssertEqual(got.fileName, "sample-smp_ccc.m4a")
        XCTAssertEqual(StudioFolders.fileId(family: .samples, name: got.fileName), got.id)
    }

    /// The mint loop is BOUNDED: a pathological `isTaken` (everything claimed) returns the last
    /// mint instead of hanging the record button forever.
    func testMintTerminatesWhenEverythingIsTaken() {
        let got = StudioMicRecorder.mintSampleFile(isTaken: { _ in true },
                                                   mintId: { "smp_stuck" })
        XCTAssertEqual(got.id, "smp_stuck")
        XCTAssertEqual(got.fileName, "sample-smp_stuck.m4a")
    }

    /// The default minter produces a namespaced sample id whose file name embeds it.
    func testDefaultMintProducesNamespacedId() {
        let got = StudioMicRecorder.mintSampleFile(isTaken: { _ in false })
        XCTAssertTrue(got.id.hasPrefix("smp_"))
        XCTAssertGreaterThan(got.id.count, "smp_".count)
        XCTAssertEqual(got.fileName, "sample-\(got.id).m4a")
    }

    // MARK: - Orphan-scan adoption decision (adoptableSampleId)

    /// A raw, document-unknown capture in either root is adoptable.
    func testAdoptsUnknownRawCapture() {
        XCTAssertEqual(StudioMicRecorder.adoptableSampleId(
            fileName: "sample-smp_x.m4a", knownIds: [], activeTake: nil, rootIsUser: false), "smp_x")
        XCTAssertEqual(StudioMicRecorder.adoptableSampleId(
            fileName: "sample-smp_x.m4a", knownIds: [], activeTake: nil, rootIsUser: true), "smp_x")
    }

    /// A render cache (`-r<rev>` stamp) parses to the same id but is DERIVED data — it must
    /// never resurrect as a phantom take, even when the id is unknown (deleted-sample stray).
    func testNeverAdoptsRenderCacheStamp() {
        let cache = StudioFolders.renderedSampleFileName(id: "smp_x", revision: 3)
        // Sanity: the strict parser DOES attribute the cache to the sample id …
        XCTAssertEqual(StudioFolders.fileId(family: .samples, name: cache), "smp_x")
        // … and the adoption decision still refuses it.
        XCTAssertNil(StudioMicRecorder.adoptableSampleId(
            fileName: cache, knownIds: [], activeTake: nil, rootIsUser: false))
    }

    /// Document-known ids are skipped (idempotency — repeated scans can't duplicate).
    func testNeverAdoptsKnownId() {
        XCTAssertNil(StudioMicRecorder.adoptableSampleId(
            fileName: "sample-smp_x.m4a", knownIds: ["smp_x"], activeTake: nil, rootIsUser: false))
    }

    /// The active take is skipped ROOT-AWARE: the live file in its own root is never adopted,
    /// but a same-named file in the OTHER root is a genuine orphan (the both-roots doctrine).
    func testActiveTakeSkipIsRootAware() {
        let live = (fileName: "sample-smp_live.m4a", wasUserFolder: true)
        XCTAssertNil(StudioMicRecorder.adoptableSampleId(
            fileName: live.fileName, knownIds: [], activeTake: live, rootIsUser: true))
        XCTAssertEqual(StudioMicRecorder.adoptableSampleId(
            fileName: live.fileName, knownIds: [], activeTake: live, rootIsUser: false), "smp_live")
    }

    /// Foreign shapes never parse — user folders hold user files, and other families'/apps'
    /// artifacts must never be adopted as mic samples.
    func testNeverAdoptsForeignShapes() {
        for name in ["sample-of-my-mix.m4a",   // loose prefix, no id namespace
                     "loop-lp_x.caf",          // another family
                     "recording-3.m4a",        // mix-session take shape
                     "sample-smp_x.caf",       // wrong extension
                     "sample-smp_.m4a",        // empty id past the namespace
                     "sample-.m4a",            // no id at all
                     ".DS_Store"] {
            XCTAssertNil(StudioMicRecorder.adoptableSampleId(
                fileName: name, knownIds: [], activeTake: nil, rootIsUser: true), name)
        }
    }

    // MARK: - Stall-watchdog math (clampedTickDt / nextStallAccum)

    /// dt clamps to [0, 0.5]: first tick contributes nothing, a suspension gap at most 0.5 s,
    /// and a backwards clock never goes negative.
    func testClampedTickDt() {
        XCTAssertEqual(StudioMicRecorder.clampedTickDt(now: 100, last: nil), 0)
        XCTAssertEqual(StudioMicRecorder.clampedTickDt(now: 100.1, last: 100), 0.1, accuracy: 1e-9)
        XCTAssertEqual(StudioMicRecorder.clampedTickDt(now: 130, last: 100), 0.5)   // 30 s suspension
        XCTAssertEqual(StudioMicRecorder.clampedTickDt(now: 99, last: 100), 0)
    }

    /// The accumulator starts from the just-armed grace state (previousAppended < 0), grows by
    /// dt while appended media is frozen, and resets the moment media advances.
    func testStallAccumGraceGrowthAndReset() {
        // Just armed: no accumulation regardless of dt.
        XCTAssertEqual(StudioMicRecorder.nextStallAccum(0, dt: 0.5, appended: 0, previousAppended: -1), 0)
        // Frozen: grows by dt.
        XCTAssertEqual(StudioMicRecorder.nextStallAccum(1.0, dt: 0.1, appended: 2.0, previousAppended: 2.0),
                       1.1, accuracy: 1e-9)
        // Sub-granularity wiggle (≤10 ms) is NOT progress.
        XCTAssertEqual(StudioMicRecorder.nextStallAccum(1.0, dt: 0.1, appended: 2.005, previousAppended: 2.0),
                       1.1, accuracy: 1e-9)
        // Real progress resets.
        XCTAssertEqual(StudioMicRecorder.nextStallAccum(4.9, dt: 0.1, appended: 2.1, previousAppended: 2.0), 0)
    }

    /// Ten clamped max-dt ticks of frozen media reach the 5 s warn threshold — and an app
    /// suspension (dt clamped to 0.5) therefore needs ten OBSERVED ticks, never one giant leap.
    func testStallWarnThresholdViaClampedTicks() {
        var accum = 0.0
        var previous = -1.0
        for _ in 0..<11 {   // 1 arming tick + 10 frozen ticks at the 0.5 s clamp
            accum = StudioMicRecorder.nextStallAccum(accum, dt: 0.5, appended: 3.0, previousAppended: previous)
            previous = 3.0
        }
        XCTAssertGreaterThanOrEqual(accum, StudioMicRecorder.stallWarnSeconds)
        // One tick short must NOT warn.
        var short = 0.0
        previous = -1.0
        for _ in 0..<10 {
            short = StudioMicRecorder.nextStallAccum(short, dt: 0.5, appended: 3.0, previousAppended: previous)
            previous = 3.0
        }
        XCTAssertLessThan(short, StudioMicRecorder.stallWarnSeconds)
    }

    // MARK: - Session-coexistence policy (spec §4)

    /// begin/end toggle the process-wide flag the playback engines' setCategory(.playback)
    /// guards read. (Process-global on purpose — restored in all paths so other tests never see
    /// a stuck flag.)
    func testMicCapturePolicyToggles() {
        defer { AudioSessionPolicy.endMicCapture() }
        XCTAssertFalse(AudioSessionPolicy.micCaptureActive)
        AudioSessionPolicy.beginMicCapture()
        XCTAssertTrue(AudioSessionPolicy.micCaptureActive)
        AudioSessionPolicy.beginMicCapture()   // idempotent — a Bool, not a count (one recorder)
        XCTAssertTrue(AudioSessionPolicy.micCaptureActive)
        AudioSessionPolicy.endMicCapture()
        XCTAssertFalse(AudioSessionPolicy.micCaptureActive)
    }
}
