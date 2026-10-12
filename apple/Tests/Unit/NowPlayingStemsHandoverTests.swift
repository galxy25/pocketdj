import AVFoundation
import XCTest
@testable import PocketDJ

/// ZERO DEAD AIR across the Now Playing DSP's full song ↔ stems handover — the Mix deck's rule
/// (`MixStemsHandoverTests`) brought to `NowPlayingDSP`. Every scenario runs a real
/// `AVAudioEngine` and listens to the DSP's raw post-stem-merge signal at SAMPLE resolution
/// (`NowPlayingDSP.captureForTesting`), so "the song keeps playing" means real samples, and
/// "aligned" means one continuous read of the song with no replayed/skipped sliver and no flam.
///
/// Fixtures: the full song is the TAGGED noise mp3 (`stream-noise-12s`), each stem part the
/// HEADERLESS ¼-level copy (`stem-noise-12s`) — four parts sum back to the song and decode one
/// 576-sample priming granule late, exactly like real Demucs stems. `.mp3` names throughout
/// (AVAudioFile picks its decoder by EXTENSION).
@MainActor
final class NowPlayingStemsHandoverTests: XCTestCase {

    private var noiseMix: Data { get throws { try StemAudioProbe.bundled("stream-noise-12s", in: Self.self) } }
    private var noiseStem: Data { get throws { try StemAudioProbe.bundled("stem-noise-12s", in: Self.self) } }

    private struct Rig {
        let dsp: NowPlayingDSP
        let burns: BurnStore
        let loader: MixStreamLoader
        let burnDir: URL
    }

    /// A DSP over a hermetic burn store. `remote`: the catalog lists stems for `songId` (so a
    /// request is accepted even with nothing on disk). `streaming`: the stem lane is wired (parts
    /// are injected, never fetched).
    private func rig(_ songId: String, remote: Bool = true, streaming: Bool = true) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        if remote {
            rips.setManifest([songId: .init(key: "rips/\(songId).mp3",
                                            stems: .init(vocals: "stems/\(songId)/vocals.mp3", drums: "stems/\(songId)/drums.mp3",
                                                         bass: "stems/\(songId)/bass.mp3", other: "stems/\(songId)/other.mp3"))])
        }
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let dsp = NowPlayingDSP(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        if streaming { dsp.streamer = loader }
        addTeardownBlock { @MainActor in dsp.disengage() }
        return Rig(dsp: dsp, burns: burns, loader: loader, burnDir: try XCTUnwrap(burns.appBurnsDirOverride))
    }

    /// Engage the full song (playing) and wait until it is audibly rendering.
    private func engage(_ r: Rig, _ songId: String, play: Bool = true) async throws {
        let url = try StemAudioProbe.tempMP3(try noiseMix, tag: songId)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        r.dsp.engage(url: url, startMs: nil, lengthMs: nil, atSeconds: 0, songId: songId, play: play)
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        if play {
            await StemAudioProbe.wait { r.dsp.currentTime > 0.3 }
            XCTAssertGreaterThan(r.dsp.currentTime, 0.3, "precondition: the full song is playing")
        }
    }

    private func burnStems(_ r: Rig, _ songId: String) throws {
        let data = try noiseStem
        for n in MixEngine.stemNames {
            try data.write(to: r.burnDir.appendingPathComponent("stem-\(songId)-\(n).mp3"))
        }
    }

    /// Grow a file the way the loader's sink does — APPENDING (an open reader keeps its handle).
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
    private func streamStems(_ r: Rig, _ songId: String, fraction: Double, files: [String: URL]? = nil) throws -> [String: URL] {
        let data = try noiseStem
        let n = min(data.count, Int(Double(data.count) * fraction))
        var out = files ?? [:]
        var bytes: [String: Int64] = [:]
        for name in MixEngine.stemNames {
            let url = out[name] ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-npstem-\(songId)-\(name)-\(UUID().uuidString).mp3")
            if out[name] == nil { addTeardownBlock { try? FileManager.default.removeItem(at: url) } }
            try grow(url, to: data.prefix(n))
            out[name] = url
            bytes[name] = Int64(n)
        }
        r.loader.injectStemsForTesting(songId: songId, files: out, bytes: bytes,
                                       expected: Int64(data.count), finished: n == data.count)
        return out
    }

