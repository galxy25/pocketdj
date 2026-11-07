import AVFoundation
import Foundation
import Observation

/// One deck as the multiplayer layer reads it off THIS device's engine.
struct MixSyncDeckStatus: Equatable {
    /// The LOCAL song id on the deck (nil = empty).
    var songId: String?
    var isPlaying: Bool
    /// The audible playhead (source ms) — the render clock when it has one.
    var playheadMs: Int
    var durationMs: Int
    var rate: Double
    /// Loaded and not waiting on bytes.
    var ready: Bool
    /// A loop (∞) is engaged — its playhead wraps, so drift against a linear anchor is meaningless.
    var looping: Bool = false
}

/// The engine surface `MixSync` drives — `MixEngine` in the app, a fake in the unit tests. Every
/// mutating call here is applied as a REMOTE event (the engine's `applyingRemote` guard: no
/// gesture tap, no session-log record), so nothing echoes back onto the wire.
@MainActor
protocol MixSyncEngine: AnyObject {
    /// Local gestures (set by `MixSync`).
    var gestureTap: ((MixEngine.Gesture) -> Void)? { get set }
    func syncStatus(_ deck: MixEngine.Deck) -> MixSyncDeckStatus
    func syncLoad(_ item: MixLoadable, on deck: MixEngine.Deck)
    func syncEject(_ deck: MixEngine.Deck)
    /// Start `deck` from `fromMs` at the LOCAL wall-clock instant `atLocalMs` (epoch ms).
    func syncPlay(_ deck: MixEngine.Deck, fromMs: Int, atLocalMs: Double)
    /// Pause `deck` and cue it at `atMs`.
    func syncPause(_ deck: MixEngine.Deck, atMs: Int)
    /// A non-transport event (tempo, FX, EQ, stems, loop, lead, ↺, crossfader…).
    func syncApplyControl(_ event: MixSyncEvent)
    /// What a fresh session should start from: this device's decks as events (load, controls,
    /// transport). The host seeds the mix with them when it starts one over decks already loaded.
    func syncSeedEvents(_ deck: MixEngine.Deck) -> [MixSyncEvent]
    var syncCrossfader: Double { get }
    func setAutoDJBlocked(_ reason: String?)
}

/// MULTIPLAYER MIX over a SharePlay Remote session (Phase 2) — two decks, several DJs, every
/// device rendering both decks LOCALLY from shared state. Never streams audio.
///
/// AUTHORITY. The Remote session's host orders everything. A participant's gesture is a
/// PROPOSAL (`mix.event`, no host sequence) → the host validates it (ownership) → assigns the
/// next host sequence number → rebroadcasts it → every device (the host included) applies ordered
/// events strictly in host order. Every device mirrors the authoritative `MixSyncModel` from that
/// stream, so any device can answer a joiner or take over as host.
///
/// OWNERSHIP. Each deck has an owner (a participant id) or is free. Default: the host takes Deck
/// A, the first joiner Deck B. A participant can claim a free deck or release theirs; the
/// crossfader is shared. Only a deck's owner's gestures are accepted; a local gesture on a deck
/// you don't own (master ▶, the lock screen) is undone from the mirror on the next tick.
///
/// NO ECHO. A gesture is applied locally the instant it happens (the DJ never waits a round
/// trip) and its echo is skipped. A sender's own un-echoed proposal on a control shadows
/// another sender's earlier-ordered value on the SAME control (the sender's will be ordered
/// after it and win), so two hands on the crossfader converge on host order instead of jittering.
///
/// TIMING. Transport events carry a shared-clock anchor {positionMs, atSharedTime, isPlaying}.
/// The host re-anchors a start / seek `startLeadMs` into the future; each device converts the
/// shared instant to its own clock (`SharedClock`) and starts the deck there with the engine's
/// scheduled start (`MixEngine.play(_:fromMs:atHostTime:)` — stems together on one sample
/// frame). A play waits for the owner's device to report the deck READY (≤ `readyTimeoutMs`);
/// late devices catch up with a position-corrected start. The owner's device sends a heartbeat
/// every `heartbeatMs`; others re-seek when off by more than `driftThresholdMs` (cooldown
/// `driftCooldownMs`).
///
/// LOCAL ONLY: cue / PFL, the meter source, recording, and the session log (a remote DJ's
/// gestures are not recorded as yours). The Auto-DJ is disabled while a mix session is active.
@MainActor
@Observable
final class MixSync {

    // MARK: Tunables

    static let tickInterval: Double = 250
    /// How far in the future the host anchors a start / seek so every device can hit it.
    static let startLeadMs: Double = 300
    /// The closest a device will schedule a start (a late anchor is position-corrected instead).
    static let minLeadMs: Double = 60
    static let heartbeatMs: Double = 2_000
    static let driftThresholdMs = 40
    static let driftCooldownMs: Double = 4_000
    /// A heartbeat older than this (shared time) is not trusted for a correction.
    static let staleBeatMs: Double = 1_500
    /// The host broadcasts a held play this long after it arrived even if the owner never
    /// reported ready (others then start late and the heartbeat corrects them).
    static let readyTimeoutMs: Double = 4_000
    /// A hole in the host sequence this old ⇒ ask for a snapshot.
    static let gapTimeoutMs: Double = 1_500
    static let snapshotRetryMs: Double = 3_000
    static let autoDJBlockedReason = "Auto DJ is off while you mix together."

    // MARK: Observable state

