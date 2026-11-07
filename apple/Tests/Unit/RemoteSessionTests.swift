import XCTest
@testable import PocketDJ

/// The Remote (SharePlay) session state machine over a LoopbackTransport hub of fake devices —
/// every device a real `RemoteSessionController` driving an `InMemoryRemoteTarget` (no audio),
/// on a manual clock (per-device skew) so guard windows / drift / heartbeats are deterministic.
/// Ticks are driven by hand; every wait is on the asserted condition.
@MainActor
final class RemoteSessionTests: XCTestCase {

    // MARK: Fixtures

    private final class ManualClock { var t: Double = 5_000_000 }

    @MainActor private struct Device {
        let controller: RemoteSessionController
        let target: InMemoryRemoteTarget
        let link: LoopbackTransport
        var queueIds: [String] { target.queue.map(\.id) }
        var currentId: String? { target.currentItem?.id }
    }

    private let clock = ManualClock()
    private let hub = LoopbackHub()

    private static let songs: [String: (String, String)] = [
        "s1": ("One", "Aria"), "s2": ("Two", "Aria"), "s3": ("Three", "Cass"),
        "s4": ("Four", "Cass"), "s5": ("Five", "Luna"),
    ]

    private static func item(_ id: String) -> SetlistPlayer.Item {
        let (t, a) = songs[id] ?? (id, "?")
        return SetlistPlayer.Item(id: id, title: t, artist: a, lengthMs: 200_000)
    }

    private static func row(_ id: String, rid: String? = nil) -> RemoteRow {
        RemoteRow(item: item(id), rid: rid ?? "r-\(id)")
    }

    /// A catalog resolver over `known` song ids.
    private static func resolver(known: Set<String> = Set(songs.keys)) -> RemoteSongResolver {
        RemoteSongResolver(catalogItem: { known.contains($0) ? item($0) : nil })
    }

    private func device(_ id: String, skew: Double = 0, known: Set<String> = Set(songs.keys)) -> Device {
        let clock = self.clock
        let now: () -> Double = { clock.t + skew }
        let target = InMemoryRemoteTarget(now: now)
        let c = RemoteSessionController(target: target, resolver: Self.resolver(known: known),
                                        deviceName: "Device \(id)", platform: "test",
                                        clock: SharedClock(localNow: now))
        return Device(controller: c, target: target, link: hub.join(id: id))
    }

    private func seed(_ ids: [String], index: Int = 0, playing: Bool = true, positionMs: Int = 0) -> RemoteQueueModel {
        var m = RemoteQueueModel()
        m.rows = ids.map { Self.row($0) }
        m.index = index
        m.isPlaying = playing
        m.positionMs = positionMs
        m.anchor = clock.t
        m.revision = 1
        return m
    }

    private func advance(_ ms: Double) { clock.t += ms }

    /// FIFO barrier: everything `from` sent `to` before this point has been processed by `to`.
    private func barrier(_ from: Device, _ to: Device) async {
        let token = UUID().uuidString
        var seen = false
        to.controller.registerHandler(kind: "test.barrier") { env, _ in
            if String(data: env.payload, encoding: .utf8) == token { seen = true }
        }
        from.controller.sendRaw(RemoteEnvelope(v: 1, kind: "test.barrier", payload: Data(token.utf8)),
                                to: .participant(to.link.localParticipantId))
        await RemoteTestSupport.waitUntil { seen }
    }

    private func commandsSent(_ d: Device) -> Int {
        d.link.sent.filter { $0.0.kind == RemoteMessageKind.command.rawValue }.count
    }

    private func attachHost(_ d: Device, mode: RemoteSessionMode = .listenTogether, seed: RemoteQueueModel?) {
        d.controller.attach(d.link, mode: mode, asHost: true, seed: seed, autoTick: false)
    }

    private func attachGuest(_ d: Device, mode: RemoteSessionMode = .listenTogether) {
        d.controller.attach(d.link, mode: mode, asHost: false, autoTick: false)
    }

    // MARK: - Host broadcast → speaker reconcile