    // MARK: 1 — stems streaming in while the song plays

    /// The field shape on Now Playing: stems NOT on disk. Asking for them keeps the full song on
    /// air ("Loading stems…") while they stream; once buffered the song crosses over to them at
    /// the playhead — one continuous, sample-aligned read of the song (priming compensated), no
    /// dead air, no fake end. (Before: `setStemMode` refused — stems had to be burned first — and
    /// a burned switch was a hard stop/start.)
    func testStemsStreamInWhileTheSongPlaysThenHandOverSampleAligned() async throws {
        let r = try rig("np1")
        try await engage(r, "np1")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let parts = try streamStems(r, "np1", fraction: 0.03)             // ~0.4 s a part — not enough
        let cap = r.dsp.captureForTesting()
        cap.start()

        XCTAssertTrue(r.dsp.setStemMode(true), "stems in the catalog → the request is accepted")
        XCTAssertTrue(r.dsp.stemMode, "the toggle shows the user's intent")
        XCTAssertTrue(r.dsp.stemsLoading, "pending: Loading stems…")
        XCTAssertFalse(r.dsp.stemsOnAir, "no runway yet — the stems must NOT take over")
        XCTAssertTrue(r.dsp.isStreamingStemsForTesting())
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting(), "the full song keeps playing")
        await StemAudioProbe.capture(cap, atLeast: 0.6)

