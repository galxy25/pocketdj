import AVFoundation
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
        XCTAssertEqual(GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000) ?? -1,
                       32_000, accuracy: 1)
        XCTAssertEqual(MixEngine.streamBytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000),
                       GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000))
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
