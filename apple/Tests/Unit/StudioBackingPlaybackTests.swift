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
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-backing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Hermetic studio root, so an END-TO-END play can resolve a real mixdown out of the real
        // instrumentals folder without touching the device's own library.
        StudioFolders.appRootOverride = tmp.appendingPathComponent("studio", isDirectory: true)
        storeURL = tmp.appendingPathComponent("studio.json")
    }

    override func tearDown() {
        StudioFolders.appRootOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// A real, readable mixdown of `seconds` IN THE SHIPPING FORMAT: an AAC `.m4a` written with
    /// `StudioRender.aacSettings` — the exact dictionary `renderTakePolyphonic` writes with.
    ///
    /// This used to be a `.wav`, and that made every engine-level assertion below a fixture-only
    /// result: `AVAudioFile` decodes by EXTENSION (the recorded lesson), and WAV is the one format
    /// whose framing is exact — no encoder priming, no packet granularity, no short reads. Pinning
    /// the loop/seek/position rules against it could not see the framing the real artifact has.
    /// The fixture is a quiet tone rather than digital silence so a decoder can never optimize the
    /// content away.
    private func writeMixdown(seconds: Double) throws -> URL {
        let url = tmp.appendingPathComponent("backing-\(UUID().uuidString).m4a")
        let fmt = InstrumentEngine.canonicalFormat
        let file = try AVAudioFile(forWriting: url, settings: StudioRender.aacSettings)
        let frames = AVAudioFrameCount(seconds * fmt.sampleRate)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        if let ch = buf.floatChannelData {
            for c in 0..<Int(fmt.channelCount) {
                for i in 0..<Int(frames) {
                    ch[c][i] = 0.2 * sinf(2 * .pi * 440 * Float(i) / Float(fmt.sampleRate))
                }
            }
        }
        try file.write(from: buf)
        return url
    }

    /// How many frames the mixdown REALLY yields for a window — read independently of the engine,
    /// so the loop-region assertions cross-check the engine against the file rather than against
    /// the engine's own arithmetic.
    private func framesActuallyReadable(_ url: URL, startFrame: AVAudioFramePosition,
                                        frameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        let file = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: frameCount))
        file.framePosition = startFrame
        try file.read(into: buf, frameCount: frameCount)
        return buf.frameLength
    }

    /// A saved multi-staff instrumental whose mixdown is REALLY on disk in the instrumentals
    /// folder — the end-to-end fixture (`StudioTakePlayback.start` resolves through the store).
    private func makeRenderedTwoStaffTake(store: StudioStore, seconds: Double = 3) throws -> StudioTake {
        let id = "tk_e2e"
        let mixdown = try writeMixdown(seconds: seconds)
        let rendered = "take-\(id)-r0.m4a"
        let dest = try StudioFolders.appRoot(.takes).appendingPathComponent(rendered)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: mixdown, to: dest)
        var take = StudioTake(id: id, name: "E2E", instrument: .piano,
                              fileName: StudioFolders.fileName(.takes, id: id), bpm: 120,
                              events: [StudioNoteEvent(onMs: 0, offMs: 900, note: 60, velocity: 96)],
                              durationMs: Int(seconds * 1000), createdAt: 1_000)
        take.extraStaffs = [StudioTakeStaff(id: "stf_1", instrument: .trumpet,
                                            events: [StudioNoteEvent(onMs: 200, offMs: 1_100,
                                                                     note: 67, velocity: 90)])]
        take.renderedFileName = rendered
        take.renderedWasUserFolder = false
        take.renderedRevision = take.renderRevision
        store.addTake(take)
        return try XCTUnwrap(store.take(id))
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
        // The REAL-TIME fallback paths report in the SAME vocabulary. Without these the fallback
        // is `Void`-returning, which is how a ▶ reports success while making no sound at all.
        for c in [InstrumentEngine.BackingStart.noStaffs, .nothingToPlay,
                  .samplersUnavailable, .samplerNotReady] {
            XCTAssertTrue(InstrumentEngine.BackingStart.allCases.contains(c))
            XCTAssertFalse(c.isAudible, "\(c.rawValue) is a refusal, not a play")
        }
        // A cursor PARK is not a failure — seeking past the last note plays nothing on purpose,
        // and alerting about it would be a regression against the shipped single-staff behaviour.
        XCTAssertTrue(InstrumentEngine.BackingStart.seekPastEnd.isCursorPark)
        XCTAssertTrue(InstrumentEngine.BackingStart.nothingToPlay.isCursorPark)
        XCTAssertFalse(InstrumentEngine.BackingStart.samplersUnavailable.isCursorPark)
        XCTAssertFalse(InstrumentEngine.BackingStart.fileUnreadable.isCursorPark)
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
        let url = try writeMixdown(seconds: 1)
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
        let url = try writeMixdown(seconds: 3)
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
        let url = try writeMixdown(seconds: 4)
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

    // MARK: The loop's length is what was READ, not what was asked for

    /// `AVAudioFile.read(into:frameCount:)` returns UP TO `frameCount`. The looping node then
    /// plays what is IN the buffer — so the cursor (and the overdub capture, which wraps on the
    /// same numbers) must be built from the frames actually read. Deriving the region from the
    /// REQUEST puts audio and cursor further apart on every iteration, forever.
    func testLoopRegionFollowsTheFramesActuallyRead() throws {
        let sr = 44_100.0
        let full = try XCTUnwrap(InstrumentEngine.loopRegion(startMs: 1_000,
                                                             framesRead: AVAudioFrameCount(sr * 2),
                                                             sampleRate: sr))
        XCTAssertEqual(full.startMs, 1_000)
        XCTAssertEqual(full.endMs, 3_000)
        // The same window, SHORT by 200 ms of frames — the region must shorten with it.
        let short = try XCTUnwrap(InstrumentEngine.loopRegion(startMs: 1_000,
                                                              framesRead: AVAudioFrameCount(sr * 1.8),
                                                              sampleRate: sr))
        XCTAssertEqual(short.endMs, 2_800,
                       "a short read shortens the loop — the audio does, so the cursor must")
        XCTAssertNotEqual(short.endMs, full.endMs)
        XCTAssertNil(InstrumentEngine.loopRegion(startMs: 0, framesRead: 0, sampleRate: sr))
        XCTAssertNil(InstrumentEngine.loopRegion(startMs: 0, framesRead: 100, sampleRate: 0))
    }

    /// End-to-end on the SHIPPING artifact: the region the engine publishes must equal what the
    /// file itself yields for that window, read independently here. This is the cross-check the
    /// pure test above cannot make — it catches the engine trusting its own arithmetic over the
    /// decoder, on the real AAC framing.
    func testTheLoopRegionMatchesWhatTheMixdownItselfYields() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let url = try writeMixdown(seconds: 3)
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        // A region running to (and past) the mixdown's own end — where short reads live.
        let asked = (startMs: 1_000, endMs: 6_000)
        let win = try XCTUnwrap(InstrumentEngine.backingWindow(fromMs: asked.startMs, loop: asked,
                                                               fileFrames: file.length,
                                                               sampleRate: sr))
        let real = try framesActuallyReadable(url, startFrame: win.startFrame,
                                              frameCount: win.frameCount)
        let expected = try XCTUnwrap(InstrumentEngine.loopRegion(startMs: asked.startMs,
                                                                 framesRead: real, sampleRate: sr))
        let out = engine.replayRenderedAudio(url: url, fromMs: asked.startMs, forTake: "tk_region",
                                             loopRegion: asked)
        XCTAssertTrue(out.isAudible, out.rawValue)
        let got = try XCTUnwrap(engine.backingLoopRegionForTesting)
        XCTAssertEqual(got.startMs, expected.startMs)
        XCTAssertEqual(got.endMs, expected.endMs,
                       "the published loop must be the frames the FILE gave, not the frames asked for")
        XCTAssertLessThan(got.endMs, asked.endMs, "a region past the mixdown's end clamps")
        engine.stopReplay()
    }

    /// The audio's loop period and the CAPTURE's loop period must be ONE number. A region the
    /// render can only partly satisfy shortens the audio; an overdub still wrapping at the ASKED
    /// end lands every note further out of time, pass after pass.
    func testAClampedLoopShortensTheOverdubCaptureRegionToo() throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let url = try writeMixdown(seconds: 2)
        XCTAssertTrue(engine.startOverdub(fromMs: 500, scoreEndMs: 9_000, loop: true))
        XCTAssertEqual(engine.overdubRegionEndMsForTesting, 9_000)
        let out = engine.replayRenderedAudio(url: url, fromMs: 500, forTake: "tk_clamp",
                                             loopRegion: (startMs: 500, endMs: 9_000))
        XCTAssertTrue(out.isAudible, out.rawValue)
        let region = try XCTUnwrap(engine.backingLoopRegionForTesting)
        XCTAssertLessThan(region.endMs, 9_000, "the mixdown is only 2 s — the loop clamps")
        XCTAssertEqual(engine.overdubRegionEndMsForTesting, region.endMs,
                       "the capture wraps on the AUDIO's period, not the one that was asked for")
        engine.stopReplay()
        _ = engine.stopOverdub()
    }

    // MARK: The sampler pool is built with the GRAPH, never on a live engine

    /// The un-exonerated suspect in the original silence was an AU attached and connected to a
    /// RUNNING engine at play time. The rendered-audio backing is attached eagerly for exactly
    /// that reason — and so is the real-time fallback's pool, which is otherwise the only backing
    /// an unsaved live score has.
    func testTheSamplerPoolIsAttachedWithTheGraphNotAtPlayTime() throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        XCTAssertEqual(engine.backingSamplerCountForTesting, 0, "nothing exists before the build")
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        XCTAssertEqual(engine.backingSamplerCountForTesting, StudioTake.maxStaffs,
                       "every staff slot is attached + connected BEFORE the engine ever plays")
        engine.prepare()
        XCTAssertEqual(engine.backingSamplerCountForTesting, StudioTake.maxStaffs,
                       "idempotent — a second build never grows the graph")
    }

    // MARK: The real-time fallback REPORTS (the ▶ may not claim success it cannot know)

    /// The fallback's refusals, by name. Each of these used to be a bare `return` behind a
    /// `Void` signature, so `startLiveSamplers` reported `.playing` — a ▶ that did nothing,
    /// alerted nothing, and left no reason in the capture. That is the reported bug's signature.
    func testTheLiveStaffFallbackNamesItsRefusals() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let bank = tmp.appendingPathComponent("not-a-real-soundfont.sf2")

        let empty = await engine.replayStaffsLive(staffs: [], bankURL: bank, forTake: "tk_a")
        XCTAssertEqual(empty, .noStaffs)
        XCTAssertFalse(empty.isAudible)

        // The staff list COLLAPSED to one (a 2-staff take whose second staff was emptied): this
        // delegates to the single-staff replay, whose two guards are the bare returns the review
        // found. With no bank ever loaded the sampler cannot sound, and that must be SAID.
        let one = await engine.replayStaffsLive(
            staffs: [([StudioNoteEvent(onMs: 0, offMs: 400, note: 60, velocity: 90)], .piano)],
            bankURL: bank, forTake: "tk_b")
        XCTAssertEqual(one, .samplerNotReady,
                       "a delegated single-staff replay that cannot sound is reported, not swallowed")
        XCTAssertFalse(one.isAudible)
        XCTAssertFalse(engine.isReplaying)

        // Two staffs, seeked past every note: a legitimate cursor PARK, named as such.
        let past = await engine.replayStaffsLive(
            staffs: [([StudioNoteEvent(onMs: 0, offMs: 400, note: 60, velocity: 90)], .piano),
                     ([StudioNoteEvent(onMs: 100, offMs: 500, note: 64, velocity: 90)], .trumpet)],
            bankURL: bank, fromMs: 30_000, forTake: "tk_c")
        XCTAssertEqual(past, .nothingToPlay)
        XCTAssertTrue(past.isCursorPark, "a park is not an error the user should be alerted about")
        XCTAssertEqual(engine.replayPositionMs(forTake: "tk_c"), 30_000)
    }

    /// A backing that never started leaves the overdub capture anchored at the BUTTON PRESS —
    /// which an on-demand render can leave seconds in the past. Re-anchoring is what stops a
    /// confined pass finalizing itself before the user plays a note.
    func testARefusedBackingReanchorsTheEmptyOverdubCapture() {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        XCTAssertFalse(engine.reanchorOverdubIfEmpty(), "nothing to re-anchor with no pass armed")
        XCTAssertTrue(engine.startOverdub(fromMs: 0, scoreEndMs: 5_000))
        XCTAssertTrue(engine.reanchorOverdubIfEmpty(),
                      "an EMPTY capture re-anchors to the instant the backing was known to fail")
        XCTAssertEqual(engine.overdubCapturedCount, 0)
        _ = engine.stopOverdub()
        XCTAssertFalse(engine.reanchorOverdubIfEmpty())
    }

    // MARK: END TO END — a saved 2-staff instrumental actually reaches audible output

    /// The claim that shipped FALSE last time, and that no test made: press ▶ on a saved
    /// multi-staff instrumental and audio really starts. Everything real — a `StudioStore`, a
    /// mixdown on disk in the instrumentals folder, the routing, the resolve, the engine.
    func testASavedTwoStaffTakeReachesTheBackingAndPlays() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        engine.prepare()
        try XCTSkipUnless(engine.isReady, "no audio device — the graph never built")
        let store = StudioStore(fileURL: storeURL)
        let packs = InstrumentPackStore(indexURL: URL(string: "https://invalid.test/index.json")!,
                                        cacheDir: tmp)
        let take = try makeRenderedTwoStaffTake(store: store)
        XCTAssertEqual(take.staffCount, 2)
        XCTAssertTrue(take.isRenderFresh)

        let outcome = await StudioTakePlayback.start(take: take, instruments: engine,
                                                    studio: store, packs: packs)
        XCTAssertEqual(outcome, .playing, "a 2-staff instrumental must actually play")
        XCTAssertNil(outcome.message)
        XCTAssertTrue(engine.isReplaying, "the transport is armed and the clock is running")
        XCTAssertTrue(engine.replayClockBelongs(to: take.id))
        XCTAssertEqual(engine.replayPositionMs(forTake: take.id) ?? -1, 0, accuracy: 250)
        engine.stopReplay()
        XCTAssertFalse(engine.isReplaying)

        // …and from a seek, on the same real artifact.
        let seeked = await StudioTakePlayback.start(take: take, fromMs: 1_000, instruments: engine,
                                                    studio: store, packs: packs)
        XCTAssertEqual(seeked, .playing)
        XCTAssertEqual(engine.replayPositionMs(forTake: take.id) ?? -1, 1_000, accuracy: 250)
        engine.stopReplay()
    }

    /// The same take with its mixdown DELETED off disk. It must degrade to the real-time fallback
    /// and — with no sound bank downloaded — report that, rather than returning `.playing` for a
    /// ▶ that makes no sound.
    func testATwoStaffTakeWhoseMixdownVanishedReportsInsteadOfClaimingToPlay() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        let store = StudioStore(fileURL: storeURL)
        let packs = InstrumentPackStore(indexURL: URL(string: "https://invalid.test/index.json")!,
                                        cacheDir: tmp)
        let take = try makeRenderedTwoStaffTake(store: store)
        let gone = try StudioFolders.appRoot(.takes)
            .appendingPathComponent(try XCTUnwrap(take.renderedFileName))
        try FileManager.default.removeItem(at: gone)

        let outcome = await StudioTakePlayback.start(take: take, instruments: engine,
                                                    studio: store, packs: packs)
        XCTAssertNotEqual(outcome, .playing, "silence must never be reported as playing")
        XCTAssertNotNil(outcome.message, "the ▶ shows the user WHY nothing happened")
        XCTAssertFalse(engine.isReplaying)
    }

    /// The fallback must play the STORE's instrumental, not the value snapshot the view is
    /// holding. Both paths around it re-read by id so an edit that landed since a screen last
    /// rendered cannot be played back as though it never happened; this one used the snapshot,
    /// which at the speaker is indistinguishable from "my overdub isn't there".
    func testTheFallbackPlaysTheSTOREsTakeNotTheCallersSnapshot() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        let store = StudioStore(fileURL: storeURL)
        let packs = InstrumentPackStore(indexURL: URL(string: "https://invalid.test/index.json")!,
                                        cacheDir: tmp)
        let snapshot = try makeRenderedTwoStaffTake(store: store)
        XCTAssertFalse(snapshot.allScoreEvents.isEmpty)

        // The score is emptied AFTER the view captured `snapshot` — every staff, both the primary
        // and the overdub. The mixdown is invalidated by the same edits, so ▶ takes the fallback.
        store.setTakeEvents(snapshot.id, events: [])
        store.setStaffEvents(snapshot.id, staffId: try XCTUnwrap(snapshot.extraStaffs?.first?.id),
                             events: [])
        XCTAssertTrue(try XCTUnwrap(store.take(snapshot.id)).allScoreEvents.isEmpty)

        let outcome = await StudioTakePlayback.start(take: snapshot, instruments: engine,
                                                    studio: store, packs: packs)
        XCTAssertEqual(outcome, .nothingToPlay,
                       "the STORE says there is nothing to play; the stale snapshot said otherwise")
        XCTAssertFalse(engine.isReplaying)
    }

    /// A multi-staff instrumental with nothing on any staff: nothing to play, said so, and never
    /// dressed up as either success or failure.
    func testAnEmptyTwoStaffTakeReportsNothingToPlay() async throws {
        let engine = InstrumentEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        let store = StudioStore(fileURL: storeURL)
        let packs = InstrumentPackStore(indexURL: URL(string: "https://invalid.test/index.json")!,
                                        cacheDir: tmp)
        var take = StudioTake(id: "tk_empty", name: "Empty", instrument: .piano,
                              fileName: StudioFolders.fileName(.takes, id: "tk_empty"))
        take.extraStaffs = [StudioTakeStaff(id: "stf_e", instrument: .trumpet, events: [])]
        store.addTake(take)
        let outcome = await StudioTakePlayback.start(take: take, instruments: engine,
                                                    studio: store, packs: packs)
        XCTAssertEqual(outcome, .nothingToPlay)
        XCTAssertNil(outcome.message, "an empty score is not an error to alert about")
        XCTAssertFalse(engine.isReplaying)
    }
}
