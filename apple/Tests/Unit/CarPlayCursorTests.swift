import XCTest
import AVFoundation
import MediaPlayer
@testable import PocketDJ

/// The CarPlay / lock-screen PROGRESS CURSOR. `CPNowPlayingTemplate` is system UI fed by
/// `MPNowPlayingInfoCenter`; the system draws the cursor by extrapolating elapsed at the card's
/// PlaybackRate from the moment of the write. So the card is correct iff, at every publication:
/// audio advancing ⇔ rate > 0 (at the audible speed), elapsed is where the audio actually is (in
/// the SONG's own timeline), and the duration is the song's. These tests capture the exact dicts
/// every writer publishes through `NowPlayingCardPublisher.sink` and hold each path to that:
/// Apple Music impersonation (`beginExternalNowPlaying`), the local AVPlayer, the Now Playing
/// DSP (engage / tempo / pause-resume / stems handover / disengage), and the Mix (stream hold →
/// resume, auto crossfade to the next track).
///
/// Field evidence these encode (Levi's iPhone traces, `ios-3712BFDE`, 2026-10-04):
///  • resume of a restored AM session at 3:26 published `pos=0` first, then jumped to 207;
///  • every AM→AM advance re-published the OLD track's clock under the NEW title
///    (`Try It … playing=false pos=302 dur=301`) — for 20 s when the next resolve was slow.
@MainActor
final class CarPlayCursorTests: XCTestCase {
    private var pubs: [NowPlayingCardPublisher.Publication] = []

    override func setUp() {
        super.setUp()
        pubs = []
        NowPlayingCardPublisher.shared.resetForTesting()
        NowPlayingCardPublisher.shared.sink = { [weak self] in self?.pubs.append($0) }
    }

