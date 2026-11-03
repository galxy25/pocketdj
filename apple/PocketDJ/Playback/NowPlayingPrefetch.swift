import Foundation
import Network

/// One release of source compatibility: the lane was born as the Stem Lock's prefetcher.
typealias StemLockPrefetcher = NowPlayingPrefetcher

/// Everything the Now Playing prefetch plan is a pure function of (np-mix-mode §2.1).
struct NowPlayingPrefetchInput: Equatable {
    /// The PLAYING row (nil when held / not running / a studio or profile row).
    var current: NowPlayingPrefetcher.Track?
    /// `queue[index+1 …]` — at least `max(window, stemLockWindow)` rows when that many exist.
    var upcoming: [NowPlayingPrefetcher.Track]
    var stemLock: StemLockState
    /// Pass DISABLED while Mix Mode is suspended (a Mix-tab session is live).
    var mixMode: NPMixModeState
    var network: NowPlayingPrefetcher.Network
    /// Mix Mode's Wi-Fi window (`npMixBufferAhead`, default 3).
    var window: Int = NPMixMode.defaultBufferAhead
    /// The Stem Lock's own window (unchanged: `SetlistPlayer.prefetchAhead`).
    var stemLockWindow: Int = 3
    var cellular: NPMixCellularPolicy = .nextSong
    /// The current track's carried stems are wired PARTIALLY (the Stem Lock's "current" rule —
    /// its missing enabled parts lead).
    var currentStemsPartial: Bool = false
    /// The listener has the Stems toggle ON for the playing track (cellular policy: its stems
    /// are fetched only when asked for).
    var currentStemsWanted: Bool = false
    /// Owner install (phase 4): only the catalog owner's lane asks the rip server to capture an
    /// Apple-Music-only row (`Plan.rips`) or to separate stems (`Plan.stemify` for Mix Mode). A
    /// hybrid / public install never enqueues server work (integrity audit; App Store 5.2.3).
    var isCatalogOwner: Bool = false
    /// FX LOCK carrying an effect that is on (`FXLockState.wantsFX`): the next tracks' WHOLE SONGS
    /// are made local within the lock window, so each boundary plays a file the DSP can take
    /// over at its start (effects need the DSP). Songs only — no stems for the FX Lock.
    var fxLockSongs: Bool = false
}

/// The Now Playing download lane (np-mix-mode §2): ONE fetch at a time, in plan order, so the
/// next track's whole-song audio never competes with its own stems (or with a further-ahead
/// track). It serves the STEM LOCK (next tracks' songs + carried stems) and, generalised in
/// phase 2, MIX MODE (the current + upcoming rows made local — audio, then stems).
///
/// `plan(...)` is pure (the ordering contract, unit-tested); `apply(_:)` runs a plan, keeping an
/// in-flight fetch that the new plan still wants and cancelling one it no longer does (a skip, a
/// queue edit, the lock / Mix Mode turned off). A failed step is not retried for
/// `failureCooldown`; a step the DISK GUARD refused (free space / the buffer cap) is not retried
/// for `blockedCooldown`. Cloud stem separation for a next track with no stems is requested once
/// per song id (`requestStemify`, fire-and-forget — playback never waits on it). Every step
/// holds a `PlaybackRunway` (a locked phone keeps fetching across the gap between songs).
@MainActor
final class NowPlayingPrefetcher {
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

