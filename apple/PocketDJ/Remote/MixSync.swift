import AVFoundation
import Foundation
import Observation

/// One deck as the multiplayer layer reads it off THIS device's engine.
struct MixSyncDeckStatus: Equatable {
    /// The LOCAL song id on the deck (nil = empty).
    var songId: String?
    var isPlaying: Bool
    /// The AUDIBLE playhead (source ms) — the render clock projected to now, minus the output
    /// path's latency, folded into a loop window.
    var playheadMs: Int
    var durationMs: Int
    var rate: Double
    /// Loaded and not waiting on bytes.
    var ready: Bool
    /// A loop (∞) is engaged — its playhead wraps inside [loopStartMs, loopEndMs).
    var looping: Bool = false
    var loopStartMs: Int? = nil
    var loopEndMs: Int? = nil
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
    /// Start `deck` from `fromMs` at the LOCAL wall-clock instant `atLocalMs` (epoch ms) — the
    /// instant it must be HEARD (the engine fires early by its output latency).
    func syncPlay(_ deck: MixEngine.Deck, fromMs: Int, atLocalMs: Double)
    /// Pause `deck` and cue it at `atMs`.
    func syncPause(_ deck: MixEngine.Deck, atMs: Int)
    /// One live non-transport event (tempo, FX, EQ, stems, lead, crossfader…).
    func syncApplyControl(_ event: MixSyncEvent)
    /// The deck's WHOLE control state = `controls` folded over defaults (diffed — unlisted
    /// controls go back to default, matching ones are untouched). Loop + transport excluded.
    func syncSetControls(_ deck: MixEngine.Deck, _ controls: [MixSyncEvent])
    /// Engage / re-place / release the loop on EXACTLY the owner's window (phase kept).
    func syncSetLoop(_ deck: MixEngine.Deck, on: Bool, units: Double?, startMs: Int?, endMs: Int?)
    /// A temporary rate multiplier (≤ ±1 %) on top of the deck's tempo — 1 restores it exactly.
    func syncNudgeRate(_ deck: MixEngine.Deck, factor: Double)
    /// What a fresh session should start from: this device's decks as events (load, every
    /// control, transport). The host seeds the mix with them when it starts one over loaded decks.
    func syncSeedEvents(_ deck: MixEngine.Deck) -> [MixSyncEvent]
    var syncCrossfader: Double { get }
    func setAutoDJBlocked(_ reason: String?)
    /// A session is driving the decks: suspend durable-session persistence, drop a parked restore.
    func syncSessionActive(_ on: Bool)
}