    private(set) var isActive = false
    private(set) var model = MixSyncModel()
    /// Decks whose session song can't be mixed on THIS device → that song's title.
    private(set) var unavailable: [MixEngine.Deck: String] = [:]
    /// Each peer's per-deck readiness (`mix.ready`), keyed peer id → deck rawValue.
    private(set) var peerReadiness: [String: [String: MixSyncReady]] = [:]
    var statusMessage: String?

    // MARK: Dependencies

    @ObservationIgnored let remote: RemoteSessionController
    @ObservationIgnored let engine: MixSyncEngine
    /// A session song → something THIS device can put on a deck (nil = not mixable here).
    @ObservationIgnored var resolve: (MixSyncEvent) -> MixLoadable?
    /// The Apple Music store id the local catalog knows for a song (stamped onto outbound loads).
    @ObservationIgnored var appleMusicIdForSong: (String) -> String? = { _ in nil }

    // MARK: Internals

    @ObservationIgnored private var nextOriginSeq = 1
    /// controlKey → my latest un-echoed proposal's originSeq.
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var expectedHostSeq = 1
    @ObservationIgnored private var buffer: [Int: MixSyncEventMessage] = [:]
    @ObservationIgnored private var gapSince: Double?
    @ObservationIgnored private var awaitingSnapshotSince: Double?
    @ObservationIgnored private var lastRequestAt: Double = -.infinity
    /// Host: a playing transport waiting for its owner's device to be ready.
    @ObservationIgnored private var held: [MixEngine.Deck: (msg: MixSyncEventMessage, from: String, since: Double)] = [:]
    @ObservationIgnored private var lastBeatAt: [MixEngine.Deck: Double] = [:]
    @ObservationIgnored private var lastDriftFixAt: [MixEngine.Deck: Double] = [:]
    /// The SESSION song id each deck currently mirrors on this device (nil = nothing loaded for it).
    @ObservationIgnored private var localSong: [MixEngine.Deck: String] = [:]
    @ObservationIgnored private var reportedReady: [MixEngine.Deck: MixSyncReady] = [:]
    @ObservationIgnored private var repairQueue: Set<MixEngine.Deck> = []
    @ObservationIgnored private var lastHostId: String?
    @ObservationIgnored private var lastRoster: Set<String> = []
    /// My clock offset to the CURRENT host, kept across ticks — a hand-over re-anchors the mirror
    /// onto my own clock with it (the controller has already reset the samples by then).
    @ObservationIgnored private var lastOffset: Double?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Test seam: drift corrections made per deck.
    @ObservationIgnored private(set) var driftFixCount: [MixEngine.Deck: Int] = [:]

