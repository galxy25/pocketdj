import Foundation
import Network

/// STEM LOCK — "keep my stems across tracks" for a Now Playing playback SESSION.
///
/// Off (the default): stems reset on every track change, exactly as before (`NowPlayingDSP`'s
/// controls are ephemeral). On: the stem state of the track that is playing — stems on/off, which
/// of vocals/drums/bass/other are muted, the per-part gains — CARRIES to every following track.
/// The carry is captured from USER stem actions only (`NowPlayingDSP.onUserStemChange`), so a
/// track that can't do stems (no stems / not a local file / a stem stream that failed) never
/// overwrites it: that track plays the full mix under a small "unavailable" indicator, and the
/// lock stays for the tracks after it.
///
/// A locked track ALWAYS starts on the full mix (zero dead air) and hands over to the carried
/// set through the ordinary `NowPlayingDSP` handover once the ENABLED parts are buffered — a
/// partial burned set may go on air without the muted parts (`NowPlayingDSP.stemPartsRequired`),
/// which join silently when they land (`NowPlayingDSP.stemPartsLanded`).
///
/// SESSION scope: the lock lives on `SetlistPlayer`'s durable session — persisted in the session
/// snapshot (`PlaybackSessionStore.Snapshot.stemLock`), restored with it, CLEARED by a new session
/// (a fresh `SetlistPlayer.play`, which mints a new `sessionId`) and by `stop()` / end of set.
/// Live-queue edits, play-now, skips, repeats and restore keep it.
///
/// The download side — `StemLockPrefetcher` below — pairs the next track's whole-song audio with
/// its stems: whole song FIRST (it is what plays at the boundary), then its enabled stems in
/// `partPriority` order, then the further-ahead tracks, and the muted parts LAST.
enum StemLock {
    /// Download priority of the stem parts (Levi: vocals, drums, other, bass). Muted parts go to
    /// the very end of the queue (skipped entirely in Low Data Mode).
    static let partPriority = ["vocals", "drums", "other", "bass"]

    /// One `stemlock` line: the remote DiagLog stream (song ids only, never titles) + the Now
    /// Playing trace (os_log `nowplaying`, Settings ▸ Debug capture).
    @MainActor
    static func log(_ message: String) {
        DiagLog.shared.log("stemlock", message)
        NPLog.trace("stemlock \(message)")
    }

    /// What the Now Playing surfaces show for the lock on the CURRENT track.
    enum Indicator: Equatable {
        /// The lock is off.
        case off
        /// Locked, carrying "stems off" (or nothing playing yet): plain full mix.
        case idle
        /// Locked with stems: the full mix plays while the carried stems buffer.
        case loading
        /// Locked with stems, and the carried stems are on air.
        case active
        /// Locked with stems, but THIS track can't do stems — full mix; the lock carries on.
        case unavailable
    }
}

/// The persisted Stem Lock state of a session (the carried stem set rides with it).
struct StemLockState: Codable, Equatable {
    var enabled = false
    /// Stems on for the carried set.
    var stemsOn = false
    /// Muted parts (sorted — stable on disk).
    var muted: [String] = []
    /// Per-part gains moved off 1.0.
    var volumes: [String: Double] = [:]

    /// The un-muted parts, in download priority — what a handover waits for.
    var enabledParts: [String] { StemLock.partPriority.filter { !muted.contains($0) } }
    /// The muted parts, in download priority — fetched last.
    var disabledParts: [String] { StemLock.partPriority.filter { muted.contains($0) } }
    /// Lock on AND carrying stems: the only state that changes playback or downloads.
    var wantsStems: Bool { enabled && stemsOn }
    /// One-line summary for DiagLog (`stems=on parts=vocals,drums muted=bass,other`).
    var logSummary: String {
        guard stemsOn else { return "stems=off" }
        var s = "stems=on parts=\(enabledParts.joined(separator: ","))"
        if !muted.isEmpty { s += " muted=\(muted.joined(separator: ","))" }
        if !volumes.isEmpty {
            s += " gains=" + volumes.keys.sorted().map { "\($0):\(String(format: "%.2f", volumes[$0] ?? 1))" }.joined(separator: ",")
        }
        return s
    }
}

/// The Stem Lock download lane: ONE fetch at a time, in plan order, so the next track's
/// whole-song audio never competes with its own stems (or with a further-ahead track).
///
/// `plan(...)` is pure (the ordering contract, unit-tested); `apply(_:)` runs a plan, keeping an
/// in-flight fetch that the new plan still wants and cancelling one it no longer does (a skip, a
/// queue edit, the lock turned off). A failed step is not retried for `failureCooldown`. Cloud
/// stem separation for a next track with no stems is requested once per song id
/// (`requestStemify`, fire-and-forget — playback never waits on it). Every step holds a
/// `PlaybackRunway` (a locked phone keeps fetching across the gap between songs).
@MainActor
final class StemLockPrefetcher {
    enum Step: Hashable, CustomStringConvertible {
        /// The whole song (`id` = the id playback resolves under).
        case song(id: String, title: String, artist: String)
        /// One stem part of `songId`.
        case stem(songId: String, part: String)