        /// The song id the step downloads for (audio id for a song, row id for a stem).
        var songId: String {
            switch self {
            case let .song(id, _, _): return id
            case let .stem(id, _): return id
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
        /// What kind of row this is (np-mix-mode §2.1) — the buffer strip and the indicator read
        /// it; the plan only needs `songLocal` / `songFetchable`.
        enum Source: String, Equatable {
            case local, ripped, appleMusicOnly, catalogOnly, live, studioOrProfile, unavailable
        }
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
        var source: Source = .ripped
    }

    struct Plan: Equatable {
        var steps: [Step] = []
        /// Songs to ask the cloud to separate (fire-and-forget).
        var stemify: [String] = []
        /// Phase 4 (np-mix-mode §2.2 step 0): Apple-Music-only rows to ask the rip server to
        /// capture — OWNER ONLY, the first `NowPlayingPrefetcher.ripAhead` such rows past the
        /// playing one, in play order. Fire-and-forget like `stemify` (a server capture is real
        /// time; the lane never waits on it), deduped per song id, and routed through the
        /// playback rip gate + same-host deferral by the production seam. (The design's `.rip`
        /// STEP became a plan list: a step would hold the one-at-a-time worker for a POST.)
        var rips: [String] = []
    }

    /// How many Apple-Music-only rows ahead Mix Mode asks the rip server for (Levi's Q7: 2 —
    /// a capture is real time with concurrency 1, so more would only queue captures nobody hears).
    static var ripAhead = 2

    /// THE STEM LOCK ORDER (unchanged since the Stem Lock shipped; Mix Mode off == exactly this).
    /// `current`: the playing track when its carried stems are wired PARTIALLY (its missing
    /// enabled parts lead — they are audible the moment they land). Then, per upcoming track
    /// within the window: its whole song (if not already local), then its enabled stems in
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

    /// The FX Lock's whole-song steps: each upcoming row in reach whose audio isn't local but can
    /// be fetched (Wi-Fi: the window; cellular / Low Data: the next track; offline: none).
    static func fxLockSongSteps(upcoming: [Track], network: Network, window: Int) -> [Step] {
        guard network != .offline else { return [] }
        let reach = network == .unmetered ? max(0, window) : min(1, max(0, window))
        return upcoming.prefix(reach).filter { !$0.songLocal && $0.songFetchable }
            .map { .song(id: $0.audioId, title: $0.title, artist: $0.artist) }
    }

    /// How far Mix Mode reaches on `network` (rows past the current one) and which stems it
    /// fetches there (np-mix-mode §2.3). nil ⇒ Mix Mode adds nothing on this network.
    enum StemPolicy: Equatable {
        /// Every part of every row in the window.
        case all
        /// Cellular: the current row's stems only when asked for (the Stems toggle on / the Stem
        /// Lock carrying stems); the next row only the Stem Lock's enabled parts.
        case onRequest
        /// Low Data: none (the toggle streams them on demand, as today).
        case none
    }
    static func mixReach(network: Network, cellular: NPMixCellularPolicy, window: Int)
        -> (ahead: Int, stems: StemPolicy)? {
        switch network {
        case .offline: return nil
        case .unmetered: return (max(0, window), .all)
        case .constrained: return (0, .none)
        case .expensive:
            switch cellular {
            case .off: return nil
            case .nextSong: return (min(1, max(0, window)), .onRequest)
            case .full: return (max(0, window), .all)
            }
        }
    }

    /// THE PLAN (np-mix-mode §2.2). Mix Mode OFF (or suspended — the caller passes it disabled):
    /// exactly the Stem Lock plan above, byte for byte. Mix Mode ON:
    ///  1. the CURRENT row's whole song when it is a ripped stream that isn't local yet (lets the
    ///     playing track hand off mid-song),
    ///  2. the current row's missing stem parts (the Stem Lock's enabled parts first, its muted
    ///     parts deferred; else all four in `partPriority`),
    ///  3–5. then row by row through the window: song, then stems,
    ///  6. muted parts last;
    /// sized by `mixReach` to the network. Then every Stem Lock step this order doesn't already
    /// hold is appended (so Mix Mode never fetches LESS than the lock alone would — on Low Data
    /// the lock still gets its next song + enabled stems), and the lock's stemify request rides.
    /// A row whose audio can't be made local is skipped whole (its stems could never play).
    static func plan(_ i: NowPlayingPrefetchInput) -> Plan {
        var lock = plan(current: i.currentStemsPartial ? i.current : nil,
                        upcoming: Array(i.upcoming.prefix(max(0, i.stemLockWindow))),
                        carry: i.stemLock, network: i.network, window: i.stemLockWindow)
        if i.fxLockSongs {
            // FX Lock: the window's songs (the Stem Lock reach — Wi-Fi the window, cellular / Low
            // Data the next track), after anything the Stem Lock already planned.
            for s in fxLockSongSteps(upcoming: Array(i.upcoming.prefix(max(0, i.stemLockWindow))),
                                     network: i.network, window: i.stemLockWindow)
            where !lock.steps.contains(s) { lock.steps.append(s) }
        }
        guard i.mixMode.enabled, let reach = mixReach(network: i.network, cellular: i.cellular, window: i.window)
        else { return lock }
        var steps: [Step] = []
        var seen = Set<Step>()
        var deferred: [Step] = []
        func add(_ s: Step) { if seen.insert(s).inserted { steps.append(s) } }
        func defer_(_ s: Step) { if !seen.contains(s), !deferred.contains(s) { deferred.append(s) } }
        let locked = i.stemLock.wantsStems
        func stems(_ t: Track, isCurrent: Bool, isNext: Bool) {
            guard t.stemsRemote else { return }
            var now: [String] = []
            var later: [String] = []
            switch reach.stems {
            case .all:
                if locked { now = i.stemLock.enabledParts; later = i.stemLock.disabledParts }
                else { now = StemLock.partPriority }
            case .onRequest:
                if isCurrent, locked || i.currentStemsWanted {
                    now = locked ? i.stemLock.enabledParts : StemLock.partPriority
                    if locked { later = i.stemLock.disabledParts }
                } else if isNext, locked {
                    now = i.stemLock.enabledParts
                    later = i.stemLock.disabledParts
                }
            case .none:
                break
            }
            for p in now where !t.stemsLocal.contains(p) { add(.stem(songId: t.songId, part: p)) }
            for p in later where !t.stemsLocal.contains(p) { defer_(.stem(songId: t.songId, part: p)) }
        }
        if let c = i.current, c.songLocal || c.songFetchable {
            if !c.songLocal { add(.song(id: c.audioId, title: c.title, artist: c.artist)) }
            stems(c, isCurrent: true, isNext: false)
        }
        for (k, t) in i.upcoming.prefix(reach.ahead).enumerated() {
            guard t.songLocal || t.songFetchable else { continue }
            if !t.songLocal { add(.song(id: t.audioId, title: t.title, artist: t.artist)) }
            stems(t, isCurrent: false, isNext: k == 0)
        }
        for s in deferred { add(s) }
        for s in lock.steps { add(s) }
        var stemify = lock.stemify
        var rips: [String] = []
        if i.isCatalogOwner {
            // Step 0: the next AM-only rows, owner only. At least `ripAhead` rows deep even on a
            // narrow (cellular) window — a server capture costs this device no data.
            let ripRows = i.upcoming.prefix(max(reach.ahead, Self.ripAhead))
            rips = Array(ripRows.filter { $0.source == .appleMusicOnly && !$0.songLocal }.map(\.audioId).prefix(Self.ripAhead))
            // Cloud separation for rows in the window whose audio is (or can be made) local but
            // that have no stems anywhere — fire-and-forget, deduped per song id by `apply`.
            var rows: [Track] = []
            if let c = i.current { rows.append(c) }
            rows += i.upcoming.prefix(reach.ahead)
            for t in rows where (t.songLocal || t.songFetchable) && t.source != .appleMusicOnly && t.source != .catalogOnly
                && !t.stemsRemote && t.stemsLocal.count < StemLock.partPriority.count && !stemify.contains(t.songId) {
                stemify.append(t.songId)
            }
        }
        return Plan(steps: steps, stemify: stemify, rips: rips)
    }

    // MARK: Disk guard (np-mix-mode §2.3)

    /// The free-space floor the lane keeps (1 GB — decimal, like the caps).
    nonisolated static let freeSpaceFloorBytes = 1_000_000_000
    /// A step's size estimate for the guard (a ~4–5 min 256 kbps mp3, or one stem part).
    nonisolated static let estimatedStepBytes = 10_000_000

    enum DiskVerdict: Equatable {
        case ok
        /// Free this many bytes of temporary assets first (soonest expiry first, never protected).
        case evict(Int)
    }

    /// PURE: may a step of `stepBytes` start with `freeBytes` free on the volume and the
    /// temporary footprint at `footprint` against `capBytes`? `.evict(n)`: the larger of the cap
    /// overshoot and the free-space shortfall. A nil `freeBytes` (the volume couldn't be read)
    /// only checks the cap.
    nonisolated static func diskVerdict(freeBytes: Int?, footprint: Int, capBytes: Int,
                                        stepBytes: Int = estimatedStepBytes) -> DiskVerdict {
        var need = 0
        if footprint + stepBytes > capBytes { need = footprint + stepBytes - capBytes }
        if let free = freeBytes, free - stepBytes < freeSpaceFloorBytes {
            need = max(need, freeSpaceFloorBytes + stepBytes - free)
        }
        return need > 0 ? .evict(need) : .ok
    }

    // MARK: Seams (production wiring: `NowPlayingPrefetcher.live`)

    /// Fetch the whole song of a `.song` step to the device; true once it plays from there.
    var fetchSong: (Step) async -> Bool = { _ in false }
    /// Burn one stem part (`BurnStore.burnStemPart`).
    var fetchStemPart: (String, String) async -> Bool = { _, _ in false }
    /// Ask the cloud to separate a song (fire-and-forget; deduped here per song id).
    var requestStemify: (String) -> Void = { _ in }
    /// Phase 4: ask the rip server to capture an Apple-Music-only row (fire-and-forget; deduped
    /// here per song id for `ripRetrySeconds`). Production: OWNER-gated again, through the
    /// playback rip gate (the rip-ahead window) and the same-host deferral.
    var requestRip: (String) -> Void = { _ in }
    /// The current network class (production: `StemLockNetworkMonitor`).
    var network: () -> Network = { .unmetered }
    /// The network class CHANGED (production: the monitor's update, on the main actor) — the
    /// sequencer re-plans (a Wi-Fi → cellular drive shrinks the window at once).
    var onNetworkChange: (() -> Void)?
    /// DISK GUARD: may this step start? Evicts temporary assets first when it has to; false ⇒
    /// the step is skipped (`blockedCooldown`). nil ⇒ always (tests that don't exercise it).
    var diskGuard: ((Step) async -> Bool)?
    /// A step finished (`ok` = its audio is on disk).
    var onStepFinished: ((Step, Bool) -> Void)?

    static var failureCooldown: TimeInterval = 120
    static var blockedCooldown: TimeInterval = 120

    // MARK: State

    private(set) var pending: [Step] = []
    private(set) var inFlight: Step?
    /// Every step STARTED, in order (test seam + diagnostics).
    private(set) var startedLog: [Step] = []
    private var worker: Task<Void, Never>?
    private var failedAt: [Step: Date] = [:]
    private var blockedAt: [Step: Date] = [:]
    private var stemifyRequested: Set<String> = []
    private var ripRequestedAt: [String: Date] = [:]
    /// A rip asked for this long ago that is STILL Apple-Music-only may be asked for again (the
    /// server's miss / a cancelled out-of-window capture); the RipsStore guards dedup in-flight jobs.
    static var ripRetrySeconds: TimeInterval = 600
    /// Every rip the lane asked for, in order (test seam + diagnostics).
    private(set) var ripLog: [String] = []
    private var lastLoggedOrder: [Step] = []

    var isIdle: Bool { worker == nil && pending.isEmpty }

    /// Song ids the lane is fetching or about to fetch (in-flight + pending; audio and stem ids)
    /// — the temporary-asset sweep never deletes these (np-mix-mode §3.5).
    var activeSongIds: Set<String> {
        Set(((inFlight.map { [$0] } ?? []) + pending).map(\.songId))
    }

    /// The whole-song step for `audioId` failed within the cooldown (the indicator's
    /// "Download failed").
    func songFailedRecently(_ audioId: String, now: Date = Date()) -> Bool {
        failedAt.contains { step, at in
            if case let .song(id, _, _) = step, id == audioId { return now.timeIntervalSince(at) < Self.failureCooldown }
            return false
        }
    }

    /// The whole-song step for `audioId` was refused by the disk guard within the cooldown
    /// ("Storage full").
    func songBlockedRecently(_ audioId: String, now: Date = Date()) -> Bool {
        blockedAt.contains { step, at in
            if case let .song(id, _, _) = step, id == audioId { return now.timeIntervalSince(at) < Self.blockedCooldown }
            return false
        }
    }

    /// `audioId`'s whole song is the step in flight.
    func isFetchingSong(_ audioId: String) -> Bool {
        if case let .song(id, _, _) = inFlight { return id == audioId }
        return false
    }

    /// `audioId`'s whole song is planned (in flight or pending).
    func isPlannedSong(_ audioId: String) -> Bool {
        ((inFlight.map { [$0] } ?? []) + pending).contains {
            if case let .song(id, _, _) = $0 { return id == audioId }
            return false
        }
    }

    /// Run `plan`: keep the in-flight fetch if the plan still wants it, otherwise cancel it.
    func apply(_ plan: Plan) {
        for id in plan.stemify where !stemifyRequested.contains(id) {
            stemifyRequested.insert(id)
            StemLock.log("stemify request song=\(id) (no stems yet)")
            requestStemify(id)
        }
        let now = Date()
        for id in plan.rips where ripRequestedAt[id].map({ now.timeIntervalSince($0) >= Self.ripRetrySeconds }) ?? true {
            ripRequestedAt[id] = now
            ripLog.append(id)
            NPMixMode.log("rip request song=\(id) (Apple Music only — mixable next play)")
            requestRip(id)
        }
        let steps = plan.steps.filter { s in
            (failedAt[s].map { now.timeIntervalSince($0) >= Self.failureCooldown } ?? true)
                && (blockedAt[s].map { now.timeIntervalSince($0) >= Self.blockedCooldown } ?? true)
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
                self.inFlight = step     // protected from the sweep from here on (activeSongIds)
                if let guardFn = self.diskGuard {
                    let allowed = await guardFn(step)
                    // Superseded while the guard ran: the canceller owns the lane's state.
                    guard !Task.isCancelled else { return }
                    if !allowed {
                        self.inFlight = nil
                        self.blockedAt[step] = Date()
                        StemLock.log("prefetch \(step.description) SKIPPED (storage: free space / buffer cap)")
                        self.onStepFinished?(step, false)
                        continue
                    }
                }
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

extension NowPlayingPrefetcher {
    /// Production wiring: whole songs through the shared `MixStreamLoader` (a finished stream is
    /// adopted as a burn, so the track plays from the device at the boundary), stem parts
    /// through `BurnStore.burnStemPart` — BOTH with origin `.buffer` (np-mix-mode Q5 = yes): a
    /// prefetch is speculative, so what it creates is a TEMPORARY asset that expires after the
    /// Settings TTL unless an explicit Download / Mix action pins it (a file already on the
    /// device is never made temporary), cloud separation
    /// through `RipsStore.stemify` (owner installs only — a hybrid user's lock never enqueues
    /// server work), and the network class from an `NWPathMonitor`.
    ///
    /// EXPLICIT DOWNLOADS SURVIVE: a song with a pending explicit background Download (iOS
    /// `TransferCoordinator`) is NOT streamed by this lane — the stream would cancel that
    /// download, and a stream that then failed lost it for good. The lane waits on the explicit
    /// download instead (`awaitPendingDownload`), and is never what cancels it.
    static func live(streamer: MixStreamLoader, burns: BurnStore, rips: RipsStore,
                     isCatalogOwner: @escaping () -> Bool) -> NowPlayingPrefetcher {
        let p = NowPlayingPrefetcher()
        let monitor = StemLockNetworkMonitor()
        p.network = { monitor.current }
        monitor.onChange = { [weak p] in p?.onNetworkChange?() }
        p.fetchSong = { [weak streamer, weak burns] step in
            guard case let .song(id, title, artist) = step, let streamer, let burns else { return false }
            if burns.hasPendingExplicitDownload(songId: id) {
                StemLock.log("prefetch song:\(id) — explicit download pending; waiting on it (never cancelled)")
                return await awaitPendingDownload(state: { [weak burns] in burns?.items[id]?.state })
            }
            guard let s = streamer.open(id, title: title, artist: artist, origin: .buffer) else { return false }
            while !Task.isCancelled {
                if s.isComplete { return true }
                if s.failed || streamer.stream(for: id) !== s { return false }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }
        p.fetchStemPart = { [weak burns] id, part in
            await burns?.burnStemPart(forSong: id, part: part, origin: .buffer) ?? false
        }
        p.requestStemify = { [weak rips] id in
            guard isCatalogOwner(), let rips else { return }
            Task { await rips.stemify(id) }
        }
        // OWNER ONLY, twice over (the planner already never lists a rip for a non-owner): a
        // public / hybrid install must never POST /rip from Mix Mode (App Store 5.2.3 line).
        // Through the rip provider's `requestAsyncRip`: the same-host deferral (a capture on
        // THIS Mac drives Music.app and interrupts our own Apple Music stream — the 10-14 skip
        // cascade) and `requestRipIfNeeded(playback: true)` — the rip-ahead window gate, and the
        // session tracks + cancels it once it falls out of the window.
        p.requestRip = { [weak rips] id in
            guard isCatalogOwner() else {
                DiagLog.shared.log("npmix", "rip request song=\(id) refused (not the catalog owner)")
                return
            }
            guard let rips else { return }
            Task { await Self.requestOwnerPlaybackRip(id, rips: rips) }
        }
        return p
    }

    /// The Mix Mode rip request (same rules as the passive rip, `RipServerPlaybackProvider
    /// .requestAsyncRip`): deferred entirely on the rip-server's own Mac (its capture drives
    /// Music.app — it would interrupt OUR Apple Music stream, the 10-14 cascade), else a
    /// PLAYBACK rip — gated to the rip-ahead window and tracked so the session cancels it once
    /// the playhead leaves it. The caller has already checked ownership.
    static func requestOwnerPlaybackRip(_ id: String, rips: RipsStore) async {
        if await rips.serverIsThisHost() {
            DiagLog.shared.log("npmix", "rip request song=\(id) deferred (same-host capture)")
            return
        }
        await rips.requestRipIfNeeded(id, playback: true)
    }

    /// How long the lane waits on an explicit download before letting the step go (the
    /// download itself carries on untouched; the step is retried after `failureCooldown`).
    static var pendingDownloadWaitSeconds: Double = 90

    /// Wait (cancellably) for an explicit download's ledger row to leave `.downloading`: true
    /// once it is `.ready`, false when it errored / vanished / the wait ran out.
    static func awaitPendingDownload(state: @escaping () -> BurnStore.State?,
                                     timeout: Double? = nil,
                                     pollNanos: UInt64 = 250_000_000) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? pendingDownloadWaitSeconds)
        while !Task.isCancelled, Date() < deadline {
            switch state() {
            case .ready: return true
            case .downloading: try? await Task.sleep(nanoseconds: pollNanos)
            default: return false
            }
        }
        return false
    }
}

/// The current path's class for the prefetch plan (`NWPathMonitor`, optimistic until the first
/// update). `onChange` fires on the MAIN actor when the class changes.
final class StemLockNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value: NowPlayingPrefetcher.Network = .unmetered
    /// The class changed (main actor).
    @MainActor var onChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let v: NowPlayingPrefetcher.Network
            if path.status != .satisfied { v = .offline }
            else if path.isConstrained { v = .constrained }
            else if path.isExpensive { v = .expensive }
            else { v = .unmetered }
            guard let self else { return }
            self.lock.lock()
            let changed = self.value != v
            self.value = v
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "pdj.stemlock.path"))
    }

    deinit { monitor.cancel() }

    var current: NowPlayingPrefetcher.Network {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
