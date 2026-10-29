import Combine
import XCTest
@testable import PocketDJ

/// Field bug (session ios-3712BFDE, 2026-10-28 22:15:59): a streamed Apple Music track ended,
/// the set moved on to a downloaded song, and CarPlay kept showing the streamed song paused.
/// ▶ on CarPlay resumed the OLD stream (MusicKit's queue was never emptied: `stop()` only
/// stopped it), interrupting our engine. These pin:
///   1. RELEASE on leave: every way playback leaves the Apple Music backend stops MusicKit AND
///      empties its queue, and the engine drops its Apple Music impersonation.
///   2. The STRAY-PLAY guard: MusicKit playing while not ours is silenced and handed back to
///      the set, which plays its own current row.
/// MusicKit can't run headless, so its player is the `MusicKitPlayerControl` fake.
@MainActor
final class StaleMusicKitCardTests: XCTestCase {

    private final class FakeMusicKitPlayer: MusicKitPlayerControl {
        var isPlaying = false
        var releaseCount = 0
        let subject = PassthroughSubject<Void, Never>()
        var stateChanges: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
        func release() { releaseCount += 1; isPlaying = false }
    }

    private var savedGrace = AppleMusicPlaybackProvider.strayGraceSeconds
    override func setUp() {
        super.setUp()
        savedGrace = AppleMusicPlaybackProvider.strayGraceSeconds
    }
    override func tearDown() {
        AppleMusicPlaybackProvider.strayGraceSeconds = savedGrace
        super.tearDown()
    }

    private func makeProvider() -> (AppleMusicPlaybackProvider, FakeMusicKitPlayer) {
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        let fake = FakeMusicKitPlayer()
        am.musicKitPlayer = fake
        return (am, fake)
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeMusicKitPlayer, PlayerEngine, RipsStore) {
        let (am, fake) = makeProvider()
        let rips = RipsStore()
        let player = PlayerEngine()
        let c = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                    appleMusic: am)
        return (c, fake, player, rips)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    // MARK: 1 — release on leave

    func testProviderStopReleasesMusicKit() {
        let (am, fake) = makeProvider()
        am.setOwnsMusicKitForTests(true)
        am.setNowPlayingForTests(.init(songId: "sng_am", title: "Cash Race", artist: "Tinashe"))
        am.stop()
        XCTAssertEqual(fake.releaseCount, 1, "stop must empty MusicKit's queue, not just stop it")
        XCTAssertFalse(am.ownsMusicKit)
        XCTAssertNil(am.nowPlaying)
    }

    /// The AM → local-file hand-off (burned / studio / profile / stem-cut branches).
    func testStopAppleMusicIfActiveReleasesMusicKit() {
        let (c, fake, _, _) = makeCoordinator()
        c.setActiveBackendForTests(.appleMusic)
        c.appleMusic.setOwnsMusicKitForTests(true)
        c.stopAppleMusicIfActive()
        XCTAssertEqual(fake.releaseCount, 1)
        XCTAssertNil(c.activeBackend)
        XCTAssertFalse(c.appleMusic.ownsMusicKit)
    }

    /// Not streaming ⇒ the local hand-off leaves MusicKit alone.
    func testStopAppleMusicIfActiveIsANoOpOffAppleMusic() {
        let (c, fake, _, _) = makeCoordinator()
        c.setActiveBackendForTests(.ripServer)
        c.stopAppleMusicIfActive()
        XCTAssertEqual(fake.releaseCount, 0)
    }

    /// The AM → cloud-row hand-off (the 22:15:59 case: the next row went to the rip provider):
    /// the coordinator's backend switch releases MusicKit before the rip provider runs.
    func testBackendSwitchToRipReleasesMusicKit() async {
        let (c, fake, _, _) = makeCoordinator()
        c.setActiveBackendForTests(.appleMusic)
        c.appleMusic.setOwnsMusicKitForTests(true)
        // The release happens at the switch, before the rip resolve's first await — don't
        // depend on how fast the (server-less) rip attempt fails.
        let t = Task { await c.play(id: "sng_next", title: "Vocal Function", artist: "X") }
        await waitUntil("leaving Apple Music for the rip provider releases MusicKit") { fake.releaseCount >= 1 }
        XCTAssertFalse(c.appleMusic.ownsMusicKit)
        t.cancel()
        _ = await t.value
    }

    func testReleaseFiresOnReleased() {
        let (am, _) = makeProvider()
        var released = 0
        am.onReleased = { released += 1 }
        am.stop()
        XCTAssertEqual(released, 1)
    }

    /// A released stream's resume closure (the impersonated card's ▶ in the gap before the next
    /// row loads) must not restart MusicKit.
    func testResumeAndToggleAreRefusedOnceReleased() {
        let (am, _) = makeProvider()
        am.stop()
        am.resume()
        XCTAssertFalse(am.isPlaying, "resume after release must not claim playback")
        am.togglePlayPause()
        XCTAssertFalse(am.isPlaying, "toggle after release must not claim playback")
    }