    override func tearDown() {
        NowPlayingCardPublisher.shared.sink = nil
        NowPlayingCardPublisher.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    private final class StreamBox {
        var position = 12.0
        var playing = true
        var rate = 1.0
        var plays = 0
        var pauses = 0
    }

    private func beginExternal(_ engine: PlayerEngine, _ box: StreamBox, title: String = "Streamed",
                               duration: Double = 200, withRate: Bool = false) {
        engine.beginExternalNowPlaying(
            title: title, artist: "AM", songId: "am:\(title)", durationSeconds: duration,
            position: { box.position },
            isPlaying: { box.playing },
            rate: withRate ? { box.rate } : nil,
            play: { box.plays += 1; box.playing = true },
            pause: { box.pauses += 1; box.playing = false })
    }

    private var last: NowPlayingCardPublisher.Publication? { pubs.last }

    private func waitFor(_ message: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    private func toneFixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stream-tone-12s", withExtension: "mp3"))
    }

    // MARK: - Apple Music impersonation (external mode)

    /// Steady state while a stream plays: rate > 0, DefaultPlaybackRate 1, the stream's
    /// duration, and every ticker beat re-publishes the LIVE position (elapsed advances).
    func testExternalPlayingCardAdvancesBetweenPublications() {
        let engine = PlayerEngine()
        let box = StreamBox()
        beginExternal(engine, box)
        let first = try! XCTUnwrap(last)
        XCTAssertGreaterThan(first.rate, 0, "playing ⇒ the cursor moves")
        XCTAssertEqual(first.defaultRate, 1)
        XCTAssertEqual(first.duration ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(first.playbackState, .playing)

        box.position = 40
        engine.externalTickForTesting()
        let next = try! XCTUnwrap(last)
        XCTAssertGreaterThan(next.rate, 0)
        XCTAssertEqual(next.elapsed ?? 0, 40, accuracy: 0.001, "the beat publishes the stream's live position")
        XCTAssertGreaterThan(next.elapsed ?? 0, first.elapsed ?? 0, "elapsed advances between publications")
    }

    /// Field 2026-10-04 02:03:12: resuming a restored AM session at 3:26 published elapsed 0 for
    /// the first second (the card's clock was reset instead of read from the stream). The very
    /// first publication must carry the stream's real position.
    func testBeginExternalSeedsTheStreamsResumePositionNotZero() {
        let engine = PlayerEngine()
        let box = StreamBox()
        box.position = 206.2
        beginExternal(engine, box, duration: 220)
        let titled = pubs.filter { $0.title == "Streamed" }
        XCTAssertFalse(titled.isEmpty)
        for p in titled {
            XCTAssertEqual(p.elapsed ?? -1, 206.2, accuracy: 0.01, "no publication may show 0:00 for a mid-song resume")
        }
    }

    /// Engaging the Now Playing DSP while PAUSED (or a stream that isn't sounding yet) must not
    /// publish a running cursor: the card mirrors the stream's REAL play state from the start.
    func testBeginExternalWhileStreamPausedPublishesRateZero() {
        let engine = PlayerEngine()
        let box = StreamBox()
        box.playing = false
        beginExternal(engine, box)
        let p = try! XCTUnwrap(last)
        XCTAssertEqual(p.rate, 0, "a paused stream ⇒ frozen cursor, not a runaway one")
        XCTAssertEqual(p.playbackState, .paused)
        XCTAssertFalse(engine.isPlaying)
    }

    /// The DSP plays at a DJ tempo: the card's rate is that tempo, so the extrapolated cursor
    /// moves at the audible speed instead of drifting and snapping back every second.
    func testExternalCardRateFollowsStreamTempo() {
        let engine = PlayerEngine()
        let box = StreamBox()
        box.rate = 1.5
        beginExternal(engine, box, withRate: true)
        XCTAssertEqual(last?.rate ?? 0, 1.5, accuracy: 0.001)
        box.rate = 0.8
        engine.externalTickForTesting()
        XCTAssertEqual(last?.rate ?? 0, 0.8, accuracy: 0.001, "a tempo change re-publishes the rate")
    }

    /// Remote ⏸ / ▶ re-publish immediately with rate 0 / > 0 at the stream's position.
    func testExternalPauseResumeRepublishesRateAndElapsed() {
        let engine = PlayerEngine()
        let box = StreamBox()
        beginExternal(engine, box)
        box.position = 30
        engine.pause()
        XCTAssertEqual(box.pauses, 1)
        XCTAssertEqual(last?.rate, 0)
        XCTAssertEqual(last?.elapsed ?? -1, 30, accuracy: 0.001, "pause pins the cursor where the audio stopped")
        engine.play()
        XCTAssertEqual(box.plays, 1)
        XCTAssertGreaterThan(last?.rate ?? 0, 0, "resume restarts the cursor")
        XCTAssertEqual(last?.elapsed ?? -1, 30, accuracy: 0.001)
    }

    /// Field 2026-10-04 20:10:36: on an AM→AM advance the external ticker kept running after the
    /// "cueing up" announce and re-published the ENDED track's clock (302 of 301 s, paused) under
    /// the NEXT track's title. Once the next track is announced, nothing may publish the old clock.
    func testAnnounceStopsTheStaleExternalClockUnderTheNextTitle() {
        let engine = PlayerEngine()
        let box = StreamBox()
        beginExternal(engine, box, title: "Old", duration: 301)
        box.position = 302
        box.playing = false                       // MusicKit parked at the end of the old track
        engine.announceUpcoming(title: "New", artist: "B", songId: nil)
        engine.externalTickForTesting()           // a ticker beat landing during the resolve
        let next = pubs.filter { $0.title == "New" }
        XCTAssertFalse(next.isEmpty, "the announce card was published")
        for p in next {
            XCTAssertEqual(p.elapsed ?? -1, 0, accuracy: 0.001, "the next track's card starts at 0:00")
            XCTAssertNil(p.duration, "never the previous track's duration under the new title")
            XCTAssertEqual(p.rate, 0)
        }
    }

    // MARK: - Local AVPlayer

    /// Playing a local file: rate > 0 and the ~1 Hz refresh re-publishes an ADVANCING elapsed.
    func testLocalPlayingCardRepublishesAdvancingElapsed() async throws {
        let engine = PlayerEngine()
        addTeardownBlock { @MainActor in engine.stop() }
        engine.load(url: try toneFixture(), live: false, startMs: nil, title: "Tone", artist: "A")
        await waitFor("a playing card with a duration") {
            pubs.contains { $0.title == "Tone" && $0.rate > 0 && $0.duration != nil }
        }
        let first = try XCTUnwrap(pubs.last { $0.title == "Tone" && $0.rate > 0 })
        await waitFor("a later refresh with advanced elapsed") {
            pubs.contains { $0.title == "Tone" && $0.rate > 0 && ($0.elapsed ?? 0) > (first.elapsed ?? 0) + 0.5 }
        }
        XCTAssertEqual(last?.defaultRate, 1)
    }

    /// An analog album rip is ONE shared file with per-song offsets. The card must show the SONG's
    /// own timeline — elapsed from the song's start, duration = the song's length — not the whole
    /// album side (a cursor crawling across a 45-minute bar reads as "not moving"). A card scrub
    /// maps back into the file.
    func testSharedAlbumFileCardIsSongRelative() async throws {
        let engine = PlayerEngine()
        addTeardownBlock { @MainActor in engine.stop() }
        engine.load(url: try toneFixture(), live: false, startMs: 4_000, title: "Side", artist: "A",
                    endBoundaryMs: 10_000, songStartMs: 4_000)
        await waitFor("the ready card with a duration") {
            pubs.contains { $0.title == "Side" && $0.duration != nil }
        }
        let p = try XCTUnwrap(pubs.last { $0.title == "Side" && $0.duration != nil })
        XCTAssertEqual(p.duration ?? 0, 6, accuracy: 0.05, "the song's length (10 s − 4 s), not the file's 12 s")
        XCTAssertLessThan(p.elapsed ?? 99, 1.5, "elapsed counts from the song's own start")

        engine.seekFromCard(toCardSeconds: 2)
        XCTAssertEqual(engine.currentTime, 6, accuracy: 0.01, "card 0:02 is 0:06 in the shared file")
        XCTAssertEqual(last?.elapsed ?? -1, 2, accuracy: 0.01, "and the card shows 0:02")
    }

    // MARK: - Now Playing DSP (SetlistPlayer engage / disengage)

    private func makeSetlist(ids: [String]) throws -> (SetlistPlayer, PlayerEngine, RipsStore, NowPlayingDSP) {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: ids, rips: rips, lengths: Dictionary(uniqueKeysWithValues: ids.map { ($0, 8.0) }))
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return (seq, player, rips, dsp)
    }

    /// Engage while PAUSED → rate 0; remote ▶ (routed to the DSP) → rate > 0 and the elapsed
    /// advances; a tempo change → the card's rate is the tempo; a track change hands the card
    /// back to the AVPlayer path for the next song.
    func testDSPEngageDisengageKeepsTheCardConsistent() async throws {
        let (seq, player, rips, dsp) = try makeSetlist(ids: ["dsp1", "dsp2"])
        seq.play([.init(id: "dsp1", title: "T-dsp1", artist: "A", lengthMs: 8_000),
                  .init(id: "dsp2", title: "T-dsp2", artist: "A", lengthMs: 8_000)])
        await waitFor("burned track 1 playing") { rips.nowPlaying?.songId == "dsp1" && player.isPlaying }
        player.pause()
        await waitFor("paused") { !player.isPlaying }
        XCTAssertTrue(seq.currentTrackMixable)

        let before = pubs.count
        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(seq.mixEngaged)
        let engaged = pubs[before...].filter { $0.writer == "engine-ext" }
        XCTAssertFalse(engaged.isEmpty, "the DSP's card was published")
        for p in engaged { XCTAssertEqual(p.rate, 0, "engaged while paused ⇒ the cursor stays put") }

        player.play()                                    // the remote ▶ → dsp.resume()
        XCTAssertTrue(dsp.isPlaying)
        XCTAssertGreaterThan(last?.rate ?? 0, 0, "▶ restarts the cursor")
        let e0 = last?.elapsed ?? 0
        await waitFor("the DSP render clock advanced") { dsp.currentTime > e0 + 0.3 }
        player.externalTickForTesting()
        XCTAssertGreaterThan(last?.elapsed ?? 0, e0, "elapsed advances while the DSP plays")

        dsp.setRate(1.25)
        player.externalTickForTesting()
        XCTAssertEqual(last?.rate ?? 0, 1.25, accuracy: 0.001, "the card moves at the DSP's tempo")

        seq.skipNext()                                   // disengage on the track change
        await waitFor("handed back + next track loaded") { !seq.mixEngaged && rips.nowPlaying?.songId == "dsp2" }
        await waitFor("the next track's local card") {
            pubs.contains { $0.writer == "engine" && $0.title == "T-dsp2" && $0.rate > 0 }
        }
        let tail = pubs.drop { $0.title != "T-dsp2" }
        XCTAssertFalse(tail.contains { $0.writer == "engine-ext" }, "no stale DSP card after the hand-back")
    }

    /// Engage while PLAYING: the card keeps moving through the AVPlayer → DSP swap (no rate-0 card
    /// left behind once the DSP is sounding).
    func testDSPEngageWhilePlayingLeavesARunningCursor() async throws {
        let (seq, player, rips, dsp) = try makeSetlist(ids: ["dsp3"])
        seq.play([.init(id: "dsp3", title: "T-dsp3", artist: "A", lengthMs: 8_000)])
        await waitFor("burned track playing") { rips.nowPlaying?.songId == "dsp3" && player.isPlaying }
        seq.engageMix()
        try XCTSkipUnless(dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(dsp.isPlaying)
        XCTAssertEqual(last?.writer, "engine-ext")
        XCTAssertGreaterThan(last?.rate ?? 0, 0, "the DSP is sounding ⇒ the card says so")
        XCTAssertEqual(last?.playbackState, .playing)
    }

    /// Stems handover (full mix ↔ stems) while the DSP owns the card: the published elapsed never
    /// runs backward across either cut and the cursor keeps moving.
    func testStemsHandoverKeepsTheCardElapsedMonotonic() async throws {
        let songId = "pdj_carplay_stems"
        let d = NowPlayingDSP(burns: try MixBurnFixture.burnStore(ids: []))
        var stems: [String: URL] = [:]
        for name in MixEngine.stemNames {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("cpc-stem-\(UUID().uuidString).wav")
            try MixBurnFixture.writeSineWAV(to: u, seconds: 8)
            addTeardownBlock { try? FileManager.default.removeItem(at: u) }
            stems[name] = u
        }
        d.profileStemResolve = { $0 == songId ? stems : nil }
        let main = FileManager.default.temporaryDirectory.appendingPathComponent("cpc-main-\(UUID().uuidString).wav")
        try MixBurnFixture.writeSineWAV(to: main, seconds: 8)
        addTeardownBlock { try? FileManager.default.removeItem(at: main) }
        d.engage(url: main, startMs: nil, lengthMs: nil, atSeconds: 0, songId: songId, play: true)
        try XCTSkipUnless(d.isReady, "no audio device on this test host")
        addTeardownBlock { @MainActor in d.disengage() }

        let engine = PlayerEngine()
        engine.beginExternalNowPlaying(
            title: "Stems", artist: "A", songId: songId, durationSeconds: d.duration,
            position: { [weak d] in d?.currentTime ?? 0 }, isPlaying: { [weak d] in d?.isPlaying ?? false },
            rate: { [weak d] in d?.rate ?? 1 },
            play: { [weak d] in d?.resume() }, pause: { [weak d] in d?.pause() })
        await waitFor("render clock running") { d.currentTime > 0.4 }

        var prev = -1.0
        func beat(_ label: String) {
            engine.externalTickForTesting()
            let p = pubs.last!
            XCTAssertGreaterThan(p.rate, 0, "\(label): cursor moving")
            XCTAssertGreaterThanOrEqual(p.elapsed ?? 0, prev - 0.05, "\(label): elapsed never runs backward")
            prev = p.elapsed ?? 0
        }
        beat("full mix")
        XCTAssertTrue(d.setStemMode(true))
        beat("cut to stems")
        await waitFor("stems advanced") { d.currentTime > prev + 0.3 }
        beat("on stems")
        XCTAssertTrue(d.setStemMode(false))
        beat("cut back to full mix")
        await waitFor("full mix advanced") { d.currentTime > prev + 0.3 }
        beat("full mix again")
    }

    // MARK: - Mix

    private func streamingEngine() throws -> (MixEngine, MixStreamLoader) {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        return (engine, loader)
    }

    /// Mix streaming mode: a deck HELD for bytes is not advancing, so its card must publish rate 0
    /// (rate 1 over a frozen playhead = a cursor that runs ahead, then snaps back). The bytes
    /// arriving RESUME the deck — and that resume must re-publish rate > 0 at once, not leave the
    /// rate-0 card up until some later tick.
    func testHeldStreamingDeckPublishesRateZeroThenResumeRepublishes() async throws {
        let data = try Data(contentsOf: try toneFixture())
        let (engine, loader) = try streamingEngine()
        addTeardownBlock { @MainActor in engine.teardown() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpc-stream-\(UUID().uuidString).mp3")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let total = Int64(data.count)
        let third = data.count / 3
        try data.prefix(third).write(to: file)
        loader.injectStreamForTesting(songId: "hs", file: file, bytes: Int64(third), expected: total)
        engine.load(songId: "hs", title: "Held", artist: "A", bpm: 120, camelot: "8A", key: nil,
                    albumId: nil, lengthMs: 12_000, on: .a)
        try XCTSkipUnless(engine.isReady, "no audio device on this test host")
        engine.play(.a)
        XCTAssertGreaterThan(last?.rate ?? 0, 0, "playing with runway ⇒ moving cursor")
        XCTAssertEqual(last?.title, "Held")

        engine.seek(.a, toSeconds: 9)                     // past the frontier → HELD
        XCTAssertTrue(engine.isBuffering(.a), "precondition: held for bytes")
        XCTAssertEqual(last?.rate, 0, "held ⇒ rate 0 (the playhead isn't moving)")
        XCTAssertEqual(last?.elapsed ?? -1, 9, accuracy: 0.01)

        let beforeResume = pubs.count
        try data.write(to: file)
        loader.injectStreamForTesting(songId: "hs", file: file, bytes: total, expected: total, finished: true)
        XCTAssertFalse(engine.isBuffering(.a), "precondition: resumed")
        XCTAssertGreaterThan(pubs.count, beforeResume, "the resume re-published the card")
        XCTAssertGreaterThan(last?.rate ?? 0, 0, "resumed ⇒ the cursor moves again")
        XCTAssertEqual(last?.elapsed ?? -1, 9, accuracy: 0.25, "from the held position")
    }

    /// Auto-DJ crossfade to the next track: once the outgoing deck stops, the card is the
    /// incoming track — its title, a running rate, and ITS elapsed (not the outgoing deck's).
    func testAutoCrossfadeHandsTheCardToTheIncomingTrack() async throws {
        let burns = try MixBurnFixture.burnStore(ids: ["cx1", "cx2"], lengths: ["cx1": 8, "cx2": 8])
        let e = MixEngine(burns: burns)
        addTeardownBlock { @MainActor in e.stopAutoMix(); e.teardown() }
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        func item(_ id: String) -> MixEngine.AutoMixItem {
            .init(loadable: MixLoadable(songId: id, title: "T-\(id)", artist: "A", bpm: 120, camelot: "8A",
                                        key: nil, albumId: nil, lengthMs: 8_000), durationMs: 8_000)
        }
        e.startAutoMix([item("cx1"), item("cx2")], shuffled: false, lead: 4, fade: 1)
        await waitFor("the first track's card") { last?.title == "T-cx1" && (last?.rate ?? 0) > 0 }

        e.skipToNext(fadeSeconds: 0.5)
        e.finishAutoCrossfadeForTesting()
        let onAir = try XCTUnwrap(e.nowPlayingDeck)
        XCTAssertEqual(e.loaded(onAir)?.songId, "cx2")
        let p = try XCTUnwrap(last)
        XCTAssertEqual(p.title, "T-cx2", "the card follows the incoming track")
        XCTAssertGreaterThan(p.rate, 0)
        XCTAssertEqual(p.elapsed ?? -1, e.position(onAir), accuracy: 0.5, "the INCOMING deck's elapsed")
        XCTAssertEqual(p.duration ?? 0, 8, accuracy: 0.1)
    }

    // MARK: - Funnel invariants

    /// The funnel never publishes a running cursor past the end, and always pairs the rate with
    /// the explicit playbackState CarPlay reads.
    func testPublisherClampsElapsedAndPairsRateWithState() {
        let pub = NowPlayingCardPublisher.shared
        pub.publish(writer: "t", title: "X", artist: "A", elapsed: 302, duration: 301, advancing: true, rate: 0)
        XCTAssertEqual(last?.elapsed ?? 0, 301, accuracy: 0.001, "elapsed clamped into the track")
        XCTAssertEqual(last?.rate ?? 0, 1, accuracy: 0.001, "advancing never publishes rate 0")
        XCTAssertEqual(last?.playbackState, .playing)
        pub.publish(writer: "t", title: "X", artist: "A", elapsed: 10, duration: 301, advancing: false, rate: 1.2)
        XCTAssertEqual(last?.rate, 0)
        XCTAssertEqual(last?.playbackState, .paused)
        XCTAssertEqual(last?.defaultRate, 1)
    }
}
