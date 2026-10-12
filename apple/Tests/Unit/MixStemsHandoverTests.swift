import Accelerate
import AVFoundation
import XCTest
@testable import PocketDJ

/// ZERO DEAD AIR across the Mix deck's full-mix ↔ stems handover (field bug: streamed a mix,
/// turned stems on, the deck went silent). Every scenario runs on a real `AVAudioEngine` and
/// listens to the deck's pre-fader tap, so "audio continues" means real samples reached the
/// deck's output — not just a flag. Stems are the real LAME mp3 fixture under `stem-<id>-*.mp3`
/// names (AVAudioFile picks its decoder from the EXTENSION — a WAV can't stand in), written
/// progressively where a scenario streams them.
@MainActor
final class MixStemsHandoverTests: XCTestCase {

    // MARK: Fixtures

    private var fixture: Data { get throws { try bundled("stream-tone-12s") } }
    /// NON-PERIODIC content for the sample-resolution probes (a tone can't show misalignment):
    /// 12 s of pink noise as a TAGGED LAME mp3 (the full mix — a rip/burn always carries the
    /// Xing/Info gapless header) and the same noise at ¼ level, HEADERLESS (`lame -t`), exactly
    /// like a real Demucs stem part (lameenc writes no tag) — so four parts sum back to the mix
    /// and decode one 576-sample priming granule late, as real stems do.
    private var noiseMix: Data { get throws { try bundled("stream-noise-12s") } }
    private var noiseStem: Data { get throws { try bundled("stem-noise-12s") } }

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp3"))
        return try Data(contentsOf: url)
    }

    private func tempFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-stemho-\(name)-\(UUID().uuidString).mp3")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Rig {
        let engine: MixEngine
        let burns: BurnStore
        let loader: MixStreamLoader?
        let burnDir: URL
    }

    /// An engine over a hermetic burn store; `streaming` wires a stub-less stream loader (streams
    /// are injected, never fetched).
    private func rig(burned ids: [String] = [], lengths: [String: Double] = [:], streaming: Bool = true) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: ids, rips: rips, lengths: lengths)
        let engine = MixEngine(burns: burns)
        var loader: MixStreamLoader?
        if streaming {
            let l = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
            l.onProgress = { [weak engine] in engine?.streamProgressed($0) }
            engine.streamer = l
            loader = l
        }
        addTeardownBlock { engine.teardown() }
        return Rig(engine: engine, burns: burns, loader: loader, burnDir: try XCTUnwrap(burns.appBurnsDirOverride))
    }

    /// Burn complete stems for `songId` (the 12 s fixture as every part, or `data`).
    private func burnStems(_ rig: Rig, _ songId: String, data: Data? = nil) throws {
        let data = try data ?? fixture
        for n in MixEngine.stemNames {
            try data.write(to: rig.burnDir.appendingPathComponent("stem-\(songId)-\(n).mp3"))
        }
    }

    /// Stream `songId` onto `deck` from a growing file holding `fraction` of the fixture (or `data`).
    @discardableResult
    private func loadStreaming(_ rig: Rig, _ songId: String, fraction: Double, on deck: MixEngine.Deck = .a,
                               data: Data? = nil) throws -> URL {
        let data = try data ?? fixture
        let file = tempFile(songId)
        let n = min(data.count, Int(Double(data.count) * fraction))
        try data.prefix(n).write(to: file)
        try XCTUnwrap(rig.loader).injectStreamForTesting(songId: songId, file: file, bytes: Int64(n),
                                                         expected: Int64(data.count), finished: n == data.count)
        rig.engine.load(songId: songId, title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil,
                        albumId: nil, lengthMs: 12_000, on: deck)
        return file
    }

    /// Grow (or complete) an injected song stream.
    private func growStream(_ rig: Rig, _ songId: String, file: URL, fraction: Double, data: Data? = nil) throws {
        let data = try data ?? fixture
        let n = min(data.count, Int(Double(data.count) * fraction))
        try grow(file, to: data.prefix(n))
        try XCTUnwrap(rig.loader).injectStreamForTesting(songId: songId, file: file, bytes: Int64(n),
                                                         expected: Int64(data.count), finished: n == data.count)
    }

    /// Grow a streamed file to `bytes` the way the loader's sink does — APPENDING (a deck's open
    /// `AVAudioFile` reads it meanwhile; rewriting it would truncate it under the reader).
    private func grow(_ url: URL, to bytes: Data) throws {
        let have = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let have, have > 0, have <= bytes.count else { return try bytes.write(to: url) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: bytes.suffix(from: bytes.startIndex + have))
    }

    /// Stream `songId`'s 4 stems with `fraction` of each part on disk; returns the part files.
    @discardableResult
    private func streamStems(_ rig: Rig, _ songId: String, fraction: Double,
                             files: [String: URL]? = nil, data: Data? = nil) throws -> [String: URL] {
        let data = try data ?? fixture
        let n = min(data.count, Int(Double(data.count) * fraction))
        var out: [String: URL] = files ?? [:]
        var bytes: [String: Int64] = [:]
        for name in MixEngine.stemNames {
            let url = out[name] ?? tempFile("\(songId)-\(name)")
            try grow(url, to: data.prefix(n))
            out[name] = url
            bytes[name] = Int64(n)
        }
        try XCTUnwrap(rig.loader).injectStemsForTesting(songId: songId, files: out, bytes: bytes,
                                                        expected: Int64(data.count), finished: n == data.count)
        return out
    }

    private func wait(timeout: TimeInterval = 5, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Real signal on the deck's pre-fader tap within `within` seconds of resetting it.
    private func audible(_ engine: MixEngine, _ deck: MixEngine.Deck = .a, within: TimeInterval = 1.5) async -> Bool {
        let lv = engine.levels(deck)
        lv.prePeak = 0
        await wait(timeout: within) { lv.prePeak > 0.01 }
        return lv.prePeak > 0.01
    }

    /// No dead air: every ~0.25 s window over `seconds` carries signal. Returns the silent windows.
    private func silentWindows(_ engine: MixEngine, _ deck: MixEngine.Deck = .a, over seconds: Double) async -> Int {
        var silent = 0
        let windows = max(1, Int(seconds / 0.25))
        for _ in 0..<windows where !(await audible(engine, deck, within: 0.25)) { silent += 1 }
        return silent
    }

    /// Engine render needs a moment after the first play before the tap carries signal.
    private func playAndSettle(_ engine: MixEngine, _ deck: MixEngine.Deck = .a) async {
        engine.play(deck)
        let ok = await audible(engine, deck, within: 3)
        XCTAssertTrue(ok, "precondition: the deck is audibly playing its full mix")
    }

    // MARK: 1 — pure decisions

    func testHandoverReadinessNeedsRunwayOnlyWhileStillArriving() {
        XCTAssertTrue(MixEngine.handoverReady(runway: 0.3, complete: true, songLeft: 100),
                      "a complete source need only cover the playhead")
        XCTAssertFalse(MixEngine.handoverReady(runway: 0.01, complete: true, songLeft: 100),
                       "…but must cover it")
        XCTAssertFalse(MixEngine.handoverReady(runway: 3, complete: false, songLeft: 100),
                       "a still-arriving source needs the full runway")
        XCTAssertTrue(MixEngine.handoverReady(runway: 4, complete: false, songLeft: 100))
        XCTAssertTrue(MixEngine.handoverReady(runway: 2.5, complete: false, songLeft: 2.5),
                      "near the song's end, what's left of it is enough")
    }

    func testStemPlayableSecondsTrustsBytesNotAHeaderClaim() {
        // A partial part whose open claims the whole 12 s (a header) but has 3 s of bytes at
        // 32 KB/s ⇒ 3 s − the 1.5 s torn-frame margin.
        XCTAssertEqual(MixEngine.stemPlayableSeconds(lengthSeconds: 12, bytes: 96_000, expectedBytes: 384_000,
                                                     songSeconds: 12, complete: false), 1.5, accuracy: 0.001)
        // Headerless (an open reports only what's present): the shorter of the two wins.
        XCTAssertEqual(MixEngine.stemPlayableSeconds(lengthSeconds: 2, bytes: 96_000, expectedBytes: 384_000,
                                                     songSeconds: 12, complete: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(MixEngine.stemPlayableSeconds(lengthSeconds: 12, bytes: 0, expectedBytes: nil,
                                                     songSeconds: 12, complete: true), 12, "complete ⇒ its length")
    }

    func testStemPartKeysRoundTripToTheirSong() {
        let key = MixStreamLoader.stemKey("sng_1", "vocals")
        XCTAssertEqual(MixStreamLoader.stemSongId(fromKey: key), "sng_1")
        XCTAssertNil(MixStreamLoader.stemSongId(fromKey: "sng_1"), "a song key is not a stem key")
    }

    /// The instrument itself: the tap probe must SEE dead air, or every "zero dead air" assertion
    /// below would pass vacuously.
    func testSilenceProbeDetectsAStoppedDeck() async throws {
        let rig = try rig(burned: ["pr"], lengths: ["pr": 10], streaming: false)
        let e = rig.engine
        e.load(songId: "pr", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        await playAndSettle(e)
        let live = await silentWindows(e, over: 0.5)
        XCTAssertEqual(live, 0)
        e.pause(.a)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let dead = await silentWindows(e, over: 0.5)
        XCTAssertGreaterThan(dead, 0, "a paused deck reads as silent")
    }

    // MARK: 2 — the field bug: stems on a STREAMING deck

    /// The user's report, end to end: a deck is playing a song that is still downloading, the
    /// stems are NOT on disk and arrive by streaming. Asking for them keeps the full mix on air
    /// ("Loading stems…") until the stems have runway, then hands over — with sound the whole way.
    func testStemsOnWhileStreamingKeepsFullMixThenHandsOverOnceBuffered() async throws {
        let rig = try rig()
        let e = rig.engine
        try loadStreaming(rig, "sw", fraction: 0.5)
        let parts = try streamStems(rig, "sw", fraction: 0.03)      // ~0.4 s per part — not enough
        await playAndSettle(e)

        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemModeOn(.a), "the request is the user's intent — the button lights")
        XCTAssertEqual(e.stemHandover(.a), .toStems, "pending: Loading stems…")
        XCTAssertFalse(e.stemActive(.a), "no runway yet — the stems must NOT take the deck")
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a), "the full mix keeps playing")
        let silentWhilePending = await silentWindows(e, over: 1.0)
        XCTAssertEqual(silentWhilePending, 0, "zero dead air while the stems load")

        try streamStems(rig, "sw", fraction: 0.8, files: parts)      // ~9.6 s ⇒ >4 s runway
        XCTAssertTrue(e.stemActive(.a), "runway arrived — the stems take over")
        XCTAssertNil(e.stemHandover(.a))
        XCTAssertTrue(e.stemNodesPlayingForTesting(.a))
        let silentAcross = await silentWindows(e, over: 1.0)
        XCTAssertEqual(silentAcross, 0, "zero dead air across the handover")
        await wait { !e.stemFadeInFlightForTesting(.a) }
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.a), "the crossfade landed: the full mix is retired")
        XCTAssertTrue(e.stemNodesPlayingForTesting(.a))
    }

    /// Stems ON while the full mix is HELD waiting for bytes (Buffering…): the stems ARE playable
    /// audio, so they carry the deck — un-held, playhead running. (Before: stems started but the
    /// deck stayed "held": Buffering… on screen, the playhead frozen, heal/resume skipping it.)
    func testStemsRescueAHeldStreamingDeck() async throws {
        let rig = try rig()
        let e = rig.engine
        try burnStems(rig, "hd")
        try loadStreaming(rig, "hd", fraction: 0.34)
        await playAndSettle(e)
        e.seek(.a, toSeconds: 8)                                     // past the download → held
        XCTAssertTrue(e.isBuffering(.a))

        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        XCTAssertFalse(e.isBuffering(.a), "the stems carry the deck — no longer buffering")
        let ok = await audible(e)
        XCTAssertTrue(ok)
        await wait { e.position(.a) > 8.3 }
        XCTAssertGreaterThan(e.position(.a), 8.3, "the playhead runs on the stems")
    }

    /// Stems OFF on a streaming deck whose playhead is PAST the full mix's download: the stems
    /// stay on air until the full mix has runway there. (Before: the stems stopped and the full
    /// mix scheduled zero frames — silence until ≥4 s more bytes arrived.)
    func testStemsOffWaitsForTheFullMixToReachThePlayhead() async throws {
        let rig = try rig()
        let e = rig.engine
        try burnStems(rig, "so")
        let file = try loadStreaming(rig, "so", fraction: 0.34)      // ~2.5 s schedulable
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        await wait { !e.stemFadeInFlightForTesting(.a) }
        e.seek(.a, toSeconds: 7)                                     // complete stems: fine there

        e.setStemMode(false, on: .a)
        XCTAssertFalse(e.stemModeOn(.a), "intent: full mix")
        XCTAssertEqual(e.stemHandover(.a), .toFullMix, "pending until the full mix reaches 7 s")
        XCTAssertTrue(e.stemActive(.a), "the stems keep the deck")
        XCTAssertFalse(e.isBuffering(.a))
        let silent = await silentWindows(e, over: 1.0)
        XCTAssertEqual(silent, 0, "zero dead air while the full mix catches up")

        try growStream(rig, "so", file: file, fraction: 1)
        XCTAssertFalse(e.stemActive(.a), "the full mix has the bytes — it takes the deck back")
        XCTAssertNil(e.stemHandover(.a))
        await wait { !e.stemFadeInFlightForTesting(.a) }
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        XCTAssertFalse(e.stemNodesPlayingForTesting(.a))
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    // MARK: 3 — stems that never come

    /// A song with no stems anywhere (fetch fails): the request drops and the full mix — which
    /// never stopped — just carries on.
    func testStemsUnavailableKeepsTheFullMix() async throws {
        let rig = try rig(burned: ["nx"], lengths: ["nx": 10], streaming: false)
        let e = rig.engine
        var release: CheckedContinuation<Void, Never>?
        e.stemFetcher = { _ in
            await withCheckedContinuation { release = $0 }
            return false
        }
        e.load(songId: "nx", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        await playAndSettle(e)

        e.setStemMode(true, on: .a)
        XCTAssertEqual(e.stemHandover(.a), .toStems)
        XCTAssertTrue(e.stemFetchPendingForTesting(.a))
        let silent = await silentWindows(e, over: 0.75)
        XCTAssertEqual(silent, 0, "the full mix plays while the fetch runs")
        release?.resume()
        await wait { e.stemHandover(.a) == nil }
        XCTAssertNil(e.stemHandover(.a), "nothing to hand over to — the request drops")
        XCTAssertFalse(e.stemModeOn(.a))
        XCTAssertFalse(e.stemActive(.a))
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a), "the full mix never stopped")
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    /// A stem STREAM that dies mid-load: same — the full mix stays.
    func testStemStreamFailureMidLoadKeepsTheFullMix() async throws {
        let rig = try rig()
        let e = rig.engine
        try loadStreaming(rig, "sf", fraction: 0.5)
        try streamStems(rig, "sf", fraction: 0.03)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertEqual(e.stemHandover(.a), .toStems)

        try XCTUnwrap(rig.loader).failStemsForTesting("sf")
        XCTAssertNil(e.stemHandover(.a))
        XCTAssertFalse(e.stemActive(.a))
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    // MARK: 4 — cancellation + generations

    /// Toggling OFF while the stems load cancels the request: the stems landing later never
    /// take the deck.
    func testToggleOffMidPendingNeverSwitches() async throws {
        let rig = try rig()
        let e = rig.engine
        try loadStreaming(rig, "tg", fraction: 0.5)
        let parts = try streamStems(rig, "tg", fraction: 0.03)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertEqual(e.stemHandover(.a), .toStems)

        e.setStemMode(false, on: .a)
        XCTAssertNil(e.stemHandover(.a), "cancelled")
        XCTAssertFalse(e.stemModeOn(.a))
        try streamStems(rig, "tg", fraction: 1, files: parts)        // the stems land anyway
        XCTAssertFalse(e.stemActive(.a), "a cancelled request never claims the deck")
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    /// Hammer the toggle on a PLAYING deck with stems on disk — every flip a live crossfade
    /// superseding the last. The deck ends on exactly the voice the LAST tap asked for, with
    /// one voice rendering and no dead air at any point.
    func testRapidTogglesLandOnTheLastIntentWithoutDeadAir() async throws {
        let rig = try rig(burned: ["rt"], lengths: ["rt": 12], streaming: false)
        let e = rig.engine
        try burnStems(rig, "rt")
        e.load(songId: "rt", title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        await playAndSettle(e)

        for i in 0..<7 {
            e.setStemMode(i % 2 == 0, on: .a)                       // on, off, on, … on
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...40_000_000))
        }
        let silent = await silentWindows(e, over: 1.0)
        XCTAssertEqual(silent, 0, "no dead air through the toggling")
        await wait { !e.stemFadeInFlightForTesting(.a) }
        XCTAssertTrue(e.stemModeOn(.a))
        XCTAssertTrue(e.stemActive(.a), "the last tap asked for stems")
        XCTAssertNil(e.stemHandover(.a))
        XCTAssertTrue(e.stemNodesPlayingForTesting(.a))
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.a), "exactly one voice renders")

        e.setStemMode(false, on: .a)
        e.setStemMode(true, on: .a)
        e.setStemMode(false, on: .a)
        await wait { !e.stemFadeInFlightForTesting(.a) }
        XCTAssertFalse(e.stemActive(.a))
        XCTAssertTrue(e.playerNodeIsPlayingForTesting(.a))
        XCTAssertFalse(e.stemNodesPlayingForTesting(.a))
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    /// A NEW TRACK while stems are being fetched: the fetch's late completion is stale — it
    /// must not put the new track into stem mode, even when the new track's stems are on disk.
    /// (Before: the Mix button's burn task called `setStemMode(true)` on whatever the deck held.)
    func testTrackChangeMidPendingDropsTheRequest() async throws {
        let rig = try rig(burned: ["t1", "t2"], lengths: ["t1": 10, "t2": 10], streaming: false)
        let e = rig.engine
        var release: CheckedContinuation<Void, Never>?
        e.stemFetcher = { _ in
            await withCheckedContinuation { release = $0 }
            return true
        }
        e.load(songId: "t1", title: "T1", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertEqual(e.stemHandover(.a), .toStems)

        e.load(songId: "t2", title: "T2", artist: "A", bpm: 120, camelot: "8A", key: nil, albumId: nil, on: .a)
        XCTAssertNil(e.stemHandover(.a), "a new track drops the old track's request")
        XCTAssertFalse(e.stemModeOn(.a))
        try burnStems(rig, "t1")
        try burnStems(rig, "t2")
        release?.resume()                                            // the stale fetch "succeeds"
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(e.stemActive(.a), "a superseded fetch never claims the deck")
        XCTAssertFalse(e.stemModeOn(.a))
        XCTAssertEqual(e.loaded(.a)?.songId, "t2")
    }

    // MARK: 5 — streaming stems running dry

    /// Partial stems ON AIR whose stream stalls: before they run out, the deck hands back to the
    /// full mix (which has the bytes) — and takes the stems again once they have runway.
    func testStemUnderrunHandsBackToTheFullMixThenReengages() async throws {
        let rig = try rig()
        let e = rig.engine
        let main = try loadStreaming(rig, "ud", fraction: 0.5)
        try growStream(rig, "ud", file: main, fraction: 1)           // the full mix is all there
        let parts = try streamStems(rig, "ud", fraction: 0.55)       // ~5 s of stems
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a), "≥4 s of runway at 0:00 — on stems")
        let end = try XCTUnwrap(e.stemEndSecondsForTesting(.a))
        XCTAssertLessThan(end, 6, "only the streamed part is scheduled")

        // The stem stream stalls; the playhead closes on its frontier.
        await wait(timeout: end + 2) { !e.stemActive(.a) }
        XCTAssertFalse(e.stemActive(.a), "handed back BEFORE the stems ran dry")
        XCTAssertLessThan(e.position(.a), end, "…while the stems still had audio")
        XCTAssertEqual(e.stemHandover(.a), .toStems, "the stems are still wanted")
        let silent = await silentWindows(e, over: 0.75)
        XCTAssertEqual(silent, 0, "zero dead air on the full mix")

        try streamStems(rig, "ud", fraction: 1, files: parts)        // the stems finish
        XCTAssertTrue(e.stemActive(.a), "re-engaged once they had runway")
        XCTAssertNil(e.stemHandover(.a))
        let ok = await audible(e)
        XCTAssertTrue(ok)
    }

    // MARK: Sample-resolution probes

    /// The deck's raw signal (`MixDeckCapture`) until `seconds` more of it has arrived.
    private func capture(_ cap: MixDeckCapture, atLeast seconds: Double) async {
        let target = cap.count + Int(seconds * 44_100)
        await wait(timeout: seconds + 3) { cap.count >= target }
    }

    /// Channel 0 of `data` decoded by Core Audio (a TAGGED mp3 decodes song-time aligned).
    private func decoded(_ data: Data) throws -> [Float] {
        let url = tempFile("src")
        try data.write(to: url)
        let f = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// The longest run of consecutive near-zero samples — dead air at SAMPLE resolution.
    private func longestSilence(_ y: [Float], threshold: Float = 1e-4) -> Int {
        var best = 0, run = 0
        for v in y {
            if abs(v) < threshold { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }

    /// Where in `src` each `block`-sample block of `y` matches best: that source offset minus the
    /// block's own offset (CONSTANT ⇔ `y` is one continuous, sample-aligned read of the source),
    /// and the match's normalized correlation. The first block searches the whole source; each
    /// later one ±`search` around its predecessor (wide enough to catch a priming-sized slip).
    private func blockLags(_ y: [Float], _ src: [Float], block: Int = 1024, search: Int = 1500) -> [(lag: Int, corr: Float)] {
        var out: [(lag: Int, corr: Float)] = []
        guard y.count >= block, src.count >= block else { return out }
        y.withUnsafeBufferPointer { yp in
            src.withUnsafeBufferPointer { sp in
                guard let yb0 = yp.baseAddress, let sb = sp.baseAddress else { return }
                var prev: Int?
                var b = 0
                while b + block <= y.count {
                    let yb = yb0 + b
                    var ey: Float = 0
                    vDSP_svesq(yb, 1, &ey, vDSP_Length(block))
                    let lo = prev.map { max(0, b + $0 - search) } ?? 0
                    let hi = prev.map { min(src.count - block, b + $0 + search) } ?? (src.count - block)
                    var best = (s: lo, c: -Float.infinity)
                    if hi >= lo {
                        for s in lo...hi {
                            var d: Float = 0, es: Float = 0
                            vDSP_dotpr(yb, 1, sb + s, 1, &d, vDSP_Length(block))
                            vDSP_svesq(sb + s, 1, &es, vDSP_Length(block))
                            let c = d / max(1e-12, (ey * es).squareRoot())
                            if c > best.c { best = (s, c) }
                        }
                    }
                    out.append((best.s - b, best.c))
                    prev = best.s - b
                    b += block
                }
            }
        }
        return out
    }

    /// A capture begun just after a SEEK, minus its first 0.25 s: the tap still delivers audio
    /// rendered before the seek (and the seek's own restart — a user's stop/start, not an engine
    /// handover), which isn't what the probe is judging.
    private func settledAfterSeek(_ y: [Float]) -> [Float] { Array(y.dropFirst(11_025)) }

    /// `y` is ONE continuous, sample-aligned read of `src` — every block at the same source offset
    /// (±2 samples) with a near-perfect match — and carries no dead air longer than 2 ms. A
    /// handover that replays or skips audio shows as an offset jump, two voices out of step as a
    /// weak match (a flam), a stop/start as a silent run.
    private func assertSeamless(_ y: [Float], against src: [Float], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(y.count, 22_050, "\(what): captured too little", file: file, line: line)
        let gap = longestSilence(y)
        XCTAssertLessThan(gap, 88, "\(what): \(gap) samples (\(gap * 1000 / 44_100) ms) of dead air", file: file, line: line)
        let lags = blockLags(y, src)
        guard let first = lags.first else { return XCTFail("\(what): nothing to align", file: file, line: line) }
        let slips = lags.enumerated().filter { abs($0.element.lag - first.lag) > 2 }
        XCTAssertTrue(slips.isEmpty, "\(what): the source offset slips at block(s) "
                      + "\(slips.prefix(4).map { "\($0.offset):\($0.element.lag - first.lag)" }) — audio replayed/skipped",
                      file: file, line: line)
        let worst = lags.map(\.corr).min() ?? 0
        XCTAssertGreaterThan(worst, 0.95, "\(what): a block matches the source only at \(worst) — voices out of step",
                             file: file, line: line)
    }

    // MARK: 6 — encoder priming (sample alignment)

    /// The stems' priming is read off the file: a headerless LAME frame ⇒ one 576-sample granule;
    /// a tagged one (Xing/Info) ⇒ 0 — also behind an ID3v2 tag, as a rip's file is.
    func testMp3PrimingIsReadFromTheFirstFrame() throws {
        XCTAssertEqual(MixEngine.mp3PrimingFrames(header: try noiseStem), 576, "headerless stem part")
        XCTAssertEqual(MixEngine.mp3PrimingFrames(header: try noiseMix), 0, "tagged full mix")
        // A 32-byte ID3v2.3 tag (syncsafe size 22) ahead of the audio.
        var id3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 22])
        id3.append(Data(repeating: 0, count: 22))
        XCTAssertEqual(MixEngine.mp3PrimingFrames(header: id3 + (try noiseMix)), 0, "ID3 + tagged")
        XCTAssertEqual(MixEngine.mp3PrimingFrames(header: id3 + (try noiseStem)), 576, "ID3 + headerless")
        XCTAssertEqual(MixEngine.mp3PrimingFrames(header: Data(repeating: 0, count: 4096)), 0, "not an mp3")
    }

    /// Pin the constant to Core Audio itself: the headerless part decodes EXACTLY the priming
    /// late against the tagged mix (the field measurement on real stem sets: 576 samples, r≈0.9998).
    func testCoreAudioDecodesAHeaderlessStemOneGranuleLate() throws {
        let mix = try decoded(try noiseMix)
        let stem = try decoded(try noiseStem)
        let probe = Array(mix[88_200..<(88_200 + 4096)])          // 2 s in
        let lags = blockLags(probe, stem, block: 4096)
        let match = try XCTUnwrap(lags.first)
        let late = match.lag - 88_200                              // stem frame of song frame 88 200
        XCTAssertEqual(late, 576, "stem frame = song frame + 576")
        XCTAssertGreaterThan(match.corr, 0.99)
        XCTAssertEqual(Int(MixEngine.mp3PrimingFrames(header: try noiseStem)), late)
    }

    /// The handover itself, both ways, at sample resolution: full mix → stems → full mix on a
    /// playing deck is one continuous read of the song — no replayed/skipped sliver at either
    /// switch (the stems' priming is compensated), no flam in the crossfade, no dead air.
    func testHandoverIsSampleAlignedAndGaplessBothWays() async throws {
        let rig = try rig()
        let e = rig.engine
        let mix = try noiseMix
        try burnStems(rig, "al", data: try noiseStem)
        try loadStreaming(rig, "al", fraction: 1, data: mix)        // complete full mix
        await playAndSettle(e)
        let cap = e.captureForTesting(.a)
        cap.start()
        await capture(cap, atLeast: 0.4)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        XCTAssertEqual(e.stemPrimeFramesForTesting(.a), 576, "headerless stems: priming compensated")
        await wait { !e.stemFadeInFlightForTesting(.a) }
        await capture(cap, atLeast: 0.4)
        e.setStemMode(false, on: .a)
        XCTAssertFalse(e.stemActive(.a))
        await wait { !e.stemFadeInFlightForTesting(.a) }
        await capture(cap, atLeast: 0.4)
        let y = cap.stop()
        assertSeamless(y, against: try decoded(mix), "full mix → stems → full mix")
    }

    /// The four stem nodes start on ONE sample frame: every pair (vocals + one other, the rest
    /// muted) is a single coherent read of the song. (Before: a host-time start, which each node
    /// converts on its own — pairs landed samples, sometimes hundreds of samples, apart: four
    /// copies summed out of step comb-filter for the rest of the song.)
    func testFourStemNodesStartOnOneSampleFrame() async throws {
        let rig = try rig()
        let e = rig.engine
        let mix = try noiseMix
        try burnStems(rig, "sy", data: try noiseStem)
        try loadStreaming(rig, "sy", fraction: 1, data: mix)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        await wait { !e.stemFadeInFlightForTesting(.a) }
        XCTAssertTrue(e.stemNodesPlayingForTesting(.a))
        let src = try decoded(mix)
        let cap = e.captureForTesting(.a)
        for other in MixEngine.stemNames where other != "vocals" {
            for n in MixEngine.stemNames where e.isStemMuted(n, on: .a) != (n != other && n != "vocals") {
                e.toggleStemMute(n, on: .a)
            }
            cap.start()
            await capture(cap, atLeast: 0.15)
            let y = cap.stop()
            let match = try XCTUnwrap(blockLags(Array(y.suffix(4096)), src, block: 4096).first)
            XCTAssertGreaterThan(match.corr, 0.995, "vocals + \(other) out of step (r=\(match.corr))")
        }
        // Re-seek (a fresh start of all four): still one frame.
        for n in MixEngine.stemNames where e.isStemMuted(n, on: .a) { e.toggleStemMute(n, on: .a) }
        e.seek(.a, toSeconds: 6)
        await wait { e.position(.a) > 6.3 }            // past the seek's own restart lead
        let on = await audible(e)
        XCTAssertTrue(on)
        cap.start()
        await capture(cap, atLeast: 0.9)
        assertSeamless(settledAfterSeek(cap.stop()), against: src, "all four after a seek")
    }

    // MARK: 7 — partial stems growing ON AIR

    /// The steady state users hit most: stems on air while still downloading, growing in steps.
    /// Every stretch appends in lockstep — one seamless, aligned read, never handed back.
    func testStreamingStemsGrowOnAirSeamlessly() async throws {
        let rig = try rig()
        let e = rig.engine
        let mix = try noiseMix, stem = try noiseStem
        try loadStreaming(rig, "gr", fraction: 1, data: mix)
        var f = 0.55                                                  // ~5 s playable per part
        let parts = try streamStems(rig, "gr", fraction: f, data: stem)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a), "≥4 s of runway — on the streaming stems")
        let cap = e.captureForTesting(.a)
        cap.start()
        var ends: [Double] = [try XCTUnwrap(e.stemEndSecondsForTesting(.a))]
        while f < 1 {
            let target = e.position(.a) + 0.45
            await wait { e.position(.a) >= target }
            f = min(1, f + 0.1)
            try streamStems(rig, "gr", fraction: f, files: parts, data: stem)
            ends.append(try XCTUnwrap(e.stemEndSecondsForTesting(.a)))
            if let frontier = e.stemFrontierForTesting(.a) {
                XCTAssertGreaterThanOrEqual((e.stemFilesReachForTesting(.a) ?? 0) + 0.001, frontier,
                                            "the frontier never runs ahead of the opens it describes")
            }
        }
        await wait(timeout: 6) { e.position(.a) > 3.6 }
        let y = cap.stop()
        XCTAssertTrue(e.stemActive(.a), "the runway kept up — never handed back")
        XCTAssertNil(e.stemFrontierForTesting(.a), "complete: ordinary stem files now")
        XCTAssertGreaterThan(ends.last ?? 0, 11.5, "scheduled through to the song's end")
        XCTAssertGreaterThan(Set(ends.map { Int($0 * 10) }).count, 2, "appended in several steps along the way")
        assertSeamless(y, against: try decoded(mix), "stems growing on air")
    }

    /// The pump's re-open throttle (d435971, redone): with stems on air, many small byte events
    /// must not each re-open the four parts — only a whole append chunk past the scheduled end
    /// is worth the opens. (Before: the chunk gate returned before the frontier moved, so every
    /// event past +0.5 s re-opened — the open storm the throttle was meant to stop.)
    func testOnAirStemPumpReopensOnlyPerAppendChunk() async throws {
        let rig = try rig()
        let e = rig.engine
        let stem = try noiseStem
        try loadStreaming(rig, "th", fraction: 1, data: try noiseMix)
        let parts = try streamStems(rig, "th", fraction: 0.6, data: stem)       // ~5.7 s playable
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        let end0 = try XCTUnwrap(e.stemEndSecondsForTesting(.a))
        let before = e.stemReopenCountForTesting
        for i in 1...10 {                                                       // 0.24 s per event
            try streamStems(rig, "th", fraction: 0.6 + 0.02 * Double(i), files: parts, data: stem)
        }
        let reopens = e.stemReopenCountForTesting - before
        XCTAssertLessThanOrEqual(reopens, 3, "10 small events, \(reopens) re-opens — one per ~1 s append chunk")
        XCTAssertGreaterThan(try XCTUnwrap(e.stemEndSecondsForTesting(.a)), end0 + 0.9, "…and the stems did extend")
    }

    /// ∞ LOOP on streaming stems: the stems finish downloading while the loop holds the deck, then
    /// the loop releases. The deck must play the rest of the song on the stems that ARRIVED —
    /// (before: `stemFiles` kept the loop-time opens while the frontier advanced, so the release
    /// scheduled the stale files to their old length under a "full song" end: silence the
    /// underrun check couldn't see).
    func testLoopOnStreamingStemsReleasesOntoTheStemsThatArrivedMeanwhile() async throws {
        let rig = try rig()
        let e = rig.engine
        let mix = try noiseMix, stem = try noiseStem
        try loadStreaming(rig, "lp", fraction: 1, data: mix)
        let parts = try streamStems(rig, "lp", fraction: 0.6, data: stem)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        let frontier0 = try XCTUnwrap(e.stemFrontierForTesting(.a))
        e.setLoop(.a, on: true)
        XCTAssertTrue(e.loopOn(.a))
        XCTAssertTrue(e.stemActive(.a), "the loop runs on the stems (its window is inside their frontier)")

        try streamStems(rig, "lp", fraction: 0.8, files: parts, data: stem)    // bytes land mid-loop…
        if let frontier = e.stemFrontierForTesting(.a) {
            XCTAssertGreaterThanOrEqual((e.stemFilesReachForTesting(.a) ?? 0) + 0.001, frontier,
                                        "the frontier never runs ahead of the opens it describes")
        }
        try streamStems(rig, "lp", fraction: 1, files: parts, data: stem)      // …and the set completes
        XCTAssertNil(e.stemFrontierForTesting(.a), "complete")
        XCTAssertGreaterThan(e.stemFilesReachForTesting(.a) ?? 0, 11.5, "the deck holds the COMPLETE opens")

        e.setLoop(.a, on: false)
        XCTAssertTrue(e.stemActive(.a))
        let end = try XCTUnwrap(e.stemEndSecondsForTesting(.a))
        XCTAssertGreaterThan(end, 11.5, "released onto the whole song")
        XCTAssertGreaterThanOrEqual((e.stemFilesReachForTesting(.a) ?? 0) + 0.001, end,
                                    "scheduled no further than the held files really reach")
        // Listen straight across where the stems' bytes had reached when the loop engaged.
        e.seek(.a, toSeconds: frontier0 + 0.5)
        await wait { e.position(.a) > frontier0 + 0.8 }  // past the seek's own restart lead
        let on = await audible(e)
        XCTAssertTrue(on)
        let cap = e.captureForTesting(.a)
        cap.start()
        await wait(timeout: 6) { e.position(.a) > frontier0 + 3.8 }
        let y = settledAfterSeek(cap.stop())
        XCTAssertTrue(e.stemActive(.a))
        assertSeamless(y, against: try decoded(mix), "past the loop-time frontier")
    }

    // MARK: 8 — the full mix's stream dies under the stems

    /// The full mix's stream dies while the stems carry the deck, then the stem stream dies too:
    /// nothing can grow — the song ENDS where its audio does and the deck stops there. (Before:
    /// the dead full mix read as "complete", the stems' failure handed back to it with ~1 s
    /// left, and the playhead ran on in silence to the catalog length.)
    func testDeadFullMixThenDeadStemsEndTheSongWhereTheAudioDoes() async throws {
        let rig = try rig()
        let e = rig.engine
        let loader = try XCTUnwrap(rig.loader)
        let mix = try noiseMix
        try loadStreaming(rig, "dd", fraction: 0.5, data: mix)                 // ~4.5 s of full mix
        try streamStems(rig, "dd", fraction: 0.55, data: try noiseStem)        // ~5 s of stems
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))

        loader.failStreamForTesting("dd")
        XCTAssertTrue(e.stemActive(.a), "the stems carry the deck")
        XCTAssertEqual(e.duration(.a), 12, accuracy: 0.2, "the stems still stream — the song isn't cut short yet")
        loader.failStemsForTesting("dd")
        XCTAssertLessThan(e.duration(.a), 5.5, "neither voice can grow: the song ends where its audio does")
        XCTAssertGreaterThan(e.duration(.a), 4)
        XCTAssertTrue(e.stemActive(.a), "the stems reach further than the cut-short full mix — they play it out")

        let cap = e.captureForTesting(.a)
        cap.start()
        await wait(timeout: 8) { !e.isPlaying(.a) }
        let y = cap.stop()
        XCTAssertFalse(e.isPlaying(.a), "the deck reached its (truncated) end and stopped")
        let tail = longestSilence(y)
        XCTAssertLessThan(tail, 44_100 / 3, "\(tail * 1000 / 44_100) ms of silence before the deck stopped — a silent playhead")
    }

    /// The full mix's stream dies under STILL-STREAMING stems that then run dry: nothing has
    /// audio at the playhead, but the stems can still grow — the deck HOLDS (Buffering…, the
    /// playhead frozen) and resumes on the stems once they arrive. (Before: with no full-mix
    /// stream the hold was skipped — a 0-frame reschedule and a playhead running over silence.)
    func testDeadFullMixHoldsForStillStreamingStemsThenResumesOnThem() async throws {
        let rig = try rig()
        let e = rig.engine
        let loader = try XCTUnwrap(rig.loader)
        try loadStreaming(rig, "dh", fraction: 0.5, data: try noiseMix)
        let parts = try streamStems(rig, "dh", fraction: 0.55, data: try noiseStem)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.stemActive(.a))
        loader.failStreamForTesting("dh")
        XCTAssertTrue(e.stemActive(.a))

        await wait(timeout: 8) { e.isBuffering(.a) }
        XCTAssertTrue(e.isBuffering(.a), "neither voice has audio at the playhead — Buffering…, not silence")
        XCTAssertEqual(e.stemHandover(.a), .toStems, "waiting for the stems")
        let held = e.position(.a)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(e.position(.a), held, accuracy: 0.001, "the playhead is frozen while held")

        try streamStems(rig, "dh", fraction: 1, files: parts, data: try noiseStem)
        XCTAssertFalse(e.isBuffering(.a))
        XCTAssertTrue(e.stemActive(.a), "resumed on the stems")
        let ok = await audible(e)
        XCTAssertTrue(ok)
        await wait { e.position(.a) > held + 0.3 }
        XCTAssertGreaterThan(e.position(.a), held + 0.3)
    }

    // MARK: 9 — transfers nobody wants

    /// A stem stream no deck wants any more is CANCELLED (it rides outside the song lane's cap
    /// and would steal bandwidth from the songs on air): toggled off mid-load, or the deck
    /// changed track.
    func testAbandonedStemStreamsAreCancelled() async throws {
        let rig = try rig()
        let e = rig.engine
        let loader = try XCTUnwrap(rig.loader)
        try loadStreaming(rig, "cx", fraction: 0.5)
        try streamStems(rig, "cx", fraction: 0.03)
        await playAndSettle(e)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.isStreamingStemsForTesting(.a))
        e.setStemMode(false, on: .a)
        XCTAssertNil(loader.stemSet(for: "cx"), "toggled off mid-load: the transfer is cancelled")

        try streamStems(rig, "cx", fraction: 0.03)
        e.setStemMode(true, on: .a)
        XCTAssertTrue(e.isStreamingStemsForTesting(.a))
        try loadStreaming(rig, "cy", fraction: 0.5)                             // new track on the deck
        XCTAssertNil(loader.stemSet(for: "cx"), "track changed: the old track's stems are cancelled")
    }

    /// Adopting a streamed stem set into the burn folder is ALL OR NOTHING: a move that fails
    /// part-way puts the parts already moved back, so the caller's files are where it left them.
    func testStreamedStemAdoptionRollsBackAPartialMove() throws {
        let rig = try rig(streaming: false)
        for round in 0..<6 {                         // dictionary order varies — fail late at least once
            let id = "ad\(round)"
            var files: [String: URL] = [:]
            for n in MixEngine.stemNames {
                let u = tempFile("\(id)-\(n)")
                if n != "other" { try Data([1, 2, 3]).write(to: u) }          // "other" is missing
                files[n] = u
            }
            XCTAssertNil(rig.burns.adoptStreamedStems(songId: id, files: files))
            for n in MixEngine.stemNames where n != "other" {
                XCTAssertTrue(FileManager.default.fileExists(atPath: files[n]!.path), "\(id)/\(n) rolled back")
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: rig.burnDir.appendingPathComponent("stem-\(id)-\(n).mp3").path), "\(id)/\(n) not half-adopted")
            }
        }
    }
}
