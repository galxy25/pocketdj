import XCTest
import AVFoundation
import Observation
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
            /// The drift loop's temporary rate multiplier (1 = none).
            var nudge = 1.0
            /// An engaged loop window (source ms) — the playhead folds into it.
            var loop: (start: Int, end: Int)?
        }

        var gestureTap: ((MixEngine.Gesture) -> Void)?
        let now: () -> Double
        var decks: [MixEngine.Deck: DeckState] = [.a: DeckState(), .b: DeckState()]
        var crossfader = 0.5
        var autoDJBlocked: String?
        var sessionActive = false
        var nudges: [(deck: MixEngine.Deck, factor: Double)] = []
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
            let linear = s.isPlaying ? s.posMs + Int(((now() - s.at) * s.rate * s.nudge).rounded()) : s.posMs
            guard let w = s.loop, w.end > w.start, linear >= w.start else { return linear }
            return w.start + (linear - w.start) % (w.end - w.start)
        }

        // MixSyncEngine
        func syncStatus(_ d: MixEngine.Deck) -> MixSyncDeckStatus {
            let s = decks[d]!
            return MixSyncDeckStatus(songId: s.songId, isPlaying: s.isPlaying, playheadMs: playhead(d),
                                     durationMs: s.songId == nil ? 0 : s.durationMs, rate: s.rate,
                                     ready: s.songId != nil && s.ready, looping: s.loop != nil,
                                     loopStartMs: s.loop?.start, loopEndMs: s.loop?.end)
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
            if let w = decks[d]!.loop, w.end > w.start {        // a looping deck starts at its phase
                let r = (fromMs - w.start) % (w.end - w.start)
                decks[d]!.posMs = w.start + (r < 0 ? r + (w.end - w.start) : r)
                decks[d]!.isPlaying = true
                decks[d]!.at = atLocalMs
                plays.append((d, fromMs, atLocalMs))
                applied.append("play:\(d.rawValue):\(fromMs)")
                return
            }
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
        func syncSetControls(_ d: MixEngine.Deck, _ controls: [MixSyncEvent]) {
            var c: [String: MixSyncEvent] = [:]
            for e in controls where e.kind != MixSyncKind.loop && e.kind != MixSyncKind.loopUnits { c[e.controlKey] = e }
            rebase(d)
            decks[d]!.rate = c["rate:\(d.rawValue)"]?.value ?? 1
            decks[d]!.controls = c
            applied.append("controls:\(d.rawValue):\(c.keys.sorted().joined(separator: ","))")
        }
        func syncSetLoop(_ d: MixEngine.Deck, on: Bool, units: Double?, startMs: Int?, endMs: Int?) {
            rebase(d)
            if on, let s = startMs, let e = endMs { decks[d]!.loop = (s, e) } else if !on { decks[d]!.loop = nil }
            applied.append("loop:\(d.rawValue):\(on ? "\(startMs ?? -1)-\(endMs ?? -1)" : "off")")
        }
        func syncNudgeRate(_ d: MixEngine.Deck, factor: Double) {
            rebase(d)
            decks[d]!.nudge = factor
            nudges.append((d, factor))
        }
        var seeds: [MixEngine.Deck: [MixSyncEvent]] = [:]
        func syncSeedEvents(_ deck: MixEngine.Deck) -> [MixSyncEvent] { seeds[deck] ?? [] }
        var syncCrossfader: Double { crossfader }
        func setAutoDJBlocked(_ reason: String?) { autoDJBlocked = reason }
        func syncSessionActive(_ on: Bool) { sessionActive = on }
        var remoteControllerGate: ((SetlistPlayer.RemoteRedirect) -> Bool)?
        var controllerSilences = 0
        func syncSilenceForController() {
            guard decks.values.contains(where: \.isPlaying) else { return }
            controllerSilences += 1
            for d in MixEngine.Deck.allCases where decks[d]!.isPlaying { rebase(d); decks[d]!.isPlaying = false }
        }

        func rebase(_ d: MixEngine.Deck) {
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
        /// This device's SYSTEM transport (lock screen / CarPlay / an interruption).
        func systemPause(_ d: MixEngine.Deck) {
            rebase(d)
            decks[d]!.isPlaying = false
            tap(MixEngine.Gesture(kind: "pause", deck: d, posMs: playhead(d), cause: .system))
        }
        func systemPlay(_ d: MixEngine.Deck) {
            decks[d]!.isPlaying = true
            decks[d]!.at = now()
            tap(MixEngine.Gesture(kind: "play", deck: d, posMs: playhead(d), cause: .system))
        }
        /// The engine's own housekeeping stop (a watchdog).
        func enginePause(_ d: MixEngine.Deck) {
            rebase(d)
            decks[d]!.isPlaying = false
            tap(MixEngine.Gesture(kind: "pause", deck: d, posMs: playhead(d), cause: .engine))
        }
        func userLoop(_ d: MixEngine.Deck, _ start: Int, _ end: Int) {
            rebase(d)
            decks[d]!.loop = (start, end)
            tap(MixEngine.Gesture(kind: MixEngine.Gesture.loop, deck: d, value: 2, flag: true,
                                  posMs: playhead(d), loopStartMs: start, loopEndMs: end))
        }
        func userReset(_ d: MixEngine.Deck) {
            decks[d]!.posMs = 0
            decks[d]!.at = now()
            decks[d]!.controls = [:]
            tap(MixEngine.Gesture(kind: "resetDeck", deck: d))
        }
        func tap(_ g: MixEngine.Gesture) {
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

    private func device(_ id: String, skew: Double = 0, unmixable: Set<String> = [],
                        platform: String = "test", deckOwnerCapable: Bool = true) -> Device {
        let clock = self.clock
        let now: () -> Double = { clock.t + skew }
        let remote = RemoteSessionController(target: InMemoryRemoteTarget(now: now),
                                             resolver: RemoteSongResolver(catalogItem: { _ in nil }),
                                             deviceName: "Device \(id)", platform: platform,
                                             clock: SharedClock(localNow: now))
        let engine = FakeMixEngine(now: now)
        let sync = MixSync(remote: remote, engine: engine, resolve: { e in
            unmixable.contains(e.songId ?? "") ? nil : Self.loadable(e)
        }, autoTick: false)
        if !deckOwnerCapable { remote.localCaps = [] }          // an Apple TV build advertises none
        return Device(id: id, remote: remote, link: hub.join(id: id), engine: engine, sync: sync, skew: skew)
    }

    /// A PHASE-1-only build in the session: the Remote layer, no Mix layer (no caps, never
    /// answers a mix request).
    private func phase1Peer(_ id: String, asHost: Bool = false) -> RemoteSessionController {
        let clock = self.clock
        let now: () -> Double = { clock.t }
        let r = RemoteSessionController(target: InMemoryRemoteTarget(now: now),
                                        resolver: RemoteSongResolver(catalogItem: { _ in nil }),
                                        deviceName: "Old \(id)", platform: "test", clock: SharedClock(localNow: now))
        r.attach(hub.join(id: id), mode: .listenTogether, asHost: asHost, autoTick: false)
        return r
    }

    private func lastSent<T: Decodable>(_ d: Device, kind: String, as: T.Type) -> T? {
        sent(d, kind: kind).last.flatMap { try? JSONDecoder().decode(T.self, from: $0.payload) }
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

    func testDriftNeedsTwoBeatsThenNudgesSmallAndReseeksLarge() async {
        let (a, b) = await twoDeviceMix(guestSkew: -2_500)
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        XCTAssertEqual(b.sync.driftThreshold(), MixSync.driftThresholdMs, "a 2 ms RTT keeps the 40 ms floor")

        func beat() async {
            advance(MixSync.heartbeatMs)
            a.sync.tick()
            await barrier(a, b)
            b.sync.tick()
        }
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0, "in sync ⇒ no correction")

        b.engine.decks[.a]!.posMs += 30                      // under the 40 ms threshold
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0)

        b.engine.decks[.a]!.posMs += 70                      // now 100 ms AHEAD
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0, "one beat is not enough (a stale relay)")
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 1, "two consecutive beats ⇒ a correction")
        XCTAssertEqual(b.sync.nudgeCount[.a, default: 0], 1, "small drift is NUDGED…")
        XCTAssertEqual(b.engine.plays.count, 1, "…never stop/restarted")
        XCTAssertEqual(b.engine.nudges.last?.factor ?? 0, 1 - MixSync.nudgeRate, accuracy: 1e-9, "ahead ⇒ 1 % slow")
        XCTAssertEqual(b.engine.decks[.a]!.rate, 1, "the deck's own tempo is untouched")

        advance(100 / MixSync.nudgeRate)                     // exactly long enough to close 100 ms
        b.sync.tick()
        XCTAssertEqual(b.engine.nudges.last?.factor, 1, "the nudge ends at exactly the deck's tempo")
        XCTAssertLessThanOrEqual(abs(b.engine.playhead(.a) - a.engine.playhead(.a)), 1, "the nudge closed the gap")

        b.engine.decks[.a]!.posMs += 600                     // large drift
        await beat()
        XCTAssertEqual(b.engine.plays.count, 1)
        await beat()                                         // 2nd strike, ≥ cooldown after the nudge
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 2)
        XCTAssertEqual(b.sync.nudgeCount[.a, default: 0], 1, "large drift re-seeks")
        XCTAssertEqual(b.engine.plays.count, 2)
        advance(MixSync.startLeadMs)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a), "re-seek lands on the owner's position")

        b.engine.decks[.a]!.posMs += 600                     // one bad beat…
        await beat()
        b.engine.decks[.a]!.posMs -= 600                     // …between good ones
        await beat()
        b.engine.decks[.a]!.posMs += 600
        await beat()
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 2, "strikes must be CONSECUTIVE")
    }

    func testDriftThresholdWidensWithClockUncertainty() async {
        let a = device("A"), b = device("B")
        attachHost(a)
        await join(b, host: a, syncedClock: false)
        b.remote.clock.ingest(SharedClock.Sample(offsetMs: 0, rttMs: 200))   // a relayed, slow path
        a.sync.start()
        await RemoteTestSupport.waitUntil { b.sync.isActive && b.sync.owner(of: .b) == "B" }
        XCTAssertEqual(b.sync.driftThreshold(), 120, "½ RTT + 20 ms margin")
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        advance(MixSync.startLeadMs)
        b.engine.decks[.a]!.posMs += 100                     // measurement noise at this RTT
        for _ in 0..<3 {
            advance(MixSync.heartbeatMs); a.sync.tick(); await barrier(a, b)
        }
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0, "100 ms under a 120 ms uncertainty is not drift")
    }

    func testOwnerProposesPlayOnlyOnceSoundingAndHostHoldTimesOut() async {
        let (a, b) = await twoDeviceMix()
        b.engine.loadsReady = false                          // B's deck is still buffering
        b.engine.userLoad(.b, "s2")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s2" }
        b.engine.userPlay(.b, fromMs: 0)
        await barrier(b, a)
        XCTAssertFalse(sent(b, kind: MixWireKind.event).contains {
            (try? JSONDecoder().decode(MixSyncEventMessage.self, from: $0.payload))?.event.kind == "play"
        }, "a buffering owner doesn't anchor everyone to a playhead that isn't moving")
        XCTAssertTrue(a.engine.plays.isEmpty)

        advance(1_500)                                       // the bytes land 1.5 s later
        b.engine.decks[.b]!.at = clock.t                    // the held playhead starts moving only now
        b.engine.decks[.b]!.ready = true
        b.sync.tick()                                        // ready → the start is proposed NOW
        await RemoteTestSupport.waitUntil { a.engine.plays.count == 1 }
        advance(MixSync.startLeadMs)
        XCTAssertEqual(a.engine.playhead(.b), b.engine.playhead(.b), "others start where the owner really is")

        // An owner that proposes while still loading (an older build): the host holds it, then
        // times out and everyone else starts anyway.
        b.engine.userLoad(.b, "s3")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s3" }
        await RemoteTestSupport.waitUntil { a.sync.peerReadiness["B"]?["B"]?.status == .loading }
        a.link.inject(envelope(MixWireKind.event, MixSyncEventMessage(originSeq: 10_000, event: MixSyncEvent(
            kind: "play", deck: "B", anchor: MixSyncAnchor(positionMs: 0, atSharedTime: clock.t, isPlaying: true)))),
                      from: "B")
        await barrier(b, a)
        XCTAssertEqual(a.engine.plays.count, 1, "held for the owner's ready report")
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
        // heartbeats (two in a row) pull it onto the shared timeline.
        syncClock(c, to: a)
        for _ in 0..<2 {
            advance(MixSync.heartbeatMs)
            a.sync.tick()
            await barrier(a, c)
        }
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

    // MARK: - Phase-2 review fixes

    func testSystemPauseStaysLocalHoldsAndRejoinsAtTheAnchor() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        advance(MixSync.startLeadMs)

        // B's lock screen / an interruption pauses B's copy of A's deck: this device only.
        let eventsBefore = sent(b, kind: MixWireKind.event).count
        b.engine.systemPause(.a)
        b.sync.tick()
        XCTAssertEqual(sent(b, kind: MixWireKind.event).count, eventsBefore, "a system pause is never proposed")
        XCTAssertTrue(b.sync.systemHeld.contains(.a))
        for _ in 0..<3 {                                    // neither the repair loop nor the drift loop restarts it
            advance(MixSync.heartbeatMs); a.sync.tick(); await barrier(a, b); b.sync.tick()
        }
        XCTAssertFalse(b.engine.decks[.a]!.isPlaying, "no repair while the system holds it (mid-call)")
        XCTAssertTrue(a.engine.decks[.a]!.isPlaying, "the owner never heard about it")
        XCTAssertEqual(b.engine.plays.count, 1)

        // The system resumes: B REJOINS at the anchored position, not where it stopped.
        b.engine.systemPlay(.a)
        b.sync.tick()
        XCTAssertFalse(b.sync.systemHeld.contains(.a))
        advance(MixSync.startLeadMs)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a))

        // The OWNER's own system pause: local to it — others keep playing, no heartbeat goes out.
        let beatsBefore = sent(a, kind: MixWireKind.beat).count
        a.engine.systemPause(.a)
        advance(MixSync.heartbeatMs)
        a.sync.tick()
        await barrier(a, b)
        XCTAssertTrue(b.engine.decks[.a]!.isPlaying)
        XCTAssertEqual(sent(a, kind: MixWireKind.beat).count, beatsBefore, "a held deck is nobody's reference")
        XCTAssertTrue(a.sync.model.deck(.a).anchor?.isPlaying == true)

        // Engine housekeeping is ignored outright (not shared, not repaired).
        b.engine.userLoad(.b, "s2")
        b.engine.userPlay(.b)
        let bEvents = sent(b, kind: MixWireKind.event).count
        b.engine.enginePause(.b)
        b.sync.tick()
        XCTAssertEqual(sent(b, kind: MixWireKind.event).count, bEvents)
    }

    func testLostProposalExpiresAndResyncsFromTheSnapshot() async {
        let (a, b) = await twoDeviceMix()
        hub.drop = { env, from, _ in from == "B" && env.kind == MixWireKind.event }
        b.engine.userCrossfader(0.9)                        // lost on the way to the host
        hub.drop = nil
        a.engine.userCrossfader(0.2)
        await barrier(a, b)
        XCTAssertEqual(b.engine.crossfader, 0.9, "shadowed while B believes its own proposal is in flight")
        advance(MixSync.pendingTimeoutMs)
        b.sync.tick()                                       // presumed lost → snapshot
        await RemoteTestSupport.waitUntil { b.engine.crossfader == 0.2 }
        XCTAssertEqual(b.sync.model.crossfader, 0.2)
    }

    func testHostDropsStaleReorderedProposals() async {
        let (a, b) = await twoDeviceMix()
        b.engine.userLoad(.b, "s2")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s2" }
        func proposal(_ seq: Int, _ v: Double) -> RemoteEnvelope {
            envelope(MixWireKind.event, MixSyncEventMessage(originSeq: seq, event: MixSyncEvent(kind: "volume", deck: "B", value: v)))
        }
        a.link.inject(proposal(500, 0.8), from: "B")
        a.link.inject(proposal(499, 0.1), from: "B")        // reordered: the older one arrives last
        await barrier(b, a)
        XCTAssertEqual(a.engine.value("volume", .b), 0.8, "an older proposal never undoes a newer one")
        XCTAssertEqual(a.sync.model.deck(.b).controls.first { $0.kind == "volume" }?.value, 0.8)
        XCTAssertEqual(a.sync.staleDropped, 1)
        a.link.inject(proposal(501, 0.3), from: "B")        // the next newer one goes through
        await barrier(b, a)
        XCTAssertEqual(a.engine.value("volume", .b), 0.3)
    }

    func testSeedCarriesTheWholeBoardAndReconcileResetsUnlistedControls() async {
        let a = device("A"), b = device("B")
        attachHost(a)
        await join(b, host: a)
        a.engine.decks[.a]!.songId = "s1"
        a.engine.seeds[.a] = [
            MixSyncEvent(kind: "load", deck: "A", songId: "s1", title: "T-s1"),
            MixSyncEvent(kind: "tempo", deck: "A", value: 1.05),
            MixSyncEvent(kind: "eq", deck: "A", param: "low", value: -6),
            MixSyncEvent(kind: "effectToggle", deck: "A", param: "reverb", flag: true, slot: 1),
            MixSyncEvent(kind: "stemMode", deck: "A", flag: true),
            MixSyncEvent(kind: "pause", deck: "A", anchor: MixSyncAnchor(positionMs: 4_000, atSharedTime: nil, isPlaying: false)),
        ]
        // B's own pre-session board on deck A must not survive the session's load.
        b.engine.decks[.a]!.controls["eq:A:high"] = MixSyncEvent(kind: "eq", deck: "A", param: "high", value: 9)
        a.sync.start()
        await RemoteTestSupport.waitUntil { b.sync.isActive && b.engine.decks[.a]?.songId == "s1" }
        await barrier(a, b)
        XCTAssertEqual(b.engine.decks[.a]!.controls["eq:A:low"]?.value, -6)
        XCTAssertEqual(b.engine.decks[.a]!.controls["effectToggle:A:#1"]?.flag, true)
        XCTAssertEqual(b.engine.decks[.a]!.controls["stemMode:A:"]?.flag, true)
        XCTAssertEqual(b.engine.decks[.a]!.rate, 1.05)
        XCTAssertNil(b.engine.decks[.a]!.controls["eq:A:high"], "a joiner's load takes the SESSION's board")
        XCTAssertEqual(b.engine.playhead(.a), 4_000)

        // A stray local change on a deck B doesn't own (a keyboard shortcut) is fully reverted —
        // including a control the session never set (back to its default).
        b.engine.userSet("volume", .a, 0.1)
        b.engine.userSet("tempo", .a, 1.3)
        b.sync.tick()
        XCTAssertNil(b.engine.value("volume", .a), "an unlisted control goes back to default")
        XCTAssertEqual(b.engine.decks[.a]!.controls["rate:A"]?.value, 1.05)
        XCTAssertEqual(b.engine.decks[.a]!.rate, 1.05, "no stray tempo left to trip the drift loop")
    }

    func testLoopSyncsTheExactWindowAndJoinersSeekBeforeLooping() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 10_000)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        advance(MixSync.startLeadMs + 500)                  // both at 10 800
        a.engine.userLoop(.a, 10_500, 11_500)
        await barrier(a, b)
        XCTAssertEqual(b.engine.decks[.a]!.loop?.start, 10_500, "the owner's window, not one around B's playhead")
        XCTAssertEqual(b.engine.decks[.a]!.loop?.end, 11_500)
        advance(3_333)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a), "same phase inside the same window")
        for _ in 0..<3 {                                    // in phase ⇒ the drift loop leaves a looping deck alone
            advance(MixSync.heartbeatMs); a.sync.tick(); await barrier(a, b)
        }
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 0)

        // Out of phase on a looping deck IS drift (compared inside the window, the short way round).
        b.engine.decks[.a]!.posMs += 150
        for _ in 0..<2 { advance(MixSync.heartbeatMs); a.sync.tick(); await barrier(a, b) }
        XCTAssertEqual(b.sync.driftFixCount[.a, default: 0], 1)

        // A late joiner: anchor (seek) FIRST, then the exact window — never a loop near 0:00.
        let c = device("C")
        await join(c, host: a)
        await RemoteTestSupport.waitUntil { c.engine.decks[.a]?.loop != nil }
        let iPlay = c.engine.applied.firstIndex { $0.hasPrefix("play:A") }
        let iLoop = c.engine.applied.firstIndex { $0 == "loop:A:10500-11500" }
        XCTAssertNotNil(iPlay); XCTAssertNotNil(iLoop)
        XCTAssertLessThan(iPlay ?? .max, iLoop ?? .min)
        advance(MixSync.startLeadMs)
        XCTAssertEqual(c.engine.playhead(.a), a.engine.playhead(.a))
    }

    func testContinuousGesturesAreCoalescedAndOwnershipObserversStayQuiet() async {
        let (a, b) = await twoDeviceMix()
        b.engine.userLoad(.b, "s2")
        await RemoteTestSupport.waitUntil { a.engine.decks[.b]?.songId == "s2" }
        let before = sent(b, kind: MixWireKind.event).count
        for i in 1...10 { b.engine.userSet("volume", .b, Double(i) / 10) }   // one drag burst
        XCTAssertEqual(sent(b, kind: MixWireKind.event).count, before + 1, "the first move goes at once")
        advance(MixSync.continuousIntervalMs)
        b.sync.tick()
        XCTAssertEqual(sent(b, kind: MixWireKind.event).count, before + 2, "…then ONE trailing send")
        await RemoteTestSupport.waitUntil { a.engine.value("volume", .b) == 1.0 }

        // The hot model isn't observed: a control on the wire never re-renders a deck.
        var fired = false
        withObservationTracking {
            _ = a.sync.canControl(.b); _ = a.sync.owner(of: .a); _ = a.sync.myDecks
        } onChange: { fired = true }
        advance(100)
        b.engine.userSet("volume", .b, 0.4)
        await RemoteTestSupport.waitUntil { a.engine.value("volume", .b) == 0.4 }
        XCTAssertFalse(fired, "ownership observers don't fire for control traffic")
        a.sync.release(.a)
        XCTAssertTrue(fired, "…only when an owner changes")
    }

    func testEveryDeviceTakesTheAnchorFromTheOwnersBeat() async {
        let (a, b) = await twoDeviceMix()
        b.engine.userLoad(.b, "s2")
        b.engine.userPlay(.b, fromMs: 0)
        await RemoteTestSupport.waitUntil { a.engine.plays.count == 1 }
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        advance(MixSync.heartbeatMs)
        a.sync.tick()
        b.sync.tick()
        await barrier(a, b)
        await barrier(b, a)
        let fromA = lastSent(a, kind: MixWireKind.beat, as: MixSyncBeat.self)
        let fromB = lastSent(b, kind: MixWireKind.beat, as: MixSyncBeat.self)
        XCTAssertEqual(fromA?.deck, "A"); XCTAssertEqual(fromB?.deck, "B")
        XCTAssertEqual(b.sync.model.deck(.a).anchor, fromA?.anchor, "a non-host folds the owner's beat in too")
        XCTAssertEqual(a.sync.model.deck(.b).anchor, fromB?.anchor)
        XCTAssertEqual(fromB?.uncertaintyMs ?? -1, 1, accuracy: 1e-9, "the owner reports ½ its RTT")
    }

    func testDeckBGoesOnlyToAMixCapablePeer() async {
        let a = device("A")
        attachHost(a)
        let old = phase1Peer("0")                           // lowest id — would have won before
        await RemoteTestSupport.waitUntil { old.hostId == "A" && old.state != nil }
        let tv = device("1", platform: "Apple TV", deckOwnerCapable: false)
        await join(tv, host: a)
        let b = device("B")
        await join(b, host: a)
        a.sync.start()
        a.sync.tick()
        await RemoteTestSupport.waitUntil { b.sync.owner(of: .b) == "B" }
        XCTAssertEqual(a.sync.owner(of: .b), "B", "not the Phase-1 build, not the Apple TV")
    }

    func testRealHostNeverEndsFromAnEmptyOrOlderHostsSnapshot() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        await RemoteTestSupport.waitUntil { b.engine.decks[.a]?.songId == "s1" }
        let seq = b.sync.model.hostSeq
        // A snapshot from a host that doesn't have the mix (another epoch, inactive) / is behind.
        for snap in [MixSyncSnapshot(epoch: "Z", active: false, hostSeq: 0, decks: [:], crossfader: nil, assignedB: false),
                     MixSyncSnapshot(epoch: "Z", active: true, hostSeq: seq - 1, decks: [:], crossfader: nil, assignedB: false)] {
            b.link.inject(envelope(MixWireKind.snapshot, snap), from: "A")
            await barrier(a, b)
            XCTAssertTrue(b.sync.isActive, "a live mix is never ended / rolled back by an empty host")
            XCTAssertEqual(b.engine.decks[.a]?.songId, "s1")
        }
        XCTAssertEqual(sent(b, kind: MixWireKind.handover).count, 2, "…it hands that host the live mix instead")
        await barrier(b, a)
        XCTAssertEqual(a.sync.model.epoch, "A", "a host whose own mix is live and current keeps it")
    }

    func testAHostThatNeverHadTheMixAdoptsALiveMirror() async {
        let e = device("E"), f = device("F")
        let hub2Model: MixSyncModel = {
            var m = MixSyncModel()
            m.epoch = "X"; m.active = true; m.hostSeq = 9; m.assignedB = true
            m.apply(MixSyncEvent(kind: "owner", deck: "A", owner: "F"), sharedNow: 0)
            m.apply(MixSyncEvent(kind: "load", deck: "A", songId: "s7", title: "T-s7"), sharedNow: 0)
            return m
        }()
        attachHost(e)
        await join(f, host: e)
        XCTAssertFalse(e.sync.isActive)
        e.link.inject(envelope(MixWireKind.handover, MixSyncHandover(snapshot: hub2Model.snapshot(), sentAtLocal: clock.t)),
                      from: "F")
        await RemoteTestSupport.waitUntil { e.sync.isActive }
        XCTAssertEqual(e.sync.model.epoch, "E")
        XCTAssertEqual(e.sync.owner(of: .a), "F")
        XCTAssertEqual(e.engine.decks[.a]?.songId, "s7")
        await RemoteTestSupport.waitUntil { f.sync.isActive && f.sync.model.epoch == "E" }
    }

    func testResetDeckRewindsEveryoneAtOneSharedInstant() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 20_000)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 1 }
        advance(2_000)
        let t = clock.t
        a.engine.userReset(.a)
        await RemoteTestSupport.waitUntil { b.engine.plays.count == 2 }
        XCTAssertEqual(b.engine.plays[1].atLocalMs, t + MixSync.startLeadMs, accuracy: 0.001, "at the shared instant…")
        XCTAssertEqual(b.engine.plays[1].fromMs, Int(MixSync.startLeadMs), "…where the owner's rewound deck will be")
        advance(MixSync.startLeadMs)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a))
    }

    func testSnapshotRequestsBackOffAndStopForAHostThatNeverAnswers() async {
        let host = phase1Peer("H", asHost: true)
        let b = device("B")
        b.remote.attach(b.link, mode: .listenTogether, asHost: false, autoTick: false)
        await RemoteTestSupport.waitUntil { b.remote.hostId == "H" && b.remote.state != nil }
        _ = host
        b.sync.tick()
        XCTAssertEqual(sent(b, kind: MixWireKind.request).count, 1)
        var times: [Double] = []
        let t0 = clock.t
        for _ in 0..<40 {
            advance(MixSync.snapshotRetryMs)
            let n = sent(b, kind: MixWireKind.request).count
            b.sync.tick()
            if sent(b, kind: MixWireKind.request).count > n { times.append(clock.t - t0) }
        }
        XCTAssertEqual(times, [3_000, 9_000, 21_000, 45_000], "3, 6, 12, 24 s apart — then it stops")
        XCTAssertEqual(sent(b, kind: MixWireKind.request).count, MixSync.snapshotMaxAttempts)
    }

    // MARK: - Re-review fixes

    /// #3 — a deck another DJ owns that THIS device's system paused has a read-only ▶: any ▶ of
    /// the DJ's own (or the banner's Rejoin) brings every held deck back at the anchor.
    func testAnyOwnPlayOrRejoinBringsBackEveryHeldDeck() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        a.engine.userPlay(.a, fromMs: 0)
        await RemoteTestSupport.waitUntil { b.engine.decks[.a]!.isPlaying }
        advance(MixSync.startLeadMs)
        b.engine.userLoad(.b, "s2")
        b.engine.userPlay(.b, fromMs: 0)
        b.sync.tick()

        // An interruption pauses both decks HERE (B's copy of A's deck + B's own).
        b.engine.systemPause(.a)
        b.engine.systemPause(.b)
        XCTAssertEqual(b.sync.systemHeld, [.a, .b])
        b.sync.tick()
        XCTAssertFalse(b.engine.decks[.a]!.isPlaying)

        // B presses ▶ on ITS deck: the other DJ's deck rejoins too.
        b.engine.userPlay(.b)
        XCTAssertTrue(b.sync.systemHeld.isEmpty)
        b.sync.tick()
        XCTAssertTrue(b.engine.decks[.a]!.isPlaying, "the read-only deck rejoined with the DJ's own ▶")
        advance(MixSync.startLeadMs)
        XCTAssertEqual(b.engine.playhead(.a), a.engine.playhead(.a), "at the anchored position")

        // …and the banner's Rejoin does it with no deck ▶ at all.
        b.engine.systemPause(.a)
        XCTAssertEqual(b.sync.systemHeld, [.a])
        b.sync.rejoin()
        XCTAssertTrue(b.sync.systemHeld.isEmpty)
        XCTAssertTrue(b.engine.decks[.a]!.isPlaying)
    }

    /// #5 — ordered events buffered while a snapshot is awaited are BOUNDED: an overflow drops
    /// them and re-requests a snapshot at once (instead of waiting out the backoff).
    func testEventBufferIsCappedAndOverflowRequestsASnapshot() async {
        let (a, b) = await twoDeviceMix()
        // The host's snapshots never reach B from here on (B keeps waiting).
        hub.drop = { env, _, to in env.kind == MixWireKind.snapshot && to == .participant("B") }
        func ordered(_ seq: Int) -> RemoteEnvelope {
            envelope(MixWireKind.event, MixSyncEventMessage(
                originSeq: 0, origin: "A", hostSeq: seq, epoch: "other-epoch",
                event: MixSyncEvent(kind: "volume", deck: "A", value: 0.5)))
        }
        let base = b.sync.model.hostSeq + 1
        b.link.inject(ordered(base), from: "A")             // epoch mismatch → buffered + request
        await RemoteTestSupport.waitUntil { b.sync.bufferedEventCount == 1 }
        let requests = sent(b, kind: MixWireKind.request).count
        for i in 1..<MixSync.eventBufferCap { b.link.inject(ordered(base + i), from: "A") }
        await RemoteTestSupport.waitUntil { b.sync.bufferedEventCount == MixSync.eventBufferCap }
        XCTAssertEqual(sent(b, kind: MixWireKind.request).count, requests, "the backoff paces requests")
        b.link.inject(ordered(base + MixSync.eventBufferCap), from: "A")
        await RemoteTestSupport.waitUntil { b.sync.bufferedEventCount == 1 }
        XCTAssertEqual(sent(b, kind: MixWireKind.request).count, requests + 1, "overflow re-asks at once")
        _ = a
    }

    /// #6 — the 4 Hz tick never runs outside a Remote session (zero cost for everyone else).
    func testMixSyncTicksOnlyWhileASessionIsLive() async {
        let clock = self.clock
        let now: () -> Double = { clock.t }
        let remote = RemoteSessionController(target: InMemoryRemoteTarget(now: now),
                                             resolver: RemoteSongResolver(catalogItem: { _ in nil }),
                                             deviceName: "T", platform: "test", clock: SharedClock(localNow: now))
        let sync = MixSync(remote: remote, engine: FakeMixEngine(now: now), resolve: Self.loadable)
        XCTAssertFalse(sync.isTicking, "no tick from launch")
        remote.attach(hub.join(id: "T"), mode: .listenTogether, asHost: true, autoTick: false)
        XCTAssertTrue(sync.isTicking)
        remote.leave()
        XCTAssertFalse(sync.isTicking, "stopped with the session")
    }

    /// #12 — a scheduled start is never placed more than `maxLeadMs` out: a far-future anchor
    /// (a skewed clock) starts within 2 s at the position that instant implies.
    func testFarFutureAnchorIsClampedToTheMaxLead() async {
        let (a, b) = await twoDeviceMix()
        a.engine.userLoad(.a, "s1")
        await RemoteTestSupport.waitUntil { b.engine.decks[.a]!.songId == "s1" }
        await barrier(a, b)
        let seq = b.sync.model.hostSeq + 1
        let far = clock.t + 10_000                         // B's clock == the host's (no skew)
        b.link.inject(envelope(MixWireKind.event, MixSyncEventMessage(
            originSeq: 0, origin: "A", hostSeq: seq, epoch: b.sync.model.epoch,
            event: MixSyncEvent(kind: "play", deck: "A", posMs: 50_000,
                                anchor: MixSyncAnchor(positionMs: 50_000, atSharedTime: far, isPlaying: true)))),
                      from: "A")
        await RemoteTestSupport.waitUntil { !b.engine.plays.isEmpty }
        let p = b.engine.plays.last!
        XCTAssertLessThanOrEqual(p.atLocalMs, clock.t + MixSync.maxLeadMs + 0.001)
        XCTAssertEqual(p.fromMs, 50_000 - Int(10_000 - MixSync.maxLeadMs), "sounds where the deck is by then")
        XCTAssertEqual(MixEngine.scheduledLead(desired: 10), MixEngine.maxScheduledLead)
        XCTAssertEqual(MixEngine.scheduledLead(desired: 0), MixEngine.handoverLead)
        XCTAssertEqual(MixEngine.scheduledLead(desired: 0.5), max(0.5, MixEngine.handoverLead))
    }

    /// #14 — a Backseat CONTROLLER's Mix decks never sound: silenced on becoming a controller
    /// and on every tick, every deck start refused through the gate (a speaker's are not).
    func testBackseatControllerSilencesAndGatesTheMixDecks() async {
        let a = device("A"), b = device("B")
        a.engine.decks[.a]!.songId = "s1"
        a.engine.decks[.a]!.isPlaying = true
        a.remote.attach(a.link, mode: .backseat, asHost: true, autoTick: false)
        XCTAssertEqual(a.remote.localRole, .controller)
        XCTAssertFalse(a.engine.decks[.a]!.isPlaying, "silenced as it became the controller")
        a.engine.decks[.a]!.isPlaying = true              // a stray start
        a.remote.tick()
        XCTAssertFalse(a.engine.decks[.a]!.isPlaying, "re-silenced on the tick")
        XCTAssertEqual(a.engine.remoteControllerGate?(.localStart), true, "deck starts refused")
        b.remote.attach(b.link, mode: .backseat, asHost: false, autoTick: false)
        XCTAssertEqual(b.engine.remoteControllerGate?(.localStart), false, "a speaker mixes as usual")
        a.remote.leave()
        XCTAssertEqual(a.engine.remoteControllerGate?(.localStart), false, "outside a session: untouched")
    }

    /// #14 — the real engine: with the gate closed, ▶ (deck / master / scheduled / Auto-DJ)
    /// starts nothing and the system ▶/⏸ go to the session; with it open (nil) nothing changes.
    func testRealEngineControllerGateRefusesEveryStart() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore(lengths: ["x": 6]))
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        var forwarded: [SetlistPlayer.RemoteRedirect] = []
        e.remoteControllerGate = { forwarded.append($0); return true }
        e.play(.a)
        e.playBoth()
        e.play(.a, fromMs: 0, atHostTime: mach_absolute_time())
        e.remotePlay()
        XCTAssertFalse(e.isPlaying(.a))
        XCTAssertFalse(e.isRunning)
        XCTAssertEqual(forwarded, [.localStart, .localStart, .localStart, .setPlaying(true)])
        e.remoteControllerGate = { _ in false }
        e.play(.a)
        XCTAssertTrue(e.isPlaying(.a), "a gate that declines changes nothing")
        e.remoteControllerGate = { _ in true }
        e.silenceForRemoteController()
        XCTAssertFalse(e.isPlaying(.a), "the controller silencer is never gated")
    }

    /// P2-11 — a session that ends with the decks STILL PLAYING keeps them (the music never
    /// dies with the session), but never writes them over the user's saved mix until the user
    /// loads something of their own; emptying the decks brings the saved mix back.
    func testRealEngineSessionEndWhilePlayingProtectsTheSavedMix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-mixsync-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = try MixBurnFixture.burnStore()
        let e = MixEngine(burns: burns)
        e.sessionStore = MixDeckSessionStore(fileURL: url)
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        let store = MixDeckSessionStore(fileURL: url)
        await RemoteTestSupport.waitUntil { store.load()?.deckA?.track.songId == "x" }

        e.syncSessionActive(true)
        e.applyingRemote {
            e.load(songId: "y", title: "T-y", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
            e.play(.a)
        }
        XCTAssertTrue(e.isRunning)
        e.syncSessionActive(false)
        XCTAssertEqual(e.loaded(.a)?.songId, "y", "a playing session deck keeps playing")
        XCTAssertTrue(e.isPlaying(.a))
        let writes = e.persistWritesForTesting
        e.setVolume(0.2, on: .a)
        e.pause(.a)
        XCTAssertEqual(e.persistWritesForTesting, writes, "the session's decks never overwrite the saved mix")
        XCTAssertEqual(store.load()?.deckA?.track.songId, "x")

        // The user empties the decks: their own mix comes back.
        e.clearDeck(.a)
        XCTAssertTrue(e.hasParkedRestore)
        e.materializePendingRestoreIfNeeded()
        XCTAssertEqual(e.loaded(.a)?.songId, "x")

        // A load of the user's own after a session lifts the protection.
        e.syncSessionActive(true)
        e.applyingRemote { e.play(.a) }
        e.syncSessionActive(false)
        XCTAssertTrue(e.postSessionPersistHold)
        e.load(songId: "z", title: "T-z", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .b)
        XCTAssertFalse(e.postSessionPersistHold)
        await RemoteTestSupport.waitUntil { store.load()?.deckB?.track.songId == "z" }
        e.pause(.a)
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
        XCTAssertTrue(e.autoEnabled, "the user's Auto setting comes back when the session ends")
        e.setAutoDJBlocked(MixSync.autoDJBlockedReason)
        e.setAutoEnabled(false)                       // an explicit OFF during the session is remembered
        e.setAutoDJBlocked(nil)
        XCTAssertFalse(e.autoEnabled)
        e.setAutoEnabled(true)
        XCTAssertTrue(e.autoEnabled)
    }

    func testRealEngineSystemTransportIsTaggedAndNeverAUserGesture() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore(lengths: ["x": 6]))
        var taps: [MixEngine.Gesture] = []
        e.gestureTap = { taps.append($0) }
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        e.play(.a)
        e.remotePause()                               // lock screen / CarPlay / an interruption
        e.remotePlay()
        let transport = taps.filter { $0.kind == "play" || $0.kind == "pause" }
        XCTAssertEqual(transport.map(\.kind), ["play", "pause", "play"])
        XCTAssertEqual(transport.map(\.cause), [.user, .system, .system])
        e.caused(.engine) { e.pause(.a) }
        XCTAssertEqual(taps.last?.cause, .engine)
        e.play(.a)
        XCTAssertEqual(taps.last?.cause, .user, "the scope ends with its body")
        e.pause(.a)
    }

    func testRealEngineScheduledStartPastTheFileFallsBackInsteadOfASilentNode() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore(lengths: ["x": 6]))
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        e.play(.a, fromMs: 1_000, atHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3))
        // A start cued past the end schedules NOTHING: the engine must not trust the old schedule
        // (the empty node used to be started as "playing").
        e.play(.a, fromMs: 9_000, atHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3))
        XCTAssertFalse(e.fileScheduledForTesting(.a), "an empty reschedule is never trusted as live")
        XCTAssertEqual(e.position(.a), 6, accuracy: 0.05)
        e.pause(.a)
    }

    func testRealEngineLoopWindowIsSetExactlyAndAScheduledStartKeepsIt() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore(lengths: ["x": 8]))
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        e.seek(.a, toSeconds: 2.2)
        e.syncSetLoop(.a, on: true, units: 2, startMs: 3_000, endMs: 4_000)
        XCTAssertTrue(e.loopOn(.a))
        XCTAssertEqual(e.loopWindowMs(.a)?.start, 3_000, "the OWNER's window — not one around this playhead")
        XCTAssertEqual(e.loopWindowMs(.a)?.end, 4_000)
        // A scheduled (anchored) start on a looping deck: no lead subtracted OUT of the window.
        e.play(.a, fromMs: 3_500, atHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3))
        XCTAssertTrue(e.isPlaying(.a))
        XCTAssertEqual(e.loopWindowMs(.a)?.start, 3_000, "a start never moves the loop")
        XCTAssertEqual(e.loopWindowMs(.a)?.end, 4_000)
        XCTAssertEqual(e.position(.a), 3.2, accuracy: 0.05, "started now at the phase it must have")
        // The same window again is a no-op; release works like the loop button.
        e.syncSetLoop(.a, on: true, units: 2, startMs: 3_000, endMs: 4_000)
        XCTAssertEqual(e.loopWindowMs(.a)?.start, 3_000)
        e.syncSetLoop(.a, on: false, units: nil, startMs: nil, endMs: nil)
        XCTAssertFalse(e.loopOn(.a))
        e.pause(.a)
        XCTAssertEqual(MixEngine.foldIntoLoop(4.25, start: 3, end: 4), 3.25, accuracy: 1e-9)
        XCTAssertEqual(MixEngine.foldIntoLoop(2.75, start: 3, end: 4), 3.75, accuracy: 1e-9)
    }

    func testRealEngineRateNudgeMultipliesAndRestoresTheUsersTempo() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore())
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        e.setRate(1.05, on: .a)
        e.syncNudgeRate(.a, factor: 1.01)
        XCTAssertEqual(e.rateNudgeForTesting(.a) ?? 0, 1.01, accuracy: 1e-9)
        XCTAssertEqual(e.rate(.a), 1.05, accuracy: 1e-9, "the user's tempo is never replaced")
        e.syncNudgeRate(.a, factor: 1.5)
        XCTAssertEqual(e.rateNudgeForTesting(.a) ?? 0, 1.01, accuracy: 1e-9, "clamped to ±1 %")
        e.syncNudgeRate(.a, factor: 1)
        XCTAssertNil(e.rateNudgeForTesting(.a))
        XCTAssertEqual(e.rate(.a), 1.05, accuracy: 1e-9)
    }

    func testRealEngineSetControlsResetsUnlistedAndSeedCarriesTheBoard() throws {
        let e = MixEngine(burns: try MixBurnFixture.burnStore())
        var taps: [MixEngine.Gesture] = []
        e.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        e.setEqGain(.low, -9, on: .a)
        e.setSlot(2, enabled: true, on: .a)
        e.setSlotEffect(.filter, slot: 0, on: .a)
        e.setVolume(0.5, on: .a)
        let seed = e.syncSeedEvents(.a)
        XCTAssertEqual(seed.first?.kind, "load")
        XCTAssertEqual(seed.last?.kind, "pause")
        XCTAssertTrue(seed.contains { $0.kind == "eq" && $0.param == "low" && $0.value == -9 })
        XCTAssertTrue(seed.contains { $0.kind == "effectSlot" && $0.slot == 0 && $0.param == "filter" })
        XCTAssertTrue(seed.contains { $0.kind == "effectToggle" && $0.slot == 2 && $0.flag == true })
        XCTAssertEqual(seed.filter { $0.kind == "effectSlot" }.count, MixEngine.fxSlotCount, "the whole rack")

        e.gestureTap = { taps.append($0) }
        e.syncSetControls(.a, [MixSyncEvent(kind: "volume", deck: "A", value: 0.4),
                               MixSyncEvent(kind: "effectSlot", deck: "A", param: "reverb", slot: 3),
                               MixSyncEvent(kind: "effectToggle", deck: "A", param: "reverb", flag: true, slot: 3)])
        XCTAssertEqual(e.volume(.a), 0.4, accuracy: 1e-9)
        XCTAssertEqual(e.eqGain(.low, on: .a), 0, "an unlisted control goes back to default")
        XCTAssertEqual(e.slot(0, on: .a)?.effect, .compressor, "a local-only rack layout doesn't survive")
        XCTAssertEqual(e.slot(2, on: .a)?.enabled, false)
        XCTAssertEqual(e.slot(3, on: .a)?.effect, .reverb)
        XCTAssertEqual(e.slot(3, on: .a)?.enabled, true)
        XCTAssertTrue(taps.isEmpty, "a reconcile is a remote apply — never tapped back")
    }

    func testRealEngineSessionSuspendsPersistenceAndRefusesAParkedRestore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-mixsync-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = try MixBurnFixture.burnStore()
        let first = MixEngine(burns: burns)
        first.sessionStore = MixDeckSessionStore(fileURL: url)
        first.load(songId: "x", title: "T-x", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .a)
        let store = MixDeckSessionStore(fileURL: url)
        await RemoteTestSupport.waitUntil { store.load()?.deckA?.track.songId == "x" }

        // While mixing together, nothing the session does is written over the user's saved mix.
        first.syncSessionActive(true)
        let writes = first.persistWritesForTesting
        first.load(songId: "y", title: "T-y", artist: "A", bpm: 120, camelot: nil, key: nil, albumId: nil, on: .b)
        first.setVolume(0.2, on: .a)
        XCTAssertEqual(first.persistWritesForTesting, writes, "the durable session is suspended")
        first.syncSessionActive(false)
        // P2-11: the session's decks (y on B) are NOT what the next gesture persists — the
        // user's own mix comes back (parked, materialized by the Mix surface as at launch).
        XCTAssertNil(first.loaded(.b), "the session's deck is cleared")
        XCTAssertTrue(first.hasParkedRestore)
        first.materializePendingRestoreIfNeeded()
        XCTAssertEqual(first.loaded(.a)?.songId, "x")
        XCTAssertNil(first.loaded(.b))
        XCTAssertEqual(store.load()?.deckA?.track.songId, "x")
        XCTAssertNil(store.load()?.deckB, "the saved mix on disk was never touched")
        first.setVolume(0.3, on: .a)
        XCTAssertGreaterThan(first.persistWritesForTesting, writes, "…and persistence resumes after")

        // A parked launch restore never lands on the session's decks.
        let second = MixEngine(burns: burns)
        second.sessionStore = store
        second.restorePersistedMixIfIdle()
        XCTAssertTrue(second.hasParkedRestore)
        second.syncSessionActive(true)
        XCTAssertFalse(second.hasParkedRestore, "a session start discards the parked restore")
        second.materializePendingRestoreIfNeeded()
        XCTAssertNil(second.loaded(.a))
    }
}