    init(remote: RemoteSessionController, engine: MixSyncEngine,
         resolve: @escaping (MixSyncEvent) -> MixLoadable?, autoTick: Bool = true) {
        self.remote = remote
        self.engine = engine
        self.resolve = resolve
        remote.registerHandler(kind: MixWireKind.event) { [weak self] env, from in self?.receiveEvent(env, from: from) }
        remote.registerHandler(kind: MixWireKind.snapshot) { [weak self] env, from in self?.receiveSnapshot(env, from: from) }
        remote.registerHandler(kind: MixWireKind.request) { [weak self] env, from in self?.receiveRequest(env, from: from) }
        remote.registerHandler(kind: MixWireKind.ready) { [weak self] env, from in self?.receiveReady(env, from: from) }
        remote.registerHandler(kind: MixWireKind.beat) { [weak self] env, from in self?.receiveBeat(env, from: from) }
        remote.registerHandler(kind: MixWireKind.reject) { [weak self] env, from in self?.receiveReject(env, from: from) }
        // A live Mix Together is session ACTIVITY: the host election never yields it to an empty host.
        remote.registerActivityProbe { [weak self] in self?.isActive == true }
        engine.gestureTap = { [weak self] g in self?.localGesture(g) }
        if autoTick {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000))
                }
            }
        }
    }

    private var now: Double { remote.clock.localNow() }
    private var localId: String? { remote.localId }
    private var isHost: Bool { remote.isHost }

    // MARK: - UI surface

    /// The Remote tab may offer "Mix together": a live Listen Together session this device hosts.
    var canStart: Bool { remote.isActive && isHost && remote.mode == .listenTogether && !isActive }

    /// Why "Mix together" can't start here (nil = it can, or a mix is already running).
    var startBlockedReason: String? {
        guard remote.isActive, !isActive else { return nil }
        if remote.mode == .backseat { return "Mixing together needs Listen Together — in Backseat only the car plays." }
        if !isHost { return "Only the session host can start a mix." }
        return nil
    }

    /// May THIS device's gestures drive `deck`? (Always, outside a mix session.)
    func canControl(_ deck: MixEngine.Deck) -> Bool {
        !isActive || (localId != nil && model.owner(of: deck) == localId)
    }

    func owner(of deck: MixEngine.Deck) -> String? { model.owner(of: deck) }
    var myDecks: [MixEngine.Deck] { localId.map { model.decks(ownedBy: $0) } ?? [] }

    /// A participant's display name ("You" for this device).
    func name(of id: String) -> String {
        if id == localId { return "You" }
        return remote.peers.first { $0.id == id }?.name ?? "Someone"
    }

    /// "Deck B · Sam’s iPhone", nil when free / outside a session.
    func ownerLabel(_ deck: MixEngine.Deck) -> String? {
        guard isActive else { return nil }
        guard let o = model.owner(of: deck) else { return "Free" }
        return name(of: o)
    }

    var participantNames: [String] { remote.peers.map { $0.isLocal ? "You" : $0.name } }

    /// The devices that can't mix `deck`'s song.
    func unavailableDevices(_ deck: MixEngine.Deck) -> [String] {
        var out: [String] = []
        if unavailable[deck] != nil { out.append("this device") }
        for (peer, decks) in peerReadiness where peer != localId && decks[deck.rawValue]?.status == .unavailable {
            out.append(name(of: peer))
        }
        return out
    }

    // MARK: - Session lifecycle (host)

    /// HOST: start mixing together inside the current Listen Together session. The host takes
    /// Deck A, the first other participant Deck B; decks already loaded here seed the mix.
    func start() {
        guard canStart, let me = localId else { return }
        checkTopology()
        let seq = model.hostSeq
        model = MixSyncModel()
        model.epoch = me
        model.hostSeq = seq
        hostOrder(MixSyncEvent(kind: MixSyncKind.session, deck: nil, flag: true), origin: me)
        hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: "A", owner: me), origin: me)
        for d in MixEngine.Deck.allCases {
            for var e in engine.syncSeedEvents(d) {
                if e.kind == MixSyncKind.load, let sid = e.songId { e.appleMusicId = appleMusicIdForSong(sid); localSong[d] = sid }
                hostOrder(e, origin: me)
            }
        }
        hostOrder(MixSyncEvent(kind: MixSyncKind.crossfader, deck: nil, value: engine.syncCrossfader), origin: me)
        autoAssignB()
        // The Listen Together set yields the speakers to the decks (one audio owner).
        remote.send(.setPlaying(false))
        DiagLog.shared.telemetry("action", "mix together start")
    }

    /// HOST: end the mix session (every device keeps its decks, back to solo mixing).
    func end() {
        guard isActive, isHost, let me = localId else { return }
        hostOrder(MixSyncEvent(kind: MixSyncKind.session, deck: nil, flag: false), origin: me)
        DiagLog.shared.telemetry("action", "mix together end")
    }

    func claim(_ deck: MixEngine.Deck) { propose(MixSyncEvent(kind: MixSyncKind.claim, deck: deck.rawValue)) }
    func release(_ deck: MixEngine.Deck) { propose(MixSyncEvent(kind: MixSyncKind.release, deck: deck.rawValue)) }

    private func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            engine.setAutoDJBlocked(Self.autoDJBlockedReason)
            statusMessage = nil
        } else {
            engine.setAutoDJBlocked(nil)
            unavailable = [:]
            peerReadiness = [:]
            held = [:]
            pending = [:]
            repairQueue = []
            reportedReady = [:]
        }
    }

    /// The Remote session is gone: the mix ends here (decks keep playing locally).
    private func resetAll() {
        setActive(false)
        let seq = model.hostSeq
        model = MixSyncModel()
        model.hostSeq = seq
        lastHostId = nil
        lastRoster = []
        lastOffset = nil
        buffer = [:]
        gapSince = nil
        awaitingSnapshotSince = nil
        localSong = [:]
        expectedHostSeq = 1
    }

    // MARK: - Tick

    /// One heartbeat (0.25 s in production; tests call it directly): topology, readiness
    /// reports, held plays, repairs, sequence gaps, the deck heartbeat.
    func tick() {
        checkTopology()
        guard remote.isActive else { return }
        let t = now
        if !isHost {
            if let since = gapSince, t - since >= Self.gapTimeoutMs { requestSnapshot("gap") }
            if awaitingSnapshotSince != nil, t - lastRequestAt >= Self.snapshotRetryMs { requestSnapshot("retry") }
        }
        guard isActive else { return }
        for d in MixEngine.Deck.allCases { reportReadiness(d) }
        if isHost {
            for (d, h) in held where t - h.since >= Self.readyTimeoutMs { releaseHeld(d) }
        }
        let repairs = repairQueue
        repairQueue = []
        for d in repairs.sorted(by: { $0.rawValue < $1.rawValue }) { reconcileDeck(d) }
        sendHeartbeats(at: t)
    }

    /// Follow the Remote session's host / roster (the controller owns election; we follow it).
    private func checkTopology() {
        guard remote.isActive, let me = localId else {
            if isActive || lastHostId != nil { resetAll() }
            return
        }
        let host = remote.hostId
        if host != lastHostId {
            let previous = lastHostId
            lastHostId = host
            pending = [:]
            held = [:]
            buffer = [:]
            gapSince = nil
            if isHost {
                if previous != nil { takeOver(me) } else { model.epoch = me }
            } else if host != nil {
                requestSnapshot("host")
            }
        }
        if !isHost, let host, remote.clock.hostId == host, let off = remote.clock.offsetMs { lastOffset = off }
        let roster = remote.roster
        if roster != lastRoster {
            let gone = lastRoster.subtracting(roster)
            lastRoster = roster
            if isHost, model.active {
                for d in MixEngine.Deck.allCases {
                    if let o = model.owner(of: d), gone.contains(o) || !roster.contains(o) {
                        hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: d.rawValue, owner: nil), origin: me)
                    }
                }
                autoAssignB()
            }
            for g in gone { peerReadiness[g] = nil }
        }
    }

    /// HAND-OVER: the old host left and the Remote controller elected me. My mirror becomes the
    /// authority — re-anchored from the old host's timeline onto my own clock (the new shared
    /// timeline), departed owners' decks freed, the sequence continued — then broadcast whole.
    private func takeOver(_ me: String) {
        let off = lastOffset ?? 0
        model.epoch = me
        for d in MixEngine.Deck.allCases {
            guard var ds = model.decks[d] else { continue }
            if var a = ds.anchor, let at = a.atSharedTime { a.atSharedTime = at - off; ds.anchor = a }
            if let o = ds.owner, !remote.roster.contains(o) { ds.owner = nil }
            model.decks[d] = ds
        }
        lastOffset = nil
        DiagLog.shared.log("remote", "mix hand-over → \(me) seq=\(model.hostSeq) active=\(model.active)")
        if model.active { post(MixWireKind.snapshot, model.snapshot(), to: .all) }
    }

    /// The first joiner gets Deck B (once per session — a released B stays free until claimed).
    private func autoAssignB() {
        guard isHost, model.active, !model.assignedB, model.owner(of: .b) == nil, let me = localId,
              let first = remote.roster.sorted().first(where: { $0 != me && model.decks(ownedBy: $0).isEmpty })
        else { return }
        hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: "B", owner: first), origin: me)
    }

    // MARK: - Local gestures → proposals

    private func localGesture(_ g: MixEngine.Gesture) {
        guard isActive, let me = localId else { return }
        var e = MixSyncEvent(kind: g.kind, deck: g.deck?.rawValue, param: g.param, value: g.value,
                             flag: g.flag, slot: g.slot, posMs: g.posMs)
        if g.kind == MixSyncKind.crossfader { propose(e); return }
        guard let d = g.deck else { return }          // auto-DJ markers etc. — not shared
        guard model.owner(of: d) == me else {
            // Not my deck: the gesture is undone from the mirror next tick. A deck that simply
            // ran out of track isn't a gesture at all.
            let st = engine.syncStatus(d)
            if g.kind == MixSyncKind.pause, st.durationMs > 0, st.playheadMs >= st.durationMs - 500 { return }
            repairQueue.insert(d)
            return
        }
        switch g.kind {
        case MixSyncKind.load:
            guard let t = g.track else { return }
            e.songId = t.songId; e.title = t.title; e.artist = t.artist
            e.bpm = t.bpm; e.camelot = t.camelot; e.key = t.key; e.albumId = t.albumId
            e.lengthMs = g.lengthMs
            e.appleMusicId = appleMusicIdForSong(t.songId)
            localSong[d] = t.songId
            unavailable[d] = nil
        case MixSyncKind.eject:
            localSong[d] = nil
            unavailable[d] = nil
        case MixSyncKind.play, MixSyncKind.pause, MixSyncKind.seek:
            let st = engine.syncStatus(d)
            e.anchor = MixSyncAnchor(positionMs: st.playheadMs, atSharedTime: remote.clock.sharedNow,
                                     isPlaying: st.isPlaying)
        default:
            break
        }
        propose(e)
        if g.kind == MixSyncKind.load || g.kind == MixSyncKind.eject { reportReadiness(d) }
    }

    private func propose(_ e: MixSyncEvent) {
        guard isActive, let me = localId else { return }
        let seq = nextOriginSeq
        nextOriginSeq += 1
        let msg = MixSyncEventMessage(originSeq: seq, event: e)
        if isHost { handleProposal(msg, from: me); return }
        guard let host = remote.hostId else { statusMessage = "Waiting for the session host…"; return }
        if e.kind != MixSyncKind.claim, e.kind != MixSyncKind.release { pending[e.controlKey] = seq }
        post(MixWireKind.event, msg, to: .participant(host))
    }

    // MARK: - Host: validate + order

    private func handleProposal(_ msg: MixSyncEventMessage, from: String) {
        let e = msg.event
        func reject(_ reason: String) {
            DiagLog.shared.log("remote", "mix reject \(e.kind) deck=\(e.deck ?? "-") from=\(from): \(reason)")
            if from == localId {
                statusMessage = reason
                if let d = e.engineDeck { repairQueue.insert(d) }
            } else {
                post(MixWireKind.reject, MixSyncReject(originSeq: msg.originSeq, reason: reason), to: .participant(from))
                post(MixWireKind.snapshot, model.snapshot(), to: .participant(from))
            }
        }
        guard model.active else { return reject("No mix session is running.") }
        switch e.kind {
        case MixSyncKind.session, MixSyncKind.owner:
            reject("Only the host can do that.")
        case MixSyncKind.claim:
            guard let d = e.engineDeck else { return }
            if let o = model.owner(of: d) { return reject("Deck \(d.rawValue) belongs to \(name(of: o)).") }
            hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: d.rawValue, owner: from),
                      origin: from, originSeq: msg.originSeq)
        case MixSyncKind.release:
            guard let d = e.engineDeck, model.owner(of: d) == from else { return reject("That deck isn’t yours.") }
            hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: d.rawValue, owner: nil),
                      origin: from, originSeq: msg.originSeq)
        case MixSyncKind.crossfader:
            hostOrder(e, origin: from, originSeq: msg.originSeq)
        default:
            guard let d = e.engineDeck else { return }
            guard model.owner(of: d) == from else {
                let who = model.owner(of: d).map { name(of: $0) } ?? "nobody — claim it first"
                return reject("Deck \(d.rawValue) belongs to \(who).")
            }
            hostOrder(e, origin: from, originSeq: msg.originSeq)
        }
    }

    /// HOST: stamp + order one event — re-anchor a start into the future, hold a start until the
    /// owner's device is ready, fold it into the model, broadcast it, apply it here.
    private func hostOrder(_ event: MixSyncEvent, origin: String, originSeq: Int = 0, bypassReadiness: Bool = false) {
        guard isHost else { return }
        var e = event
        let t = now                                   // the host's clock IS the shared clock
        if let d = e.engineDeck, e.isTransport || e.kind == MixSyncKind.load || e.kind == MixSyncKind.eject {
            held[d] = nil                             // a newer transport supersedes a held start
        }
        if e.isTransport, var a = e.anchor {
            if a.atSharedTime == nil { a.atSharedTime = t }
            if a.isPlaying, let d = e.engineDeck {
                if !bypassReadiness, !ownerReady(d) {
                    e.anchor = a
                    held[d] = (MixSyncEventMessage(originSeq: originSeq, origin: origin, event: e), origin, t)
                    return
                }
                let target = max(a.atSharedTime ?? t, t + Self.startLeadMs)
                a = MixSyncAnchor(positionMs: a.position(at: target, rate: model.deck(d).rate),
                                  atSharedTime: target, isPlaying: true)
            }
            e.anchor = a
        }
        model.hostSeq += 1
        let msg = MixSyncEventMessage(originSeq: originSeq, origin: origin, hostSeq: model.hostSeq,
                                      epoch: model.epoch, event: e)
        model.apply(e, sharedNow: t)
        post(MixWireKind.event, msg, to: .all)
        applyOrdered(msg)
    }

    private func releaseHeld(_ d: MixEngine.Deck) {
        guard let h = held.removeValue(forKey: d) else { return }
        hostOrder(h.msg.event, origin: h.from, originSeq: h.msg.originSeq, bypassReadiness: true)
    }

    /// Can the deck's OWNER device sound its current song (so a start can go out)?
    private func ownerReady(_ d: MixEngine.Deck) -> Bool {
        guard let sid = model.deck(d).track?.songId else { return true }
        let owner = model.owner(of: d) ?? localId
        if owner == localId { return localSong[d] == sid && engine.syncStatus(d).ready }
        guard let owner, let r = peerReadiness[owner]?[d.rawValue], r.songId == sid else { return false }
        return r.status != .loading
    }

    // MARK: - Inbound

    private func receiveEvent(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard let msg = env.decode(MixSyncEventMessage.self) else { return }
        if let seq = msg.hostSeq {
            guard !isHost, from == remote.hostId else { return }
            if awaitingSnapshotSince != nil { buffer[seq] = msg; return }
            guard msg.epoch == model.epoch else { buffer[seq] = msg; requestSnapshot("epoch"); return }
            guard seq >= expectedHostSeq else { return }      // duplicate
            buffer[seq] = msg
            drain()
        } else if isHost {
            handleProposal(msg, from: from)
        }
    }

    /// Apply buffered ordered events strictly in host order.
    private func drain() {
        while let m = buffer.removeValue(forKey: expectedHostSeq) {
            model.apply(m.event, sharedNow: remote.clock.sharedNow ?? now)
            model.hostSeq = expectedHostSeq
            expectedHostSeq += 1
            applyOrdered(m)
        }
        gapSince = buffer.isEmpty ? nil : (gapSince ?? now)
    }

    private func receiveSnapshot(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard !isHost, from == remote.hostId, let s = env.decode(MixSyncSnapshot.self) else { return }
        model = MixSyncModel(s)
        expectedHostSeq = s.hostSeq + 1
        awaitingSnapshotSince = nil
        pending = [:]
        buffer = buffer.filter { $0.key > s.hostSeq && $0.value.epoch == s.epoch }
        setActive(s.active)
        if s.active {
            if let x = s.crossfader, abs(engine.syncCrossfader - x) > 1e-6 {
                engine.syncApplyControl(MixSyncEvent(kind: MixSyncKind.crossfader, deck: nil, value: x))
            }
            for d in MixEngine.Deck.allCases { reconcileDeck(d) }
        }
        drain()
    }

    private func receiveRequest(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard isHost else { return }
        post(MixWireKind.snapshot, model.snapshot(), to: .participant(from))
    }

    private func receiveReady(_ env: RemoteEnvelope, from: String) {
        guard let r = env.decode(MixSyncReady.self) else { return }
        peerReadiness[from, default: [:]][r.deck] = r
        if isHost, let d = MixEngine.Deck(rawValue: r.deck), held[d] != nil, ownerReady(d) { releaseHeld(d) }
    }

    private func receiveReject(_ env: RemoteEnvelope, from: String) {
        guard from == remote.hostId, let r = env.decode(MixSyncReject.self) else { return }
        pending = pending.filter { $0.value != r.originSeq }
        statusMessage = r.reason
        // The host's snapshot follows and puts the deck back.
    }

    private func receiveBeat(_ env: RemoteEnvelope, from: String) {
        guard isActive, let b = env.decode(MixSyncBeat.self), b.epoch == model.epoch,
              let d = MixEngine.Deck(rawValue: b.deck), from != localId,
              from == (model.owner(of: d) ?? remote.hostId) else { return }
        if isHost, model.deck(d).track?.songId == b.songId { model.decks[d]?.anchor = b.anchor }
        driftCheck(d, b.anchor, songId: b.songId)
    }

    // MARK: - Apply (every device, host order)

    private func applyOrdered(_ msg: MixSyncEventMessage) {
        let e = msg.event
        switch e.kind {
        case MixSyncKind.session:
            setActive(e.flag ?? false)
            if isActive, !isHost { for d in MixEngine.Deck.allCases { reconcileDeck(d) } }
            return
        case MixSyncKind.owner:
            return                                     // the model already moved; the UI follows it
        default:
            break
        }
        guard isActive else { return }
        let key = e.controlKey
        if msg.origin == localId {
            // My own gesture, already applied locally. Clear its pending mark unless a newer one
            // on the same control is still in flight.
            if let p = pending[key], p > msg.originSeq { return }
            pending[key] = nil
            return
        }
        // My newer proposal on this control is in flight and will be ordered after this one.
        if pending[key] != nil { return }
        applyToEngine(e)
    }

    private func applyToEngine(_ e: MixSyncEvent) {
        guard let d = e.engineDeck else {
            if e.kind == MixSyncKind.crossfader { engine.syncApplyControl(e) }
            return
        }
        switch e.kind {
        case MixSyncKind.load:
            loadLocally(d, e)
        case MixSyncKind.eject:
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            unavailable[d] = nil
            reportReadiness(d)
        case MixSyncKind.play, MixSyncKind.pause, MixSyncKind.seek:
            if let a = e.anchor { applyAnchor(d, a) }
        default:
            guard localSong[d] != nil else { return }  // nothing here to apply it to (unavailable)
            engine.syncApplyControl(e)
        }
    }

    /// Put the session's song for `d` on this device's deck — or, when this device can't mix it,
    /// leave the deck EMPTY (silent for it) and say so.
    private func loadLocally(_ d: MixEngine.Deck, _ e: MixSyncEvent) {
        guard let loadable = resolve(e) else {
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            unavailable[d] = e.title ?? "This song"
            reportReadiness(d)
            DiagLog.shared.log("remote", "mix deck \(d.rawValue): \(e.songId ?? "-") not mixable here")
            return
        }
        if engine.syncStatus(d).songId != loadable.songId { engine.syncLoad(loadable, on: d) }
        localSong[d] = e.songId
        unavailable[d] = nil
        reportReadiness(d)
    }

    /// Make the deck match the mirror (a joiner, a snapshot, a refused / stray local gesture).
    private func reconcileDeck(_ d: MixEngine.Deck) {
        guard isActive else { return }
        let ds = model.deck(d)
        guard let t = ds.track else {
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            unavailable[d] = nil
            reportReadiness(d)
            return
        }
        loadLocally(d, t)
        guard localSong[d] != nil else { return }
        for c in ds.controls { engine.syncApplyControl(c) }
        // A looping deck's playhead wraps: re-seeking it to a linear anchor would MOVE the loop.
        if let a = ds.anchor, !(a.isPlaying && engine.syncStatus(d).looping) { applyAnchor(d, a) }
    }

    /// Drive the deck to the anchor: start at the shared instant (position-corrected when that
    /// instant is already too close), or pause + cue. No-op when the deck already matches within
    /// the drift threshold — applying the same state twice never re-seeks.
    private func applyAnchor(_ d: MixEngine.Deck, _ a: MixSyncAnchor) {
        let st = engine.syncStatus(d)
        guard st.songId != nil else { return }
        let t = now
        if a.isPlaying {
            guard let at = a.atSharedTime, let localAt = remote.clock.localTime(forShared: at) else {
                // No shared clock yet: start now from the anchor (the heartbeat corrects later).
                if !st.isPlaying { engine.syncPlay(d, fromMs: a.positionMs, atLocalMs: t) }
                return
            }
            if st.isPlaying {
                let expected = a.positionMs + Int(((t - localAt) * st.rate).rounded())
                if abs(st.playheadMs - expected) <= Self.driftThresholdMs { return }
            }
            let start = max(localAt, t + Self.minLeadMs)
            let pos = a.positionMs + Int(((start - localAt) * st.rate).rounded())
            if st.durationMs > 0, pos >= st.durationMs - 100 {
                engine.syncPause(d, atMs: st.durationMs)   // the track already ended there
                return
            }
            engine.syncPlay(d, fromMs: max(0, pos), atLocalMs: start)
        } else {
            if !st.isPlaying, abs(st.playheadMs - a.positionMs) <= Self.driftThresholdMs { return }
            engine.syncPause(d, atMs: a.positionMs)
        }
    }

    // MARK: - Drift

    private func sendHeartbeats(at t: Double) {
        guard let me = localId, let shared = remote.clock.sharedNow else { return }
        for d in MixEngine.Deck.allCases {
            let mine = model.owner(of: d) == me || (model.owner(of: d) == nil && isHost)
            guard mine, let sid = model.deck(d).track?.songId, localSong[d] == sid,
                  t - (lastBeatAt[d] ?? -.infinity) >= Self.heartbeatMs else { continue }
            let st = engine.syncStatus(d)
            guard st.songId != nil else { continue }
            lastBeatAt[d] = t
            let a = MixSyncAnchor(positionMs: st.playheadMs, atSharedTime: shared, isPlaying: st.isPlaying)
            if isHost { model.decks[d]?.anchor = a }     // snapshots stay fresh for joiners
            post(MixWireKind.beat, MixSyncBeat(deck: d.rawValue, songId: sid, anchor: a, epoch: model.epoch),
                 to: .all, reliable: false)
        }
    }

    /// A heartbeat from the deck's owner: re-seek (or fix ▶/⏸) when this device is off by more
    /// than the threshold — against a clock measured on THIS host, a fresh beat, and never more
    /// often than the cooldown (hysteresis: a correction's own settling is not chased).
    private func driftCheck(_ d: MixEngine.Deck, _ a: MixSyncAnchor, songId: String) {
        guard isActive, model.deck(d).track?.songId == songId, localSong[d] == songId,
              remote.clock.isSynced, isHost || remote.clock.hostId == remote.hostId,
              let at = a.atSharedTime, let shared = remote.clock.sharedNow,
              shared - at <= Self.staleBeatMs else { return }
        let t = now
        guard t - (lastDriftFixAt[d] ?? -.infinity) >= Self.driftCooldownMs else { return }
        let st = engine.syncStatus(d)
        guard st.songId != nil, !st.looping else { return }
        if a.isPlaying == st.isPlaying {
            guard a.isPlaying else { return }
            let expected = a.position(at: shared, rate: st.rate)
            if st.durationMs > 0, expected >= st.durationMs - 250 { return }
            guard abs(st.playheadMs - expected) > Self.driftThresholdMs else { return }
        }
        lastDriftFixAt[d] = t
        driftFixCount[d, default: 0] += 1
        DiagLog.shared.log("remote", "mix drift deck \(d.rawValue): local=\(st.playheadMs) playing=\(st.isPlaying) → anchor")
        applyAnchor(d, a)
    }

    // MARK: - Readiness

    private func readiness(_ d: MixEngine.Deck) -> MixSyncReady {
        let sid = model.deck(d).track?.songId
        guard let sid else { return MixSyncReady(deck: d.rawValue, songId: nil, status: .empty) }
        if unavailable[d] != nil || localSong[d] != sid {
            return MixSyncReady(deck: d.rawValue, songId: sid, status: unavailable[d] != nil ? .unavailable : .loading)
        }
        return MixSyncReady(deck: d.rawValue, songId: sid, status: engine.syncStatus(d).ready ? .ready : .loading)
    }

    private func reportReadiness(_ d: MixEngine.Deck) {
        guard isActive, let me = localId else { return }
        let r = readiness(d)
        guard reportedReady[d] != r else { return }
        reportedReady[d] = r
        peerReadiness[me, default: [:]][d.rawValue] = r
        post(MixWireKind.ready, r, to: .all)
        if isHost, held[d] != nil, ownerReady(d) { releaseHeld(d) }
    }

    // MARK: - Outbound

    private func requestSnapshot(_ reason: String) {
        guard !isHost, let host = remote.hostId else { return }
        awaitingSnapshotSince = awaitingSnapshotSince ?? now
        lastRequestAt = now
        post(MixWireKind.request, MixSyncRequest(reason: reason), to: .participant(host))
    }

    private func post<T: Encodable>(_ kind: String, _ body: T, to: RemoteRecipient, reliable: Bool = true) {
        guard let payload = try? JSONEncoder().encode(body) else { return }
        remote.sendRaw(RemoteEnvelope(v: RemoteWire.version, kind: kind, payload: payload), to: to, reliable: reliable)
    }
}

