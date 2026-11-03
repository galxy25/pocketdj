import AVFoundation
import XCTest
@testable import PocketDJ

/// FX LOCK — carry the Now Playing mini-mix EFFECTS across a session's tracks (`FXLock.swift`).
///
///  • The model + plan are pure (Codable forward tolerance, `wantsFX`, the FX-only song steps).
///  • The carry runs the REAL sequencer + DSP over burned WAV files (no network): the carried
///    effects come up on the next track (the DSP engages at its start and RAMPS them in), tempo /
///    pitch / gain do NOT carry, a mid-track change is what carries, unlock / no-effect-on keep the
///    old per-track reset (no engage), the snapshot persists + a restore re-applies, a new session
///    / stop clear it, the Stem Lock and FX Lock carry together, and a media-services reset
///    re-takes the track with its effects on the fresh graph.
///  (Growing-file start, Apple Music dormancy + touch hand-off, Mix-tab dormancy and the Mix Mode
///  swap-on-land live with their rigs in `NPMixGrowingFileTests` — "FX Lock".)
@MainActor
final class FXLockTests: XCTestCase {
    private var savedRamp = NowPlayingDSP.fxRampSeconds

    override func setUp() {
        super.setUp()
        savedRamp = NowPlayingDSP.fxRampSeconds
        NPLog.mirror = { print("TRACE", $0) }
    }

    override func tearDown() {
        NowPlayingDSP.fxRampSeconds = savedRamp
        NPLog.mirror = nil
        super.tearDown()
    }

