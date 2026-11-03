import AVFoundation
import Combine
import Observation
import XCTest
@testable import PocketDJ

/// np-mix-mode PHASE 3 — the Now Playing DSP plays a ripped row from its GROWING buffer file.
///
///  • `GrowingFileSchedule`: the shared (Mix deck + Now Playing) frontier / hold / append /
///    underrun decisions — pure tables, and the Mix deck's names forward to them.
///  • `NowPlayingDSP.engageStreaming` over a real `AVAudioEngine` and the TAGGED noise mp3 written
///    progressively (the sink's way — appended): never scheduled past the written frontier, a
///    start / underrun / seek without runway HOLDS and resumes exactly there, growth is seamless
///    at SAMPLE resolution, stems arriving later hand over onto the growing song, a dead stream
///    keeps what arrived (stems carry; the full song plays to its last frame and hands back),
///    completion swaps to the adopted burn and ends once, the requireRunway probe touches
///    nothing, and a file AVAudioFile can't decode by its EXTENSION is refused.
///  • `SetlistPlayer`: a Mix Mode ripped row STARTS in the DSP on its buffer stream (no presigned
///    download, one card writer that scrubs the DSP), a dead stream falls back to the plain
///    stream, the first touch moves a presigned stream onto the growing file at the same position
///    (paused stays paused, never across an interruption), a long mid-song hold falls back to the
///    stream it left, the start watchdog backstops a start that never gets bytes, the Mix tab
///    tears the engagement down, a durable restore resumes on the growing file at the saved
///    position, and a media-services reset re-enters it.
@MainActor
final class NPMixGrowingFileTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private var noise: Data { get throws { try StemAudioProbe.bundled("stream-noise-12s", in: Self.self) } }
    private var noiseStem: Data { get throws { try StemAudioProbe.bundled("stem-noise-12s", in: Self.self) } }

    private var saved: (rekick: Double, escalate: Double, cap: Double, hold: Double, failDelay: Double) = (8, 20, 25, 20, 2.5)

    override func setUp() {
        super.setUp()
        GrowStub.reset()
        saved = (SetlistPlayer.startStallRekickSeconds, SetlistPlayer.startStallEscalateSeconds,
                 SetlistPlayer.startRunwayCapSeconds, SetlistPlayer.growingHoldFallbackSeconds,
                 PlayerEngine.itemFailedSignalDelay)
        PlayerEngine.itemFailedSignalDelay = 600     // the scripted S3 URL never loads in AVFoundation
        SetlistPlayer.startRunwayCapSeconds = 0.2
    }

    override func tearDown() {
        SetlistPlayer.startStallRekickSeconds = saved.rekick
        SetlistPlayer.startStallEscalateSeconds = saved.escalate
        SetlistPlayer.startRunwayCapSeconds = saved.cap
        SetlistPlayer.growingHoldFallbackSeconds = saved.hold
        PlayerEngine.itemFailedSignalDelay = saved.failDelay
        GrowStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func tempMP3(_ tag: String, ext: String = "mp3") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-grow-\(tag)-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Grow `url` to the first `n` bytes of `data` the way the loader's sink does — APPENDING
    /// (an open reader keeps its handle).
    private func grow(_ url: URL, _ data: Data, to n: Int) throws {
        let have = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let have, have > 0, have <= n else { return try data.prefix(n).write(to: url) }
        guard n > have else { return }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data[data.startIndex + have ..< data.startIndex + n])
    }

    private func bytes(_ data: Data, _ fraction: Double) -> Int { min(data.count, Int(Double(data.count) * fraction)) }

    /// Write `fraction` of the noise song to `file` and report it on `songId`'s stream.
    @discardableResult
    private func feed(_ loader: MixStreamLoader, _ songId: String, _ file: URL, _ data: Data, _ fraction: Double,
                      finished: Bool = false, adoptable: Bool = false) throws -> MixStreamLoader.Stream {
        let n = bytes(data, fraction)
        try grow(file, data, to: n)
        return loader.injectStreamForTesting(songId: songId, file: file, bytes: Int64(n), expected: Int64(data.count),
                                             adoptable: adoptable, finished: finished, origin: .buffer)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private struct DSPRig { let dsp: NowPlayingDSP; let burns: BurnStore; let loader: MixStreamLoader; let rips: RipsStore }

    private func dspRig(_ ids: [String], stems: Bool = false) throws -> DSPRig {
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: .ephemeral))
        rips.setManifest(Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, RipsStore.ManifestEntry(key: "rips/\(id).mp3", source: "digital",
                                         stems: stems ? .init(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                                                              bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3") : nil))
        }))
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let dsp = NowPlayingDSP(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        dsp.streamer = loader
        addTeardownBlock { @MainActor in dsp.disengage() }
        return DSPRig(dsp: dsp, burns: burns, loader: loader, rips: rips)
    }

    // MARK: - 1 · GrowingFileSchedule (pure)

    func testScheduleTablesAndTheMixDeckForwardsToThem() {
        // 12 s whose file is 384 KB ⇒ 32 KB/s; the Mix deck's names are the shared functions.
        XCTAssertEqual(GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000, claim: .frameCount) ?? -1,
                       32_000, accuracy: 1)
        XCTAssertEqual(MixEngine.streamBytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000, claim: .frameCount),
                       GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000, claim: .frameCount))
        XCTAssertEqual(MixEngine.streamResumeRunway, GrowingFileSchedule.resumeRunway)
        XCTAssertEqual(MixEngine.streamStartRunway, GrowingFileSchedule.startRunway)
        // Frontier: 160 000 B at 32 000 B/s = 5 s − the 1.5 s torn-frame margin, capped at the window end.
        let sr = 44_100.0
        XCTAssertEqual(GrowingFileSchedule.frontier(bytes: 160_000, complete: false, bytesPerSecond: 32_000, sampleRate: sr,
                                                    start: 0, fullEnd: 529_200), AVAudioFramePosition(3.5 * sr))
        XCTAssertEqual(GrowingFileSchedule.frontier(bytes: 10_000_000, complete: false, bytesPerSecond: 32_000, sampleRate: sr,
                                                    start: 0, fullEnd: 529_200), 529_200, "never past the window's end")
        XCTAssertEqual(GrowingFileSchedule.frontier(bytes: 1, complete: true, bytesPerSecond: 32_000, sampleRate: sr,
                                                    start: 0, fullEnd: 529_200), 529_200, "complete ⇒ the whole window")
        // Start / resume: runway past the playhead, or the window's end.
        XCTAssertTrue(GrowingFileSchedule.canStart(position: 0, frontier: AVAudioFramePosition(2 * sr), fullEnd: 529_200,
                                                   complete: false, runway: 2, sampleRate: sr))
        XCTAssertFalse(GrowingFileSchedule.canStart(position: 0, frontier: AVAudioFramePosition(1.9 * sr), fullEnd: 529_200,
                                                    complete: false, runway: 2, sampleRate: sr))
        XCTAssertTrue(GrowingFileSchedule.canStart(position: AVAudioFramePosition(11 * sr), frontier: 529_200, fullEnd: 529_200,
                                                   complete: false, runway: 4, sampleRate: sr), "the tail is all there")
        XCTAssertFalse(GrowingFileSchedule.canStart(position: AVAudioFramePosition(5 * sr), frontier: AVAudioFramePosition(5 * sr),
                                                    fullEnd: 529_200, complete: false, runway: 0, sampleRate: sr),
                       "the frontier must be PAST the playhead")
        XCTAssertTrue(GrowingFileSchedule.canStart(position: 529_200, frontier: 0, fullEnd: 529_200, complete: true,
                                                   runway: 4, sampleRate: sr))
        // Append: 1 s chunks while the runway is short, 15 s once comfortable; complete appends at once.
        XCTAssertTrue(GrowingFileSchedule.shouldAppend(scheduledEnd: AVAudioFramePosition(3 * sr), frontier: AVAudioFramePosition(4.1 * sr),
                                                       playFrame: AVAudioFramePosition(2 * sr), sampleRate: sr, complete: false))
        XCTAssertFalse(GrowingFileSchedule.shouldAppend(scheduledEnd: AVAudioFramePosition(3 * sr), frontier: AVAudioFramePosition(3.5 * sr),
                                                        playFrame: AVAudioFramePosition(2 * sr), sampleRate: sr, complete: false))
        XCTAssertFalse(GrowingFileSchedule.shouldAppend(scheduledEnd: AVAudioFramePosition(20 * sr), frontier: AVAudioFramePosition(30 * sr),
                                                        playFrame: AVAudioFramePosition(2 * sr), sampleRate: sr, complete: false))
        XCTAssertTrue(GrowingFileSchedule.shouldAppend(scheduledEnd: AVAudioFramePosition(3 * sr), frontier: AVAudioFramePosition(3.1 * sr),
                                                       playFrame: 0, sampleRate: sr, complete: true))
        // Underrun: at the end of what's scheduled while more of the song is to come — not at its end.
        XCTAssertTrue(GrowingFileSchedule.underrun(position: 4.96, scheduledEnd: 5, duration: 12))
        XCTAssertFalse(GrowingFileSchedule.underrun(position: 4.5, scheduledEnd: 5, duration: 12))
        XCTAssertFalse(GrowingFileSchedule.underrun(position: 11.99, scheduledEnd: 12, duration: 12), "the real end is no underrun")
        // Window: an analog side's song slice; nothing in it ⇒ count ≤ 0.
        let w = GrowingFileSchedule.window(fileLength: 44_100 * 600, sampleRate: sr, startMs: 60_000, windowMs: 180_000)
        XCTAssertEqual(w.start, 60 * 44_100); XCTAssertEqual(w.count, 180 * 44_100)
        XCTAssertLessThanOrEqual(GrowingFileSchedule.window(fileLength: 1_000, sampleRate: sr, startMs: 60_000, windowMs: nil).count, 0)
        // Reach estimate for an eligibility read (no open).
        XCTAssertEqual(GrowingFileSchedule.coveredFileSeconds(bytes: 50, expectedBytes: 100, complete: false, fileDurationSeconds: 12) ?? -1,
                       4.5, accuracy: 1e-9)
        XCTAssertEqual(GrowingFileSchedule.coveredFileSeconds(bytes: 1, expectedBytes: nil, complete: true, fileDurationSeconds: 12), 12)
        XCTAssertNil(GrowingFileSchedule.coveredFileSeconds(bytes: 50, expectedBytes: nil, complete: false, fileDurationSeconds: 12))
        // The decodes-by-EXTENSION trap.
        XCTAssertTrue(GrowingFileSchedule.decodableByExtension(URL(fileURLWithPath: "/x/a.MP3")))
        XCTAssertFalse(GrowingFileSchedule.decodableByExtension(URL(fileURLWithPath: "/x/a.part")))
        XCTAssertFalse(GrowingFileSchedule.decodableByExtension(URL(fileURLWithPath: "/x/a")))
    }

    // MARK: - 2 · NowPlayingDSP on a growing file

    /// The headline: the song starts while it downloads (HELD until the start runway), keeps
    /// growing under the playhead with appends from fresh opens, and is ONE continuous,
    /// sample-aligned read with no dead air — while what's scheduled never passes the written
    /// frontier.
    func testGrowingSongStartsWithRunwayAndGrowsSeamlesslyNeverPastTheFrontier() async throws {
        let data = try noise
        let r = try dspRig(["g1"])
        let file = tempMP3("g1")
        let s = try feed(r.loader, "g1", file, data, 0.05)              // ~0.6 s: under the margin + runway
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        var firstAudio = 0
        r.dsp.onFirstAudio = { firstAudio += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g1", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isEngaged)
        XCTAssertTrue(r.dsp.isStreamingMain)
        XCTAssertTrue(r.dsp.isBuffering, "no runway yet: HELD, not silent-playing")
        XCTAssertTrue(r.dsp.isPlaying, "play intent kept")
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting(), "nothing scheduled past the frontier")
        XCTAssertEqual(r.dsp.currentTime, 0)

        try feed(r.loader, "g1", file, data, 0.4)                        // 4.8 s ⇒ 3.3 s frontier ≥ 2 s
        XCTAssertFalse(r.dsp.isBuffering, "runway arrived — it starts")
        XCTAssertEqual(r.dsp.duration, 12, accuracy: 0.1, "the header's window replaced the catalog guess")
        await waitUntil("rendering") { r.dsp.currentTime > 0.3 }
        XCTAssertEqual(firstAudio, 1, "first audio reported once")
        let cap = r.dsp.captureForTesting()
        cap.start()
        let bps = Double(data.count) / 12
        for step in 5...9 {
            await pause(0.4)
            let scheduled = r.dsp.mainScheduledEndSecondsForTesting()
            let written = Double(bytes(data, Double(step - 1) / 10)) / bps
            XCTAssertLessThanOrEqual(scheduled, written - GrowingFileSchedule.frontierMargin + 0.05,
                                     "scheduled \(scheduled)s past the written frontier \(written)s")
            XCTAssertLessThanOrEqual(scheduled, (r.dsp.mainFrontierSecondsForTesting() ?? 12) + 1e-6)
            try feed(r.loader, "g1", file, data, Double(step) / 10)
        }
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(data), "growing file appends")
        XCTAssertFalse(r.dsp.isBuffering)
        XCTAssertEqual(ends, 0, "a frontier is not the end")
        XCTAssertEqual(firstAudio, 1)
    }

    /// STALL → WAIT: the playhead catching the download HOLDS at the frontier (frozen, play
    /// intent kept, no end, no skip); a resume needs the bigger runway (no hold ⇄ play flapping)
    /// and continues exactly where it stopped.
    func testUnderrunHoldsAtTheFrontierAndResumesThereWithTheResumeRunway() async throws {
        let data = try noise
        let r = try dspRig(["g2"])
        let file = tempMP3("g2")
        let s = try feed(r.loader, "g2", file, data, 0.35)              // 4.2 s ⇒ 2.7 s frontier
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g2", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertFalse(r.dsp.isBuffering)
        await waitUntil("underrun hold", timeout: 6) { r.dsp.isBuffering }
        let held = r.dsp.currentTime
        let frontier = try XCTUnwrap(r.dsp.mainFrontierSecondsForTesting())
        XCTAssertEqual(held, frontier, accuracy: 0.2, "held AT the frontier")
        XCTAssertTrue(r.dsp.isPlaying, "intent kept — Buffering…, not paused")
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting())
        await pause(0.3)
        XCTAssertEqual(r.dsp.currentTime, held, "the playhead is frozen while held")
        XCTAssertEqual(ends, 0, "no fake end at a stall")

        try feed(r.loader, "g2", file, data, 0.55)                       // 6.6 − 1.5 = 5.1 s < held + 4
        XCTAssertTrue(r.dsp.isBuffering, "a resume waits for the RESUME runway")
        try feed(r.loader, "g2", file, data, 0.8)                        // 8.1 s ≥ held + 4
        XCTAssertFalse(r.dsp.isBuffering, "resumed")
        await waitUntil("rendering again") { r.dsp.currentTime > held + 0.3 }
        XCTAssertLessThan(r.dsp.currentTime, held + 1.5, "resumed where it stopped — not from the frontier ahead")
        let cap = r.dsp.captureForTesting()
        cap.start()
        await StemAudioProbe.capture(cap, atLeast: 0.6)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(data), "after the resume")
        XCTAssertEqual(ends, 0)
    }

    /// SEEK PAST THE FRONTIER: the scrub lands where asked and HOLDS there; the bytes arriving
    /// resume the song at the target (not at the frontier, not at 0:00), and the song then ends
    /// exactly once.
    func testSeekPastTheFrontierHoldsAtTheTargetThenResumesThereAndEndsOnce() async throws {
        let data = try noise
        let r = try dspRig(["g3"])
        let file = tempMP3("g3")
        let s = try feed(r.loader, "g3", file, data, 0.4)
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g3", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        await waitUntil("rendering") { r.dsp.currentTime > 0.2 }
        r.dsp.seek(toSongSeconds: 9)
        XCTAssertTrue(r.dsp.isBuffering, "past the frontier: held at the target")
        XCTAssertEqual(r.dsp.currentTime, 9, accuracy: 0.01)
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting(), "nothing scheduled beyond the written bytes")
        try feed(r.loader, "g3", file, data, 1.0)                        // all bytes, not yet complete: 10.5 s < 12
        XCTAssertTrue(r.dsp.isBuffering, "the tail isn't there yet (torn-frame margin)")
        try feed(r.loader, "g3", file, data, 1.0, finished: true)
        XCTAssertFalse(r.dsp.isBuffering)
        XCTAssertFalse(r.dsp.isStreamingMain, "complete ⇒ an ordinary file")
        await waitUntil("rendering at the target") { r.dsp.currentTime > 9.2 }
        XCTAssertLessThan(r.dsp.currentTime, 10.5)
        await waitUntil("the end", timeout: 6) { ends > 0 }
        await pause(0.2)
        XCTAssertEqual(ends, 1, "exactly one end")
        // A seek while PAUSED just moves where ▶ resumes.
    }

    /// STEMS ARRIVING LATER than the song: the growing full song plays on ("Loading stems…")
    /// while the stems stream in, then hands over to them at the playhead — one continuous,
    /// sample-aligned read.
    func testStemsArrivingLaterHandOverOntoTheGrowingSongSeamlessly() async throws {
        let data = try noise, stem = try noiseStem
        let r = try dspRig(["g4"], stems: true)
        let file = tempMP3("g4")
        let s = try feed(r.loader, "g4", file, data, 0.6)
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g4", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        await waitUntil("rendering") { r.dsp.currentTime > 0.3 }
        var parts: [String: URL] = [:]
        func streamStems(_ fraction: Double) throws {
            let n = min(stem.count, Int(Double(stem.count) * fraction))
            var b: [String: Int64] = [:]
            for name in MixEngine.stemNames {
                let url = parts[name] ?? tempMP3("g4-\(name)")
                try grow(url, stem, to: n)
                parts[name] = url
                b[name] = Int64(n)
            }
            r.loader.injectStemsForTesting(songId: "g4", files: parts, bytes: b, expected: Int64(stem.count), finished: n == stem.count)
        }
        try streamStems(0.03)
        let cap = r.dsp.captureForTesting()
        cap.start()
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsLoading, "Loading stems… — the growing song stays on air")
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting())
        try feed(r.loader, "g4", file, data, 0.9)                        // keep the song ahead
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        try streamStems(0.9)
        XCTAssertTrue(r.dsp.stemsOnAir, "runway arrived — the stems take over")
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        await StemAudioProbe.capture(cap, atLeast: 0.6)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(data), "growing song → late stems")
        XCTAssertFalse(r.dsp.isBuffering)
    }

    /// `mainTruncated` semantics: burned stems carry a song whose full-mix stream is still
    /// arriving (even before it attached); the stream DYING then never stops them — and a
    /// "back to the full song" request is dropped (it can't carry the rest), no hand-back.
    func testStemsCarryAndKeepCarryingWhenTheSongStreamDies() async throws {
        let data = try noise, stem = try noiseStem
        let r = try dspRig(["g5"])
        let dir = try XCTUnwrap(r.burns.appBurnsDirOverride)
        for n in MixEngine.stemNames { try stem.write(to: dir.appendingPathComponent("stem-g5-\(n).mp3")) }
        let file = tempMP3("g5")
        let s = try feed(r.loader, "g5", file, data, 0.2)                // 2.4 − 1.5 = 0.9 s: holds
        var handedBack = 0
        r.dsp.onMainStreamFailed = { _ in handedBack += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g5", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering)
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsOnAir, "complete stems carry the held song at once")
        XCTAssertFalse(r.dsp.isBuffering, "…so it is no longer waiting")
        r.loader.failStreamForTesting("g5")
        XCTAssertTrue(r.dsp.mainTruncated)
        XCTAssertTrue(r.dsp.stemsOnAir)
        XCTAssertTrue(r.dsp.setStemMode(false))
        XCTAssertTrue(r.dsp.stemsOnAir, "the cut-short song can't carry the rest — the stems stay")
        await waitUntil("past the song's dead frontier") { r.dsp.currentTime > 1.6 }
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertTrue(r.dsp.stemNodesPlayingForTesting())
        XCTAssertEqual(handedBack, 0, "stems carried it: no hand-back")
    }

    /// A DEAD stream never costs the audio that did arrive: the song plays up to its last frame,
    /// THEN hands the row back (once) at that second — no fake end, no skip.
    func testDeadStreamPlaysWhatArrivedThenHandsBackAtItsLastFrame() async throws {
        let data = try noise
        let r = try dspRig(["g6"])
        let file = tempMP3("g6")
        let s = try feed(r.loader, "g6", file, data, 0.35)              // 2.7 s frontier
        var handedBack: [Double] = []
        var ends = 0
        r.dsp.onMainStreamFailed = { handedBack.append($0) }
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g6", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        await waitUntil("rendering") { r.dsp.currentTime > 0.3 }
        r.loader.failStreamForTesting("g6")
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting(), "what arrived keeps playing")
        XCTAssertTrue(handedBack.isEmpty)
        await waitUntil("handed back at the last frame", timeout: 6) { !handedBack.isEmpty }
        XCTAssertEqual(handedBack.first ?? 0, 2.7, accuracy: 0.3)
        await pause(0.3)
        XCTAssertEqual(handedBack.count, 1)
        XCTAssertEqual(ends, 0, "a dead stream is not the song's end")
        XCTAssertFalse(r.dsp.isBuffering)
    }

    /// Dead BEFORE any audio (a held start): handed back at once, at the start position.
    func testStreamDyingBeforeAudioHandsBackAtOnce() async throws {
        let data = try noise
        let r = try dspRig(["g7"])
        let file = tempMP3("g7")
        let s = try feed(r.loader, "g7", file, data, 0.02)
        var handedBack: [Double] = []
        r.dsp.onMainStreamFailed = { handedBack.append($0) }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 3, songId: "g7", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering)
        r.loader.failStreamForTesting("g7")
        await waitUntil("handed back") { !handedBack.isEmpty }
        XCTAssertEqual(handedBack, [3])
        XCTAssertFalse(r.dsp.isBuffering)
        XCTAssertFalse(r.dsp.isPlaying)
    }

    /// COMPLETION adopts the buffer stream as a TEMPORARY burn; the DSP swaps to the adopted file
    /// (`onMainStreamFinished` names it) and is an ordinary local file — a mid-song (restore-shaped)
    /// start resumes at its offset and the song ends once.
    func testCompletionSwapsToTheAdoptedBurnAndEndsOnce() async throws {
        let data = try noise
        let r = try dspRig(["g8"])
        let file = tempMP3("g8")
        let s = try feed(r.loader, "g8", file, data, 0.5, adoptable: true)
        var finished: URL?
        var ends = 0
        r.dsp.onMainStreamFinished = { finished = $0 }
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 9, songId: "g8", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering, "a resume offset past the frontier holds")
        XCTAssertEqual(r.dsp.currentTime, 9, accuracy: 0.01)
        try feed(r.loader, "g8", file, data, 1.0, finished: true, adoptable: true)
        let url = try XCTUnwrap(finished, "finished with the adopted file")
        XCTAssertTrue(url.path.hasPrefix(try XCTUnwrap(r.burns.appBurnsDirOverride).path), "now the burn: \(url.path)")
        XCTAssertTrue(r.burns.isTemporary("g8"), "a buffer-lane adoption is TEMPORARY")
        XCTAssertFalse(r.dsp.isStreamingMain)
        XCTAssertFalse(r.dsp.isBuffering)
        await waitUntil("rendering at 9 s") { r.dsp.currentTime > 9.2 }
        await waitUntil("the end", timeout: 6) { ends > 0 }
        await pause(0.2)
        XCTAssertEqual(ends, 1)
    }

    /// REVIEW MUST — a HEADERLESS growing mp3 (no Xing/Info full-length claim: a user's own
    /// digital file) opens on its partial bytes with a length ESTIMATED from what is there. That
    /// estimate must never become the song's window: it holds until complete, then plays the
    /// WHOLE song (before: attached at ~3.6 s, so the completed song "ended" a quarter in).
    func testHeaderlessGrowingFileHoldsUntilCompleteThenPlaysTheWholeSong() async throws {
        let data = try noiseStem                                         // headerless (no Xing)
        let r = try dspRig(["g11"])
        let file = tempMP3("g11")
        let s = try feed(r.loader, "g11", file, data, 0.3)
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 0, songId: "g11", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering, "no full-length claim: nothing is schedulable until complete")
        try feed(r.loader, "g11", file, data, 0.6)
        XCTAssertTrue(r.dsp.isBuffering)
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting())
        try feed(r.loader, "g11", file, data, 1.0, finished: true)
        XCTAssertFalse(r.dsp.isBuffering, "complete: it plays")
        XCTAssertEqual(r.dsp.duration, 12, accuracy: 0.2, "the whole song — not the partial open's estimate")
        r.dsp.seek(toSongSeconds: 9)
        await waitUntil("rendering at 9 s") { r.dsp.currentTime > 9.2 }
        XCTAssertEqual(ends, 0)
    }

    /// The hand-off probe (`requireRunway`): a stream that can't play at the position RIGHT NOW
    /// is refused with NOTHING touched (the plain player keeps sounding); one that can, engages.
    /// A growing file under a name AVAudioFile can't decode by EXTENSION is refused too.
    func testRequireRunwayAndTheExtensionTrapRefuseWithoutTouchingAnything() async throws {
        let data = try noise
        let r = try dspRig(["g9", "g9b"])
        let file = tempMP3("g9")
        let s = try feed(r.loader, "g9", file, data, 0.3)                // 3.6 − 1.5 = 2.1 s
        XCTAssertFalse(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 6, songId: "g9", play: false,
                                             atTrackStart: false, requireRunway: true))
        XCTAssertFalse(r.dsp.isEngaged, "refused: untouched")
        XCTAssertNil(r.dsp.loadedSongId)
        try feed(r.loader, "g9", file, data, 0.9)                         // 9.3 s ≥ 5 + 4
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 5, songId: "g9", play: false,
                                            atTrackStart: false, requireRunway: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isEngaged)
        XCTAssertEqual(r.dsp.currentTime, 5, accuracy: 0.01)
        r.dsp.disengage()

        let part = tempMP3("g9b", ext: "part")
        try data.prefix(bytes(data, 0.9)).write(to: part)
        let bad = r.loader.injectStreamForTesting(songId: "g9b", file: part, bytes: Int64(bytes(data, 0.9)),
                                                  expected: Int64(data.count), origin: .buffer)
        XCTAssertFalse(r.dsp.engageStreaming(bad, lengthMs: 12_000, atSeconds: 0, songId: "g9b", play: true),
                       "AVAudioFile decodes by EXTENSION — a .part growing file is refused")
        XCTAssertFalse(r.dsp.isEngaged)
    }

    /// PAUSE / RESUME across a hold: a held playhead paused is just paused at the hold point;
    /// ▶ there without runway holds again; with runway it plays from there.
    func testPauseDuringAHoldAndResume() async throws {
        let data = try noise
        let r = try dspRig(["g10"])
        let file = tempMP3("g10")
        let s = try feed(r.loader, "g10", file, data, 0.05)
        XCTAssertTrue(r.dsp.engageStreaming(s, lengthMs: 12_000, atSeconds: 2, songId: "g10", play: true))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering)
        r.dsp.pause()
        XCTAssertFalse(r.dsp.isBuffering)
        XCTAssertFalse(r.dsp.isPlaying)
        try feed(r.loader, "g10", file, data, 0.5)                        // 4.5 s frontier: 2 + 2 ✓
        XCTAssertFalse(r.dsp.isPlaying, "bytes never start a paused song")
        XCTAssertEqual(r.dsp.currentTime, 2, accuracy: 0.01)
        r.dsp.resume()
        XCTAssertFalse(r.dsp.isBuffering)
        await waitUntil("rendering from 2 s") { r.dsp.currentTime > 2.2 }
        XCTAssertLessThan(r.dsp.currentTime, 3.5)
    }

    // MARK: - 3 · SetlistPlayer: the growing-file start, fallbacks, hand-off, ownership

    private struct SeqRig {
        let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine; let coord: PlaybackCoordinator
        let seq: SetlistPlayer; let dsp: NowPlayingDSP; let loader: MixStreamLoader
    }

    /// The REAL sequencer + coordinator over a scripted rip server (presign → an https URL the
    /// AVPlayer streams — the plain path), a real DSP, and a loader whose buffer streams are
    /// injected (no network). `mixDefault`: new sessions start in Mix Mode.
    private func seqRig(_ ids: [String], mixDefault: Bool = true) throws -> SeqRig {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrowStub.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://server.test"
        settings.ripToken = ""
        rips.settings = settings
        rips.setManifest(Dictionary(uniqueKeysWithValues: ids.map { ($0, RipsStore.ManifestEntry(key: "rips/\($0).mp3", source: "digital")) }))
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        dsp.streamer = loader
        seq.dsp = dsp
        seq.openBufferStream = { [weak loader] id, _, _ in loader?.stream(for: id) }
        seq.bufferStream = { [weak loader] id in loader?.stream(for: id) }
        seq.mixModeSettings = { (3, .nextSong, mixDefault) }
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return SeqRig(rips: rips, burns: burns, player: player, coord: coord, seq: seq, dsp: dsp, loader: loader)
    }

    private func item(_ id: String) -> SetlistPlayer.Item { .init(id: id, title: id, artist: "A", lengthMs: 12_000) }

    /// MIX MODE ON: a ripped, not-local row STARTS in the DSP on its buffer stream — no presigned
    /// download of the same bytes, one history play, controls live from the first second, ONE
    /// card writer (the engine's external path) that scrubs the DSP; "Buffering…" while it holds.
    func testRippedRowStartsInTheDSPOnItsGrowingFile() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        let file = tempMP3("sa")
        try feed(r.loader, "a", file, data, 0.05)
        var plays: [String] = []
        r.rips.onPlay = { plays.append($0) }
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixMode.enabled)
        XCTAssertEqual(r.seq.growingStartCount, 1)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "a")
        XCTAssertEqual(r.rips.nowPlaying?.url, file, "the row plays its buffer file")
        XCTAssertEqual(GrowStub.presignCount("a"), 0, "no presigned download of the same bytes")
        XCTAssertTrue(r.seq.currentTrackMixable, "controls live from the first second")
        XCTAssertEqual(r.seq.mixModeIndicator, .holding(nil), "held for bytes: Buffering…, controls live")
        XCTAssertTrue(r.seq.mixModeIndicator.controlsLive)
        XCTAssertTrue(r.player.hasLoadedItem, "the engine's external path owns the card")
        XCTAssertTrue(NowPlayingArbiter.shared.isActive(r.player), "one card writer")
        XCTAssertTrue(r.player.isPlaying, "the card says playing (intent) while it buffers")

        try feed(r.loader, "a", file, data, 0.5)
        XCTAssertFalse(r.dsp.isBuffering)
        await waitUntil("first audio closes the start window") { !r.seq.isStartPending }
        XCTAssertEqual(r.seq.mixModeIndicator, .engaged)
        // The card's scrubber drives the DSP — past the frontier it holds at the target.
        r.player.seek(to: 10)
        XCTAssertEqual(r.dsp.currentTime, 10, accuracy: 0.05)
        XCTAssertTrue(r.dsp.isBuffering)
        XCTAssertEqual(r.seq.mixModeIndicator, .holding(nil))
        XCTAssertEqual(plays.filter { $0 == "a" }.count, 1, "one history play")
        XCTAssertEqual(r.seq.index, 0)
    }

    /// Mix Mode OFF (the regression contract): the same row plays its plain presigned stream.
    func testMixModeOffPlaysThePlainStream() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        try feed(r.loader, "a", tempMP3("so"), data, 0.5)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a streaming") { r.rips.nowPlaying?.songId == "a" && r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.growingStartCount, 0)
        XCTAssertEqual(GrowStub.presignCount("a"), 1)
    }

    /// REVIEW: on a network where the policy lets Mix Mode download NOTHING (cellular "Off"), a
    /// ripped row starts plain — a growing start would fetch the whole song (and keep fetching
    /// it after a skip) against the listener's setting.
    func testCellularOffStartsPlain() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        r.seq.mixModeSettings = { (3, .off, true) }
        let pf = NowPlayingPrefetcher()
        pf.network = { .expensive }
        r.seq.prefetcher = pf
        try feed(r.loader, "a", tempMP3("sc"), data, 0.5)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a streaming") { r.rips.nowPlaying?.songId == "a" && r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.growingStartCount, 0)
        XCTAssertEqual(GrowStub.presignCount("a"), 1, "the plain presigned stream")
    }

    /// A DEAD buffer stream never costs the row: it falls back to its plain presigned stream at
    /// the same position (no advance, refused for the growing path this play).
    func testDeadBufferStreamFallsBackToThePlainStream() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        let file = tempMP3("sd")
        try feed(r.loader, "a", file, data, 0.02)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        r.loader.failStreamForTesting("a")
        await waitUntil("back on the plain stream") { r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.growingFallbackCount, 1)
        XCTAssertEqual(r.seq.index, 0, "a dead buffer is not a dead row: no advance")
        XCTAssertEqual(r.rips.nowPlaying?.songId, "a")
        XCTAssertEqual(GrowStub.presignCount("a"), 1)
    }

    /// Start a plain presigned stream (Mix Mode off), heard (start window closed).
    private func startPlain(_ r: SeqRig, _ ids: [String]) async {
        r.seq.play(ids.map(item))
        await waitUntil("\(ids[0]) streaming") {
            r.rips.nowPlaying?.songId == ids[0] && r.rips.nowPlaying?.url.isFileURL == false
        }
        r.player.simulateFirstAudioForTesting()
        await waitUntil("start window closed") { !r.seq.isStartPending }
    }

    /// Mix Mode turned on MID-SONG over a presigned stream: once the buffer lane's copy covers
    /// the playhead the controls go live, and the FIRST TOUCH moves the row onto the growing file
    /// in the DSP at the same song position — same row, no second history play.
    func testFirstTouchMovesAPresignedStreamOntoTheGrowingFileAtThePosition() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        var plays: [String] = []
        r.rips.onPlay = { plays.append($0) }
        await startPlain(r, ["a", "b"])
        let presigned = try XCTUnwrap(r.rips.nowPlaying?.url)
        r.seq.setMixMode(true)
        r.player.clock.currentTime = 3                     // the stream's playhead
        let file = tempMP3("st")
        try feed(r.loader, "a", file, data, 0.2)            // 2.4 − 1.5 s: doesn't cover 3 s + 4
        XCTAssertFalse(r.seq.currentTrackMixable, "the buffer is behind the playhead")
        r.seq.engageMix()
        XCTAssertFalse(r.seq.mixEngaged, "no touch hand-off without coverage")
        try feed(r.loader, "a", file, data, 0.95)
        XCTAssertTrue(r.seq.currentTrackMixable, "the buffer covers the playhead: controls live")
        XCTAssertEqual(r.seq.mixModeIndicator, .ready)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertEqual(r.rips.nowPlaying?.url, file)
        XCTAssertEqual(r.dsp.currentTime, 3, accuracy: 0.3, "same song position")
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertEqual(r.seq.handOffCount, 1)
        XCTAssertEqual(r.seq.index, 0)
        XCTAssertLessThanOrEqual(plays.filter { $0 == "a" }.count, 1, "no second history play")
        XCTAssertNotEqual(presigned, file)
    }

    /// The phase-2 hand-off rules hold for the growing hand-off: a PAUSED stream moves paused;
    /// an open interruption refuses it outright.
    func testTouchHandOffStaysPausedAndNeverCrossesAnInterruption() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        r.seq.setMixMode(true)
        r.player.clock.currentTime = 2
        try feed(r.loader, "a", tempMP3("sp"), data, 0.95)
        r.player.handleInterruption(began: true, shouldResume: nil)
        r.seq.engageMix()
        XCTAssertFalse(r.seq.mixEngaged, "never take the audio across a call")
        r.player.handleInterruption(began: false, shouldResume: false)
        r.player.pause()
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertFalse(r.dsp.isPlaying, "paused stays paused")
        XCTAssertFalse(r.player.isPlaying, "the card says paused")
        XCTAssertEqual(r.dsp.currentTime, 2, accuracy: 0.3)
    }

    /// A mid-song HOLD that outlasts `growingHoldFallbackSeconds` falls back to the presigned
    /// stream the touch hand-off left, at the held position.
    func testLongMidSongHoldFallsBackToTheStreamItLeft() async throws {
        let data = try noise
        SetlistPlayer.growingHoldFallbackSeconds = 0.2
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let presigned = try XCTUnwrap(r.rips.nowPlaying?.url)
        r.seq.setMixMode(true)
        r.player.clock.currentTime = 2
        try feed(r.loader, "a", tempMP3("sh"), data, 0.95)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        await waitUntil("rendering") { r.dsp.currentTime > 2.2 && !r.dsp.awaitingFirstAudio }
        r.dsp.seek(toSongSeconds: 11)                       // past the frontier: holds
        XCTAssertTrue(r.dsp.isBuffering)
        await waitUntil("fell back to the stream it left") { !r.seq.mixEngaged }
        XCTAssertEqual(r.rips.nowPlaying?.url, presigned)
        XCTAssertEqual(r.rips.nowPlaying?.seekMs ?? 0, 11_000, accuracy: 100, "at the held position")
        XCTAssertEqual(r.seq.growingFallbackCount, 1)
        XCTAssertEqual(r.seq.index, 0)
    }

    /// Levi 2026-11-02: the mid-song hold budget is 5 s (was 20).
    func testMidSongHoldBudgetIsFiveSeconds() {
        XCTAssertEqual(SetlistPlayer.growingHoldFallbackSeconds, 5)
    }

    /// A scrub FAR past the downloaded frontier holds, then — at the real 5 s default — falls back
    /// to the plain stream at the scrub target (not 20 s of dead air, not before the budget).
    func testScrubFarPastTheFrontierFallsBackAfterFiveSeconds() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let presigned = try XCTUnwrap(r.rips.nowPlaying?.url)
        r.seq.setMixMode(true)
        r.player.clock.currentTime = 2
        try feed(r.loader, "a", tempMP3("s5"), data, 0.95)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        await waitUntil("rendering") { r.dsp.currentTime > 2.2 && !r.dsp.awaitingFirstAudio }
        let held = Date()
        r.dsp.seek(toSongSeconds: 11)                       // far past the frontier: holds
        XCTAssertTrue(r.dsp.isBuffering)
        await pause(3.5)
        XCTAssertTrue(r.seq.mixEngaged, "still inside the 5 s budget")
        await waitUntil("fell back to the plain stream", timeout: 6) { !r.seq.mixEngaged }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(held), 4.9)
        XCTAssertEqual(r.rips.nowPlaying?.url, presigned)
        XCTAssertEqual(r.rips.nowPlaying?.seekMs ?? 0, 11_000, accuracy: 100, "at the scrub target")
        XCTAssertEqual(r.seq.index, 0, "a fallback, never a skip")
    }

    /// A START hold keeps the start-watchdog semantics: the short mid-song budget never applies
    /// while the DSP still awaits its first audio.
    func testStartHoldIsNotCutShortByTheMidSongBudget() async throws {
        SetlistPlayer.startStallRekickSeconds = 30
        SetlistPlayer.startStallEscalateSeconds = 30
        SetlistPlayer.growingHoldFallbackSeconds = 0.2
        let r = try seqRig(["a", "b"])
        _ = r.loader.injectStreamForTesting(songId: "a", file: tempMP3("sk"), bytes: 0, expected: 400_000, origin: .buffer)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering)
        await pause(1.0)
        XCTAssertTrue(r.seq.mixEngaged, "a start hold waits for the watchdog, not the 0.2 s mid-song budget")
        XCTAssertEqual(r.seq.growingFallbackCount, 0)
    }

    /// The START WATCHDOG backstops a growing start that never gets bytes: it escalates (hop /
    /// advance through the cascade breaker) exactly as for any stalled start.
    func testStartWatchdogBackstopsAGrowingStartThatNeverGetsBytes() async throws {
        SetlistPlayer.startStallRekickSeconds = 0.1
        SetlistPlayer.startStallEscalateSeconds = 0.3
        let r = try seqRig(["a", "b"])
        _ = r.loader.injectStreamForTesting(songId: "a", file: tempMP3("sw"), bytes: 0, expected: 400_000, origin: .buffer)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.dsp.isBuffering)
        await waitUntil("escalated to b", timeout: 5) { r.rips.nowPlaying?.songId == "b" }
        XCTAssertFalse(r.seq.mixEngaged, "b (no buffer stream) plays the plain way")
    }

    /// SHOULD (review): a START hold the listener pauses and resumes is no longer the start
    /// watchdog's (it stood down on the pause) — the hold backstop still takes the row to its
    /// plain stream instead of holding forever.
    func testPausedAndResumedStartHoldIsStillBackstopped() async throws {
        SetlistPlayer.startStallRekickSeconds = 0.2
        SetlistPlayer.startStallEscalateSeconds = 0.4
        let r = try seqRig(["a", "b"])
        _ = r.loader.injectStreamForTesting(songId: "a", file: tempMP3("sb"), bytes: 0, expected: 400_000, origin: .buffer)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        r.player.pause()                                      // the card's ⏸ → the DSP
        XCTAssertFalse(r.dsp.isPlaying)
        await pause(0.5)                                      // the watchdog stands down (not owed)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "a", "a paused start is never escalated")
        r.player.play()                                       // ▶ → holds again, still no bytes
        XCTAssertTrue(r.dsp.isBuffering)
        await waitUntil("backstopped onto the plain stream", timeout: 6) { r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertEqual(r.rips.nowPlaying?.songId, "a", "same row — a fallback, not a skip")
        XCTAssertEqual(r.seq.growingFallbackCount, 1)
    }

    /// One DSP surface at a time: a Mix-tab session going live tears the growing engagement
    /// down, and the next row then plays the plain way (Mix Mode suspended).
    func testMixTabGoingLiveTearsDownTheGrowingEngagement() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        let live = GrowLiveFlag()
        r.seq.mixSessionActive = { live.on }
        try feed(r.loader, "a", tempMP3("sm"), data, 0.5)
        try feed(r.loader, "b", tempMP3("smb"), data, 0.5)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        live.on = true
        await waitUntil("torn down") { !r.seq.mixEngaged }
        XCTAssertFalse(r.dsp.isEngaged)
        XCTAssertFalse(r.dsp.isPlaying, "no hidden second audio source")
        r.seq.skipNext()
        await waitUntil("b streaming plain") { r.rips.nowPlaying?.songId == "b" && r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertEqual(r.seq.growingStartCount, 1, "suspended: no growing start under a live Mix tab")
    }

    /// DURABLE RESTORE: held (no stream opened before ▶); ▶ resumes the row ON the growing file
    /// at the saved position.
    func testRestoreResumesOnTheGrowingFileAtTheSavedPosition() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        var opened = 0
        let loader = r.loader
        r.seq.openBufferStream = { id, _, _ in opened += 1; return loader.stream(for: id) }
        try feed(r.loader, "a", tempMP3("sr"), data, 0.9)
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_g", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "a", title: "a", artist: "A", lengthMs: 12_000, repeatCount: nil),
                    .init(songId: "b", title: "b", artist: "A", lengthMs: 12_000, repeatCount: nil)],
            index: 0, positionMs: 4_000, isPlaying: true, npMixMode: NPMixModeState(enabled: true), updatedAt: 0)
        r.seq.restore(from: snap)
        XCTAssertEqual(opened, 0, "held: nothing opened before ▶")
        XCTAssertFalse(r.seq.mixEngaged)
        r.seq.resumeFromHold()
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(r.dsp.currentTime, 4, accuracy: 0.3, "at the saved position")
        XCTAssertFalse(r.dsp.isBuffering, "9.3 s written covers 4 s + 2")
    }

    /// MEDIA SERVICES RESET while on a growing file: the graph is recreated and the row re-enters
    /// the growing path at the same position (a partial can't go to the AVPlayer).
    func testMediaServicesResetReentersTheGrowingFile() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        try feed(r.loader, "a", tempMP3("sx"), data, 0.6)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        await waitUntil("rendering") { r.dsp.currentTime > 0.5 }
        r.dsp.pause()
        let at = r.dsp.currentTime
        r.seq.handleMediaServicesReset()
        XCTAssertEqual(r.dsp.mediaResetRebuilds, 1)
        await waitUntil("re-entered the growing file") { r.seq.mixEngaged && r.seq.growingStartCount == 2 }
        XCTAssertEqual(r.dsp.currentTime, at, accuracy: 0.1)
        XCTAssertFalse(r.dsp.isPlaying, "paused stays paused")
        XCTAssertEqual(r.seq.index, 0)
    }

    // MARK: - 4 · Review fixes (adversarial pass)

    /// MUST: a restore-resume DEEP into a song the buffer doesn't cover yet must not hold until
    /// the download gets there — it plays the plain stream (which seeks at once), the buffer
    /// keeps downloading for a later touch. Covered ⇒ the growing file.
    func testDeepResumeTheBufferDoesNotCoverPlaysPlainCoveredPlaysGrowing() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        try feed(r.loader, "a", tempMP3("dr"), data, 0.3)               // covers ~2.1 s of 12
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_d", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "a", title: "a", artist: "A", lengthMs: 12_000, repeatCount: nil),
                    .init(songId: "b", title: "b", artist: "A", lengthMs: 12_000, repeatCount: nil)],
            index: 0, positionMs: 8_000, isPlaying: true, npMixMode: NPMixModeState(enabled: true), updatedAt: 0)
        SetlistPlayer.growingDeepResumeMs = 5_000
        defer { SetlistPlayer.growingDeepResumeMs = 15_000 }
        r.seq.restore(from: snap)
        r.seq.resumeFromHold()
        await waitUntil("a streaming plain") { r.rips.nowPlaying?.songId == "a" && r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.growingStartCount, 0)
        XCTAssertEqual(r.rips.nowPlaying?.seekMs, 8_000, "the plain stream seeks straight to the saved position")

        r.seq.stop()
        try feed(r.loader, "b", tempMP3("dr2"), data, 1.0)                // covers 10.5 s ≥ 8 + 2
        r.seq.restore(from: PlaybackSessionStore.Snapshot(
            sessionId: "pses_d2", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "b", title: "b", artist: "A", lengthMs: 12_000, repeatCount: nil)],
            index: 0, positionMs: 8_000, isPlaying: true, npMixMode: NPMixModeState(enabled: true), updatedAt: 0))
        r.seq.resumeFromHold()
        await waitUntil("b on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertEqual(r.dsp.currentTime, 8, accuracy: 0.3)
    }

    /// MUST: an analog song with no per-song cut would stream its whole album SIDE from byte 0 —
    /// it starts plain (the AVPlayer range-seeks to the song).
    func testAnalogSongWithoutACutStartsPlain() async throws {
        let r = try seqRig(["v1", "v2"])
        r.rips.setManifest(["v1": .init(key: "rips/alb.mp3", source: "analog", startMs: 600_000),
                            "v2": .init(key: "rips/v2.mp3", source: "digital")])
        _ = r.loader.injectStreamForTesting(songId: "v1", file: tempMP3("an"), bytes: 1_000, expected: 40_000_000, origin: .buffer)
        r.seq.play([item("v1"), item("v2")])
        await waitUntil("v1 streaming plain") { r.rips.nowPlaying?.songId == "v1" && r.rips.nowPlaying?.url.isFileURL == false }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.growingStartCount, 0)
    }

    /// SHOULD: with the DSP owning a COMPLETE local file (the F4 touch), the card's scrubber now
    /// drives the DSP too (before, a scrub hit the idle AVPlayer and did nothing).
    func testCardScrubDrivesAnEngagedCompleteFile() async throws {
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: ["f1"], rips: rips, lengths: ["f1": 12.0])
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        seq.play([item("f1")])
        await waitUntil("f1 playing") { rips.nowPlaying?.songId == "f1" }
        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(seq.mixEngaged)
        player.seek(to: 7)
        XCTAssertEqual(dsp.currentTime, 7, accuracy: 0.05)
        XCTAssertFalse(dsp.isBuffering, "a complete file never holds")
    }

    /// MUST (loader): a stream cancelled (collection run stopped) or evicted to make room tells
    /// its readers it is dead — a growing-file reader holding the record would wait forever.
    func testLoaderCancelTellsAReaderTheStreamIsDead() throws {
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        var heard: [String] = []
        loader.addProgressListener { heard.append($0) }
        let s = loader.injectStreamForTesting(songId: "c1", file: tempMP3("c1"), bytes: 10, expected: 1_000, origin: .buffer)
        heard.removeAll()
        loader.cancel(songIds: ["c1"])
        XCTAssertTrue(s.failed, "the reader's record says dead")
        XCTAssertEqual(heard, ["c1"], "…and the listeners hear it")
        XCTAssertNil(loader.stream(for: "c1"))
        // A pinned stream (what Now Playing / a Mix deck plays) is left alone.
        loader.pinnedIds = { ["c2"] }
        let p = loader.injectStreamForTesting(songId: "c2", file: tempMP3("c2"), bytes: 10, expected: 1_000, origin: .buffer)
        loader.cancel(songIds: ["c2"])
        XCTAssertFalse(p.failed)
    }

    // MARK: - Phase 4: Apple Music rows

    private final class FakeMusicKit: MusicKitPlayerControl {
        var isPlaying = false
        var releaseCount = 0
        let subject = PassthroughSubject<Void, Never>()
        var stateChanges: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
        func release() { releaseCount += 1; isPlaying = false }
    }

    /// Put the running row `id` on APPLE MUSIC at `pos` (MusicKit can't run headless): the state a
    /// won Apple Music start leaves — the coordinator's backend, MusicKit owned, the provider's
    /// now-playing + clock, the rip path's own now-playing cleared, the card impersonating MusicKit.
    @discardableResult
    private func putOnAppleMusic(_ r: SeqRig, _ id: String, at pos: Double, playing: Bool = true,
                                 duration: Double = 12) -> FakeMusicKit {
        let fake = FakeMusicKit()
        fake.isPlaying = playing
        let am = r.coord.appleMusic
        am.musicKitPlayer = fake
        r.rips.setNowPlaying(nil, announce: false)
        r.coord.setActiveBackendForTests(.appleMusic)
        am.setOwnsMusicKitForTests(true)
        am.setNowPlayingForTests(.init(songId: id, title: id, artist: "A"))
        am.setPlaybackForTests(playing: playing, audioConfirmed: true, position: pos, duration: duration)
        r.seq.appleMusicPositionOverride = { pos }
        r.player.beginExternalNowPlaying(title: id, artist: "A", songId: id, durationSeconds: duration,
                                         position: { pos }, isPlaying: { playing },
                                         play: { [weak am] in am?.resume() }, pause: { [weak am] in am?.pausePlayback() })
        return fake
    }

    /// Q1: an Apple Music row whose buffer covers MusicKit's playhead goes LIVE ("Ready — tap a
    /// control…") and the FIRST TOUCH cuts over in the DSP at MusicKit's position + the lead:
    /// MusicKit stopped AND released (no stale card, nothing to resume), no second history play,
    /// the card's scrubber now drives the DSP, same row.
    func testFirstTouchHandsAnAppleMusicRowToItsBufferAtMusicKitsPosition() async throws {
        let data = try noise
        UserDefaults.standard.set(250, forKey: "pdj.npmix.amHandoffLeadMs")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "pdj.npmix.amHandoffLeadMs") }
        let r = try seqRig(["a", "b"], mixDefault: false)
        var plays: [String] = []
        await startPlain(r, ["a", "b"])
        r.rips.onPlay = { plays.append($0) }
        let fake = putOnAppleMusic(r, "a", at: 3)
        try feed(r.loader, "a", tempMP3("am"), data, 0.95)
        XCTAssertFalse(r.seq.currentTrackMixable, "Mix Mode off: an Apple Music row is never mixable")
        r.seq.setMixMode(true)
        XCTAssertTrue(r.seq.currentTrackMixable, "the local copy covers MusicKit's playhead")
        XCTAssertEqual(r.seq.mixModeIndicator, .readyFromAppleMusic)
        XCTAssertEqual(r.coord.activeBackend, .appleMusic, "nothing moved on its own")
        r.seq.engageMix()                                    // the touch
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertEqual(r.seq.amHandOffCount, 1)
        XCTAssertNil(r.coord.activeBackend, "Apple Music left")
        XCTAssertEqual(fake.releaseCount, 1, "MusicKit stopped AND its queue emptied — no stale CarPlay card")
        XCTAssertFalse(r.coord.appleMusic.ownsMusicKit)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "a")
        XCTAssertTrue(r.rips.nowPlaying?.url.isFileURL ?? false)
        XCTAssertEqual(r.dsp.currentTime, 3.25, accuracy: 0.3, "MusicKit's position + the 250 ms lead")
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertTrue(plays.isEmpty, "Apple Music already counted this play — no second one")
        XCTAssertTrue(NowPlayingArbiter.shared.isActive(r.player), "one card writer")
        XCTAssertEqual(r.seq.mixModeIndicator, .engaged)
        r.player.seek(to: 6)
        XCTAssertEqual(r.dsp.currentTime, 6, accuracy: 0.05, "the card's scrubber drives the DSP now")
        XCTAssertEqual(r.seq.index, 0)
    }

    /// Q1: WITHOUT a touch the Apple Music row finishes on Apple Music — the buffer completing,
    /// the swap-on-land hand-off, the Mix Mode toggle: none of them cut over.
    func testAppleMusicRowNeverHandsOffWithoutATouch() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let fake = putOnAppleMusic(r, "a", at: 3)
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("an"), data, 1, finished: true)
        r.seq.noteBufferStreamProgress("a")
        XCTAssertFalse(r.seq.handOffCurrentToLocal(reason: "test"), "the swap-on-land never takes an AM row")
        await pause(0.2)
        XCTAssertEqual(r.coord.activeBackend, .appleMusic)
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(fake.releaseCount, 0)
    }

    /// No local copy covering MusicKit's playhead ⇒ not mixable, the touch does nothing, MusicKit
    /// keeps playing. Same in the last seconds of the track, before MusicKit confirmed audio, and
    /// while a Mix-tab session is live.
    func testAppleMusicHandOffRefusals() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let fake = putOnAppleMusic(r, "a", at: 8)
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("ar"), data, 0.3)    // 3.6 s − margin: behind 8 s + 4
        XCTAssertFalse(r.seq.currentTrackMixable)
        XCTAssertFalse(r.seq.mixModeIndicator.controlsLive, "its rip exists but doesn't cover the playhead yet")
        XCTAssertNotEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"), "a ripped row never says so")
        r.seq.engageMix()
        XCTAssertFalse(r.seq.mixEngaged)
        try feed(r.loader, "a", tempMP3("ar2"), data, 1, finished: true)
        // Last seconds of the track: it finishes on Apple Music.
        r.seq.appleMusicPositionOverride = { 10 }
        XCTAssertFalse(r.seq.currentTrackMixable, "inside the tail guard")
        r.seq.appleMusicPositionOverride = { 4 }
        // MusicKit hasn't confirmed audio yet.
        r.coord.appleMusic.setPlaybackForTests(playing: true, audioConfirmed: false, position: 4, duration: 12)
        XCTAssertFalse(r.seq.currentTrackMixable, "a start still in flight on Apple Music")
        r.coord.appleMusic.setPlaybackForTests(playing: true, audioConfirmed: true, position: 4, duration: 12)
        // A live Mix-tab session (one DSP surface): suspended.
        let live = GrowLiveFlag()
        r.seq.mixSessionActive = { live.on }
        live.on = true
        XCTAssertFalse(r.seq.currentTrackMixable)
        r.seq.engageMix()
        XCTAssertFalse(r.seq.mixEngaged)
        live.on = false
        XCTAssertTrue(r.seq.currentTrackMixable)
        XCTAssertEqual(fake.releaseCount, 0, "every refusal left MusicKit alone")
        XCTAssertEqual(r.coord.activeBackend, .appleMusic)
    }

    /// A PAUSED Apple Music row hands off paused; ▶ on the card then plays the DSP.
    func testPausedAppleMusicHandsOffPaused() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        putOnAppleMusic(r, "a", at: 2, playing: false)
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("ap"), data, 0.95)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertFalse(r.dsp.isPlaying, "paused stays paused")
        XCTAssertEqual(r.dsp.currentTime, 2, accuracy: 0.3)
        r.player.play()
        XCTAssertTrue(r.dsp.isPlaying, "the card's ▶ drives the DSP")
    }

    /// After the hand-off Apple Music can't move the set: a late end-of-track report from the
    /// provider is ignored (its backend is gone), and a STRAY MusicKit play (a stale card's ▶)
    /// is silenced and resumes the DSP — never a restart of the row from 0:00.
    func testAfterTheHandOffAppleMusicCannotAdvanceOrRestartTheRow() async throws {
        let data = try noise
        AppleMusicPlaybackProvider.strayGraceSeconds = 0
        addTeardownBlock { @MainActor in AppleMusicPlaybackProvider.strayGraceSeconds = 1.5 }
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let fake = putOnAppleMusic(r, "a", at: 3)
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("as"), data, 0.95)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        r.coord.appleMusic.onTrackEnded?(.natural)          // a stray end report
        XCTAssertEqual(r.seq.index, 0, "no stray end-of-track advance")
        XCTAssertTrue(r.seq.mixEngaged)
        let url = r.rips.nowPlaying?.url
        r.dsp.pause()
        fake.isPlaying = true                                // MusicKit resumed on its own
        XCTAssertEqual(r.coord.appleMusic.checkForStrayPlay(source: "test"), .reclaim)
        await waitUntil("the DSP resumed") { r.dsp.isPlaying }
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertEqual(r.rips.nowPlaying?.url, url, "the row was not restarted")
        XCTAssertEqual(r.seq.index, 0)
    }

    /// A BURNED (adopted) copy takes the Apple Music row over at MusicKit's position.
    func testFirstTouchHandsAnAppleMusicRowToItsBurnedCopy() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let tmp = tempMP3("ab")
        try data.write(to: tmp)
        let burned = try XCTUnwrap(r.burns.adoptStreamedFile(songId: "a", title: "a", artist: "A", from: tmp, origin: .buffer))
        let fake = putOnAppleMusic(r, "a", at: 5)
        r.seq.setMixMode(true)
        XCTAssertTrue(r.seq.currentTrackMixable)
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertEqual(r.rips.nowPlaying?.url.standardizedFileURL, burned.standardizedFileURL)
        XCTAssertEqual(r.dsp.currentTime, 5, accuracy: 0.3)
        XCTAssertEqual(fake.releaseCount, 1)
        XCTAssertNil(r.coord.activeBackend)
    }

    /// The touch is refused across an open audio-session interruption (a call): MusicKit is
    /// paused by it (not by the listener) — nothing changes.
    func testAppleMusicHandOffRefusedAcrossAnInterruption() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        let fake = putOnAppleMusic(r, "a", at: 3, playing: false)
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("ai"), data, 0.95)
        r.player.handleInterruption(began: true, shouldResume: nil)
        r.seq.engageMix()
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertEqual(fake.releaseCount, 0)
        XCTAssertEqual(r.coord.activeBackend, .appleMusic)
    }

    /// REVIEW MUST (2026-11-02, field logs ios-3712BFDE 10-23…25): MusicKit's OWN start interrupts
    /// our session ("AM play …" + "interruption began … external=1", never ended). With MusicKit
    /// audibly playing that is not a call: the touch hands off, and the stale interruption is
    /// cleared (or the growing file's hold fallback would never fire).
    func testAppleMusicHandOffIsNotBlockedByMusicKitsOwnStaleInterruption() async throws {
        let data = try noise
        SetlistPlayer.growingHoldFallbackSeconds = 0.2
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        // Build the DSP graph up front, so a REFUSED hand-off fails here instead of skipping.
        let warm = tempMP3("azw")
        try data.write(to: warm)
        r.dsp.engage(url: warm, startMs: nil, lengthMs: 12_000, atSeconds: 0, songId: "warm", play: false)
        r.dsp.disengage()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        let fake = putOnAppleMusic(r, "a", at: 3)
        r.player.handleInterruption(began: true, shouldResume: nil)   // MusicKit's start did this
        r.seq.setMixMode(true)
        try feed(r.loader, "a", tempMP3("az"), data, 0.95)
        XCTAssertTrue(r.seq.currentTrackMixable)
        r.seq.engageMix()
        XCTAssertTrue(r.seq.mixEngaged, "MusicKit audibly playing proves no call holds the audio")
        XCTAssertEqual(fake.releaseCount, 1)
        XCTAssertFalse(r.player.interruptionOpen, "the stale interruption is over")
        // …so a hold past the frontier still falls back (5 s rule) instead of holding forever.
        await waitUntil("rendering") { r.dsp.currentTime > 3.2 && !r.dsp.awaitingFirstAudio }
        r.dsp.seek(toSongSeconds: 11.5)
        XCTAssertTrue(r.dsp.isBuffering)
        await waitUntil("fell back") { !r.seq.mixEngaged }
        XCTAssertEqual(r.seq.growingFallbackCount, 1)
        XCTAssertEqual(r.seq.index, 0)
        // The growing file that failed this play is never offered for a second hand-off.
        XCTAssertNil(r.seq.amHandOffCopyKindForTests(atSongSeconds: 4))
    }

    /// REVIEW MUST (2026-11-02): an Apple Music row left our session's interruption open; the
    /// NEXT row starts in the DSP on its growing file (no `PlayerEngine.load` to clear it). Its
    /// mid-song hold must still fall back after the budget — not hold forever.
    func testGrowingStartAfterAnAppleMusicRowStillFallsBackOnALongHold() async throws {
        let data = try noise
        SetlistPlayer.growingHoldFallbackSeconds = 0.2
        let r = try seqRig(["a", "b"])
        await startPlain(r, ["a", "b"])
        putOnAppleMusic(r, "a", at: 3)
        r.player.handleInterruption(began: true, shouldResume: nil)   // MusicKit's start did this
        await pause(0.1)                                     // the now-playing observers settle on a
        try feed(r.loader, "b", tempMP3("gb"), data, 0.95)
        r.seq.skipNext()
        await waitUntil("b on the growing file") { r.seq.index == 1 && r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertFalse(r.player.interruptionOpen)
        await waitUntil("rendering") { r.dsp.currentTime > 0.5 && !r.dsp.awaitingFirstAudio }
        r.dsp.seek(toSongSeconds: 11.5)
        XCTAssertTrue(r.dsp.isBuffering)
        await waitUntil("fell back to the plain stream") { !r.seq.mixEngaged }
        XCTAssertEqual(r.seq.growingFallbackCount, 1)
        XCTAssertEqual(r.seq.index, 1, "a fallback, never a skip")
    }

    /// Q7, OWNER ONLY: the lane asks the rip server for the next 2 Apple-Music-only rows; a
    /// public / hybrid install never does, and the chip says "Apple Music only" there while the
    /// owner's says "Ripping — mixable next play".
    func testOwnerAsksForTheNextTwoAppleMusicOnlyRowsAndPublicUsersNever() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        let amOnly: Set<String> = ["x", "y", "z"]
        r.coord.sourceOfSong = { amOnly.contains($0) ? Config.appleMusicSourceName : nil }
        var owner = true
        r.coord.isCatalogOwner = { owner }
        let pf = NowPlayingPrefetcher()
        var asked: [String] = []
        pf.requestRip = { asked.append($0) }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in false }
        await startPlain(r, ["a", "x", "b", "y", "z"])
        r.seq.setMixMode(true)
        r.seq.replanPrefetch()
        XCTAssertEqual(asked, ["x", "y"], "the next two AM-only rows — never z, never the playing row")
        // The public user (a fresh lane — nothing deduped): no rip, ever.
        owner = false
        let pf2 = NowPlayingPrefetcher()
        var asked2: [String] = []
        pf2.requestRip = { asked2.append($0) }
        r.seq.prefetcher = pf2
        r.seq.replanPrefetch()
        XCTAssertTrue(asked2.isEmpty, "a non-owner never asks for a rip")
    }

    func testRippingChipIsOwnerOnly() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        var owner = true
        r.coord.isCatalogOwner = { owner }
        await startPlain(r, ["a", "b"])
        // Row a is now an Apple-Music-only row (not ripped) playing on Apple Music, its rip in flight.
        r.rips.setManifest(["b": .init(key: "rips/b.mp3", source: "digital")])
        r.coord.sourceOfSong = { $0 == "a" ? Config.appleMusicSourceName : nil }
        putOnAppleMusic(r, "a", at: 2)
        r.rips.setJobForTesting("a", phase: .ripping)
        r.seq.setMixMode(true)
        XCTAssertEqual(r.seq.mixModeIndicator, .ripping)
        owner = false
        XCTAssertEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"), "a public user never sees Ripping")
        owner = true
        r.rips.setJobForTesting("a", phase: nil)
        XCTAssertEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"), "nothing in flight")
    }

    /// LEVI'S REPRO (iPhone, 2026-11-02, "Workout"): an Apple-Music-sourced row whose SAME-edition
    /// rip exists plays on Apple Music; Mix Mode is turned on MID-SONG. The lane must re-plan to
    /// buffer the CURRENT row (owner AND public user — buffering an existing rip is not ripping),
    /// the chip must say "Buffering…" — never "Apple Music only" — and once the copy covers
    /// MusicKit's playhead, "Ready — tap a control…".
    func testCurrentAppleMusicRowWithItsRipBuffersWhenMixModeTurnsOnMidSong() async throws {
        let data = try noise
        for owner in [true, false] {
            let r = try seqRig(["a", "b"], mixDefault: false)
            r.coord.isCatalogOwner = { owner }
            let pf = NowPlayingPrefetcher()
            var asked: [String] = []
            pf.requestRip = { asked.append($0) }
            pf.fetchSong = { _ in try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            r.seq.prefetcher = pf
            r.seq.prefetchSongFetchable = { _ in true }
            await startPlain(r, ["a", "b"])
            r.coord.sourceOfSong = { _ in Config.appleMusicSourceName }
            putOnAppleMusic(r, "a", at: 3)
            XCTAssertEqual(r.seq.mixModeIndicator, .off)
            r.seq.setMixMode(true)                           // mid-song, not at session start
            await waitUntil("the current AM row is planned (owner=\(owner))") { pf.isPlannedSong("a") }
            XCTAssertNotEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"), "a same-edition rip exists")
            if case .buffering = r.seq.mixModeIndicator {} else {
                XCTFail("expected Buffering…, got \(r.seq.mixModeIndicator) (owner=\(owner))")
            }
            XCTAssertFalse(asked.contains("a"), "an existing rip is never re-ripped")
            try feed(r.loader, "a", tempMP3("rp\(owner)"), data, 0.95)
            r.seq.noteBufferStreamProgress("a")
            XCTAssertEqual(r.seq.mixModeIndicator, .readyFromAppleMusic, "owner=\(owner)")
            r.seq.stop()
        }
    }

    /// A ripped Apple Music row whose copy CAN'T buffer right now still says why — never
    /// "Apple Music only" (that is reserved for rows with no rip of their edition).
    func testRippedAppleMusicRowNeverSaysAppleMusicOnly() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        r.coord.sourceOfSong = { _ in Config.appleMusicSourceName }
        putOnAppleMusic(r, "a", at: 3)
        r.seq.setMixMode(true)
        XCTAssertNotEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"))
    }

    /// The upcoming AM-sourced ripped row's presign is fetched ahead, so its start under Mix Mode
    /// is rip-first (`preferLocalAudio`) — and plain Apple Music first without Mix Mode.
    func testUpcomingAppleMusicRowWithARipGetsItsPresignAheadSoItStartsLocal() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        r.coord.appleMusicReadyOverrideForTests = true
        r.coord.sourceOfSong = { $0 == "b" ? Config.appleMusicSourceName : nil }
        await startPlain(r, ["a", "b"])
        await waitUntil("b's presign is in hand") { r.rips.prefetchedURL("b") != nil }
        XCTAssertFalse(r.coord.streamsAppleMusicFirst(id: "b", title: "b", artist: "A", variant: nil, preferLocalAudio: true),
                       "Mix Mode: the ripped AM row starts from its rip")
        XCTAssertTrue(r.coord.streamsAppleMusicFirst(id: "b", title: "b", artist: "A", variant: nil))
    }

    /// EDITION MISMATCH (Levi's repro, second song): the row wants the EXPLICIT edition, only the
    /// clean one is ripped. It stays on Apple Music; the owner's chip names the edition being
    /// ripped, a public user's says "Apple Music only"; the owner's rip-ahead asks for the
    /// specific edition id — and never for an edition whose catalog id is unknown.
    func testEditionMismatchChipAndRipAheadAskForTheWantedEdition() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        var owner = true
        r.coord.isCatalogOwner = { owner }
        r.coord.sourceOfSong = { _ in Config.appleMusicSourceName }
        let pf = NowPlayingPrefetcher()
        var asked: [String] = []
        pf.requestRip = { asked.append($0) }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in false }
        func ed(_ id: String, catalog: String?) -> SetlistPlayer.Item {
            var i = item(id); i.variant = .explicit; i.editionLocked = true; i.editionCatalogId = catalog; return i
        }
        // Only the CLEAN (base) cuts are ripped.
        r.rips.setManifest(["a": .init(key: "rips/a.mp3", source: "digital"), "b": .init(key: "rips/b.mp3", source: "digital"),
                            "c": .init(key: "rips/c.mp3", source: "digital")])
        r.seq.play([ed("a", catalog: "111"), ed("b", catalog: "222"), ed("c", catalog: nil)])
        await pause(0.1)
        putOnAppleMusic(r, "a_explicit", at: 2)
        await pause(0.1)
        r.seq.setMixMode(true)
        r.seq.replanPrefetch()
        XCTAssertEqual(asked, ["b_explicit"], "the wanted edition — and never c (its edition's catalog id is unknown)")
        r.rips.setJobForTesting("a_explicit", phase: .ripping)
        XCTAssertEqual(r.seq.mixModeIndicator, .rippingEdition("explicit"))
        XCTAssertEqual(r.seq.mixModeIndicator.chipText, "Ripping explicit edition — mixable next play")
        owner = false
        XCTAssertEqual(r.seq.mixModeIndicator, .unavailable("Apple Music only"))
    }

    // MARK: - Rule A: edition-agnostic instrumental (Levi 2026-11-02, second repro)

    private func stemmed(_ id: String) -> RipsStore.ManifestEntry {
        .init(key: "rips/\(id).mp3", source: "digital",
              stems: .init(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                           bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3"))
    }
    private func explicitRow(_ id: String, locked: Bool = false, variant: SongVariant = .explicit) -> SetlistPlayer.Item {
        var i = item(id); i.variant = variant; i.editionLocked = locked; i.editionCatalogId = "cat-\(id)"; return i
    }
    private var vocalsMuted: StemLockState {
        var st = StemLockState(); st.enabled = true; st.stemsOn = true; st.muted = ["vocals"]; return st
    }

    /// The pure rule: only a vocals-muted carry, only a PREFERENCE row whose edition has no rip,
    /// only onto a ripped BASE cut with stems — never a clean-only restriction, never with the
    /// vocals audible, never when the wanted edition is ripped.
    func testVocalsMutedEditionSubstituteRule() async throws {
        let r = try seqRig(["a"], mixDefault: false)
        r.rips.setManifest(["a": stemmed("a"), "b": stemmed("b"), "n": .init(key: "rips/n.mp3", source: "digital"),
                            "w": stemmed("w"), "w_explicit": stemmed("w_explicit")])
        await startPlain(r, ["a"])
        let b = explicitRow("b")
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(b), "no lock: the normal edition rule")
        var audible = vocalsMuted; audible.muted = ["drums"]
        r.seq.setStemLockForTesting(audible)
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(b), "vocals audible: never")
        r.seq.setStemLockForTesting(vocalsMuted)
        XCTAssertEqual(r.seq.vocalsMutedEditionSubstitute(b), "b")
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(explicitRow("b", locked: true, variant: .clean)),
                     "a clean-only RESTRICTION never substitutes")
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(explicitRow("n")), "the base has no stems")
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(explicitRow("w")), "the wanted edition is ripped")
        XCTAssertNil(r.seq.vocalsMutedEditionSubstitute(item("b")), "no edition requested")
    }

    /// The repro: an explicit row with only the base rip (+ stems) under a vocals-muted lock. The
    /// lane plans the BASE cut, the dot fills only when that file is local, and the row's start
    /// plays the base rip — never Apple Music — logging the substitution.
    func testVocalsMutedLockPlaysTheBaseRipForAnUnrippedEdition() async throws {
        let r = try seqRig(["a"], mixDefault: false)
        r.rips.setManifest(["a": stemmed("a"), "b": stemmed("b")])
        r.coord.appleMusicReadyOverrideForTests = true
        r.coord.sourceOfSong = { $0 == "b" ? Config.appleMusicSourceName : nil }
        let pf = NowPlayingPrefetcher()
        pf.fetchSong = { _ in try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
        r.seq.prefetcher = pf
        r.seq.prefetchSongFetchable = { _ in true }
        r.seq.play([item("a"), explicitRow("b")])
        await waitUntil("a streaming") { r.rips.nowPlaying?.songId == "a" }
        r.player.simulateFirstAudioForTesting()
        await waitUntil("start window closed") { !r.seq.isStartPending }
        r.seq.setStemLockForTesting(vocalsMuted)
        r.seq.setMixMode(true)
        r.seq.replanPrefetch()
        XCTAssertTrue(pf.isPlannedSong("b"), "the lane fetches the BASE cut")
        XCTAssertFalse(pf.isPlannedSong("b_explicit"))
        XCTAssertNotEqual(r.seq.mixModeBufferStrip().first?.dot, .local, "not local yet")
        r.seq.skipNext()
        await waitUntil("b resolved") { r.rips.nowPlaying?.songId == "b" }
        XCTAssertEqual(r.coord.activeBackend, .ripServer, "the base rip — never Apple Music")
        XCTAssertEqual(r.rips.nowPlaying?.url.path, "/rips/b.mp3", "the base cut's bytes")
        XCTAssertEqual(r.seq.editionSubstitution?.id, "b")
        XCTAssertNil(r.seq.editionSubstituteNote, "vocals muted: no note")
        // Phase 2 swap-on-land: the BASE cut landing is the SAME bytes this play streams.
        r.player.simulateFirstAudioForTesting()
        await waitUntil("b's start window closed") { !r.seq.isStartPending }
        let tmp = tempMP3("sl")
        try (try noise).write(to: tmp)
        XCTAssertNotNil(r.burns.adoptStreamedFile(songId: "b", title: "b", artist: "A", from: tmp, origin: .buffer))
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"), "the edition match takes the substituted base cut")
        XCTAssertTrue(r.rips.nowPlaying?.url.isFileURL ?? false)
        // Un-muting mid-track keeps the local base file; the chip notes the edition.
        r.seq.setStemLockForTesting(StemLockState(enabled: true, stemsOn: true, muted: [], volumes: [:]))
        XCTAssertEqual(r.seq.editionSubstituteNote, "Clean edition")
        XCTAssertEqual(r.rips.nowPlaying?.songId, "b")
        XCTAssertEqual(r.seq.index, 1)
    }

    /// Mix Mode on: the substituted row STARTS in the DSP on the base cut's growing file (the lock
    /// can mute its vocals) — not on Apple Music, even though its source is Apple Music.
    func testVocalsMutedSubstitutionStartsOnTheBaseGrowingFile() async throws {
        let data = try noise
        let r = try seqRig(["a"], mixDefault: false)
        r.rips.setManifest(["a": stemmed("a"), "b": stemmed("b")])
        r.coord.sourceOfSong = { $0 == "b" ? Config.appleMusicSourceName : nil }
        await startPlain(r, ["a"])
        r.seq.play([item("a"), explicitRow("b")])
        await waitUntil("a streaming") { r.rips.nowPlaying?.songId == "a" }
        r.player.simulateFirstAudioForTesting()
        await waitUntil("start window closed") { !r.seq.isStartPending }
        r.seq.setStemLockForTesting(vocalsMuted)
        r.seq.setMixMode(true)
        let file = tempMP3("rb")
        try feed(r.loader, "b", file, data, 0.95)
        XCTAssertEqual(r.seq.mixModeBufferStrip().first?.dot, .queued, "its BASE rip will buffer (the edition's isn't ripped)")
        r.seq.skipNext()
        await waitUntil("b on the base growing file") { r.seq.index == 1 && r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertEqual(r.rips.nowPlaying?.url, file)
        XCTAssertEqual(r.seq.editionSubstitution?.id, "b")
    }

    /// B: a dot is FULL only when the file the row WILL play is local — the start's own lookup
    /// (unmemoized), so a burn whose file vanished never shows full; rule A's base cut counts
    /// only while the lock mutes the vocals.
    func testBufferDotsAreEditionAwareAndMatchTheStart() async throws {
        let r = try seqRig(["a"], mixDefault: false)
        r.rips.setManifest(["a": stemmed("a"), "b": stemmed("b"), "c": stemmed("c")])
        let cuts = GrowLiveFlag()
        r.seq.prefetchedCutFile = { id in (id == "c" && cuts.on) ? URL(fileURLWithPath: "/tmp/c-cut.mp3") : nil }
        r.seq.play([item("a"), item("b"), explicitRow("c", locked: true, variant: .clean)])
        await waitUntil("a streaming") { r.rips.nowPlaying?.songId == "a" }
        r.seq.setMixMode(true)
        let tmp = tempMP3("db")
        try (try noise).write(to: tmp)
        let burned = try XCTUnwrap(r.burns.adoptStreamedFile(songId: "b", title: "b", artist: "A", from: tmp, origin: .buffer))
        XCTAssertEqual(r.seq.mixModeBufferStrip()[0].dot, .local)
        try FileManager.default.removeItem(at: burned)      // the file went away (the memo didn't)
        XCTAssertNotEqual(r.seq.mixModeBufferStrip()[0].dot, .local, "never full for a file the start can't open")
        // A clean-only row: the base cut's prefetched copy is NOT what it will play.
        cuts.on = true
        XCTAssertNotEqual(r.seq.mixModeBufferStrip()[1].dot, .local, "another edition's copy never fills the dot")
    }

    /// A rip landing for a window row re-plans the lane (its song + stems buffer next).
    func testRipLandingReplansTheLane() async throws {
        let r = try seqRig(["a", "b"], mixDefault: false)
        let pf = NowPlayingPrefetcher()
        r.seq.prefetcher = pf
        var fetchable: Set<String> = []
        r.seq.prefetchSongFetchable = { fetchable.contains($0) }
        pf.fetchSong = { _ in try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
        await startPlain(r, ["a", "x", "b"])
        r.seq.setMixMode(true)
        r.seq.replanPrefetch()
        XCTAssertFalse(pf.isPlannedSong("x"))
        r.rips.setManifest(["a": .init(key: "rips/a.mp3", source: "digital"), "b": .init(key: "rips/b.mp3", source: "digital"),
                            "x": .init(key: "rips/x.mp3", source: "digital")])
        fetchable = ["x", "b"]
        r.seq.noteRipLanded("x")
        await waitUntil("x planned") { pf.isPlannedSong("x") }
    }
}

// MARK: - FX Lock on the Mix Mode paths (growing start, Apple Music, Mix tab, swap-on-land)

extension NPMixGrowingFileTests {
    private func reverbLock(_ strength: Double = 0.6) -> FXLockState {
        FXLockState(enabled: true, effects: [MixEngine.Effect.reverb.rawValue: .init(on: true, strength: strength)])
    }

    /// The GROWING-FILE DSP start (phase 3) carries the locked effects: the next row starts in the
    /// DSP on its buffer stream with them on (ramped in), no touch.
    func testFXLockCarriesOntoTheGrowingFileStart() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        try feed(r.loader, "a", tempMP3("fxa"), data, 0.6)
        try feed(r.loader, "b", tempMP3("fxb"), data, 0.6)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        r.dsp.setEffectStrength(.reverb, 0.6)
        r.dsp.setEffect(.reverb, enabled: true)
        r.dsp.setRate(0.9)
        r.seq.setFXLock(true)
        r.seq.skipNext()
        await waitUntil("b on its growing file") { r.seq.mixEngaged && r.dsp.loadedSongId == "b" }
        XCTAssertEqual(r.seq.growingStartCount, 2)
        XCTAssertTrue(r.dsp.isStreamingMain || r.rips.nowPlaying?.url.isFileURL == true)
        XCTAssertTrue(r.dsp.isEnabled(.reverb))
        XCTAssertEqual(r.dsp.rate, 1, accuracy: 1e-9, "tempo never carries")
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)
        await waitUntil("ramp landed") { !r.dsp.effectRampInFlight }
        XCTAssertEqual(r.dsp.reverbWetDryMix, 60, accuracy: 0.01)
        XCTAssertFalse(r.dsp.reverbBypassed)
    }

    /// APPLE MUSIC ROW: the lock is kept but DORMANT on the stream ("waiting" — dry, MusicKit is
    /// out of process) and never moves the row by itself (Q1); the TOUCH hand-off brings the
    /// carried effects up on the local copy the moment the DSP owns it.
    func testFXLockWaitsOnAnAppleMusicRowThenAppliesOnTheTouchHandOff() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        r.seq.setFXLockForTesting(reverbLock())
        putOnAppleMusic(r, "a", at: 3)
        XCTAssertEqual(r.seq.fxLockIndicator, .waiting, "Apple Music: dry for now, lock kept")
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertFalse(r.dsp.isEngaged)
        XCTAssertTrue(r.dsp.isEnabled(.reverb), "the panel shows what will apply")
        try feed(r.loader, "a", tempMP3("fxam"), data, 0.95)
        r.seq.setMixMode(true)
        XCTAssertTrue(r.seq.currentTrackMixable)
        await pause(0.1)
        XCTAssertEqual(r.coord.activeBackend, .appleMusic, "the lock never cuts an Apple Music row over on its own")
        XCTAssertFalse(r.seq.mixEngaged)
        r.seq.engageMix()                                    // the touch
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertEqual(r.seq.amHandOffCount, 1)
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertTrue(r.dsp.isEnabled(.reverb))
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)
        await waitUntil("ramp landed") { !r.dsp.effectRampInFlight }
        XCTAssertEqual(r.dsp.reverbWetDryMix, 60, accuracy: 0.01)
        XCTAssertTrue(r.seq.fxLock.wantsFX, "the lock carries on")
    }

    /// MIX TAB live: one DSP surface — the engagement is torn down, the lock goes DORMANT (kept,
    /// never engaging the next row), and wakes as "waiting" once the Mix tab stops.
    func testFXLockIsDormantWhileTheMixTabIsLive() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"])
        let live = GrowLiveFlag()
        r.seq.mixSessionActive = { live.on }
        try feed(r.loader, "a", tempMP3("fxm"), data, 0.6)
        try feed(r.loader, "b", tempMP3("fxmb"), data, 0.6)
        r.seq.play([item("a"), item("b")])
        await waitUntil("a on the growing file") { r.seq.mixEngaged }
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        r.dsp.setEffect(.filter, enabled: true)
        r.seq.setFXLock(true)
        live.on = true
        await waitUntil("torn down") { !r.seq.mixEngaged }
        XCTAssertEqual(r.seq.fxLockIndicator, .dormant)
        XCTAssertFalse(r.dsp.isEngaged)
        XCTAssertTrue(r.seq.fxLock.wantsFX, "the lock is kept")
        r.seq.skipNext()
        await waitUntil("b playing") { r.rips.nowPlaying?.songId == "b" }
        await pause(0.1)
        XCTAssertFalse(r.seq.mixEngaged, "dormant: no engage under a live Mix tab")
        XCTAssertFalse(r.dsp.isPlaying, "no hidden second audio source")
        XCTAssertEqual(r.seq.fxLockIndicator, .dormant)
        live.on = false
        XCTAssertEqual(r.seq.fxLockIndicator, .waiting, "the Mix tab stopped: applies on the next DSP take-over")
        XCTAssertTrue(r.dsp.isEnabled(.filter), "…with the carried effects")
    }

    /// The Mix Mode SWAP-ON-LAND (phase 2): the playing stream's bytes land as a local file — the
    /// FX Lock takes it straight into the DSP at the same position with the carried effects.
    func testFXLockTakesTheSwapOnLandIntoTheDSP() async throws {
        let data = try noise
        let r = try seqRig(["a", "b"], mixDefault: false)
        await startPlain(r, ["a", "b"])
        r.seq.setFXLockForTesting(FXLockState(enabled: true, effects: [MixEngine.Effect.compressor.rawValue: .init(on: true, strength: 0.5)]))
        XCTAssertEqual(r.seq.fxLockIndicator, .waiting, "a plain stream: dry for now")
        r.seq.setMixMode(true)
        let tmp = tempMP3("fxland")
        try data.write(to: tmp)
        XCTAssertNotNil(r.burns.adoptStreamedFile(songId: "a", title: "a", artist: "A", from: tmp, origin: .buffer))
        r.player.clock.currentTime = 2
        XCTAssertTrue(r.seq.handOffCurrentToLocal(reason: "test"))
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged, "the lock engages the landed file at once")
        XCTAssertEqual(r.dsp.loadedSongId, "a")
        XCTAssertEqual(r.dsp.currentTime, 2, accuracy: 0.3, "same song position")
        XCTAssertTrue(r.dsp.isEnabled(.compressor))
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)
        XCTAssertEqual(r.seq.index, 0)
        XCTAssertEqual(r.seq.handOffCount, 1)
    }
}

@MainActor
@Observable
private final class GrowLiveFlag { var on = false }

/// Scripted rip server + S3: presign → an https URL, everything else → small bytes.
private final class GrowStub: URLProtocol {
    nonisolated(unsafe) static var presigns: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() { lock.lock(); presigns = [:]; lock.unlock() }
    static func presignCount(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return presigns[id] ?? 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data, json: Bool = false) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: json ? ["Content-Type": "application/json"] : nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            Self.lock.lock(); Self.presigns[song, default: 0] += 1; Self.lock.unlock()
            respond(200, Data(#"{"url":"https://s3.test/rips/\#(song).mp3?X-Amz-Signature=x"}"#.utf8), json: true)
            return
        }
        respond(200, Data("BYTES".utf8))
    }
}
