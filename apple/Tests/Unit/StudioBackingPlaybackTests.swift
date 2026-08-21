import XCTest
import AVFoundation
@testable import PocketDJ

/// Multi-staff instrumental playback — the RENDERED-MIXDOWN backing that replaced the multitimbral
/// MIDI synth. The shipped bug these pin: a take with 2+ staffs went totally silent (its extra
/// staff rerouted EVERY staff, the original included, onto a synth that never sounded on device),
/// and every failure on that path returned SILENTLY, so a user capture could not name the reason.
@MainActor
final class StudioBackingPlaybackTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-backing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// A real, readable audio file of `seconds` — the backing player's input is a FILE, so the
    /// window/seek/park rules must be exercised against one, not a mock.
    private func writeSilentWave(seconds: Double) throws -> URL {
        let url = tmp.appendingPathComponent("backing-\(UUID().uuidString).wav")
        let fmt = InstrumentEngine.canonicalFormat
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * fmt.sampleRate)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        try file.write(from: buf)
        return url
    }

    // MARK: Routing (which engine path plays an instrumental)

    /// The whole fix in one rule. Single staff keeps the SHIPPED sampler replay — it demonstrably
    /// works and is deliberately untouched; multi-staff plays its rendered mixdown; multi-staff
    /// with no mixdown falls back to real-time per-staff samplers (never to silence, never to the
    /// retired MIDI synth). An overdub BACKING never routes to the sampler at any staff count —
    /// the sampler is the user's overdub voice.
    func testRouteByStaffCountAndRenderAvailability() {
        typealias P = StudioTakePlayback
        XCTAssertEqual(P.route(staffCount: 1, hasRender: false), .sampler)
        XCTAssertEqual(P.route(staffCount: 1, hasRender: true), .sampler,
                       "a single staff is bit-for-bit the shipped path, render or no render")
        XCTAssertEqual(P.route(staffCount: 2, hasRender: true), .renderedAudio)
        XCTAssertEqual(P.route(staffCount: 4, hasRender: true), .renderedAudio)
        XCTAssertEqual(P.route(staffCount: 2, hasRender: false), .liveSamplers)
        XCTAssertEqual(P.route(staffCount: 1, hasRender: true, asBacking: true), .renderedAudio,
                       "an overdub backing may never take the sampler — that is the user's voice")
        XCTAssertEqual(P.route(staffCount: 1, hasRender: false, asBacking: true), .liveSamplers)
    }

    // MARK: The scheduled window (score ms → file frames)

    /// The render's frame 0 IS score-clock ms 0 (`StudioRender.pumpSampler` writes the leading
    /// silence), so a seek is a plain ms→frame conversion and a one-pass window runs to the end of
    /// the file.
    func testBackingWindowOnePassStartsAtTheSeekAndRunsToTheEnd() throws {
        let sr = 44_100.0
        let frames = AVAudioFramePosition(sr * 10)          // a 10 s mixdown
        let w = try XCTUnwrap(InstrumentEngine.backingWindow(fromMs: 2_000, loop: nil,
                                                             fileFrames: frames, sampleRate: sr))
        XCTAssertEqual(w.startFrame, AVAudioFramePosition(sr * 2))
        XCTAssertEqual(w.frameCount, AVAudioFrameCount(sr * 8))
        XCTAssertFalse(w.loops)
        let head = try XCTUnwrap(InstrumentEngine.backingWindow(fromMs: 0, loop: nil,
                                                               fileFrames: frames, sampleRate: sr))
        XCTAssertEqual(head.startFrame, 0)
        XCTAssertEqual(head.frameCount, AVAudioFrameCount(frames))
    }

    /// An overdub with Loop on plays `[region.start, region.end)` forever — and an end past the
    /// render's own length CLAMPS to the file rather than scheduling frames that don't exist.
    func testBackingWindowLoopsTheRegionAndClampsToTheFile() throws {
        let sr = 44_100.0
        let frames = AVAudioFramePosition(sr * 10)
        let w = try XCTUnwrap(InstrumentEngine.backingWindow(fromMs: 3_000,
                                                             loop: (startMs: 3_000, endMs: 5_000),
                                                             fileFrames: frames, sampleRate: sr))
        XCTAssertTrue(w.loops)
        XCTAssertEqual(w.startFrame, AVAudioFramePosition(sr * 3))
        XCTAssertEqual(w.frameCount, AVAudioFrameCount(sr * 2))
        let past = try XCTUnwrap(InstrumentEngine.backingWindow(fromMs: 8_000,
                                                                loop: (startMs: 8_000, endMs: 30_000),
                                                                fileFrames: frames, sampleRate: sr))
        XCTAssertEqual(past.frameCount, AVAudioFrameCount(sr * 2), "clamped to the file's end")
    }

    /// A zero-frame window is REFUSED, never scheduled: scheduling one is an uncatchable crash
    /// (the `StudioEngine.scheduleSampleWindow` rule), and a seek past the end must degrade.
    func testBackingWindowRefusesZeroFrameSchedules() {
        let sr = 44_100.0
        let frames = AVAudioFramePosition(sr * 4)
        XCTAssertNil(InstrumentEngine.backingWindow(fromMs: 4_000, loop: nil,
                                                    fileFrames: frames, sampleRate: sr),
                     "a seek AT the end has no frames left to play")
        XCTAssertNil(InstrumentEngine.backingWindow(fromMs: 9_000, loop: nil,
                                                    fileFrames: frames, sampleRate: sr))
        XCTAssertNil(InstrumentEngine.backingWindow(fromMs: 0, loop: (startMs: 5_000, endMs: 9_000),
                                                    fileFrames: frames, sampleRate: sr),
                     "a loop region entirely past the render is empty once clamped")
        XCTAssertNil(InstrumentEngine.backingWindow(fromMs: 0, loop: nil, fileFrames: 0, sampleRate: sr))
        XCTAssertNil(InstrumentEngine.backingWindow(fromMs: 0, loop: nil, fileFrames: 100, sampleRate: 0))
    }

    /// The looping backing's CURSOR: the render clock counts monotonically across `.loops`
    /// iterations, so the position folds back into the region — iteration 3 paints where
    /// iteration 1 did, exactly as the retired note-scheduler's loop did.
    func testBackingPositionWrapsIntoTheLoopRegion() {
        let region = (startMs: 5_000, endMs: 7_000)
        func at(_ elapsedMs: Int) -> Int {
            InstrumentEngine.wrapIntoLoop(ms: region.startMs + elapsedMs, region: region)
        }
        XCTAssertEqual(at(0), 5_000)
        XCTAssertEqual(at(1_500), 6_500)
        XCTAssertEqual(at(2_000), 5_000, "the wrap point is the region's start again")
        XCTAssertEqual(at(5_500), 6_500, "iteration 3 paints where iteration 1 did")
    }

    // MARK: No silent failures (the reason a user capture will name)

    /// EVERY exit is a distinct, non-empty reason string. This is the compile-time proof that no
    /// early return on the playback path is a bare `return` — the defect that let a total silence
    /// ship and be un-diagnosable from a debug capture.
    func testEveryBackingExitCarriesADistinctReason() {
        let raws = InstrumentEngine.BackingStart.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count, "reasons must be distinguishable in a capture")
        XCTAssertTrue(raws.allSatisfy { !$0.isEmpty })
        XCTAssertGreaterThanOrEqual(raws.count, 6)
        // Only the two START cases are audible; every other case is a refusal the ▶ alerts on.
        for c in InstrumentEngine.BackingStart.allCases {
            XCTAssertEqual(c.isAudible, c == .started || c == .startedOnePassFallback,
                           "\(c.rawValue) misreports whether audio actually started")
        }
    }

    /// A mixdown that can't be opened REFUSES by name, leaves the transport alone, and — the part
    /// that silently rots a device — releases the file's security scope instead of leaking it.
    func testUnreadableMixdownRefusesByNameAndReleasesItsScope() {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        var released = false
        let out = engine.replayRenderedAudio(url: tmp.appendingPathComponent("not-there.m4a"),
                                             release: { released = true }, forTake: "tk_x")
        XCTAssertTrue(out == .fileUnreadable || out == .noEngine,
                      "a refusal is NAMED (got \(out.rawValue)) — never a silent no-op")
        XCTAssertFalse(out.isAudible)
        XCTAssertFalse(engine.isReplaying, "a refused backing must not leave the transport armed")
        XCTAssertTrue(released, "the security scope is released on EVERY refusal — never leaked")
    }

    /// Seeking past the end of the mixdown parks the cursor where the tap asked for (the
    /// `replayTake` rule) and says so, instead of scheduling an empty window or doing nothing.
    func testSeekPastTheEndParksTheCursorAndNamesTheReason() throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let url = try writeSilentWave(seconds: 1)
        var released = false
        let out = engine.replayRenderedAudio(url: url, release: { released = true },
                                             fromMs: 9_000, forTake: "tk_seek")
        XCTAssertEqual(out, .seekPastEnd)
        XCTAssertFalse(engine.isReplaying)
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_seek"), 9_000,
                       "the cursor parks where the seek asked — the 'last played' emphasis holds")
        XCTAssertTrue(released)
    }

    /// The whole point: a real mixdown STARTS, owns the clock, reports its position from the
    /// render clock, and gives everything back on stop — repeatedly, with no node/scope leak
    /// across cycles (the one-audio-owner rule).
    func testAMixdownStartsReportsPositionAndFullyReleasesOnStop() throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let url = try writeSilentWave(seconds: 3)
        for cycle in 0..<3 {
            var released = false
            let out = engine.replayRenderedAudio(url: url, release: { released = true },
                                                 fromMs: 1_000, forTake: "tk_play")
            XCTAssertTrue(out.isAudible, "cycle \(cycle): \(out.rawValue)")
            XCTAssertTrue(engine.isReplaying)
            XCTAssertTrue(engine.replayClockBelongs(to: "tk_play"))
            XCTAssertEqual(engine.replayPositionMs(forTake: "tk_play") ?? -1, 1_000, accuracy: 250,
                           "position is read from the backing's own clock, anchored at the seek")
            XCTAssertFalse(released, "the scope is HELD for the whole play (releasing early ⇒ 0:00)")
            engine.stopReplay()
            XCTAssertFalse(engine.isReplaying)
            XCTAssertTrue(released, "cycle \(cycle): the scope is released exactly on stop")
            XCTAssertNotNil(engine.replayPositionMs(forTake: "tk_play"),
                            "a stopped backing FREEZES the cursor where it stopped")
        }
    }

    /// A looping backing (an overdub with Loop on) schedules its region and keeps the cursor
    /// inside it — the confined-region contract, now driven by audio.
    func testALoopingBackingKeepsTheCursorInsideItsRegion() throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let url = try writeSilentWave(seconds: 4)
        let out = engine.replayRenderedAudio(url: url, fromMs: 1_000, forTake: "tk_loop",
                                             loopRegion: (startMs: 1_000, endMs: 2_000))
        XCTAssertTrue(out.isAudible, out.rawValue)
        let pos = try XCTUnwrap(engine.replayPositionMs(forTake: "tk_loop"))
        XCTAssertGreaterThanOrEqual(pos, 1_000,
                                    "the cursor never reads BEFORE the region — the render clock "
                                    + "is momentarily negative right after play()")
        XCTAssertLessThanOrEqual(pos, 2_000, "the cursor never leaves the confined region")
        engine.stopReplay()
    }
}