    func testSpeakerMirrorsQueueIndexPlayStateAndPositionWithoutEcho() async {
        let a = device("A"), b = device("B", skew: 4_000)
        attachHost(a, seed: seed(["s1", "s2", "s3", "s4"], index: 1, positionMs: 10_000))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        XCTAssertEqual(b.queueIds, ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(b.target.currentIndex, 1)
        XCTAssertTrue(b.target.isPlaying)
        XCTAssertEqual(b.target.positionMs, 10_000, "unsynced clock ⇒ the state's own position")
        XCTAssertEqual(b.target.log, ["play"])

        // ⏸ on the host — past the post-load guard — pauses the speaker.
        advance(2_500)
        a.controller.send(.playPause)
        await RemoteTestSupport.waitUntil { !b.target.isPlaying }

        // ⏭ moves the speaker with a JUMP (no reload of the set).
        advance(2_500)
        a.controller.send(.skipNext)
        await RemoteTestSupport.waitUntil { b.target.currentIndex == 2 }
        XCTAssertEqual(b.currentId, "s3")
        XCTAssertEqual(b.target.log.filter { $0 == "play" }.count, 1)

        // The speaker's own ticks never echo what it applied back as commands.
        let rev = a.controller.model.revision
        for _ in 0..<6 { advance(500); b.controller.tick() }
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0, "applying remote state must not re-broadcast it")
        XCTAssertEqual(a.controller.model.revision, rev)
        XCTAssertEqual(b.controller.state?.revision, rev)
    }

    func testDriftIsCorrectedOnlyPastTheThreshold() async {
        let a = device("A"), b = device("B", skew: -2_000)
        attachHost(a, seed: seed(["s1", "s2"], positionMs: 30_000))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        b.controller.tick()                                       // first ping
        await RemoteTestSupport.waitUntil { b.controller.clock.isSynced }
        XCTAssertEqual(b.controller.clock.offsetMs ?? 0, 2_000, accuracy: 0.001)
        advance(2_500)                                            // past the load guard
        b.controller.tick()
        let seeks = { b.target.log.filter { $0 == "seek" }.count }
        XCTAssertEqual(seeks(), 0, "in sync ⇒ no correction")

        // 600 ms off: under the 750 ms threshold → left alone.
        b.target.userSeek(b.target.positionMs + 600)
        b.controller.tick()
        XCTAssertEqual(seeks(), 0)

        // 2 s off: corrected with ONE seek onto the shared position.
        b.target.userSeek(b.target.positionMs + 1_400)
        b.controller.tick()
        XCTAssertEqual(seeks(), 1)
        let expected = a.controller.model.position(at: a.controller.clock.localNow())
        XCTAssertEqual(b.target.positionMs, expected)
        // …and the correction itself is not read back as a user scrub.
        for _ in 0..<4 { advance(500); b.controller.tick() }
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
    }

    // MARK: - Participant command → host → everyone converges

    func testParticipantCommandsConvergeAllDevicesOnTheSameRevision() async {
        let a = device("A"), b = device("B", skew: 900), c = device("C", skew: -1_700)
        attachHost(a, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b)
        attachGuest(c)
        let all = [a, b, c]
        await RemoteTestSupport.waitUntil { all.allSatisfy { $0.target.isRunning } }

        b.controller.send(.skipNext)
        b.controller.send(.append(rows: [Self.row("s5", rid: "r-new")]))
        await RemoteTestSupport.waitUntil {
            all.allSatisfy { $0.controller.state?.revision == a.controller.model.revision }
                && all.allSatisfy { $0.currentId == "s2" && $0.queueIds.last == "s5" }
        }
        XCTAssertEqual(a.controller.model.currentRow?.songId, "s2")

        // A LOCAL Now Playing ⏭ on C (its user, not a command) is turned into a session command.
        advance(2_500)
        c.controller.tick()                     // settle: past the guard, observation baseline
        c.target.userSkipNext()
        c.controller.tick()
        await RemoteTestSupport.waitUntil {
            all.allSatisfy { $0.currentId == "s3" && $0.controller.state?.revision == a.controller.model.revision }
        }
        // A local queue removal on B is forwarded too.
        advance(2_500)
        b.controller.tick()
        b.target.userRemoveUpcoming(at: 0)     // removes s5 (the only upcoming row)
        b.controller.tick()
        await RemoteTestSupport.waitUntil {
            a.controller.model.rows.map(\.songId) == ["s1", "s2", "s3"]
                && all.allSatisfy { $0.queueIds.last == "s3" }
        }
    }

