import XCTest
import AVFoundation
@testable import PocketDJ

/// StudioRender's offline bounces (spec §4) — REAL renders on synthesized sine sources.
/// Manual rendering mode needs no audio device, so every test here runs headless on CI
/// (nothing constructs a live realtime engine; there is nothing to skip). What's pinned:
///   • loops render EXACTLY the beat-window frame count (incl. rate ≠ 1) — the seam contract;
///   • samples render ⌈window/rate⌉ + a tail drain that STOPS (dry ⇒ almost immediately,
///     wet ⇒ after the reverb decays, never running to the 3 s cap on silence);
///   • the AU priming-latency head is trimmed (first 512-frame window of the written file is
///     full-level signal, not warm-up silence);
///   • carve is frame-exact; decode canonicalizes; a throwing render leaves NO partial file.
final class StudioRenderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-render-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    /// A sine LPCM CAF source (amplitude 0.5 — loud enough that RMS assertions are unambiguous).
    private func makeSineCAF(name: String, seconds: Double, sampleRate: Double = 44_100,
                             channels: UInt32 = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<Int(channels) {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) {
                p[i] = sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buf)
        return url
    }

    private func makeSineBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<2 {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 2 * .pi * 440 / 44_100) * 0.5 }
        }
        return buf
    }

    /// RMS of the FIRST `frames` of a written file — the head-trim assertion's probe.
    private func firstWindowRMS(_ url: URL, frames: AVAudioFrameCount = 512) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames)!
        try f.read(into: buf, frameCount: frames)
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for c in 0..<Int(f.processingFormat.channelCount) {
            let p = buf.floatChannelData![c]
            for i in 0..<n { sum += Double(p[i]) * Double(p[i]) }
        }
        return (sum / Double(n * Int(f.processingFormat.channelCount))).squareRoot()
    }

    private func neutralSample(id: String = "smp_t", edit: StudioSampleEdit = .neutral) -> StudioSample {
        StudioSample(id: id, name: "t", fileName: "sample-\(id).m4a", durationMs: 1000, edit: edit)
    }

    // MARK: Sample renders

    func testRenderSampleNeutralLengthAndTailStops() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let dest = dir.appendingPathComponent("neutral.m4a")
        let r = try await StudioRender.shared.renderSample(neutralSample(), sourceURL: src, to: dest)
        // Nominal = the full 1 s window (44100). The tail drain must add SOMETHING (the drain
        // writes at least the below-floor window it stopped on) but stop far short of the 3 s
        // cap — a dry source goes silent immediately after the schedule ends.
        XCTAssertGreaterThanOrEqual(r.frames, 44_100)
        XCTAssertLessThan(r.frames, 44_100 + 44_100, "dry tail drain must stop early, not run toward the cap")
        XCTAssertEqual(r.durationMs, Int((Double(r.frames) / 44_100 * 1000).rounded()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRenderSampleTrimsPrimingLatencyHead() async throws {
        // The reviewed defect: timePitch's priming latency puts silence at frame 0 unless the
        // head is trimmed — then every baked loop starts late and beat-sync dies. A trimmed
        // render of a 0.5-amplitude sine must be full-level within the FIRST 512 frames.
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let dest = dir.appendingPathComponent("head.m4a")
        _ = try await StudioRender.shared.renderSample(neutralSample(), sourceURL: src, to: dest)
        let rms = try firstWindowRMS(dest)
        XCTAssertGreaterThan(rms, 0.05, "first 512-frame window is warm-up silence — head not trimmed (rms \(rms))")
    }

    func testRenderSampleBakesRate() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let slow = try await StudioRender.shared.renderSample(neutralSample(id: "smp_r1"),
                                                              sourceURL: src,
                                                              to: dir.appendingPathComponent("r1.m4a"))
        let fast = try await StudioRender.shared.renderSample(
            neutralSample(id: "smp_r2", edit: StudioSampleEdit(rate: 2.0)),
            sourceURL: src, to: dir.appendingPathComponent("r2.m4a"))
        // rate 2 halves the musical length: nominal 22050 vs 44100. Tail lengths vary slightly
        // with the AU, so pin the ordering + the halved nominal floor rather than exact counts.
        XCTAssertGreaterThanOrEqual(fast.frames, 22_050)
        XCTAssertLessThan(fast.frames, slow.frames, "rate=2 render must be shorter than rate=1")
    }

    func testRenderSampleBakesTrimWindow() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let r = try await StudioRender.shared.renderSample(
            neutralSample(edit: StudioSampleEdit(trimStartMs: 0, trimEndMs: 250)),
            sourceURL: src, to: dir.appendingPathComponent("trim.m4a"))
        // Window = 250 ms ⇒ nominal 11025; anything ≥ the full second means trim wasn't baked.
        XCTAssertGreaterThanOrEqual(r.frames, 11_025)
        XCTAssertLessThan(r.frames, 22_050)
    }

    func testRenderSampleDrainsReverbTail() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let r = try await StudioRender.shared.renderSample(
            neutralSample(edit: StudioSampleEdit(reverbWet: 1.0)),
            sourceURL: src, to: dir.appendingPathComponent("wet.m4a"))
        // Full-wet reverb rings well past the source: the drain must capture a real tail
        // (> nominal + a couple of windows) AND respect the 3 s cap.
        XCTAssertGreaterThan(r.frames, 44_100 + 2_048, "reverb tail was truncated")
        XCTAssertLessThanOrEqual(r.frames, 44_100 + Int64(3.2 * 44_100))
    }

    func testRenderSampleRejectsZeroFrameWindow() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        do {
            _ = try await StudioRender.shared.renderSample(
                neutralSample(edit: StudioSampleEdit(trimStartMs: 5_000, trimEndMs: 6_000)),   // past EOF
                sourceURL: src, to: dir.appendingPathComponent("zero.m4a"))
            XCTFail("zero-frame window must throw")
        } catch let e as StudioRenderError {
            guard case .emptyWindow = e else { return XCTFail("expected .emptyWindow, got \(e)") }
        }
    }

    // MARK: Loop renders — EXACT frames (the seam contract)

    func testRenderLoopExactFramesAtRateOne() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let dest = dir.appendingPathComponent("loop1.caf")
        // Constant grid @120 BPM, 1 beat = 500 ms ⇒ EXACTLY 22050 canonical frames.
        let r = try await StudioRender.shared.renderLoop(
            sample: neutralSample(), sourceURL: src, anchorMs: 0, beats: .one,
            grid: StudioGrid(bpm: 120), to: dest)
        XCTAssertEqual(r.frames, 22_050)
        XCTAssertEqual(r.lengthMs, 500)
        XCTAssertEqual(r.bpm, 120, accuracy: 0.5)
        // The CAF on disk must hold the same exact count — this is WHY loops are LPCM CAF
        // (AAC priming/padding would make the on-disk length lie, and seams would tick).
        let f = try AVAudioFile(forReading: dest)
        XCTAssertEqual(f.length, 22_050)
        // …and frame 0 is musical frame 0 (head trimmed) even through the loop path.
        XCTAssertGreaterThan(try firstWindowRMS(dest), 0.05)
    }

    func testRenderLoopExactFramesAtRateTwo() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        // Baked rate 2: the 500 ms window plays in 250 ms ⇒ EXACTLY 11025 frames, and the
        // loop's standalone tempo doubles (the sequencer trusts this bpm).
        let r = try await StudioRender.shared.renderLoop(
            sample: neutralSample(edit: StudioSampleEdit(rate: 2.0)), sourceURL: src,
            anchorMs: 0, beats: .one, grid: StudioGrid(bpm: 120),
            to: dir.appendingPathComponent("loop2.caf"))
        XCTAssertEqual(r.frames, 11_025)
        XCTAssertEqual(r.bpm, 240, accuracy: 1.5)
    }

    func testRenderLoopPadsWhenSourceRunsOut() async throws {
        // 2 beats @120 from a 0.6 s source: the window (1 s) outlives the audio — the render
        // must still be EXACTLY the window's frame count (zero-padded), never short.
        let src = try makeSineCAF(name: "short.caf", seconds: 0.6)
        let r = try await StudioRender.shared.renderLoop(
            sample: neutralSample(), sourceURL: src, anchorMs: 0, beats: .two,
            grid: StudioGrid(bpm: 120), to: dir.appendingPathComponent("loopPad.caf"))
        XCTAssertEqual(r.frames, 44_100)
        XCTAssertEqual(r.lengthMs, 1_000)
    }

    func testRenderLoopWithoutGridThrows() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        do {
            _ = try await StudioRender.shared.renderLoop(
                sample: neutralSample(), sourceURL: src, anchorMs: 0, beats: .one,
                grid: StudioGrid(bpm: 0), to: dir.appendingPathComponent("loopX.caf"))
            XCTFail("no usable grid must throw")
        } catch let e as StudioRenderError {
            guard case .noGrid = e else { return XCTFail("expected .noGrid, got \(e)") }
        }
    }

    // MARK: Instrumental (take) renders
    //
    // The event-driven sampler render is exercised end-to-end (real audio, non-silent waveform)
    // in the simulator — the SoundFont bank it loads is a 32 MB download, not bundled for unit
    // tests. Here we cover the two guards that need no bank: no-notes and an unloadable bank.

    func testRenderTakeRejectsEmptyEvents() async throws {
        do {
            _ = try await StudioRender.shared.renderTake(events: [], bankURL: dir, program: 0,
                                                         to: dir.appendingPathComponent("empty.m4a"))
            XCTFail("no note events must throw")
        } catch let e as StudioRenderError {
            guard case .emptyTake = e else { return XCTFail("expected .emptyTake, got \(e)") }
        }
    }

    func testRenderTakeWithUnloadableBankThrows() async throws {
        // A non-SoundFont file: the offline sampler starts, but loadSoundBankInstrument rejects it
        // → `.bankLoadFailed` (the "download the pack first" prompt), never a crash or silent file.
        let bogus = dir.appendingPathComponent("not-a-bank.sf2")
        try Data("nope".utf8).write(to: bogus)
        do {
            _ = try await StudioRender.shared.renderTake(
                events: [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 100)],
                bankURL: bogus, program: 0, to: dir.appendingPathComponent("bad.m4a"))
            XCTFail("an unloadable bank must throw")
        } catch let e as StudioRenderError {
            guard case .bankLoadFailed = e else { return XCTFail("expected .bankLoadFailed, got \(e)") }
        }
    }

    // MARK: Pattern bounces

    func testBouncePatternRefusesZeroSoundingSteps() async throws {
        // Zero-frame schedules crash (spec §2) — the render refuses at the door.
        let p = StudioPattern(id: "ptn_t0", name: "empty", rows: [StudioPatternRow(targetId: "smp_x")])
        do {
            _ = try await StudioRender.shared.bouncePattern(p, buffers: [:],
                                                            to: dir.appendingPathComponent("b0.m4a"))
            XCTFail("empty pattern must throw")
        } catch let e as StudioRenderError {
            guard case .emptyPattern = e else { return XCTFail("expected .emptyPattern, got \(e)") }
        }
    }

    func testBouncePatternRefusesWhenEverySoundingRowIsMissing() async throws {
        // Per-row missing targets are SKIPPED (spec §2) — but when NOTHING remains the bounce
        // would be a bar of pure silence, so it refuses like the zero-steps case.
        var row = StudioPatternRow(targetId: "smp_gone")
        row.steps[0] = true
        let p = StudioPattern(id: "ptn_t1", name: "missing", rows: [row])
        do {
            _ = try await StudioRender.shared.bouncePattern(p, buffers: [:],
                                                            to: dir.appendingPathComponent("b1.m4a"))
            XCTFail("all-missing pattern must throw")
        } catch let e as StudioRenderError {
            guard case .emptyPattern = e else { return XCTFail("expected .emptyPattern, got \(e)") }
        }
    }

    func testBouncePatternRendersOneBarPlusBoundedTail() async throws {
        var row = StudioPatternRow(targetId: "smp_hit")
        row.steps[0] = true; row.steps[4] = true; row.steps[8] = true; row.steps[12] = true
        let p = StudioPattern(id: "ptn_t2", name: "four", bpm: 120, rows: [row])
        let dest = dir.appendingPathComponent("bounce.m4a")
        let r = try await StudioRender.shared.bouncePattern(p, buffers: ["smp_hit": makeSineBuffer(frames: 4_410)],
                                                            to: dest)
        // One bar @120 = 16 × stepFrames(120) = 88208; the last hit (step 12) ends inside the
        // bar, so the drain stops quickly after it.
        let bar = StudioEngine.stepFrames(bpm: 120, sampleRate: 44_100) * 16
        XCTAssertGreaterThanOrEqual(r.frames, bar)
        XCTAssertLessThan(r.frames, bar + 44_100, "dry bounce tail must stop early")
        XCTAssertEqual(r.lengthMs, Int((Double(r.frames) / 44_100 * 1000).rounded()))
        // Step 0 lands at frame 0 of the file — the schedule anchor is the file's origin.
        XCTAssertGreaterThan(try firstWindowRMS(dest), 0.05)
    }

    // MARK: Decode + carve

    func testDecodeBufferCanonicalizesHeterogeneousInput() async throws {
        // A 48 kHz MONO source (the mic-capture shape): decode must return canonical 44.1/2ch
        // with the EXACT resampled length — a short/shifted decode would desync every pattern
        // row buffer built from it. 0.5 s × 44100 = 22050.
        let src = try makeSineCAF(name: "src48.caf", seconds: 0.5, sampleRate: 48_000, channels: 1)
        let buf = try await StudioRender.shared.decodeBuffer(url: src)
        XCTAssertTrue(StudioAudio.isCanonical(buf.format))
        XCTAssertEqual(Int64(buf.frameLength), 22_050)
    }

    func testDecodeBufferPassthroughForCanonicalInput() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 0.25)
        let buf = try await StudioRender.shared.decodeBuffer(url: src)
        XCTAssertTrue(StudioAudio.isCanonical(buf.format))
        XCTAssertEqual(Int64(buf.frameLength), 11_025)
    }

    func testCarveTrackRegionIsFrameExact() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        let dest = dir.appendingPathComponent("carve.m4a")
        let r = try await StudioRender.shared.carveTrackRegion(sourceURL: src, startMs: 250,
                                                               endMs: 750, to: dest)
        XCTAssertEqual(r.frames, 22_050)          // 500 ms at 44.1 kHz, no FX graph — exact
        XCTAssertEqual(r.durationMs, 500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testCarveTrackRegionRejectsBadWindows() async throws {
        let src = try makeSineCAF(name: "src.caf", seconds: 1.0)
        for (s, e) in [(500, 500), (700, 300), (-10, 100), (2_000, 3_000)] {
            do {
                _ = try await StudioRender.shared.carveTrackRegion(sourceURL: src, startMs: s,
                                                                   endMs: e,
                                                                   to: dir.appendingPathComponent("bad.m4a"))
                XCTFail("window (\(s),\(e)) must throw")
            } catch let err as StudioRenderError {
                guard case .emptyWindow = err else { return XCTFail("expected .emptyWindow, got \(err)") }
            }
        }
    }

    // MARK: Stem-mix carve (sum of selected stems)

    func testCarveStemMixSumsSelectedStems() async throws {
        // Two identical in-phase 0.5-amplitude sines: one stem ⇒ ~0.354 RMS, both summed ⇒ ~2×.
        let a = try makeSineCAF(name: "stemA.caf", seconds: 1.0)
        let b = try makeSineCAF(name: "stemB.caf", seconds: 1.0)
        let one = dir.appendingPathComponent("one.m4a")
        let both = dir.appendingPathComponent("both.m4a")
        let rOne = try await StudioRender.shared.carveStemMix(stemURLs: [a], startMs: 0, endMs: 500, to: one)
        let rBoth = try await StudioRender.shared.carveStemMix(stemURLs: [a, b], startMs: 0, endMs: 500, to: both)
        XCTAssertEqual(rOne.frames, 22_050)          // the window is authoritative, frame-exact
        XCTAssertEqual(rBoth.durationMs, 500)
        let rmsOne = try fullRMS(one)
        let rmsBoth = try fullRMS(both)
        XCTAssertGreaterThan(rmsOne, 0.15, "a single stem must be audible")
        XCTAssertEqual(rmsBoth / rmsOne, 2.0, accuracy: 0.35, "summing two in-phase stems ≈ doubles level")
    }

    func testCarveStemMixRejectsBadInput() async throws {
        let a = try makeSineCAF(name: "stemA.caf", seconds: 1.0)
        // No stems, and zero/reversed windows, all refuse — never a zero-frame schedule.
        let cases: [(urls: [URL], s: Int, e: Int)] = [([], 0, 500), ([a], 500, 500), ([a], 700, 300)]
        for c in cases {
            do {
                _ = try await StudioRender.shared.carveStemMix(stemURLs: c.urls, startMs: c.s, endMs: c.e,
                                                               to: dir.appendingPathComponent("bad.m4a"))
                XCTFail("stem mix (\(c.urls.count) urls, \(c.s)-\(c.e)) must throw")
            } catch let err as StudioRenderError {
                guard case .emptyWindow = err else { return XCTFail("expected .emptyWindow, got \(err)") }
            }
        }
    }

    private func fullRMS(_ url: URL) throws -> Double {
        let buf = try StudioRender.decodeFileSync(url: url)
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for c in 0..<ch {
            let p = buf.floatChannelData![c]
            for i in 0..<n { sum += Double(p[i]) * Double(p[i]) }
        }
        return (sum / Double(n * ch)).squareRoot()
    }

    // MARK: Failure latch — a throwing render never leaves a partial file

    func testThrowingRenderLeavesNoPartialFile() async throws {
        let dest = dir.appendingPathComponent("never.m4a")
        _ = try? await StudioRender.shared.renderSample(neutralSample(),
                                                        sourceURL: dir.appendingPathComponent("missing.caf"),
                                                        to: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        // …and no temp sibling survives either (the atomic-write discipline).
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix(".studio-render-") } ?? []
        XCTAssertEqual(leftovers, [])
    }
}
