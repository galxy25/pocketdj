import XCTest
@testable import PocketDJ

/// The 2026-10-13 "Potential" cascade (macOS, rip server on the SAME Mac): every track start
/// queued a rip; the server's live capture drove Music.app, which interrupted the app's Apple
/// Music stream; the set read that as an end / dead source and advanced — queueing another
/// rip. The server was left capturing a long queue nobody heard while no music played.
///
/// Three fixes, three groups of tests:
///   1. the RIP-AHEAD WINDOW (playing row + next 10): gate + track + cancel on playhead move,
///      reshuffle/queue edit, stop and a new session — never a user-requested rip, never a
///      row the listener heard;
///   2. the CASCADE BREAKER: 3 quick auto-advances in a row → pause on the row, keep position;
///   3. an Apple Music `.stopped` far short of the track's length is an INTERRUPTION (hold),
///      not the end of the track (advance).
@MainActor
final class PlaybackRipWindowTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        WindowStub.reset()
    }

    override func tearDown() {
        WindowStub.reset()
        RipsStore.localHostNameOverride = nil
        super.tearDown()
    }

    // MARK: - 1a. The window itself (pure)

    private func rows(_ n: Int) -> [(id: String, resolveId: String)] {
        (0..<n).map { ("c\($0)", "c\($0)") }
    }

    func testWindowIsThePlayingRowPlusTheNextTen() {
        XCTAssertEqual(PlaybackRipWindow.ahead, 10)
        let w = PlaybackRipWindow.windowIds(rows: rows(20), index: 3)
        XCTAssertEqual(w, Set((3...13).map { "c\($0)" }))
        XCTAssertFalse(PlaybackRipWindow.allows("c2", rows: rows(20), index: 3), "behind the playhead")
        XCTAssertFalse(PlaybackRipWindow.allows("c14", rows: rows(20), index: 3), "11 ahead")
        XCTAssertTrue(PlaybackRipWindow.allows("c13", rows: rows(20), index: 3))
        XCTAssertEqual(PlaybackRipWindow.windowIds(rows: rows(5), index: 4), ["c4"], "clamped at the end")
        XCTAssertEqual(PlaybackRipWindow.windowIds(rows: rows(5), index: 9), [], "out of range")
    }

    func testWindowCoversBothTheBaseAndTheVariantIdOfARow() {
        let w = PlaybackRipWindow.windowIds(rows: [("s1", "s1_explicit")], index: 0)
        XCTAssertEqual(w, ["s1", "s1_explicit"])
    }

    func testMovingThePlayheadEvictsWhatFellBehind() {
        var w = PlaybackRipWindow()
        ["c0", "c1", "c5"].forEach { w.record($0) }
        let evicted = w.evict(keeping: PlaybackRipWindow.windowIds(rows: rows(20), index: 2))
        XCTAssertEqual(evicted, ["c0", "c1"])
        XCTAssertEqual(w.requested, ["c5"])
        XCTAssertEqual(w.evict(keeping: PlaybackRipWindow.windowIds(rows: rows(20), index: 2)), [],
                       "evicted ids are forgotten — never cancelled twice")
    }

    func testAReorderThatPushesARowPastTheWindowEvictsIt() {
        var w = PlaybackRipWindow()
        ["c3", "c6"].forEach { w.record($0) }
        var order = rows(20)
        let moved = order.remove(at: 6)
        order.append(moved)                                   // c6 → the end of the queue
        XCTAssertEqual(w.evict(keeping: PlaybackRipWindow.windowIds(rows: order, index: 0)), ["c6"])
    }

    func testEndingTheSessionCancelsAllButThePlayingRow() {
        var w = PlaybackRipWindow()
        ["c1", "c2", "c3"].forEach { w.record($0) }
        XCTAssertEqual(w.endSession(playing: ["c2"]), ["c1", "c3"])
        XCTAssertTrue(w.requested.isEmpty)
    }

    func testAHeardRowIsNeverEvicted() {
        var w = PlaybackRipWindow()
        ["c0", "c1"].forEach { w.record($0) }
        w.keep(["c0"])
        XCTAssertEqual(w.evict(keeping: []), ["c1"])
    }

    // MARK: - 1b. The window wired into the real sequencer

    private struct Rig { let rips: RipsStore; let player: PlayerEngine
                         let coord: PlaybackCoordinator; let seq: SetlistPlayer }

    private func makeRig(server: String = "https://server.test") -> Rig {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WindowStub.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = server
        settings.ripToken = ""
        rips.settings = settings
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-ripwindow-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        return Rig(rips: rips, player: player, coord: coord, seq: seq)
    }

    private func items(_ n: Int) -> [SetlistPlayer.Item] {
        (0..<n).map { SetlistPlayer.Item(id: "c\($0)", title: "c\($0)", artist: "A") }
    }

    private func manifest(_ rips: RipsStore, _ n: Int) {
        var m: [String: RipsStore.ManifestEntry] = [:]
        for i in 0..<n { m["c\(i)"] = .init(key: "rips/c\(i).mp3", source: "digital") }
        rips.setManifest(m)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    func testPlaybackRipGateOnlyAllowsTheWindowOfTheRunningSet() async {
        let r = makeRig()
        manifest(r.rips, 15)
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        XCTAssertTrue(r.seq.playbackRipAllowed("c0"), "the playing row")
        XCTAssertTrue(r.seq.playbackRipAllowed("c10"), "10 ahead")
        XCTAssertFalse(r.seq.playbackRipAllowed("c11"), "11 ahead")
        XCTAssertTrue(r.seq.playbackRipAllowed("zz_not_in_set"), "another surface's song is not ours to gate")
        // The store consults the same gate: a playback rip outside the window never POSTs.
        r.rips.setManifest([:])
        await r.rips.requestRipIfNeeded("c12", playback: true)
        XCTAssertEqual(WindowStub.ripPosts, [], "outside the window → no POST /rip")
        await r.rips.requestRipIfNeeded("c12")                    // not playback-originated
        XCTAssertEqual(WindowStub.ripPosts, ["c12"], "a non-playback request is not gated")
        r.seq.stop()
    }

    func testAQueuedPlaybackRipIsTrackedAndCancelledOnceThePlayheadLeavesIt() async {
        let r = makeRig()
        manifest(r.rips, 15)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }

        r.rips.onPlaybackRipQueued?("c0")
        r.rips.onPlaybackRipQueued?("c3")
        r.rips.onPlaybackRipQueued?("c10")
        r.rips.onPlaybackRipQueued?("zz_single")                 // not a set member → ignored
        XCTAssertEqual(r.seq.ripWindow.requested, ["c0", "c3", "c10"])
        r.rips.onPlaybackRipQueued?("c12")                       // landed outside → cancelled now
        XCTAssertEqual(cancelled, ["c12"])

        r.seq.skipNext()                                         // playhead → c1
        XCTAssertEqual(cancelled, ["c12", "c0"], "c0 fell behind the playhead (never heard)")
        let c5 = r.seq.queue[5].uid
        r.seq.jumpToUpcoming(uid: c5)                            // playhead → c5 (window c5…c14)
        XCTAssertEqual(cancelled, ["c12", "c0", "c3"])
        XCTAssertEqual(r.seq.ripWindow.requested, ["c10"])

        r.seq.stop()
        XCTAssertEqual(cancelled, ["c12", "c0", "c3", "c10"], "stop cancels the rest")
    }

    func testStopKeepsThePlayingRowsRipAndANewSessionCancelsTheOldOnes() async {
        let r = makeRig()
        manifest(r.rips, 15)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        r.rips.onPlaybackRipQueued?("c0")
        r.rips.onPlaybackRipQueued?("c2")
        // A fresh session replaces this one: the old window's rips go, except the sounding row.
        r.seq.play(items(3).reversed())
        XCTAssertEqual(cancelled, ["c2"])
        XCTAssertTrue(r.seq.ripWindow.requested.isEmpty)
        r.seq.stop()
    }

    func testAQueueReorderThatPushesARowOutOfTheWindowCancelsIt() async {
        let r = makeRig()
        manifest(r.rips, 15)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        r.rips.onPlaybackRipQueued?("c3")
        r.rips.onPlaybackRipQueued?("c4")
        r.seq.moveUpcomingToEnd(uid: r.seq.queue[3].uid)         // c3 → position 14
        await waitUntil("the reorder reconciled") { cancelled == ["c3"] }
        XCTAssertEqual(r.seq.ripWindow.requested, ["c4"])
        r.seq.stop()
    }

    func testAReshuffleCancelsExactlyTheTrackedRowsItPushedOutOfTheWindow() async {
        let r = makeRig()
        manifest(r.rips, 30)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(30))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        let tracked = (1...10).map { "c\($0)" }
        tracked.forEach { r.rips.onPlaybackRipQueued?($0) }
        r.seq.setShuffle(true)
        let window = Set(r.seq.queue[0...10].map(\.id))
        let expected = Set(tracked).subtracting(window)
        await waitUntil("the reshuffle reconciled") { Set(cancelled) == expected }
        XCTAssertEqual(r.seq.ripWindow.requested, Set(tracked).intersection(window))
        r.seq.stop()
    }

    func testAHeardRowsRipIsNeverCancelled() async {
        let r = makeRig()
        manifest(r.rips, 15)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        r.rips.onPlaybackRipQueued?("c0")
        r.seq.addAudibleSeconds(PlaybackRipWindow.heardSeconds + 1)   // the listener heard c0
        r.seq.skipNext()
        r.seq.stop()
        XCTAssertEqual(cancelled, [], "the passive rip of a song the listener heard stays queued")
    }

    func testAUserRequestedRipIsNeverCancelledByTheWindow() async {
        let r = makeRig()
        manifest(r.rips, 15)
        var cancelled: [String] = []
        r.seq.cancelPlaybackRips = { cancelled += $0 }
        r.seq.play(items(15))
        await waitUntil("c0 playing") { r.rips.nowPlaying?.songId == "c0" }
        r.rips.onPlaybackRipQueued?("c1")
        r.rips.onPlaybackRipQueued?("c2")
        r.rips.setManifest([:])
        _ = await r.rips.requestRip(songId: "c1", title: "c1", artist: "A")   // the user asked too
        XCTAssertTrue(r.rips.isUserRequestedRip("c1"))
        r.seq.stop()
        XCTAssertEqual(cancelled, ["c2"])
    }

    func testPlaybackRipIfNeededReportsTheQueuedJobOnlyForPlaybackRequests() async {
        let r = makeRig()
        var queued: [String] = []
        r.rips.onPlaybackRipQueued = { queued.append($0) }
        await r.rips.requestRipIfNeeded("p1", playback: true)
        await r.rips.requestRipIfNeeded("p2")
        XCTAssertEqual(WindowStub.ripPosts, ["p1", "p2"])
        XCTAssertEqual(queued, ["p1"])
    }

    // MARK: - 2. The cascade breaker

    func testBreakerTripsOnTheThirdQuickAutoAdvanceInARow() {
        var b = AutoAdvanceCascadeBreaker()
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 4.9))
        XCTAssertTrue(b.shouldHalt(afterAudibleSeconds: 1))
    }

    func testBreakerResetsOnAPlayedTrackOrAUserAction() {
        var b = AutoAdvanceCascadeBreaker()
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 200), "a track that played breaks the run")
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
        b.reset()
        XCTAssertFalse(b.shouldHalt(afterAudibleSeconds: 0))
    }

    /// Every row is a dead source (no server, nothing ripped): before, the set skipped through
    /// the whole queue in a blink. Now it stops on the third row, paused, position kept.
    func testDeadSourceCascadeStopsOnTheThirdRowAndKeepsThePosition() async {
        let r = makeRig(server: "")
        r.seq.play(items(8))
        await waitUntil("the breaker tripped") { r.seq.pausedByCascade }
        XCTAssertEqual(r.seq.index, 2, "two quick advances happened; the third was refused")
        XCTAssertTrue(r.seq.isRunning, "paused, not stopped — the queue position survives")
        XCTAssertNotNil(r.seq.playbackNotice)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.seq.index, 2, "nothing auto-advances while halted")

        r.seq.skipNext()                                   // the listener acts → advancing resumes
        XCTAssertFalse(r.seq.pausedByCascade)
        XCTAssertNil(r.seq.playbackNotice)
        XCTAssertGreaterThanOrEqual(r.seq.index, 3)
        r.seq.stop()
    }

    /// ▶ on a halted deck retries the SAME row (it doesn't jump ahead).
    func testStartCurrentAfterACascadeRetriesTheSameRow() async {
        let r = makeRig(server: "")
        r.seq.play(items(8))
        await waitUntil("the breaker tripped") { r.seq.pausedByCascade }
        XCTAssertEqual(r.seq.index, 2)
        XCTAssertTrue(r.seq.startCurrent())
        XCTAssertFalse(r.seq.pausedByCascade)
        XCTAssertEqual(r.seq.index, 2, "▶ retries the halted row itself")
        // That row (and the next ones) are still dead: a FRESH count of quick advances runs
        // from the retried row and trips again two rows later.
        await waitUntil("tripped again") { r.seq.pausedByCascade }
        XCTAssertEqual(r.seq.index, 4)
        r.seq.stop()
    }

    /// Tracks that really played never trip the breaker, however many end in a row.
    func testPlayedTracksEndingInARowNeverTripTheBreaker() async {
        let r = makeRig()
        manifest(r.rips, 6)
        r.seq.play(items(6))
        for i in 0..<4 {
            await waitUntil("c\(i) playing") { r.rips.nowPlaying?.songId == "c\(i)" }
            r.seq.addAudibleSeconds(10)
            r.player.onTrackEnded?()
        }
        await waitUntil("c4 playing") { r.rips.nowPlaying?.songId == "c4" }
        XCTAssertFalse(r.seq.pausedByCascade)
        r.seq.stop()
    }

    /// The device-mode "no burned file here" skip is deliberate and instant — it must not
    /// count toward a cascade (a mostly-unburned set in device mode still plays its burns).
    func testDeviceModeUnplayableSkipsDoNotTripTheBreaker() async {
        let r = makeRig(server: "")
        r.seq.playbackMode = { .device }
        r.seq.play(items(6))
        await waitUntil("ran off the end of the set") { !r.seq.isRunning }
        XCTAssertFalse(r.seq.pausedByCascade)
    }

    // MARK: - 3. Interruption is not end-of-track

    func testStoppedFarShortOfTheLengthIsAnInterruption() {
        let saved = AppleMusicPlaybackProvider.interruptionGraceSeconds
        defer { AppleMusicPlaybackProvider.interruptionGraceSeconds = saved }
        AppleMusicPlaybackProvider.interruptionGraceSeconds = 10
        XCTAssertTrue(AppleMusicPlaybackProvider.stoppedByInterruption(
            stopped: true, expectedDuration: 180, playedSeconds: 4),
            "Music.app took over 4 s in — an interruption")
        XCTAssertTrue(AppleMusicPlaybackProvider.stoppedByInterruption(
            stopped: true, expectedDuration: 180, playedSeconds: 120))
        XCTAssertFalse(AppleMusicPlaybackProvider.stoppedByInterruption(
            stopped: true, expectedDuration: 180, playedSeconds: 178),
            "the one-song queue finished — the natural end")
        XCTAssertFalse(AppleMusicPlaybackProvider.stoppedByInterruption(
            stopped: true, expectedDuration: 0, playedSeconds: 4),
            "unknown length: the old .stopped ⇒ ended rule stands")
        XCTAssertFalse(AppleMusicPlaybackProvider.stoppedByInterruption(
            stopped: false, expectedDuration: 180, playedSeconds: 4))
    }

    /// The provider's interruption hook HOLDS the row and says why — no advance.
    func testAnAppleMusicInterruptionHoldsTheRowAndSurfacesANotice() async {
        let r = makeRig()
        manifest(r.rips, 3)
        r.seq.play(items(3))
        await waitUntil("c0 resolved") { r.rips.nowPlaying?.songId == "c0" }
        r.coord.setActiveBackendForTests(.appleMusic)
        r.coord.appleMusic.setNowPlayingForTests(.init(songId: "c0", title: "c0", artist: "A"))
        r.coord.appleMusic.onInterrupted?()
        XCTAssertEqual(r.seq.index, 0, "an interruption never advances the set")
        XCTAssertTrue(r.seq.isRunning)
        XCTAssertEqual(r.seq.playbackNotice, SetlistPlayer.appleMusicInterruptedNotice)
        r.seq.stop()
        XCTAssertNil(r.seq.playbackNotice)
    }

    // MARK: - Same-host detection (live capture on this Mac)

    func testSameHostNameComparesTheFirstLabelCaseInsensitively() {
        XCTAssertTrue(RipsStore.sameHostName("Levis-iMac.local", "levis-imac"))
        XCTAssertTrue(RipsStore.sameHostName("levis-imac", "Levis-iMac.tail1234.ts.net"))
        XCTAssertFalse(RipsStore.sameHostName("levis-imac", "levis-macbook"))
        XCTAssertFalse(RipsStore.sameHostName("", ""))
        XCTAssertTrue(RipsStore.isLoopbackHost("LOCALHOST"))
        XCTAssertTrue(RipsStore.isLoopbackHost("127.0.0.1"))
        XCTAssertFalse(RipsStore.isLoopbackHost("100.64.0.1"))
    }

    func testServerIsThisHost() async {
        RipsStore.localHostNameOverride = "levis-imac"
        WindowStub.healthHost = "Levis-iMac.local"
        let remote = makeRig(server: "https://imac.tail.ts.net/rip")
        let loopback = makeRig(server: "http://127.0.0.1:8787")
        #if os(macOS)
        let a = await remote.rips.serverIsThisHost()
        let b = await loopback.rips.serverIsThisHost()
        XCTAssertTrue(a, "/health names this machine")
        XCTAssertTrue(b)
        WindowStub.healthHost = "some-other-box"
        let other = makeRig(server: "https://other.tail.ts.net")
        let c = await other.rips.serverIsThisHost()
        XCTAssertFalse(c)
        #else
        // An iPhone / iPad / TV can never be the rip-server host.
        let a = await remote.rips.serverIsThisHost()
        let b = await loopback.rips.serverIsThisHost()
        XCTAssertFalse(a)
        XCTAssertFalse(b)
        #endif
    }
}

// MARK: - Stub rip server / S3

private final class WindowStub: URLProtocol {
    nonisolated(unsafe) static var ripPosts: [String] = []
    nonisolated(unsafe) static var healthHost = "nobody"
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        ripPosts = []; healthHost = "nobody"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let b = request.httpBody { return b }
        guard let s = request.httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("/health") {
            Self.lock.lock(); let host = Self.healthHost; Self.lock.unlock()
            respond(200, Data(#"{"ok":true,"host":"\#(host)"}"#.utf8)); return
        }
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            respond(200, Data(#"{"url":"https://s3.test/rips/\#(song).mp3?X-Amz-Signature=x"}"#.utf8)); return
        }
        if url.path.hasSuffix("/rip"), request.httpMethod == "POST" {
            let obj = bodyData().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let id = obj?["songId"] as? String ?? "?"
            Self.lock.lock(); Self.ripPosts.append(id); Self.lock.unlock()
            respond(200, Data(#"{"jobId":"job_\#(id)","songId":"\#(id)","phase":"queued"}"#.utf8)); return
        }
        if url.path.contains("/jobs/") {
            respond(200, Data(#"{"phase":"queued"}"#.utf8)); return
        }
        respond(200, Data("BURNT-MP3".utf8))
    }
}
