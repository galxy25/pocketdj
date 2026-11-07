import Foundation

/// The session's shared timeline: the HOST's clock. Every participant estimates its offset to
/// the host NTP-style over the transport (ping → pong) and keeps the best — LOWEST round-trip —
/// of the last `sampleCap` samples, because the symmetric-delay assumption behind the offset
/// math is least wrong on the fastest exchange (an asymmetric path's error is bounded by
/// rtt / 2, so the quickest sample has the tightest bound).
///
/// For one exchange (participant clock P, host clock H):
///     t0 = P at ping send      t1 = H at ping receipt
///     t2 = H at pong send      t3 = P at pong receipt
///     offset = ((t1 − t0) + (t2 − t3)) / 2      (H ≈ P + offset)
///     rtt    = (t3 − t0) − (t2 − t1)
///
/// The host itself has offset 0 by definition. A host hand-over `reset`s the samples — the
/// shared timeline just CHANGED to the new host's clock, and until a fresh sample lands this
/// device reports `isSynced == false` (receivers then skip drift corrections, never guess).
@MainActor
final class SharedClock {
    struct Sample: Equatable {
        var offsetMs: Double
        var rttMs: Double
    }

    static let sampleCap = 8

    /// Local wall clock in ms (injectable: tests skew it per device).
    let localNow: () -> Double
    private(set) var samples: [Sample] = []
    private(set) var isHost = false
    /// The host this clock's samples were measured against.
    private(set) var hostId: String?

    init(localNow: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.localNow = localNow
    }

    /// The offset math for one exchange (pure).
    nonisolated static func sample(t0: Double, t1: Double, t2: Double, t3: Double) -> Sample {
        Sample(offsetMs: ((t1 - t0) + (t2 - t3)) / 2, rttMs: max(0, (t3 - t0) - (t2 - t1)))
    }

    /// Re-base onto a (new) host. The host's own clock IS the shared clock.
    func reset(hostId: String?, isHost: Bool) {
        self.hostId = hostId
        self.isHost = isHost
        samples.removeAll()
    }

    /// The best (lowest-RTT) of the retained samples.
    var best: Sample? { samples.min { $0.rttMs < $1.rttMs } }

    var isSynced: Bool { isHost || !samples.isEmpty }

    /// Local → shared offset (ms), nil before the first sample.
    var offsetMs: Double? { isHost ? 0 : best?.offsetMs }

    /// Shared (host) time now, nil until synced.
    var sharedNow: Double? { offsetMs.map { localNow() + $0 } }

    /// A shared-clock instant → this device's local clock.
    func localTime(forShared shared: Double) -> Double? { offsetMs.map { shared - $0 } }

    /// A shared-clock instant → a local `Date`.
    func localDate(forShared shared: Double) -> Date? {
        localTime(forShared: shared).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    // MARK: Exchange

    func makePing() -> RemotePing { RemotePing(id: UUID().uuidString, t0: localNow()) }

    /// Host side: answer a ping (t1 = receipt, t2 = send — both "now" in-process).
    func pong(for ping: RemotePing) -> RemotePong {
        let t = localNow()
        return RemotePong(id: ping.id, t0: ping.t0, t1: t, t2: localNow())
    }

    /// Participant side: fold a pong in (only against the host we're measuring).
    func ingest(_ pong: RemotePong, from sender: String) {
        guard !isHost, sender == hostId else { return }
        ingest(Self.sample(t0: pong.t0, t1: pong.t1, t2: pong.t2, t3: localNow()))
    }

    func ingest(_ s: Sample) {
        samples.append(s)
        if samples.count > Self.sampleCap { samples.removeFirst(samples.count - Self.sampleCap) }
    }
}