    func testHostLocalFreshPlayBecomesTheSessionSet() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning && a.target.isRunning }
        advance(2_500)
        a.controller.tick()
        // The host's user starts a brand-new set from Browse.
        a.target.userPlay([Self.item("s4"), Self.item("s5")])
        a.controller.tick()
        XCTAssertEqual(a.controller.model.rows.map(\.songId), ["s4", "s5"])
        await RemoteTestSupport.waitUntil { b.queueIds == ["s4", "s5"] && b.currentId == "s4" }
        XCTAssertEqual(a.target.log.filter { $0 == "play" }.count, 1, "the host's own player isn't reloaded")
    }

    // MARK: - Backseat

    func testBackseatHostIsAControllerThatNeverPlaysLocally() async {
        let a = device("A"), b = device("B")
        // The controller phone was already playing a set — Backseat hands it to the car.
        a.target.userPlay([Self.item("s1"), Self.item("s2"), Self.item("s3")])
        attachHost(a, mode: .backseat, seed: nil)
        XCTAssertEqual(a.controller.localRole, .controller)
        XCTAssertFalse(a.target.isPlaying, "the controller's own audio stops")
        XCTAssertEqual(a.controller.model.rows.map(\.songId), ["s1", "s2", "s3"])

        attachGuest(b, mode: .backseat)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        XCTAssertEqual(b.controller.localRole, .speaker)
        XCTAssertEqual(b.currentId, "s1")
        XCTAssertTrue(b.target.isPlaying)

        advance(2_500)
        a.controller.send(.skipNext)
        a.controller.send(.enqueueNext(rows: [Self.row("s5", rid: "r-s5")]))
        await RemoteTestSupport.waitUntil { b.currentId == "s2" && b.queueIds.contains("s5") }
        for _ in 0..<4 { advance(500); a.controller.tick() }
        XCTAssertFalse(a.target.isPlaying)
        XCTAssertEqual(a.target.currentIndex, 0, "the controller's local player is never driven")
        XCTAssertFalse(a.target.log.contains("resume"))
        XCTAssertEqual(a.controller.peers.first(where: { !$0.isLocal })?.role, .speaker)

        // Flip the passenger phone to controller: it goes quiet.
        b.controller.setLocalRole(.controller)
        XCTAssertFalse(b.target.isPlaying)
        await RemoteTestSupport.waitUntil { a.controller.peers.first(where: { !$0.isLocal })?.role == .controller }
    }

    // MARK: - Host leaves → hand-over

    func testHostLeaveHandsOverToTheLowestRemainingId() async {
        let a = device("A"), b = device("B"), c = device("C")
        attachHost(a, seed: seed(["s1", "s2", "s3", "s4"], index: 1))
        attachGuest(b)
        attachGuest(c)
        await RemoteTestSupport.waitUntil { b.target.isRunning && c.target.isRunning }
        a.controller.leave()
        XCTAssertFalse(a.controller.isActive)
        XCTAssertTrue(a.target.isPlaying, "leaving keeps this device's music playing")

        await RemoteTestSupport.waitUntil { b.controller.isHost && c.controller.hostId == "B" }
        XCTAssertEqual(b.controller.model.rows.map(\.songId), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(b.controller.model.currentRow?.songId, "s2")

        advance(2_500)
        c.controller.send(.skipNext)
        await RemoteTestSupport.waitUntil { b.currentId == "s3" && c.currentId == "s3" }
        XCTAssertEqual(c.controller.state?.hostId, "B")
    }

    func testSessionEndKeepsSpeakersPlaying() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        hub.end()
        await RemoteTestSupport.waitUntil { !b.controller.isActive && !a.controller.isActive }
        XCTAssertTrue(b.target.isPlaying)
        XCTAssertEqual(b.currentId, "s1")
    }

    // MARK: - Song identity / rights

    func testResolutionCatalogThenAppleMusicThenTitleArtistElseUnavailable() {
        var amUsable = true
        let r = RemoteSongResolver(
            catalogItem: { $0 == "s1" ? Self.item("s1") : nil },
            catalogItemForAppleMusicId: { $0 == "999" ? Self.item("s1") : nil },
            matchTitleArtist: { t, a in t == "Three" && a == "Cass" ? Self.item("s3") : nil },
            appleMusicAvailable: { amUsable })
        func row(_ songId: String, title: String = "T", artist: String = "A", am: String? = nil) -> RemoteRow {
            RemoteRow(rid: "r", row: .init(songId: songId, title: title, artist: artist, lengthMs: 1,
                                           repeatCount: nil, appleMusicId: am))
        }
        XCTAssertEqual(r.resolve(row("s1")).item?.id, "s1")
        // Someone else's songId, but the Apple Music id is in OUR catalog.
        guard case .catalog(let mapped) = r.resolve(row("theirs", am: "999")) else { return XCTFail() }
        XCTAssertEqual(mapped.id, "s1")
        // Unknown here, Apple Music id → plays through this user's own Apple Music.
        guard case .appleMusic(let am) = r.resolve(row("theirs", am: "123")) else { return XCTFail() }
        XCTAssertEqual(am.id, "am:123")
        guard case .appleMusic(let ns) = r.resolve(row("am:555")) else { return XCTFail() }
        XCTAssertEqual(ns.id, "am:555")
        // Title + artist match.
        guard case .matched(let m) = r.resolve(row("theirs", title: "Three", artist: "Cass")) else { return XCTFail() }
        XCTAssertEqual(m.id, "s3")
        XCTAssertEqual(r.resolve(row("nope")), .unavailable)
        amUsable = false
        XCTAssertEqual(r.resolve(row("theirs", am: "123")), .unavailable, "no Apple Music here ⇒ unavailable")
        XCTAssertNil(RemoteSongResolver.storeId(fromNamespaced: "am:album:1"))
    }

    func testUnavailableRowsAreSkippedLocallyAndReportedToTheHost() async {
        let a = device("A"), b = device("B", known: ["s1", "s3"])
        attachHost(a, mode: .backseat, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b, mode: .backseat)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        XCTAssertEqual(b.queueIds, ["s1", "s3"])
        await RemoteTestSupport.waitUntil { a.controller.unavailableByPeer["B"] == ["r-s2"] }
        XCTAssertEqual(a.controller.unavailableDevices(for: "r-s2"), ["Device B"])
        XCTAssertEqual(a.controller.peers.first(where: { $0.id == "B" })?.unavailableCount, 1)

        // The session lands ON the unavailable row: this speaker plays the next one it can.
        advance(2_500)
        a.controller.send(.skipNext)
        await RemoteTestSupport.waitUntil { a.controller.state?.currentRow?.songId == "s2" && b.currentId == "s3" }
    }

    func testOutboundRowsCarryTheAppleMusicIdButNoRipUrls() throws {
        var r = Self.resolver()
        r.appleMusicIdForSong = { $0 == "s1" ? "1440" : nil }
        let c = RemoteSessionController(target: nil, resolver: r, deviceName: "X", platform: "t")
        let rows = c.rows(for: [Self.item("s1")])
        XCTAssertEqual(rows.first?.row.appleMusicId, "1440")
        let json = String(data: try JSONEncoder().encode(rows), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("http"), "rows are ids + names only")
    }

    // MARK: - Wire format forward-compat

    func testUnknownKindsNewerEnvelopesAndUnknownCommandsAreIgnored() async throws {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        let rev = a.controller.model.revision

        // An unknown kind with no handler: ignored. A registered handler (Phase 2's hook) sees it.
        a.link.inject(RemoteEnvelope(v: 1, kind: "mix.deckEvent", payload: Data("{}".utf8)), from: "B")
        await barrier(b, a)
        var extSeen = 0
        a.controller.registerHandler(kind: "mix.deckEvent") { _, from in if from == "B" { extSeen += 1 } }
        a.link.inject(RemoteEnvelope(v: 1, kind: "mix.deckEvent", payload: Data("{}".utf8)), from: "B")
        // A NEWER envelope version of a known kind: ignored.
        let newer = RemoteEnvelope(v: 99, kind: "command",
                                   payload: try JSONEncoder().encode(RemoteCommandMessage(command: .skipNext)))
        a.link.inject(newer, from: "B")
        // A command case this build doesn't know: dropped (no crash, no change).
        a.link.inject(RemoteEnvelope(v: 1, kind: "command",
                                     payload: Data(#"{"id":"x","command":{"teleport":{}}}"#.utf8)), from: "B")
        // Garbage payload for a known kind.
        a.link.inject(RemoteEnvelope(v: 1, kind: "state", payload: Data("nope".utf8)), from: "B")
        await barrier(b, a)
        XCTAssertEqual(extSeen, 1)
        XCTAssertTrue(a.controller.isActive)
        XCTAssertEqual(a.controller.model.revision, rev)

        // The envelope round-trips as the documented {v, kind, payload} shape.
        let env = try RemoteEnvelope.make(.command, RemoteCommandMessage(command: .seek(ms: 42)))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(env)) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Int, 1)
        XCTAssertEqual(obj?["kind"] as? String, "command")
        XCTAssertNotNil(obj?["payload"] as? String)
        XCTAssertEqual(env.decode(RemoteCommandMessage.self)?.command, .seek(ms: 42))
    }

    // MARK: - The authoritative model (pure)

    func testModelCommands() {
        var m = RemoteQueueModel()
        let ids = ["s1", "s2", "s3", "s4", "s5"]
        XCTAssertTrue(m.apply(.play(rows: ids.map { Self.row($0) }, startIndex: 1), now: 0))
        XCTAssertEqual(m.currentRow?.songId, "s2")
        let r0 = m.revision
        // Natural advance reported by TWO speakers moves the set once.
        XCTAssertTrue(m.apply(.advanced(fromRid: "r-s2"), now: 1_000))
        XCTAssertFalse(m.apply(.advanced(fromRid: "r-s2"), now: 1_001))
        XCTAssertEqual(m.currentRow?.songId, "s3")
        XCTAssertEqual(m.revision, r0 + 1)
        // Position runs while playing, freezes on pause.
        XCTAssertEqual(m.position(at: 6_000), 5_000)
        m.apply(.setPlaying(false), now: 6_000)
        XCTAssertEqual(m.position(at: 60_000), 5_000)
        // ⏮ past 3 s restarts; within 3 s goes back.
        m.apply(.skipPrevious, now: 60_000)
        XCTAssertEqual(m.currentRow?.songId, "s3")
        XCTAssertEqual(m.positionMs, 0)
        m.apply(.skipPrevious, now: 60_100)
        XCTAssertEqual(m.currentRow?.songId, "s2")
        // Remove / move / reorder only touch the upcoming tail.
        XCTAssertFalse(m.apply(.remove(rid: "r-s2"), now: 0), "the current row is never removed")
        m.apply(.move(rid: "r-s5", toUpcomingOffset: 0), now: 0)
        XCTAssertEqual(m.upcoming.map(\.songId), ["s5", "s3", "s4"])
        m.apply(.reorder(rids: ["r-s4", "r-s5"]), now: 0)
        XCTAssertEqual(m.upcoming.map(\.songId), ["s4", "s3", "s5"], "unlisted rows keep their slot")
        // Shuffle is reversible to the canonical order, keeping rows added while shuffled.
        m.apply(.setShuffle(true), now: 0, shuffler: { $0.reversed() })
        XCTAssertEqual(m.upcoming.map(\.songId), ["s5", "s3", "s4"])
        m.apply(.append(rows: [Self.row("s1", rid: "r-again")]), now: 0)
        m.apply(.setShuffle(false), now: 0)
        XCTAssertEqual(m.upcoming.map(\.songId), ["s4", "s3", "s5", "s1"])
        // End of set: stops on the last row; repeat-all wraps.
        m.apply(.jumpTo(rid: "r-again"), now: 0)
        m.apply(.skipNext, now: 0)
        XCTAssertFalse(m.isPlaying)
        m.apply(.setRepeat(.all), now: 0)
        m.apply(.playPause, now: 0)
        m.apply(.skipNext, now: 0)
        XCTAssertEqual(m.index, 0)
        // The broadcast window is bounded and index-relative.
        var big = RemoteQueueModel()
        big.apply(.play(rows: (0..<1_000).map { Self.row("s1", rid: "r\($0)") }, startIndex: 500), now: 0)
        let s = big.state(hostId: "H", mode: .listenTogether, sessionId: "x", now: 0)
        XCTAssertEqual(s.windowStart, 500 - RemoteQueueModel.windowBehind)
        XCTAssertEqual(s.snapshot.queue.count, RemoteQueueModel.windowBehind + 1 + RemoteQueueModel.windowAhead)
        XCTAssertEqual(s.currentRow?.rid, "r500")
        XCTAssertEqual(s.totalCount, 1_000)
    }

    // MARK: - Showcase seed

    func testShowcaseSeedIsABackseatControllerWithAFakeCar() async {
        setenv("PDJ_SEED_REMOTE", "showcase", 1)
        defer { unsetenv("PDJ_SEED_REMOTE") }
        let c = RemoteSessionController(target: nil, resolver: Self.resolver(), deviceName: "Me", platform: "t")
        c.seedShowcaseIfRequested()
        XCTAssertTrue(c.isHost)
        XCTAssertEqual(c.mode, .backseat)
        XCTAssertEqual(c.localRole, .controller)
        XCTAssertEqual(c.state?.currentRow?.title, "Golden Hour")
        await RemoteTestSupport.waitUntil { c.peers.contains { $0.name == "Car" && $0.role == .speaker } }
        c.leave()
    }
}