/// MULTIPLAYER MIX over a SharePlay Remote session (Phase 2) — two decks, several DJs, every
/// device rendering both decks LOCALLY from shared state. Never streams audio.
///
/// AUTHORITY. The Remote session's host orders everything. A participant's gesture is a
/// PROPOSAL (`mix.event`, no host sequence) → the host validates it (ownership, and drops one
/// older than the sender's last on that control) → assigns the next host sequence number →
/// rebroadcasts it → every device (the host included) applies ordered events strictly in host
/// order. Every device mirrors the authoritative `MixSyncModel` from that stream, so any device
/// can answer a joiner or take over as host — and a live mix is never ended by an empty or
/// older host (`mix.handover`).
///
/// OWNERSHIP. Each deck has an owner (a participant id) or is free. Default: the host takes Deck
/// A, the first mix-capable joiner (`MixCapability.deckOwner` — never a Phase-1 build or an Apple
/// TV) Deck B. A participant can claim a free deck or release theirs; the crossfader is shared.
/// Only a deck's owner's USER gestures are proposed; a local gesture on a deck you don't own is
/// undone from the mirror on the next tick, and the deck's WHOLE board is reconciled (unlisted
/// controls back to default).
///
/// SYSTEM CAUSES stay local: a lock-screen / CarPlay / Siri / interruption pause of THIS device
/// (`MixEngine.Gesture.Cause.system`) silences only this device — the deck is "held" (no repair,
/// no heartbeat, no drift fix) until the system resumes it, then it REJOINS at the anchored
/// position. Engine-internal stops (`.engine`) are ignored outright.
///
/// NO ECHO. A gesture is applied locally the instant it happens (the DJ never waits a round
/// trip) and its echo is skipped. A sender's own un-echoed proposal on a control shadows
/// another sender's earlier-ordered value on the SAME control (the sender's will be ordered
/// after it and win), so two hands on the crossfader converge on host order instead of jittering.
/// An un-echoed proposal older than `pendingTimeoutMs` is dropped and a snapshot requested (a
/// lost proposal never freezes the control). Continuous surfaces are coalesced (`continuousIntervalMs`,
/// scrubs `seekIntervalMs`) with a trailing send of the final value.
///
/// TIMING. Transport events carry a shared-clock anchor {positionMs, atSharedTime, isPlaying}.
/// The host re-anchors a start / seek / ↺ `startLeadMs` into the future; each device converts
/// the shared instant to its own clock (`SharedClock`) and starts the deck there with the
/// engine's scheduled start (`MixEngine.play(_:fromMs:atHostTime:)` — stems together on one
/// sample frame, fired early by the output latency). An owner proposes a play only once its
/// deck can SOUND (not while it buffers), and the host still waits for its ready report
/// (≤ `readyTimeoutMs`). The owner's device sends a heartbeat every `heartbeatMs` that every
/// device folds into its anchor; others correct drift past `driftThreshold` (max 40 ms, the
/// two clocks' uncertainty + margin) seen on 2 consecutive beats — under `nudgeMaxMs` by a ≤ 1 %
/// rate nudge, above it by a re-seek (cooldown `driftCooldownMs`). Looping decks compare
/// PHASE inside the loop window.
///
/// LOCAL ONLY: cue / PFL, the meter source, recording, and the session log (a remote DJ's
/// gestures are not recorded as yours). The Auto-DJ is disabled while a mix session is active,
/// and the durable Mix session is not written (the user's own saved mix survives the session).
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
    /// The FLOOR of the drift threshold — the real one adds both clocks' uncertainty + margin.
    static let driftThresholdMs = 40
    static let driftMarginMs: Double = 20
    /// Consecutive out-of-threshold beats before a correction (one beat can be a stale relay).
    static let driftStrikesNeeded = 2
    /// Drift below this is slid back with a rate nudge; at or above, re-seeked.
    static let nudgeMaxMs = 250
    /// The nudge's rate offset (1 % — inaudible as pitch with the time-stretch, ~10 ms/s).
    static let nudgeRate: Double = 0.01
    static let driftCooldownMs: Double = 4_000
    /// A heartbeat older than this (shared time) is not trusted for a correction.
    static let staleBeatMs: Double = 1_500
    /// The host broadcasts a held play this long after it arrived even if the owner never
    /// reported ready (others then start late and the heartbeat corrects them).
    static let readyTimeoutMs: Double = 4_000
    /// A hole in the host sequence this old ⇒ ask for a snapshot.
    static let gapTimeoutMs: Double = 1_500
    /// Snapshot requests back off 3, 6, 12, 24, 48 s and stop after `snapshotMaxAttempts`
    /// (a Phase-1 host never answers).
    static let snapshotRetryMs: Double = 3_000
    static let snapshotMaxAttempts = 5
    /// An un-echoed proposal this old is presumed lost: drop it, re-sync from a snapshot.
    static let pendingTimeoutMs: Double = 2_000
    /// Coalescing: continuous surfaces at ~20 Hz, scrubs at ~4 Hz (each with a trailing send).
    static let continuousIntervalMs: Double = 50
    static let seekIntervalMs: Double = 250
    static let autoDJBlockedReason = "Auto DJ is off while you mix together."

    // MARK: Observable state

    private(set) var isActive = false
    /// Deck → owner id — the ONLY ownership state views observe (the hot model below is not
    /// observed, so a slider drag on the wire never re-renders a deck).
    private(set) var owners: [MixEngine.Deck: String] = [:]
    /// Decks whose session song can't be mixed on THIS device → that song's title.
    private(set) var unavailable: [MixEngine.Deck: String] = [:]
    /// Each peer's per-deck readiness (`mix.ready`), keyed peer id → deck rawValue.
    private(set) var peerReadiness: [String: [String: MixSyncReady]] = [:]
    var statusMessage: String?

    /// The authoritative mix as mirrored here (NOT observed — see `owners`).
    @ObservationIgnored private(set) var model = MixSyncModel()

    // MARK: Dependencies

    @ObservationIgnored let remote: RemoteSessionController
    @ObservationIgnored let engine: MixSyncEngine
    /// A session song → something THIS device can put on a deck (nil = not mixable here).
    @ObservationIgnored var resolve: (MixSyncEvent) -> MixLoadable?
    /// The Apple Music store id the local catalog knows for a song (stamped onto outbound loads).
    @ObservationIgnored var appleMusicIdForSong: (String) -> String? = { _ in nil }

    // MARK: Internals

    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private var nextOriginSeq = 1
    /// controlKey → my latest un-echoed proposal (originSeq, when proposed).
    @ObservationIgnored private var pending: [String: (seq: Int, at: Double)] = [:]
    @ObservationIgnored private var expectedHostSeq = 1
    @ObservationIgnored private var buffer: [Int: MixSyncEventMessage] = [:]
    @ObservationIgnored private var gapSince: Double?
    @ObservationIgnored private var awaitingSnapshotSince: Double?
    @ObservationIgnored private var snapshotAttempts = 0
    @ObservationIgnored private var nextRequestAt: Double = -.infinity
    /// Host: a playing transport waiting for its owner's device to be ready.
    @ObservationIgnored private var held: [MixEngine.Deck: (msg: MixSyncEventMessage, from: String, since: Double)] = [:]
    /// Host: "sender|controlKey" → the newest originSeq ordered for it (older arrivals are stale).
    @ObservationIgnored private var lastProposalSeq: [String: Int] = [:]
    @ObservationIgnored private var lastBeatAt: [MixEngine.Deck: Double] = [:]
    @ObservationIgnored private var lastDriftFixAt: [MixEngine.Deck: Double] = [:]
    @ObservationIgnored private var driftStrikes: [MixEngine.Deck: Int] = [:]
    /// A rate nudge in progress → when it ends (local ms).
    @ObservationIgnored private var nudgeUntil: [MixEngine.Deck: Double] = [:]
    /// The SESSION song id each deck currently mirrors on this device (nil = nothing loaded for it).
    @ObservationIgnored private var localSong: [MixEngine.Deck: String] = [:]
    @ObservationIgnored private var reportedReady: [MixEngine.Deck: MixSyncReady] = [:]
    @ObservationIgnored private var repairQueue: Set<MixEngine.Deck> = []
    /// Decks this device's SYSTEM paused (lock screen / CarPlay / interruption): silent here, not
    /// repaired, not heart-beaten, until the system resumes them (then they rejoin the anchor).
    @ObservationIgnored private(set) var systemHeld: Set<MixEngine.Deck> = []
    /// Owned decks whose ▶ waits for the deck to be able to SOUND before it is proposed.
    @ObservationIgnored private var deferredPlay: Set<MixEngine.Deck> = []
    /// Coalescing: controlKey → the latest queued proposal + when it may go.
    @ObservationIgnored private var outbox: [String: (msg: MixSyncEventMessage, due: Double)] = [:]
    @ObservationIgnored private var lastSentAt: [String: Double] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastHostId: String?
    @ObservationIgnored private var lastRoster: Set<String> = []
    /// My clock offset to the CURRENT host, kept across ticks — a hand-over re-anchors the mirror
    /// onto my own clock with it (the controller has already reset the samples by then).
    @ObservationIgnored private var lastOffset: Double?
    /// My offset to the PREVIOUS host's timeline, captured at a host change (0 if I was it) —
    /// what my mirror's anchors are on until a new snapshot replaces them.
    @ObservationIgnored private var previousHostOffset: Double = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Test seams: drift corrections made per deck (nudges + re-seeks), and the nudges alone.
    @ObservationIgnored private(set) var driftFixCount: [MixEngine.Deck: Int] = [:]
    @ObservationIgnored private(set) var nudgeCount: [MixEngine.Deck: Int] = [:]
    /// Test seam: proposals the host dropped as stale (older than the sender's last).
    @ObservationIgnored private(set) var staleDropped = 0

    init(remote: RemoteSessionController, engine: MixSyncEngine,
         resolve: @escaping (MixSyncEvent) -> MixLoadable?, autoTick: Bool = true) {
        self.remote = remote
        self.engine = engine
        self.resolve = resolve
        self.autoTick = autoTick
        remote.registerHandler(kind: MixWireKind.event) { [weak self] env, from in self?.receiveEvent(env, from: from) }
        remote.registerHandler(kind: MixWireKind.snapshot) { [weak self] env, from in self?.receiveSnapshot(env, from: from) }
        remote.registerHandler(kind: MixWireKind.request) { [weak self] env, from in self?.receiveRequest(env, from: from) }
        remote.registerHandler(kind: MixWireKind.ready) { [weak self] env, from in self?.receiveReady(env, from: from) }
        remote.registerHandler(kind: MixWireKind.beat) { [weak self] env, from in self?.receiveBeat(env, from: from) }
        remote.registerHandler(kind: MixWireKind.reject) { [weak self] env, from in self?.receiveReject(env, from: from) }
        remote.registerHandler(kind: MixWireKind.handover) { [weak self] env, from in self?.receiveHandover(env, from: from) }
        // A live Mix Together is session ACTIVITY: the host election never yields it to an empty host.
        remote.registerActivityProbe { [weak self] in self?.isActive == true }
        // An Apple TV renders the mix but has no deck board: never a deck-owner candidate.
        #if !os(tvOS)
        if !remote.localCaps.contains(MixCapability.deckOwner) { remote.localCaps.append(MixCapability.deckOwner) }
        #endif
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
        !isActive || (localId != nil && owners[deck] == localId)
    }

    func owner(of deck: MixEngine.Deck) -> String? { owners[deck] }
    var myDecks: [MixEngine.Deck] {
        guard let me = localId else { return [] }
        return MixEngine.Deck.allCases.filter { owners[$0] == me }
    }

    /// A participant's display name ("You" for this device).
    func name(of id: String) -> String {
        if id == localId { return "You" }
        return remote.peers.first { $0.id == id }?.name ?? "Someone"
    }

    /// "Deck B · Sam’s iPhone", nil when free / outside a session.
    func ownerLabel(_ deck: MixEngine.Deck) -> String? {
        guard isActive else { return nil }
        guard let o = owners[deck] else { return "Free" }
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

    /// The model changed: publish ownership (only when it actually moved — views observe it).
    private func publishOwners() {
        var o: [MixEngine.Deck: String] = [:]
        for d in MixEngine.Deck.allCases { if let id = model.owner(of: d) { o[d] = id } }
        if o != owners { owners = o }
    }

    private func setUnavailable(_ d: MixEngine.Deck, _ title: String?) {
        if unavailable[d] != title { unavailable[d] = title }
    }

    // MARK: - Session lifecycle (host)

    /// HOST: start mixing together inside the current Listen Together session. The host takes
    /// Deck A, the first other mix-capable participant Deck B; decks already loaded here seed the
    /// mix with their WHOLE board (EQ, FX rack incl. modulation, stems, loop, lead, levels).
    func start() {
        guard canStart, let me = localId else { return }
        checkTopology()
        let seq = model.hostSeq
        model = MixSyncModel()
        model.epoch = me
        model.hostSeq = seq
        lastProposalSeq = [:]
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
        engine.syncSessionActive(on)
        if on {
            engine.setAutoDJBlocked(Self.autoDJBlockedReason)
            statusMessage = nil
        } else {
            engine.setAutoDJBlocked(nil)
            for d in nudgeUntil.keys { engine.syncNudgeRate(d, factor: 1) }
            nudgeUntil = [:]
            driftStrikes = [:]
            unavailable = [:]
            peerReadiness = [:]
            held = [:]
            pending = [:]
            outbox = [:]
            repairQueue = []
            reportedReady = [:]
            systemHeld = []
            deferredPlay = []
        }
    }

    /// The Remote session is gone: the mix ends here (decks keep playing locally).
    private func resetAll() {
        setActive(false)
        let seq = model.hostSeq
        model = MixSyncModel()
        model.hostSeq = seq
        publishOwners()
        lastHostId = nil
        lastRoster = []
        lastOffset = nil
        buffer = [:]
        gapSince = nil
        awaitingSnapshotSince = nil
        snapshotAttempts = 0
        lastProposalSeq = [:]
        localSong = [:]
        expectedHostSeq = 1
    }

    // MARK: - Tick

    /// One heartbeat (0.25 s in production; tests call it directly): topology, snapshot retries,
    /// lost proposals, the coalescing outbox, readiness reports, deferred plays, held plays,
    /// nudges, repairs, sequence gaps, the deck heartbeat.
    func tick() {
        checkTopology()
        guard remote.isActive else { return }
        let t = now
        if !isHost {
            if let since = gapSince, t - since >= Self.gapTimeoutMs { requestSnapshot("gap") }
            if awaitingSnapshotSince != nil, snapshotAttempts < Self.snapshotMaxAttempts, t >= nextRequestAt {
                requestSnapshot("retry")
            }
            expirePending(at: t)
        }
        flushOutbox(at: t)
        guard isActive else { return }
        if isHost { autoAssignB() }
        for d in MixEngine.Deck.allCases { reportReadiness(d) }
        flushDeferredPlays()
        if isHost {
            for (d, h) in held where t - h.since >= Self.readyTimeoutMs { releaseHeld(d) }
        }
        for (d, until) in nudgeUntil where t >= until {
            nudgeUntil[d] = nil
            engine.syncNudgeRate(d, factor: 1)          // the deck's own tempo, exactly
            lastDriftFixAt[d] = t                       // the cooldown runs from the nudge's END
        }
        let repairs = repairQueue.subtracting(systemHeld)
        repairQueue.subtract(repairs)
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
            previousHostOffset = previous == me ? 0 : (lastOffset ?? 0)
            pending = [:]
            held = [:]
            buffer = [:]
            gapSince = nil
            awaitingSnapshotSince = nil
            snapshotAttempts = 0
            nextRequestAt = -.infinity
            if isHost {
                if previous != nil { takeOver(me) } else { model.epoch = me }
            } else if let host {
                // I WAS the host and yielded: the new host may not have the mix — hand it mine.
                if previous == me, model.active { pushHandover(to: host) }
                requestSnapshot("host")
            }
        }
        if !isHost, let host, remote.clock.hostId == host, let off = remote.clock.offsetMs { lastOffset = off }
        let roster = remote.roster
        if roster != lastRoster {
            let gone = lastRoster.subtracting(roster)
            lastRoster = roster
            for g in gone {
                peerReadiness[g] = nil
                lastProposalSeq = lastProposalSeq.filter { !$0.key.hasPrefix(g + "|") }
            }
            if isHost, model.active {
                for d in MixEngine.Deck.allCases {
                    if let o = model.owner(of: d), gone.contains(o) || !roster.contains(o) {
                        hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: d.rawValue, owner: nil), origin: me)
                    }
                }
                autoAssignB()
            }
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
        lastProposalSeq = [:]
        publishOwners()
        DiagLog.shared.log("remote", "mix hand-over → \(me) seq=\(model.hostSeq) active=\(model.active)")
        if model.active { post(MixWireKind.snapshot, model.snapshot(), to: .all) }
    }

    /// Could `id` own a deck? A build that advertises it (hello caps), or — for a build whose
    /// hello raced the roster — one that already reports mix readiness and isn't an Apple TV.
    private func isDeckOwnerCandidate(_ id: String) -> Bool {
        let hello = remote.peerInfo[id]
        if hello?.caps?.contains(MixCapability.deckOwner) == true { return true }
        guard peerReadiness[id] != nil, let platform = hello?.platform else { return false }
        return platform != "Apple TV"
    }

    /// The first mix-capable joiner gets Deck B (once per session — a released B stays free
    /// until claimed). Re-checked every host tick: a capable peer's hello can land after its join.
    private func autoAssignB() {
        guard isHost, model.active, !model.assignedB, model.owner(of: .b) == nil, let me = localId,
              let first = remote.roster.sorted().first(where: {
                  $0 != me && model.decks(ownedBy: $0).isEmpty && isDeckOwnerCandidate($0)
              })
        else { return }
        hostOrder(MixSyncEvent(kind: MixSyncKind.owner, deck: "B", owner: first), origin: me)
    }

    // MARK: - Local gestures → proposals

    private func localGesture(_ g: MixEngine.Gesture) {
        guard isActive, let me = localId else { return }
        switch g.cause {
        case .engine:
            return                                     // the engine's own housekeeping — never shared
        case .system:
            // THIS device's system transport: local only. A pause holds the deck silent here
            // (no repair / beat / drift); a resume rejoins the session at the anchor.
            guard let d = g.deck else { return }
            if g.kind == MixSyncKind.pause {
                systemHeld.insert(d)
                deferredPlay.remove(d)
            } else if g.kind == MixSyncKind.play {
                systemHeld.remove(d)
                repairQueue.insert(d)
            }
            return
        case .user:
            break
        }
        var e = MixSyncEvent(kind: g.kind, deck: g.deck?.rawValue, param: g.param, value: g.value,
                             flag: g.flag, slot: g.slot, posMs: g.posMs)
        if g.kind == MixSyncKind.crossfader { propose(e); return }
        guard let d = g.deck else { return }          // auto-DJ markers etc. — not shared
        if systemHeld.remove(d) != nil, g.kind == MixSyncKind.play, model.deck(d).anchor?.isPlaying == true {
            // ▶ on a deck the system silenced while the session kept playing: REJOIN — never
            // re-anchor everyone onto where this device stopped.
            repairQueue.insert(d)
            return
        }
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
            setUnavailable(d, nil)
            deferredPlay.remove(d)
        case MixSyncKind.eject:
            localSong[d] = nil
            setUnavailable(d, nil)
            deferredPlay.remove(d)
        case MixSyncKind.play:
            // Propose a start only once this deck can SOUND: a buffering owner would otherwise
            // anchor everyone to a playhead that isn't moving yet (they'd start seconds ahead).
            guard engine.syncStatus(d).ready else { deferredPlay.insert(d); return }
            deferredPlay.remove(d)
            e.anchor = currentAnchor(d)
        case MixSyncKind.pause:
            deferredPlay.remove(d)
            e.anchor = currentAnchor(d)
        case MixSyncKind.seek:
            let st = engine.syncStatus(d)
            // A scrub on a LOOPING deck moves the loop: share the new window FIRST, so receivers
            // place it before the seek's anchor lands inside it.
            if st.looping {
                propose(MixSyncEvent(kind: MixSyncKind.loop, deck: d.rawValue, value: nil, flag: true,
                                     loopStartMs: st.loopStartMs, loopEndMs: st.loopEndMs))
            }
            e.anchor = currentAnchor(d)
        case MixSyncKind.resetDeck:
            e.anchor = currentAnchor(d)                // ↺ rewinds everyone at ONE shared instant
        case MixSyncKind.loop, MixSyncKind.loopUnits:
            // One loop state per deck: the window travels with every loop / length / edge change.
            e.kind = MixSyncKind.loop
            e.loopStartMs = g.loopStartMs
            e.loopEndMs = g.loopEndMs
            if e.flag == nil { e.flag = engine.syncStatus(d).looping }
        default:
            break
        }
        propose(e)
        if g.kind == MixSyncKind.load || g.kind == MixSyncKind.eject { reportReadiness(d) }
    }

    private func currentAnchor(_ d: MixEngine.Deck) -> MixSyncAnchor {
        let st = engine.syncStatus(d)
        return MixSyncAnchor(positionMs: st.playheadMs, atSharedTime: remote.clock.sharedNow, isPlaying: st.isPlaying)
    }

    /// Owned decks whose ▶ waited for bytes: propose the start the moment the deck can sound
    /// (with an anchor read off the moving playhead). A deck paused meanwhile drops the wait.
    private func flushDeferredPlays() {
        for d in deferredPlay.sorted(by: { $0.rawValue < $1.rawValue }) {
            let st = engine.syncStatus(d)
            guard st.isPlaying, model.owner(of: d) == localId else { deferredPlay.remove(d); continue }
            guard st.ready else { continue }
            deferredPlay.remove(d)
            propose(MixSyncEvent(kind: MixSyncKind.play, deck: d.rawValue, posMs: st.playheadMs,
                                 anchor: currentAnchor(d)))
        }
    }

    private func coalesceInterval(_ e: MixSyncEvent) -> Double {
        if e.kind == MixSyncKind.seek { return Self.seekIntervalMs }
        return MixSyncKind.continuous.contains(e.kind) ? Self.continuousIntervalMs : 0
    }

    private func propose(_ e: MixSyncEvent) {
        guard isActive, localId != nil else { return }
        let seq = nextOriginSeq
        nextOriginSeq += 1
        let msg = MixSyncEventMessage(originSeq: seq, event: e)
        let key = e.controlKey
        let t = now
        if !isHost {
            guard remote.hostId != nil else { statusMessage = "Waiting for the session host…"; return }
            if e.kind != MixSyncKind.claim, e.kind != MixSyncKind.release { pending[key] = (seq, t) }
        }
        let interval = coalesceInterval(e)
        guard interval > 0 else {
            outbox[key] = nil                          // a discrete event on the control supersedes a queued drag
            send(msg)
            return
        }
        // COALESCE: the first move goes at once; later ones inside the interval replace each
        // other and the LAST is sent when the interval closes (the final value always lands).
        if outbox[key] == nil, t - (lastSentAt[key] ?? -.infinity) >= interval {
            lastSentAt[key] = t
            send(msg)
        } else {
            let due = (lastSentAt[key] ?? t) + interval
            outbox[key] = (msg, due)
            scheduleFlush(at: due)
        }
    }

    private func send(_ msg: MixSyncEventMessage) {
        guard let me = localId else { return }
        if isHost { handleProposal(msg, from: me); return }
        guard let host = remote.hostId else { return }
        post(MixWireKind.event, msg, to: .participant(host))
    }

    /// Send every queued (coalesced) proposal whose interval has closed.
    private func flushOutbox(at t: Double) {
        let due = outbox.filter { $0.value.due <= t }.sorted { $0.value.msg.originSeq < $1.value.msg.originSeq }
        for (key, q) in due {
            outbox[key] = nil
            lastSentAt[key] = t
            send(q.msg)
        }
    }

    private func scheduleFlush(at due: Double) {
        guard autoTick, flushTask == nil else { return }   // tests flush from `tick`
        flushTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let wait = max(5, (self.outbox.values.map(\.due).min() ?? self.now) - self.now)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000))
                self.flushOutbox(at: self.now)
                if self.outbox.isEmpty { self.flushTask = nil; return }
            }
        }
    }

    /// A proposal not echoed within `pendingTimeoutMs` was lost (or its echo was): stop
    /// shadowing the control and re-sync it from the host's snapshot.
    private func expirePending(at t: Double) {
        let expired = pending.filter { t - $0.value.at >= Self.pendingTimeoutMs && outbox[$0.key] == nil }
        guard !expired.isEmpty else { return }
        for k in expired.keys { pending[k] = nil }
        DiagLog.shared.log("remote", "mix proposals unanswered (\(expired.keys.sorted().joined(separator: ","))) → snapshot")
        requestSnapshot("pending")
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
        // STALE: an older proposal from this sender on this control arriving after a newer one
        // (a reordered send) would undo the newer value — drop it; the sender already shows the
        // newer one and its pending mark waits for THAT echo.
        let seqKey = "\(from)|\(e.controlKey)"
        if e.kind != MixSyncKind.claim, e.kind != MixSyncKind.release {
            if let last = lastProposalSeq[seqKey], msg.originSeq <= last {
                staleDropped += 1
                DiagLog.shared.log("remote", "mix stale \(e.kind) deck=\(e.deck ?? "-") from=\(from) seq=\(msg.originSeq)≤\(last)")
                return
            }
            lastProposalSeq[seqKey] = msg.originSeq
        }
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
        if e.carriesAnchor, var a = e.anchor {
            if a.atSharedTime == nil { a.atSharedTime = t }
            if a.isPlaying, let d = e.engineDeck {
                if e.isTransport, !bypassReadiness, !ownerReady(d) {
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
        if e.kind == MixSyncKind.owner { publishOwners() }
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
            if m.event.kind == MixSyncKind.owner { publishOwners() }
            applyOrdered(m)
            // The mirror now names this deck's song: say at once whether it can sound here (a
            // held start of the owner's waits on exactly this report).
            if let d = m.event.engineDeck, m.event.kind == MixSyncKind.load || m.event.kind == MixSyncKind.eject {
                reportReadiness(d)
            }
        }
        gapSince = buffer.isEmpty ? nil : (gapSince ?? now)
    }

    private func receiveSnapshot(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard !isHost, from == remote.hostId, let s = env.decode(MixSyncSnapshot.self) else { return }
        // A live mix is never ended (or rolled back) by a host that doesn't have it: a host that
        // took over without ever mirroring the mix, or one behind us. Hand it ours instead — it
        // adopts it and answers with a snapshot we accept. (Its later ordered events stay
        // buffered on the epoch mismatch; the backed-off retry re-asks.)
        if isActive, s.epoch != model.epoch, !s.active || s.hostSeq < model.hostSeq {
            DiagLog.shared.log("remote", "mix snapshot from \(from) refused (active=\(s.active) seq=\(s.hostSeq) < ours=\(model.hostSeq)) → handover")
            pushHandover(to: from)
            return
        }
        model = MixSyncModel(s)
        publishOwners()
        expectedHostSeq = s.hostSeq + 1
        awaitingSnapshotSince = nil
        snapshotAttempts = 0
        nextRequestAt = -.infinity
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

    /// Send my live mirror to `host`, anchors re-expressed on my local clock.
    private func pushHandover(to host: String) {
        var snap = model.snapshot()
        let off = previousHostOffset
        for (k, var ds) in snap.decks {
            if var a = ds.anchor, let at = a.atSharedTime { a.atSharedTime = at - off; ds.anchor = a }
            snap.decks[k] = ds
        }
        post(MixWireKind.handover, MixSyncHandover(snapshot: snap, sentAtLocal: now), to: .participant(host))
    }

    /// HOST: a participant's live mirror. Adopt it only when mine is empty / inactive or behind
    /// it — then it becomes the authority under my epoch, anchors mapped onto my clock.
    private func receiveHandover(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard isHost, let me = localId, let h = env.decode(MixSyncHandover.self), h.snapshot.active,
              !model.active || h.snapshot.hostSeq > model.hostSeq else { return }
        var m = MixSyncModel(h.snapshot)
        let t = now
        m.epoch = me
        m.hostSeq = max(m.hostSeq, model.hostSeq) + 1
        for d in MixEngine.Deck.allCases {
            guard var ds = m.decks[d] else { continue }
            // "That long before the sender sent" ≈ that long before now (one-way latency ignored).
            if var a = ds.anchor, let at = a.atSharedTime { a.atSharedTime = t - (h.sentAtLocal - at); ds.anchor = a }
            if let o = ds.owner, !remote.roster.contains(o) { ds.owner = nil }
            m.decks[d] = ds
        }
        DiagLog.shared.log("remote", "mix handover from \(from) adopted seq=\(m.hostSeq)")
        model = m
        lastProposalSeq = [:]
        publishOwners()
        setActive(true)
        for d in MixEngine.Deck.allCases { reconcileDeck(d) }
        if let x = m.crossfader, abs(engine.syncCrossfader - x) > 1e-6 {
            engine.syncApplyControl(MixSyncEvent(kind: MixSyncKind.crossfader, deck: nil, value: x))
        }
        post(MixWireKind.snapshot, model.snapshot(), to: .all)
    }

    private func receiveRequest(_ env: RemoteEnvelope, from: String) {
        checkTopology()
        guard isHost else { return }
        post(MixWireKind.snapshot, model.snapshot(), to: .participant(from))
    }

    private func receiveReady(_ env: RemoteEnvelope, from: String) {
        guard let r = env.decode(MixSyncReady.self) else { return }
        if peerReadiness[from]?[r.deck] != r { peerReadiness[from, default: [:]][r.deck] = r }
        if isHost, let d = MixEngine.Deck(rawValue: r.deck), held[d] != nil, ownerReady(d) { releaseHeld(d) }
        if isHost { autoAssignB() }
    }

    private func receiveReject(_ env: RemoteEnvelope, from: String) {
        guard from == remote.hostId, let r = env.decode(MixSyncReject.self) else { return }
        pending = pending.filter { $0.value.seq != r.originSeq }
        statusMessage = r.reason
        // The host's snapshot follows and puts the deck back.
    }

    private func receiveBeat(_ env: RemoteEnvelope, from: String) {
        guard isActive, let b = env.decode(MixSyncBeat.self), b.epoch == model.epoch,
              let d = MixEngine.Deck(rawValue: b.deck), from != localId,
              from == (model.owner(of: d) ?? remote.hostId) else { return }
        // EVERY device keeps the deck's anchor fresh from its owner (repairs, joiner snapshots
        // after a hand-over and late applies all start from where the deck really is).
        if model.deck(d).track?.songId == b.songId { model.decks[d]?.anchor = b.anchor }
        driftCheck(d, b.anchor, songId: b.songId, theirUncertaintyMs: b.uncertaintyMs ?? 0)
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
            if isHost { return }                       // the host's own gesture, applied when made
            if let p = pending[key] {
                // My own gesture, already applied locally. Keep shadowing while a newer one is
                // in flight; otherwise it's settled.
                if p.seq > msg.originSeq { return }
                pending[key] = nil
                if p.seq == msg.originSeq { return }
            }
            // No mark left (expired, or a snapshot reconciled the deck under it): the host's
            // ordered value is the truth — apply it (idempotent on a deck that already shows it).
            applyToEngine(e)
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
            // A joiner's / a follower's deck takes the SESSION's board with the song (a load keeps
            // EQ / FX / volume — the session's, never this device's own leftovers).
            if localSong[d] != nil { engine.syncSetControls(d, model.deck(d).controls) }
        case MixSyncKind.eject:
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            setUnavailable(d, nil)
            reportReadiness(d)
        case MixSyncKind.play, MixSyncKind.pause, MixSyncKind.seek:
            // A deck the system silenced here stays silent until it rejoins (never mid-call).
            guard !systemHeld.contains(d) else { return }
            if let a = e.anchor { applyAnchor(d, a) }
        case MixSyncKind.resetDeck:
            guard localSong[d] != nil else { return }
            engine.syncSetControls(d, model.deck(d).controls)   // the model already folded the reset
            if !systemHeld.contains(d), let a = e.anchor ?? model.deck(d).anchor { applyAnchor(d, a) }
        case MixSyncKind.loop, MixSyncKind.loopUnits:
            guard localSong[d] != nil else { return }
            applyLoop(d, e)
        default:
            guard localSong[d] != nil else { return }  // nothing here to apply it to (unavailable)
            engine.syncApplyControl(e)
        }
    }

    private func applyLoop(_ d: MixEngine.Deck, _ e: MixSyncEvent?) {
        guard let e else {
            if engine.syncStatus(d).looping { engine.syncSetLoop(d, on: false, units: nil, startMs: nil, endMs: nil) }
            return
        }
        engine.syncSetLoop(d, on: e.flag ?? engine.syncStatus(d).looping, units: e.value,
                           startMs: e.loopStartMs, endMs: e.loopEndMs)
    }

    /// Put the session's song for `d` on this device's deck — or, when this device can't mix it,
    /// leave the deck EMPTY (silent for it) and say so.
    private func loadLocally(_ d: MixEngine.Deck, _ e: MixSyncEvent) {
        guard let loadable = resolve(e) else {
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            setUnavailable(d, e.title ?? "This song")
            reportReadiness(d)
            DiagLog.shared.log("remote", "mix deck \(d.rawValue): \(e.songId ?? "-") not mixable here")
            return
        }
        if engine.syncStatus(d).songId != loadable.songId { engine.syncLoad(loadable, on: d) }
        localSong[d] = e.songId
        setUnavailable(d, nil)
        reportReadiness(d)
    }

    /// Make the deck match the mirror EXACTLY (a joiner, a snapshot, a refused / stray local
    /// gesture, a system resume): the song, its whole board (unlisted controls → default), the
    /// transport at the anchor, THEN the loop window (placed around where the anchor put it).
    private func reconcileDeck(_ d: MixEngine.Deck) {
        guard isActive else { return }
        let ds = model.deck(d)
        guard let t = ds.track else {
            if engine.syncStatus(d).songId != nil { engine.syncEject(d) }
            localSong[d] = nil
            setUnavailable(d, nil)
            reportReadiness(d)
            return
        }
        loadLocally(d, t)
        guard localSong[d] != nil else { return }
        engine.syncSetControls(d, ds.controls)
        if let a = ds.anchor, !systemHeld.contains(d) { applyAnchor(d, a) }
        applyLoop(d, ds.controls.last { $0.kind == MixSyncKind.loop || $0.kind == MixSyncKind.loopUnits })
    }

    // MARK: - Timing math

    /// My clock's uncertainty against the shared timeline (½ the best RTT; 0 on the host).
    private var clockUncertaintyMs: Double {
        isHost ? 0 : (remote.clock.best?.rttMs ?? 0) / 2
    }

    /// The drift threshold: never under 40 ms, and never under what the two clocks can't tell
    /// apart (both uncertainties + a margin) — a relayed SharePlay RTT of 200 ms makes 40 ms
    /// "drift" pure measurement noise.
    func driftThreshold(theirUncertaintyMs: Double = 0) -> Int {
        max(Self.driftThresholdMs, Int((clockUncertaintyMs + theirUncertaintyMs + Self.driftMarginMs).rounded(.up)))
    }

    /// local − expected, in ms. On a looping deck: the shortest way around the loop window
    /// (both folded into it — the PHASE inside the loop is what must agree).
    private func offsetMs(_ st: MixSyncDeckStatus, expected: Int) -> Int {
        guard st.looping, let s = st.loopStartMs, let e = st.loopEndMs, e > s else { return st.playheadMs - expected }
        let len = e - s
        func fold(_ x: Int) -> Int { let r = (x - s) % len; return s + (r < 0 ? r + len : r) }
        var diff = fold(st.playheadMs) - fold(expected)
        if diff > len / 2 { diff -= len } else if diff < -len / 2 { diff += len }
        return diff
    }

    /// Drive the deck to the anchor: start at the shared instant (position-corrected when that
    /// instant is already too close), or pause + cue. No-op when the deck already matches within
    /// the drift threshold — applying the same state twice never re-seeks.
    private func applyAnchor(_ d: MixEngine.Deck, _ a: MixSyncAnchor, force: Bool = false) {
        let st = engine.syncStatus(d)
        guard st.songId != nil else { return }
        let t = now
        let threshold = driftThreshold()
        if a.isPlaying {
            guard let at = a.atSharedTime, let localAt = remote.clock.localTime(forShared: at) else {
                // No shared clock yet: start now from the anchor (the heartbeat corrects later).
                if !st.isPlaying { engine.syncPlay(d, fromMs: a.positionMs, atLocalMs: t) }
                return
            }
            if st.isPlaying, !force {
                let expected = a.positionMs + Int(((t - localAt) * st.rate).rounded())
                if abs(offsetMs(st, expected: expected)) <= threshold { return }
            }
            let start = max(localAt, t + Self.minLeadMs)
            let pos = a.positionMs + Int(((start - localAt) * st.rate).rounded())
            if !st.looping, st.durationMs > 0, pos >= st.durationMs - 100 {
                engine.syncPause(d, atMs: st.durationMs)   // the track already ended there
                return
            }
            engine.syncPlay(d, fromMs: max(0, pos), atLocalMs: start)
        } else {
            if !st.isPlaying, abs(st.playheadMs - a.positionMs) <= threshold { return }
            engine.syncPause(d, atMs: a.positionMs)
        }
    }

    // MARK: - Drift

    private func sendHeartbeats(at t: Double) {
        guard let me = localId, let shared = remote.clock.sharedNow else { return }
        for d in MixEngine.Deck.allCases {
            let mine = model.owner(of: d) == me || (model.owner(of: d) == nil && isHost)
            // A system-silenced or still-buffering deck is not the reference anyone should chase.
            guard mine, !systemHeld.contains(d), !deferredPlay.contains(d),
                  let sid = model.deck(d).track?.songId, localSong[d] == sid,
                  t - (lastBeatAt[d] ?? -.infinity) >= Self.heartbeatMs else { continue }
            let st = engine.syncStatus(d)
            guard st.songId != nil else { continue }
            lastBeatAt[d] = t
            let a = MixSyncAnchor(positionMs: st.playheadMs, atSharedTime: shared, isPlaying: st.isPlaying)
            model.decks[d]?.anchor = a                   // snapshots + repairs stay fresh
            post(MixWireKind.beat, MixSyncBeat(deck: d.rawValue, songId: sid, anchor: a, epoch: model.epoch,
                                               uncertaintyMs: clockUncertaintyMs),
                 to: .all, reliable: false)
        }
    }

    /// A heartbeat from the deck's owner. Corrections need a clock measured on THIS host, a fresh
    /// beat, the offset past `driftThreshold` on `driftStrikesNeeded` consecutive beats, and the
    /// cooldown since the last fix (hysteresis: a correction's own settling is never chased).
    /// Small drift is slid back with a ≤ 1 % rate nudge (inaudible — no stop/restart); large
    /// drift (or a ▶/⏸ mismatch) re-seeks.
    private func driftCheck(_ d: MixEngine.Deck, _ a: MixSyncAnchor, songId: String, theirUncertaintyMs: Double) {
        guard isActive, !systemHeld.contains(d), model.deck(d).track?.songId == songId, localSong[d] == songId,
              remote.clock.isSynced, isHost || remote.clock.hostId == remote.hostId,
              let at = a.atSharedTime, let shared = remote.clock.sharedNow,
              shared - at <= Self.staleBeatMs else { return }
        let t = now
        let st = engine.syncStatus(d)
        guard st.songId != nil else { return }
        var offset = 0
        let mismatch = a.isPlaying != st.isPlaying
        if !mismatch {
            guard a.isPlaying else { driftStrikes[d] = 0; return }
            guard nudgeUntil[d] == nil else { return }           // a nudge is already sliding it back
            let expected = a.position(at: shared, rate: st.rate)
            if !st.looping, st.durationMs > 0, expected >= st.durationMs - 250 { return }
            offset = offsetMs(st, expected: expected)
            guard abs(offset) > driftThreshold(theirUncertaintyMs: theirUncertaintyMs) else { driftStrikes[d] = 0; return }
        }
        driftStrikes[d, default: 0] += 1
        guard driftStrikes[d, default: 0] >= Self.driftStrikesNeeded else { return }
        guard t - (lastDriftFixAt[d] ?? -.infinity) >= Self.driftCooldownMs else { return }
        driftStrikes[d] = 0
        lastDriftFixAt[d] = t
        driftFixCount[d, default: 0] += 1
        if !mismatch, abs(offset) < Self.nudgeMaxMs {
            // Ahead ⇒ run 1 % slow (behind ⇒ fast) for exactly as long as it takes to close it.
            let factor = offset > 0 ? 1 - Self.nudgeRate : 1 + Self.nudgeRate
            nudgeUntil[d] = t + Double(abs(offset)) / Self.nudgeRate
            nudgeCount[d, default: 0] += 1
            DiagLog.shared.log("remote", "mix drift deck \(d.rawValue): \(offset) ms → nudge ×\(factor)")
            engine.syncNudgeRate(d, factor: factor)
            return
        }
        DiagLog.shared.log("remote", "mix drift deck \(d.rawValue): local=\(st.playheadMs) playing=\(st.isPlaying) off=\(offset) → re-seek")
        applyAnchor(d, a, force: true)
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

    /// Ask the host for a snapshot. One request in flight at a time; retries back off (3, 6, 12…
    /// s) and stop after `snapshotMaxAttempts` — a host that never answers (a Phase-1 build) is
    /// not polled forever.
    private func requestSnapshot(_ reason: String) {
        guard !isHost, let host = remote.hostId else { return }
        let t = now
        if awaitingSnapshotSince == nil {
            awaitingSnapshotSince = t
            snapshotAttempts = 0
        } else if t < nextRequestAt {
            return                                       // the backoff paces it
        }
        snapshotAttempts += 1
        nextRequestAt = t + Self.snapshotRetryMs * pow(2, Double(snapshotAttempts - 1))
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
        let w = loopWindowMs(deck)
        return MixSyncDeckStatus(songId: l?.songId, isPlaying: isPlaying(deck),
                                 playheadMs: Int((audiblePlayhead(deck) * 1000).rounded()),
                                 durationMs: Int((duration(deck) * 1000).rounded()), rate: rate(deck),
                                 ready: l != nil && !isBuffering(deck), looping: w != nil,
                                 loopStartMs: w?.start, loopEndMs: w?.end)
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
        // `atLocalMs` is when the frame must be HEARD: render it the output path's latency earlier.
        let host = Self.hostTime(forLocalMs: atLocalMs - outputLatencySeconds * 1000,
                                 nowLocalMs: Date().timeIntervalSince1970 * 1000,
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
            case MixSyncKind.loop, MixSyncKind.loopUnits:
                syncSetLoop(d, on: e.flag ?? loopOn(d), units: e.value, startMs: e.loopStartMs, endMs: e.loopEndMs)
            default:
                break                                   // a kind this build doesn't apply — ignored
            }
        }
    }

    func syncSeedEvents(_ deck: Deck) -> [MixSyncEvent] {
        var out = syncDeckStateEvents(deck)             // load + the WHOLE board (durable-session snapshot)
        guard !out.isEmpty else { return [] }
        out.append(MixSyncEvent(kind: isPlaying(deck) ? MixSyncKind.play : MixSyncKind.pause, deck: deck.rawValue,
                                anchor: MixSyncAnchor(positionMs: syncStatus(deck).playheadMs, atSharedTime: nil,
                                                      isPlaying: isPlaying(deck))))
        return out
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
