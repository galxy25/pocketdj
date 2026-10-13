import AVFoundation
import XCTest
@testable import PocketDJ

/// STEM DRIFT, everywhere a group of `AVAudioPlayerNode`s is meant to sound as one. Starting
/// several nodes with one shared HOST-time `AVAudioTime` does not start them on one sample: each
/// node converts the host time on its own (measured on the Mix branch: stem pairs a few — in the
/// simulator hundreds of — samples apart; four stems summed out of step comb-filter for the rest
/// of the song). Every site now starts its group on ONE SAMPLE FRAME (`StemSync.startTogether`).
///
/// The probe is exact and needs no audio analysis: `StemSync.startFrame(of:)` asks each node at
/// which render-timeline frame its player time 0 fell — i.e. the frame it STARTED on. Nodes
/// started together report the same number.
@MainActor
final class SyncedStartDriftTests: XCTestCase {

    private var noiseStem: Data { get throws { try StemAudioProbe.bundled("stem-noise-12s", in: Self.self) } }
    private var noiseMix: Data { get throws { try StemAudioProbe.bundled("stream-noise-12s", in: Self.self) } }

    /// Wait until every frame is known, then assert they're all ONE frame.
    private func assertOneFrame(_ what: String, _ frames: () -> [AVAudioFramePosition?],
                                count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await StemAudioProbe.wait(timeout: 3) { let f = frames(); return f.count == count && f.allSatisfy { $0 != nil } }
        let f = frames()
        XCTAssertEqual(f.count, count, "\(what): every node accounted for", file: file, line: line)
        let known = f.compactMap { $0 }
        XCTAssertEqual(known.count, count, "\(what): every node has started rendering", file: file, line: line)
        let spread = (known.max() ?? 0) - (known.min() ?? 0)
        XCTAssertEqual(spread, 0, "\(what): nodes started \(spread) samples apart — \(known)", file: file, line: line)
    }

    private func stemFiles(_ tag: String) throws -> [String: URL] {
        var out: [String: URL] = [:]
        for n in MixEngine.stemNames {
            let u = try StemAudioProbe.tempMP3(try noiseStem, tag: "\(tag)-\(n)")
            addTeardownBlock { try? FileManager.default.removeItem(at: u) }
            out[n] = u
        }
        return out
    }

    // MARK: The shared helper itself

