import AVFoundation
import XCTest
@testable import PocketDJ

/// Mix tab Auto-DJ VOLUME GLIDE (opt-in loudness leveling on each deck's trim) and the fader
/// automation the Mix tab shows (the crossfader sweeping through fades and skips).
@MainActor
final class MixVolumeGlideTests: XCTestCase {

    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), message)
    }

    private func makeEngine() -> (MixEngine, LoudnessCache) {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: .shared)
        let burnsURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-vg-burns-\(UUID().uuidString).json")
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-vg-loud-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: burnsURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let e = MixEngine(burns: BurnStore(rips: rips, fileURL: burnsURL))
        let cache = LoudnessCache(fileURL: cacheURL)
        e.loudnessCache = cache
        addTeardownBlock { @MainActor in e.stopAutoMix(); e.ejectAll() }
        return (e, cache)
    }

    private func sine(seconds: Double, amp: Float) throws -> URL {
        let sr = 44_100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 2 * .pi * 440 / Float(sr)) * amp }
        }
        try file.write(from: buf)
        return url
    }

    private func start(_ e: MixEngine, files: [String: URL], seconds: Double = 6) throws {
        e.studioResolve = { id in
            guard let url = files[id] else { return nil }
            return (url: url, release: nil, title: id, lengthMs: Int(seconds * 1000))
        }
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")
        let items = files.keys.sorted().map { id in
            MixEngine.AutoMixItem(loadable: MixLoadable(songId: id, title: id, artist: "A", bpm: 120, camelot: "8A",
                                                        key: "Am", albumId: nil, lengthMs: Int(seconds * 1000)),
                                  durationMs: Int(seconds * 1000))
        }
        e.startAutoMix(items, shuffled: false, lead: 15, fade: 3)
    }

    /// OFF (the default): no trim, no readout — the Auto-DJ is exactly what it was.
    func testOffByDefaultChangesNothing() async throws {
        let (e, _) = makeEngine()
        XCTAssertFalse(e.volumeGlideEnabled)
        try start(e, files: ["smp_o1": try sine(seconds: 6, amp: 0.5), "smp_o2": try sine(seconds: 6, amp: 0.05)])
        XCTAssertEqual(e.levelDbForTesting(.a), 0)
        XCTAssertEqual(e.levelDbForTesting(.b), 0)
        XCTAssertEqual(e.trimGainDbForTesting(.a), 0)
        XCTAssertEqual(e.deckLeveling[.a]?.status ?? .inactive, .inactive)
        XCTAssertEqual(e.deckLeveling[.b]?.status ?? .inactive, .inactive)
    }

    /// ON: each loaded deck is measured off-main and its trim lands (a loud song turned down, a
    /// quiet one up); the listener's Vol is untouched and still composes (boost + trim).
    func testOnLevelsBothDecksOnTheTrimNotTheFader() async throws {
        let (e, cache) = makeEngine()
        e.setVolumeGlide(true)
        let loud = try sine(seconds: 6, amp: 0.7), quiet = try sine(seconds: 6, amp: 0.03)
        try start(e, files: ["smp_l1": loud, "smp_l2": quiet])
        XCTAssertEqual(e.deckLeveling[.a]?.status, .measuring, "says measuring… until the analysis lands")
        await waitUntil("both measured") {
            e.deckLeveling[.a]?.status == .measured && e.deckLeveling[.b]?.status == .measured
                && e.levelRampsSettledForTesting
        }
        let ka = try XCTUnwrap(LoudnessCache.key(songId: "smp_l1", url: loud))
        let kb = try XCTUnwrap(LoudnessCache.key(songId: "smp_l2", url: quiet))
        let ga = try XCTUnwrap(cache.gainDb(for: ka)), gb = try XCTUnwrap(cache.gainDb(for: kb))
        XCTAssertLessThan(ga, 0, "the loud song is turned down")
        XCTAssertGreaterThan(gb, 0, "the quiet song is turned up")
        XCTAssertEqual(e.levelDbForTesting(.a), ga, accuracy: 0.05)
        XCTAssertEqual(e.levelDbForTesting(.b), gb, accuracy: 0.05)
        XCTAssertEqual(Double(e.trimGainDbForTesting(.a) ?? 99), ga, accuracy: 0.05)
        XCTAssertEqual(e.deckLeveling[.a]?.trimDb ?? 99, ga, accuracy: 0.05)
        XCTAssertEqual(e.volume(.a), 1, "the Vol fader never moves")
        e.setVolume(2, on: .a)                                   // +6 dB boost composes with the trim
        XCTAssertEqual(Double(e.trimGainDbForTesting(.a) ?? 99), 20 * log10(2) + ga, accuracy: 0.05)
        // Off again / the Auto-DJ ends → back to 0 dB, no readout.
        MixEngine.levelRampSeconds = 0.3
        defer { MixEngine.levelRampSeconds = LoudnessLeveling.rampSeconds }
        e.setVolumeGlide(false)
        await waitUntil("off → the trim ramps back to 0 dB") {
            e.levelDbForTesting(.a) == 0 && e.levelDbForTesting(.b) == 0 && e.levelRampsSettledForTesting
        }
        XCTAssertEqual(e.deckLeveling[.a]?.status ?? .inactive, .inactive)
    }

    /// The Auto-DJ ending takes its leveling with it.
    func testStopAutoMixClearsTheTrim() async throws {
        let (e, _) = makeEngine()
        e.setVolumeGlide(true)
        try start(e, files: ["smp_s1": try sine(seconds: 6, amp: 0.7), "smp_s2": try sine(seconds: 6, amp: 0.7)])
        await waitUntil("measured") { e.deckLeveling[.b]?.status == .measured }
        e.stopAutoMix()
        await waitUntil("trim gone") { e.levelDbForTesting(.a) == 0 && e.levelDbForTesting(.b) == 0 }
        XCTAssertEqual(e.deckLeveling[.a]?.status ?? .inactive, .inactive)
    }

    /// The fader AUTOMATION is visible: a skip's crossfade (tap = Skip fade, double-tap = the fast
    /// sweep) moves the observed `crossfader` through the middle, not just the audio.
    func testCrossfaderMovesThroughASkip() async throws {
        let (e, _) = makeEngine()
        try start(e, files: ["smp_x1": try sine(seconds: 8, amp: 0.3), "smp_x2": try sine(seconds: 8, amp: 0.3)])
        let from = e.crossfader
        e.skipToNext(fadeSeconds: 1.2)
        await waitUntil("the crossfader sweeps through the middle") { abs(e.crossfader - 0.5) < 0.35 && e.crossfader != from }
        await waitUntil("…and lands at the other end") { abs(e.crossfader - (1 - from)) < 0.01 }
    }
}