        var description: String {
            switch self {
            case let .song(id, _, _): return "song:\(id)"
            case let .stem(id, part): return "\(part):\(id)"
            }
        }
    }

    /// The network the plan sizes itself to.
    enum Network: String {
        /// Wi-Fi / wired: the whole prefetch window.
        case unmetered
        /// Cellular (an expensive path): the NEXT track only (its song + all its stems).
        case expensive
        /// Low Data Mode: the next track's song + ENABLED stems only — muted parts are skipped.
        case constrained
        /// No path: nothing.
        case offline
    }

    /// One queue row as the planner sees it.
    struct Track: Equatable {
        /// The row's song id — stems are keyed on it (what `NowPlayingDSP` loads).
        var songId: String
        /// The id the whole-song audio resolves under (an edition-substituted row's variant id).
        var audioId: String
        var title: String
        var artist: String
        /// The whole song already plays from this device (burned / a finished stream).
        var songLocal: Bool
        /// The whole song can be fetched now (ripped, a rip server, a network path).
        var songFetchable: Bool
        /// Stem parts already on disk.
        var stemsLocal: Set<String>
        /// The catalog has stems for it (separated server-side).
        var stemsRemote: Bool
    }

    struct Plan: Equatable {
        var steps: [Step] = []
        /// Songs to ask the cloud to separate (fire-and-forget).
        var stemify: [String] = []
    }

    /// THE ORDER. `current`: the playing track when its carried stems are wired PARTIALLY (its
    /// missing enabled parts lead — they are audible the moment they land). Then, per upcoming
    /// track within the window: its whole song (if not already local), then its enabled stems in
    /// `StemLock.partPriority` order; the next track gets a cloud stem request when it has none.
    /// Muted parts — the current track's included — come LAST, after every track (skipped on a
    /// constrained network). A track whose audio can't be made local is skipped: its stems could
    /// never play (Now Playing stems need the full song on the device).
    static func plan(current: Track?, upcoming: [Track], carry: StemLockState, network: Network,
                     window: Int) -> Plan {
        var plan = Plan()
        guard carry.wantsStems, network != .offline else { return plan }
        let reach = network == .unmetered ? max(0, window) : min(1, max(0, window))
        var deferred: [Step] = []
        func stems(_ t: Track) {
            for p in carry.enabledParts where !t.stemsLocal.contains(p) { plan.steps.append(.stem(songId: t.songId, part: p)) }
            guard network != .constrained else { return }
            for p in carry.disabledParts where !t.stemsLocal.contains(p) { deferred.append(.stem(songId: t.songId, part: p)) }
        }
        if let c = current, c.stemsRemote { stems(c) }
        for (i, t) in upcoming.prefix(reach).enumerated() {
            let hasStems = t.stemsRemote || t.stemsLocal.count == StemLock.partPriority.count
            if i == 0, !hasStems { plan.stemify.append(t.songId) }
            guard t.songLocal || t.songFetchable else { continue }
            if !t.songLocal { plan.steps.append(.song(id: t.audioId, title: t.title, artist: t.artist)) }
            if t.stemsRemote { stems(t) }
        }
        plan.steps += deferred
        return plan
    }

    // MARK: Seams (production wiring: `StemLockPrefetcher.live`)

    /// Fetch the whole song of a `.song` step to the device; true once it plays from there.
    var fetchSong: (Step) async -> Bool = { _ in false }
    /// Burn one stem part (`BurnStore.burnStemPart`).
    var fetchStemPart: (String, String) async -> Bool = { _, _ in false }
    /// Ask the cloud to separate a song (fire-and-forget; deduped here per song id).
    var requestStemify: (String) -> Void = { _ in }
    /// The current network class (production: `StemLockNetworkMonitor`).
    var network: () -> Network = { .unmetered }
    /// A step finished (`ok` = its audio is on disk).
    var onStepFinished: ((Step, Bool) -> Void)?

    static var failureCooldown: TimeInterval = 120

    // MARK: State

    private(set) var pending: [Step] = []
    private(set) var inFlight: Step?
    /// Every step STARTED, in order (test seam + diagnostics).
    private(set) var startedLog: [Step] = []
    private var worker: Task<Void, Never>?
    private var failedAt: [Step: Date] = [:]
    private var stemifyRequested: Set<String> = []
    private var lastLoggedOrder: [Step] = []