// MARK: - The app's engine

extension MixEngine: MixSyncEngine {
    func syncStatus(_ deck: Deck) -> MixSyncDeckStatus {
        let l = loaded(deck)
        return MixSyncDeckStatus(songId: l?.songId, isPlaying: isPlaying(deck),
                                 playheadMs: Int((audiblePlayhead(deck) * 1000).rounded()),
                                 durationMs: Int((duration(deck) * 1000).rounded()), rate: rate(deck),
                                 ready: l != nil && !isBuffering(deck), looping: loopOn(deck))
    }

    func syncLoad(_ item: MixLoadable, on deck: Deck) {
        applyingRemote {
            load(songId: item.songId, title: item.title, artist: item.artist, bpm: item.bpm,
                 camelot: item.camelot, key: item.key, albumId: item.albumId, lengthMs: item.lengthMs, on: deck)
        }
    }

    func syncEject(_ deck: Deck) {
        // Cue / PFL is per device — an eject the session asked for must not drop this DJ's cue.
        let cue = cued(deck), cueVol = cueVolume(deck)
        applyingRemote { clearDeck(deck) }
        setCued(cue, on: deck)
        setCueVolume(cueVol, on: deck)
    }

    func syncPlay(_ deck: Deck, fromMs: Int, atLocalMs: Double) {
        let host = Self.hostTime(forLocalMs: atLocalMs, nowLocalMs: Date().timeIntervalSince1970 * 1000,
                                 nowHost: mach_absolute_time())
        applyingRemote { play(deck, fromMs: fromMs, atHostTime: host) }
    }

