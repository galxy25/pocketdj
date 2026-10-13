import AVFoundation
import XCTest
@testable import PocketDJ

/// ZERO DEAD AIR at the song boundary of an Auto-DJ mix whose queue mixes on-device songs with
/// ripped-but-not-downloaded (STREAMING) ones — the field report "both in Mix and pocket shuffle
/// mode it was pausing at the end of songs and I had to skip forward multiple times" (Levi,
/// CarPlay on cellular, 2026-10-12). Network conditions are scripted through the loader's seams:
/// a BUFFERING stream (a few hundred ms of bytes), a COMPLETE one, a stream that DIES, and a
/// closed stream gate (rip server cooldown — what a presign failure on cellular trips).
@MainActor
final class MixEndOfSongTests: XCTestCase {
    private var savedStall = MixEngine.autoStallSkipSeconds

    override func tearDown() {
        MixEngine.autoStallSkipSeconds = savedStall
        super.tearDown()
    }

    // MARK: Harness

    private struct Rig {
        let engine: MixEngine
        let loader: MixStreamLoader
        let rips: RipsStore
        let data: Data
        var files: [String: URL] = [:]
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stream-tone-12s", withExtension: "mp3"))
        return try Data(contentsOf: url)
    }

    private func makeRig(burned: [String], ripped: [String] = []) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://server.test"
        settings.ripToken = ""
        rips.settings = settings
        var manifest: [String: RipsStore.ManifestEntry] = [:]
        for id in ripped { manifest[id] = .init(key: "rips/\(id).mp3", source: "digital", durationMs: 12_000) }
        rips.setManifest(manifest)
        let burns = try MixBurnFixture.burnStore(ids: burned, rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        engine.ensureEngine()
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        return Rig(engine: engine, loader: loader, rips: rips, data: try fixture())
    }

    private func tempFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-eos-\(name)-\(UUID().uuidString).mp3")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A stream with ~0.4 s of bytes: under the frontier margin + start runway ⇒ the deck HOLDS.
    private func buffering(_ rig: inout Rig, _ id: String) throws {
        let f = tempFile(id)
        try rig.data.prefix(12_000).write(to: f)
        rig.files[id] = f
        rig.loader.injectStreamForTesting(songId: id, file: f, bytes: 12_000, expected: Int64(rig.data.count))
    }

    /// The whole object landed.
    private func complete(_ rig: inout Rig, _ id: String) throws {
        let f = rig.files[id] ?? tempFile(id)
        try rig.data.write(to: f)
        rig.files[id] = f
        rig.loader.injectStreamForTesting(songId: id, file: f, bytes: Int64(rig.data.count),
                                          expected: Int64(rig.data.count), finished: true)
    }

    private func item(_ id: String) -> MixEngine.AutoMixItem {
        .init(loadable: MixLoadable(songId: id, title: id, artist: "A", bpm: 120, camelot: "8A",
                                    key: nil, albumId: nil, lengthMs: 12_000), durationMs: 12_000)
    }

    private func start(_ e: MixEngine, _ ids: [String], shuffled: Bool = false, lead: Double = 15) {
        e.startAutoMix(ids.map(item), shuffled: shuffled, lead: lead, fade: 3, label: "eos")
    }

    // MARK: 1 — the natural transition never fades into a Buffering… deck

    /// The on-deck next is still buffering when the live song reaches its lead window, and a
    /// song further down is on device: the ready one is PROMOTED into the slot (the buffering
    /// one stays queued right behind it) and the crossfade goes into audio, not silence.
    func testAutoTransitionPromotesAReadySongOverABufferingNext() throws {
        var rig = try makeRig(burned: ["x", "y"])
        try buffering(&rig, "h1")
        let e = rig.engine
        start(e, ["x", "h1", "y"])
        XCTAssertEqual(e.loaded(.b)?.songId, "h1")
        XCTAssertTrue(e.isBuffering(.b), "the on-deck next is still waiting for bytes")

        e.backdateAutoDeckEndForTesting(secondsLeft: 5)
        e.autoFireForTesting()
        XCTAssertNotNil(e.autoFadeStartedAtForTesting, "the transition runs on time")
        XCTAssertEqual(e.loaded(.b)?.songId, "y", "…into the song that can AIR, not the buffering one")
        XCTAssertFalse(e.isBuffering(.b))
        XCTAssertEqual(e.autoQueueIdsForTesting, ["x", "y", "h1"], "the buffering song is deferred, never dropped")
        e.teardown()
    }

