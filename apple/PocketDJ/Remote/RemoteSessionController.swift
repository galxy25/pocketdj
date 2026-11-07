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
///     LOWEST id takes over from the last state it saw.
///   • device role — a SPEAKER plays the session's audio on its own player (reconciled from the
///     host's state); a CONTROLLER plays nothing (the Backseat remote). In Listen Together every
///     device is a speaker; in Backseat the host starts as the controller and joiners as
///     speakers. Any device may flip its own role.
///
/// RECONCILE (a speaker, every 0.5 s tick + on every state): resolve the state's window against
/// this device's catalog (`RemoteSongResolver` — unavailable rows are skipped locally and
/// reported), then make the local player match with the cheapest move — tail edit, jump to an
/// upcoming row, or a fresh `play(…startIndex:)` — and correct position only when the drift
/// exceeds `driftThresholdMs` (never more often than `driftCooldownMs`).
///
/// LOCAL CHANGES (a speaker whose user drives the ordinary Now Playing UI): each tick diffs the
/// local player against what the session last left it as, and turns real changes into commands
/// (skip/jump/advance, ▶/⏸, a scrub, queue adds/removes/reorders, a brand-new set). A guard window
/// after every reconcile move keeps the player's own async settling from echoing back as
/// commands — applying remote state never re-broadcasts itself.
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
    static let driftCooldownMs: Double = 5_000
    /// After a reconcile move, local changes are not read as user intent for this long.
    static let applyGuardMs: Double = 2_000
    /// A local edit a participant sent holds reconcile until a newer state (or this timeout).
    static let pendingHoldMs: Double = 3_000
    /// A position jump bigger than this between ticks is a user scrub.
    static let seekDetectMs = 3_000
    /// A local ▶/⏸ flip must persist this long before it counts (load blips don't).
    static let playFlipHoldMs: Double = 900
    /// No state from any host this long after joining ⇒ elect one.
    static let electionTimeoutMs: Double = 8_000
    /// The host advances on its own when no speaker reported a track end this long past it.
    static let hostAdvanceSlackMs = 8_000

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
    @ObservationIgnored var isObservingSessions = false
    var statusMessage: String?

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

    // Participant
    @ObservationIgnored private var lastRevision = -1
    @ObservationIgnored private var lastPingAt: Double = 0
    @ObservationIgnored private var attachedAt: Double = 0

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
    }
    /// Local row instance → session rid.
    @ObservationIgnored private var ridByUid: [UUID: String] = [:]
    @ObservationIgnored private var resolutionCache: [String: RemoteSongResolver.Resolution] = [:]
    @ObservationIgnored private var expected: LocalObservation?
    @ObservationIgnored private var guardUntil: Double = 0
    @ObservationIgnored private var pendingUntil: Double = 0
    @ObservationIgnored private var pendingBaseRevision = -1
    @ObservationIgnored private var lastDriftFixAt: Double = -.infinity
    @ObservationIgnored private var playFlip: (playing: Bool, since: Double)?
    @ObservationIgnored private var reportedUnavailable: Set<String>?

    /// Phase-2 extension point: handlers for message kinds this controller doesn't own
    /// (multiplayer Mix events ride the SAME session/transport under their own `kind`).
    @ObservationIgnored private var extensionHandlers: [String: (RemoteEnvelope, String) -> Void] = [:]

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
        statusMessage = nil
        if asHost { becomeHost(seed: seed) }
        if localRole == .controller { target?.setPlaying(false) }
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
        localId = nil; hostId = nil
        state = nil
        roster = []; peerInfo = [:]; unavailableByPeer = [:]; localUnavailable = []
        model = RemoteQueueModel()
        ridByUid = [:]; resolutionCache = [:]; expected = nil
        reportedUnavailable = nil
        let hub = showcaseHub
        showcaseHub = nil
        showcaseKeepAlive = []
        hub?.end()                      // the fake car leaves with us
        localRole = .speaker
        clock.reset(hostId: nil, isHost: false)
        DiagLog.shared.telemetry("action", "remote end leave=\(leave)")
    }

    /// Flip THIS device between speaker and controller.
    func setLocalRole(_ role: RemoteDeviceRole) {
        guard isActive, role != localRole else { return }
        localRole = role
        if role == .controller {
            target?.setPlaying(false)
            expected = nil
        } else {
            expected = nil
            ridByUid = [:]   // re-mirror from scratch
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

    // MARK: - Extension point

    func registerHandler(kind: String, _ handler: @escaping (RemoteEnvelope, String) -> Void) {
        extensionHandlers[kind] = handler
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

    private func receiveState(_ s: RemotePlaybackState) {
        if isHost {
            // Two hosts (a hand-over race): the LOWER id wins, deterministically on both sides.
            guard let localId, s.hostId < localId else { return }
            DiagLog.shared.log("remote", "yield host to \(s.hostId)")
        }
        if s.hostId != hostId {
            hostId = s.hostId
            clock.reset(hostId: s.hostId, isHost: false)
            lastRevision = -1
            lastPingAt = 0
        }
        guard s.revision >= lastRevision else { return }
        let structural = s.revision > lastRevision
        lastRevision = s.revision
        state = s
        mode = s.mode
        if structural { resolutionWindowChanged() }
        reconcileLocal()
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

    /// The host is gone (or never showed): the lowest remaining id takes over.
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
    private func seedModelFromLocalPlayer() {
        guard let target, target.currentItem != nil else { return }
        let lo = max(0, target.currentIndex - RemoteQueueModel.windowBehind)
        let hi = min(target.queueCount, target.currentIndex + 1 + RemoteQueueModel.windowAhead)
        let items = (lo..<hi).map { target.item(at: $0) }
        model.rows = items.map { localRow($0) }
        model.index = target.currentIndex - lo
        model.isPlaying = target.isPlaying
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

    private func broadcastState(to recipient: RemoteRecipient = .all) {
        guard isHost, let localId else { return }
        let s = model.state(hostId: localId, mode: mode, sessionId: sessionId, now: now)
        if recipient == .all {
            let structural = state?.revision != s.revision
            state = s
            lastBroadcastAt = now
            if structural { resolutionWindowChanged() }
        }
        post(.state, s, to: recipient)
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
            if t - lastBroadcastAt >= Self.heartbeatMs { broadcastState() }
        } else {
            if let hostId {
                let interval: Double = clock.samples.count < SharedClock.sampleCap ? 1_000 : 5_000
                if t - lastPingAt >= interval {
                    lastPingAt = t
                    post(.ping, clock.makePing(), to: .participant(hostId), reliable: false)
                }
            }
            if state == nil, t - attachedAt >= Self.electionTimeoutMs, roster.count > 0,
               hostId == nil || !roster.contains(hostId!) {
                electHost()
            }
        }
        if localRole == .speaker, target != nil {
            observeLocalChanges()
            reconcileLocal()
        }
    }

    // MARK: - Speaker: resolve + reconcile

    private func resolutionWindowChanged() {
        // Keep the cache bounded to the live window (rows leave it as the set advances).
        guard let s = state else { return }
        let live = Set(s.rowIds)
        resolutionCache = resolutionCache.filter { live.contains($0.key) }
    }

    private func resolution(_ row: RemoteRow) -> RemoteSongResolver.Resolution {
        if let r = resolutionCache[row.rid] { return r }
        let r = resolver.resolve(row)
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
        guard isActive, localRole == .speaker, let target, let s = state else { return }
        let t = now
        // A local edit this participant just sent is in flight: don't revert it underneath the
        // user before the host's answer lands.
        if t < pendingUntil, s.revision <= pendingBaseRevision { return }

        let rows = s.rows
        var available: [(rid: String, item: SetlistPlayer.Item)] = []
        var unavailable: [String] = []
        for r in rows {
            if let it = resolution(r).item { available.append((r.rid, it)) } else { unavailable.append(r.rid) }
        }
        reportAvailability(Set(unavailable))

        let curRel = s.snapshot.index
        guard curRel >= 0, curRel < rows.count else { return }
        // The row to sound here: the session's current row, or the next one this device can play.
        guard let desiredRid = rows[curRel...].first(where: { r in available.contains { $0.rid == r.rid } })?.rid,
              let dIdx = available.firstIndex(where: { $0.rid == desiredRid }) else {
            if target.isPlaying, t >= guardUntil { target.setPlaying(false); guardUntil = t + Self.applyGuardMs }
            expected = observe()
            return
        }
        let onSessionCurrent = desiredRid == rows[curRel].rid
        let desiredPos = onSessionCurrent ? s.positionMs(at: clock.sharedNow ?? s.anchorSharedTime) : 0

        var moved = false
        let localCurRid = target.currentItem.flatMap { ridByUid[$0.uid] }
        if localCurRid != desiredRid {
            if let hit = target.upcomingItems(limit: RemoteQueueModel.windowAhead * 2)
                .first(where: { ridByUid[$0.uid] == desiredRid }) {
                target.jumpToUpcoming(uid: hit.uid)
                if onSessionCurrent, desiredPos > 1_500 { target.seek(toMs: desiredPos) }
            } else {
                let items = available.map { Self.fresh($0.item) }
                target.play(items, startIndex: dIdx, atMs: onSessionCurrent ? desiredPos : 0)
                remap(available.map(\.rid), from: 0, expecting: items)
                if !s.isPlaying { target.setPlaying(false) }   // a paused session loads paused
            }
            moved = true
        }
        // The tail after the current row.
        let desiredTail = Array(available[(dIdx + 1)...])
        let localTail = target.upcomingItems(limit: RemoteQueueModel.windowAhead * 2)
        let localTailRids = localTail.map { ridByUid[$0.uid] }
        let desiredTailRids = desiredTail.map(\.rid)
        if localTailRids != desiredTailRids.map(Optional.some) {
            if localTailRids.count < desiredTailRids.count,
               Array(desiredTailRids.prefix(localTailRids.count)).map(Optional.some) == localTailRids {
                let extra = desiredTail.dropFirst(localTailRids.count).map { Self.fresh($0.item) }
                target.appendToQueue(extra)
                remap(Array(desiredTailRids.dropFirst(localTailRids.count)),
                      from: target.queueCount - extra.count, expecting: extra)
            } else {
                let items = desiredTail.map { Self.fresh($0.item) }
                target.replaceUpcoming(with: items)
                remap(desiredTailRids, from: target.currentIndex + 1, expecting: items)
            }
        }
        if target.repeatMode != s.repeatMode { target.setRepeatMode(s.repeatMode) }
        if moved { guardUntil = t + Self.applyGuardMs }

        // ▶/⏸ — not while a move is still settling (a toggle mid-load would be refused or, on an
        // async backend, double-fire).
        if t >= guardUntil, !target.isTransitioning, target.isPlaying != s.isPlaying {
            target.setPlaying(s.isPlaying)
            guardUntil = t + Self.applyGuardMs
        }
        // Drift: only against a clock measured on THIS host, on the session's own row, and
        // never chasing every heartbeat.
        if !moved, onSessionCurrent, s.isPlaying, target.isPlaying, t >= guardUntil,
           clock.isSynced, clock.hostId == s.hostId, t - lastDriftFixAt >= Self.driftCooldownMs,
           abs(target.positionMs - desiredPos) > Self.driftThresholdMs {
            target.seek(toMs: desiredPos)
            lastDriftFixAt = t
            guardUntil = t + Self.applyGuardMs
        }
        expected = observe()
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
                                upcomingUids: target.upcomingItems(limit: RemoteQueueModel.windowAhead * 2).map(\.uid),
                                isPlaying: target.isPlaying, positionMs: target.positionMs, at: now,
                                repeatMode: target.repeatMode, shuffle: target.shuffleEnabled)
    }

    private func observeLocalChanges() {
        guard let target, let obs = observe() else { return }
        let t = obs.at
        guard let exp = expected, t >= guardUntil else { expected = obs; playFlip = nil; return }
        var cmds: [RemoteCommand] = []

        if exp.isRunning, !obs.isRunning {
            cmds.append(.setPlaying(false))                    // stopped locally
        } else if obs.isRunning, let cur = obs.currentUid {
            if ridByUid[cur] == nil {
                // A brand-new set started locally (Browse ▶, a widget, Siri…) → the session's set.
                let lo = max(0, target.currentIndex - RemoteQueueModel.windowBehind)
                let hi = min(target.queueCount, target.currentIndex + 1 + RemoteQueueModel.windowAhead)
                let rows = (lo..<hi).map { localRow(target.item(at: $0)) }
                cmds.append(.play(rows: rows, startIndex: target.currentIndex - lo))
            } else if cur != exp.currentUid {
                let expRid = exp.currentUid.flatMap { ridByUid[$0] }
                if let expRid, exp.upcomingUids.first == cur {
                    cmds.append(.advanced(fromRid: expRid))       // ⏭ or a natural track end
                } else if let rid = ridByUid[cur] {
                    cmds.append(.jumpTo(rid: rid))
                }
            } else {
                if obs.shuffle != exp.shuffle {
                    cmds.append(.setShuffle(obs.shuffle))         // the host re-orders; we mirror it
                } else if obs.generation != exp.generation {
                    cmds += queueEditCommands(exp: exp, obs: obs)
                }
                let predicted = exp.isPlaying ? exp.positionMs + Int(t - exp.at) : exp.positionMs
                if abs(obs.positionMs - predicted) > Self.seekDetectMs {
                    cmds.append(.seek(ms: obs.positionMs))
                }
                // ▶/⏸ — must HOLD (a load blip / stall is not the user pausing).
                if obs.isPlaying != (state?.isPlaying ?? obs.isPlaying), !target.isTransitioning {
                    if let f = playFlip, f.playing == obs.isPlaying {
                        if t - f.since >= Self.playFlipHoldMs {
                            cmds.append(.setPlaying(obs.isPlaying))
                            playFlip = nil
                        }
                    } else {
                        playFlip = (obs.isPlaying, t)
                    }
                } else {
                    playFlip = nil
                }
            }
            if obs.repeatMode != exp.repeatMode, obs.repeatMode != state?.repeatMode {
                cmds.append(.setRepeat(obs.repeatMode))
            }
        }
        expected = obs
        guard !cmds.isEmpty else { return }
        DiagLog.shared.log("remote", "local change → \(cmds.count) command(s)")
        if !isHost {
            pendingUntil = t + Self.pendingHoldMs
            pendingBaseRevision = lastRevision
        }
        for c in cmds { send(c) }
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
        let upcoming = target.upcomingItems(limit: RemoteQueueModel.windowAhead * 2)
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
        post(.hello, RemoteHello(name: deviceName, role: localRole, platform: platform), to: recipient)
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
        let hub = LoopbackHub()
        let me = hub.join(id: "A-host")
        let carLink = hub.join(id: "B-car")
        let car = RemoteSessionController(target: InMemoryRemoteTarget(), resolver: .acceptAll,
                                          deviceName: "Car", platform: "iPhone")
        car.attach(carLink, mode: .backseat, asHost: false)
        var seed = RemoteQueueModel()
        seed.rows = PlaybackSessionStore.showcaseRows.map { RemoteRow(row: $0) }
        seed.index = 0
        seed.isPlaying = true
        seed.positionMs = 97_000
        seed.anchor = clock.localNow()
        seed.revision = 1
        seed.sourceName = "Golden Hour Rooftop"
        attach(me, mode: .backseat, asHost: true, seed: seed)
        showcaseKeepAlive = [car, carLink]
        showcaseHub = hub
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
