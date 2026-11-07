import Foundation

/// Who a message goes to. `.participant` is a transport participant id.
enum RemoteRecipient: Equatable, Sendable {
    case all
    case participant(String)
}

/// One received message: the envelope + the SENDER's participant id.
struct RemoteInbound {
    var envelope: RemoteEnvelope
    var from: String
}

/// The session transport, abstracted so the controller never touches GroupActivities directly:
/// `GroupSessionTransport` is SharePlay; `LoopbackTransport` is an in-memory hub connecting N
/// fake peers (unit tests + the `PDJ_SEED_REMOTE=showcase` seed). Messages never loop back to
/// the sender (GroupSessionMessenger semantics).
@MainActor
protocol RemoteTransport: AnyObject {
    /// This device's participant id — stable for the session, comparable across devices (the
    /// host hand-over elects the LOWEST id).
    var localParticipantId: String { get }
    /// Every message other participants send to us (or to all).
    var inbound: AsyncStream<RemoteInbound> { get }
    /// The ACTIVE participant set (including the local one) — yields on every join/leave;
    /// finishes when the session ends.
    var participants: AsyncStream<Set<String>> { get }
    /// `reliable: false` = best-effort delivery (clock pings — a stale ping is worse than none).
    func send(_ envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Bool)
    /// Leave the session (other participants carry on).
    func leave()
}

// MARK: - Loopback

/// An in-memory "SharePlay": connects any number of `LoopbackTransport`s. Delivery is async (a
/// hop through each receiver's stream), in send order per receiver — close enough to a reliable
/// messenger for the state machine, and it never needs a FaceTime call.
@MainActor
final class LoopbackHub {
    private var peers: [String: LoopbackTransport] = [:]
    /// Optional one-way latency injection (seconds) per (from, to) — the clock tests' asymmetric
    /// delay. nil ⇒ immediate.
    var latency: ((String, String) -> Double)?
    /// Optional loss injection: true ⇒ the envelope from → to is dropped (a lost send).
    var drop: ((RemoteEnvelope, String, RemoteRecipient) -> Bool)?

    init() {}

    /// Join a new peer under `id` (ids order the hand-over election, so tests pick them).
    func join(id: String = UUID().uuidString) -> LoopbackTransport {
        let t = LoopbackTransport(id: id, hub: self)
        peers[id] = t
        broadcastRoster()
        return t
    }

    var participantIds: Set<String> { Set(peers.keys) }

    fileprivate func remove(_ id: String) {
        guard let t = peers.removeValue(forKey: id) else { return }
        t.finish()
        broadcastRoster()
    }

    /// End the session for everyone.
    func end() {
        let all = peers.values
        peers.removeAll()
        for t in all { t.finish() }
    }

    fileprivate func deliver(_ env: RemoteEnvelope, from: String, to: RemoteRecipient) {
        if drop?(env, from, to) == true { return }
        let targets: [LoopbackTransport]
        switch to {
        case .all: targets = peers.values.filter { $0.localParticipantId != from }
        case .participant(let id): targets = [peers[id]].compactMap { $0 }.filter { $0.localParticipantId != from }
        }
        for t in targets {
            let msg = RemoteInbound(envelope: env, from: from)
            if let delay = latency?(from, t.localParticipantId), delay > 0 {
                Task { @MainActor [weak t] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    t?.receive(msg)
                }
            } else {
                t.receive(msg)
            }
        }
    }

    private func broadcastRoster() {
        let ids = participantIds
        for t in peers.values { t.rosterChanged(ids) }
    }
}

@MainActor
final class LoopbackTransport: RemoteTransport {
    let localParticipantId: String
    let inbound: AsyncStream<RemoteInbound>
    let participants: AsyncStream<Set<String>>
    private let inboundCont: AsyncStream<RemoteInbound>.Continuation
    private let rosterCont: AsyncStream<Set<String>>.Continuation
    private weak var hub: LoopbackHub?
    /// Every envelope this peer SENT (tests assert "no echo" against it).
    private(set) var sent: [(RemoteEnvelope, RemoteRecipient)] = []

