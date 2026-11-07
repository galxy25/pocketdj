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