    func syncPause(_ deck: Deck, atMs: Int) {
        applyingRemote {
            if isPlaying(deck) { pause(deck) }
            if abs(position(deck) * 1000 - Double(atMs)) > Double(MixSync.driftThresholdMs) {
                seek(deck, toSeconds: Double(atMs) / 1000)
            }
        }
    }

    func syncApplyControl(_ e: MixSyncEvent) {
        applyingRemote {
            if e.kind == MixSyncKind.crossfader { if let v = e.value { setCrossfader(v) }; return }
            guard let d = e.engineDeck else { return }
            let slot = e.slot
            switch e.kind {
            case MixSyncKind.tempo, MixSyncKind.sync: if let v = e.value { setRate(v, on: d) }
            case "pitch": if let v = e.value { setPitch(v, on: d) }
            case "volume": if let v = e.value { setVolume(v, on: d) }
            case "eq":
                if let v = e.value, let band = EQBand.allCases.first(where: { "\($0)" == e.param }) { setEqGain(band, v, on: d) }
            case "effectToggle":
                guard let on = e.flag else { return }
                if let i = slot { setSlot(i, enabled: on, on: d) }
                else if let fx = e.param.flatMap(Effect.init(rawValue:)) { setEffect(fx, enabled: on, on: d) }
            case "effectStrength":
                guard let v = e.value else { return }
                if let i = slot { setSlotStrength(i, v, on: d) }
                else if let fx = e.param.flatMap(Effect.init(rawValue:)) { setEffectStrength(fx, v, on: d) }
            case "effectSlot":
                if let i = slot, let fx = e.param.flatMap(Effect.init(rawValue:)) { setSlotEffect(fx, slot: i, on: d) }
            case "effectVariant":
                if let i = slot, let v = e.param.flatMap(EffectVariant.init(rawValue:)) { setSlotVariant(v, slot: i, on: d) }
            case "effectMod":
                guard let i = slot, let parts = e.param?.split(separator: ":").map(String.init), parts.count == 3,
                      let src = ModSource(rawValue: parts[0]), let r = ModRate(rawValue: parts[1]),
                      let shape = ModShape(rawValue: parts[2]) else { return }
                setSlotMod(SlotMod(source: src, rate: r, depth: e.value ?? 0.5, shape: shape,
                                   phase: self.slot(i, on: d)?.mod.phase ?? 0), slot: i, on: d)
            case "filterMode":
                if let m = e.param.flatMap(FilterMode.init(rawValue:)) { setFilterMode(m, on: d) }
            case "stemMode":
                if let on = e.flag { setStemMode(on, on: d) }
            case "stemMute":
                if let name = e.param, let muted = e.flag, isStemMuted(name, on: d) != muted { toggleStemMute(name, on: d) }
            case "stemVolume":
                if let name = e.param, let v = e.value { setStemVolume(name, v, on: d) }
            case MixSyncKind.lead:
                if (e.flag ?? false) != isLead(d) { setLead(d) }
            case MixSyncKind.resetDeck:
                resetDeck(d)
            case MixSyncKind.loop:
                if let u = e.value { setLoopUnits(d, u) }
                if let on = e.flag { setLoop(d, on: on) }
            case MixSyncKind.loopUnits:
                if let u = e.value { setLoopUnits(d, u) }
            default:
                break                                   // a kind this build doesn't apply — ignored
            }
        }
    }

