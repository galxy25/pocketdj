import XCTest
import AVFoundation
@testable import PocketDJ

/// Multiplayer Mix (SharePlay Phase 2) — `MixSync` over a LoopbackTransport hub of fake devices.
/// Every device is a real `RemoteSessionController` + `MixSync` driving a `FakeMixEngine` (no
/// audio), on one manual clock with per-device skew, ticked by hand; every wait is on the asserted
/// condition (negative assertions sit behind a FIFO barrier). A few tests drive the REAL
/// `MixEngine` for the engine seams (remote-apply guard, scheduled start, Auto-DJ block).
@MainActor
final class MixSyncTests: XCTestCase {

    // MARK: - Fake engine

    @MainActor final class FakeMixEngine: MixSyncEngine {
        struct DeckState {
            var songId: String?
            var isPlaying = false
            /// Position `posMs` at local time `at` (a scheduled start sets `at` in the future).
            var posMs = 0
            var at: Double = 0
            var durationMs = 200_000
            var rate = 1.0
            var ready = true
            var controls: [String: MixSyncEvent] = [:]
        }

        var gestureTap: ((MixEngine.Gesture) -> Void)?
        let now: () -> Double
        var decks: [MixEngine.Deck: DeckState] = [.a: DeckState(), .b: DeckState()]
        var crossfader = 0.5
        var autoDJBlocked: String?
        /// Every remote apply, in order ("load:A:s1", "play:A:10300@…", "ctl:volume:A=0.3"…).
        var applied: [String] = []
        var plays: [(deck: MixEngine.Deck, fromMs: Int, atLocalMs: Double)] = []
        /// LOCAL gestures this device's user made (what a session log would record).
        var gestures: [MixEngine.Gesture] = []
        /// Whether the next user load reports ready (a streaming deck that is still buffering = false).
        var loadsReady = true

        init(now: @escaping () -> Double) { self.now = now }

        func playhead(_ d: MixEngine.Deck) -> Int {
            let s = decks[d]!
            guard s.isPlaying else { return s.posMs }
            return s.posMs + Int(((now() - s.at) * s.rate).rounded())
        }

        // MixSyncEngine
        func syncStatus(_ d: MixEngine.Deck) -> MixSyncDeckStatus {
            let s = decks[d]!
            return MixSyncDeckStatus(songId: s.songId, isPlaying: s.isPlaying, playheadMs: playhead(d),
                                     durationMs: s.songId == nil ? 0 : s.durationMs, rate: s.rate,
                                     ready: s.songId != nil && s.ready)
        }
        func syncLoad(_ item: MixLoadable, on d: MixEngine.Deck) {
            decks[d] = DeckState(songId: item.songId, at: now(), controls: decks[d]!.controls)
            applied.append("load:\(d.rawValue):\(item.songId)")
        }
        func syncEject(_ d: MixEngine.Deck) {
            decks[d] = DeckState()
            applied.append("eject:\(d.rawValue)")
        }
        func syncPlay(_ d: MixEngine.Deck, fromMs: Int, atLocalMs: Double) {
            decks[d]!.isPlaying = true
            decks[d]!.posMs = fromMs
            decks[d]!.at = atLocalMs
            plays.append((d, fromMs, atLocalMs))
            applied.append("play:\(d.rawValue):\(fromMs)")
        }
        func syncPause(_ d: MixEngine.Deck, atMs: Int) {
            decks[d]!.isPlaying = false
            decks[d]!.posMs = atMs
            decks[d]!.at = now()
            applied.append("pause:\(d.rawValue):\(atMs)")
        }
        func syncApplyControl(_ e: MixSyncEvent) {
            if e.kind == MixSyncKind.crossfader {
                crossfader = e.value ?? crossfader
                applied.append("ctl:crossfader=\(e.value ?? -1)")
                return
            }
            guard let d = e.engineDeck else { return }
            if e.kind == MixSyncKind.tempo, let v = e.value { rebase(d); decks[d]!.rate = v }
            decks[d]!.controls[e.controlKey] = e
            applied.append("ctl:\(e.kind):\(d.rawValue)=\(e.value ?? -1)")
        }
        func syncSeedEvents(_ deck: MixEngine.Deck) -> [MixSyncEvent] { [] }
        var syncCrossfader: Double { crossfader }
        func setAutoDJBlocked(_ reason: String?) { autoDJBlocked = reason }