        try streamStems(r, "np1", fraction: 0.8, files: parts)          // ~9.6 s ⇒ > 4 s runway
        XCTAssertTrue(r.dsp.stemsOnAir, "runway arrived — the stems take over")
        XCTAssertFalse(r.dsp.stemsLoading)
        XCTAssertEqual(r.dsp.stemPrimeFramesForTesting(), 576, "headerless stems: priming compensated")
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting(), "the crossfade landed: the full song is retired")
        XCTAssertTrue(r.dsp.stemNodesPlayingForTesting())
        await StemAudioProbe.capture(cap, atLeast: 0.6)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(try noiseMix),
                                      "full song → streaming stems")
        XCTAssertEqual(ends, 0, "no fake end across the handover")
        XCTAssertTrue(r.dsp.isPlaying)
    }

    /// Burned stems, both directions on a PLAYING song: song → stems → song is one continuous,
    /// sample-aligned read with no dead air. (Before: a hard stop/start each way — a 60 ms+ hole —
    /// and the stems played 576 samples late.)
    func testBurnedStemsHandOverBothWaysWithoutAGap() async throws {
        let r = try rig("np2", remote: false, streaming: false)
        try burnStems(r, "np2")
        try await engage(r, "np2")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let cap = r.dsp.captureForTesting()
        cap.start()
        await StemAudioProbe.capture(cap, atLeast: 0.4)
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsOnAir, "complete stems on disk: immediate (crossfaded) switch")
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        await StemAudioProbe.capture(cap, atLeast: 0.4)
        XCTAssertTrue(r.dsp.setStemMode(false))
        XCTAssertFalse(r.dsp.stemsOnAir)
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting())
        XCTAssertFalse(r.dsp.stemNodesPlayingForTesting())
        await StemAudioProbe.capture(cap, atLeast: 0.4)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(try noiseMix),
                                      "song → stems → song")
        XCTAssertEqual(ends, 0)
    }

    // MARK: 2 — stems that never come

    /// Stems listed in the catalog but the fetch fails (no stream lane): the request drops and
    /// the full song — which never stopped — carries on. No end, no skip.
    func testStemsNeverAvailableKeepsTheSongPlaying() async throws {
        let r = try rig("np3", remote: true, streaming: false)
        var release: CheckedContinuation<Void, Never>?
        r.dsp.stemFetcher = { _ in
            await withCheckedContinuation { release = $0 }
            return false
        }
        try await engage(r, "np3")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let cap = r.dsp.captureForTesting()
        cap.start()
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsLoading)
        XCTAssertTrue(r.dsp.stemFetchPendingForTesting())
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        release?.resume()
        await StemAudioProbe.wait { !r.dsp.stemsLoading }
        XCTAssertFalse(r.dsp.stemsLoading, "nothing to hand over to — the request drops")
        XCTAssertFalse(r.dsp.stemMode)
        XCTAssertFalse(r.dsp.stemsOnAir)
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting(), "the full song never stopped")
        await StemAudioProbe.capture(cap, atLeast: 0.3)
        let y = cap.stop()
        XCTAssertLessThan(StemAudioProbe.longestSilence(y), 88, "no dead air while stems were sought")
        StemAudioProbe.assertSeamless(y, against: try StemAudioProbe.decoded(try noiseMix), "the song plays on")
        XCTAssertEqual(ends, 0)
    }

    // MARK: 3 — cancellation + generations

    /// Toggling OFF while the stems load cancels the request: stems landing later never take over.
    func testToggleOffMidPendingNeverSwitches() async throws {
        let r = try rig("np4")
        try await engage(r, "np4")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let parts = try streamStems(r, "np4", fraction: 0.03)
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsLoading)
        XCTAssertTrue(r.dsp.setStemMode(false))
        XCTAssertFalse(r.dsp.stemsLoading, "cancelled")
        XCTAssertFalse(r.dsp.stemMode)
        XCTAssertFalse(r.dsp.isStreamingStemsForTesting(), "the stem stream is let go")
        let cap = r.dsp.captureForTesting()
        cap.start()
        try streamStems(r, "np4", fraction: 1, files: parts)              // they land anyway
        XCTAssertFalse(r.dsp.stemsOnAir, "a cancelled request never claims the song")
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting())
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        XCTAssertLessThan(StemAudioProbe.longestSilence(cap.stop()), 88)
        XCTAssertEqual(ends, 0)
    }

    /// Hammer the toggle on a PLAYING song with stems on disk: the song never goes silent, never
    /// fakes an end, and lands on exactly the voice the LAST tap asked for.
    func testRapidTogglingNeverGoesSilentAndLandsOnTheLastIntent() async throws {
        let r = try rig("np5", remote: false, streaming: false)
        try burnStems(r, "np5")
        try await engage(r, "np5")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let cap = r.dsp.captureForTesting()
        cap.start()
        for i in 0..<9 {
            r.dsp.setStemMode(i % 2 == 0)                                  // on, off, on, … on
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...50_000_000))
        }
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() && r.dsp.stemHandover == nil }
        await StemAudioProbe.capture(cap, atLeast: 0.3)
        let y = cap.stop()
        let gap = StemAudioProbe.longestSilence(y)
        XCTAssertLessThan(gap, 88, "\(gap) samples of dead air through the toggling")
        XCTAssertEqual(ends, 0, "no fake end")
        XCTAssertTrue(r.dsp.stemMode)
        XCTAssertTrue(r.dsp.stemsOnAir, "the last tap asked for stems")
        XCTAssertTrue(r.dsp.stemNodesPlayingForTesting())
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting(), "exactly one voice renders")
        XCTAssertTrue(r.dsp.isPlaying)
    }

    /// A TRACK CHANGE while stems are being fetched (SetlistPlayer tears the engagement down —
    /// `disengage` — and the next song engages): the fetch's late "success" is stale. It must not
    /// switch the new song onto stems, and must not report an end (which would SKIP a song).
    func testTrackChangeMidPendingNeitherSwitchesNorEnds() async throws {
        let r = try rig("np6a", remote: true, streaming: false)
        var release: CheckedContinuation<Void, Never>?
        r.dsp.stemFetcher = { _ in
            await withCheckedContinuation { release = $0 }
            return true
        }
        try await engage(r, "np6a")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemFetchPendingForTesting())

        r.dsp.disengage()                                                  // the track changes
        r.dsp.resetControls()
        let next = try StemAudioProbe.tempMP3(try noiseMix, tag: "np6b")
        addTeardownBlock { try? FileManager.default.removeItem(at: next) }
        r.dsp.engage(url: next, startMs: nil, lengthMs: nil, atSeconds: 0, songId: "np6b", play: true)
        r.dsp.onReachedEnd = { ends += 1 }
        try burnStems(r, "np6a")
        try burnStems(r, "np6b")
        release?.resume()                                                  // the stale fetch "succeeds"
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(r.dsp.stemsOnAir, "a superseded fetch never claims the new song")
        XCTAssertFalse(r.dsp.stemMode)
        XCTAssertNil(r.dsp.stemHandover)
        XCTAssertEqual(r.dsp.loadedSongId, "np6b")
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertEqual(ends, 0, "no end reported — the set would have skipped a song")
    }

    // MARK: 4 — stems off while the full song is behind

    /// Stems OFF while the full song can't yet cover the playhead (`setMainFrontierForTesting`
    /// — the Now Playing main is a complete local file in production, so the seam stands in for
    /// a still-arriving one): the stems stay on air ("Loading full mix…") until it can, then cross
    /// back sample-aligned. Never silent.
    func testStemsOffWaitsForTheFullSongThenCrossesBackAligned() async throws {
        let r = try rig("np7", remote: false, streaming: false)
        try burnStems(r, "np7")
        try await engage(r, "np7")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        XCTAssertTrue(r.dsp.setStemMode(true))
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        await StemAudioProbe.wait { r.dsp.currentTime > 1.0 }
        r.dsp.setMainFrontierForTesting(0.5)                               // the full song is "behind"
        let cap = r.dsp.captureForTesting()
        cap.start()

        XCTAssertTrue(r.dsp.setStemMode(false))
        XCTAssertFalse(r.dsp.stemMode, "intent: the full song")
        XCTAssertEqual(r.dsp.stemHandover, .toFullMix, "pending until the full song can carry it")
        XCTAssertTrue(r.dsp.stemsOnAir, "the stems keep playing")
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        XCTAssertTrue(r.dsp.stemsOnAir)

        r.dsp.releaseMainFrontierForTesting()
        XCTAssertFalse(r.dsp.stemsOnAir, "it can now — it takes the song back")
        XCTAssertNil(r.dsp.stemHandover)
        await StemAudioProbe.wait { !r.dsp.stemFadeInFlightForTesting() }
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting())
        XCTAssertFalse(r.dsp.stemNodesPlayingForTesting())
        await StemAudioProbe.capture(cap, atLeast: 0.4)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(try noiseMix),
                                      "stems (full song behind) → full song")
        XCTAssertEqual(ends, 0)
    }

    // MARK: 5 — streaming stems running dry

    /// Partial stems ON AIR whose stream stalls: before they run out the song hands back to the
    /// full song (no dead air, request kept), and takes the stems again once they have runway.
    func testStemUnderrunHandsBackToTheSongThenReengages() async throws {
        let r = try rig("np8")
        try await engage(r, "np8")
        var ends = 0
        r.dsp.onReachedEnd = { ends += 1 }
        let parts = try streamStems(r, "np8", fraction: 0.55)            // ~5 s playable a part
        XCTAssertTrue(r.dsp.setStemMode(true))
        XCTAssertTrue(r.dsp.stemsOnAir, "≥ 4 s of runway — on stems")
        let end = r.dsp.stemEndSecondsForTesting()
        XCTAssertLessThan(end, 6, "only the streamed part is scheduled")
        let cap = r.dsp.captureForTesting()
        cap.start()

        await StemAudioProbe.wait(timeout: end + 2) { !r.dsp.stemsOnAir }
        XCTAssertFalse(r.dsp.stemsOnAir, "handed back BEFORE the stems ran dry")
        XCTAssertLessThan(r.dsp.currentTime, end, "…while they still had audio")
        XCTAssertEqual(r.dsp.stemHandover, .toStems, "the stems are still wanted")
        await StemAudioProbe.capture(cap, atLeast: 0.4)
        StemAudioProbe.assertSeamless(cap.stop(), against: try StemAudioProbe.decoded(try noiseMix),
                                      "stems running dry → full song")

        try streamStems(r, "np8", fraction: 1, files: parts)              // the stems finish
        XCTAssertTrue(r.dsp.stemsOnAir, "re-engaged once they had runway")
        XCTAssertNil(r.dsp.stemHandover)
        XCTAssertEqual(ends, 0)
        XCTAssertTrue(r.dsp.isPlaying)
    }
}