    /// Nothing can air at the lead window: wait (the live song plays on). At its very end:
    /// REPLAY it rather than go silent. The moment the next has audio, transition.
    func testNothingReadyAtTheEndKeepsTheLiveSongPlaying() throws {
        var rig = try makeRig(burned: ["x"])
        try buffering(&rig, "h1")
        let e = rig.engine
        start(e, ["x", "h1"])

        e.backdateAutoDeckEndForTesting(secondsLeft: 5)
        e.autoFireForTesting()
        XCTAssertNil(e.autoFadeStartedAtForTesting, "no crossfade into a deck that's still buffering")
        XCTAssertTrue(e.isPlaying(.a), "the live song keeps playing while the next buffers")

        e.backdateAutoDeckEndForTesting(secondsLeft: 0.2)
        e.autoFireForTesting()
        XCTAssertNil(e.autoFadeStartedAtForTesting, "still nothing to air at the very end…")
        XCTAssertTrue(e.autoExtendingForTesting, "…so the live song is EXTENDED")
        XCTAssertEqual(e.loaded(.a)?.songId, "x")
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertEqual(e.position(.a), 0, accuracy: 0.05, "replayed from the top — music, not silence")
        XCTAssertTrue(e.autoMixing)

        try complete(&rig, "h1")
        e.autoFireForTesting()
        XCTAssertNotNil(e.autoFadeStartedAtForTesting, "the next has audio — transition at once")
        XCTAssertEqual(e.loaded(.b)?.songId, "h1")
        XCTAssertFalse(e.isBuffering(.b))
        XCTAssertFalse(e.autoExtendingForTesting)
        e.teardown()
    }

    // MARK: 2 — Skip: one press = one audible next song

    func testSkipPrefersAReadySongOverABufferingNext() throws {
        var rig = try makeRig(burned: ["x", "y"])
        try buffering(&rig, "h1")
        let e = rig.engine
        start(e, ["x", "h1", "y"])
        e.skipToNext(fadeSeconds: 1)
        XCTAssertNotNil(e.autoFadeStartedAtForTesting)
        XCTAssertEqual(e.loaded(.b)?.songId, "y", "the skip lands on a song that plays NOW")
        XCTAssertFalse(e.isBuffering(.b))
        e.teardown()
    }

    /// Nothing ready at the first Skip: the fade into the buffering song is FROZEN (the outgoing
    /// song stays on air instead of fading into silence). A second Skip — the listener still
    /// hears the old song — must NOT be swallowed: it re-targets past the buffering song.
    func testSkipDuringAFrozenFadeRetargetsPastTheBufferingSong() throws {
        var rig = try makeRig(burned: ["x"])
        try buffering(&rig, "h1")
        try buffering(&rig, "h2")
        let e = rig.engine
        start(e, ["x", "h1", "h2"])

        e.skipToNext(fadeSeconds: 1)
        XCTAssertEqual(e.loaded(.b)?.songId, "h1")
        e.backdateAutoFadeStartForTesting(seconds: 10)   // the whole fade "elapsed" while it buffered
        e.autoFireForTesting()
        XCTAssertEqual(e.autoLiveDeck, .a, "the fade never completed into a silent deck")
        XCTAssertNotNil(e.autoFadeStartedAtForTesting, "frozen, not finished")
        XCTAssertEqual(e.crossfader, 0, accuracy: 0.001, "the outgoing song is still fully on air")
        XCTAssertTrue(e.isPlaying(.a))

        try complete(&rig, "h2")
        e.skipToNext(fadeSeconds: 1)
        XCTAssertEqual(e.loaded(.b)?.songId, "h2", "the second press reaches the song that can play")
        XCTAssertFalse(e.isBuffering(.b))
        XCTAssertNotNil(e.autoFadeStartedAtForTesting)
        XCTAssertEqual(e.autoQueueIdsForTesting, ["x", "h2", "h1"], "the buffering song is deferred to the end")
        e.backdateAutoFadeStartForTesting(seconds: 10)
        e.autoFireForTesting()
        XCTAssertEqual(e.autoLiveDeck, .b, "this fade completes — into audio")
        e.teardown()
    }

    /// The incoming stream DIES (presign / network failure) while the fade waits on it: the deck
    /// is ejected — and the fade must back out, not sweep the fader onto an empty deck (which
    /// left the mix silent for a whole song length).
    func testIncomingStreamDyingMidFadeBacksOut() throws {
        var rig = try makeRig(burned: ["x"])
        try buffering(&rig, "h1")
        let e = rig.engine
        start(e, ["x", "h1"])
        e.skipToNext(fadeSeconds: 1)
        XCTAssertNotNil(e.autoFadeStartedAtForTesting)

        rig.loader.failStreamForTesting("h1")
        XCTAssertNil(e.loaded(.b), "a stream that died before audio empties its deck")
        e.autoFireForTesting()
        XCTAssertNil(e.autoFadeStartedAtForTesting, "the fade backs out")
        XCTAssertEqual(e.autoLiveDeck, .a)
        XCTAssertEqual(e.crossfader, 0, accuracy: 0.001, "the outgoing song keeps the fader")
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertTrue(e.autoMixing)
        e.teardown()
    }

