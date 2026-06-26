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

    // MARK: - Helpers

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