        private func rebase(_ d: MixEngine.Deck) {
            decks[d]!.posMs = playhead(d)
            decks[d]!.at = now()
        }

        // The user's hands (local gestures → the tap, like the real engine's `rec`).
        func userLoad(_ d: MixEngine.Deck, _ id: String) {
            decks[d] = DeckState(songId: id, at: now(), ready: loadsReady, controls: decks[d]!.controls)
            tap(MixEngine.Gesture(kind: MixEngine.Gesture.load, deck: d, posMs: 0,
                                  track: MixEngine.LoadedTrack(songId: id, title: "T-\(id)", artist: "A",
                                                               bpm: 120, camelot: nil, key: nil, albumId: nil),
                                  lengthMs: 200_000))
        }
        func userPlay(_ d: MixEngine.Deck, fromMs: Int? = nil) {
            if let fromMs { decks[d]!.posMs = fromMs }
            decks[d]!.isPlaying = true
            decks[d]!.at = now()
            tap(MixEngine.Gesture(kind: "play", deck: d, posMs: playhead(d)))
        }
        func userPause(_ d: MixEngine.Deck) {
            rebase(d)
            decks[d]!.isPlaying = false
            tap(MixEngine.Gesture(kind: "pause", deck: d, posMs: playhead(d)))
        }
        func userSet(_ kind: String, _ d: MixEngine.Deck, _ v: Double) {
            let g = MixEngine.Gesture(kind: kind, deck: d, value: v)
            decks[d]!.controls[MixSyncEvent(kind: kind, deck: d.rawValue).controlKey] =
                MixSyncEvent(kind: kind, deck: d.rawValue, value: v)
            tap(g)
        }
        func userCrossfader(_ v: Double) {
            crossfader = v
            tap(MixEngine.Gesture(kind: "crossfader", deck: nil, value: v))
        }
        func value(_ kind: String, _ d: MixEngine.Deck) -> Double? {
            decks[d]!.controls[MixSyncEvent(kind: kind, deck: d.rawValue).controlKey]?.value
        }
        private func tap(_ g: MixEngine.Gesture) {
            gestures.append(g)
            gestureTap?(g)
        }
    }

    // MARK: - Fixtures

    private final class ManualClock { var t: Double = 8_000_000 }

    @MainActor private struct Device {
        let id: String
        let remote: RemoteSessionController
        let link: LoopbackTransport
        let engine: FakeMixEngine
        let sync: MixSync
        let skew: Double
    }

    private let clock = ManualClock()
    private let hub = LoopbackHub()

    private static func loadable(_ e: MixSyncEvent) -> MixLoadable? {
        guard let id = e.songId else { return nil }
        return MixLoadable(songId: id, title: e.title ?? id, artist: e.artist ?? "", bpm: 120,
                           camelot: nil, key: nil, albumId: nil, lengthMs: 200_000)
    }

    private func device(_ id: String, skew: Double = 0, unmixable: Set<String> = []) -> Device {
        let clock = self.clock
        let now: () -> Double = { clock.t + skew }
        let remote = RemoteSessionController(target: InMemoryRemoteTarget(now: now),
                                             resolver: RemoteSongResolver(catalogItem: { _ in nil }),
                                             deviceName: "Device \(id)", platform: "test",
                                             clock: SharedClock(localNow: now))
        let engine = FakeMixEngine(now: now)
        let sync = MixSync(remote: remote, engine: engine, resolve: { e in
            unmixable.contains(e.songId ?? "") ? nil : Self.loadable(e)
        }, autoTick: false)
        return Device(id: id, remote: remote, link: hub.join(id: id), engine: engine, sync: sync, skew: skew)
    }

