import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// This device's display name in a Remote session ("Levi’s iPhone").
enum RemoteDevice {
    @MainActor static var kind: String {
        #if os(macOS)
        return "Mac"
        #elseif os(visionOS)
        return "Apple Vision Pro"
        #elseif os(tvOS)
        return "Apple TV"
        #else
        return UIDevice.current.model   // "iPhone" / "iPad"
        #endif
    }
    @MainActor static func name(owner: String) -> String {
        let o = owner.trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? kind : "\(o)’s \(kind)"
    }
}

/// The Remote tab's engine (SharePlay "Listen Together" + "Backseat"), app-scoped so a session
/// survives tab switches and keeps a car speaker in sync while the controller phone browses.
///
/// ROLES. Two independent axes:
///   • session role — the HOST owns the authoritative `RemoteQueueModel` (every command is applied
///     there, then broadcast as a `RemotePlaybackState`); everyone else is a participant. The
///     device that started the session hosts; if it leaves, the remaining participant with the
///     LOWEST id takes over from the last state it saw. Two hosts (a race) resolve by
///     `shouldYield`: an ACTIVE session beats an empty one, then the newer revision, then the
///     lower id — an empty self-elected host can never wipe a real one.
///   • device role — a SPEAKER plays the session's audio on its own player (reconciled from the
///     host's state); a CONTROLLER plays nothing (the Backseat remote) — its player is held
///     silent (`silenceForController`, re-asserted every tick) and every local transport on it
///     (panel, widget, lock screen, CarPlay, Siri) is forwarded to the session through
///     `SetlistPlayer.remoteControllerGate` → `interceptLocalTransport`.
///
/// WIRE. The full windowed state goes out on every revision, to a joiner, and on request; a
/// small heartbeat (revision + position) every 2 s keeps anchors fresh and lets a receiver
/// notice a missed revision (→ `stateRequest`). The encoded state is size-capped (the window
/// shrinks to fit the messenger's budget).
///
/// RECONCILE (a speaker, every 0.5 s tick + on every state): resolve the state's window against
/// this device's catalog (`RemoteSongResolver` — cheap exact paths for every row, the expensive
/// fuzzy matcher only for the current + next few), then make the local player match with the
/// cheapest move — a tail-segment edit, a jump to an upcoming row (cued at the session
/// position), or a fresh `play(…startIndex:startPaused:)` — and correct drift only when it
/// persists past the threshold (wider for Apple Music's coarse clock, never while buffering).
///
/// LOCAL CHANGES (a speaker whose user drives the ordinary Now Playing UI): each reconcile first
/// diffs the local player against what the session last left it as. Only the LISTENER's own
/// actions become commands — the player tags every row change with its cause
/// (`SetlistPlayer.TransitionCause`) and every ▶/⏸ the listener pressed (`userPlayIntentSeq`),
/// and the session's own applies are tagged `.remote`, so no time window is needed: a stall
/// hop, a dead-source / cascade / unplayable skip marks that row unplayable HERE; a natural end
/// reports `.advanced` only when the session is near that row's end too (a shorter local copy
/// waits silently instead); a local stop never pauses everyone.
@MainActor
@Observable
final class RemoteSessionController {

    struct Peer: Identifiable, Equatable {
        var id: String
        var name: String
        var role: RemoteDeviceRole
        var isHost: Bool
        var isLocal: Bool
        /// Rows in the current window this device can't play.
        var unavailableCount: Int
    }

    // MARK: Tunables

    static let tickInterval: Double = 500
    static let heartbeatMs: Double = 2_000
    static let driftThresholdMs = 750
    /// Apple Music's position clock is coarse — a tighter threshold chases its own jitter.
    static let coarseDriftThresholdMs = 2_000
    /// Plain drift must be seen on this many consecutive ticks before it's corrected.
    static let driftStrikesNeeded = 2
    static let driftCooldownMs: Double = 5_000
    /// A local edit a participant sent holds reconcile until a newer state (or this timeout).
    static let pendingHoldMs: Double = 3_000
    /// A position jump bigger than this between ticks is a user scrub.
    static let seekDetectMs = 3_000
    /// No state from any host this long after joining ⇒ re-hello (or, alone, host it).
    static let electionTimeoutMs: Double = 8_000
    /// The host advances on its own when no speaker reported a track end this long past it.
    static let hostAdvanceSlackMs = 8_000
    /// A local natural end counts as the SESSION's track end only this close to its length.
    static let naturalEndToleranceMs = 10_000
    /// A ▶/⏸ the reconciler applied that hasn't taken is re-issued no sooner than this.
    static let playRetryMs: Double = 2_000
    /// A state request that got no answer is re-sent after this, doubling per attempt up to
    /// `stateRequestMaxBackoffMs` (a lost request / answer never strands a participant).
    static let stateRequestRetryMs: Double = 2_000
    static let stateRequestMaxBackoffMs: Double = 16_000
    /// Encoded-state budget (the messenger's payload limit, with headroom).
    static let maxStateBytes = 60_000
    static let minWindowAhead = 10
    /// The fuzzy title/artist matcher runs only for the current row + this many after it.
    static let fuzzyLookahead = 3
    /// The host refills its model from its own local set when the upcoming tail runs this low.
    static let hostRefillBelow = 100
    static let hostRefillChunk = 200
    /// How many local upcoming rows a speaker inspects (≥ the session window).
    static let tailLimit = RemoteQueueModel.windowAhead * 2

    // MARK: Observable state

    private(set) var isActive = false
    private(set) var mode: RemoteSessionMode = .listenTogether
    private(set) var localId: String?
    private(set) var hostId: String?
    private(set) var localRole: RemoteDeviceRole = .speaker
    /// The latest state (the host's own broadcast on the host).
    private(set) var state: RemotePlaybackState?
    private(set) var roster: Set<String> = []
    private(set) var peerInfo: [String: RemoteHello] = [:]
    private(set) var unavailableByPeer: [String: Set<String>] = [:]
    /// Rows in the current window THIS device can't play.
    private(set) var localUnavailable: Set<String> = []
    /// A start in flight (FaceTime activation / the share sheet) — the next session that
    /// arrives is ours to host, in this mode.
    var pendingStartMode: RemoteSessionMode?
    var statusMessage: String?
    /// This SPEAKER's audio was paused by its own system (a call / Siri interruption that didn't
    /// resume, headphones or CarPlay unplugged) while the session plays on: it stays silent here
    /// — the app never resumes a system pause out of the phone speaker — until the listener
    /// presses ▶ (Now Playing, lock screen) or Rejoin (`rejoinHere`).
    private(set) var pausedHere = false
    /// Capabilities this device advertises in its hello (extensions add theirs at init).
    @ObservationIgnored var localCaps: [String] = []

    var isHost: Bool { localId != nil && localId == hostId }

