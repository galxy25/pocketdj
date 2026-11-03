import AVFoundation
import XCTest
@testable import PocketDJ

/// HEADERLESS DETECTION for growing mp3s — shared by the Mix deck (`MixEngine.pumpStream`) and
/// the Now Playing DSP (`NowPlayingDSP.pumpMain`) through `GrowingFileSchedule`.
///
/// An `AVAudioFile` opened on a partial mp3 reports the FULL length only when the file declares
/// it (Xing / Info / VBRI). A headerless file's open reports an ESTIMATE from the bytes present.
/// The old detector only asked "is that length implausible at 320 kbps?" — a 128 kbps
/// headerless file past ~40 % downloaded passes that test, was attached at the partial's length,
/// and the completed song "ended" early. Now the length is trusted only when a header (or an
/// agreeing ID3 TLEN) is actually in the file — and a proper CBR/VBR file with its header still
/// starts while it grows (the Phase 3 growing-start benefit).
///
/// Fixtures (lame 3.100, the same pink noise as `stream-noise-12s`, 12 s, 44.1 kHz stereo):
///  • `noise-128-headerless-12s` — `-b 128 --cbr -t` (no Info frame);
///  • `noise-128-info-12s` — `-b 128 --cbr` (LAME Info frame);
///  • `noise-vbr-xing-12s` — `-V 4` (Xing frame, ~82 kbps average);
///  • `stem-noise-12s` — 256 kbps headerless; `stream-noise-12s` — 256 kbps with Info.
/// ID3-only / ID3+TLEN variants are the headerless fixture behind a synthesized ID3v2.3 tag.
@MainActor
final class GrowingHeaderlessDetectionTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func fixture(_ name: String) throws -> Data { try StemAudioProbe.bundled(name, in: Self.self) }

    private func temp(_ tag: String, ext: String = "mp3") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-hdr-\(tag)-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An ID3v2.3 tag: a TIT2, an optional TLEN (ms), and `padding` zero bytes (cover-art-sized
    /// tags push the first frame far in).
    private func id3(tlenMs: Int? = nil, padding: Int = 2_048) -> Data {
        func frame(_ id: String, _ text: String) -> Data {
            var body = Data([0x00]); body.append(Data(text.utf8))      // ISO-8859-1
            var d = Data(id.utf8)
            let n = body.count
            d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), 0, 0])
            d.append(body)
            return d
        }
        var frames = frame("TIT2", "Noise")
        if let tlenMs { frames.append(frame("TLEN", String(tlenMs))) }
        frames.append(Data(count: padding))
        let size = frames.count
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0,
                                UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)])
        tag.append(frames)
        return tag
    }

    private struct Partial { let url: URL; let bytes: Int64; let expected: Int64 }

    /// The first `fraction` of `data` on disk.
    private func partial(_ data: Data, _ fraction: Double, tag: String) throws -> Partial {
        let n = fraction >= 1 ? data.count : Int(Double(data.count) * fraction)
        let url = temp(tag)
        try data.prefix(n).write(to: url)
        return Partial(url: url, bytes: Int64(n), expected: Int64(data.count))
    }

    /// The decision both engines make at first attach, on a real AVAudioFile open of the partial.
    private func attachRate(_ p: Partial) throws -> (bps: Double?, claim: GrowingFileSchedule.LengthClaim, seconds: Double) {
        let f = try AVAudioFile(forReading: p.url)
        let sr = f.processingFormat.sampleRate
        let claim = GrowingFileSchedule.lengthClaim(of: p.url)
        return (GrowingFileSchedule.bytesPerSecond(totalFrames: f.length, sampleRate: sr,
                                                   expectedBytes: p.expected, claim: claim),
                claim, Double(f.length) / sr)
    }

    // MARK: - 1 · The sniffer (pure)

    func testSnifferReadsEachHeaderKind() throws {
        let headerless = try fixture("noise-128-headerless-12s")
        let info = try fixture("noise-128-info-12s")
        let vbr = try fixture("noise-vbr-xing-12s")
        typealias C = GrowingFileSchedule.LengthClaim
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: headerless.prefix(20_000)), C.absent, "CBR, no header")
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: try fixture("stem-noise-12s").prefix(20_000)), C.absent)
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: info.prefix(20_000)), C.frameCount, "CBR with an Info frame")
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: try fixture("stream-noise-12s").prefix(20_000)), C.frameCount)
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: vbr.prefix(20_000)), C.frameCount, "VBR with a Xing frame")
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: id3() + headerless.prefix(20_000)), C.absent, "ID3 only: still headerless")
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: id3(tlenMs: 12_000) + headerless.prefix(20_000)), C.tlen(12_000))
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: id3(padding: 200_000) + info.prefix(20_000)), C.frameCount,
                       "a cover-art-sized tag before the Info frame")
        // Not enough bytes to decide: wait, never a verdict either way.
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: Data()), C.undetermined)
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: Data("ID".utf8)), C.undetermined)
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: id3(padding: 200_000).prefix(50_000)), C.undetermined, "inside the tag")
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: info.prefix(300)), C.undetermined, "first frame not yet verifiable")
        // A Xing tag with NO frames field / a zero count declares nothing.
        var zeroed = [UInt8](info.prefix(20_000))
        let at = try XCTUnwrap(zeroed.indices.first { Array(zeroed[$0..<min($0 + 4, zeroed.count)]) == Array("Info".utf8) })
        zeroed[at + 7] = 0                                                                  // clear the frames flag
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: Data(zeroed)), C.absent)
        // Junk / random bytes before the first frame are skipped; a non-mp3 extension defers to its container.
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(in: Data(repeating: 0, count: 700) + info.prefix(20_000)), C.frameCount)
        XCTAssertEqual(GrowingFileSchedule.lengthClaim(of: URL(fileURLWithPath: "/x/a.m4a")), C.container)
    }

    // MARK: - 2 · The attach decision on real partial opens

    /// THE BUG: 128 kbps headerless at 40 % / 70 % — the open's estimate is plausible at 320 kbps,
    /// but there is no header: hold (nil), not a song that ends at the partial's length.
    func test128kbpsHeaderlessAt40And70PercentIsProvisional() throws {
        let data = try fixture("noise-128-headerless-12s")
        for fraction in [0.4, 0.7] {
            let p = try partial(data, fraction, tag: "hl128-\(fraction)")
            let r = try attachRate(p)
            XCTAssertLessThan(r.seconds, 11, "precondition: the partial open reports an estimate (\(r.seconds)s)")
            XCTAssertGreaterThanOrEqual(r.seconds, Double(p.expected) / 41_000,
                                        "precondition: the old 320 kbps test would have trusted it")
            XCTAssertEqual(r.claim, .absent)
            XCTAssertNil(r.bps, "\(Int(fraction * 100))% of a 128 kbps headerless file: no full-length claim ⇒ hold")
        }
    }

    func testCBRWithInfoHeaderStartsWhileGrowing() throws {
        for name in ["noise-128-info-12s", "stream-noise-12s"] {
            let data = try fixture(name)
            for fraction in [0.1, 0.4, 0.7] {
                let r = try attachRate(try partial(data, fraction, tag: "\(name)-\(fraction)"))
                XCTAssertEqual(r.seconds, 12, accuracy: 0.1, "\(name): the Info frame claims the full length")
                XCTAssertEqual(r.bps ?? -1, Double(data.count) / r.seconds, accuracy: 1,
                               "\(name) at \(fraction): attaches — the growing start is kept")
            }
        }
    }

    func testVBRWithXingStartsWhileGrowing() throws {
        let data = try fixture("noise-vbr-xing-12s")
        for fraction in [0.1, 0.4, 0.7] {
            let r = try attachRate(try partial(data, fraction, tag: "vbr-\(fraction)"))
            XCTAssertEqual(r.claim, .frameCount)
            XCTAssertEqual(r.seconds, 12, accuracy: 0.1)
            XCTAssertNotNil(r.bps, "VBR+Xing at \(fraction): attaches")
        }
    }

    func testCBRWithNoHeaderIsProvisionalAtEveryFraction() throws {
        for name in ["noise-128-headerless-12s", "stem-noise-12s"] {
            let data = try fixture(name)
            for fraction in [0.1, 0.4, 0.7, 0.95] {
                let r = try attachRate(try partial(data, fraction, tag: "\(name)-\(fraction)"))
                XCTAssertNil(r.bps, "\(name) at \(fraction)")
            }
        }
    }

    func testID3OnlyIsProvisionalAndAnAgreeingTLENIsTheOnlyTagThatCounts() throws {
        let audio = try fixture("noise-128-headerless-12s")
        for fraction in [0.4, 0.7] {
            let r = try attachRate(try partial(id3() + audio, fraction, tag: "id3-\(fraction)"))
            XCTAssertEqual(r.claim, .absent)
            XCTAssertNil(r.bps, "ID3 tag but no Xing/Info at \(fraction): hold")
            // A TLEN is sniffed, but Core Audio ignores it — the open is still an estimate: hold.
            let t = try attachRate(try partial(id3(tlenMs: 12_000) + audio, fraction, tag: "tlen-\(fraction)"))
            XCTAssertEqual(t.claim, .tlen(12_000))
            XCTAssertLessThan(t.seconds, 11, "precondition: the open ignores TLEN (\(t.seconds)s)")
            XCTAssertNil(t.bps, "ID3 TLEN alone at \(fraction): hold")
        }
        // Even at 95 % (the estimate is within a second of TLEN) it is not trusted — that is
        // where a tolerance would truncate the song.
        let late = try attachRate(try partial(id3(tlenMs: 12_000) + audio, 0.95, tag: "tlen95"))
        XCTAssertNil(late.bps, "95 %: \(late.seconds)s is still an estimate")
        XCTAssertNil(GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100,
                                                        expectedBytes: 200_000, claim: .tlen(12_000)))
        // Header + ID3 together: the header wins.
        let info = try fixture("noise-128-info-12s")
        let both = try attachRate(try partial(id3(tlenMs: 99_000) + info, 0.4, tag: "id3info"))
        XCTAssertEqual(both.claim, .frameCount)
        XCTAssertNotNil(both.bps)
    }

    func testCompleteHeaderlessFileStillPlaysAndUndeterminedNeverClaims() {
        // A complete file never needs a claim (the frontier is the whole window) — undetermined /
        // absent only ever mean "hold", never a rate.
        XCTAssertNil(GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 200_000, claim: .undetermined))
        XCTAssertNil(GrowingFileSchedule.bytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: nil, claim: .absent))
        XCTAssertEqual(GrowingFileSchedule.frontier(bytes: 1, complete: true, bytesPerSecond: nil, sampleRate: 44_100,
                                                    start: 0, fullEnd: 529_200), 529_200)
    }

    // MARK: - 3 · Both engines, end to end

    private func rips() -> RipsStore {
        let r = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: .ephemeral))
        r.setManifest(["m1": .init(key: "rips/m1.mp3", source: "digital"), "n1": .init(key: "rips/n1.mp3", source: "digital"),
                       "m2": .init(key: "rips/m2.mp3", source: "digital"), "n2": .init(key: "rips/n2.mp3", source: "digital")])
        return r
    }

    /// MIX DECK: 128 kbps headerless at 40 % and 70 % stays unattached on the provisional catalog
    /// length (Buffering…) — then plays the WHOLE song once complete.
    func testMixDeck128kbpsHeaderlessHoldsUntilComplete() async throws {
        let data = try fixture("noise-128-headerless-12s")
        let rips = rips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        defer { engine.teardown() }
        let file = temp("mix128")
        func feed(_ fraction: Double, finished: Bool = false) throws {
            let n = finished ? data.count : Int(Double(data.count) * fraction)
            try data.prefix(n).write(to: file)
            loader.injectStreamForTesting(songId: "m1", file: file, bytes: Int64(n), expected: Int64(data.count), finished: finished)
        }
        try feed(0.4)
        engine.load(songId: "m1", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, lengthMs: 30_000, on: .a)
        engine.play(.a)
        XCTAssertTrue(engine.isBuffering(.a), "40 %: no header ⇒ held")
        XCTAssertFalse(engine.fileScheduledForTesting(.a))
        XCTAssertEqual(engine.duration(.a), 30, accuracy: 0.01, "the catalog length stays provisional")
        try feed(0.7)
        XCTAssertTrue(engine.isBuffering(.a), "70 %: still held")
        XCTAssertFalse(engine.fileScheduledForTesting(.a))
        XCTAssertEqual(engine.duration(.a), 30, accuracy: 0.01)
        try feed(1, finished: true)
        XCTAssertFalse(engine.isBuffering(.a))
        XCTAssertEqual(engine.duration(.a), 12, accuracy: 0.2, "the whole song")
        XCTAssertEqual(engine.scheduledEndSecondsForTesting(.a) ?? 0, 12, accuracy: 0.2)
    }

    /// MIX DECK: a 128 kbps CBR WITH an Info frame still attaches at 40 % and starts growing.
    func testMixDeck128kbpsInfoStartsWhileGrowing() async throws {
        let data = try fixture("noise-128-info-12s")
        let rips = rips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        defer { engine.teardown() }
        let file = temp("mixinfo")
        let n = Int(Double(data.count) * 0.4)
        try data.prefix(n).write(to: file)
        loader.injectStreamForTesting(songId: "m2", file: file, bytes: Int64(n), expected: Int64(data.count))
        engine.load(songId: "m2", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, lengthMs: 30_000, on: .a)
        engine.play(.a)
        XCTAssertEqual(engine.duration(.a), 12, accuracy: 0.1, "the header's length replaced the catalog guess")
        XCTAssertTrue(engine.fileScheduledForTesting(.a), "40 % with an Info header: playing while it grows")
        XCTAssertTrue(engine.isStreaming(.a))
    }

    private func dsp() throws -> (NowPlayingDSP, MixStreamLoader) {
        let rips = rips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let dsp = NowPlayingDSP(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        dsp.streamer = loader
        addTeardownBlock { @MainActor in dsp.disengage() }
        return (dsp, loader)
    }

    /// NOW PLAYING DSP: the same 128 kbps headerless file holds at 40 % and 70 %, then plays the
    /// whole song (seekable to 9 s) once complete.
    func testNowPlaying128kbpsHeaderlessHoldsUntilComplete() async throws {
        let data = try fixture("noise-128-headerless-12s")
        let (dsp, loader) = try dsp()
        let file = temp("np128")
        func feed(_ fraction: Double, finished: Bool = false) throws -> MixStreamLoader.Stream {
            let n = finished ? data.count : Int(Double(data.count) * fraction)
            try data.prefix(n).write(to: file)
            return loader.injectStreamForTesting(songId: "n1", file: file, bytes: Int64(n), expected: Int64(data.count),
                                                 adoptable: false, finished: finished, origin: .buffer)
        }
        var ends = 0
        dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(dsp.engageStreaming(try feed(0.4), lengthMs: 30_000, atSeconds: 0, songId: "n1", play: true))
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(dsp.isBuffering, "40 %: held")
        XCTAssertEqual(dsp.duration, 30, accuracy: 0.01, "provisional catalog length kept")
        _ = try feed(0.7)
        XCTAssertTrue(dsp.isBuffering, "70 %: held")
        XCTAssertFalse(dsp.mainNodePlayingForTesting())
        XCTAssertEqual(dsp.duration, 30, accuracy: 0.01)
        _ = try feed(1, finished: true)
        XCTAssertFalse(dsp.isBuffering)
        XCTAssertEqual(dsp.duration, 12, accuracy: 0.2, "the whole song — not the 70 % estimate")
        dsp.seek(toSongSeconds: 9)
        let deadline = Date().addingTimeInterval(5)
        while dsp.currentTime <= 9.2 && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThan(dsp.currentTime, 9.2, "renders past where the partial would have ended")
        XCTAssertEqual(ends, 0)
    }

    /// NOW PLAYING DSP: a VBR file with a Xing frame starts at 40 % (growing start kept).
    func testNowPlayingVBRXingStartsWhileGrowing() async throws {
        let data = try fixture("noise-vbr-xing-12s")
        let (dsp, loader) = try dsp()
        let file = temp("npvbr")
        let n = Int(Double(data.count) * 0.4)
        try data.prefix(n).write(to: file)
        let s = loader.injectStreamForTesting(songId: "n2", file: file, bytes: Int64(n), expected: Int64(data.count),
                                              adoptable: false, finished: false, origin: .buffer)
        XCTAssertTrue(dsp.engageStreaming(s, lengthMs: 30_000, atSeconds: 0, songId: "n2", play: true))
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertEqual(dsp.duration, 12, accuracy: 0.1, "the Xing frame's length")
        XCTAssertFalse(dsp.isBuffering, "4.8 s present ⇒ 3.3 s runway: it starts")
    }
}