    /// Leaving Apple Music drops the engine's AM impersonation, so the card + remote commands
    /// belong to the engine again (a ▶ reaches the idle engine, not the released stream).
    func testReleaseEndsTheEnginesAppleMusicImpersonation() {
        let rips = RipsStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-stalemk-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let (am, fake) = makeProvider()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player), appleMusic: am)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        _ = seq
        var streamPlays = 0
        player.beginExternalNowPlaying(title: "Cash Race", artist: "Tinashe", songId: "sng_am",
                                       durationSeconds: 274, position: { 270 }, isPlaying: { true },
                                       play: { streamPlays += 1 }, pause: {})
        XCTAssertTrue(player.hasLoadedItem, "precondition: impersonating the stream")
        coord.setActiveBackendForTests(.appleMusic)
        am.setOwnsMusicKitForTests(true)
        coord.stopAppleMusicIfActive()
        XCTAssertEqual(fake.releaseCount, 1)
        XCTAssertFalse(player.hasLoadedItem, "the engine left external mode")
        XCTAssertFalse(player.isPlaying)
        player.play()
        XCTAssertEqual(streamPlays, 0, "▶ after the release never reaches the released stream")
    }

    // MARK: 2 — stray-play verdict

    func testStrayVerdict() {
        typealias P = AppleMusicPlaybackProvider
        XCTAssertEqual(P.strayPlayVerdict(ownsMusicKit: true, musicKitPlaying: true, secondsSinceRelease: 10), .ignore,
                       "an Apple Music row playing is ours")
        XCTAssertEqual(P.strayPlayVerdict(ownsMusicKit: false, musicKitPlaying: false, secondsSinceRelease: 10), .ignore)
        XCTAssertEqual(P.strayPlayVerdict(ownsMusicKit: false, musicKitPlaying: true, secondsSinceRelease: 10), .reclaim)
        XCTAssertEqual(P.strayPlayVerdict(ownsMusicKit: false, musicKitPlaying: true, secondsSinceRelease: nil), .reclaim)
        let grace = P.strayGraceSeconds
        XCTAssertEqual(P.strayPlayVerdict(ownsMusicKit: false, musicKitPlaying: true, secondsSinceRelease: 0.5),
                       .recheck(after: grace - 0.5),
                       "right after our own release MusicKit's status can still lag on .playing")
    }

    func testCheckForStrayPlayReclaimsAndHandsBack() {
        let (am, fake) = makeProvider()
        var handedBack = 0
        am.onStrayPlay = { handedBack += 1 }
        fake.isPlaying = true                       // ▶ on the stale CarPlay card resumed MusicKit
        XCTAssertEqual(am.checkForStrayPlay(source: "test"), .reclaim)
        XCTAssertEqual(fake.releaseCount, 1, "the stray stream is silenced + emptied")
        XCTAssertEqual(handedBack, 1, "the set gets ▶ back for its own row")
    }

    func testCheckForStrayPlayIgnoresOurOwnStream() {
        let (am, fake) = makeProvider()
        var handedBack = 0
        am.onStrayPlay = { handedBack += 1 }
        am.setOwnsMusicKitForTests(true)
        fake.isPlaying = true
        XCTAssertEqual(am.checkForStrayPlay(source: "test"), .ignore)
        XCTAssertEqual(fake.releaseCount, 0)
        XCTAssertEqual(handedBack, 0)
    }

    /// The observation path: MusicKit's state changes after we released it and it is playing.
    func testStateChangeAfterReleaseTriggersReclaim() async {
        AppleMusicPlaybackProvider.strayGraceSeconds = 0
        let (am, fake) = makeProvider()
        var handedBack = 0
        am.onStrayPlay = { handedBack += 1 }
        am.setOwnsMusicKitForTests(true)
        am.stop()                                   // leave AM → release arms the state watch
        XCTAssertEqual(fake.releaseCount, 1)
        fake.isPlaying = true
        fake.subject.send()
        await waitUntil("stray play reclaimed") { handedBack == 1 }
        XCTAssertEqual(fake.releaseCount, 2)
    }

    /// Inside the grace window the check re-reads later; a status that settled to not-playing
    /// is no stray.
    func testGraceRecheckDoesNotReclaimASettledStop() async {
        AppleMusicPlaybackProvider.strayGraceSeconds = 0.2
        let (am, fake) = makeProvider()
        var handedBack = 0
        am.onStrayPlay = { handedBack += 1 }
        am.stop()
        fake.isPlaying = true                       // MusicKit's lagging status for the stopped track
        if case .recheck = am.checkForStrayPlay(source: "test") {} else { XCTFail("expected recheck") }
        fake.isPlaying = false                      // …settles to stopped
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(handedBack, 0)
        XCTAssertEqual(fake.releaseCount, 1, "only our own release")
    }

    /// Backstop path: our engine's session interruption makes the provider look at MusicKit.
    func testLocalInterruptionSchedulesAStrayCheck() async {
        AppleMusicPlaybackProvider.strayGraceSeconds = 0
        let rips = RipsStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-stalemk-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let (am, fake) = makeProvider()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player), appleMusic: am)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        _ = seq
        am.stop()                                   // MusicKit used + released this launch
        fake.isPlaying = true
        player.handleInterruption(began: true, shouldResume: nil)
        await waitUntil("interruption-triggered stray check reclaimed MusicKit") { fake.releaseCount == 2 }
    }

    // MARK: 2b — what the set does with ▶ handed back

    func testStrayReclaimAction() {
        typealias S = SetlistPlayer
        XCTAssertEqual(S.strayReclaimAction(isRunning: false, isHeld: false, appleMusicActive: false,
                                            engineHasLocalItem: true, startPending: false), .none)
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: true,
                                            engineHasLocalItem: false, startPending: false), .none,
                       "an Apple Music row is never stray")
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: true, appleMusicActive: false,
                                            engineHasLocalItem: false, startPending: false), .resumeHeld)
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                            engineHasLocalItem: true, startPending: false), .resumeEngine,
                       "the 22:16:25 case: Isn't She Lovely loaded → play IT")
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                            engineHasLocalItem: true, startPending: true), .resumeEngine)
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                            engineHasLocalItem: false, startPending: true), .none,
                       "a start in flight will sound on its own")
        XCTAssertEqual(S.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                            engineHasLocalItem: false, startPending: false), .startCurrent)
    }
}
