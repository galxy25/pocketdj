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
        bridge.notePlayed(deck: .a, songId: song, event: ev)
        return ev
    }

    private func row(_ history: PlayHistoryStore, _ id: UUID) -> PlayHistoryStore.PlayEvent? {
        history.events.first { $0.id == id }
    }

    func testSkipAt20PercentIsASkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 40, duration: 200, reason: .skip)
        XCTAssertEqual(row(history, ev.id)?.wasSkipped, true)
        XCTAssertEqual(row(history, ev.id)?.listenedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(row(history, ev.id)?.outcome, .skipped)
        XCTAssertEqual(skips, ["sng_a"], "the cumulative per-song counter fired once")
    }

    func testSkipAt70PercentIsCompleted() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 140, duration: 200, reason: .skip)
        XCTAssertNil(row(history, ev.id)?.wasSkipped)
        XCTAssertEqual(row(history, ev.id)?.outcome, .completed)
        XCTAssertTrue(skips.isEmpty)
    }

    func testNaturalEndIsCompleted() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 196, duration: 200, reason: .natural)
        XCTAssertEqual(row(history, ev.id)?.outcome, .completed)
        XCTAssertTrue(skips.isEmpty)
    }

    /// Natural ends and stops are never skips, however little played (a stream that died, a mix
    /// the user stopped) — they read `partial`.
    func testShortStopIsPartialNotSkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 10, duration: 200, reason: .stopped)
        XCTAssertNil(row(history, ev.id)?.wasSkipped)
        XCTAssertEqual(row(history, ev.id)?.outcome, .partial)
        XCTAssertTrue(skips.isEmpty)
    }

    func testReplacedUnderHalfIsASkip() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 30, duration: 200, reason: .replaced)
        XCTAssertEqual(row(history, ev.id)?.outcome, .skipped)
        XCTAssertEqual(skips, ["sng_a"])
    }

    func testSecondEndForSameEventIsIgnored() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 180, duration: 200, reason: .natural)
        // A collapsed re-note maps the song back onto the SAME event, then a late skip report.
        bridge.notePlayed(deck: .a, songId: "sng_a", event: nil)
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 10, duration: 200, reason: .skip)
        XCTAssertNil(row(history, ev.id)?.wasSkipped, "only the first end applies")
        XCTAssertTrue(skips.isEmpty)
        // An end with no mapping at all is a no-op.
        bridge.noteTrackEnded(deck: .a, songId: "sng_unmapped", played: 1, duration: 200, reason: .skip)
        XCTAssertTrue(skips.isEmpty)
    }

    func testCollapsedPlayMapsViaLastLocalEvent() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let first = mixPlay(history, bridge, "sng_a", at: 1_000)!
        // A re-load 4 s later: record collapses it (nil) and the bridge falls back to the tail.
        let collapsed = mixPlay(history, bridge, "sng_a", at: 5_000)
        XCTAssertNil(collapsed, "within the 30 s window record collapses")
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 20, duration: 200, reason: .skip)
        XCTAssertEqual(row(history, first.id)?.wasSkipped, true, "the collapsed play wrote to the surviving row")
    }

    /// Repeat-one auto mix: BOTH decks hold the same song. The incoming deck's play (fired at
    /// crossfade START) must not capture the outgoing deck's natural end, and the replay's skip
    /// must land on the replay's own event.
    func testSameSongOnBothDecksKeepsEachDecksOutcome() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ctx = PlayHistoryStore.PlayContext(source: .mix, contextId: nil, contextName: nil)
        let e1 = history.record(songId: "sng_x", context: ctx, at: 1_000)!
        bridge.notePlayed(deck: .a, songId: "sng_x", event: e1)
        let e2 = history.record(songId: "sng_x", context: ctx, at: 241_000)!   // the replay, 4 min on
        bridge.notePlayed(deck: .b, songId: "sng_x", event: e2)
        bridge.noteTrackEnded(deck: .a, songId: "sng_x", played: 238, duration: 240, reason: .natural)
        bridge.noteTrackEnded(deck: .b, songId: "sng_x", played: 24, duration: 240, reason: .skip)
        XCTAssertEqual(row(history, e1.id)?.outcome, .completed, "deck A's full play is e1's")
        XCTAssertEqual(row(history, e2.id)?.outcome, .skipped, "the replay's skip is not lost")
        XCTAssertEqual(row(history, e2.id)?.listenedFraction ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(skips, ["sng_x"])
        // A deck's end for a song it isn't mapped to (a stale report) is a no-op.
        bridge.notePlayed(deck: .a, songId: "sng_y", event: history.record(songId: "sng_y", context: ctx, at: 500_000))
        bridge.noteTrackEnded(deck: .a, songId: "sng_z", played: 1, duration: 240, reason: .skip)
        XCTAssertEqual(skips, ["sng_x"])
    }

    func testUnknownDurationReportsNothing() {
        let history = makeHistory()
        let bridge = makeBridge(history)
        let ev = mixPlay(history, bridge, "sng_a")!
        bridge.noteTrackEnded(deck: .a, songId: "sng_a", played: 10, duration: 0, reason: .skip)
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
        e.onSongPlayed = { id, _ in played.append(id) }
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
        e.onDeckTrackEnded = { id, _, duration, reason, _ in
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

    /// A ↺ / rewind before the deck is loaded over must not turn the listen into a skip: the end
    /// reports the load's HIGH-WATER position, not the re-zeroed playhead.
    func testEndReportsHighWaterNotTheRewoundPlayhead() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        var played: [Double] = []
        e.onDeckTrackEnded = { _, p, _, _, _ in played.append(p) }
        let url = try makeSineWAV(seconds: 2)
        e.loadFile(url, release: nil, startMs: nil, meta: meta("a"), on: .a)
        e.play(.a)
        e.seek(.a, toSeconds: 1.9)
        e.restart(.a)                                  // the ↺ Reset path rewinds to 0
        XCTAssertEqual(e.position(.a), 0, accuracy: 0.01)
        e.loadFile(url, release: nil, startMs: nil, meta: meta("b"), on: .a)
        XCTAssertEqual(played.count, 1)
        XCTAssertGreaterThanOrEqual(played.first ?? 0, 1.85, "the furthest point reached, not 0")
        // The NEXT load starts its own mark from scratch.
        e.play(.a)
        e.clearDeck(.a)
        XCTAssertLessThan(played.last ?? 9, 1.0)
    }

    private func autoItem(_ id: String) -> MixEngine.AutoMixItem {
        .init(loadable: MixLoadable(songId: id, title: "T-\(id)", artist: "A", bpm: 120,
                                    camelot: "8A", key: nil, albumId: nil, lengthMs: 2_000),
              durationMs: 180_000)
    }

    /// Repeat-one auto mix, wired exactly as the app wires it (record → bridge, end → bridge):
    /// the replay on the other deck is its own play, the outgoing deck's natural end stays on the
    /// first play, and a ⏭ during the replay marks the REPLAY skipped.
    func testRepeatOneReplayKeepsOutcomesOnTheirOwnPlays() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-mixoutcome-r1-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let history = PlayHistoryStore(fileURL: url)
        var skips: [String] = []
        let bridge = MixPlayOutcomeBridge(history: history, noteSkip: { skips.append($0) })
        var clockMs = 1_000.0
        var events: [UUID] = []
        e.onSongPlayed = { songId, deck in
            clockMs += 300_000   // each play minutes apart, as in a real mix (no 30 s collapse)
            let ev = history.record(songId: songId,
                                    context: .init(source: .mix, contextId: nil, contextName: nil), at: clockMs)
            if let ev { events.append(ev.id) }
            bridge.notePlayed(deck: deck, songId: songId, event: ev)
        }
        e.onDeckTrackEnded = { songId, played, duration, reason, deck in
            bridge.noteTrackEnded(deck: deck, songId: songId, played: played, duration: duration, reason: reason)
        }
        e.startAutoMix([autoItem("x"), autoItem("y")], shuffled: false, lead: 15, fade: 3)
        e.setAutoRepeat(.one)
        e.backdateAutoDeckEndForTesting(secondsLeft: 1)
        e.autoFireForTesting()                 // repeat-one: the other deck starts x again
        e.finishAutoCrossfadeForTesting()      // …and the first deck reports its natural end
        XCTAssertEqual(e.onAirTrack?.songId, "x")
        XCTAssertEqual(events.count, 2, "the replay is its own play")
        e.skipToNext(fadeSeconds: 0.5)         // ⏭ during the replay, a few % in
        let rows = Dictionary(uniqueKeysWithValues: history.events.map { ($0.id, $0) })
        XCTAssertNotEqual(rows[events[0]]?.outcome, .skipped, "the first play ended naturally")
        XCTAssertEqual(rows[events[1]]?.outcome, .skipped, "the replay's skip landed on the replay")
        XCTAssertEqual(skips, ["x"])
        e.stopAutoMix()
        e.teardown()
    }

    /// Stopped mid-crossfade: the incoming deck has played too, so it reports `.stopped` then —
    /// not a few-percent `.replaced` (a skip) when a later mix ejects it.
    func testStopMidCrossfadeReportsTheIncomingDeckAsStopped() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        var ended: [(String, MixTrackEndReason)] = []
        e.onDeckTrackEnded = { id, _, _, reason, _ in ended.append((id, reason)) }
        e.startAutoMix([autoItem("x"), autoItem("y")], shuffled: false, lead: 15, fade: 3)
        e.skipToNext(fadeSeconds: 5)           // fade x → y begins; y is playing
        e.stopAutoMix()
        e.startAutoMix([autoItem("z")], shuffled: false, lead: 15, fade: 3)   // ejects both decks
        let y = ended.filter { $0.0 == "y" }.map(\.1)
        XCTAssertEqual(y, [.stopped], "one end for y, and it is a stop — never a replace/skip")
        XCTAssertEqual(ended.first { $0.0 == "x" }?.1, .skip)
        e.stopAutoMix()
        e.teardown()
    }
}