    /// `StemSync.startTogether` on a bare engine: four nodes, one frame — repeatedly (each start
    /// lands somewhere else in the render cycle; a host-time start drifts on some of them).
    func testStartTogetherPutsEveryNodeOnOneFrame() async throws {
        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100))
        buf.frameLength = 44_100
        let nodes = (0..<4).map { _ in AVAudioPlayerNode() }
        for n in nodes { engine.attach(n); engine.connect(n, to: engine.mainMixerNode, format: fmt) }
        engine.prepare()
        do { try engine.start() } catch { throw XCTSkip("no audio device on this test host") }
        defer { engine.stop() }
        for round in 0..<5 {
            for n in nodes { n.stop(); n.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil) }
            StemSync.startTogether(nodes, lead: 0.05)
            await assertOneFrame("round \(round)", { nodes.map { StemSync.startFrame(of: $0) } }, count: 4)
            try? await Task.sleep(nanoseconds: UInt64.random(in: 3_000_000...17_000_000))
        }
    }

    // MARK: Every synced-group site

    /// SongDetail's stem audition (`StemPlayer`): Play All, a seek, and a pause→resume all start
    /// the four stems on one frame. (Before: one shared host time.)
    func testStemPlayerStartsItsFourStemsOnOneFrame() async throws {
        let p = StemPlayer()
        addTeardownBlock { @MainActor in p.stop() }
        p.load(songId: "sp1", localURLs: try stemFiles("sp1"))
        XCTAssertTrue(p.ready)
        p.playAll()
        try XCTSkipUnless(p.isPlaying, "no audio device on this test host")
        await assertOneFrame("play all", { p.startFramesForTesting() }, count: 4)
        p.seek(to: 4)
        await assertOneFrame("after a seek", { p.startFramesForTesting() }, count: 4)
        p.togglePlayPause()
        p.togglePlayPause()
        await assertOneFrame("after pause → resume", { p.startFramesForTesting() }, count: 4)
    }

    /// The stem audition skips the stems' encoder priming: a headerless part's 576 frames.
    func testStemPlayerSkipsTheStemsMp3Priming() throws {
        let p = StemPlayer()
        defer { p.stop() }
        p.load(songId: "sp2", localURLs: try stemFiles("sp2"))
        let raw = try AVAudioFile(forReading: try XCTUnwrap(stemFiles("sp2x")["vocals"]))
        XCTAssertEqual(p.duration, Double(raw.length - 576) / raw.processingFormat.sampleRate, accuracy: 1e-6,
                       "the playable length starts past the priming granule")
    }

    /// Now Playing's stems (`NowPlayingDSP`): engaged paused, stems on, resumed — the four
    /// start on one frame; and again after a pause → resume.
    func testNowPlayingStemsStartOnOneFrame() async throws {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let dir = try XCTUnwrap(burns.appBurnsDirOverride)
        for n in MixEngine.stemNames { try noiseStem.write(to: dir.appendingPathComponent("stem-npd-\(n).mp3")) }
        let dsp = NowPlayingDSP(burns: burns)
        addTeardownBlock { @MainActor in dsp.disengage() }
        let main = try StemAudioProbe.tempMP3(try noiseMix, tag: "npd")
        addTeardownBlock { try? FileManager.default.removeItem(at: main) }
        dsp.engage(url: main, startMs: nil, lengthMs: nil, atSeconds: 1, songId: "npd", play: false)
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(dsp.setStemMode(true))
        XCTAssertTrue(dsp.stemsOnAir)
        dsp.resume()
        await assertOneFrame("resume on stems", { dsp.stemStartFramesForTesting() }, count: 4)
        dsp.pause()
        dsp.resume()
        await assertOneFrame("pause → resume", { dsp.stemStartFramesForTesting() }, count: 4)
    }

    /// The Mix deck's stems (`MixEngine.startStems`, now through the shared helper): stems on a
    /// cued deck, then Play — one frame.
    func testMixDeckStemsStartOnOneFrame() async throws {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: ["mxd"], rips: rips, lengths: ["mxd": 10])
        let dir = try XCTUnwrap(burns.appBurnsDirOverride)
        for n in MixEngine.stemNames { try noiseStem.write(to: dir.appendingPathComponent("stem-mxd-\(n).mp3")) }
        let e = MixEngine(burns: burns)
        addTeardownBlock { @MainActor in e.teardown() }
        e.load(songId: "mxd", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        e.play(.a)
        await assertOneFrame("mix deck stems", { e.stemStartFramesForTesting(.a) }, count: 4)
    }

    /// The Studio step sequencer's rows (`StudioEngine.restartPatternFromTop`): every step is
    /// scheduled at a sample time on its row player's OWN timeline, so rows that start apart play
    /// every hit apart. Four sounding rows start on one frame.
    func testStudioPatternRowsStartOnOneFrame() async throws {
        let engine = StudioEngine()
        addTeardownBlock { @MainActor in engine.stopPattern(); engine.teardown() }
        let fmt = StudioAudio.canonicalFormat
        var buffers: [Int: AVAudioPCMBuffer] = [:]
        var rows: [StudioPatternRow] = []
        for i in 0..<4 {
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_410))
            b.frameLength = 4_410
            for c in 0..<Int(fmt.channelCount) {
                for k in 0..<4_410 { b.floatChannelData![c][k] = Float(sin(Double(k) * 0.05 * Double(i + 1))) * 0.2 }
            }
            buffers[i] = b
            var steps = Array(repeating: false, count: StudioPattern.defaultStepCount)
            steps[0] = true; steps[4] = true; steps[8] = true; steps[12] = true
            rows.append(StudioPatternRow(targetId: "t\(i)", steps: steps))
        }
        engine.loadPattern(StudioPattern(id: "ptn_drift", name: "D", bpm: 120, rows: rows), buffers: buffers)
        engine.startPattern()
        try XCTSkipUnless(engine.isPlayingPattern, "pattern did not start")
        await assertOneFrame("pattern rows", { engine.patternRowStartFramesForTesting() }, count: 4)
    }
}
