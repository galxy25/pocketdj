import AVFoundation
import XCTest
@testable import PocketDJ

/// ZERO DEAD AIR at the song boundary of a Now Playing set (a Pocket played in shuffle) — the
/// field report "pausing at the end of songs and I had to skip forward multiple times" (Levi,
/// CarPlay on cellular, 2026-10-12). The rip server + S3 are a scripted `URLProtocol`: per-song
/// presign that can FAIL (offline), HANG (cellular dead zone), or fail after a delay; rip jobs
/// whose poll never answers. Every test drives the REAL sequencer / coordinator / providers.
@MainActor
final class SetlistEndOfSongTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!
    private var saved: (stall: Double, grace: Double, amStart: Double, wait: Int, poll: Double)!

    override func setUp() {
        super.setUp()
        EOSStub.reset()
        saved = (SetlistPlayer.resolveStallSeconds, SetlistPlayer.liveEndGraceSeconds,
                 AppleMusicPlaybackProvider.startTimeoutSeconds,
                 RipsStore.interactivePlayWaitSeconds, RipsStore.jobPollTimeoutSeconds)
    }

    override func tearDown() {
        SetlistPlayer.resolveStallSeconds = saved.stall
        SetlistPlayer.liveEndGraceSeconds = saved.grace
        AppleMusicPlaybackProvider.startTimeoutSeconds = saved.amStart
        RipsStore.interactivePlayWaitSeconds = saved.wait
        RipsStore.jobPollTimeoutSeconds = saved.poll
        EOSStub.reset()
        super.tearDown()
    }

    // MARK: Harness

    private struct Rig { let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
                         let coord: PlaybackCoordinator; let seq: SetlistPlayer }

    private func makeRig(server: String = "https://server.test") -> Rig {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EOSStub.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = server
        settings.ripToken = ""
        rips.settings = settings
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-eosburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        return Rig(rips: rips, burns: burns, player: player, coord: coord, seq: seq)
    }

    private func manifest(_ rips: RipsStore, _ ids: [String]) {
        var m: [String: RipsStore.ManifestEntry] = [:]
        for id in ids { m[id] = .init(key: "rips/\(id).mp3", source: "digital") }
        rips.setManifest(m)
    }

    private func burn(_ r: Rig, _ id: String) async {
        _ = await r.burns.burn([(id: id, title: id, artist: "A")])
        XCTAssertNotNil(r.burns.localURL(forSong: id), "precondition: \(id) is burned")
        EOSStub.presignCount = [:]
    }

    private func item(_ id: String, lengthMs: Int? = nil) -> SetlistPlayer.Item {
        .init(id: id, title: id, artist: "A", lengthMs: lengthMs)
    }

    /// Let a just-loaded row's nowPlaying-change observer (the jump-adopt, one main-actor turn
    /// later) run BEFORE the test ends that row — a real track ends minutes after it loads,
    /// never in the same turn. Yields only: a stub burned file fails in AVFoundation ~100 ms in.
    private func settleLoad() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Wait (bounded) for the asserted condition.
    private func waitUntil(_ message: String, timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    // MARK: 1 — the next song's URL is resolved BEFORE the boundary

    /// The set is playing over cellular; the network drops out before the current song ends.
    /// The advance must still start the next ripped song: its presigned URL was fetched while
    /// the current one played (pre-fix: the presign happened AT the boundary, failed offline,
    /// and the set skipped every row until it stopped — silence).
    func testAdvanceUsesTheUpcomingURLFetchedDuringTheCurrentSong() async {
        let r = makeRig()
        manifest(r.rips, ["c1", "c2"])
        r.seq.play([item("c1"), item("c2")])
        await waitUntil("c1 playing") { r.rips.nowPlaying?.songId == "c1" }
        await waitUntil("c2's URL pre-resolved while c1 plays") { EOSStub.presignCount["c2", default: 0] >= 1 }

        EOSStub.offline = true                        // dead zone: every request now fails
        r.player.onTrackEnded?()                      // c1 ends naturally
        await waitUntil("c2 starts from its pre-resolved URL") { r.rips.nowPlaying?.songId == "c2" }
        XCTAssertTrue(r.seq.isRunning, "the set is still running — no silent stop")
        XCTAssertEqual(r.seq.index, 1)
        r.seq.stop()
    }

    // MARK: 2 — a stalled resolve hops to a song that's on the device

    /// The next row's resolve HANGS (a cellular dead zone swallows the presign): after
    /// `resolveStallSeconds` the set plays the next ON-DEVICE row instead, and the stalled row is
    /// DEFERRED right behind it (reordered, never dropped). Pre-fix: silence for the full request
    /// timeout, per row, per skip press.
    func testStalledResolveHopsToAnOnDeviceRowAndDefersTheStalledOne() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["hang", "b1"])
        await burn(r, "b1")
        EOSStub.hangPresign = ["hang"]
        r.seq.play([item("hang"), item("b1")])
        await waitUntil("hopped onto the burned row") { r.rips.nowPlaying?.songId == "b1" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "hang"], "the stalled row is deferred, not dropped")
        XCTAssertEqual(r.seq.index, 0)
        r.seq.stop()
    }

    /// No on-device row nearby: the stall hop falls back to a row that starts INSTANTLY (a durable
    /// rip) instead of waiting — a row stuck on a queued rip sat silent 47 s (drive 2026-10-25).
    func testStalledResolveWithNoOnDeviceRowHopsToAnInstantRow() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["hang", "c2"])
        EOSStub.hangPresign = ["hang"]
        r.seq.play([item("hang"), item("c2")])
        await waitUntil("hopped onto the durable-rip row") { r.rips.nowPlaying?.songId == "c2" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["c2", "hang"], "the stalled row is deferred, not dropped")
        r.seq.stop()
    }

    /// "If we skip ahead because the next song can't download, play it AFTER the song we skipped
    /// to — don't skip back to it" (Levi, drive 2026-10-28 03:01). The stalled row is placed
    /// IMMEDIATELY after the hop target (even when the hop target sat further down), its late
    /// resolve never interrupts the hop target, and it plays next when the hop target ends —
    /// instantly, from the URL resolved while the hop target played.
    func testDeferredRowsLateResolveNeverInterruptsTheHopTargetAndPlaysNextAtItsEnd() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["slow", "x", "b1", "c4"])
        await burn(r, "b1")
        EOSStub.delayedPresign = ["slow": 0.6]      // lands AFTER the hop
        EOSStub.hangPresign = ["x"]                 // x can't start either — the hop skips it
        r.seq.play([item("slow"), item("x"), item("b1"), item("c4")])
        await waitUntil("hopped onto the burned row") { r.rips.nowPlaying?.songId == "b1" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "slow", "x", "c4"],
                       "the stalled row sits IMMEDIATELY after the hop target — deferred, not dropped")

        // Well past the stalled row's late resolve (0.6 s) + the presign prefetched for it
        // while b1 plays: nothing may take b1's place.
        await waitUntil("the deferred row's URL resolved while b1 plays") { r.rips.prefetchedURL("slow") != nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "b1", "the late resolve did not interrupt the hop target")
        XCTAssertEqual(r.seq.index, 0)
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "slow", "x", "c4"])

        let before = EOSStub.presignCount["slow", default: 0]
        r.player.onTrackEnded?()                    // b1 ends
        await waitUntil("the deferred row plays next") { r.rips.nowPlaying?.songId == "slow" }
        XCTAssertEqual(r.seq.index, 1)
        XCTAssertEqual(EOSStub.presignCount["slow", default: 0], before, "started instantly — no new round trip")
        r.seq.stop()
    }

    // MARK: 2b — stall EPISODES: never hop back to a row this episode abandoned

    /// THE ping-pong (drive log 2026-10-27 07:12, ios-3712BFDE): two Apple Music rows whose
    /// catalog Song is prefetched count as "instant", but their audio still streams — on weak
    /// signal BOTH stall, and the hop went b229 → 1393 → b229 → … every 6 s, each hop cancelling
    /// the other's partial buffer. Now the row abandoned in this episode is never a target again:
    /// the current row is left resolving (not cancelled, not restarted) and plays when it lands.
    func testStallHopNeverPingPongsBackToTheAbandonedRowAndTheCurrentRowKeepsBuffering() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["amA", "amB"])
        r.seq.startsInstantlyOverrideForTesting = { ["amA", "amB"].contains($0) ? true : nil }
        EOSStub.hangPresign = ["amA"]
        EOSStub.delayedPresign = ["amB": 1.2]       // stalls past its own 0.3 s, then lands
        r.seq.play([item("amA"), item("amB")])
        await waitUntil("hopped off the stalled row") { r.seq.stallHopCount == 1 }
        XCTAssertEqual(r.seq.queue.map(\.id), ["amB", "amA"], "deferred, not dropped")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let presigns = EOSStub.presignCount["amB", default: 0]

        // amB stalls too (0.3 s) — the only other row is amA, abandoned this episode: no hop back.
        await waitUntil("amB's buffered resolve lands and plays", timeout: 4) { r.rips.nowPlaying?.songId == "amB" }
        XCTAssertEqual(r.seq.stallHopCount, 1, "no return hop to the abandoned row")
        XCTAssertEqual(r.seq.queue.map(\.id), ["amB", "amA"])
        XCTAssertEqual(r.seq.index, 0)
        XCTAssertEqual(EOSStub.presignCount["amB", default: 0], presigns,
                       "the stalled current row was never cancelled + restarted from zero")
        r.seq.stop()
    }

    /// An on-device row anywhere in the hop range beats an earlier "instant" (streaming) row.
    func testStallHopPrefersAnOnDeviceRowOverAnEarlierInstantRow() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["hang", "inst", "b1"])
        await burn(r, "b1")
        r.seq.startsInstantlyOverrideForTesting = { $0 == "inst" ? true : nil }
        EOSStub.hangPresign = ["hang", "inst"]
        r.seq.play([item("hang"), item("inst"), item("b1")])
        await waitUntil("hopped onto the burned row") { r.rips.nowPlaying?.songId == "b1" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "hang", "inst"])
        XCTAssertEqual(r.seq.stallHopCount, 1)
        r.seq.stop()
    }

    /// Several streaming hops in one episode are fine — each to a row not yet abandoned.
    func testMultipleDistinctStreamingHopsInOneEpisode() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["s1", "s2", "s3"])
        r.seq.startsInstantlyOverrideForTesting = { ["s1", "s2", "s3"].contains($0) ? true : nil }
        EOSStub.hangPresign = ["s1", "s2"]
        r.seq.play([item("s1"), item("s2"), item("s3")])
        await waitUntil("hopped twice onto s3", timeout: 4) { r.rips.nowPlaying?.songId == "s3" }
        XCTAssertEqual(r.seq.stallHopCount, 2, "s1 → s2 → s3: two distinct hops")
        XCTAssertEqual(r.seq.queue.map(\.id), ["s3", "s2", "s1"], "each stalled row deferred behind its hop target")
        r.seq.stop()
    }

    /// First audio ends the episode: a LATER stall may hop to a row abandoned in an earlier one.
    func testEpisodeResetsAfterFirstAudioSoALaterStallCanHopToAPreviouslyAbandonedRow() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["amA", "b1", "late"])
        await burn(r, "b1")
        r.seq.startsInstantlyOverrideForTesting = { $0 == "amA" ? true : nil }
        EOSStub.hangPresign = ["amA", "late"]
        r.seq.play([item("amA"), item("b1")])
        await waitUntil("episode 1: hopped onto the burned row") { r.rips.nowPlaying?.songId == "b1" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "amA"])
        r.player.onFirstAudio?()                     // b1 renders → the episode is over (the stub bytes never render, and can fail first: drive the wired hook)
        r.seq.insertNextInQueue([item("late")])      // a stalling row now sits BEFORE amA
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "late", "amA"])
        await settleLoad()
        r.player.onTrackEnded?()                     // b1 ends → "late" starts and stalls
        await waitUntil("episode 2 may hop to amA again") { r.seq.stallHopCount == 2 }
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "amA", "late"])
        r.seq.stop()
    }

    /// Control for the above: WITHOUT first audio the episode persists, so the same stall finds
    /// only the abandoned row and leaves the current one buffering.
    func testWithoutFirstAudioTheEpisodePersistsAndTheAbandonedRowIsNotATarget() async {
        SetlistPlayer.resolveStallSeconds = 0.3
        let r = makeRig()
        manifest(r.rips, ["amA", "b1", "late"])
        await burn(r, "b1")
        r.seq.startsInstantlyOverrideForTesting = { $0 == "amA" ? true : nil }
        EOSStub.hangPresign = ["amA", "late"]
        r.seq.play([item("amA"), item("b1")])
        await waitUntil("episode 1: hopped onto the burned row") { r.rips.nowPlaying?.songId == "b1" }
        r.seq.insertNextInQueue([item("late")])
        await settleLoad()
        r.player.onTrackEnded?()                     // b1 never rendered (no first audio)
        await waitUntil("late is the current row") { r.seq.index == 1 }
        try? await Task.sleep(nanoseconds: 700_000_000)   // well past late's 0.3 s stall
        XCTAssertEqual(r.seq.stallHopCount, 1, "amA was abandoned this episode — no hop")
        XCTAssertEqual(r.seq.queue.map(\.id), ["b1", "late", "amA"])
        XCTAssertEqual(r.seq.index, 1, "the stalled row is left buffering, not advanced past")
        r.seq.stop()
    }

    /// THE field mechanism (drive log 2026-10-28 03:01:34): the hop CANCELS the stalled row's
    /// start; Apple Music (first provider) fails with that CancellationError, and the coordinator
    /// fell through to the rip provider — whose presign was PREFETCHED, so no await threw the
    /// cancel — and it loaded the stalled song over the on-device row, which the set then adopted
    /// as a jump back. A cancelled play must stand down: no load, no nowPlaying, no error.
    func testCancelledPlayDoesNotFallThroughToAnInstantRip() async {
        let r = makeRig()
        manifest(r.rips, ["honey"])
        r.coord.sourceOfSong = { _ in Config.appleMusicSourceName }   // AM first, rip behind it
        r.coord.appleMusicReadyOverrideForTests = true
        XCTAssertTrue(r.coord.streamsAppleMusicFirst(id: "honey", title: "honey", artist: "A", variant: nil),
                      "precondition: Apple Music is tried first")
        r.rips.prefetchPresigned(["honey"])
        await waitUntil("honey's presign prefetched") { r.rips.prefetchedURL("honey") != nil }

        let t = Task { await r.coord.play(id: "honey", title: "honey", artist: "A") }
        t.cancel()                                   // the set hopped off this row
        await t.value
        XCTAssertNil(r.rips.nowPlaying, "a cancelled play never stamps nowPlaying (the set would adopt it)")
        XCTAssertFalse(r.player.hasLoadedItem, "a cancelled play never loads the engine")
        XCTAssertNil(r.coord.activeBackend)
        XCTAssertNil(r.coord.lastErrorMessage, "a cancel is not a dead source")
    }

    /// The same guard one layer down: a cancelled rip resolve served from the prefetch throws
    /// instead of handing back a NowPlaying.
    func testCancelledRipResolveFromThePrefetchThrows() async {
        let r = makeRig()
        manifest(r.rips, ["c1"])
        r.rips.prefetchPresigned(["c1"])
        await waitUntil("c1's presign prefetched") { r.rips.prefetchedURL("c1") != nil }
        let t = Task { try await r.rips.play((id: "c1", title: "c1", artist: "A"), playback: true) }
        t.cancel()
        let result = await t.result
        XCTAssertThrowsError(try result.get())
        XCTAssertNil(r.rips.nowPlaying)
    }

    /// ▶ in the app while the row's start is still in flight must NOT restart it — that cancelled
    /// the wait each time (six taps, six restarts, never played: drive 2026-10-25 05:15).
    func testPanelPlayDuringAnInFlightStartDoesNotRestartIt() async {
        SetlistPlayer.resolveStallSeconds = 30
        let r = makeRig()
        manifest(r.rips, ["hang"])
        EOSStub.hangPresign = ["hang"]
        r.seq.play([item("hang")])
        await waitUntil("start in flight") { r.seq.isStartPending && EOSStub.presignCount["hang", default: 0] >= 1 }
        for _ in 0..<3 {
            NowPlayingPanel.togglePlayPause(sequencer: r.seq, coordinator: r.coord, player: r.player)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(EOSStub.presignCount["hang", default: 0], 1, "no restart re-requested the row")
        XCTAssertTrue(r.seq.isStartPending)
        r.seq.stop()
    }

    /// The stall window holds a UIKit background-task assertion: a locked/CarPlay phone with no
    /// audio playing between songs is otherwise suspended mid-resolve, and only the NEXT remote
    /// press wakes it (the "skip several times" signature).
    func testCloudResolveHoldsABackgroundRunway() async {
        SetlistPlayer.resolveStallSeconds = 30
        let r = makeRig()
        manifest(r.rips, ["hang"])
        EOSStub.hangPresign = ["hang"]
        let before = PlaybackRunway.activeCount
        r.seq.play([item("hang")])
        await waitUntil("runway held during the resolve") { PlaybackRunway.activeCount == before + 1 }
        r.seq.stop()
        await waitUntil("runway released") { PlaybackRunway.activeCount == before }
    }

    // MARK: 3 — no silent waits without a bound

    /// A rip job whose status poll never answers (cellular): the interactive wait is a WALL-CLOCK
    /// bound. Pre-fix it counted iterations, each up to URLSession's 60 s default — a ▶/⏭ that
    /// landed on an un-ripped row could sit silent for many minutes.
    func testRipJobPollIsBoundedByWallClock() async throws {
        RipsStore.interactivePlayWaitSeconds = 2
        RipsStore.jobPollTimeoutSeconds = 1
        let r = makeRig()
        r.rips.setManifest([:])
        EOSStub.ripPostBody = Data(#"{"jobId":"j1","songId":"new","phase":"queued"}"#.utf8)
        EOSStub.hangJobs = true
        let t0 = Date()
        var finished = false
        let task = Task {
            _ = try? await r.rips.play((id: "new", title: "N", artist: "A"))
            finished = true
        }
        await waitUntil("the play resolve gives up within its bound", timeout: 6) { finished }
        task.cancel()
        XCTAssertGreaterThanOrEqual(EOSStub.jobPolls, 1, "the job was polled")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
    }

    /// A live HLS capture whose ENDLIST never arrives (the capture wedged, or the playlist reload
    /// died on cellular): advance once the song's known length + grace has passed. Pre-fix:
    /// `waitingForLive` — silence until someone pressed Next.
    func testLiveCaptureThatNeverEndsAdvancesAfterItsLength() async {
        SetlistPlayer.liveEndGraceSeconds = 0.2
        let r = makeRig(server: "")
        r.rips.setManifest(["live": .init(key: "hls/live/stream.m3u8", source: "digital"),
                            "next": .init(key: "hls/next/stream.m3u8", source: "digital")])
        r.seq.play([item("live", lengthMs: 200), item("next", lengthMs: 300_000)])
        await waitUntil("live capture playing") { r.rips.nowPlaying?.songId == "live" }
        await waitUntil("advanced past the never-ending capture") { r.seq.index == 1 }
        XCTAssertTrue(r.seq.isRunning)
        r.seq.stop()
    }

    /// An AVPlayer item that FAILS mid-song (network error on the presigned mp3) never posts
    /// DidPlayToEndTime — the set must advance on the failure. Pre-fix: silence until ⏭.
    func testItemFailedToPlayToEndAdvances() async {
        let r = makeRig()
        manifest(r.rips, ["c1", "c2"])
        r.seq.play([item("c1"), item("c2")])
        await waitUntil("c1 playing") { r.rips.nowPlaying?.songId == "c1" }
        let current = r.player.currentItemForTesting
        XCTAssertNotNil(current)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: current)
        await waitUntil("advanced off the failed item") { r.rips.nowPlaying?.songId == "c2" }
        XCTAssertEqual(r.seq.index, 1)
        r.seq.stop()
    }

    // MARK: 4 — Apple Music accepted the play but never started

    func testAppleMusicNeverStartedVerdict() {
        AppleMusicPlaybackProvider.startTimeoutSeconds = 12
        XCTAssertTrue(AppleMusicPlaybackProvider.neverStarted(everPlayed: false, waitedSeconds: 13, intentionalPause: false))
        XCTAssertFalse(AppleMusicPlaybackProvider.neverStarted(everPlayed: false, waitedSeconds: 5, intentionalPause: false),
                       "a slow start is just buffering")
        XCTAssertFalse(AppleMusicPlaybackProvider.neverStarted(everPlayed: true, waitedSeconds: 60, intentionalPause: false))
        XCTAssertFalse(AppleMusicPlaybackProvider.neverStarted(everPlayed: false, waitedSeconds: 60, intentionalPause: true),
                       "the listener paused it before it started — not a dead source")
    }

    /// The never-started end ADVANCES (a dead source) — even under repeat-one, which would
    /// otherwise replay the silent row forever.
    func testAppleMusicNeverStartedAdvancesEvenUnderRepeatOne() async {
        let r = makeRig()
        manifest(r.rips, ["am1", "c2"])
        r.seq.play([item("am1"), item("c2")])
        await waitUntil("am1 resolved") { r.rips.nowPlaying?.songId == "am1" }
        r.seq.setRepeatMode(.one)
        r.coord.setActiveBackendForTests(.appleMusic)
        r.coord.appleMusic.setNowPlayingForTests(.init(songId: "am1", title: "am1", artist: "A"))
        r.coord.appleMusic.onTrackEnded?(.neverStarted)
        await waitUntil("advanced off the silent stream") { r.seq.index == 1 }
        r.seq.stop()
    }

    // MARK: 5 — skip storms: a superseded resolve must not poison the newer one

    /// ⏭ pressed while row A's presign is still out: A's late FAILURE must not land in the
    /// coordinator's shared error after B started — pre-fix, B's sequencer read it as B being a
    /// dead source and skipped AGAIN (one press = two songs, or a silent stop at the end).
    func testSupersededResolveFailureDoesNotPoisonTheNewerPlay() async {
        let r = makeRig()
        manifest(r.rips, ["slowfail", "b"])
        EOSStub.delayedFailPresign = ["slowfail": 0.4]
        let a = Task { await r.coord.play(id: "slowfail", title: "A", artist: "A") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await r.coord.play(id: "b", title: "B", artist: "A")
        XCTAssertNil(r.coord.lastErrorMessage, "B played")
        _ = await a.value
        XCTAssertNil(r.coord.lastErrorMessage, "A's late failure belongs to a superseded play")
        XCTAssertEqual(r.rips.nowPlaying?.songId, "b")
    }
}

// MARK: - Stub rip server / S3

private final class EOSStub: URLProtocol {
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var hangPresign: Set<String> = []
    nonisolated(unsafe) static var delayedFailPresign: [String: Double] = [:]
    nonisolated(unsafe) static var delayedPresign: [String: Double] = [:]
    nonisolated(unsafe) static var presignCount: [String: Int] = [:]
    nonisolated(unsafe) static var ripPostBody = Data("{}".utf8)
    nonisolated(unsafe) static var hangJobs = false
    nonisolated(unsafe) static var jobPolls = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        offline = false; hangPresign = []; delayedFailPresign = [:]; delayedPresign = [:]; presignCount = [:]
        ripPostBody = Data("{}".utf8); hangJobs = false; jobPolls = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data, json: Bool = false) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: json ? ["Content-Type": "application/json"] : nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        let offline = Self.offline
        Self.lock.unlock()
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            Self.lock.lock()
            Self.presignCount[song, default: 0] += 1
            let hang = Self.hangPresign.contains(song)
            let delayFail = Self.delayedFailPresign[song]
            let delay = Self.delayedPresign[song]
            Self.lock.unlock()
            if hang { return }                                   // never answers
            if let delay {                                       // answers OK, late
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                    respond(200, Data(#"{"url":"https://s3.test/rips/\#(song).mp3?X-Amz-Signature=x"}"#.utf8), json: true)
                }
                return
            }
            if let delayFail {
                DispatchQueue.global().asyncAfter(deadline: .now() + delayFail) { [self] in
                    respond(500, Data())
                }
                return
            }
            respond(200, Data(#"{"url":"https://s3.test/rips/\#(song).mp3?X-Amz-Signature=x"}"#.utf8), json: true)
            return
        }
        if url.path.hasSuffix("/rip"), request.httpMethod == "POST" {
            respond(200, Self.ripPostBody, json: true); return
        }
        if url.path.contains("/jobs/") {
            Self.lock.lock(); Self.jobPolls += 1; let hang = Self.hangJobs; Self.lock.unlock()
            if hang { return }
            respond(200, Data(#"{"phase":"queued"}"#.utf8), json: true); return
        }
        respond(200, Data("BURNT-MP3".utf8))
    }
}
