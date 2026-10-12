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

    private var fixture: Data {
        get throws {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stream-tone-12s", withExtension: "mp3"))
            return try Data(contentsOf: url)
        }
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

    /// Burn complete stems for `songId` (the 12 s fixture as every part).
    private func burnStems(_ rig: Rig, _ songId: String) throws {
        let data = try fixture
        for n in MixEngine.stemNames {
            try data.write(to: rig.burnDir.appendingPathComponent("stem-\(songId)-\(n).mp3"))
        }
    }

    /// Stream `songId` onto `deck` from a growing file holding `fraction` of the fixture.
    @discardableResult
    private func loadStreaming(_ rig: Rig, _ songId: String, fraction: Double, on deck: MixEngine.Deck = .a) throws -> URL {
        let data = try fixture
        let file = tempFile(songId)
        let n = Int(Double(data.count) * fraction)
        try data.prefix(n).write(to: file)
        try XCTUnwrap(rig.loader).injectStreamForTesting(songId: songId, file: file, bytes: Int64(n), expected: Int64(data.count))
        rig.engine.load(songId: songId, title: "T", artist: "A", bpm: 120, camelot: "8A", key: nil,
                        albumId: nil, lengthMs: 12_000, on: deck)
        return file
    }

    /// Grow (or complete) an injected song stream.
    private func growStream(_ rig: Rig, _ songId: String, file: URL, fraction: Double) throws {
        let data = try fixture
        let n = min(data.count, Int(Double(data.count) * fraction))
        try data.prefix(n).write(to: file)
        try XCTUnwrap(rig.loader).injectStreamForTesting(songId: songId, file: file, bytes: Int64(n),
                                                         expected: Int64(data.count), finished: n == data.count)
    }

    /// Stream `songId`'s 4 stems with `fraction` of each part on disk; returns the part files.
    @discardableResult
    private func streamStems(_ rig: Rig, _ songId: String, fraction: Double,
                             files: [String: URL]? = nil) throws -> [String: URL] {
        let data = try fixture
        let n = min(data.count, Int(Double(data.count) * fraction))
        var out: [String: URL] = files ?? [:]
        var bytes: [String: Int64] = [:]
        for name in MixEngine.stemNames {
            let url = out[name] ?? tempFile("\(songId)-\(name)")
            try data.prefix(n).write(to: url)
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
}