    var peers: [Peer] {
        roster.sorted().map { id in
            let isLocal = id == localId
            let hello = peerInfo[id]
            return Peer(id: id,
                        name: isLocal ? deviceName : (hello?.name ?? "Joining…"),
                        role: isLocal ? localRole : (hello?.role ?? .speaker),
                        isHost: id == hostId, isLocal: isLocal,
                        unavailableCount: isLocal ? localUnavailable.count : (unavailableByPeer[id]?.count ?? 0))
        }
    }

    /// Names of the devices that can't play `rid` (the controller list's warning).
    func unavailableDevices(for rid: String) -> [String] {
        peers.filter { p in p.role == .speaker &&
            (p.isLocal ? localUnavailable.contains(rid) : (unavailableByPeer[p.id]?.contains(rid) ?? false)) }
            .map(\.name)
    }

    /// The session position of the current row right now (UI scrubber).
    func positionNow() -> Int {
        guard let s = state else { return 0 }
        return s.positionMs(at: clock.sharedNow ?? s.anchorSharedTime)
    }

    // MARK: Dependencies

    @ObservationIgnored let target: RemotePlaybackTarget?
    @ObservationIgnored var resolver: RemoteSongResolver
    @ObservationIgnored let clock: SharedClock
    @ObservationIgnored let deviceName: String
    @ObservationIgnored let platform: String
    @ObservationIgnored private var transport: RemoteTransport?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The app-scoped SharePlay `sessions()` observer (`startObservingGroupSessions`) — owned
    /// here, started ONCE from app init, so it never dies with a window.
    @ObservationIgnored var groupSessionsObserver: Task<Void, Never>?
    /// Identity of the CURRENT attach — a cancelled session's trailing roster-finish must never
    /// end the session that replaced it.
    @ObservationIgnored private var sessionToken = UUID()
    /// Kept alive for the showcase seed's in-memory session (hub + the fake "Car").
    @ObservationIgnored private var showcaseKeepAlive: [AnyObject] = []
    @ObservationIgnored private var showcaseHub: LoopbackHub?

    // Host
    @ObservationIgnored private(set) var model = RemoteQueueModel()
    @ObservationIgnored private var sessionId = "rses_" + UUID().uuidString
    @ObservationIgnored private var lastBroadcastAt: Double = 0
    /// Phase-2 extensions (Mix Together) report "my session is live" — counted as activity in
    /// the host election even when the queue is empty.
    @ObservationIgnored private var activityProbes: [() -> Bool] = []

    // Participant
    @ObservationIgnored private var lastRevision = -1
    /// The host whose state `state` is (vs `hostId`, which an election may set provisionally).
    @ObservationIgnored private var stateHostId: String?
    @ObservationIgnored private var lastPingAt: Double = 0
    @ObservationIgnored private var attachedAt: Double = 0
    @ObservationIgnored private var lastHelloAt: Double = 0
    @ObservationIgnored private var stateReceivedAt: Double = -.infinity
    /// host → the revision we last asked it for, when, and how many re-sends so far (an
    /// unanswered request is retried with backoff — see `stateRequestRetryMs`).
    @ObservationIgnored private var stateRequested: [String: (revision: Int, at: Double, attempt: Int)] = [:]

    // Speaker reconcile / local observation
    private struct LocalObservation: Equatable {
        var isRunning: Bool
        var generation: Int
        var currentUid: UUID?
        var upcomingUids: [UUID]
        var isPlaying: Bool
        var positionMs: Int
        var at: Double
        var repeatMode: RepeatMode
        var shuffle: Bool
        var transitionSeq: Int
        var userTransitionSeq: Int
        var lastCause: SetlistPlayer.TransitionCause
        var playIntentSeq: Int
        var playIntent: Bool
    }
    /// Local row instance → session rid.
    @ObservationIgnored private var ridByUid: [UUID: String] = [:]
    /// DECIDED resolutions only (an undecided row is re-tried once it nears the current one).
    @ObservationIgnored private var resolutionCache: [String: RemoteSongResolver.Resolution] = [:]
    @ObservationIgnored private var expected: LocalObservation?
    @ObservationIgnored private var pendingUntil: Double = 0
    @ObservationIgnored private var pendingBaseRevision = -1
    @ObservationIgnored private var lastDriftFixAt: Double = -.infinity
    @ObservationIgnored private var driftStrikes = 0
    /// A new revision arrived: a position difference past the threshold is a session SEEK,
    /// applied at once (no strikes / cooldown).
    @ObservationIgnored private var seekOwed = false
    /// The position our last seek aimed at — its (possibly late) landing is not a user scrub.
    @ObservationIgnored private var pendingSeekMs: Int?
    @ObservationIgnored private var lastPlayApply: (on: Bool, at: Double)?
    /// A row that ENDED here while the session is still on it (a shorter local copy) or on the
    /// unavailable row it stood in for: hold silent — never re-mirror it — until the session
    /// moves (or restarts that row).
    @ObservationIgnored private var heldAfterEnd: (rid: String, sessionRid: String?, sessionPos: Int)?
    /// Rows this device's player could not play (auto-skipped / stall-hopped away from) —
    /// treated as unavailable here so the reconciler never loops back onto them.
    @ObservationIgnored private var locallyFailed: Set<String> = []
    @ObservationIgnored private var reportedUnavailable: Set<String>?
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var isObservingLocal = false

    /// Phase-2 extension point: handlers for message kinds this controller doesn't own
    /// (multiplayer Mix events ride the SAME session/transport under their own `kind`).
    @ObservationIgnored private var extensionHandlers: [String: (RemoteEnvelope, String) -> Void] = [:]
    /// Extensions told when a session attaches (true) / ends (false) — Mix Together runs its
    /// tick only while a session is live.
    @ObservationIgnored private var sessionObservers: [(Bool) -> Void] = []
    /// Other audio engines on this device a CONTROLLER must keep silent (the Mix decks), run
    /// with `target.silenceForController()` — on becoming a controller and on every tick.
    @ObservationIgnored private var controllerSilencers: [() -> Void] = []
    /// `rejoinHere` is driving the reconcile: the system hold is lifted for this pass.
    @ObservationIgnored private var rejoining = false

    init(target: RemotePlaybackTarget?, resolver: RemoteSongResolver,
         deviceName: String, platform: String, clock: SharedClock? = nil) {
        self.target = target
        self.resolver = resolver
        self.deviceName = deviceName
        self.platform = platform
        self.clock = clock ?? SharedClock()
    }

    private var now: Double { clock.localNow() }

    // MARK: - Lifecycle

