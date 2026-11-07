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

/// The outbound side of a real transport: ONE consumer delivering messages strictly in send
/// order (a per-message `Task` let a later state overtake an earlier one), with
///   • per-participant messages BUFFERED while that participant isn't resolvable yet (a reply to
///     a joiner's hello can beat the roster update that makes the joiner addressable), flushed
///     on `participantsChanged()` (capped per participant, oldest dropped);
///   • reliable sends RETRIED with backoff on failure (logged each time), unreliable ones dropped.
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

    private let resolve: (RemoteRecipient) -> Recipient?
    private let sendOne: Send
    private let retryDelays: [Double]
    private let stream: AsyncStream<Outbound>
    private let cont: AsyncStream<Outbound>.Continuation
    private var consumer: Task<Void, Never>?
    private(set) var buffered: [String: [Outbound]] = [:]
    /// Delivered (tests) — kinds in delivery order.
    private(set) var deliveredCount = 0
    private(set) var failureCount = 0

    /// `retryDelays` (seconds): one entry per retry of a failed reliable send.
    init(resolve: @escaping (RemoteRecipient) -> Recipient?, retryDelays: [Double] = [0.25, 1.0],
         send: @escaping Send) {
        self.resolve = resolve
        self.sendOne = send
        self.retryDelays = retryDelays
        (stream, cont) = AsyncStream.makeStream(of: Outbound.self)
        let stream = self.stream
        consumer = Task { [weak self] in
            for await o in stream {
                guard let self else { return }
                await self.deliver(o)
            }
        }
    }

    func enqueue(_ envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Bool) {
        cont.yield(Outbound(envelope: envelope, to: to, reliable: reliable))
    }

    /// The roster moved: buffered messages for participants that are now resolvable go out
    /// (in their original order, behind anything already queued).
    func participantsChanged() {
        for (id, msgs) in buffered where resolve(.participant(id)) != nil {
            buffered[id] = nil
            for m in msgs { cont.yield(m) }
        }
    }

    func finish() {
        cont.finish()
        consumer?.cancel()
        consumer = nil
        buffered = [:]
    }

    private func deliver(_ o: Outbound) async {
        guard let recipient = resolve(o.to) else {
            if case .participant(let id) = o.to, o.reliable {
                var list = buffered[id, default: []]
                list.append(o)
                if list.count > Self.bufferCap { list.removeFirst(list.count - Self.bufferCap) }
                buffered[id] = list
            }
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
                guard o.reliable, attempt < retryDelays.count, !Task.isCancelled else { return }
                let delay = retryDelays[attempt]
                attempt += 1
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }
}