    private func advance(_ ms: Double) { clock.t += ms }

    /// FIFO barrier: everything `from` sent `to` before this point has been processed by `to`.
    private func barrier(_ from: Device, _ to: Device) async {
        let token = UUID().uuidString
        var seen = false
        to.remote.registerHandler(kind: "test.barrier") { env, _ in
            if String(data: env.payload, encoding: .utf8) == token { seen = true }
        }
        from.remote.sendRaw(RemoteEnvelope(v: 1, kind: "test.barrier", payload: Data(token.utf8)),
                            to: .participant(to.id))
        await RemoteTestSupport.waitUntil { seen }
    }

    /// The guest's clock measured against the host: host time = guest time + (hostSkew − guestSkew).
    private func syncClock(_ guest: Device, to host: Device) {
        guest.remote.clock.ingest(SharedClock.Sample(offsetMs: host.skew - guest.skew, rttMs: 2))
    }

    private func attachHost(_ d: Device, mode: RemoteSessionMode = .listenTogether) {
        d.remote.attach(d.link, mode: mode, asHost: true, autoTick: false)
        d.sync.tick()
    }

    /// Join `d` as a guest of `host`: wait for the host's state, sync the clock, and fetch the
    /// mix snapshot.
    private func join(_ d: Device, host: Device, syncedClock: Bool = true) async {
        d.remote.attach(d.link, mode: .listenTogether, asHost: false, autoTick: false)
        await RemoteTestSupport.waitUntil { d.remote.hostId == host.id && d.remote.state != nil }
        if syncedClock { syncClock(d, to: host) }
        d.sync.tick()                                  // sees the host → requests a snapshot
        await barrier(d, host)
        await barrier(host, d)
    }

    private func envelope<T: Encodable>(_ kind: String, _ body: T) -> RemoteEnvelope {
        RemoteEnvelope(v: 1, kind: kind, payload: try! JSONEncoder().encode(body))
    }

    private func sent(_ d: Device, kind: String) -> [RemoteEnvelope] {
        d.link.sent.map(\.0).filter { $0.kind == kind }
    }

    /// A two-device mix: host "A" (Deck A) + guest "B" (Deck B, the first joiner).
    private func twoDeviceMix(guestSkew: Double = 0) async -> (Device, Device) {
        let a = device("A"), b = device("B", skew: guestSkew)
        attachHost(a)
        await join(b, host: a)
        a.sync.tick()
        a.sync.start()
        await RemoteTestSupport.waitUntil { b.sync.isActive && b.sync.owner(of: .b) == "B" }
        return (a, b)
    }

    // MARK: - Session start + ownership

    func testStartAssignsHostDeckAAndFirstJoinerDeckB() async {
        let (a, b) = await twoDeviceMix()
        XCTAssertTrue(a.sync.isActive)
        XCTAssertEqual(a.sync.owner(of: .a), "A")
        XCTAssertEqual(a.sync.owner(of: .b), "B")
        XCTAssertEqual(b.sync.owner(of: .a), "A")
        XCTAssertTrue(b.sync.canControl(.b))
        XCTAssertFalse(b.sync.canControl(.a), "another DJ's deck is read-only here")
        XCTAssertEqual(b.sync.ownerLabel(.a), "Device A")
        XCTAssertEqual(b.sync.ownerLabel(.b), "You")
    }

    func testAutoDJDisabledDuringSessionAndRestoredAfter() async {
        let (a, b) = await twoDeviceMix()
        XCTAssertEqual(a.engine.autoDJBlocked, MixSync.autoDJBlockedReason)
        XCTAssertEqual(b.engine.autoDJBlocked, MixSync.autoDJBlockedReason)
        a.sync.end()
        await RemoteTestSupport.waitUntil { !b.sync.isActive }
        XCTAssertNil(a.engine.autoDJBlocked)
        XCTAssertNil(b.engine.autoDJBlocked)
    }