    /// Enter a session over `transport`. `asHost` = this device started it. `seed` replaces the
    /// host's starting model (the showcase); otherwise a host seeds from whatever its local
    /// player is running, so "start Backseat while a set plays" hands that set to the car.
    func attach(_ transport: RemoteTransport, mode: RemoteSessionMode, asHost: Bool,
                seed: RemoteQueueModel? = nil, autoTick: Bool = true) {
        if isActive { end(leave: true) }
        let token = UUID()
        sessionToken = token
        self.transport = transport
        self.mode = mode
        isActive = true
        localId = transport.localParticipantId
        roster = [transport.localParticipantId]
        localRole = (mode == .backseat && asHost) ? .controller : .speaker
        #if os(tvOS)
        localRole = .speaker          // the TV is always a speaker (no start / controller surface)
        #endif
        attachedAt = now
        lastRevision = -1
        stateHostId = nil
        stateRequested = [:]
        stateReceivedAt = -.infinity
        statusMessage = nil
        expected = nil
        heldAfterEnd = nil
        locallyFailed = []
        resolver.prepare()              // the catalog index builds off-main before rows arrive
        if asHost { becomeHost(seed: seed) }
        if localRole == .controller { silenceLocalAudio() }
        tasks.append(Task { [weak self] in
            for await msg in transport.inbound { self?.handle(msg) }
        })
        tasks.append(Task { [weak self] in
            for await ids in transport.participants { self?.rosterChanged(ids) }
            guard !Task.isCancelled else { return }
            self?.sessionEnded(token: token)
        })
        if autoTick {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    self?.tick()
                    try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000))
                }
            })
        }
        sendHello()
        DiagLog.shared.telemetry("action", "remote attach mode=\(mode.rawValue) host=\(asHost)")
        for o in sessionObservers { o(true) }
    }

    /// Leave the session. Speakers keep playing locally (the music never dies with the session).
    func leave() { end(leave: true) }

    private func sessionEnded(token: UUID) {
        guard token == sessionToken else { return }
        end(leave: false)
    }

    private func end(leave: Bool) {
        guard isActive else { return }
        if leave { transport?.leave() }
        for t in tasks { t.cancel() }
        tasks.removeAll()
        transport = nil
        isActive = false
        localId = nil; hostId = nil; stateHostId = nil
        state = nil
        roster = []; peerInfo = [:]; unavailableByPeer = [:]; localUnavailable = []
        model = RemoteQueueModel()
        ridByUid = [:]; resolutionCache = [:]; expected = nil
        heldAfterEnd = nil; locallyFailed = []; pendingSeekMs = nil; lastPlayApply = nil
        reportedUnavailable = nil
        stateRequested = [:]
        let hub = showcaseHub
        showcaseHub = nil
        showcaseKeepAlive = []
        hub?.end()                      // the fake car leaves with us
        localRole = .speaker
        pausedHere = false
        clock.reset(hostId: nil, isHost: false)
        DiagLog.shared.telemetry("action", "remote end leave=\(leave)")
        for o in sessionObservers { o(false) }
    }

    /// Flip THIS device between speaker and controller.
    func setLocalRole(_ role: RemoteDeviceRole) {
        guard isActive, role != localRole else { return }
        localRole = role
        expected = nil
        heldAfterEnd = nil
        if role == .controller {
            pausedHere = false
            silenceLocalAudio()
        } else {
            ridByUid = [:]   // re-mirror from scratch
            locallyFailed = []
            reconcileLocal()
        }
        reportedUnavailable = nil
        sendHello()
    }

    // MARK: - Commands (the Remote tab's controls)

    /// Issue a command: the host applies it; a participant sends it to the host.
    func send(_ command: RemoteCommand) {
        guard isActive else { return }
        if isHost {
            applyAsHost(command)
        } else if let hostId {
            post(.command, RemoteCommandMessage(command: command), to: .participant(hostId))
        } else {
            statusMessage = "Waiting for the session host…"
        }
    }

    /// Rows for outbound commands from local catalog items (stamped with the Apple Music id so
    /// a device without this songId can still play it through its own subscription).
    func rows(for items: [SetlistPlayer.Item]) -> [RemoteRow] {
        items.map { RemoteRow(item: $0, rid: UUID().uuidString, appleMusicId: resolver.appleMusicIdForSong($0.id)) }
    }

    /// `SetlistPlayer.remoteControllerGate`: a local transport on THIS device while it is a
    /// CONTROLLER — refused locally (true) and forwarded to the session instead. false ⇒ not a
    /// controller: the player handles it as usual.
    func interceptLocalTransport(_ request: SetlistPlayer.RemoteRedirect) -> Bool {
        guard isActive, localRole == .controller else { return false }
        switch request {
        case .playPause: send(.playPause)
        case .setPlaying(let on): send(.setPlaying(on))
        case .skipNext: send(.skipNext)
        case .skipPrevious: send(.skipPrevious)
        case .play(let items, let startIndex):
            // A brand-new set started here (Browse ▶, a widget, Siri, CarPlay) becomes the
            // session's set — windowed like a broadcast (a 26k-row set never rides one message).
            let i = max(0, min(startIndex, items.count - 1))
            let lo = max(0, i - RemoteQueueModel.windowBehind)
            let hi = min(items.count, i + 1 + RemoteQueueModel.windowAhead)
            guard lo < hi else { return true }
            send(.play(rows: rows(for: Array(items[lo..<hi])), startIndex: i - lo))
        case .playNow(let item):
            let r = rows(for: [item])
            send(state?.currentRow == nil ? .play(rows: r, startIndex: 0) : .playNow(rows: r))
        case .jump(let uid):
            if let rid = ridByUid[uid] { send(.jumpTo(rid: rid)) }
        case .localStart:
            break                       // an internal (re)start: refused, nothing to forward
        }
        return true
    }

    // MARK: - Extension point

    func registerHandler(kind: String, _ handler: @escaping (RemoteEnvelope, String) -> Void) {
        extensionHandlers[kind] = handler
    }

    /// An extension's "my part of the session is live" probe (see `activityProbes`).
    func registerActivityProbe(_ probe: @escaping () -> Bool) {
        activityProbes.append(probe)
    }

    /// Told `true` when a session attaches and `false` when it ends (see `sessionObservers`).
    func registerSessionObserver(_ observer: @escaping (Bool) -> Void) {
        sessionObservers.append(observer)
    }

    /// Another local audio engine a CONTROLLER must keep silent (see `controllerSilencers`).
    func registerControllerSilencer(_ silence: @escaping () -> Void) {
        controllerSilencers.append(silence)
    }

    /// This device is a controller: every local audio engine goes (and stays) quiet.
    private func silenceLocalAudio() {
        target?.silenceForController()
        for s in controllerSilencers { s() }
    }

    /// The listener tapped Rejoin after a system pause (`pausedHere`): resume HERE at the
    /// session's position — a local action, nothing is sent (the session never stopped).
    func rejoinHere() {
        guard isActive, localRole == .speaker, pausedHere else { return }
        DiagLog.shared.telemetry("action", "remote rejoin after a system pause")
        rejoining = true
        defer { rejoining = false }
        lastPlayApply = nil
        reconcileLocal()
    }

    /// The share sheet (Messages / nearby invite) closed. Unless it sent an invite — whose
    /// session is then on its way — the pending start is withdrawn: otherwise the NEXT session
    /// that arrives (a peer's) would be taken as ours to host.
    func shareInviteEnded(succeeded: Bool) {
        guard !succeeded, !isActive else { return }
        pendingStartMode = nil
    }

    func sendRaw(_ envelope: RemoteEnvelope, to: RemoteRecipient = .all, reliable: Bool = true) {
        transport?.send(envelope, to: to, reliable: reliable)
    }

    // MARK: - Inbound

    func handle(_ msg: RemoteInbound) {
        guard isActive else { return }
        let env = msg.envelope
        guard let kind = env.knownKind else {
            extensionHandlers[env.kind]?(env, msg.from)   // unknown + unhandled ⇒ ignored
            return
        }
        switch kind {
        case .hello:
            guard let h = env.decode(RemoteHello.self) else { return }
            let isNew = peerInfo[msg.from] == nil
            peerInfo[msg.from] = h
            roster.insert(msg.from)
            if isNew { sendHello(to: .participant(msg.from)) }
            if isHost { broadcastState(to: .participant(msg.from)) }
        case .state:
            guard let s = env.decode(RemotePlaybackState.self), s.hostId == msg.from else { return }
            receiveState(s)
        case .heartbeat:
            guard let hb = env.decode(RemoteHeartbeat.self), hb.hostId == msg.from else { return }
            receiveHeartbeat(hb)
        case .stateRequest:
            guard isHost, env.decode(RemoteStateRequest.self) != nil else { return }
            broadcastState(to: .participant(msg.from))
        case .command:
            guard isHost, let c = env.decode(RemoteCommandMessage.self) else { return }
            applyAsHost(c.command)
        case .ping:
            guard isHost, let p = env.decode(RemotePing.self) else { return }
            post(.pong, clock.pong(for: p), to: .participant(msg.from), reliable: false)
        case .pong:
            guard let p = env.decode(RemotePong.self) else { return }
            clock.ingest(p, from: msg.from)
        case .availability:
            guard let a = env.decode(RemoteAvailability.self) else { return }
            unavailableByPeer[msg.from] = Set(a.unavailableRids)
        }
    }

    /// Two hosts (a hand-over race / an election that ran while the real host was slow): who
    /// yields — deterministic and SYMMETRIC (exactly one side yields). An active session beats
    /// an empty one, then the newer revision, then the LOWER id.
    nonisolated static func shouldYield(theirs: (active: Bool, revision: Int, id: String),
                                        mine: (active: Bool, revision: Int, id: String)) -> Bool {
        if theirs.active != mine.active { return theirs.active }
        if theirs.revision != mine.revision { return theirs.revision > mine.revision }
        return theirs.id < mine.id
    }

    private var hostIsActive: Bool { !model.rows.isEmpty || activityProbes.contains { $0() } }

    private func receiveState(_ s: RemotePlaybackState) {
        stateRequested[s.hostId] = nil
        if isHost {
            guard let localId, s.hostId != localId,
                  Self.shouldYield(theirs: (s.isActiveSession, s.revision, s.hostId),
                                   mine: (hostIsActive, model.revision, localId)) else { return }
            DiagLog.shared.log("remote", "yield host to \(s.hostId)")
        } else if let cur = stateHostId, s.hostId != cur, let mine = state,
                  mine.isActiveSession, !s.isActiveSession {
            // An EMPTY host while the session we follow is live: never adopt its nothing.
            if roster.contains(cur) { return }      // the real host is alive — the empty one yields to it
            DiagLog.shared.log("remote", "empty host \(s.hostId) after \(cur) left — taking over with the set")
            takeOverAsHost()
            return
        }
        if s.hostId != hostId {
            hostId = s.hostId
            clock.reset(hostId: s.hostId, isHost: false)
            lastRevision = -1
            lastPingAt = 0
        }
        if s.hostId != stateHostId { lastRevision = -1 }
        guard s.revision >= lastRevision else { return }
        let structural = s.revision > lastRevision
        lastRevision = s.revision
        stateHostId = s.hostId
        state = s
        mode = s.mode
        stateReceivedAt = now
        if structural {
            resolutionWindowChanged()
            seekOwed = true
        }
        reconcileLocal()
    }

    private func receiveHeartbeat(_ hb: RemoteHeartbeat) {
        if isHost {
            // Another device thinks it hosts: get its full state so the yield rule can decide.
            if hb.hostId != localId { requestState(from: hb.hostId, revision: hb.revision) }
            return
        }
        guard hb.hostId == stateHostId, var s = state, hb.revision <= lastRevision else {
            requestState(from: hb.hostId, revision: hb.revision)    // a missed revision / a new host
            return
        }
        guard hb.revision == lastRevision else { return }
        s.snapshot.positionMs = hb.positionMs
        s.snapshot.isPlaying = hb.isPlaying
        s.anchorSharedTime = hb.anchorSharedTime
        state = s
        reconcileLocal()
    }

    private func requestState(from host: String, revision: Int) {
        let t = now
        if let r = stateRequested[host], r.revision >= revision {
            // Already asked for this: re-ask only once the backoff for that attempt has passed.
            let wait = min(Self.stateRequestMaxBackoffMs, Self.stateRequestRetryMs * pow(2, Double(r.attempt)))
            guard t - r.at >= wait else { return }
            stateRequested[host] = (r.revision, t, r.attempt + 1)
        } else {
            stateRequested[host] = (revision, t, 0)
        }
        post(.stateRequest, RemoteStateRequest(haveRevision: lastRevision), to: .participant(host))
    }

    private func rosterChanged(_ ids: Set<String>) {
        guard isActive else { return }
        let grew = !ids.subtracting(roster).isEmpty
        roster = ids
        for gone in Set(peerInfo.keys).subtracting(ids) {
            peerInfo[gone] = nil
            unavailableByPeer[gone] = nil
        }
        if let hostId, !ids.contains(hostId) { electHost() }
        if grew {
            sendHello()
            if isHost { broadcastState() }
        }
    }

    /// The host is gone: the lowest remaining id takes over. (Only ever after a host LEFT — a
    /// joiner that simply hasn't heard from its host yet re-hellos instead; see `tick`.)
    private func electHost() {
        guard let localId, let winner = roster.min() else { return }
        if winner == localId {
            takeOverAsHost()
        } else {
            hostId = winner          // provisional until its first state arrives
            clock.reset(hostId: winner, isHost: false)
            lastRevision = -1
        }
    }

    private func takeOverAsHost() {
        DiagLog.shared.telemetry("action", "remote host handover → \(localId ?? "?")")
        var seed: RemoteQueueModel?
        if let s = state {
            // The old host's position estimated on ITS clock (our offset still points at it),
            // then re-anchored on ours — the shared timeline changes hands here.
            let pos = s.positionMs(at: clock.sharedNow ?? s.anchorSharedTime)
            var m = RemoteQueueModel(adopting: s, positionNow: pos, now: now)
            m.revision += 1
            seed = m
        }
        becomeHost(seed: seed ?? RemoteQueueModel())
    }

    private func becomeHost(seed: RemoteQueueModel?) {
        guard let localId else { return }
        hostId = localId
        stateHostId = localId
        clock.reset(hostId: localId, isHost: true)
        if let seed {
            model = seed
        } else {
            model = RemoteQueueModel()
            seedModelFromLocalPlayer()
        }
        model.revision = max(model.revision, lastRevision + 1)
        lastRevision = model.revision
        broadcastState()
        reconcileLocal()
    }

    /// The host's starting model = whatever its own player is running (window around the
    /// current row; rids = the local row uids, so the host's own speaker mirrors with no reload).
    /// Rows past the window stay in the local player and refill the model as the set advances
    /// (`refillFromLocalSource`) — the host's own long queue is never truncated.
    private func seedModelFromLocalPlayer() {
        guard let target, target.currentItem != nil else { return }
        let lo = max(0, target.currentIndex - RemoteQueueModel.windowBehind)
        let hi = min(target.queueCount, target.currentIndex + 1 + RemoteQueueModel.windowAhead)
        let items = (lo..<hi).map { target.item(at: $0) }
        model.rows = items.map { localRow($0) }
        model.index = target.currentIndex - lo
        model.isPlaying = target.isPlaying || target.isTransitioning   // a start in flight means ▶
        model.positionMs = target.positionMs
        model.anchor = now
        model.repeatMode = target.repeatMode
        model.revision = 1
    }

    private func localRow(_ item: SetlistPlayer.Item) -> RemoteRow {
        let rid = item.uid.uuidString
        ridByUid[item.uid] = rid
        return RemoteRow(item: item, rid: rid, appleMusicId: resolver.appleMusicIdForSong(item.id))
    }

    // MARK: - Host

    private func applyAsHost(_ command: RemoteCommand) {
        guard isHost else { return }
        if model.apply(command, now: now) {
            lastRevision = model.revision
            broadcastState()
            reconcileLocal()
        }
    }

    /// The full state to `recipient` (all ⇒ also this host's own `state`). The WIRE copy is
    /// size-capped: the window halves until the encoded envelope fits `maxStateBytes`.
    private func broadcastState(to recipient: RemoteRecipient = .all) {
        guard isHost, let localId else { return }
        let t = now
        let active = hostIsActive
        let full = model.state(hostId: localId, mode: mode, sessionId: sessionId, now: t, sessionActive: active)
        if recipient == .all {
            let structural = state?.revision != full.revision
            state = full
            lastBroadcastAt = t
            if structural { resolutionWindowChanged() }
        }
        guard let transport, var env = try? RemoteEnvelope.make(.state, full) else { return }
        var ahead = RemoteQueueModel.windowAhead
        var behind = RemoteQueueModel.windowBehind
        while Self.encodedSize(env) > Self.maxStateBytes, ahead > Self.minWindowAhead {
            ahead = max(Self.minWindowAhead, ahead / 2)
            behind = min(behind, max(1, ahead / 4))
            let trimmed = model.state(hostId: localId, mode: mode, sessionId: sessionId, now: t,
                                      behind: behind, ahead: ahead, sessionActive: active)
            guard let e = try? RemoteEnvelope.make(.state, trimmed) else { return }
            env = e
        }
        if ahead < RemoteQueueModel.windowAhead {
            DiagLog.shared.log("remote", "state window trimmed to \(ahead) ahead (\(Self.encodedSize(env)) bytes)")
        }
        transport.send(env, to: recipient, reliable: true)
    }

    nonisolated static func encodedSize(_ env: RemoteEnvelope) -> Int {
        (try? JSONEncoder().encode(env).count) ?? .max
    }

    /// The small 2 s beat (see `RemoteHeartbeat`).
    private func sendHeartbeat() {
        guard isHost, let localId else { return }
        let t = now
        lastBroadcastAt = t
        post(.heartbeat, RemoteHeartbeat(revision: model.revision, hostId: localId,
                                         currentRid: model.currentRow?.rid, positionMs: model.position(at: t),
                                         isPlaying: model.isPlaying, anchorSharedTime: t,
                                         sessionActive: hostIsActive),
             to: .all, reliable: false)
    }

    /// The model's upcoming tail ran low: pull the next rows from the host's OWN local set (the
    /// rows past the seeded window), so a long set keeps going for everyone.
    private func refillFromLocalSource() {
        guard isHost, let target, target.isRunning, model.upcoming.count < Self.hostRefillBelow,
              let lastRid = model.rows.last?.rid else { return }
        let lo = max(0, target.currentIndex)
        let hi = min(target.queueCount, lo + Self.tailLimit * 4)
        guard lo < hi, let k = (lo..<hi).last(where: { ridByUid[target.item(at: $0).uid] == lastRid }) else { return }
        var more: [SetlistPlayer.Item] = []
        var i = k + 1
        while i < target.queueCount, more.count < Self.hostRefillChunk {
            let it = target.item(at: i)
            if ridByUid[it.uid] == nil { more.append(it) }
            i += 1
        }
        guard !more.isEmpty else { return }
        DiagLog.shared.log("remote", "host refill +\(more.count) row(s) from the local set")
        applyAsHost(.append(rows: more.map(localRow)))
    }

    // MARK: - Tick

    /// One heartbeat of the session (0.5 s in production; tests call it directly).
    func tick() {
        guard isActive else { return }
        let t = now
        if isHost {
            if let cur = model.currentRow, model.isPlaying, let len = cur.row.lengthMs,
               model.position(at: t) > len + Self.hostAdvanceSlackMs {
                applyAsHost(.advanced(fromRid: cur.rid))
            }
            refillFromLocalSource()
            if t - lastBroadcastAt >= Self.heartbeatMs { sendHeartbeat() }
        } else {
            if let hostId {
                let interval: Double = clock.samples.count < SharedClock.sampleCap ? 1_000 : 5_000
                if t - lastPingAt >= interval {
                    lastPingAt = t
                    post(.ping, clock.makePing(), to: .participant(hostId), reliable: false)
                }
            }
            if state == nil, t - attachedAt >= Self.electionTimeoutMs, let localId {
                if roster == [localId] {
                    takeOverAsHost()            // alone: there is no host to wait for
                } else if t - lastHelloAt >= Self.electionTimeoutMs {
                    // Never elect a host over a peer that may simply be slow (an empty self-elected
                    // host would wipe the real one) — re-hello: a live host answers with its state.
                    sendHello()
                }
            }
        }
        guard let target else { return }
        switch localRole {
        case .speaker:
            reconcileLocal()
        case .controller:
            // Re-assert silence: whatever started since (a stray start, a pending one that
            // landed, another surface's play) goes quiet again.
            if target.isPlaying || target.isTransitioning { target.silenceForController() }
            for s in controllerSilencers { s() }        // idempotent — cheap when already silent
        }
    }

    // MARK: - Speaker: resolve + reconcile

    private func resolutionWindowChanged() {
        // Keep the cache bounded to the live window (rows leave it as the set advances).
        guard let s = state else { return }
        let live = Set(s.rowIds)
        resolutionCache = resolutionCache.filter { live.contains($0.key) }
        if locallyFailed.count > 500 { locallyFailed = locallyFailed.intersection(live) }
        pruneRidMapIfLarge()
    }

    /// `ridByUid` only grows (replaced rows leave stale uids): rebuild it from the rows still
    /// near the playhead when it gets large.
    private func pruneRidMapIfLarge() {
        guard ridByUid.count > Self.tailLimit * 10, let target else { return }
        let lo = max(0, target.currentIndex - RemoteQueueModel.windowBehind * 2)
        let hi = min(target.queueCount, target.currentIndex + 1 + Self.tailLimit * 2)
        var kept: [UUID: String] = [:]
        if lo < hi {
            for i in lo..<hi { let u = target.item(at: i).uid; if let r = ridByUid[u] { kept[u] = r } }
        }
        if isHost { for r in model.rows { if let u = UUID(uuidString: r.rid), ridByUid[u] != nil { kept[u] = r.rid } } }
        ridByUid = kept
    }

    /// nil = UNDECIDED (the cheap paths missed and the fuzzy matcher wasn't allowed yet).
    private func resolution(_ row: RemoteRow, allowFuzzy: Bool) -> RemoteSongResolver.Resolution? {
        if let r = resolutionCache[row.rid] { return r }
        guard let r = resolver.resolve(row, allowFuzzy: allowFuzzy) else { return nil }
        resolutionCache[row.rid] = r
        return r
    }

    /// A NEW row instance (fresh uid) for the local player — a cached resolution must never put
    /// the same uid into the queue twice (uid-keyed queue edits rely on uniqueness).
    private static func fresh(_ it: SetlistPlayer.Item) -> SetlistPlayer.Item {
        var n = SetlistPlayer.Item(id: it.id, title: it.title, artist: it.artist,
                                   lengthMs: it.lengthMs, repeatCount: it.repeatCount)
        n.variant = it.variant
        n.editionLocked = it.editionLocked
        return n
    }

    func reconcileLocal() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        guard isActive, localRole == .speaker, let target, state != nil else { return }
        // The listener's own action FIRST — reconciling before reading it would revert it.
        if expected != nil { observeLocalChanges() }
        guard isActive, localRole == .speaker, let s = state else { return }
        let t = now
        // A local edit this participant just sent is in flight: don't revert it underneath the
        // user before the host's answer lands.
        if t < pendingUntil, s.revision <= pendingBaseRevision { return }

        let rows = s.rows
        let curRel = s.snapshot.index
        var available: [(rid: String, item: SetlistPlayer.Item)] = []
        var availIdx: [String: Int] = [:]
        var unavailable: Set<String> = []
        for (i, r) in rows.enumerated() {
            if locallyFailed.contains(r.rid) { unavailable.insert(r.rid); continue }
            // The fuzzy matcher (a catalog scan) only for the rows about to play.
            let fuzzyOK = i >= curRel && i <= curRel + Self.fuzzyLookahead
            guard let res = resolution(r, allowFuzzy: fuzzyOK) else { continue }   // undecided
            if let it = res.item {
                availIdx[r.rid] = available.count
                available.append((r.rid, it))
            } else {
                unavailable.insert(r.rid)
            }
        }
        reportAvailability(unavailable)

        guard curRel >= 0, curRel < rows.count else { expected = observe(); return }
        let sessionRid = rows[curRel].rid
        let sessionPos = s.positionMs(at: clock.sharedNow ?? s.anchorSharedTime)
        // A row that ended HERE early: hold silent until the session moves (or restarts it).
        if let h = heldAfterEnd, sessionRid != h.sessionRid || sessionPos + 5_000 < h.sessionPos {
            heldAfterEnd = nil
        }
        if heldAfterEnd != nil {
            if target.isPlaying, !target.isTransitioning { target.setPlaying(false) }
            expected = observe()
            return
        }
        // The row to sound here: the session's current row, or the next one this device can play.
        guard let desiredRid = rows[curRel...].first(where: { availIdx[$0.rid] != nil })?.rid,
              let dIdx = availIdx[desiredRid] else {
            if target.isPlaying, !target.isTransitioning { target.setPlaying(false) }
            expected = observe()
            return
        }
        let onSessionCurrent = desiredRid == sessionRid
        let desiredPos = onSessionCurrent ? sessionPos : 0
        let threshold = target.hasCoarsePosition ? Self.coarseDriftThresholdMs : Self.driftThresholdMs
        // THIS device's system paused it (a call, Siri, an unplugged route) — never resumed by the
        // app: the speaker follows the session SILENTLY (moves load paused) until the listener's
        // own ▶ / Rejoin.
        let systemHeld = !rejoining && target.isSystemPaused && !target.isPlaying
        if pausedHere != (systemHeld && s.isPlaying) { pausedHere = systemHeld && s.isPlaying }

        var moved = false
        let localCurRid = target.currentItem.flatMap { ridByUid[$0.uid] }
        if localCurRid != desiredRid {
            let startAt = onSessionCurrent && desiredPos > 1_500 ? desiredPos : 0
            let hit = s.isPlaying && !systemHeld
                ? target.upcomingItems(limit: Self.tailLimit).first(where: { ridByUid[$0.uid] == desiredRid })
                : nil   // a PAUSED session (or a system-held speaker) loads paused (a jump would sound first)
            if let hit {
                target.jumpToUpcoming(uid: hit.uid, atMs: startAt)
            } else {
                let items = available.map { Self.fresh($0.item) }
                target.play(items, startIndex: dIdx, atMs: startAt, startPaused: !s.isPlaying || systemHeld)
                remap(available.map(\.rid), from: 0, expecting: items)
            }
            moved = true
            seekOwed = false            // the start cue carries the position
            driftStrikes = 0
            pendingSeekMs = nil
        }
        if target.repeatMode != s.repeatMode { target.setRepeatMode(s.repeatMode) }
        // Shuffle: the host re-orders; a participant mirrors the flag (its order follows from the
        // tail sync below). The host's own long local set is never re-shuffled underneath it.
        if !isHost, target.isRunning, target.shuffleEnabled != s.shuffleEnabled { target.setShuffle(s.shuffleEnabled) }
        syncTail(Array(available[(dIdx + 1)...]))

        // ▶/⏸ — not while a start / buffering is still settling, and an apply that hasn't
        // taken yet is re-issued only after `playRetryMs`.
        if !moved, !target.isTransitioning, target.isRunning, target.isPlaying != s.isPlaying,
           !(s.isPlaying && systemHeld) {
            let due = lastPlayApply.map { $0.on != s.isPlaying || t - $0.at >= Self.playRetryMs } ?? true
            if due {
                if s.isPlaying, onSessionCurrent, abs(target.positionMs - desiredPos) > threshold {
                    target.seek(toMs: desiredPos)          // resume AT the session position
                    pendingSeekMs = desiredPos
                }
                target.setPlaying(s.isPlaying)
                lastPlayApply = (s.isPlaying, t)
            }
        }
        // Drift / session seeks — never while buffering, only on the session's own row.
        if !moved, onSessionCurrent, s.isPlaying, target.isPlaying, !target.isTransitioning {
            let off = abs(target.positionMs - desiredPos)
            let synced = clock.isSynced && clock.hostId == s.hostId
            if off > threshold {
                // A NEW revision (a session seek, a resume) is applied at once — on a synced
                // clock, or fresh off the wire; plain drift must persist and respects a cooldown.
                let owed = seekOwed && (synced || t - stateReceivedAt < 1_000)
                if synced { driftStrikes += 1 }
                if owed || (synced && driftStrikes >= Self.driftStrikesNeeded && t - lastDriftFixAt >= Self.driftCooldownMs) {
                    target.seek(toMs: desiredPos)
                    pendingSeekMs = desiredPos
                    lastDriftFixAt = t
                    driftStrikes = 0
                }
            } else {
                driftStrikes = 0
            }
            seekOwed = false
        }
        expected = observe()
    }

    /// Make the local upcoming tail match `desired`. The local rows that belong to the session
    /// are the SEGMENT up to the last rid-mapped one; rows after it (the host's own set beyond
    /// the window) are kept — only the segment is ever edited.
    private func syncTail(_ desired: [(rid: String, item: SetlistPlayer.Item)]) {
        guard let target, target.isRunning else { return }
        let local = target.upcomingItems(limit: Self.tailLimit)
        let mappedCount = (local.lastIndex(where: { ridByUid[$0.uid] != nil }) ?? -1) + 1
        let segment = local.prefix(mappedCount).map { ridByUid[$0.uid] }
        let want = desired.map(\.rid)
        guard segment != want.map(Optional.some) else { return }
        if mappedCount < want.count, Array(want.prefix(mappedCount)).map(Optional.some) == segment {
            // The session grew: the new rows go right after the segment.
            let extra = desired.dropFirst(mappedCount).map { Self.fresh($0.item) }
            let at = target.currentIndex + 1 + mappedCount
            if mappedCount < local.count {
                target.insertUpcoming(extra, before: local[mappedCount].uid)
            } else {
                target.appendToQueue(extra)
            }
            remap(Array(want.dropFirst(mappedCount)), from: at, expecting: extra)
        } else {
            let items = desired.map { Self.fresh($0.item) }
            target.replaceUpcoming(first: mappedCount, with: items)
            remap(want, from: target.currentIndex + 1, expecting: items)
        }
    }

    /// Bind session rids to the rows the local player now holds, by POSITION (a player may copy
    /// rows while stamping editions; position is what it can't change in a synchronous apply).
    private func remap(_ rids: [String], from start: Int, expecting items: [SetlistPlayer.Item]) {
        guard let target else { return }
        for (k, rid) in rids.enumerated() {
            let i = start + k
            if i >= 0, i < target.queueCount {
                ridByUid[target.item(at: i).uid] = rid
            } else if k < items.count {
                ridByUid[items[k].uid] = rid
            }
        }
    }

    private func reportAvailability(_ set: Set<String>) {
        localUnavailable = set
        guard set != reportedUnavailable else { return }
        reportedUnavailable = set
        post(.availability, RemoteAvailability(unavailableRids: set.sorted()), to: .all)
        if !set.isEmpty {
            DiagLog.shared.log("remote", "unavailable on this device: \(set.count) row(s)")
        }
    }

    // MARK: - Speaker: local user changes → commands

    private func observe() -> LocalObservation? {
        guard let target else { return nil }
        let cur = target.currentItem
        return LocalObservation(isRunning: target.isRunning, generation: target.queueGeneration,
                                currentUid: cur?.uid,
                                upcomingUids: target.upcomingItems(limit: Self.tailLimit).map(\.uid),
                                isPlaying: target.isPlaying, positionMs: target.positionMs, at: now,
                                repeatMode: target.repeatMode, shuffle: target.shuffleEnabled,
                                transitionSeq: target.transitionSeq,
                                userTransitionSeq: target.lastUserTransitionSeq,
                                lastCause: target.lastTransitionCause,
                                playIntentSeq: target.userPlayIntentSeq,
                                playIntent: target.lastUserPlayIntent)
    }

    private func observeLocalChanges() {
        guard !isObservingLocal, let target, let obs = observe() else { return }
        isObservingLocal = true
        defer { isObservingLocal = false }
        guard let exp = expected else { expected = obs; return }
        expected = obs
        let t = obs.at
        var cmds: [RemoteCommand] = []
        let userMoved = obs.userTransitionSeq != exp.userTransitionSeq
        let autoMoved = !userMoved && obs.transitionSeq != exp.transitionSeq
        let expRid = exp.currentUid.flatMap { ridByUid[$0] }

        if autoMoved {
            // The player moved BY ITSELF — never the listener's intent.
            cmds += automaticTransition(obs.lastCause, fromRid: expRid)
        } else if userMoved, obs.isRunning, let cur = obs.currentUid {
            pendingSeekMs = nil
            if ridByUid[cur] == nil {
                // A brand-new set the listener started here SINCE joining (Browse ▶, a widget,
                // Siri…) → the session's set. (A set already playing when we joined never is.)
                let lo = max(0, target.currentIndex - RemoteQueueModel.windowBehind)
                let hi = min(target.queueCount, target.currentIndex + 1 + RemoteQueueModel.windowAhead)
                let rows = (lo..<hi).map { localRow(target.item(at: $0)) }
                cmds.append(.play(rows: rows, startIndex: target.currentIndex - lo))
            } else if cur != exp.currentUid {
                if let expRid, exp.upcomingUids.first == cur {
                    cmds.append(.advanced(fromRid: expRid))       // ⏭ (applied once, while still current)
                } else if let rid = ridByUid[cur] {
                    cmds.append(.jumpTo(rid: rid))
                }
            } else {
                cmds.append(.seek(ms: obs.positionMs))            // ⏮ restarted the same row
            }
        } else if obs.isRunning, exp.isRunning, obs.currentUid != nil, obs.currentUid == exp.currentUid {
            if obs.shuffle != exp.shuffle {
                cmds.append(.setShuffle(obs.shuffle))             // the host re-orders; we mirror it
            } else if obs.generation != exp.generation {
                cmds += queueEditCommands(exp: exp, obs: obs)
            }
            if !target.isTransitioning {
                let predicted = exp.isPlaying ? exp.positionMs + Int(t - exp.at) : exp.positionMs
                if abs(obs.positionMs - predicted) > Self.seekDetectMs {
                    if let ps = pendingSeekMs, abs(obs.positionMs - ps) <= Self.seekDetectMs {
                        pendingSeekMs = nil                       // OUR seek landing late
                    } else {
                        cmds.append(.seek(ms: obs.positionMs))
                    }
                }
            }
        }
        // ▶/⏸ the listener pressed (a cascade halt / interruption / stall never counts).
        if obs.playIntentSeq != exp.playIntentSeq, obs.isRunning, let s = state, obs.playIntent != s.isPlaying {
            cmds.append(.setPlaying(obs.playIntent))
        }
        if obs.isRunning, obs.repeatMode != exp.repeatMode, obs.repeatMode != state?.repeatMode {
            cmds.append(.setRepeat(obs.repeatMode))
        }
        guard !cmds.isEmpty else { return }
        DiagLog.shared.log("remote", "local change → \(cmds.count) command(s)")
        if !isHost {
            pendingUntil = t + Self.pendingHoldMs
            pendingBaseRevision = lastRevision
        }
        for c in cmds { send(c) }
    }

    /// The local player changed rows on its own (`cause`) away from session row `fromRid`.
    private func automaticTransition(_ cause: SetlistPlayer.TransitionCause, fromRid: String?) -> [RemoteCommand] {
        pendingSeekMs = nil
        switch cause {
        case .user, .remote:
            return []
        case .naturalEnd:
            guard let fromRid, let s = state else { return [] }
            let pos = s.positionMs(at: clock.sharedNow ?? s.anchorSharedTime)
            let cur = s.currentRow
            if cur?.rid == fromRid, cur?.row.lengthMs.map({ pos >= $0 - Self.naturalEndToleranceMs }) ?? true {
                return [.advanced(fromRid: fromRid)]      // the row really ended — for everyone
            }
            // Our copy ended early (shorter), or the row we played in place of one we can't play
            // ended: wait silently for the session, never re-mirror the row we just finished.
            heldAfterEnd = (fromRid, cur?.rid, pos)
            DiagLog.shared.log("remote", "local copy ended before the session — holding silent")
            return []
        case .autoSkip, .stallHop, .unplayable:
            // This device can't play that row right now: mirror the session AROUND it.
            if let fromRid { locallyFailed.insert(fromRid) }
            return []
        }
    }

    /// Same current row, queue moved: removals, additions (next / end), and re-orders.
    private func queueEditCommands(exp: LocalObservation, obs: LocalObservation) -> [RemoteCommand] {
        guard let target else { return [] }
        var cmds: [RemoteCommand] = []
        let expRids = exp.upcomingUids.compactMap { ridByUid[$0] }
        let obsKnown = obs.upcomingUids.compactMap { ridByUid[$0] }
        let obsKnownSet = Set(obsKnown)
        for rid in expRids where !obsKnownSet.contains(rid) { cmds.append(.remove(rid: rid)) }
        // New local rows (no rid yet): a leading run is "play next", the rest are appends.
        let upcoming = target.upcomingItems(limit: Self.tailLimit)
        var leading: [SetlistPlayer.Item] = [], trailing: [SetlistPlayer.Item] = []
        var seenKnown = false
        for it in upcoming {
            if ridByUid[it.uid] != nil { seenKnown = true; continue }
            if seenKnown { trailing.append(it) } else { leading.append(it) }
        }
        if !expRids.isEmpty, !leading.isEmpty { cmds.append(.enqueueNext(rows: leading.map(localRow))) }
        else if !leading.isEmpty { trailing.insert(contentsOf: leading, at: 0) }
        if !trailing.isEmpty { cmds.append(.append(rows: trailing.map(localRow))) }
        let kept = expRids.filter(obsKnownSet.contains)
        if kept != obsKnown.filter(Set(expRids).contains) { cmds.append(.reorder(rids: obsKnown)) }
        return cmds
    }

    // MARK: - Outbound

    private func sendHello(to recipient: RemoteRecipient = .all) {
        if recipient == .all { lastHelloAt = now }
        post(.hello, RemoteHello(name: deviceName, role: localRole, platform: platform,
                                 caps: localCaps.isEmpty ? nil : localCaps), to: recipient)
    }

    private func post<T: Encodable>(_ kind: RemoteMessageKind, _ body: T, to: RemoteRecipient,
                                    reliable: Bool = true) {
        guard let transport, let env = try? RemoteEnvelope.make(kind, body) else { return }
        transport.send(env, to: to, reliable: reliable)
    }
}

