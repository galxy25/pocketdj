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

        // 2 s off: a single tick's reading is not enough (it must PERSIST — a one-tick blip of a
        // coarse clock is not drift)…
        b.target.userSeek(b.target.positionMs + 1_400)
        b.controller.tick()
        XCTAssertEqual(seeks(), 0)
        // …the second consecutive reading corrects it with ONE seek onto the shared position.
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

    // MARK: - Review fixes (phase 1 + the session layer of phase 2)

    private func sentKinds(_ d: Device) -> [String] { d.link.sent.map(\.0.kind) }

    private func sentCommands(_ d: Device) -> [RemoteCommand] {
        d.link.sent.filter { $0.0.kind == RemoteMessageKind.command.rawValue }
            .compactMap { $0.0.decode(RemoteCommandMessage.self)?.command }
    }

    /// #2 — the controller attached while its own player had a start IN FLIGHT: a plain pause
    /// was a no-op (nothing sounded yet) and the start then landed audibly. Silence must cancel
    /// the pending start and be re-asserted on every tick.
    func testBackseatControllerStaysSilentWhenAPendingStartSettles() async {
        let a = device("A"), b = device("B")
        a.target.userPlay([Self.item("s1"), Self.item("s2")])
        a.target.beginPendingStart()                  // ⏭ / a fresh set still resolving
        attachHost(a, mode: .backseat, seed: nil)
        attachGuest(b, mode: .backseat)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        a.target.settlePendingStart()                 // the start lands
        XCTAssertFalse(a.target.isPlaying, "a cancelled start never sounds")
        // Something else starts audio on the controller later (a stray start): the tick silences it.
        a.target.userSetPlaying(true)
        a.controller.tick()
        XCTAssertFalse(a.target.isPlaying)
        XCTAssertTrue(b.target.isPlaying, "the car keeps playing")
    }

    /// #2 — every local transport on a controller is forwarded to the session (and refused
    /// locally); a speaker's are not intercepted.
    func testControllerGateForwardsLocalTransportToTheSession() async {
        let a = device("A"), b = device("B")
        attachHost(a, mode: .backseat, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b, mode: .backseat)
        await RemoteTestSupport.waitUntil { b.currentId == "s1" }
        XCTAssertTrue(a.controller.interceptLocalTransport(.skipNext))
        await RemoteTestSupport.waitUntil { b.currentId == "s2" }
        XCTAssertTrue(a.controller.interceptLocalTransport(.setPlaying(false)))
        await RemoteTestSupport.waitUntil { !b.target.isPlaying }
        // Browse ▶ on the controller → the session's new set (the car plays it).
        XCTAssertTrue(a.controller.interceptLocalTransport(.play([Self.item("s4"), Self.item("s5")], startIndex: 1)))
        await RemoteTestSupport.waitUntil { b.currentId == "s5" }
        XCTAssertTrue(a.controller.interceptLocalTransport(.localStart), "internal restarts are refused")
        XCTAssertFalse(b.controller.interceptLocalTransport(.skipNext), "a speaker plays locally as usual")
        XCTAssertFalse(a.target.isPlaying)
    }

    /// #2 / #6 / #9 — the SetlistPlayer seams: the controller gate refuses every local start,
    /// `applyingRemote` bypasses it and tags the transition `.remote`, listener ▶/⏸ intent is
    /// recorded (never during an apply), and `startPaused` parks the run HELD at the position.
    func testSetlistPlayerGateCauseTaggingAndStartPaused() {
        setenv("PDJ_HOLD_PLAYBACK", "1", 1)
        defer { unsetenv("PDJ_HOLD_PLAYBACK") }
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-rsgate-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let items = ["s1", "s2", "s3"].map(Self.item)

        seq.play(items)
        XCTAssertEqual(seq.lastTransitionCause, .user)
        let userSeq = seq.lastUserTransitionSeq
        seq.applyingRemote { seq.skipNext() }
        XCTAssertEqual(seq.lastTransitionCause, .remote, "a session apply is never the listener")
        XCTAssertEqual(seq.lastUserTransitionSeq, userSeq)
        XCTAssertEqual(seq.index, 1)

        var forwarded: [SetlistPlayer.RemoteRedirect] = []
        seq.remoteControllerGate = { forwarded.append($0); return true }
        seq.skipNext()
        seq.skipPrevious()
        seq.play(["s4"].map(Self.item))
        seq.jumpToUpcoming(uid: seq.queue[2].uid)
        XCTAssertTrue(seq.startCurrent(by: "test"), "a refused start reports handled (nothing else may start it)")
        XCTAssertTrue(player.onListenerTransport?(.toggle) ?? false, "lock-screen ⏯ is forwarded too")
        XCTAssertTrue(seq.routeListenerPlayPause())
        XCTAssertEqual(seq.index, 1, "nothing moved locally")
        XCTAssertEqual(seq.queue.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(forwarded.count, 7)
        XCTAssertEqual(forwarded.first, .skipNext)
        XCTAssertEqual(forwarded[2], .play(["s4"].map(Self.item), startIndex: 0))
        XCTAssertEqual(forwarded[3], .jump(seq.queue[2].uid))
        XCTAssertEqual(forwarded[4], .localStart)
        // …but a session apply passes the gate.
        seq.applyingRemote { seq.skipNext() }
        XCTAssertEqual(seq.index, 2)
        seq.remoteControllerGate = nil

        // Listener intent: recorded from the panel's ▶/⏸, never from an apply.
        let intent = seq.userPlayIntentSeq
        XCTAssertFalse(seq.routeListenerPlayPause(.setPlaying(false)))
        XCTAssertEqual(seq.userPlayIntentSeq, intent + 1)
        XCTAssertFalse(seq.lastUserPlayIntent)
        seq.applyingRemote { seq.noteListenerPlayIntent(true) }
        XCTAssertEqual(seq.userPlayIntentSeq, intent + 1)

        // Start paused: loaded HELD at the position, nothing audible.
        seq.applyingRemote { seq.play(items, startIndex: 1, startPaused: true, startAtMs: 42_000) }
        XCTAssertTrue(seq.isHeldForResume)
        XCTAssertFalse(seq.isAudiblyPlaying)
        XCTAssertEqual(seq.index, 1)
        XCTAssertEqual(seq.songPositionMs, 42_000)
        seq.setHeldResumePosition(ms: 50_000)
        XCTAssertEqual(seq.songPositionMs, 50_000)
        // A controller's silence parks the deck held too (idempotent).
        seq.applyingRemote { seq.play(items) }
        seq.holdSilentForRemote()
        XCTAssertTrue(seq.isHeldForResume)
        XCTAssertFalse(seq.isStartInFlight, "the pending start is cancelled")
        seq.holdSilentForRemote()
        seq.stop()
    }

    /// #3 — no full-window re-send every 2 s: the host beats a small heartbeat; a receiver that
    /// sees a NEWER revision on a beat asks for the full state.
    func testHeartbeatIsSmallAndAMissedRevisionIsRequested() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        let states = { a.link.sent.filter { $0.0.kind == RemoteMessageKind.state.rawValue }.count }
        let before = states()
        for _ in 0..<5 { advance(2_000); a.controller.tick() }
        XCTAssertEqual(states(), before, "an unchanged session re-sends no full state")
        let beats = a.link.sent.filter { $0.0.kind == RemoteMessageKind.heartbeat.rawValue }
        XCTAssertEqual(beats.count, 5)
        guard let beat = beats.first else { return XCTFail("no heartbeat sent") }
        XCTAssertLessThan(RemoteSessionController.encodedSize(beat.0), 600)
        await barrier(a, b)
        XCTAssertFalse(sentKinds(b).contains(RemoteMessageKind.stateRequest.rawValue))

        // A beat announcing a revision B never saw → B requests, A answers with the full state.
        var m = a.controller.model
        m.revision += 5
        let hb = RemoteHeartbeat(revision: m.revision, hostId: "A", currentRid: "r-s1", positionMs: 0,
                                 isPlaying: true, anchorSharedTime: clock.t, sessionActive: true)
        b.link.inject(try! RemoteEnvelope.make(.heartbeat, hb), from: "A")
        await RemoteTestSupport.waitUntil { sentKinds(b).contains(RemoteMessageKind.stateRequest.rawValue) }
        await RemoteTestSupport.waitUntil { states() == before + 1 }
    }

    /// #3 — the encoded state never exceeds the messenger budget: the window shrinks to fit.
    func testEncodedStateIsCappedByTrimmingTheWindow() async {
        let a = device("A"), b = device("B")
        let long = String(repeating: "x", count: 600)
        var m = RemoteQueueModel()
        m.rows = (0..<300).map { i in
            RemoteRow(rid: "r\(i)", row: .init(songId: "s1", title: long, artist: long, lengthMs: 200_000, repeatCount: nil))
        }
        m.index = 5
        m.isPlaying = true
        m.anchor = clock.t
        m.revision = 1
        attachHost(a, seed: m)
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.controller.state != nil }
        let sentStates = a.link.sent.filter { $0.0.kind == RemoteMessageKind.state.rawValue }
        XCTAssertFalse(sentStates.isEmpty)
        for (env, _) in sentStates {
            XCTAssertLessThanOrEqual(RemoteSessionController.encodedSize(env), RemoteSessionController.maxStateBytes)
        }
        let got = b.controller.state!
        XCTAssertEqual(got.currentRow?.rid, "r5", "the current row always rides")
        XCTAssertLessThan(got.rows.count, 221)
        XCTAssertEqual(a.controller.state?.rows.count, 206, "the host's own view keeps the full window")
    }

    /// #4 / phase-2 #13 — a joiner that self-elected (an EMPTY host with the lower id) must not
    /// wipe the real host: the active session wins the yield, the empty one follows it.
    func testEmptySelfElectedHostNeverWipesTheRealHost() async {
        let real = device("H"), empty = device("E")
        attachHost(real, seed: seed(["s1", "s2", "s3"]))
        empty.controller.attach(empty.link, mode: .listenTogether, asHost: true, seed: RemoteQueueModel(), autoTick: false)
        await RemoteTestSupport.waitUntil { empty.controller.hostId == "H" && empty.currentId == "s1" }
        XCTAssertTrue(real.controller.isHost, "the real host never yields to an empty one")
        XCTAssertEqual(real.controller.model.rows.map(\.songId), ["s1", "s2", "s3"])
        XCTAssertFalse(empty.controller.isHost)
        // The yield rule is symmetric: exactly one side yields.
        let x = (active: true, revision: 3, id: "H"), y = (active: false, revision: 9, id: "E")
        XCTAssertNotEqual(RemoteSessionController.shouldYield(theirs: x, mine: y),
                          RemoteSessionController.shouldYield(theirs: y, mine: x))
        XCTAssertTrue(RemoteSessionController.shouldYield(theirs: (true, 4, "Z"), mine: (true, 3, "A")))
        XCTAssertTrue(RemoteSessionController.shouldYield(theirs: (true, 3, "A"), mine: (true, 3, "Z")))
    }

    /// #4 — no state after the election timeout while OTHER peers are present: re-hello, never
    /// self-elect (the host may just be slow). Alone, the device hosts.
    func testNoSelfElectionWhileOthersArePresent() async {
        let b = device("B")
        _ = hub.join(id: "A")                         // a peer that hasn't spoken yet
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.controller.roster.count == 2 }
        let hellos = { b.link.sent.filter { $0.0.kind == RemoteMessageKind.hello.rawValue }.count }
        let h0 = hellos()
        advance(RemoteSessionController.electionTimeoutMs + 100)
        b.controller.tick()
        XCTAssertFalse(b.controller.isHost)
        XCTAssertGreaterThan(hellos(), h0, "re-hello so a live host answers with its state")

        let soloHub = LoopbackHub()
        let solo = RemoteSessionController(target: InMemoryRemoteTarget(now: { [clock] in clock.t }),
                                           resolver: Self.resolver(), deviceName: "C", platform: "t",
                                           clock: SharedClock(localNow: { [clock] in clock.t }))
        solo.attach(soloHub.join(id: "C"), mode: .listenTogether, asHost: false, autoTick: false)
        await RemoteTestSupport.waitUntil { solo.roster == ["C"] }
        advance(RemoteSessionController.electionTimeoutMs + 100)
        solo.tick()
        XCTAssertTrue(solo.isHost, "alone: nobody to wait for")
        solo.leave()
        withExtendedLifetime(soloHub) {}
    }

    /// #5 — the expensive fuzzy matcher runs only for the current row + the next few, never for
    /// the whole 200-row window on the main actor.
    func testFuzzyResolutionIsBoundedToTheRowsAboutToPlay() async {
        var fuzzyCalls = 0
        let clock = self.clock
        let now: () -> Double = { clock.t }
        let target = InMemoryRemoteTarget(now: now)
        var r = RemoteSongResolver(catalogItem: { _ in nil })
        r.fuzzyTitleArtist = { t, a in fuzzyCalls += 1; return SetlistPlayer.Item(id: "local-\(t)", title: t, artist: a, lengthMs: 200_000) }
        let b = RemoteSessionController(target: target, resolver: r, deviceName: "B", platform: "t",
                                        clock: SharedClock(localNow: now))
        let a = device("A")
        var m = RemoteQueueModel()
        m.rows = (0..<50).map { RemoteRow(rid: "r\($0)", row: .init(songId: "theirs\($0)", title: "T\($0)", artist: "A",
                                                                    lengthMs: 200_000, repeatCount: nil)) }
        m.isPlaying = true; m.anchor = clock.t; m.revision = 1
        attachHost(a, seed: m)
        b.attach(hub.join(id: "B"), mode: .listenTogether, asHost: false, autoTick: false)
        await RemoteTestSupport.waitUntil { target.isRunning }
        XCTAssertEqual(fuzzyCalls, RemoteSessionController.fuzzyLookahead + 1)
        XCTAssertEqual(target.queue.count, RemoteSessionController.fuzzyLookahead + 1)
        XCTAssertTrue(b.localUnavailable.isEmpty, "undecided rows are not reported unavailable")
        for _ in 0..<3 { b.tick() }
        XCTAssertEqual(fuzzyCalls, RemoteSessionController.fuzzyLookahead + 1, "decided rows are cached")
        advance(2_500)
        a.controller.send(.skipNext)
        await RemoteTestSupport.waitUntil { target.currentItem?.id == "local-T1" }
        XCTAssertEqual(fuzzyCalls, RemoteSessionController.fuzzyLookahead + 2, "one new row came into range")
        b.leave()
    }

    /// #6 — the speaker's own automatic events never drive the session: a stall hop / dead-source
    /// skip marks the row unplayable HERE (no command), and a local stop never pauses everyone.
    func testAutomaticLocalEventsAreNotSessionCommands() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2", "s3", "s4"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.currentId == "s1" }
        b.controller.tick()
        b.target.simulateAutoAdvance(.stallHop)
        b.controller.tick()
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
        XCTAssertEqual(a.controller.model.currentRow?.songId, "s1", "the set didn't move for everyone")
        XCTAssertTrue(b.controller.localUnavailable.contains("r-s1"), "s1 is unplayable here now")
        XCTAssertEqual(b.currentId, "s2", "mirrors the session around the row it can't play")
        // The end of the locally-available rows stops the local set: nothing is sent.
        b.target.simulateAutoAdvance(.autoSkip)    // s2 dead too
        b.target.simulateAutoAdvance(.autoSkip)
        b.target.simulateAutoAdvance(.autoSkip)    // past the end → stopped
        b.controller.tick()
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
        XCTAssertTrue(a.controller.model.isPlaying, "a local stop never pauses everyone")
    }

    /// #6 / #7 — a natural end: near the session's end of that row it IS the session's advance;
    /// a shorter local copy ending early (or the stand-in for an unavailable row) holds SILENT —
    /// never re-mirrored in a loop — until the session moves.
    func testNaturalEndAdvancesOnlyNearTheSessionEndElseHoldsSilent() async {
        let a = device("A"), b = device("B", known: ["s1", "s3", "s4"])
        attachHost(a, seed: seed(["s1", "s2", "s3", "s4"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.currentId == "s1" }
        // s1's local copy ends at 2:00 of its 3:20 session row: hold, don't advance everyone.
        advance(120_000)
        b.controller.tick()
        b.target.simulateAutoAdvance(.naturalEnd)
        b.controller.tick()
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
        XCTAssertEqual(a.controller.model.currentRow?.songId, "s1")
        XCTAssertFalse(b.target.isPlaying, "waits silently")
        let plays = b.target.log.filter { $0.hasPrefix("play") }.count
        for _ in 0..<4 { advance(500); b.controller.tick() }
        XCTAssertEqual(b.target.log.filter { $0.hasPrefix("play") }.count, plays, "no re-mirror loop")
        // The session moves on (to s2, unavailable here) → B plays s3 in its place.
        a.controller.send(.skipNext)
        await RemoteTestSupport.waitUntil { b.currentId == "s3" && b.target.isPlaying }
        // s3 (the stand-in) ends while the session is still on s2: hold, no loop back onto s3.
        advance(200_000)
        b.controller.tick()
        b.target.simulateAutoAdvance(.naturalEnd)
        for _ in 0..<4 { advance(500); b.controller.tick() }
        XCTAssertFalse(b.target.isPlaying)
        XCTAssertEqual(b.currentId, "s4")
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
        // At the session row's real end, a natural end IS the advance.
        a.controller.send(.jumpTo(rid: "r-s4"))
        await RemoteTestSupport.waitUntil { b.currentId == "s4" && b.target.isPlaying }
        b.controller.tick()
        advance(199_000)
        b.controller.tick()
        b.target.simulateAutoAdvance(.naturalEnd)
        b.controller.tick()
        await RemoteTestSupport.waitUntil { !a.controller.model.isPlaying }   // s4 was the last row
        XCTAssertEqual(sentCommands(b), [.advanced(fromRid: "r-s4")])
    }

    /// #8 — moving onto an upcoming row mid-song CUES the start at the session position (a
    /// seek after the jump landed on the OLD track's backend while the new one resolved).
    func testJumpOntoAnUpcomingRowIsCuedAtTheSessionPosition() async throws {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.currentId == "s1" }
        var m = a.controller.model
        m.apply(.jumpTo(rid: "r-s2"), now: clock.t)
        m.apply(.seek(ms: 30_000), now: clock.t)
        let s = m.state(hostId: "A", mode: .listenTogether, sessionId: "x", now: clock.t)
        b.link.inject(try RemoteEnvelope.make(.state, s), from: "A")
        await RemoteTestSupport.waitUntil { b.currentId == "s2" }
        XCTAssertEqual(b.target.log, ["play", "jump@30000"])
        XCTAssertEqual(b.target.positionMs, 30_000)
    }

    /// #9 — joining a PAUSED session loads paused: nothing sounds, not even a blip.
    func testJoiningAPausedSessionLoadsPaused() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2"], playing: false, positionMs: 30_000))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        XCTAssertEqual(b.target.log, ["play(paused)"])
        XCTAssertFalse(b.target.isPlaying)
        XCTAssertEqual(b.target.positionMs, 30_000)
        // ▶ on the host resumes it at the session position.
        advance(1_000)
        a.controller.send(.playPause)
        await RemoteTestSupport.waitUntil { b.target.isPlaying }
    }

    /// #10 — a real user action right after a reconcile move is forwarded (no guard window
    /// swallows it), and the reconciler never reverts it.
    func testUserActionRightAfterAMoveIsForwardedNotReverted() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2", "s3"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.currentId == "s1" }
        a.controller.send(.skipNext)                  // a reconcile move on B…
        await RemoteTestSupport.waitUntil { b.currentId == "s2" }
        b.target.userSkipNext()                       // …and B's user ⏭ in the same instant
        b.controller.tick()
        await RemoteTestSupport.waitUntil { a.controller.model.currentRow?.songId == "s3" }
        XCTAssertEqual(b.currentId, "s3")
        // A listener ⏸ (recorded intent) pauses the session; a stall / blip never would.
        b.target.userSetPlaying(false)
        b.controller.tick()
        await RemoteTestSupport.waitUntil { !a.controller.model.isPlaying }
    }

    /// #11 — no drift correction while buffering, and Apple Music's coarse clock gets the wider
    /// threshold.
    func testDriftIgnoresBufferingAndWidensForCoarseClocks() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2"], positionMs: 30_000))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        b.controller.tick()
        await RemoteTestSupport.waitUntil { b.controller.clock.isSynced }
        let seeks = { b.target.log.filter { $0 == "seek" }.count }
        b.target.hasCoarsePosition = true
        b.target.userSeek(b.target.positionMs + 1_500)
        for _ in 0..<4 { b.controller.tick() }
        XCTAssertEqual(seeks(), 0, "1.5 s on Apple Music's coarse clock is jitter")
        b.target.userSeek(b.target.positionMs + 1_000)
        b.controller.tick()
        b.controller.tick()
        XCTAssertEqual(seeks(), 1, "2.5 s, persisting: corrected")
        b.target.isTransitioning = true
        b.target.userSeek(b.target.positionMs + 2_500)
        for _ in 0..<4 { b.controller.tick() }
        XCTAssertEqual(seeks(), 1, "buffering: never chase the position")
    }

    /// #12 — starting a session never truncates the host's own long queue, and the model refills
    /// from it as the set advances.
    func testHostSessionKeepsAndRefillsFromTheLocalQueue() async {
        let ids = (0..<300).map { i in "x\(i)" }
        let a = device("A", known: Set(ids)), b = device("B", known: Set(ids))
        a.target.userPlay(ids.map { Self.item($0) })
        attachHost(a, seed: nil)
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        XCTAssertEqual(a.controller.model.rows.count, 201)
        for _ in 0..<3 { advance(500); a.controller.tick() }
        XCTAssertEqual(a.target.queueCount, 300, "the host's local set is never truncated")
        XCTAssertFalse(a.target.log.contains("replaceUpcoming"))
        // Jump deep into the window: the tail runs low → refilled from the local set.
        a.controller.send(.jumpTo(rid: a.controller.model.rows[150].rid))
        a.controller.tick()
        XCTAssertEqual(a.controller.model.rows.count, 300)
        XCTAssertEqual(a.controller.model.rows.last?.songId, "x299")
        XCTAssertEqual(a.target.queueCount, 300)
        await RemoteTestSupport.waitUntil { b.currentId == "x150" && b.queueIds.last == "x299" }
    }

    /// #15 — a joiner's unrelated local set (playing before it joined) never takes over an empty
    /// session; a set its user starts AFTER joining does.
    func testJoinersPreexistingSetNeverTakesOverAnEmptySession() async {
        let a = device("A"), b = device("B")
        b.target.userPlay([Self.item("s4"), Self.item("s5")])
        attachHost(a, seed: RemoteQueueModel())
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.controller.state != nil }
        for _ in 0..<4 { advance(500); b.controller.tick() }
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0)
        XCTAssertTrue(a.controller.model.rows.isEmpty)
        b.target.userPlay([Self.item("s1"), Self.item("s2")])
        b.controller.tick()
        await RemoteTestSupport.waitUntil { a.controller.model.rows.map(\.songId) == ["s1", "s2"] }
    }

    /// #17 — the host's shuffle is mirrored to speakers (flag + order).
    func testShuffleIsMirroredToSpeakers() async {
        let a = device("A"), b = device("B")
        attachHost(a, seed: seed(["s1", "s2", "s3", "s4"]))
        attachGuest(b)
        await RemoteTestSupport.waitUntil { b.target.isRunning }
        a.controller.send(.setShuffle(true))
        await RemoteTestSupport.waitUntil { b.target.shuffleEnabled }
        await RemoteTestSupport.waitUntil {
            Array(b.queueIds.dropFirst()) == a.controller.model.upcoming.map(\.songId)
        }
        advance(500); b.controller.tick()
        await barrier(b, a)
        XCTAssertEqual(commandsSent(b), 0, "mirroring the flag is not a local shuffle command")
    }

    /// #16 — the serial send queue: strict order even when a send suspends, per-participant
    /// sends buffered until the participant is resolvable, reliable failures retried.
    func testSendQueueIsSerialBuffersJoinersAndRetries() async {
        var known: Set<String> = ["P"]
        var delivered: [String] = []
        var failNext = 1
        var gate = true
        var slowStarted = false
        let q = RemoteSendQueue<String>(resolve: { to in
            switch to {
            case .all: return "*"
            case .participant(let id): return known.contains(id) ? id : nil
            }
        }, retryDelays: [0], send: { env, to, _ in
            if String(data: env.payload, encoding: .utf8) == "slow" {
                slowStarted = true
                while gate { await Task.yield() }
            }
            if String(data: env.payload, encoding: .utf8) == "flaky", failNext > 0 {
                failNext -= 1
                throw URLError(.timedOut)
            }
            delivered.append("\(to):" + (String(data: env.payload, encoding: .utf8) ?? ""))
        })
        func env(_ s: String) -> RemoteEnvelope { RemoteEnvelope(v: 1, kind: "t", payload: Data(s.utf8)) }
        q.enqueue(env("slow"), to: .all, reliable: true)
        q.enqueue(env("second"), to: .all, reliable: true)
        q.enqueue(env("toJoiner"), to: .participant("J"), reliable: true)
        q.enqueue(env("flaky"), to: .participant("P"), reliable: true)
        await RemoteTestSupport.waitUntil { slowStarted }
        XCTAssertTrue(delivered.isEmpty, "nothing overtakes the suspended first send")
        gate = false
        await RemoteTestSupport.waitUntil { delivered.count == 3 }
        XCTAssertEqual(delivered, ["*:slow", "*:second", "P:flaky"], "order kept; the flaky send retried")
        XCTAssertEqual(q.failureCount, 1)
        XCTAssertEqual(q.buffered["J"]?.count, 1)
        known.insert("J")
        q.participantsChanged()
        await RemoteTestSupport.waitUntil { delivered.count == 4 }
        XCTAssertEqual(delivered.last, "J:toJoiner")
        q.finish()
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
