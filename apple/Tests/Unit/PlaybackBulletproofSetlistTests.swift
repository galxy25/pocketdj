import AVFoundation
import MediaPlayer
import XCTest
@testable import PocketDJ

/// docs/design/playback-bulletproof-plan.md — the SETLIST / PlayerEngine lane:
/// P0-1 (remote ▶ reaches a held / idle set + the pre-restore latch), P0-2 (a restore prefers
/// the set as the remote target), P0-4 (owner/intent-scoped interruption `.ended`), P0-6
/// (ownership held across a local→next gap), P1-7 (runway until first audio, start watchdog,
/// honest card, dead item advances), P1-8 (bounded AM `.interrupted` auto-resume) and the §3
/// supervisor core. Uses the same offline rips/burns/coordinator rig as `SetlistPlayerTests`.
@MainActor
final class PlaybackBulletproofSetlistTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!
    private var saved: (rekick: Double, escalate: Double, cap: Double, maxAge: TimeInterval, failDelay: Double)!

    override func setUp() {
        super.setUp()
        NowPlayingArbiter.shared.resetForTesting()
        BulletproofStub.hangPresign = []
        saved = (SetlistPlayer.startStallRekickSeconds, SetlistPlayer.startStallEscalateSeconds,
                 SetlistPlayer.startRunwayCapSeconds, SetlistPlayer.pendingRemotePlayMaxAge,
                 PlayerEngine.itemFailedSignalDelay)
        // The stub "burned files" are undecodable bytes: keep their failure from advancing the
        // set mid-test unless a test asks for it.
        PlayerEngine.itemFailedSignalDelay = 60
    }

    override func tearDown() {
        SetlistPlayer.startStallRekickSeconds = saved.rekick
        SetlistPlayer.startStallEscalateSeconds = saved.escalate
        SetlistPlayer.startRunwayCapSeconds = saved.cap
        SetlistPlayer.pendingRemotePlayMaxAge = saved.maxAge
        PlayerEngine.itemFailedSignalDelay = saved.failDelay
        BulletproofStub.hangPresign = []
        NowPlayingArbiter.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: Rig

    private struct Rig { let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
                         let coord: PlaybackCoordinator; let seq: SetlistPlayer }

    private func makeRig() -> Rig {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BulletproofStub.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://imac.test"
        settings.ripToken = ""
        rips.settings = settings
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bpburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        return Rig(rips: rips, burns: burns, player: player, coord: coord, seq: seq)
    }

    private func burn(_ r: Rig, _ ids: [String]) async {
        var m: [String: RipsStore.ManifestEntry] = [:]
        for id in ids { m[id] = .init(key: "rips/\(id).mp3", source: "digital") }
        r.rips.setManifest(m)
        for id in ids {
            Self.cleanBurned(id)
            addTeardownBlock { Self.cleanBurned(id) }
            _ = await r.burns.burn([(id: id, title: id, artist: "A")])
            XCTAssertNotNil(r.burns.localURL(forSong: id), "precondition: \(id) is burned")
        }
    }

    nonisolated private static func cleanBurned(_ id: String) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in ["\(id).mp3", "\(id).txt"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    private func snapshot(_ ids: [String], index: Int = 0, positionMs: Int = 0) -> PlaybackSessionStore.Snapshot {
        PlaybackSessionStore.Snapshot(
            sessionId: "pses_bp_\(UUID().uuidString)", source: .init(kind: "setlist", id: "set_bp", name: "BP"),
            queue: ids.map { .init(songId: $0, title: $0, artist: "A", lengthMs: 200_000, repeatCount: nil) },
            index: index, positionMs: positionMs, isPlaying: true, updatedAt: 0)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    // MARK: P0-1 — remote ▶ on a HELD set resumes it

    func testRemotePlayOnHeldDeckResumesTheHeldSessionAtItsPosition() async {
        let r = makeRig()
        await burn(r, ["bp_held"])
        r.seq.restore(from: snapshot(["bp_held"], positionMs: 42_000))
        XCTAssertTrue(r.seq.isHeldForResume)
        XCTAssertFalse(r.player.hasLoadedItem, "held — no audio yet")

        // The head unit's play-on-connect: the PlayerEngine playCommand target body.
        XCTAssertEqual(r.player.handleRemotePlay(), .success)
        XCTAssertFalse(r.seq.isHeldForResume, "the remote ▶ resumed the held set (was: REFUSED (idle))")
        await waitUntil("resume started the burned row") { r.rips.nowPlaying?.songId == "bp_held" }
        XCTAssertEqual(r.rips.nowPlaying?.seekMs, 42_000, "resumes AT the saved position")
        XCTAssertNil(r.player.pendingRemotePlayAt, "handled — nothing latched")
        r.seq.stop()
    }

    /// The ⏯ variant (some head units send toggle) takes the same ladder.
    func testRemoteToggleOnHeldDeckResumesToo() async {
        let r = makeRig()
        await burn(r, ["bp_tog"])
        r.seq.restore(from: snapshot(["bp_tog"]))
        XCTAssertEqual(r.player.handleRemoteToggle(), .success)
        XCTAssertFalse(r.seq.isHeldForResume)
        await waitUntil("resumed") { r.rips.nowPlaying?.songId == "bp_tog" }
        r.seq.stop()
    }

    /// A ▶ that lands BEFORE the launch task restored the session is latched and honoured by
    /// the restore — exactly once.
    func testRemotePlayBeforeRestoreIsLatchedAndHonouredOnce() async {
        let r = makeRig()
        await burn(r, ["bp_pre"])
        XCTAssertEqual(r.player.handleRemotePlay(), .success)
        XCTAssertNotNil(r.player.pendingRemotePlayAt, "refused-idle with no session → latched")

        r.seq.restore(from: snapshot(["bp_pre"], positionMs: 5_000))
        XCTAssertFalse(r.seq.isHeldForResume, "the latched ▶ resumed the restored set")
        XCTAssertNil(r.player.pendingRemotePlayAt, "consumed")
        await waitUntil("resumed") { r.rips.nowPlaying?.songId == "bp_pre" }

        r.seq.stop()
        r.seq.restore(from: snapshot(["bp_pre"]))
        XCTAssertTrue(r.seq.isHeldForResume, "a later restore does NOT resume again")
        r.seq.stop()
    }

    func testStaleLatchedRemotePlayIsIgnored() async {
        SetlistPlayer.pendingRemotePlayMaxAge = 0.05
        let r = makeRig()
        _ = r.player.handleRemotePlay()
        try? await Task.sleep(nanoseconds: 150_000_000)
        r.seq.restore(from: snapshot(["bp_stale"]))
        XCTAssertTrue(r.seq.isHeldForResume, "a ▶ older than the window must not wake a later restore")
        XCTAssertNil(r.player.pendingRemotePlayAt)
        r.seq.stop()
    }

    /// A deliberately stopped set is never resurrected by a remote ▶.
    func testRemotePlayOnStoppedSetDoesNothing() {
        let r = makeRig()
        XCTAssertNil(r.player.onIdlePlay?(), "not running → the hook declines")
        _ = r.player.handleRemotePlay()
        XCTAssertFalse(r.seq.isRunning)
    }

    // MARK: P0-2 — the held set is the preferred remote target; stop clears it

    func testRestorePrefersThePlayerAndStopClearsIt() {
        let r = makeRig()
        r.seq.restore(from: snapshot(["bp_pref"]))
        XCTAssertTrue(NowPlayingArbiter.shared.preferred === r.player)
        XCTAssertNil(NowPlayingArbiter.shared.owner, "a restore never claims the card")
        XCTAssertFalse(NowPlayingArbiter.shared.isActive(NSObject()), "a parked engine is not a remote target")
        r.seq.stop()
        XCTAssertNil(NowPlayingArbiter.shared.preferred)
    }

    // MARK: P0-6 — ownership held across the local → next gap

    func testOwnershipStaysWithThePlayerAcrossALocalToCloudAdvance() async {
        let r = makeRig()
        await burn(r, ["bp_b1"])
        var m = [String: RipsStore.ManifestEntry]()
        m["bp_b1"] = .init(key: "rips/bp_b1.mp3", source: "digital")
        m["bp_c2"] = .init(key: "rips/bp_c2.mp3", source: "digital")
        r.rips.setManifest(m)
        BulletproofStub.hangPresign = ["bp_c2"]          // the next row's resolve sits in the gap
        r.seq.play([.init(id: "bp_b1", title: "B1", artist: "A"), .init(id: "bp_c2", title: "C2", artist: "A")])
        await waitUntil("b1 playing") { r.rips.nowPlaying?.songId == "bp_b1" }
        XCTAssertTrue(NowPlayingArbiter.shared.owner === r.player)

        r.player.onTrackEnded?()                          // b1 ends → local-lane stop → resolve c2
        await waitUntil("in the gap (engine idle, resolve in flight)") { r.seq.index == 1 && !r.player.hasLoadedItem }
        XCTAssertTrue(NowPlayingArbiter.shared.owner === r.player,
                      "the set keeps the card across the gap (a parked Mix can't grab it)")

        r.seq.stop()
        XCTAssertNil(NowPlayingArbiter.shared.owner, "a finished set still frees the card")
    }

    // MARK: P1-7 — runway until first audio + start watchdog

    func testLocalLaneStartHoldsARunwayUntilFirstAudio() async {
        let r = makeRig()
        await burn(r, ["bp_rw"])
        r.seq.play([.init(id: "bp_rw", title: "RW", artist: "A")])
        await waitUntil("loaded") { r.rips.nowPlaying?.songId == "bp_rw" }
        XCTAssertTrue(r.seq.startRunwayHeldForTesting, "the local-file branch holds a runway now (was: none)")
        XCTAssertTrue(r.seq.isStartPending)
        XCTAssertGreaterThanOrEqual(PlaybackRunway.activeCount, 1)
        XCTAssertTrue(r.seq.startStallArmedForTesting, "start watchdog armed after a local-lane load")

        let before = PlaybackRunway.activeCount
        // The engine's first-audio hook (fired once per load from the timeControlStatus KVO —
        // `PlayerEngineBulletproofTests` covers that side; the stub bytes never render, and
        // can fail first, so drive the hook the sequencer wired directly).
        r.player.onFirstAudio?()
        XCTAssertFalse(r.seq.startRunwayHeldForTesting, "first audio closes the start window")
        XCTAssertEqual(PlaybackRunway.activeCount, before - 1)
        XCTAssertFalse(r.seq.startStallArmedForTesting, "…and disarms the watchdog")
        r.seq.stop()
    }

    func testStartRunwayIsCapped() async {
        SetlistPlayer.startRunwayCapSeconds = 0.3
        let r = makeRig()
        await burn(r, ["bp_cap"])
        r.seq.play([.init(id: "bp_cap", title: "Cap", artist: "A")])
        await waitUntil("loaded") { r.rips.nowPlaying?.songId == "bp_cap" }
        await waitUntil("cap ended the runway") { !r.seq.startRunwayHeldForTesting }
        r.seq.stop()
    }

    /// A start that never renders: re-kick at the first threshold, escalate at the second —
    /// here a hop to the next on-device row (the stalled row is deferred, never dropped).
    func testStartWatchdogRekicksThenEscalates() async {
        SetlistPlayer.startStallRekickSeconds = 0.2
        SetlistPlayer.startStallEscalateSeconds = 0.5
        let r = makeRig()
        await burn(r, ["bp_s1", "bp_s2"])
        r.seq.play([.init(id: "bp_s1", title: "S1", artist: "A"), .init(id: "bp_s2", title: "S2", artist: "A")])
        await waitUntil("s1 loaded") { r.rips.nowPlaying?.songId == "bp_s1" }
        let activations = r.player.sessionActivationRequests
        await waitUntil("re-kicked in place") { r.player.sessionActivationRequests > activations }
        XCTAssertEqual(r.rips.nowPlaying?.songId, "bp_s1", "the re-kick stays on the row")
        await waitUntil("escalated to the next on-device row") { r.rips.nowPlaying?.songId == "bp_s2" }
        XCTAssertEqual(r.seq.queue.map(\.id), ["bp_s2", "bp_s1"], "stalled row deferred, not dropped")
        r.seq.stop()
    }

    /// The watchdog never fires on a listener pause.
    func testStartWatchdogStandsDownOnAListenerPause() async {
        SetlistPlayer.startStallRekickSeconds = 0.1
        SetlistPlayer.startStallEscalateSeconds = 0.2
        let r = makeRig()
        await burn(r, ["bp_p1", "bp_p2"])
        r.seq.play([.init(id: "bp_p1", title: "P1", artist: "A"), .init(id: "bp_p2", title: "P2", artist: "A")])
        await waitUntil("p1 loaded") { r.rips.nowPlaying?.songId == "bp_p1" }
        r.player.pause()
        let activations = r.player.sessionActivationRequests
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(r.rips.nowPlaying?.songId, "bp_p1", "a paused start is never advanced")
        XCTAssertEqual(r.player.sessionActivationRequests, activations, "…nor re-kicked")
        r.seq.stop()
    }

    /// A dead item (`.failed`) advances the set instead of sitting silent.
    func testFailedItemAdvancesTheSet() async {
        PlayerEngine.itemFailedSignalDelay = 0.05
        let r = makeRig()
        await burn(r, ["bp_f1"])
        var m = [String: RipsStore.ManifestEntry]()
        m["bp_f1"] = .init(key: "rips/bp_f1.mp3", source: "digital")
        m["bp_f2"] = .init(key: "rips/bp_f2.mp3", source: "digital")
        r.rips.setManifest(m)
        BulletproofStub.hangPresign = ["bp_f2"]          // the next row parks in its resolve
        r.seq.play([.init(id: "bp_f1", title: "F1", artist: "A"), .init(id: "bp_f2", title: "F2", artist: "A")])
        await waitUntil("advanced off the undecodable item", timeout: 5) { r.seq.index == 1 }
        XCTAssertTrue(r.seq.isRunning)
        r.seq.stop()
    }
}

// MARK: - PlayerEngine seams

@MainActor
final class PlayerEngineBulletproofTests: XCTestCase {
    private var savedDelay: Double = 0

    override func setUp() {
        super.setUp()
        NowPlayingArbiter.shared.resetForTesting()
        NowPlayingCardPublisher.shared.resetForTesting()
        savedDelay = PlayerEngine.itemFailedSignalDelay
    }

    override func tearDown() {
        PlayerEngine.itemFailedSignalDelay = savedDelay
        NowPlayingCardPublisher.shared.sink = nil
        NowPlayingArbiter.shared.resetForTesting()
        super.tearDown()
    }

    private final class Probe { var plays = 0; var pauses = 0; var playing = true }

    private func beginExternal(_ e: PlayerEngine, _ p: Probe) {
        e.beginExternalNowPlaying(title: "AM", artist: "X", songId: "am:1", durationSeconds: 200,
                                  position: { 10 }, isPlaying: { p.playing },
                                  play: { p.plays += 1; p.playing = true },
                                  pause: { p.pauses += 1; p.playing = false })
    }

    func testIdleRemotePlayLatchesOnceAndExpires() {
        let e = PlayerEngine()
        XCTAssertEqual(e.handleRemotePlay(), .success)
        XCTAssertNotNil(e.pendingRemotePlayAt)
        XCTAssertNotNil(e.consumePendingRemotePlay(maxAge: 15))
        XCTAssertNil(e.consumePendingRemotePlay(maxAge: 15), "one-shot")
        _ = e.handleRemotePlay()
        XCTAssertNil(e.consumePendingRemotePlay(maxAge: 15, now: Date().addingTimeInterval(60)), "stale ⇒ dropped")
    }

    func testIdlePlayOffersTheHookFirst() {
        let e = PlayerEngine()
        var calls = 0
        e.onIdlePlay = { calls += 1; return "resumeHeld" }
        e.play()
        XCTAssertEqual(calls, 1, "play() at the idle guard asks the owner first")
        XCTAssertEqual(e.handleRemotePlay(), .success)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(e.pendingRemotePlayAt, "handled by the hook → nothing latched")
    }

    func testRemotePlayRefusedForANonOwner() {
        let e = PlayerEngine()
        let parked = NSObject()
        NowPlayingArbiter.shared.prefer(parked)
        var calls = 0
        e.onIdlePlay = { calls += 1; return "x" }
        XCTAssertEqual(e.handleRemotePlay(), .commandFailed)
        XCTAssertEqual(calls, 0)
        withExtendedLifetime(parked) {}
    }

    // P0-4 — interruption `.ended` is intent-scoped

    func testExternalEndedDoesNotResumeAnIntentionalPauseOrTouchTheSession() {
        let e = PlayerEngine(); let p = Probe()
        beginExternal(e, p)
        e.appleMusicPauseWasIntentional = { true }
        e.handleInterruption(began: true, shouldResume: nil)
        XCTAssertTrue(e.interruptionOpen)
        let activations = e.sessionActivationRequests
        XCTAssertEqual(e.handleInterruption(began: false, shouldResume: true), "hold")
        XCTAssertEqual(p.plays, 0, "a stream the listener paused stays paused")
        XCTAssertEqual(e.sessionActivationRequests, activations, "MusicKit owns the session — no setActive")
        XCTAssertFalse(e.interruptionOpen)
    }

    func testExternalEndedResumesAPlayingStreamWithoutReactivatingTheSession() {
        let e = PlayerEngine(); let p = Probe()
        beginExternal(e, p)
        e.appleMusicPauseWasIntentional = { false }
        e.handleInterruption(began: true, shouldResume: nil)
        let activations = e.sessionActivationRequests
        XCTAssertEqual(e.handleInterruption(began: false, shouldResume: true), "resume")
        XCTAssertEqual(p.plays, 1)
        XCTAssertEqual(e.sessionActivationRequests, activations)
        XCTAssertTrue(e.listenerIntentPlaying)
    }

    func testEndedWithoutShouldResumeHoldsAndParksTheIntent() {
        let e = PlayerEngine(); let p = Probe()
        beginExternal(e, p)
        e.handleInterruption(began: true, shouldResume: nil)
        XCTAssertEqual(e.handleInterruption(began: false, shouldResume: false), "hold")
        XCTAssertEqual(p.plays, 0)
        XCTAssertFalse(e.listenerIntentPlaying, "the supervisor must not resume what the system said not to")
    }

    func testStreamNotPlayingAtBeganIsNotResumed() {
        let e = PlayerEngine(); let p = Probe()
        p.playing = false
        beginExternal(e, p)
        e.handleInterruption(began: true, shouldResume: nil)
        XCTAssertEqual(e.handleInterruption(began: false, shouldResume: true), "hold")
        XCTAssertEqual(p.plays, 0)
    }

    func testLocalListenerPauseSurvivesAnInterruption() {
        let e = PlayerEngine()
        e.load(url: FileManager.default.temporaryDirectory.appendingPathComponent("pdj-bp-\(UUID().uuidString).mp3"),
               live: false, startMs: nil, title: "L", artist: "A")
        e.pause()
        e.handleInterruption(began: true, shouldResume: nil)
        XCTAssertEqual(e.handleInterruption(began: false, shouldResume: true), "hold")
        XCTAssertTrue(e.pausedByListener)
        XCTAssertFalse(e.listenerIntentPlaying)
    }

    func testRouteLossIsAListenerPause() {
        let e = PlayerEngine()
        e.load(url: FileManager.default.temporaryDirectory.appendingPathComponent("pdj-bp-\(UUID().uuidString).mp3"),
               live: false, startMs: nil, title: "L", artist: "A")
        XCTAssertTrue(e.listenerIntentPlaying)
        e.handleRouteLoss()
        XCTAssertTrue(e.pausedByListener, "headphones / CarPlay unplugged ⇒ nobody re-kicks it")
        XCTAssertFalse(e.listenerIntentPlaying)
    }

    // P0-6

    func testHoldsOwnershipAcrossTracksSkipsTheResign() {
        let e = PlayerEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-bp-\(UUID().uuidString).mp3")
        e.load(url: url, live: false, startMs: nil, title: "T", artist: "A")
        XCTAssertTrue(NowPlayingArbiter.shared.owner === e)
        e.holdsOwnershipAcrossTracks = true
        e.stop()
        XCTAssertTrue(NowPlayingArbiter.shared.owner === e, "a running set keeps the card across the gap")
        e.load(url: url, live: false, startMs: nil, title: "T2", artist: "A")
        e.holdsOwnershipAcrossTracks = false
        e.stop()
        XCTAssertNil(NowPlayingArbiter.shared.owner, "without the hold, stop resigns as before")
    }

    // P1-7

    func testDeadItemSignalsTrackFailed() async {
        PlayerEngine.itemFailedSignalDelay = 0.05
        let e = PlayerEngine()
        var failed = 0
        e.onTrackFailed = { failed += 1 }
        e.load(url: URL(fileURLWithPath: "/nonexistent/pdj-bp-\(UUID().uuidString).mp3"),
               live: false, startMs: nil, title: "Dead", artist: "A")
        let deadline = Date().addingTimeInterval(2)
        while failed == 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(failed, 1, "a .failed item advances (within 2 s) instead of sitting silent")
        XCTAssertFalse(e.firstAudioPendingForTesting)
    }

    func testFirstAudioFiresOncePerLoad() {
        let e = PlayerEngine()
        var n = 0
        e.onFirstAudio = { n += 1 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-bp-\(UUID().uuidString).mp3")
        e.load(url: url, live: false, startMs: nil, title: "T", artist: "A")
        XCTAssertTrue(e.firstAudioPendingForTesting)
        e.simulateFirstAudioForTesting(); e.simulateFirstAudioForTesting()
        XCTAssertEqual(n, 1)
        e.load(url: url, live: false, startMs: nil, title: "T", artist: "A")
        e.simulateFirstAudioForTesting()
        XCTAssertEqual(n, 2, "re-armed by the next load")
        e.stop()
    }

    func testToggleOnAWaitingItemRekicksInsteadOfPausing() async throws {
        let e = PlayerEngine()
        // A non-routable host: the item can only ever WAIT for data.
        e.load(url: URL(string: "https://10.255.255.1/pdj-bp.mp3")!, live: false, startMs: nil, title: "W", artist: "A")
        let deadline = Date().addingTimeInterval(1)
        while e.timeControlStatus != .waitingToPlayAtSpecifiedRate && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard e.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            throw XCTSkip("AVPlayer did not enter waitingToPlayAtSpecifiedRate in this environment")
        }
        e.toggle()
        XCTAssertFalse(e.pausedByListener, "⏯ on a buffering start means play, not pause")
        XCTAssertNotEqual(e.timeControlStatus, .paused)
        e.pause()
        XCTAssertTrue(e.pausedByListener, "the discrete pause still pauses a buffering track")
        e.stop()
    }

    func testHonestCardPublishesPlayingStateWithAFrozenCursor() {
        var pubs: [NowPlayingCardPublisher.Publication] = []
        NowPlayingCardPublisher.shared.sink = { pubs.append($0) }
        NowPlayingCardPublisher.shared.publish(writer: "engine", title: "T", artist: "A", elapsed: 3,
                                               duration: 100, advancing: false, intentPlaying: true)
        XCTAssertEqual(pubs.last?.playbackState, .playing, "buffering start shows ⏸ (playing), not ▶")
        XCTAssertEqual(pubs.last?.rate, 0, "…with the cursor frozen")
        NowPlayingCardPublisher.shared.publish(writer: "engine", title: "T", artist: "A", elapsed: 3,
                                               duration: 100, advancing: false)
        XCTAssertEqual(pubs.last?.playbackState, .paused)
    }
}

// MARK: - P1-8 — Apple Music `.interrupted` bounded auto-resume (the injected gate seam)

@MainActor
final class AppleMusicInterruptedResumeTests: XCTestCase {
    private typealias Gate = AppleMusicPlaybackProvider.InterruptedResumeGate

    /// Poll the gate every 0.4 s (the monitor cadence) for `seconds`; return the poll times that fired.
    private func run(_ gate: inout Gate, seconds: Double, start: Date = Date(timeIntervalSince1970: 1000),
                     interrupted: Bool = true, intentional: Bool = false, session: Bool = false) -> [Double] {
        var fired: [Double] = []
        var t = 0.0
        while t <= seconds {
            if gate.observe(interrupted: interrupted, intentionalPause: intentional, sessionInterrupted: session,
                            now: start.addingTimeInterval(t)) { fired.append(t) }
            t += 0.4
        }
        return fired
    }

    func testInterruptedResumesTwiceOnTheLadderThenGivesUp() {
        var g = Gate()
        let fired = run(&g, seconds: 30)
        XCTAssertEqual(fired.count, 2, "one-shot at 2 s, then 6 s — never more per episode")
        XCTAssertGreaterThanOrEqual(fired[0], 2); XCTAssertLessThan(fired[0], 2.5)
        XCTAssertGreaterThanOrEqual(fired[1], 6); XCTAssertLessThan(fired[1], 6.5)
    }

    func testPausedNeverResumes() {
        var g = Gate()
        XCTAssertTrue(run(&g, seconds: 30, interrupted: false).isEmpty, ".paused is a user/system pause")
    }

    func testIntentionalPauseThenInterruptedNeverResumes() {
        var g = Gate()
        XCTAssertTrue(run(&g, seconds: 30, intentional: true).isEmpty, "pausePlayback() then .interrupted → never")
    }

    func testNoResumeDuringAnOpenSessionInterruption() {
        var g = Gate()
        XCTAssertTrue(run(&g, seconds: 10, session: true).isEmpty, "a phone call is in progress")
    }

    func testPerTrackCapBoundsAPingPong() {
        var g = Gate()
        var total = 0
        for episode in 0..<5 {
            let start = Date(timeIntervalSince1970: 1000 + Double(episode) * 100)
            total += run(&g, seconds: 10, start: start).count
            _ = g.observe(interrupted: false, intentionalPause: false, sessionInterrupted: false,
                          now: start.addingTimeInterval(11))   // back on air between episodes
        }
        XCTAssertEqual(total, Gate.maxPerTrack)
        g.resetForTrack()
        XCTAssertEqual(run(&g, seconds: 3).count, 1, "a new track gets a fresh budget")
    }

    func testProviderExposesTheIntentionalFlagReadOnly() {
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        XCTAssertFalse(am.pauseIsIntentional)
        am.setPauseWasIntentionalForTests(true)
        XCTAssertTrue(am.pauseIsIntentional)
    }
}

/// Minimal rip-server / S3 stub: presign echoes a stub URL (or HANGS for listed songs); any
/// other request answers 200 with undecodable bytes (a "burned file").
private final class BulletproofStub: URLProtocol {
    nonisolated(unsafe) static var hangPresign: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            if Self.hangPresign.contains(song) { return }   // never answers (a dead zone)
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"url":"https://imac.test/rips/\#(song).mp3"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("BURNT-MP3".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