// MARK: - Showcase seed (App Store screenshots)

extension RemoteSessionController {
    /// `PDJ_SEED_REMOTE=showcase`: the controller in a fake BACKSEAT session — a loopback hub
    /// with an in-memory "Car" speaker, playing the playback showcase set — so the Remote tab can
    /// be screenshotted without a second device or a FaceTime call.
    func seedShowcaseIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_REMOTE"] == "showcase", !isActive else { return }
        #if os(tvOS)
        // The TV never starts a session — it JOINS one a phone offers and plays as a speaker. So
        // on tvOS the showcase is a Listen Together session hosted by an in-memory "iPhone" that
        // owns the set; the TV attaches as a participant and receives it over the loopback.
        let tvHub = LoopbackHub()
        let phoneLink = tvHub.join(id: "A-host")
        let tvLink = tvHub.join(id: "B-tv")
        let phone = RemoteSessionController(target: InMemoryRemoteTarget(), resolver: .acceptAll,
                                            deviceName: "iPhone", platform: "iPhone")
        phone.attach(phoneLink, mode: .listenTogether, asHost: true, seed: Self.showcaseSeed(clock: phone.clock))
        attach(tvLink, mode: .listenTogether, asHost: false)
        showcaseKeepAlive = [phone, phoneLink]
        showcaseHub = tvHub
        return
        #else
        let hub = LoopbackHub()
        let me = hub.join(id: "A-host")
        let carLink = hub.join(id: "B-car")
        let car = RemoteSessionController(target: InMemoryRemoteTarget(), resolver: .acceptAll,
                                          deviceName: "Car", platform: "iPhone")
        car.attach(carLink, mode: .backseat, asHost: false)
        attach(me, mode: .backseat, asHost: true, seed: Self.showcaseSeed(clock: clock))
        showcaseKeepAlive = [car, carLink]
        showcaseHub = hub
        #endif
    }

    /// The showcase set (the playback showcase's rows), playing 1:37 into the first track.
    private static func showcaseSeed(clock: SharedClock) -> RemoteQueueModel {
        var seed = RemoteQueueModel()
        seed.rows = PlaybackSessionStore.showcaseRows.map { RemoteRow(row: $0) }
        seed.index = 0
        seed.isPlaying = true
        seed.positionMs = 97_000
        seed.anchor = clock.localNow()
        seed.revision = 1
        seed.sourceName = "Golden Hour Rooftop"
        return seed
    }
}

extension RemoteSongResolver {
    /// Plays every row as-is (the showcase's fake speaker has no catalog).
    static var acceptAll: RemoteSongResolver {
        var r = RemoteSongResolver(catalogItem: { _ in nil })
        r.lastResort = { row in
            SetlistPlayer.Item(id: row.songId, title: row.title, artist: row.artist, lengthMs: row.row.lengthMs)
        }
        return r
    }
}