    fileprivate init(id: String, hub: LoopbackHub) {
        localParticipantId = id
        self.hub = hub
        (inbound, inboundCont) = AsyncStream.makeStream(of: RemoteInbound.self)
        (participants, rosterCont) = AsyncStream.makeStream(of: Set<String>.self,
                                                            bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Bool) {
        sent.append((envelope, to))
        hub?.deliver(envelope, from: localParticipantId, to: to)
    }

    func leave() { hub?.remove(localParticipantId) }

    /// Inject a raw envelope as if `from` sent it (tests: unknown kinds, hostile payloads).
    func inject(_ envelope: RemoteEnvelope, from: String) {
        receive(RemoteInbound(envelope: envelope, from: from))
    }

    fileprivate func receive(_ msg: RemoteInbound) { inboundCont.yield(msg) }
    fileprivate func rosterChanged(_ ids: Set<String>) { rosterCont.yield(ids) }
    fileprivate func finish() {
        inboundCont.finish()
        rosterCont.finish()
    }
}

// MARK: - Serial send queue

/// The outbound side of a real transport: TWO independent lanes, each delivering strictly in
/// send order (a per-message `Task` let a later state overtake an earlier one):
///   • RELIABLE (state / commands / hellos / Mix events): retried with backoff on failure
///     (logged each time). While a send is being retried the lane waits — so it is BOUNDED
///     (`reliableCap`, oldest superseded/plain message dropped past it) and COALESCED: an
///     undelivered `state` to the same recipient is replaced by the newer one (latest wins —
///     the full state is idempotent), so a stalled messenger never piles up stale windows.
///   • UNRELIABLE (clock pings, heartbeats, Mix beats): best-effort, never retried, and never
///     stuck behind a reliable retry; bounded (`unreliableCap`, oldest dropped), heartbeats
///     coalesced the same way.
/// Per-participant messages are BUFFERED while that participant isn't resolvable yet (a reply
/// to a joiner's hello can beat the roster update that makes the joiner addressable), flushed on
/// `participantsChanged` (capped per participant, oldest dropped; at most `bufferedPeersCap`
/// participants; a DEPARTED participant's buffer is dropped).
/// Generic over the transport's recipient type so it is unit-testable without GroupActivities.
@MainActor
final class RemoteSendQueue<Recipient> {
    typealias Send = (RemoteEnvelope, Recipient, Bool) async throws -> Void

    struct Outbound {
        var envelope: RemoteEnvelope
        var to: RemoteRecipient
        var reliable: Bool
    }

    static var bufferCap: Int { 32 }
    static var bufferedPeersCap: Int { 16 }
    static var reliableCap: Int { 256 }
    static var unreliableCap: Int { 32 }
    /// Kinds whose newest undelivered message to a recipient supersedes an older one.
    static var coalescedKinds: Set<String> {
        [RemoteMessageKind.state.rawValue, RemoteMessageKind.heartbeat.rawValue]
    }

    private let resolve: (RemoteRecipient) -> Recipient?
    private let sendOne: Send
    private let retryDelays: [Double]
    private var reliableLane: [Outbound] = []
    private var unreliableLane: [Outbound] = []
    private var reliableWorker: Task<Void, Never>?
    private var unreliableWorker: Task<Void, Never>?
    private var finished = false
    private(set) var buffered: [String: [Outbound]] = [:]
    /// Buffered participant ids, oldest first (the peers cap drops from the front).
    private var bufferedOrder: [String] = []
    /// Delivered / failed attempts / dropped (coalesced or over a cap) — tests + diagnostics.
    private(set) var deliveredCount = 0
    private(set) var failureCount = 0
    private(set) var droppedCount = 0
    /// Messages waiting in each lane (not yet handed to the messenger).
    var pendingReliable: Int { reliableLane.count }
    var pendingUnreliable: Int { unreliableLane.count }

    /// `retryDelays` (seconds): one entry per retry of a failed reliable send.
    init(resolve: @escaping (RemoteRecipient) -> Recipient?, retryDelays: [Double] = [0.25, 1.0],
         send: @escaping Send) {
        self.resolve = resolve
        self.sendOne = send
        self.retryDelays = retryDelays
    }

    func enqueue(_ envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Bool) {
        guard !finished else { return }
        push(Outbound(envelope: envelope, to: to, reliable: reliable))
        startWorkers()
    }

