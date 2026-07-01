import XCTest
import AVFoundation
@testable import PocketDJ

/// MixEngine — the first-party AVAudioEngine DSP backend (tempo / pitch / seek / beat-match +
/// per-effect strength). Split into:
///  • PURE math (octave-fold + sync ratio) — no instance, no audio.
///  • CLAMP invariants (rate/pitch/strength/crossfader) — exercised on an un-built engine.
///  • A real-graph STRESS test — builds the engine on the sim, loads two generated WAVs, and drives
///    240 mixed ops asserting invariants never break + the graph never crashes (skipped on a host
///    with no audio device).
@MainActor
final class MixEngineTests: XCTestCase {

    // MARK: - Pure beat-match math

    func testOctaveFoldKeepsInRangeValues() {
        XCTAssertEqual(MixEngine.octaveFolded(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.octaveFolded(1.5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.octaveFolded(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.octaveFolded(2.0), 2.0, accuracy: 1e-9)
    }

    func testOctaveFoldHalvesAndDoublesIntoRange() {
        XCTAssertEqual(MixEngine.octaveFolded(2.5), 1.25, accuracy: 1e-9)   // ÷2
        XCTAssertEqual(MixEngine.octaveFolded(4.0), 2.0, accuracy: 1e-9)    // ÷2 → 2.0 (upper bound, in range)
        XCTAssertEqual(MixEngine.octaveFolded(4.5), 1.125, accuracy: 1e-9)  // ÷2 ÷2
        XCTAssertEqual(MixEngine.octaveFolded(0.4), 0.8, accuracy: 1e-9)    // ×2
        XCTAssertEqual(MixEngine.octaveFolded(0.2), 0.8, accuracy: 1e-9)    // ×2 ×2
    }

    func testOctaveFoldGuardsBadInput() {
        XCTAssertEqual(MixEngine.octaveFolded(0), 1.0)
        XCTAssertEqual(MixEngine.octaveFolded(-3), 1.0)
        XCTAssertEqual(MixEngine.octaveFolded(.nan), 1.0)
        XCTAssertEqual(MixEngine.octaveFolded(.infinity), 1.0)
    }

    func testSyncRateMatchesEffectiveBPM() {
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 120, leadRate: 1, followerBPM: 120), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 120, leadRate: 1, followerBPM: 100), 1.2, accuracy: 1e-9)
        // Half/double-time fold: a 128 lead over a 64 follower = ×2 (in range).
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 128, leadRate: 1, followerBPM: 64), 2.0, accuracy: 1e-9)
        // 174 DnB lead over an 87 follower folds to 2.0 as well.
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 174, leadRate: 1, followerBPM: 87), 2.0, accuracy: 1e-9)
        // The lead's own tempo nudge carries into the match.
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 120, leadRate: 1.05, followerBPM: 120), 1.05, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.syncRate(leadBPM: 120, leadRate: 1, followerBPM: 0), 1.0)   // unknown follower BPM
    }

    // MARK: - Clamp invariants (no audio device needed)

    func testRatePitchStrengthCrossfaderClamp() {
        let e = makeEngine()
        e.setRate(3.0, on: .a);  XCTAssertEqual(e.rate(.a), 2.0)
        e.setRate(0.1, on: .a);  XCTAssertEqual(e.rate(.a), 0.5)
        e.setRate(1.25, on: .a); XCTAssertEqual(e.rate(.a), 1.25)

        e.setPitch(99, on: .b);  XCTAssertEqual(e.pitch(.b), 12)
        e.setPitch(-99, on: .b); XCTAssertEqual(e.pitch(.b), -12)
        e.setPitch(3.5, on: .b); XCTAssertEqual(e.pitch(.b), 3.5)

        e.setEffectStrength(.reverb, 1.7, on: .a);  XCTAssertEqual(e.strength(.reverb, on: .a), 1.0)
        e.setEffectStrength(.reverb, -0.4, on: .a); XCTAssertEqual(e.strength(.reverb, on: .a), 0.0)
        e.setEffectStrength(.reverb, 0.66, on: .a); XCTAssertEqual(e.strength(.reverb, on: .a), 0.66, accuracy: 1e-9)

        e.setCrossfader(5);    XCTAssertEqual(e.crossfader, 1.0)
        e.setCrossfader(-5);   XCTAssertEqual(e.crossfader, 0.0)
        e.setCrossfader(0.3);  XCTAssertEqual(e.crossfader, 0.3, accuracy: 1e-9)
    }

    /// Reset (↺) returns EVERY per-deck parameter to default: tempo, pitch, volume, all effects off,
    /// and effect strengths back to 0.5.
    func testResetDeckClearsAllParameters() {
        let e = makeEngine()
        e.setRate(1.6, on: .a)
        e.setPitch(7, on: .a)
        e.setVolume(0.2, on: .a)
        e.setEffect(.reverb, enabled: true, on: .a)
        e.setEffectStrength(.reverb, 0.9, on: .a)
        e.setEffect(.filter, enabled: true, on: .a)
        e.resetDeck(.a)
        XCTAssertEqual(e.rate(.a), 1.0)
        XCTAssertEqual(e.pitch(.a), 0.0)
        XCTAssertEqual(e.volume(.a), 1.0)
        XCTAssertFalse(e.isEnabled(.reverb, on: .a))
        XCTAssertFalse(e.isEnabled(.filter, on: .a))
        XCTAssertEqual(e.strength(.reverb, on: .a), 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.strength(.filter, on: .a), 0.5, accuracy: 1e-9)
    }

    func testLeadToggleAndCanSync() {
        let e = makeEngine()
        XCTAssertNil(e.leadDeck)
        e.setLead(.a); XCTAssertTrue(e.isLead(.a)); XCTAssertEqual(e.leadDeck, .a)
        e.setLead(.a); XCTAssertNil(e.leadDeck)              // tapping the lead clears it
        e.setLead(.b); XCTAssertTrue(e.isLead(.b))
        XCTAssertFalse(e.canSync(.a))                        // nothing loaded → can't sync
    }

    // MARK: - Real-graph stress test

    func testStressDriveGraphThroughManyOps() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        let a = try makeSineWAV(seconds: 2)
        let b = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        e.loadFile(a, release: nil, startMs: nil, meta: meta("a", bpm: 120), on: .a)
        e.loadFile(b, release: nil, startMs: nil, meta: meta("b", bpm: 100), on: .b)
        XCTAssertNotNil(e.loaded(.a))
        XCTAssertNotNil(e.loaded(.b))
        XCTAssertEqual(e.duration(.a), 2.0, accuracy: 0.1)

        let decks: [MixEngine.Deck] = [.a, .b]
        for i in 0..<240 {
            let d = decks[i % 2]
            switch i % 12 {
            case 0:  e.setRate(0.3 + Double(i % 30) / 10, on: d)     // spans out-of-range → must clamp
            case 1:  e.setPitch(Double(i % 40) - 20, on: d)         // spans out-of-range → must clamp
            case 2:  e.setEffect(.reverb, enabled: i % 2 == 0, on: d)
            case 3:  e.setEffect(.filter, enabled: i % 3 == 0, on: d)
            case 4:  e.setEffect(.compressor, enabled: i % 2 == 1, on: d)
            case 5:  e.setEffect(.flanger, enabled: i % 4 == 0, on: d)
            case 6:  e.setEffectStrength(.filter, Double(i % 11) / 10, on: d)
            case 7:  e.setCrossfader(Double(i % 11) / 10)
            case 8:  e.play(d)
            case 9:  e.seek(d, toSeconds: Double(i % 3))
            case 10: e.restart(d)
            default: e.pause(d)
            }
            XCTAssertTrue(MixEngine.rateRange.contains(e.rate(d)), "rate \(e.rate(d)) out of range at \(i)")
            XCTAssertTrue(MixEngine.pitchRange.contains(e.pitch(d)), "pitch out of range at \(i)")
            XCTAssertGreaterThanOrEqual(e.position(d), 0)
            XCTAssertLessThanOrEqual(e.position(d), e.duration(d) + 0.05)
            XCTAssertTrue(e.isReady, "engine fell over at op \(i)")
        }

        // Beat-match: reload (resets rate to 1), Lead A(120) → Sync B(100) ⇒ rate 1.2.
        e.loadFile(a, release: nil, startMs: nil, meta: meta("a", bpm: 120), on: .a)
        e.loadFile(b, release: nil, startMs: nil, meta: meta("b", bpm: 100), on: .b)
        e.setLead(.a)
        e.play(.a); e.play(.b)
        e.syncToLead(.b)
        XCTAssertEqual(e.rate(.b), 1.2, accuracy: 1e-6)

        e.teardown()
        XCTAssertNil(e.loaded(.a))
    }

    func testAnalogStartMsWindowsTheSegment() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        // A shared-album fallback starting 0.5 s in, no length bound ⇒ the deck plays to end-of-file (1.5 s).
        e.loadFile(url, release: nil, startMs: 500, meta: meta("x", bpm: nil), on: .a)
        XCTAssertEqual(e.duration(.a), 1.5, accuracy: 0.1)
        e.seek(.a, toSeconds: 1.0)
        XCTAssertEqual(e.position(.a), 1.0, accuracy: 1e-6)
    }

    // MARK: - Adversarial-review regressions (confirmed crash/bug findings)

    /// #3 — an analog shared-album fallback must be BOUNDED to its [startMs, startMs+lengthMs) slice,
    /// not play to end-of-side. With a length window the deck duration is the song length, and a seek
    /// can't scrub past the slice into the next song.
    func testLengthWindowBoundsTheSongSlice() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        // Start 0.5 s in, window 1.0 s ⇒ duration 1.0 s even though 2.5 s remain in the file.
        e.loadFile(url, release: nil, startMs: 500, lengthMs: 1000, meta: meta("x", bpm: nil), on: .a)
        XCTAssertEqual(e.duration(.a), 1.0, accuracy: 0.05)
        e.seek(.a, toSeconds: 5.0)                       // past the window
        XCTAssertLessThanOrEqual(e.position(.a), 1.0 + 1e-6)
    }

    /// #1 — a MONO file (and a mono load AFTER a stereo one) must not reconfigure/crash the running
    /// effect chain. Before the fix this raised an uncatchable NSException on the first reconnect.
    func testMonoAndStereoLoadsDoNotCrashGraph() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let mono = try makeSineWAV(seconds: 1, channels: 1)
        let stereo = try makeSineWAV(seconds: 1, channels: 2)
        defer { [mono, stereo].forEach { try? FileManager.default.removeItem(at: $0) } }
        e.loadFile(mono, release: nil, startMs: nil, meta: meta("m", bpm: nil), on: .a)   // mono FIRST
        XCTAssertNotNil(e.loaded(.a)); XCTAssertTrue(e.isReady)
        e.play(.a)
        e.loadFile(stereo, release: nil, startMs: nil, meta: meta("s", bpm: nil), on: .a) // stereo→…
        e.loadFile(mono, release: nil, startMs: nil, meta: meta("m2", bpm: nil), on: .a)   // …→mono switch
        XCTAssertTrue(e.isReady)
    }

    /// #1 (sample-rate variant) — a 48 kHz file must not reconfigure/crash the canonical-44.1k chain.
    func test48kFileDoesNotCrashGraph() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let f48 = try makeSineWAV(seconds: 1, sr: 48_000)
        defer { try? FileManager.default.removeItem(at: f48) }
        e.loadFile(f48, release: nil, startMs: nil, meta: meta("48", bpm: nil), on: .b)
        XCTAssertNotNil(e.loaded(.b))
        e.play(.b)
        XCTAssertTrue(e.isReady)
    }

    /// #2 — an over-length startMs (window past EOF) must be rejected WITHOUT crashing and must leave
    /// the currently-loaded track intact (scheduling a zero-frame segment is an uncatchable crash).
    func testOverLengthStartMsIsRejectedAndPreservesCurrentTrack() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        e.loadFile(url, release: nil, startMs: nil, meta: meta("good", bpm: nil), on: .a)
        XCTAssertEqual(e.duration(.a), 2.0, accuracy: 0.1)
        // startMs beyond the 2 s file ⇒ no-op, current track preserved, no crash.
        e.loadFile(url, release: nil, startMs: 999_999, meta: meta("bad", bpm: nil), on: .a)
        XCTAssertEqual(e.loaded(.a)?.songId, "good")
        XCTAssertEqual(e.duration(.a), 2.0, accuracy: 0.1)
        XCTAssertTrue(e.isReady)
    }

    /// #10 — a load that fails to open the file must still invoke `release` (balance the security
    /// scope) and leave the deck empty.
    func testFailedLoadReleasesScope() {
        let e = makeEngine()
        var released = false
        let bad = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        e.loadFile(bad, release: { released = true }, startMs: nil, meta: meta("z", bpm: nil), on: .a)
        XCTAssertTrue(released, "the held scope must be released on the failure path")
        XCTAssertNil(e.loaded(.a))
    }

    /// #6 — a manual Pause during an Auto-DJ must END the auto-mix, not let the wall-clock machine
    /// resurrect playback. #11 — and it recenters the crossfader so the next manual mix isn't silent.
    func testManualPauseEndsAutoMixAndRecentersCrossfader() {
        let e = makeEngine()
        let item = MixEngine.AutoMixItem(loadable: loadable("x", bpm: 120, lengthMs: 180_000), durationMs: 180_000)
        e.startAutoMix([item], shuffled: false, lead: 15, fade: 3)
        XCTAssertTrue(e.autoMixing)
        XCTAssertEqual(e.crossfader, 0.0)             // auto-mix starts full-A
        e.pauseBoth()                                  // user hits master Pause
        XCTAssertFalse(e.autoMixing, "manual pause must end the auto-mix")
        XCTAssertEqual(e.crossfader, 0.5, accuracy: 1e-9, "crossfader recenters on auto-mix end")
        e.teardown()
    }

    /// #11 — stopping the auto-mix recenters the crossfader (it oscillates fully 0↔1 during a mix).
    func testStopAutoMixRecentersCrossfader() {
        let e = makeEngine()
        let item = MixEngine.AutoMixItem(loadable: loadable("y", bpm: 120, lengthMs: 180_000), durationMs: 180_000)
        e.startAutoMix([item], shuffled: false, lead: 15, fade: 3)
        e.setCrossfader(1.0)                           // simulate having faded to B
        e.stopAutoMix()
        XCTAssertFalse(e.autoMixing)
        XCTAssertEqual(e.crossfader, 0.5, accuracy: 1e-9)
        e.teardown()
    }

    /// Toggling Auto ON→OFF without an actual auto-mix must NOT move or record the crossfader: a bare
    /// Manual→Auto→Manual flip otherwise injects a phantom `.crossfader` event (auto internals used to
    /// share the recording setter) that would materialize a junk session on Reset.
    func testAutoToggleWithoutMixingRecordsNoCrossfader() {
        let e = makeEngine()
        let rec = MockRecorder()
        e.recorder = rec
        let before = e.crossfader
        e.setAutoEnabled(true)
        e.setAutoEnabled(false)               // endAutoLoop with autoMixing == false → no recenter
        XCTAssertEqual(e.crossfader, before, accuracy: 1e-9, "no forced recenter without a real auto-mix")
        XCTAssertTrue(rec.events.allSatisfy { $0.kind != .crossfader },
                      "auto-internal fader moves must not be recorded as user gestures")
        e.teardown()
    }

    /// Beat-grid ingestion (#5): a deck's MEASURED grid BPM is preferred over the catalog BPM for
    /// sync. Lead grid 128 (catalog 120) over follower grid 100 ⇒ rate 1.28, not the catalog 1.2x.
    func testSyncPrefersMeasuredGridBpmOverCatalog() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let a = try makeSineWAV(seconds: 2)
        let b = try makeSineWAV(seconds: 2)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        var ma = meta("a", bpm: 120); ma.gridBpm = 128
        var mb = meta("b", bpm: 99);  mb.gridBpm = 100
        e.loadFile(a, release: nil, startMs: nil, meta: ma, on: .a)
        e.loadFile(b, release: nil, startMs: nil, meta: mb, on: .b)
        e.setLead(.a); e.play(.a); e.play(.b)
        e.syncToLead(.b)
        XCTAssertEqual(e.rate(.b), 1.28, accuracy: 1e-6)   // 128/100 grid, not 120/99 catalog
    }

    // MARK: - Now Playing (lock-screen) deck selection

    /// `nowPlayingDeck`: exactly one deck PLAYING → that deck ("the only active track"); zero or both
    /// playing → Deck A regardless of its play state; only B loaded → B; nothing loaded → nil.
    func testNowPlayingDeckPrefersThePlayingDeckElseDeckA() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        XCTAssertNil(e.nowPlayingDeck)                       // nothing loaded
        let a = try makeSineWAV(seconds: 2), b = try makeSineWAV(seconds: 2)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        e.loadFile(b, release: nil, startMs: nil, meta: meta("b", bpm: 120), on: .b)
        XCTAssertEqual(e.nowPlayingDeck, .b)                 // only B loaded → B
        e.loadFile(a, release: nil, startMs: nil, meta: meta("a", bpm: 120), on: .a)
        XCTAssertEqual(e.nowPlayingDeck, .a)                 // both loaded, none playing → Deck A
        e.play(.b)
        XCTAssertEqual(e.nowPlayingDeck, .b)                 // only B playing → the only active track
        XCTAssertEqual(e.nowPlaying?.songId, "b")
        e.play(.a)
        XCTAssertEqual(e.nowPlayingDeck, .a)                 // both playing → fall back to Deck A
        e.pause(.a)
        XCTAssertEqual(e.nowPlayingDeck, .b)                 // only B playing again
        e.teardown()
    }

    // MARK: - Cue / PFL (pre-fade listen)

    /// Cue state machine (no audio device needed): toggling per deck, `anyCued`, the 0…1 cue-volume
    /// clamp, and the cue-channel preference.
    func testCueToggleVolumeAndChannel() {
        let e = makeEngine()
        XCTAssertFalse(e.cued(.a)); XCTAssertFalse(e.cued(.b)); XCTAssertFalse(e.anyCued)
        XCTAssertEqual(e.cueVolume(.a), 1.0)                 // default monitor level
        e.setCued(true, on: .a)
        XCTAssertTrue(e.cued(.a)); XCTAssertTrue(e.anyCued); XCTAssertFalse(e.cued(.b))
        e.toggleCue(.a); XCTAssertFalse(e.cued(.a)); XCTAssertFalse(e.anyCued)
        e.toggleCue(.b); XCTAssertTrue(e.cued(.b)); XCTAssertTrue(e.anyCued)
        e.setCueVolume(1.5, on: .b);  XCTAssertEqual(e.cueVolume(.b), 1.0)
        e.setCueVolume(-0.2, on: .b); XCTAssertEqual(e.cueVolume(.b), 0.0)
        e.setCueVolume(0.4, on: .b);  XCTAssertEqual(e.cueVolume(.b), 0.4, accuracy: 1e-9)
        XCTAssertTrue(e.cueOnRight)                          // default
        e.setCueOnRight(false); XCTAssertFalse(e.cueOnRight)
        e.setCueOnRight(true);  XCTAssertTrue(e.cueOnRight)
    }

    /// Real-graph PFL routing: cueing a deck sends it to the CUE channel at full (pre-fader — even
    /// with the crossfader fully on the OTHER deck), leaves its MAIN send untouched, and pans
    /// main/cue to opposite output channels. Un-cued ⇒ cue silent + centered (normal stereo).
    func testCueRoutingIsPreFaderPFLAndPansToTheCueChannel() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let a = try makeSineWAV(seconds: 1), b = try makeSineWAV(seconds: 1)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        e.loadFile(a, release: nil, startMs: nil, meta: meta("a", bpm: 120), on: .a)
        e.loadFile(b, release: nil, startMs: nil, meta: meta("b", bpm: 120), on: .b)
        e.setCueOnRight(true)
        e.setCrossfader(0.0)                                  // full A on main → B's main send is ~0

        // Nothing cued: cue sends silent, both buses centered, main = equal-power crossfade.
        let a0 = try XCTUnwrap(e.cueRoutingSnapshot(.a)); let b0 = try XCTUnwrap(e.cueRoutingSnapshot(.b))
        XCTAssertEqual(a0.cueVol, 0, accuracy: 1e-6); XCTAssertEqual(b0.cueVol, 0, accuracy: 1e-6)
        XCTAssertEqual(a0.mainPan, 0, accuracy: 1e-6); XCTAssertEqual(b0.mainPan, 0, accuracy: 1e-6)
        XCTAssertEqual(a0.mainVol, 1.0, accuracy: 1e-5)       // full A
        XCTAssertEqual(b0.mainVol, 0.0, accuracy: 1e-5)       // B faded out of main

        // Cue B: monitors at FULL on the right, despite the crossfader sitting on A (pre-fader PFL);
        // its main send is unchanged; both decks' main pan to the house (left) side.
        e.setCued(true, on: .b)
        let b1 = try XCTUnwrap(e.cueRoutingSnapshot(.b)); let a1 = try XCTUnwrap(e.cueRoutingSnapshot(.a))
        XCTAssertEqual(b1.cueVol, 1.0, accuracy: 1e-6, "cue is pre-fader: full despite the crossfader on A")
        XCTAssertEqual(b1.cuePan, 1.0, accuracy: 1e-6, "cue panned to the right channel")
        XCTAssertEqual(b1.mainPan, -1.0, accuracy: 1e-6, "main panned to the house (left) side while cueing")
        XCTAssertEqual(a1.mainPan, -1.0, accuracy: 1e-6, "the other deck's main also goes to the house side")
        XCTAssertEqual(b1.mainVol, 0.0, accuracy: 1e-5, "cue did NOT push B back onto main")

        // Independent cue level.
        e.setCueVolume(0.5, on: .b)
        XCTAssertEqual(try XCTUnwrap(e.cueRoutingSnapshot(.b)).cueVol, 0.5, accuracy: 1e-6)

        // PFL is also pre-BOOST: the >unity boost lives on the shared EQ upstream of the split, so the
        // cue send divides it back out (`cueVol / max(vol,1)`) → at 200% the send halves so the boosted
        // signal lands at the same `cueVol` monitor level (boost-invariant).
        e.setVolume(2.0, on: .b)
        XCTAssertEqual(try XCTUnwrap(e.cueRoutingSnapshot(.b)).cueVol, 0.25, accuracy: 1e-6,
                       "cue send halves at 200% so the boost cancels → monitor stays at cueVol")
        e.setVolume(1.0, on: .b)
        XCTAssertEqual(try XCTUnwrap(e.cueRoutingSnapshot(.b)).cueVol, 0.5, accuracy: 1e-6)

        // Flip the cue channel to the left → pans invert live.
        e.setCueOnRight(false)
        let b2 = try XCTUnwrap(e.cueRoutingSnapshot(.b))
        XCTAssertEqual(b2.cuePan, -1.0, accuracy: 1e-6); XCTAssertEqual(b2.mainPan, 1.0, accuracy: 1e-6)

        // Un-cue: cue send silent, buses recenter → normal stereo.
        e.setCued(false, on: .b)
        let b3 = try XCTUnwrap(e.cueRoutingSnapshot(.b))
        XCTAssertEqual(b3.cueVol, 0, accuracy: 1e-6); XCTAssertEqual(b3.mainPan, 0, accuracy: 1e-6)
        e.teardown()
    }

    // MARK: - Beat grid (true playhead + per-beat hydration)

    /// `truePlayhead` reads the real audio render clock (not the wall-clock accumulator) and — the
    /// load-bearing bit — adds back the seek offset, so after seeking to 2 s it reports ~2 s, not the
    /// segment-relative 0 that `playerTime.sampleTime` resets to.
    func testTruePlayheadReadsAudioClockAndHonorsSeekOffset() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let url = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        e.loadFile(url, release: nil, startMs: nil, meta: meta("x", bpm: 120), on: .a)
        XCTAssertNil(e.truePlayhead(.a), "no render yet → nil (callers fall back to position)")
        e.play(.a)
        try await Task.sleep(nanoseconds: 250_000_000)        // let the engine render a little
        let p1 = try XCTUnwrap(e.truePlayhead(.a))
        XCTAssertGreaterThan(p1, 0); XCTAssertLessThan(p1, 3)
        e.seek(.a, toSeconds: 2.0)
        try await Task.sleep(nanoseconds: 200_000_000)
        let p2 = try XCTUnwrap(e.truePlayhead(.a))
        XCTAssertGreaterThan(p2, 1.9, "true playhead honors the seek offset, not segment-relative 0")
        e.teardown()
    }

    /// Enabling the pulse hydrates the loaded deck's per-beat grid from a LOCAL (burned) sidecar —
    /// no network — so the pulse can phase-lock to the real beats.
    func testEnablingPulseHydratesLocalBeatGrid() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let dir = try RipsStore.burnsDirectory()
        let sidecar = dir.appendingPathComponent("analysis-bg.json")
        try Data(#"{"beatsMs":[100,600,1100],"downbeatsMs":[100]}"#.utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        let url = try makeSineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        e.loadFile(url, release: nil, startMs: nil, meta: meta("bg", bpm: 120), on: .a)
        XCTAssertNil(e.loaded(.a)?.beatsMs, "loadFile alone doesn't hydrate")
        e.setBeatPulseEnabled(true)                           // hydrates the loaded deck from the local sidecar
        XCTAssertEqual(e.loaded(.a)?.beatsMs, [100, 600, 1100])
        XCTAssertEqual(e.loaded(.a)?.downbeatsMs, [100])
        e.teardown()
    }

    // MARK: - Auto-Mix manual skip

    /// A manual Skip kicks off a crossfade to the next track immediately (status → "fading") and stays
    /// in the mix.
    func testSkipToNextStartsAFadeAndStaysInTheMix() throws {
        let e = makeEngine()
        let q = [MixEngine.AutoMixItem(loadable: loadable("a", bpm: 120, lengthMs: 180_000), durationMs: 180_000),
                 MixEngine.AutoMixItem(loadable: loadable("b", bpm: 120, lengthMs: 180_000), durationMs: 180_000)]
        e.startAutoMix(q, shuffled: false, lead: 15, fade: 3)
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        XCTAssertTrue(e.autoMixing)
        e.skipToNext(fadeSeconds: 5)
        XCTAssertTrue(e.autoMixing, "skip keeps the mix running")
        XCTAssertEqual(e.autoStatus?.contains("fading"), true, "a manual skip starts a crossfade now")
        e.teardown()
    }

    /// Skip on the LAST queued track ends the mix (and recenters the fader) — mirrors the natural end.
    func testSkipToNextOnLastTrackEndsTheMix() throws {
        let e = makeEngine()
        let q = [MixEngine.AutoMixItem(loadable: loadable("only", bpm: 120, lengthMs: 180_000), durationMs: 180_000)]
        e.startAutoMix(q, shuffled: false, lead: 15, fade: 3)
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.skipToNext(fadeSeconds: 5)
        XCTAssertFalse(e.autoMixing, "no next track → the skip ends the mix")
        XCTAssertEqual(e.crossfader, 0.5, accuracy: 1e-9)
        e.teardown()
    }

    /// Skip outside an auto-mix is an inert no-op (guarded), never a crash.
    func testSkipToNextIsANoOpWhenNotAutoMixing() {
        let e = makeEngine()
        e.skipToNext(fadeSeconds: 5)
        XCTAssertFalse(e.autoMixing)
        e.teardown()
    }

    // MARK: - Stems (per-deck stem mode / mute / volume)

    func testStemNamesAreTheFourCanonical() {
        XCTAssertEqual(MixEngine.stemNames.count, 4)
        XCTAssertEqual(Set(MixEngine.stemNames), ["vocals", "drums", "bass", "other"])
    }

    func testStemStateDefaultsOff() {
        let e = makeEngine()
        XCTAssertFalse(e.stemModeOn(.a))
        XCTAssertFalse(e.stemActive(.a))                       // no stems wired
        XCTAssertFalse(e.isStemMuted("vocals", on: .a))
        XCTAssertEqual(e.stemVolume("vocals", on: .a), 1.0)
    }

    func testStemMuteTogglesPerDeck() {
        let e = makeEngine()
        e.toggleStemMute("drums", on: .a)
        XCTAssertTrue(e.isStemMuted("drums", on: .a))
        XCTAssertFalse(e.isStemMuted("drums", on: .b), "mute is per-deck")
        e.toggleStemMute("drums", on: .a)
        XCTAssertFalse(e.isStemMuted("drums", on: .a))
    }

    func testStemVolumeClampsZeroToOne() {
        let e = makeEngine()
        e.setStemVolume("bass", 1.5, on: .a);  XCTAssertEqual(e.stemVolume("bass", on: .a), 1.0)
        e.setStemVolume("bass", -0.3, on: .a); XCTAssertEqual(e.stemVolume("bass", on: .a), 0.0)
        e.setStemVolume("bass", 0.4, on: .a);  XCTAssertEqual(e.stemVolume("bass", on: .a), 0.4, accuracy: 1e-9)
    }

    /// Stem nodes carry ONLY their per-stem balance — NOT the deck volume (which lives downstream on
    /// the main bus). Regression for a double-gain (g²) bug: a stem at 0.8 stays 0.8 on the node even
    /// when the deck Vol is 0.5, so stem-mode main level isn't squared and the cue PFL stays pre-fader.
    func testStemNodesCarryOnlyPerStemBalanceNotDeckVolume() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.setVolume(0.5, on: .a)
        e.setStemVolume("bass", 0.8, on: .a)
        XCTAssertEqual(try XCTUnwrap(e.stemNodeVolume("bass", on: .a)), 0.8, accuracy: 1e-6,
                       "stem node volume is the per-stem balance, not deckVol×stemVol")
        e.toggleStemMute("bass", on: .a)
        XCTAssertEqual(try XCTUnwrap(e.stemNodeVolume("bass", on: .a)), 0.0, accuracy: 1e-6, "muted ⇒ 0")
        e.teardown()
    }

    /// No loaded track (and no burned stems) → entering stem mode is a no-op (stays off).
    func testSetStemModeWithoutTrackStaysOff() {
        let e = makeEngine()
        e.setStemMode(true, on: .a)
        XCTAssertFalse(e.stemModeOn(.a))
        XCTAssertFalse(e.stemActive(.a))
    }

    // MARK: - Gain boost (>unity volume) — math + clamps

    /// Volume clamps to the 0…2 (0%…200%) boost range.
    func testVolumeClampsZeroToTwo() {
        let e = makeEngine()
        e.setVolume(3.0, on: .a);  XCTAssertEqual(e.volume(.a), 2.0)
        e.setVolume(-1, on: .a);   XCTAssertEqual(e.volume(.a), 0.0)
        e.setVolume(1.5, on: .b);  XCTAssertEqual(e.volume(.b), 1.5, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.volumeRange, 0...2.0)
    }

    /// The gain SPLIT identity: source-node gain `min(v,1)` × the EQ boost `10^(20·log10(max(v,1))/20)`
    /// multiplies back to the intended `v`, and the source-node factor never exceeds 1.0 (the
    /// documented player/stem `volume` range). This is the invariant the >unity boost relies on.
    func testGainSplitIdentity() {
        for v in [0.0, 0.25, 0.5, 1.0, 1.25, 1.5, 2.0] {
            let source = min(v, 1.0)
            XCTAssertLessThanOrEqual(source, 1.0)
            let boost = pow(10.0, (20 * log10(max(v, 1.0))) / 20)
            XCTAssertEqual(source * boost, v, accuracy: 1e-9, "gain identity broke at v=\(v)")
        }
        // 200% is +6.02 dB on the EQ; unity is 0 dB.
        XCTAssertEqual(20 * log10(2.0), 6.0206, accuracy: 1e-3)
        XCTAssertEqual(20 * log10(1.0), 0.0, accuracy: 1e-12)
    }

    // MARK: - Session recording (the engine emits into a MixSessionRecorder)

    /// Every deck-parameter setter emits its session event into the wired recorder.
    func testSettersEmitSessionEvents() {
        let e = makeEngine()
        let rec = MockRecorder()
        e.recorder = rec
        e.setRate(1.2, on: .a)
        e.setPitch(3, on: .a)
        e.setVolume(1.5, on: .a)
        e.setCrossfader(0.7)
        e.setEffect(.reverb, enabled: true, on: .a)
        e.setEffectStrength(.reverb, 0.8, on: .a)
        e.toggleStemMute("vocals", on: .a)
        e.setStemVolume("bass", 0.5, on: .a)
        e.setLead(.a)
        e.resetDeck(.a)
        let kinds = Set(rec.events.map { $0.kind })
        for expected: MixEventKind in [.tempo, .pitch, .volume, .crossfader, .effectToggle,
                                       .effectStrength, .stemMute, .stemVolume, .lead, .resetDeck] {
            XCTAssertTrue(kinds.contains(expected), "missing \(expected) event")
        }
        // Crossfader is a GLOBAL event (no deck); tempo is deck-scoped.
        XCTAssertNil(rec.events.first { $0.kind == .crossfader }?.deck)
        XCTAssertEqual(rec.events.first { $0.kind == .tempo }?.deck, "A")
    }

    /// A real load → play records `.load` + `.play` and marks the song played exactly once.
    func testLoadAndPlayRecordsAndMarksPlayed() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let rec = MockRecorder()
        e.recorder = rec
        let url = try makeSineWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        e.loadFile(url, release: nil, startMs: nil, meta: meta("song-x", bpm: 120), on: .a)
        e.play(.a)
        e.play(.a)        // idempotent re-issue → NO second .play
        XCTAssertEqual(rec.events.filter { $0.kind == .load }.count, 1)
        XCTAssertEqual(rec.events.filter { $0.kind == .play }.count, 1)
        XCTAssertEqual(rec.played, ["song-x"])
        e.pause(.a)
        XCTAssertEqual(rec.events.filter { $0.kind == .pause }.count, 1)
        e.teardown()
    }

    /// No recorder wired ⇒ recording is a silent no-op (the engine still works).
    func testNoRecorderIsNoOp() {
        let e = makeEngine()
        e.setRate(1.3, on: .a)        // must not crash with recorder == nil
        XCTAssertEqual(e.rate(.a), 1.3, accuracy: 1e-9)
    }

    // MARK: - Audio recording (capture the mixed house output to a file)

    /// End-to-end: recording the live graph produces a NON-EMPTY, DECODABLE audio file — proves the
    /// master-limiter tap → MixTapWriter → AAC write path actually yields valid output (the format
    /// match between the tap buffer and the AVAudioFile write is only exercisable on a real graph).
    func testRecordingCapturesAPlayableFile() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("rec-song", bpm: 120), on: .a)
        e.play(.a)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mixrec-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(e.startRecording(to: out, release: nil))
        XCTAssertTrue(e.isRecording)
        try await Task.sleep(nanoseconds: 500_000_000)   // let the graph render into the tap
        e.stopRecording()
        XCTAssertFalse(e.isRecording)
        // AVAssetWriter.finishWriting is async — poll until the file finalizes to a decodable take.
        let frames = try await Self.pollForAudioFrames(at: out)
        XCTAssertGreaterThan(frames, 0, "recording should finalize to a decodable, non-empty file")
        e.teardown()
    }

    /// Poll (up to ~4 s) for `url` to open as a non-empty audio file — AVAssetWriter finalizes async.
    private static func pollForAudioFrames(at url: URL) async throws -> AVAudioFramePosition {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let f = try? AVAudioFile(forReading: url), f.length > 0 { return f.length }
        }
        return 0
    }

    /// Crash-safety: fragments flush to disk WHILE recording, so a take survives an app kill (no clean
    /// stop / finalize). Records past the fragment interval, then — without stopping — asserts the file
    /// on disk already holds audio.
    func testRecordingFlushesFragmentsForCrashSafety() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("x", bpm: 120), on: .a)
        e.play(.a)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("crashrec-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(e.startRecording(to: out, release: nil))
        try await Task.sleep(nanoseconds: 3_000_000_000)   // past the 2 s fragment interval → a fragment flushes
        // WITHOUT stopping (simulating a crash), the on-disk file already carries data.
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "a fragment must be flushed mid-recording so a crash keeps the audio")
        e.stopRecording()
        e.teardown()
    }

    /// Stopping a recording must NOT stop playback. Asserted at the AUDIO layer via `truePlayhead` (the
    /// real render clock) — the persistent tap means stop never reconfigures the graph, so the deck's
    /// clock keeps advancing. (Regression: stop used to `removeTap`, which paused the decks on-device.)
    func testStoppingRecordingDoesNotStopPlayback() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let src = try makeSineWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: src) }
        e.loadFile(src, release: nil, startMs: nil, meta: meta("x", bpm: 120), on: .a)
        e.play(.a)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(e.startRecording(to: out, release: nil))
        try await Task.sleep(nanoseconds: 250_000_000)
        e.stopRecording()
        let before = try XCTUnwrap(e.truePlayhead(.a))
        try await Task.sleep(nanoseconds: 300_000_000)         // let the render clock advance post-stop
        let after = try XCTUnwrap(e.truePlayhead(.a))
        XCTAssertTrue(e.isPlaying(.a), "the deck is still logically playing")
        XCTAssertGreaterThan(after, before, "the audio render clock must keep advancing after stop")
        e.teardown()
    }

    /// A second startRecording while already recording is rejected (no dangling second tap/file), and
    /// stopRecording is idempotent.
    func testStartRecordingTwiceRejectedAndStopIsIdempotent() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let out1 = FileManager.default.temporaryDirectory.appendingPathComponent("rec1-\(UUID().uuidString).m4a")
        let out2 = FileManager.default.temporaryDirectory.appendingPathComponent("rec2-\(UUID().uuidString).m4a")
        defer { [out1, out2].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertTrue(e.startRecording(to: out1, release: nil))
        XCTAssertFalse(e.startRecording(to: out2, release: nil), "already recording → rejected")
        e.stopRecording()
        e.stopRecording()                                 // idempotent — no crash / no double-release
        XCTAssertFalse(e.isRecording)
        e.teardown()
    }

    /// The scope-release contract: on a host with NO audio device, a start fails and drops the passed
    /// scope release rather than leaking it. (On the simulator the graph builds and the start succeeds,
    /// so this only asserts on a headless host; the file is cleaned up either way.)
    func testStartRecordingReleasesScopeOnFailure() {
        let e = makeEngine()               // NOT ensureEngine'd; a headless host stays unbuilt → start fails
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("recfail-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        var released = false
        let ok = e.startRecording(to: out, release: { released = true })
        if !ok { XCTAssertTrue(released, "a failed start must drop the security scope, not leak it") }
        e.teardown()                        // finalizes the capture on a host where it did start
    }

    /// Recording while a deck is CUED still captures the clean STEREO house mix (the tap is on the
    /// pre-cue-pan house sum), not the mono-collapsed house + private cue bleed. Guards the review's
    /// confirmed cue/recording finding.
    func testRecordingWhileCuedCapturesCleanStereoHouse() async throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let a = try makeSineWAV(seconds: 1), b = try makeSineWAV(seconds: 1)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        e.loadFile(a, release: nil, startMs: nil, meta: meta("a", bpm: 120), on: .a)
        e.loadFile(b, release: nil, startMs: nil, meta: meta("b", bpm: 120), on: .b)
        e.setCueOnRight(true)
        e.setCrossfader(0.0)                 // full A on the house
        e.play(.a); e.play(.b)
        e.setCued(true, on: .b)              // monitor B in the cue — must NOT pollute the recording
        // The house is steered to the monitor's house side (pan on `housePan`, DOWNSTREAM of the tap)…
        XCTAssertEqual(try XCTUnwrap(e.cueRoutingSnapshot(.a)).mainPan, -1, accuracy: 1e-6)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cuerec-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(e.startRecording(to: out, release: nil))
        try await Task.sleep(nanoseconds: 500_000_000)
        e.stopRecording()
        _ = try await Self.pollForAudioFrames(at: out)     // wait for async finalize
        // …so the take stays full STEREO (not mono-collapsed) and is a valid audio file.
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.channelCount, 2, "capture is stereo house, not cue-pan collapsed")
        XCTAssertGreaterThan(f.length, 0)
        e.teardown()
    }

    // MARK: - Mix Glide (Camelot harmonic glide math)

    /// Signed Camelot-hour distance wraps to the SHORTEST way round the 12-hour wheel (−6…+6).
    func testSignedCamelotSteps() {
        XCTAssertEqual(MixEngine.signedCamelotSteps("5A", "9A"), 4)     // the spec example
        XCTAssertEqual(MixEngine.signedCamelotSteps("9A", "5A"), -4)
        XCTAssertEqual(MixEngine.signedCamelotSteps("5A", "5A"), 0)
        XCTAssertEqual(MixEngine.signedCamelotSteps("1A", "12A"), -1)   // wrap: shortest is DOWN one
        XCTAssertEqual(MixEngine.signedCamelotSteps("12A", "1A"), 1)
        XCTAssertEqual(MixEngine.signedCamelotSteps("2A", "8A"), 6)     // exactly opposite → +6
        XCTAssertEqual(MixEngine.signedCamelotSteps("5A", "12A"), -5)   // shortest is DOWN five
        XCTAssertNil(MixEngine.signedCamelotSteps("nope", "9A"))
        XCTAssertNil(MixEngine.signedCamelotSteps(nil, "9A"))
    }

    /// PITCH bend (A=5A, B=9A) comes from Camelot: outgoing up ~1.65 st, incoming down ~1.65 st. With
    /// no BPM there is NO tempo bend (rate stays 1.0).
    func testGlideParamsPitchFromCamelotOnly() {
        let p = MixEngine.glideParams(fromCamelot: "5A", toCamelot: "9A", fromBPM: nil, toBPM: nil)
        XCTAssertEqual(p.outPitch, MixEngine.semitonesPerKey, accuracy: 1e-9)
        XCTAssertEqual(p.inPitch, -MixEngine.semitonesPerKey, accuracy: 1e-9)
        XCTAssertEqual(p.outRate, 1.0, accuracy: 1e-9, "no BPM ⇒ no tempo bend")
        XCTAssertEqual(p.inRate, 1.0, accuracy: 1e-9)
    }

    /// Direction flips when the incoming key is LOWER (outgoing pitch bends down, incoming up).
    func testGlideParamsPitchDirectionFlips() {
        let p = MixEngine.glideParams(fromCamelot: "9A", toCamelot: "5A", fromBPM: nil, toBPM: nil)
        XCTAssertEqual(p.outPitch, -MixEngine.semitonesPerKey, accuracy: 1e-9)
        XCTAssertEqual(p.inPitch, MixEngine.semitonesPerKey, accuracy: 1e-9)
    }

    /// TEMPO bend comes from BPM only: two BPMs bend toward their mean, capped ±10%; no camelot ⇒ no
    /// pitch bend. (128 & 140 → mean ≈133.8 → outRate ≈1.045, inRate ≈0.956.)
    func testGlideParamsTempoFromBPMOnly() {
        let p = MixEngine.glideParams(fromCamelot: nil, toCamelot: nil, fromBPM: 128, toBPM: 140)
        XCTAssertEqual(p.outRate, sqrt(128.0 * 140) / 128, accuracy: 1e-6)
        XCTAssertEqual(p.inRate, sqrt(128.0 * 140) / 140, accuracy: 1e-6)
        XCTAssertTrue((0.9...1.1).contains(p.outRate) && (0.9...1.1).contains(p.inRate))
        XCTAssertEqual(p.outPitch, 0, "no camelot ⇒ no pitch bend")
        XCTAssertEqual(p.inPitch, 0)
    }

    /// Far-apart BPMs clamp the tempo bend to ±10% (subtle, not a full match).
    func testGlideParamsTempoCapsAtTenPercent() {
        let p = MixEngine.glideParams(fromCamelot: nil, toCamelot: nil, fromBPM: 128, toBPM: 90)
        XCTAssertEqual(p.outRate, 0.9, accuracy: 1e-9)
        XCTAssertEqual(p.inRate, 1.1, accuracy: 1e-9)
    }

    /// Half/double-time BPMs octave-match to ~1:1 (already aligned → little/no bend).
    func testGlideParamsTempoOctaveMatches() {
        let p = MixEngine.glideParams(fromCamelot: nil, toCamelot: nil, fromBPM: 128, toBPM: 64)
        XCTAssertEqual(p.outRate, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.inRate, 1.0, accuracy: 1e-6)
    }

    /// NO default: with neither Camelot nor BPM known for both tracks, Mix Glide is identity — just
    /// the volume crossfade, no pitch/tempo bend.
    func testGlideParamsIdentityWhenNoData() {
        for c in [("5A", "5A"), (nil, "9A"), ("5A", "zz"), (nil, nil)] as [(String?, String?)] {
            let p = MixEngine.glideParams(fromCamelot: c.0, toCamelot: c.1, fromBPM: nil, toBPM: 120)
            XCTAssertEqual(p.outRate, 1.0); XCTAssertEqual(p.inRate, 1.0)
            XCTAssertEqual(p.outPitch, 0); XCTAssertEqual(p.inPitch, 0)
        }
    }

    /// A key → tempo/pitch mapping clamps to the engine's rate/pitch ranges.
    func testGlideRateAndPitchClamp() {
        XCTAssertEqual(MixEngine.glideRate(keys: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(MixEngine.glideRate(keys: 1), 1.10, accuracy: 1e-12)
        XCTAssertEqual(MixEngine.glideRate(keys: -1), 0.90, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(MixEngine.glideRate(keys: 100), MixEngine.rateRange.upperBound)
        XCTAssertGreaterThanOrEqual(MixEngine.glideRate(keys: -100), MixEngine.rateRange.lowerBound)
        XCTAssertEqual(MixEngine.glidePitch(keys: 1), MixEngine.semitonesPerKey, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(MixEngine.glidePitch(keys: 100), MixEngine.pitchRange.upperBound)
        XCTAssertGreaterThanOrEqual(MixEngine.glidePitch(keys: -100), MixEngine.pitchRange.lowerBound)
    }

    // MARK: - FX Glide (texture coherence)

    /// Texture rolls are deterministic given a seed, and every roll is within the documented bounds
    /// (effect ∈ pool, peak ∈ 0.5…0.8, run ∈ 3…5).
    func testRollTextureIsDeterministicAndBounded() {
        var s1: UInt64 = 0xABCDEF, s2: UInt64 = 0xABCDEF
        for _ in 0..<32 {
            let a = MixEngine.rollTexture(&s1)
            let b = MixEngine.rollTexture(&s2)
            XCTAssertEqual(a.effect.rawValue, b.effect.rawValue)         // reproducible
            XCTAssertEqual(a.peak, b.peak, accuracy: 1e-12)
            XCTAssertEqual(a.run, b.run)
            XCTAssertTrue(MixEngine.fxGlidePool.contains { $0.rawValue == a.effect.rawValue })
            XCTAssertTrue((0.5...0.8).contains(a.peak))
            XCTAssertTrue((3...5).contains(a.run))
        }
    }

    /// The compressor is deliberately NOT in the FX-Glide pool (it's a dynamics tool, not a sweep).
    func testFXGlidePoolIsSweepEffectsOnly() {
        XCTAssertEqual(MixEngine.fxGlidePool.count, 3)
        XCTAssertFalse(MixEngine.fxGlidePool.contains { $0.rawValue == MixEngine.Effect.compressor.rawValue })
    }

    /// The per-mix texture seed is deterministic per track set (no wall-clock randomness).
    func testFxSeedIsDeterministicPerQueue() {
        let a = [MixEngine.AutoMixItem(loadable: loadable("song-a", bpm: 120, lengthMs: 1000), durationMs: 1000)]
        let b = [MixEngine.AutoMixItem(loadable: loadable("song-b", bpm: 120, lengthMs: 1000), durationMs: 1000)]
        XCTAssertEqual(MixEngine.fxSeed(from: a), MixEngine.fxSeed(from: a))
        XCTAssertNotEqual(MixEngine.fxSeed(from: a), MixEngine.fxSeed(from: b))
    }

    // MARK: - Glide toggles + transition wiring

    func testGlideTogglesDefaultOffAndSettable() {
        let e = makeEngine()
        XCTAssertFalse(e.fxGlideEnabled)
        XCTAssertFalse(e.mixGlideEnabled)
        e.setFXGlide(true); e.setMixGlide(true)
        XCTAssertTrue(e.fxGlideEnabled)
        XCTAssertTrue(e.mixGlideEnabled)
        e.setFXGlide(false)
        XCTAssertFalse(e.fxGlideEnabled)
        XCTAssertTrue(e.mixGlideEnabled)
        e.teardown()
    }

    /// A glide-armed manual skip keeps the mix running AND records the transition as compact `.glide`
    /// nodes (from/to/rate) — including the CROSSFADER — instead of ~100 sampled points, so a replay
    /// reconstructs it losslessly. The machine sweep never masquerades as a sampled user `.crossfader`.
    func testGlideSkipRecordsCompactGlideNodesIncludingCrossfader() throws {
        let e = makeEngine()
        let rec = MockRecorder()
        e.recorder = rec
        let q = [MixEngine.AutoMixItem(loadable: loadable("a", bpm: 120, lengthMs: 180_000), durationMs: 180_000),
                 MixEngine.AutoMixItem(loadable: loadable("b", bpm: 120, lengthMs: 180_000), durationMs: 180_000)]
        e.setFXGlide(true); e.setMixGlide(true)
        e.startAutoMix(q, shuffled: false, lead: 15, fade: 3)
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        e.skipToNext(fadeSeconds: 5)                       // glide skip → must not crash
        XCTAssertTrue(e.autoMixing, "glide skip keeps the mix running")
        XCTAssertTrue(e.autoStatus?.contains("fading") == true)
        XCTAssertTrue(rec.glides.contains { $0.param == "crossfader" }, "the crossfade is captured as a .glide node")
        // No per-tick sampled automation for the machine sweep (that's what the compact node replaces).
        XCTAssertFalse(rec.events.contains { $0.kind == .crossfader },
                       "the machine crossfade is a .glide node, not a sampled .crossfader gesture")
        // A .glide carries from/to/rate (not just a single value).
        if let g = rec.glides.first(where: { $0.param == "crossfader" }) {
            XCTAssertNotEqual(g.from, g.to)
            XCTAssertNotEqual(g.rate, 0)
        }
        e.teardown()
    }

    /// Stopping an auto-mix restores a pristine crossfader even with the glide features armed (the
    /// glide teardown path must not leave the engine in a partial-transition state).
    func testStopWithGlideArmedRecentersCleanly() {
        let e = makeEngine()
        e.setFXGlide(true); e.setMixGlide(true)
        let item = MixEngine.AutoMixItem(loadable: loadable("z", bpm: 120, lengthMs: 180_000), durationMs: 180_000)
        e.startAutoMix([item], shuffled: false, lead: 15, fade: 3)
        e.stopAutoMix()
        XCTAssertFalse(e.autoMixing)
        XCTAssertEqual(e.crossfader, 0.5, accuracy: 1e-9)
        e.teardown()
    }

    // MARK: - Helpers

    /// Captures the engine's emitted session events without any persistence (test double).
    private final class MockRecorder: MixSessionRecorder {
        var events: [(kind: MixEventKind, deck: String?, value: Double?)] = []
        var glides: [(param: String, deck: String?, from: Double, to: Double, rate: Double)] = []
        var played: [String] = []
        func logEvent(_ kind: MixEventKind, deck: String?, songId: String?, title: String?,
                      artist: String?, bpm: Double?, camelot: String?, param: String?,
                      value: Double?, flag: Bool?, posMs: Int?) {
            events.append((kind, deck, value))
        }
        func logGlide(deck: String?, param: String, songId: String?, title: String?, artist: String?,
                      from: Double, to: Double, rate: Double, posMs: Int?) {
            glides.append((param: param, deck: deck, from: from, to: to, rate: rate))
            events.append((.glide, deck, to))
        }
        func notePlayed(songId: String) { played.append(songId) }
    }

    private func makeEngine() -> MixEngine {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtest-burns-\(UUID().uuidString).json")
        return MixEngine(burns: BurnStore(rips: rips, fileURL: url))
    }

    private func meta(_ id: String, bpm: Double?) -> MixEngine.LoadedTrack {
        MixEngine.LoadedTrack(songId: id, title: "T-\(id)", artist: "A", bpm: bpm,
                              camelot: nil, key: nil, albumId: nil)
    }

    /// A short sine WAV on disk (configurable channels + sample rate) so `loadFile` exercises the
    /// REAL decode + schedule path — including the mono / non-44.1k formats that used to crash.
    private func makeSineWAV(seconds: Double, sr: Double = 44_100, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtest-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData!
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                ch[c][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sr)) * 0.2
            }
        }
        try file.write(from: buf)
        return url
    }

    private func loadable(_ id: String, bpm: Double?, lengthMs: Int?) -> MixLoadable {
        MixLoadable(songId: id, title: "T", artist: "A", bpm: bpm,
                    camelot: nil, key: nil, albumId: nil, lengthMs: lengthMs)
    }
}