    func testBackseatSessionCannotStartAMix() {
        let a = device("A")
        a.remote.attach(a.link, mode: .backseat, asHost: true, autoTick: false)
        a.sync.tick()
        XCTAssertFalse(a.sync.canStart)
        XCTAssertNotNil(a.sync.startBlockedReason)
        a.sync.start()
        XCTAssertFalse(a.sync.isActive)
    }

    func testOwnershipRejectionFromHostAndLocalNonOwnerGestureNotSent() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        await RemoteTestSupport.waitUntil { b.engine.decks[.a]?.songId == "s1" }

        // A hostile/stale proposal from B for Deck A (owned by A) is refused by the host.
        let before = a.sync.model
        let appliedBefore = a.engine.applied.count
        a.link.inject(envelope(MixWireKind.event,
                               MixSyncEventMessage(originSeq: 99, event: MixSyncEvent(kind: "volume", deck: "A", value: 0.1))),
                      from: "B")
        await RemoteTestSupport.waitUntil { !self.sent(a, kind: MixWireKind.reject).isEmpty }
        XCTAssertEqual(a.sync.model, before, "a refused proposal never reaches the authoritative model")
        XCTAssertEqual(a.engine.applied.count, appliedBefore)
        XCTAssertEqual(a.link.sent.last { $0.0.kind == MixWireKind.reject }?.1, .participant("B"))

        // B's OWN hands on Deck A: never proposed (no mix.event leaves B for it).
        let eventsBefore = sent(b, kind: MixWireKind.event).count
        b.engine.userSet("volume", .a, 0.2)
        XCTAssertEqual(sent(b, kind: MixWireKind.event).count, eventsBefore)