    private func fx(_ pairs: [(MixEngine.Effect, Bool, Double)]) -> [String: FXLockState.Setting] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue, FXLockState.Setting(on: $0.1, strength: $0.2)) })
    }

    // MARK: - Pure

    func testStateWantsFXSummaryAndForwardTolerantDecoding() throws {
        XCTAssertFalse(FXLockState().wantsFX)
        XCTAssertFalse(FXLockState(enabled: true).wantsFX, "locked with nothing on: nothing to apply")
        XCTAssertFalse(FXLockState(enabled: true, effects: fx([(.reverb, false, 0.9)])).wantsFX, "a strength alone is inaudible")
        XCTAssertFalse(FXLockState(enabled: false, effects: fx([(.reverb, true, 0.9)])).wantsFX)
        let st = FXLockState(enabled: true, effects: fx([(.reverb, true, 0.7), (.filter, true, 0.25), (.flanger, false, 0.1)]))
        XCTAssertTrue(st.wantsFX)
        XCTAssertEqual(st.logSummary, "fx=filter:0.25,reverb:0.70")
        XCTAssertEqual(try JSONDecoder().decode(FXLockState.self, from: try JSONEncoder().encode(st)), st)
        // Missing keys decode as defaults; an unknown effect key survives the round trip.
        XCTAssertEqual(try JSONDecoder().decode(FXLockState.self, from: Data("{}".utf8)), FXLockState())
        let future = try JSONDecoder().decode(FXLockState.self, from: Data(#"{"enabled":true,"effects":{"bitcrush":{"on":true,"strength":0.4}}}"#.utf8))
        XCTAssertTrue(future.enabled)
        XCTAssertEqual(future.effects["bitcrush"]?.strength, 0.4)
    }

    /// The FX Lock's lane: the next tracks' WHOLE SONGS only (no stems), Wi-Fi the window,
    /// cellular / Low Data the next track, offline none — and nothing at all without it (the Stem
    /// Lock / Mix Mode plans are byte-for-byte unchanged).
    func testPlanFetchesTheNextSongsOnlyWhenTheLockCarriesEffects() {
        func t(_ id: String, local: Bool = false, fetchable: Bool = true) -> NowPlayingPrefetcher.Track {
            .init(songId: id, audioId: id, title: id, artist: "A", songLocal: local, songFetchable: fetchable,
                  stemsLocal: [], stemsRemote: true)
        }
        let up = [t("n1"), t("n2", local: true), t("n3"), t("n4"), t("n5", fetchable: false)]
        func input(_ net: NowPlayingPrefetcher.Network, fx: Bool) -> NowPlayingPrefetchInput {
            NowPlayingPrefetchInput(current: t("cur"), upcoming: up, stemLock: StemLockState(), mixMode: NPMixModeState(),
                                    network: net, stemLockWindow: 3, fxLockSongs: fx)
        }
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(.unmetered, fx: false)).steps, [], "lock off: nothing speculative")
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(.unmetered, fx: true)).steps.map(\.description), ["song:n1", "song:n3"],
                       "the window's songs that aren't local yet — never the playing row, never stems")
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(.expensive, fx: true)).steps.map(\.description), ["song:n1"])
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(.constrained, fx: true)).steps.map(\.description), ["song:n1"])
        XCTAssertEqual(NowPlayingPrefetcher.plan(input(.offline, fx: true)).steps, [])
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(.unmetered, fx: true)).stemify.isEmpty)
        // With the Stem Lock carrying stems too: its plan, the FX songs adding nothing it has.
        var both = input(.unmetered, fx: true)
        both.stemLock = StemLockState(enabled: true, stemsOn: true)
        var stemsOnly = both; stemsOnly.fxLockSongs = false
        XCTAssertEqual(NowPlayingPrefetcher.plan(both), NowPlayingPrefetcher.plan(stemsOnly))
    }

    // MARK: - Rig (the Stem Lock suite's: real sequencer + DSP over burned WAVs)

    private struct Rig {
        let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
        let seq: SetlistPlayer; let dsp: NowPlayingDSP
    }

    private func rig(_ ids: [String], stems: Bool = false) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        rips.setManifest(Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, RipsStore.ManifestEntry(key: "rips/\(id).mp3", source: "digital",
                                         stems: stems ? .init(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                                                              bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3") : nil))
        }))
        let burns = try MixBurnFixture.burnStore(ids: ids, rips: rips, lengths: Dictionary(uniqueKeysWithValues: ids.map { ($0, 12.0) }))
        return wire(rips, burns)
    }

    private func wire(_ rips: RipsStore, _ burns: BurnStore) -> Rig {
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return Rig(rips: rips, burns: burns, player: player, seq: seq, dsp: dsp)
    }

    private func item(_ id: String) -> SetlistPlayer.Item { .init(id: id, title: id, artist: "A") }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        await StemAudioProbe.wait(timeout: timeout, until: predicate)
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    /// Let the sequencer's one-turn-later `nowPlaying` observer run before the next skip (a skip in
    /// the SAME turn as a track's stamp reads that stamp as a foreign jump — not a human cadence).
    private func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    /// Start the set and engage the DSP on track 0 (a control touch).
    private func startEngaged(_ r: Rig, _ ids: [String]) async throws {
        r.seq.play(ids.map(item))
        await waitUntil("\(ids[0]) playing") { r.rips.nowPlaying?.songId == ids[0] }
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        if !r.dsp.isPlaying { r.dsp.resume() }
    }

    // MARK: - Carry

    /// THE HEADLINE: reverb 70 % + filter 25 % on track 1, locked → track 2 comes up ENGAGED (the
    /// DSP takes it at its start — no touch) with exactly those effects, ramped in from
    /// transparent; tempo / pitch / gain set on track 1 do NOT follow.
    func testLockedEffectsCarryToTheNextTrackAndTempoPitchGainReset() async throws {
        NowPlayingDSP.fxRampSeconds = 0.6
        let r = try rig(["c1", "c2"])
        try await startEngaged(r, ["c1", "c2"])
        r.dsp.setEffectStrength(.reverb, 0.7)
        r.dsp.setEffect(.reverb, enabled: true)
        r.dsp.setEffectStrength(.filter, 0.25)
        r.dsp.setEffect(.filter, enabled: true)
        r.dsp.setRate(1.2)
        r.dsp.setPitch(3)
        r.dsp.setVolume(1.5)
        r.seq.setFXLock(true)
        XCTAssertEqual(r.seq.fxLock, FXLockState(enabled: true, effects: fx([(.reverb, true, 0.7), (.filter, true, 0.25)])))
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)

        r.seq.skipNext()
        await waitUntil("c2 engaged at its start") { r.rips.nowPlaying?.songId == "c2" && r.dsp.loadedSongId == "c2" }
        XCTAssertTrue(r.seq.mixEngaged, "FX Lock with an effect on engages the DSP at the track start")
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertLessThan(r.dsp.currentTime, 1.5, "from the top")
        XCTAssertTrue(r.dsp.isEnabled(.reverb))
        XCTAssertEqual(r.dsp.strength(.reverb), 0.7, accuracy: 1e-9)
        XCTAssertTrue(r.dsp.isEnabled(.filter))
        XCTAssertEqual(r.dsp.strength(.filter), 0.25, accuracy: 1e-9)
        XCTAssertFalse(r.dsp.isEnabled(.flanger))
        XCTAssertFalse(r.dsp.isEnabled(.compressor))
        // RAMP IN: the boundary never pops — the wet mix starts below its target and climbs.
        XCTAssertTrue(r.dsp.effectRampInFlight, "the carried effects ramp in")
        XCTAssertFalse(r.dsp.reverbBypassed)
        XCTAssertLessThan(r.dsp.reverbWetDryMix, 70 * 0.9, "not slammed in at full wet")
        await waitUntil("ramp landed") { !r.dsp.effectRampInFlight }
        XCTAssertEqual(r.dsp.reverbWetDryMix, 70, accuracy: 0.01)
        XCTAssertFalse(r.dsp.filterBandBypassed)
        XCTAssertTrue(r.dsp.flangerBypassed)
        // Tempo / pitch / gain reset per track (Levi's Q9 default — not part of the lock).
        XCTAssertEqual(r.dsp.rate, 1, accuracy: 1e-9)
        XCTAssertEqual(r.dsp.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(r.dsp.volume, 1, accuracy: 1e-9)
        XCTAssertEqual(r.dsp.timePitchRate, 1, accuracy: 1e-6)
        XCTAssertEqual(r.dsp.timePitchPitchCents, 0, accuracy: 1e-6)
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)
        XCTAssertEqual(r.seq.index, 1, "no fake end, no skip")
    }

    /// A change MID-TRACK is what carries; a user toggle during the ramp wins over the ramp.
    func testMidTrackChangeUpdatesTheCarryAndBeatsTheRamp() async throws {
        NowPlayingDSP.fxRampSeconds = 0.6
        let r = try rig(["m1", "m2", "m3"])
        try await startEngaged(r, ["m1", "m2", "m3"])
        r.dsp.setEffect(.reverb, enabled: true)
        r.seq.setFXLock(true)
        r.dsp.setEffect(.reverb, enabled: false)               // changed my mind…
        r.dsp.setEffectStrength(.flanger, 0.4)
        r.dsp.setEffect(.flanger, enabled: true)
        XCTAssertEqual(r.seq.fxLock.effects, fx([(.flanger, true, 0.4)]),
                       "reverb back off at its untouched strength is neutral — nothing to carry")

        r.seq.skipNext()
        await waitUntil("m2 on the carry") { r.dsp.loadedSongId == "m2" && r.seq.mixEngaged }
        XCTAssertTrue(r.dsp.isEnabled(.flanger))
        XCTAssertFalse(r.dsp.isEnabled(.reverb))
        XCTAssertTrue(r.dsp.effectRampInFlight)
        r.dsp.setEffectStrength(.flanger, 0.8)                 // the listener's hand mid-ramp
        XCTAssertEqual(r.dsp.flangerWetDryMix, 40, accuracy: 0.01, "the touched effect lands at once")
        XCTAssertEqual(r.seq.fxLock.effects[MixEngine.Effect.flanger.rawValue]?.strength ?? 0, 0.8, accuracy: 1e-9)
        await waitUntil("ramp landed") { !r.dsp.effectRampInFlight }
        XCTAssertEqual(r.dsp.flangerWetDryMix, 40, accuracy: 0.01, "the ramp never overwrites it")

        r.seq.skipNext()
        await waitUntil("m3 on the updated carry") { r.dsp.loadedSongId == "m3" && r.seq.mixEngaged }
        XCTAssertEqual(r.dsp.strength(.flanger), 0.8, accuracy: 1e-9)
    }

    /// UNLOCK → the NEXT track resets exactly as before (no engage, every effect off); the
    /// current track keeps what it plays. And a lock carrying NO effect that is on never engages.
    func testUnlockResetsTheNextTrackAndANoEffectLockNeverEngages() async throws {
        let r = try rig(["u1", "u2", "u3", "u4"])
        try await startEngaged(r, ["u1", "u2", "u3", "u4"])
        r.dsp.setEffect(.compressor, enabled: true)
        r.seq.setFXLock(true)
        r.seq.skipNext()
        await waitUntil("u2 on the carry") { r.dsp.loadedSongId == "u2" && r.seq.mixEngaged }
        await settle()
        XCTAssertTrue(r.dsp.isEnabled(.compressor))
        r.seq.setFXLock(false)
        XCTAssertTrue(r.dsp.isEnabled(.compressor), "the current track keeps what it is playing")
        XCTAssertFalse(r.dsp.compressorBypassed)

        r.seq.skipNext()
        await waitUntil("u3 playing") { r.rips.nowPlaying?.songId == "u3" }
        XCTAssertFalse(r.seq.mixEngaged, "unlocked: the plain AVPlayer path (F4 swap-on-touch)")
        XCTAssertFalse(r.dsp.isEnabled(.compressor), "controls reset (ephemeral)")
        XCTAssertEqual(r.seq.fxLockIndicator, .off)
        await settle()

        // Locked with nothing on: nothing to carry, nothing engages.
        r.seq.setFXLock(true)
        XCTAssertEqual(r.seq.fxLockIndicator, .idle)
        r.seq.skipNext()
        await waitUntil("u4 playing") { r.rips.nowPlaying?.songId == "u4" }
        XCTAssertFalse(r.seq.mixEngaged)
        XCTAssertTrue(r.seq.fxLock.enabled)
    }

    /// The lock + its effects ride the durable snapshot: a relaunch restore STAMPS them on the idle
    /// DSP (the panel shows them while held, nothing engaged) and the first ▶ engages with them; a
    /// new session and stop() clear the lock AND the stamp.
    func testLockPersistsRestoresAndANewSessionOrStopClearsIt() async throws {
        let r = try rig(["s1", "s2"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-fxlock-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        r.seq.sessionStore = store
        try await startEngaged(r, ["s1", "s2"])
        r.dsp.setEffectStrength(.reverb, 0.6)
        r.dsp.setEffect(.reverb, enabled: true)
        r.dsp.setRate(1.1)
        r.seq.setFXLock(true)
        r.seq.flushSessionSnapshotNow()
        store.flush()
        let snap = try XCTUnwrap(store.load())
        XCTAssertEqual(snap.fxLock, FXLockState(enabled: true, effects: fx([(.reverb, true, 0.6)])))
        let decoded = try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.fxLock, snap.fxLock)

        // Relaunch: a fresh sequencer + DSP restore the held session.
        r.seq.stop()
        let r2 = wire(r.rips, r.burns)
        r2.seq.restore(from: snap)
        XCTAssertEqual(r2.seq.fxLock, snap.fxLock)
        XCTAssertFalse(r2.seq.mixEngaged, "held: nothing engaged before ▶")
        XCTAssertEqual(r2.seq.fxLockIndicator, .idle, "held deck: nothing applied until ▶")
        XCTAssertTrue(r2.dsp.isEnabled(.reverb), "the panel shows the carried effects while held")
        XCTAssertEqual(r2.dsp.rate, 1, "…but never the tempo")
        r2.seq.resumeFromHold()
        await waitUntil("restored track engaged with its effects") { r2.dsp.loadedSongId == "s1" && r2.seq.mixEngaged }
        try XCTSkipUnless(r2.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r2.dsp.isEnabled(.reverb))
        await waitUntil("ramp landed") { !r2.dsp.effectRampInFlight }
        XCTAssertEqual(r2.dsp.reverbWetDryMix, 60, accuracy: 0.01)

        // A pre-FX-Lock snapshot (no key) restores unlocked.
        var old = snap; old.fxLock = nil
        let r3 = wire(r.rips, r.burns)
        r3.seq.restore(from: old)
        XCTAssertFalse(r3.seq.fxLock.enabled)
        XCTAssertFalse(r3.dsp.isEnabled(.reverb))

        // A new session — a fresh play — starts unlocked and neutral.
        r2.seq.play([item("s2")])
        XCTAssertFalse(r2.seq.fxLock.enabled)
        await waitUntil("s2 playing") { r2.rips.nowPlaying?.songId == "s2" }
        XCTAssertFalse(r2.seq.mixEngaged, "no carried effects in the new session")
        XCTAssertFalse(r2.dsp.isEnabled(.reverb))
        r2.seq.setFXLockForTesting(FXLockState(enabled: true, effects: fx([(.filter, true, 0.5)])))
        XCTAssertTrue(r2.dsp.isEnabled(.filter), "stamped on the idle DSP")
        r2.seq.stop()
        XCTAssertFalse(r2.seq.fxLock.enabled, "stop ends the session — and its lock")
        XCTAssertFalse(r2.dsp.isEnabled(.filter), "…and the idle DSP drops the stamp")
    }

    /// STEMS CARRY + FX CARRY together: the Stem Lock engages the next track for its stems and
    /// the FX Lock's effects ride the same engagement.
    func testStemLockAndFXLockCarryTogether() async throws {
        let all = MixEngine.stemNames
        let r = try rig(["b1", "b2"], stems: true)
        let data = try StemAudioProbe.bundled("stem-noise-12s", in: Self.self)
        let dir = try XCTUnwrap(r.burns.appBurnsDirOverride)
        for id in ["b1", "b2"] { for p in all { try data.write(to: dir.appendingPathComponent("stem-\(id)-\(p).mp3")) } }
        try await startEngaged(r, ["b1", "b2"])
        XCTAssertTrue(r.dsp.setStemMode(true), "precondition: stems on disk")
        await waitUntil("b1 on stems") { r.dsp.stemsOnAir }
        r.dsp.toggleStemMute("vocals")
        r.dsp.setEffect(.reverb, enabled: true)
        r.seq.setStemLock(true)
        r.seq.setFXLock(true)

        r.seq.skipNext()
        await waitUntil("b2 on stems with its effects") { r.dsp.loadedSongId == "b2" && r.dsp.stemsOnAir }
        XCTAssertTrue(r.dsp.isStemMuted("vocals"))
        XCTAssertTrue(r.dsp.isEnabled(.reverb))
        XCTAssertEqual(r.seq.stemLockIndicator, .active)
        XCTAssertEqual(r.seq.fxLockIndicator, .applied)
    }

    /// MEDIA SERVICES RESET while the DSP carries the effects: the graph is recreated, the track
    /// goes back to the AVPlayer — and the FX Lock re-takes it on the FRESH graph at the same
    /// position with its effects (before: dry for the rest of the song).
    func testMediaServicesResetReappliesTheCarriedEffectsOnTheFreshGraph() async throws {
        let r = try rig(["r1", "r2"])
        try await startEngaged(r, ["r1", "r2"])
        r.dsp.setEffect(.flanger, enabled: true)
        r.seq.setFXLock(true)
        await waitUntil("rendering") { r.dsp.currentTime > 0.5 }
        r.dsp.pause()
        let at = r.dsp.currentTime
        r.seq.handleMediaServicesReset()
        XCTAssertEqual(r.dsp.mediaResetRebuilds, 1)
        XCTAssertTrue(r.seq.mixEngaged, "re-engaged on the fresh graph")
        XCTAssertTrue(r.dsp.isReady)
        XCTAssertEqual(r.dsp.loadedSongId, "r1")
        XCTAssertEqual(r.dsp.currentTime, at, accuracy: 0.15, "same position")
        XCTAssertFalse(r.dsp.isPlaying, "paused stays paused")
        XCTAssertTrue(r.dsp.isEnabled(.flanger))
        await waitUntil("ramp landed") { !r.dsp.effectRampInFlight }
        XCTAssertFalse(r.dsp.flangerBypassed, "the effect is on the NEW graph's AU")
        XCTAssertEqual(r.seq.index, 0)
    }

    // MARK: - Adversarial review (2026-11-02)

    /// A lock engage at a track start CLOSES the start bookkeeping exactly once: the start
    /// runway is released, the dead-air meter records ONE transition (no double first audio —
    /// the AVPlayer it idled never reports one), and nothing is left open for the next track.
    func testLockEngageAtStartClosesTheStartWindowAndRecordsOneTransition() async throws {
        let r = try rig(["d1", "d2"])
        try await startEngaged(r, ["d1", "d2"])
        r.dsp.setEffect(.reverb, enabled: true)
        r.seq.setFXLock(true)
        DeadAirMeter.shared.resetForTesting()
        r.seq.skipNext()
        await waitUntil("d2 engaged at its start") { r.dsp.loadedSongId == "d2" && r.seq.mixEngaged }
        XCTAssertFalse(r.seq.startRunwayHeldForTesting, "the lock engage closed the start window")
        await settle(); await settle()
        XCTAssertEqual(DeadAirMeter.shared.day().transitions, 1, "exactly one transition — no double first audio")
        XCTAssertFalse(r.player.firstAudioPendingForTesting, "the idled AVPlayer owes no first audio")
    }

    /// A local row the AVPlayer can play but the DSP CAN'T open (AVAudioFile refuses it — it picks
    /// its decoder by extension, a corrupt / mislabelled burn): the FX Lock's start engage must
    /// leave the track on the AVPlayer. It used to idle the AVPlayer and claim the card for a DSP
    /// that never engaged — "playing" over dead air for the whole track.
    func testDSPRefusingTheFileLeavesTheTrackOnTheAVPlayer() async throws {
        let r = try rig(["g1", "g2"])
        // g2's burn: bytes AVAudioFile can't read.
        let dir = try XCTUnwrap(r.burns.appBurnsDirOverride)
        try Data(repeating: 0x5A, count: 4096).write(to: dir.appendingPathComponent("burn-g2.wav"))
        try await startEngaged(r, ["g1", "g2"])
        r.dsp.setEffect(.reverb, enabled: true)
        r.seq.setFXLock(true)
        r.seq.skipNext()
        await waitUntil("g2 started") { r.rips.nowPlaying?.songId == "g2" }
        XCTAssertFalse(r.seq.mixEngaged, "the DSP refused the file — nothing may claim it engaged")
        XCTAssertFalse(r.dsp.isEngaged)
        XCTAssertEqual(r.seq.fxLockIndicator, .waiting, "dry, lock kept")
        XCTAssertTrue(r.seq.fxLock.wantsFX, "the lock carries on")
    }
}
