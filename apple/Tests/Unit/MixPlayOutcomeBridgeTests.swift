import XCTest
import AVFoundation
@testable import PocketDJ

/// MixPlayOutcomeBridge — the Mix decks' per-play outcomes (the SkipTracker never sees Mix /
/// Auto-DJ playback). A `.skip` / `.replaced` end under 50% is a skip (+ the cumulative count);
/// over 50% or a natural end is completed; one end per event; a collapsed play maps to the
/// newest local event.
@MainActor
final class MixPlayOutcomeBridgeTests: XCTestCase {

    private var skips: [String] = []

    private func makeHistory() -> PlayHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixoutcome-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PlayHistoryStore(fileURL: url)
    }

    private func makeBridge(_ history: PlayHistoryStore) -> MixPlayOutcomeBridge {
        skips = []
        return MixPlayOutcomeBridge(history: history, noteSkip: { [weak self] in self?.skips.append($0) })
    }

    private func mixPlay(_ history: PlayHistoryStore, _ bridge: MixPlayOutcomeBridge,
                         _ song: String, at ms: Double = 1_000) -> PlayHistoryStore.PlayEvent? {
        let ev = history.record(songId: song,
                                context: PlayHistoryStore.PlayContext(source: .mix, contextId: nil, contextName: nil),
                                at: ms)
        bridge.notePlayed(songId: song, event: ev)
        return ev
    }

    private func row(_ history: PlayHistoryStore, _ id: UUID) -> PlayHistoryStore.PlayEvent? {
        history.events.first { $0.id == id }
    }

    func testSkipAt20PercentIsASkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 40, duration: 200, reason: .skip)
        XCTAssertEqual(row(history, ev.id)?.wasSkipped, true)
        XCTAssertEqual(row(history, ev.id)?.listenedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(row(history, ev.id)?.outcome, .skipped)
        XCTAssertEqual(skips, ["sng_a"], "the cumulative per-song counter fired once")
    }

    func testSkipAt70PercentIsCompleted() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 140, duration: 200, reason: .skip)
        XCTAssertNil(row(history, ev.id)?.wasSkipped)
        XCTAssertEqual(row(history, ev.id)?.outcome, .completed)
        XCTAssertTrue(skips.isEmpty)
    }

    func testNaturalEndIsCompleted() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 196, duration: 200, reason: .natural)
        XCTAssertEqual(row(history, ev.id)?.outcome, .completed)
        XCTAssertTrue(skips.isEmpty)
    }

    /// Natural ends and stops are never skips, however little played (a stream that died, a mix
    /// the user stopped) — they read `partial`.
    func testShortStopIsPartialNotSkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 10, duration: 200, reason: .stopped)
        XCTAssertNil(row(history, ev.id)?.wasSkipped)
        XCTAssertEqual(row(history, ev.id)?.outcome, .partial)
        XCTAssertTrue(skips.isEmpty)
    }

    func testReplacedUnderHalfIsASkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 30, duration: 200, reason: .replaced)
        XCTAssertEqual(row(history, ev.id)?.outcome, .skipped)
        XCTAssertEqual(skips, ["sng_a"])
    }

    func testSecondEndForSameEventIsIgnored() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 180, duration: 200, reason: .natural)
        // A collapsed re-note maps the song back onto the SAME event, then a late skip report.
        bridge.notePlayed(songId: "sng_a", event: nil)
        bridge.noteTrackEnded(songId: "sng_a", played: 10, duration: 200, reason: .skip)
        XCTAssertNil(row(history, ev.id)?.wasSkipped, "only the first end applies")
        XCTAssertTrue(skips.isEmpty)
        // An end with no mapping at all is a no-op.
        bridge.noteTrackEnded(songId: "sng_unmapped", played: 1, duration: 200, reason: .skip)
        XCTAssertTrue(skips.isEmpty)
    }

    func testCollapsedPlayMapsViaLastLocalEvent() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let first = mixPlay(history, bridge, "sng_a", at: 1_000)!
        // A re-load 4 s later: record collapses it (nil) and the bridge falls back to the tail.
        let collapsed = mixPlay(history, bridge, "sng_a", at: 5_000)
        XCTAssertNil(collapsed, "within the 30 s window record collapses")
        bridge.noteTrackEnded(songId: "sng_a", played: 20, duration: 200, reason: .skip)
        XCTAssertEqual(row(history, first.id)?.wasSkipped, true, "the collapsed play wrote to the surviving row")
    }

    func testUnknownDurationReportsNothing() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(songId: "sng_a", played: 10, duration: 0, reason: .skip)
        XCTAssertEqual(row(history, ev.id)?.outcome, .unknown)
        XCTAssertTrue(skips.isEmpty)
    }
}

/// The MixEngine half: `onSongPlayed` fires ONCE per deck load (a resume is the same listen),
/// and `onDeckTrackEnded` fires once per played load when the track is loaded over / ejected,
/// never for a load that never played. Real graph — skipped on a host with no audio device.
@MainActor
final class MixDeckOutcomeHookTests: XCTestCase {

    private func makeEngine() -> MixEngine {
        MixEngine(burns: try! MixBurnFixture.burnStore())
    }

    private func meta(_ id: String) -> MixEngine.LoadedTrack {
        MixEngine.LoadedTrack(songId: id, title: "T-\(id)", artist: "A", bpm: 120,
                              camelot: nil, key: nil, albumId: nil)
    }

    private func makeSineWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixoutcome-\(UUID().uuidString).wav")
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<2 {
            for i in 0..<Int(frames) { ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2 }
        }
        try file.write(from: buf)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSongPlayedFiresOncePerLoadAcrossPauseResume() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        var played: [String] = []
        e.onSongPlayed = { played.append($0) }
        let url = try makeSineWAV(seconds: 2)
        e.loadFile(url, release: nil, startMs: nil, meta: meta("a"), on: .a)
        e.play(.a)
        e.pause(.a)
        e.play(.a)
        e.pause(.a)
        e.play(.a)
        XCTAssertEqual(played, ["a"], "resumes are the same listen")
        // A fresh load is a fresh play.
        e.loadFile(url, release: nil, startMs: nil, meta: meta("b"), on: .a)
        e.play(.a)
        XCTAssertEqual(played, ["a", "b"])
        e.clearDeck(.a)
    }

    func testTrackEndedFiresOnReplaceAndEjectOnlyForPlayedLoads() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        var ended: [(String, MixTrackEndReason)] = []
        e.onDeckTrackEnded = { id, _, duration, reason in
            XCTAssertGreaterThan(duration, 0)
            ended.append((id, reason))
        }
        let url = try makeSineWAV(seconds: 2)
        // Loaded but never played, then loaded over → nothing to report.
        e.loadFile(url, release: nil, startMs: nil, meta: meta("unplayed"), on: .a)
        e.loadFile(url, release: nil, startMs: nil, meta: meta("a"), on: .a)
        XCTAssertTrue(ended.isEmpty)
        // Played, then loaded over → .replaced, once.
        e.play(.a)
        e.loadFile(url, release: nil, startMs: nil, meta: meta("b"), on: .a)
        XCTAssertEqual(ended.map(\.0), ["a"])
        XCTAssertEqual(ended.first?.1, .replaced)
        // Played, then ejected → .replaced for b; a second clear reports nothing.
        e.play(.a)
        e.clearDeck(.a)
        e.clearDeck(.a)
        XCTAssertEqual(ended.map(\.0), ["a", "b"])
    }
}