    /// The roster moved: a departed participant's buffer is dropped; buffered messages for
    /// participants that are now resolvable go out (in their original order, behind anything
    /// already queued).
    func participantsChanged(departed: Set<String> = []) {
        for id in departed where buffered[id] != nil { buffered[id] = nil }
        bufferedOrder.removeAll { departed.contains($0) }
        for id in bufferedOrder where resolve(.participant(id)) != nil {
            let msgs = buffered.removeValue(forKey: id) ?? []
            for m in msgs { push(m) }
        }
        bufferedOrder.removeAll { buffered[$0] == nil }
        startWorkers()
    }

    func finish() {
        finished = true
        reliableWorker?.cancel(); reliableWorker = nil
        unreliableWorker?.cancel(); unreliableWorker = nil
        reliableLane = []
        unreliableLane = []
        buffered = [:]
        bufferedOrder = []
    }

    // MARK: Lanes

    private func push(_ o: Outbound) {
        func into(_ lane: inout [Outbound], cap: Int) {
            if Self.coalescedKinds.contains(o.envelope.kind),
               let i = lane.firstIndex(where: { $0.envelope.kind == o.envelope.kind && $0.to == o.to }) {
                lane.remove(at: i)              // latest wins
                droppedCount += 1
            }
            lane.append(o)
            if lane.count > cap {
                // Over the cap: shed a superseded-kind message first (the next one carries it),
                // else the oldest.
                let i = lane.firstIndex(where: { Self.coalescedKinds.contains($0.envelope.kind) }) ?? 0
                let gone = lane.remove(at: i)
                droppedCount += 1
                DiagLog.shared.log("remote", "send queue full (\(cap)) — dropped \(gone.envelope.kind)")
            }
        }
        if o.reliable { into(&reliableLane, cap: Self.reliableCap) } else { into(&unreliableLane, cap: Self.unreliableCap) }
    }

    private func startWorkers() {
        guard !finished else { return }
        if reliableWorker == nil, !reliableLane.isEmpty {
            reliableWorker = Task { [weak self] in await self?.drain(reliable: true) }
        }
        if unreliableWorker == nil, !unreliableLane.isEmpty {
            unreliableWorker = Task { [weak self] in await self?.drain(reliable: false) }
        }
    }

    /// One lane's consumer: delivers until the lane is empty, then exits (the next enqueue
    /// starts a new one). Main-actor isolated, so the empty check and the exit are atomic with
    /// respect to `enqueue`.
    private func drain(reliable: Bool) async {
        while !Task.isCancelled, !finished {
            let next: Outbound
            if reliable {
                guard !reliableLane.isEmpty else { break }
                next = reliableLane.removeFirst()
            } else {
                guard !unreliableLane.isEmpty else { break }
                next = unreliableLane.removeFirst()
            }
            await deliver(next)
        }
        if reliable { reliableWorker = nil } else { unreliableWorker = nil }
    }

    private func deliver(_ o: Outbound) async {
        guard let recipient = resolve(o.to) else {
            if case .participant(let id) = o.to, o.reliable { bufferForLater(o, id: id) }
            return
        }
        var attempt = 0
        while true {
            do {
                try await sendOne(o.envelope, recipient, o.reliable)
                deliveredCount += 1
                return
            } catch {
                failureCount += 1
                DiagLog.shared.log("remote", "send \(o.envelope.kind) failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                guard o.reliable, attempt < retryDelays.count, !Task.isCancelled, !finished else { return }
                let delay = retryDelays[attempt]
                attempt += 1
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }

    private func bufferForLater(_ o: Outbound, id: String) {
        guard !finished else { return }
        if buffered[id] == nil {
            bufferedOrder.append(id)
            while bufferedOrder.count > Self.bufferedPeersCap {
                let oldest = bufferedOrder.removeFirst()
                droppedCount += buffered.removeValue(forKey: oldest)?.count ?? 0
            }
        }
        var list = buffered[id, default: []]
        list.append(o)
        if list.count > Self.bufferCap {
            droppedCount += list.count - Self.bufferCap
            list.removeFirst(list.count - Self.bufferCap)
        }
        buffered[id] = list
    }
}