    func syncSeedEvents(_ deck: Deck) -> [MixSyncEvent] {
        guard let l = loaded(deck) else { return [] }
        let d = deck.rawValue
        return [
            MixSyncEvent(kind: MixSyncKind.load, deck: d, songId: l.songId, title: l.title, artist: l.artist,
                         bpm: l.bpm, camelot: l.camelot, key: l.key, albumId: l.albumId,
                         lengthMs: duration(deck) > 0 ? Int(duration(deck) * 1000) : nil),
            MixSyncEvent(kind: MixSyncKind.tempo, deck: d, value: rate(deck)),
            MixSyncEvent(kind: "pitch", deck: d, value: pitch(deck)),
            MixSyncEvent(kind: "volume", deck: d, value: volume(deck)),
            MixSyncEvent(kind: isPlaying(deck) ? MixSyncKind.play : MixSyncKind.pause, deck: d,
                         anchor: MixSyncAnchor(positionMs: syncStatus(deck).playheadMs, atSharedTime: nil,
                                               isPlaying: isPlaying(deck))),
        ]
    }

    var syncCrossfader: Double { crossfader }
}

// MARK: - Production resolver

extension MixSync {
    /// A session song → a deck-loadable song on THIS device: the same song id when it's burned /
    /// streamable / a local performance item here, else the Remote resolver's catalog match (Apple
    /// Music id, then title + artist) when THAT song is mixable here. Apple Music playback is never
    /// mixable (no decks over a DRM stream), so an `am:` resolution is "not available".
    static func liveResolver(app: AppModel, collections: CollectionsStore, burns: BurnStore,
                             studio: StudioStore, engine: MixEngine) -> (MixSyncEvent) -> MixLoadable? {
        let songs = RemoteSongResolver.live(app: app)
        return { [weak app, weak collections, weak burns, weak studio, weak engine] e in
            guard let app, let collections, let burns, let studio, let sid = e.songId else { return nil }
            let mix = MixResolver(app: app, collections: collections, burns: burns, studio: studio,
                                  streamable: { engine?.canStream($0) ?? false })
            if let hit = mix.loadables(forSongIds: [sid]).first { return hit }
            let row = RemoteRow(rid: "mix", row: PlaybackSessionStore.Row(
                songId: sid, title: e.title ?? "", artist: e.artist ?? "", lengthMs: e.lengthMs,
                repeatCount: nil, appleMusicId: e.appleMusicId))
            switch songs.resolve(row) {
            case .catalog(let it), .matched(let it):
                return mix.loadables(forSongIds: [it.id]).first
            case .appleMusic, .unavailable:
                return nil
            }
        }
    }
}