    // MARK: 3 — the stream gate (offline / rip-server cooldown) defers, never drains the queue

    /// A presign failure trips the server cooldown: `canStream` refuses every ripped song for a
    /// minute. Those songs are DEFERRED behind the next on-device one — dropping them (the old
    /// behaviour) drained a ripped-union mix down to its last track.
    func testClosedStreamGateDefersRippedSongsInsteadOfDroppingThem() throws {
        let rig = try makeRig(burned: ["x", "y"], ripped: ["r1", "r2"])
        rig.loader.tripServerDownForTesting()
        let e = rig.engine
        XCTAssertFalse(e.canStream("r1"))
        start(e, ["x", "r1", "r2", "y"])
        XCTAssertEqual(e.loaded(.a)?.songId, "x")
        XCTAssertEqual(e.loaded(.b)?.songId, "y", "the next PLAYABLE song takes the on-deck slot")
        XCTAssertEqual(e.autoQueueIdsForTesting, ["x", "y", "r1", "r2"], "gated songs stay queued (deferred)")
        e.teardown()
    }

    /// Only gated songs left after the live one: the natural end and a Skip both keep the live
    /// song playing (the mix ENDED here before — silence, and the next Skip did nothing).
    func testClosedStreamGateAtTheEndKeepsTheMixAlive() throws {
        let rig = try makeRig(burned: ["x"], ripped: ["r1"])
        rig.loader.tripServerDownForTesting()
        let e = rig.engine
        start(e, ["x", "r1"])
        XCTAssertEqual(e.autoQueueIdsForTesting, ["x", "r1"])

        e.skipToNext(fadeSeconds: 1)
        XCTAssertTrue(e.autoMixing, "a Skip with nothing loadable RIGHT NOW doesn't end the mix")
        XCTAssertTrue(e.isPlaying(.a))

        e.backdateAutoDeckEndForTesting(secondsLeft: 0.2)
        e.autoFireForTesting()
        e.autoFireForTesting()
        XCTAssertTrue(e.autoMixing, "the natural end with only gated songs left extends the live song")
        XCTAssertTrue(e.autoExtendingForTesting)
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertEqual(e.autoQueueIdsForTesting, ["x", "r1"], "the gated song is still there for when the gate opens")
        e.teardown()
    }

    // MARK: 4 — a live deck stalled on an underrun

    /// The LIVE deck is frozen waiting for bytes (a cellular dead zone mid-song) — dead air. After
    /// `autoStallSkipSeconds` the mix hands over to a song that can air; a short hold doesn't.
    func testLiveDeckStalledOnAnUnderrunHandsOverToAReadySong() throws {
        var rig = try makeRig(burned: ["y"])
        try buffering(&rig, "h1")
        let e = rig.engine
        start(e, ["h1", "y"], lead: 2)    // 12 s songs: keep the natural window out of the way
        XCTAssertEqual(e.loaded(.a)?.songId, "h1")
        XCTAssertTrue(e.isBuffering(.a) && e.isPlaying(.a), "the live deck is on air, waiting for bytes")

        e.backdateStreamHoldForTesting(.a, seconds: 2)
        e.autoFireForTesting()
        XCTAssertNil(e.autoFadeStartedAtForTesting, "a short hold is just buffering — no hand-over")

        e.backdateStreamHoldForTesting(.a, seconds: MixEngine.autoStallSkipSeconds + 1)
        e.autoFireForTesting()
        XCTAssertNotNil(e.autoFadeStartedAtForTesting, "a long stall hands over")
        XCTAssertEqual(e.loaded(.b)?.songId, "y")
        e.teardown()
    }

    // MARK: 5 — a shuffled mix opens on audio

    func testShuffledStartOpensOnAnOnDeviceSong() throws {
        var rig = try makeRig(burned: ["x"])
        let held = (1...7).map { "h\($0)" }
        for h in held { try buffering(&rig, h) }
        let e = rig.engine
        start(e, held + ["x"], shuffled: true)
        XCTAssertEqual(e.loaded(.a)?.songId, "x", "a shuffle's order is ours — open on the song that plays NOW")
        XCTAssertFalse(e.isBuffering(.a))
        e.teardown()
    }
}