        // Claiming a taken deck is refused; once A releases it, B can claim it.
        await barrier(a, b)
        b.sync.statusMessage = nil
        b.sync.claim(.a)
        await RemoteTestSupport.waitUntil { b.sync.statusMessage != nil }
        XCTAssertEqual(b.sync.owner(of: .a), "A")
        a.sync.release(.a)
        await RemoteTestSupport.waitUntil { b.sync.owner(of: .a) == nil }
        b.sync.claim(.a)
        await RemoteTestSupport.waitUntil { a.sync.owner(of: .a) == "B" && b.sync.owner(of: .a) == "B" }
        XCTAssertEqual(b.sync.myDecks, [.a, .b])
    }

    // MARK: - Ordering + echo

    func testEventsApplyInHostSequenceOrderAndDuplicatesDrop() async {
        let (a, b) = await twoDeviceMix()
        await barrier(a, b)
        let n = b.sync.model.hostSeq + 1
        func ordered(_ seq: Int, _ v: Double) -> RemoteEnvelope {
            envelope(MixWireKind.event, MixSyncEventMessage(originSeq: seq, origin: "A", hostSeq: seq, epoch: "A",
                                                            event: MixSyncEvent(kind: "crossfader", deck: nil, value: v)))
        }
        b.link.inject(ordered(n + 1, 0.9), from: "A")   // arrives FIRST, ordered second
        await barrier(a, b)
        XCTAssertEqual(b.engine.crossfader, 0.5, "a sequence hole holds later events")
        b.link.inject(ordered(n, 0.1), from: "A")
        await RemoteTestSupport.waitUntil { b.engine.crossfader == 0.9 }
        XCTAssertEqual(b.engine.applied.suffix(2), ["ctl:crossfader=0.1", "ctl:crossfader=0.9"])
        XCTAssertEqual(b.sync.model.crossfader, 0.9)
        b.link.inject(ordered(n, 0.1), from: "A")        // duplicate
        await barrier(a, b)
        XCTAssertEqual(b.engine.crossfader, 0.9)
    }

    func testNoEchoAndRemoteAppliesAreNotRecordedAsLocalGestures() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        a.engine.userSet("volume", .a, 0.3)
        await RemoteTestSupport.waitUntil { b.engine.value("volume", .a) == 0.3 }
        XCTAssertEqual(b.engine.decks[.a]?.songId, "s1")
        XCTAssertTrue(b.engine.gestures.isEmpty, "remote applies never surface as this DJ's gestures")
        XCTAssertTrue(sent(b, kind: MixWireKind.event).isEmpty, "the guest echoes nothing back")
        // The host never re-applies its own gesture when it orders it.
        XCTAssertFalse(a.engine.applied.contains { $0.hasPrefix("ctl:volume") || $0.hasPrefix("load") })

        // The guest's own gesture: applied locally at once, echoed back by the host, NOT re-applied.
        b.engine.userLoad(.b, "s2")
        b.engine.userSet("volume", .b, 0.6)
        await RemoteTestSupport.waitUntil { a.engine.value("volume", .b) == 0.6 }
        await barrier(a, b)
        XCTAssertFalse(b.engine.applied.contains { $0.contains(":B") }, "own echoes are skipped")
    }

    func testConcurrentCrossfaderConvergesOnHostOrder() async {
        let (a, b) = await twoDeviceMix()
        // B drags, A drags while B's proposal is in flight: host order = A(0.2) then B(0.8).
        a.engine.userCrossfader(0.2)          // ordered immediately by the host
        b.engine.userCrossfader(0.8)          // proposal: arrives after, ordered after
        await barrier(b, a)
        await barrier(a, b)
        XCTAssertEqual(a.engine.crossfader, 0.8)
        XCTAssertEqual(b.engine.crossfader, 0.8, "B's in-flight 0.8 shadows A's earlier 0.2 — no jitter")
        XCTAssertEqual(a.sync.model.crossfader, 0.8)
        XCTAssertEqual(b.sync.model.crossfader, 0.8)
    }

    // MARK: - Timing

    func testAnchoredPlayConvertsSharedTimeWithClockOffset() async {
        let (a, b) = await twoDeviceMix(guestSkew: 4_000)    // B's clock reads 4 s ahead
        a.engine.userLoad(.a, "s1")
        let hostNow = clock.t
        a.engine.userPlay(.a, fromMs: 10_000)
        await RemoteTestSupport.waitUntil { !b.engine.plays.isEmpty }
        let p = b.engine.plays[0]
        XCTAssertEqual(p.deck, .a)
        // Host anchored the start 300 ms out on ITS clock; B's clock is +4 s.
        XCTAssertEqual(p.atLocalMs, hostNow + MixSync.startLeadMs + 4_000, accuracy: 0.001)
        XCTAssertEqual(p.fromMs, 10_000 + Int(MixSync.startLeadMs))
        // At the shared instant both decks read the same position.
        advance(MixSync.startLeadMs + 1_000)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a))
        XCTAssertTrue(a.engine.plays.isEmpty, "the owner is the reference — never rescheduled")
    }

    func testDriftCorrectionThresholdAndCooldown() async {
        let (a, b) = await twoDeviceMix(guestSkew: -2_500)
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }

        func beat() async {
            advance(MixSync.heartbeatMs)
            a.sync.tick()
            await barrier(a, b)
        }
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0, "in sync ⇒ no correction")

        b.engine.decks[.a]!.posMs += 30                      // under the 40 ms threshold
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0)

        b.engine.decks[.a]!.posMs += 70                      // now 100 ms off
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 1)
        XCTAssertEqual(b.engine.plays.count, 2)
        advance(MixSync.startLeadMs)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a), "re-seek lands on the owner's position")

        b.engine.decks[.a]!.posMs += 120                     // off again, inside the cooldown
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 1, "cooldown: no chasing")
        await beat()                                         // ≥ cooldown since the fix
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 2)
    }

    func testHeldPlayWaitsForOwnerReadyThenTimesOut() async {
        let (a, b) = await twoDeviceMix()
        b.engine.loadsReady = false                          // B's deck is still buffering
        b.engine.userLoad(.b, "s2")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s2" }
        b.engine.userPlay(.b, fromMs: 0)
        await barrier(b, a)
        XCTAssertTrue(a.engine.plays.isEmpty, "the host holds a start until the owner's deck is ready")

        b.engine.decks[.b]!.ready = true
        b.sync.tick()                                        // readiness report → the host releases
        await RemoteTestSupport.waitUntil { a.engine.plays.count == 1 }

        // Never ready: the hold times out and everyone else starts anyway.
        b.engine.userLoad(.b, "s3")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s3" }
        b.engine.userPlay(.b, fromMs: 0)
        await barrier(b, a)
        XCTAssertEqual(a.engine.plays.count, 1)
        advance(MixSync.readyTimeoutMs)
        a.sync.tick()
        XCTAssertEqual(a.engine.plays.count, 2)
    }

    // MARK: - Join / availability / hand-over

    func testJoinMidMixSnapshotConverges() async {
        let a = device("A")
        attachHost(a)
        a.sync.start()
        XCTAssertNil(a.sync.owner(of: .b), "no joiner yet")
        a.engine.userLoad(.a, "s1")
        a.engine.userSet("volume", .a, 0.7)
        a.engine.userCrossfader(0.2)
        a.engine.userPlay(.a, fromMs: 30_000)
        advance(5_000)

        let c = device("C", skew: 1_234)
        await join(c, host: a, syncedClock: false)
        await RemoteTestSupport.waitUntil { c.sync.isActive && c.engine.decks[.a]?.isPlaying == true }
        XCTAssertEqual(c.engine.decks[.a]?.songId, "s1")
        XCTAssertEqual(c.engine.value("volume", .a), 0.7)
        XCTAssertEqual(c.engine.crossfader, 0.2)
        XCTAssertEqual(c.engine.autoDJBlocked, MixSync.autoDJBlockedReason)
        // The first joiner gets Deck B.
        a.sync.tick()
        await RemoteTestSupport.waitUntil { c.sync.owner(of: .b) == "C" }

        // Joined unsynced (started from the anchor as-is); once its clock syncs the owner's
        // heartbeat pulls it onto the shared timeline.
        syncClock(c, to: a)
        advance(MixSync.heartbeatMs)
        a.sync.tick()
        await barrier(a, c)
        advance(MixSync.startLeadMs)
        XCTAssertEqual(c.engine.playhead(.a), a.engine.playhead(.a))
    }

    func testUnavailableSongStaysSilentAndIsReported() async {
        let a = device("A"), b = device("B", unmixable: ["s9"])
        attachHost(a)
        await join(b, host: a)
        a.sync.start()
        await RemoteTestSupport.waitUntil { b.sync.isActive }
        b.engine.userLoad(.a, "old")                         // stale local deck (not a gesture it owns)
        a.engine.userLoad(.a, "s9")
        await RemoteTestSupport.waitUntil { b.sync.unavailable[.a] != nil }
        XCTAssertEqual(b.sync.unavailable[.a], "T-s9")
        XCTAssertNil(b.engine.decks[.a]?.songId, "an unmixable song leaves the deck empty (silent) here")
        await RemoteTestSupport.waitUntil {
            a.sync.peerReadiness["B"]?["A"]?.status == .unavailable
        }
        XCTAssertEqual(a.sync.unavailableDevices(.a), ["Device B"])
        a.engine.userPlay(.a)
        await barrier(a, b)
        XCTAssertTrue(b.engine.plays.isEmpty, "nothing to start on a deck this device can't mix")
        XCTAssertEqual(b.sync.unavailableDevices(.a), ["this device"])
    }

    func testHostHandoverKeepsDeckOwnership() async {
        let a = device("A"), b = device("B", skew: 700), c = device("C", skew: -300)
        attachHost(a)
        await join(b, host: a)
        await join(c, host: a)
        a.sync.start()
        await RemoteTestSupport.waitUntil { c.sync.isActive && c.sync.owner(of: .b) == "B" }
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 50_000)
        b.engine.userLoad(.b, "s2")
        await RemoteTestSupport.waitUntil { c.engine.decks[.b]?.songId == "s2" && c.engine.decks[.a]?.isPlaying == true }
        b.sync.tick(); c.sync.tick()                         // remember the offsets under host A
        let anchorOnA = b.sync.model.deck(.a).anchor!

        a.link.leave()                                       // the host walks away
        await RemoteTestSupport.waitUntil { b.remote.isHost }
        b.sync.tick()                                        // B takes over the mix
        XCTAssertEqual(b.sync.model.epoch, "B")
        XCTAssertNil(b.sync.owner(of: .a), "the departed host's deck is freed")
        XCTAssertEqual(b.sync.owner(of: .b), "B", "everyone else keeps their deck")
        XCTAssertTrue(b.sync.isActive)
        // Anchors move from A's timeline onto B's clock (B's clock reads A + 700 ms): the deck is
        // where A said it would be at the SAME physical instant (B's own first heartbeat may
        // already have re-stamped it — equivalently).
        let rebased = b.sync.model.deck(.a).anchor!
        XCTAssertEqual(rebased.position(at: anchorOnA.atSharedTime! + 700, rate: 1), anchorOnA.positionMs)

        await RemoteTestSupport.waitUntil { c.remote.hostId == "B" }
        c.sync.tick()
        await RemoteTestSupport.waitUntil { c.sync.model.epoch == "B" }
        XCTAssertEqual(c.sync.owner(of: .b), "B")
        XCTAssertNil(c.sync.owner(of: .a))
        // The new host orders: C claims the free deck, B keeps mixing on its own.
        c.sync.claim(.a)
        await RemoteTestSupport.waitUntil { b.sync.owner(of: .a) == "C" && c.sync.owner(of: .a) == "C" }
        b.engine.userSet("volume", .b, 0.4)
        await RemoteTestSupport.waitUntil { c.engine.value("volume", .b) == 0.4 }
    }

    // MARK: - Pure model

    func testModelLoadResetsTrackScopedControlsAndLeadIsExclusive() {
        var m = MixSyncModel()
        m.apply(MixSyncEvent(kind: "load", deck: "A", songId: "s1"), sharedNow: 0)
        m.apply(MixSyncEvent(kind: "tempo", deck: "A", value: 1.1), sharedNow: 0)
        m.apply(MixSyncEvent(kind: "volume", deck: "A", value: 0.4), sharedNow: 0)
        m.apply(MixSyncEvent(kind: "lead", deck: "A", flag: true), sharedNow: 0)
        m.apply(MixSyncEvent(kind: "lead", deck: "B", flag: true), sharedNow: 0)
        XCTAssertFalse(m.deck(.a).controls.contains { $0.kind == "lead" })
        XCTAssertEqual(m.deck(.a).rate, 1.1)
        m.apply(MixSyncEvent(kind: "load", deck: "A", songId: "s2"), sharedNow: 10)
        XCTAssertEqual(m.deck(.a).rate, 1)
        XCTAssertEqual(m.deck(.a).controls.map(\.kind), ["volume"], "volume survives a load, tempo doesn't")
        m.apply(MixSyncEvent(kind: "eject", deck: "A"), sharedNow: 20)
        XCTAssertNil(m.deck(.a).track)
        XCTAssertTrue(m.deck(.a).controls.isEmpty)
        let round = MixSyncModel(m.snapshot())
        XCTAssertEqual(round, m)
        XCTAssertEqual(MixSyncAnchor(positionMs: 1_000, atSharedTime: 100, isPlaying: true)
            .position(at: 600, rate: 1.5), 1_750)
    }

    // MARK: - The real engine's seams

    private final class CountingRecorder: MixSessionRecorder {
        var kinds: [MixEventKind] = []
        func logEvent(_ kind: MixEventKind, deck: String?, songId: String?, title: String?, artist: String?,
                      bpm: Double?, camelot: String?, param: String?, value: Double?, flag: Bool?,
                      posMs: Int?, slot: Int?) { kinds.append(kind) }
        func logGlide(deck: String?, param: String, songId: String?, title: String?, artist: String?,
                      from: Double, to: Double, rate: Double, posMs: Int?, slot: Int?) {}
        func notePlayed(songId: String) {}
        func hasPlayed(_ songId: String) -> Bool { false }
    }

    func testRealEngineRemoteApplyIsNeitherTappedNorRecorded() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore())
        let rec = CountingRecorder()
        e.recorder = rec
        var taps: [MixEngine.Gesture] = []
        e.gestureTap = { taps.append($0) }

        e.syncApplyControl(MixSyncEvent(kind: "volume", deck: "A", value: 0.3))
        e.syncApplyControl(MixSyncEvent(kind: "crossfader", deck: nil, value: 0.25))
        e.syncApplyControl(MixSyncEvent(kind: "effectToggle", deck: "A", param: "reverb", flag: true, slot: 1))
        e.syncLoad(MixLoadable(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil,
                               albumId: nil, lengthMs: 2_000), on: .b)
        XCTAssertEqual(e.volume(.a), 0.3, accuracy: 1e-9)
        XCTAssertEqual(e.crossfader, 0.25, accuracy: 1e-9)
        XCTAssertEqual(e.slot(1, on: .a)?.enabled, true)
        XCTAssertEqual(e.loaded(.b)?.songId, "x")
        XCTAssertTrue(taps.isEmpty, "remote applies never tap")
        XCTAssertTrue(rec.kinds.isEmpty, "remote applies never land in this DJ's session log")

        e.setVolume(0.5, on: .a)                          // a LOCAL gesture taps + records
        XCTAssertEqual(taps.map(\.kind), ["volume"])
        XCTAssertEqual(rec.kinds, [.volume])
        e.clearDeck(.b)                                   // compound gesture → ONE eject
        XCTAssertEqual(taps.map(\.kind), ["volume", "eject"])
    }

    func testRealEngineScheduledStartCuesForTheSharedInstant() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore(lengths: ["x": 6]))
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        XCTAssertEqual(e.loaded(.a)?.songId, "x")
        let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3)
        e.play(.a, fromMs: 2_000, atHostTime: start)
        XCTAssertTrue(e.isPlaying(.a))
        // The playhead reads `fromMs` minus the wait, so it lands on 2.0 s at the start instant
        // (on either path — sample-scheduled, or the no-render-clock seek + play fallback).
        XCTAssertEqual(e.position(.a), 1.7, accuracy: 0.05)
        e.pause(.a)
    }

    func testHostTimeConversionIsLinearAndNeverInThePast() {
        let base: UInt64 = 1_000_000
        XCTAssertEqual(MixEngine.hostTime(forLocalMs: 1_500, nowLocalMs: 1_000, nowHost: base),
                       base + AVAudioTime.hostTime(forSeconds: 0.5))
        XCTAssertEqual(MixEngine.hostTime(forLocalMs: 900, nowLocalMs: 1_000, nowHost: base), base)
    }

    func testRealEngineAutoDJBlockRefusesAutoMode() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore())
        e.setAutoEnabled(true)
        XCTAssertTrue(e.autoEnabled)
        e.setAutoDJBlocked(MixSync.autoDJBlockedReason)
        XCTAssertFalse(e.autoEnabled)
        e.setAutoEnabled(true)
        XCTAssertFalse(e.autoEnabled, "Auto mode is refused while mixing together")
        e.startAutoMix([MixEngine.AutoMixItem(loadable: MixLoadable(songId: "x", title: "T", artist: "A", bpm: 120,
                                                                   camelot: nil, key: nil, albumId: nil, lengthMs: 2_000),
                                              durationMs: 2_000)],
                       shuffled: false, lead: 5, fade: 3)
        XCTAssertFalse(e.autoMixing)
        e.setAutoDJBlocked(nil)
        e.setAutoEnabled(true)
        XCTAssertTrue(e.autoEnabled)
    }
}