    var isIdle: Bool { worker == nil && pending.isEmpty }

    /// Run `plan`: keep the in-flight fetch if the plan still wants it, otherwise cancel it.
    func apply(_ plan: Plan) {
        for id in plan.stemify where !stemifyRequested.contains(id) {
            stemifyRequested.insert(id)
            StemLock.log("stemify request song=\(id) (next track has no stems)")
            requestStemify(id)
        }
        let now = Date()
        let steps = plan.steps.filter { s in
            failedAt[s].map { now.timeIntervalSince($0) >= Self.failureCooldown } ?? true
        }
        if let cur = inFlight, steps.contains(cur) {
            pending = steps.filter { $0 != cur }
        } else {
            if inFlight != nil { StemLock.log("prefetch cancel \(inFlight!.description) (no longer planned)") }
            worker?.cancel(); worker = nil; inFlight = nil
            pending = steps
        }
        let order = (inFlight.map { [$0] } ?? []) + pending
        if order != lastLoggedOrder {
            lastLoggedOrder = order
            if !order.isEmpty {
                StemLock.log("prefetch order net=\(network().rawValue) \(order.map(\.description).joined(separator: " → "))")
            }
        }
        if worker == nil, !pending.isEmpty { startWorker() }
    }

    func cancelAll() {
        if inFlight != nil || !pending.isEmpty { StemLock.log("prefetch cancel all") }
        worker?.cancel(); worker = nil
        inFlight = nil
        pending = []
        lastLoggedOrder = []
    }

    private func startWorker() {
        worker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.pending.isEmpty else { break }
                let step = self.pending.removeFirst()
                self.inFlight = step
                self.startedLog.append(step)
                let runway = PlaybackRunway("pocketdj-stemlock-\(step.description)")
                let t0 = Date()
                let ok: Bool
                switch step {
                case .song: ok = await self.fetchSong(step)
                case let .stem(id, part): ok = await self.fetchStemPart(id, part)
                }
                runway.end()
                // Superseded — the canceller owns the lane's state. A fetch that LANDED anyway
                // (its bytes are on disk) is still reported: a re-plan that ran between the
                // write and this line must not swallow the playing track's late part.
                guard !Task.isCancelled else {
                    if ok { self.onStepFinished?(step, true) }
                    return
                }
                self.inFlight = nil
                if !ok { self.failedAt[step] = Date() }
                StemLock.log("prefetch \(step.description) \(ok ? "ok" : "FAILED") ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
                self.onStepFinished?(step, ok)
            }
            if !Task.isCancelled { self?.worker = nil }
        }
    }
}

extension StemLockPrefetcher {
    /// Production wiring: whole songs through the shared `MixStreamLoader` (a finished stream is
    /// adopted as an ordinary burn, so the track plays from the device at the boundary — the
    /// prefetch IS a download), stem parts through `BurnStore.burnStemPart`, cloud separation
    /// through `RipsStore.stemify` (owner installs only — a hybrid user's lock never enqueues
    /// server work), and the network class from an `NWPathMonitor`.
    static func live(streamer: MixStreamLoader, burns: BurnStore, rips: RipsStore,
                     isCatalogOwner: @escaping () -> Bool) -> StemLockPrefetcher {
        let p = StemLockPrefetcher()
        let monitor = StemLockNetworkMonitor()
        p.network = { monitor.current }
        p.fetchSong = { [weak streamer] step in
            guard case let .song(id, title, artist) = step, let streamer,
                  let s = streamer.open(id, title: title, artist: artist) else { return false }
            while !Task.isCancelled {
                if s.isComplete { return true }
                if s.failed || streamer.stream(for: id) !== s { return false }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }
        p.fetchStemPart = { [weak burns] id, part in await burns?.burnStemPart(forSong: id, part: part) ?? false }
        p.requestStemify = { [weak rips] id in
            guard isCatalogOwner(), let rips else { return }
            Task { await rips.stemify(id) }
        }
        return p
    }
}

/// The current path's class for the Stem Lock plan (`NWPathMonitor`, optimistic until the first
/// update).
final class StemLockNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value: StemLockPrefetcher.Network = .unmetered

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let v: StemLockPrefetcher.Network
            if path.status != .satisfied { v = .offline }
            else if path.isConstrained { v = .constrained }
            else if path.isExpensive { v = .expensive }
            else { v = .unmetered }
            self?.lock.lock(); self?.value = v; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "pdj.stemlock.path"))
    }

    deinit { monitor.cancel() }

    var current: StemLockPrefetcher.Network {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
