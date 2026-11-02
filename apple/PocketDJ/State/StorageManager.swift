import Foundation
import Observation

/// The storage manager's PRUNE engine (Settings ▸ Storage / TV Settings ▸ Storage). When
/// the user sets a SOFT CAP — in decimal GB (`storageSoftCapGB`) or as a #-of-songs count
/// (`storageSoftCapSongs`) — the app tries once a day — in the background (iOS BGTask) or
/// on foreground activation — to evict burned media, LEAST-RECENTLY-PLAYED first, until
/// the burned footprint fits under the cap(s). The caps are UNSET by default: no cap ⇒ the
/// app NEVER deletes media on its own; storage stays fully user-managed via the manual
/// delete tools.
///
/// tvOS is the exception (task #48): TV burns live in Caches and must keep themselves
/// bounded, so on tvOS the TV Settings "Auto-manage storage" toggle (ON by default) is the
/// master switch — toggle OFF ⇒ no pruning even with a cap set, toggle ON with no explicit
/// cap ⇒ the default `tvDefaultCapGB` applies. See `autoManageGate` / `activeCap()`.
///
/// Pruning removes downloaded media only (burn ledger + on-disk files, via
/// `BurnStore.removeBurns`) — the catalog and collections are untouched, and anything
/// pruned re-downloads on the next burn. Session recordings are user-created content and
/// are never auto-pruned.
@MainActor
@Observable
final class StorageManager {
    @ObservationIgnored private let burns: BurnStore
    @ObservationIgnored private let playStats: PlayStatsStore
    @ObservationIgnored private let settings: SettingsStore
    /// Song ids that must not be pruned RIGHT NOW (deck-loaded / now-playing) — deleting a
    /// file the player holds open breaks audio mid-song. Wired at app init; `{ [] }` in tests.
    @ObservationIgnored var protectedSongIds: () -> Set<String> = { [] }

    /// The daily-prune BGProcessingTask id (declared in Info.plist's
    /// BGTaskSchedulerPermittedIdentifiers; registered/armed by AppDelegate on iOS).
    nonisolated static let bgTaskId = "com.levi.pocketdj.storage-prune"

    /// Decimal GB (1 GB = 10⁹ bytes) — matches what Finder / the Files app show the user.
    nonisolated static let bytesPerGB: Double = 1_000_000_000
    /// The soft cap (decimal GB) tvOS applies while auto-manage is ON and no explicit cap
    /// has been picked — a fresh Apple TV bounds its Caches burns with zero setup. 5 GB ≈
    /// a few hundred burned songs: bounded, but roomy enough that a typical TV mix session
    /// never churns its own queue out from under itself.
    nonisolated static let tvDefaultCapGB: Double = 5
    /// Whether THIS platform's pruning is gated by the `storageAutoManage` toggle. tvOS
    /// only — iPhone/iPad/Mac keep the original contract (cap set ⇒ prune, toggle ignored).
    nonisolated static var platformAutoManageGate: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }
    /// The once-a-day gate's interval. 20 h (not 24) so a "daily at breakfast" launch
    /// cadence keeps qualifying instead of drifting ever later.
    nonisolated static let pruneIntervalMs: Double = 20 * 3600 * 1000

    /// tvOS policy switch, an instance var (not an #if) so the TV semantics are fully
    /// unit-testable from the iOS test bundle. When true, `settings.storageAutoManage`
    /// gates ALL pruning and toggle-ON-with-no-cap applies `tvDefaultCapGB`.
    @ObservationIgnored var autoManageGate: Bool = StorageManager.platformAutoManageGate

    /// The last completed prune's outcome (drives the Storage screen's status line).
    private(set) var lastResult: PruneResult?

    struct PruneResult: Equatable {
        var evicted = 0          // songs removed
        var freedBytes = 0
        var usageBytes = 0       // burned footprint AFTER the prune
        var capBytes = 0         // 0 ⇒ no byte cap was in force (songs-only prune)
        var usageSongs = 0       // ready burned songs AFTER the prune
        var capSongs = 0         // 0 ⇒ no songs cap was in force
    }

    /// The cap actually in force, resolved from settings + the platform's auto-manage
    /// policy. nil ⇒ pruning is OFF (fully manual storage). Off the TV both caps are read
    /// straight from settings; on tvOS (`autoManageGate`) the TV Settings toggle is the
    /// master switch, and ON-with-no-explicit-cap falls back to `tvDefaultCapGB`.
    struct ActiveCap: Equatable {
        var bytes: Int?          // nil = no byte cap
        var songs: Int?          // nil = no songs cap
    }
    func activeCap() -> ActiveCap? {
        if autoManageGate && !settings.storageAutoManage { return nil }
        let bytes = settings.storageSoftCapGB.map { Int($0 * Self.bytesPerGB) }
        let songs = settings.storageSoftCapSongs
        if bytes != nil || songs != nil { return ActiveCap(bytes: bytes, songs: songs) }
        if autoManageGate { return ActiveCap(bytes: Int(Self.tvDefaultCapGB * Self.bytesPerGB), songs: nil) }
        return nil
    }

    init(burns: BurnStore, playStats: PlayStatsStore, settings: SettingsStore) {
        self.burns = burns
        self.playStats = playStats
        self.settings = settings
    }

    /// True while a prune is running — the 15-min tick, scenePhase hook and BGTask can all
    /// fire close together; only one pass may run.
    @ObservationIgnored private(set) var isPruning = false
    /// Evictions per main-actor turn in the async pass — big enough to be quick, small
    /// enough that the UI never stalls behind a long delete run.
    nonisolated static let evictionChunk = 25

    /// The once-a-day gate: prune only when a cap is SET and the last run is old enough.
    /// Called from the daily BGTask (iOS) and every foreground activation (both platforms).
    func pruneIfDue(now: Double = Date().timeIntervalSince1970 * 1000) async {
        guard activeCap() != nil, !isPruning else { return }   // no active cap ⇒ manual-only
        if let last = settings.lastStoragePruneAt, now - last < Self.pruneIntervalMs { return }
        await prune(now: now)
    }

    /// The app's prune: plan once, then evict in small chunks, yielding the main actor
    /// between them so taps, playback and the UI keep running through a multi-GB prune.
    @discardableResult
    func prune(now: Double = Date().timeIntervalSince1970 * 1000) async -> PruneResult? {
        guard !isPruning, let run = beginPrune(now: now) else { return nil }
        isPruning = true
        defer { isPruning = false }
        var start = 0
        while start < run.plan.evict.count {
            let end = min(start + Self.evictionChunk, run.plan.evict.count)
            // Re-read the protected set per chunk: a song loaded onto a deck mid-prune is spared.
            evict(Array(run.plan.evict[start..<end]), protected: protectedSongIds())
            start = end
            await Task.yield()
        }
        return finishPrune(run)
    }

    /// Synchronous prune (Settings' "prune now" path and tests): same plan, one batch.
    @discardableResult
    func pruneNow(now: Double = Date().timeIntervalSince1970 * 1000) -> PruneResult? {
        guard !isPruning, let run = beginPrune(now: now) else { return nil }
        evict(run.plan.evict, protected: protectedSongIds())
        return finishPrune(run)
    }

    /// One eviction batch. A song that is still TEMPORARY (buffered audio) goes through the
    /// hold-scoped primitive — only what its hold lists, so stems the user pinned for it survive
    /// — and every other song through the ordinary `removeBurns`. Protected ids (and their
    /// edition variants) are skipped.
    private func evict(_ ids: [String], protected: Set<String>) {
        let bases = Self.bases(of: protected)
        let live = ids.filter { !protected.contains($0) }
        let temp = live.filter { burns.isTemporary($0) && !Self.isProtected($0, protected: protected, bases: bases) }
        let tempSet = Set(temp)
        if !temp.isEmpty { burns.removeTemporaryAssets(songIds: temp) }
        burns.removeBurns(songIds: live.filter { !tempSet.contains($0) && !(burns.isTemporary($0)) })
    }

    private struct PruneRun {
        var cap: ActiveCap
        var usageBefore: Int
        var plan: BurnStore.EvictionPlan
        var itemsBefore: Int
    }

    /// Evict least-recently-played burned songs until the burned footprint fits the active
    /// cap(s) — bytes, song count, or both: never-played songs first (oldest download
    /// first), then by last play time. ONE disk scan plans the whole pass
    /// (`BurnStore.planEviction`) and the footprint is re-measured once at the end — never
    /// per eviction. The daily stamp is written FIRST: if the process dies mid-prune
    /// (watchdog, jetsam, user force-quit) the next launch must NOT retry straight away —
    /// that is exactly the launch-crash loop a 35 GB → 32 GB cap produced. No-op when no
    /// cap is active.
    private func beginPrune(now: Double) -> PruneRun? {
        guard let cap = activeCap() else { return nil }
        settings.lastStoragePruneAt = now
        settings.persist()
        let capBytes = cap.bytes ?? Int.max
        let capSongs = cap.songs ?? Int.max
        let usageBefore = burns.burnedUsageBytes()
        if usageBefore > capBytes {
            // Cheap space first: orphan stem/beat-grid cache (songs with no burned
            // audio) goes before any real burned song is evicted.
            burns.sweepOrphanAuxFiles()
        }
        let protected = protectedSongIds()
        // TEMPORARY (buffered) songs go first, soonest expiry first (np-mix-mode §3.5) — they
        // were never asked for — then the pinned burns, least-recently-played first.
        let protectedBases = Self.bases(of: protected)
        let tempFirst = burns.temporaryHolds.values
            .filter { $0.audio && burns.items[$0.songId]?.state == .ready
                && !Self.isProtected($0.songId, protected: protected, bases: protectedBases) }
            .sorted { ($0.expiresAtMs, $0.songId) < ($1.expiresAtMs, $1.songId) }
            .map(\.songId)
        let tempSet = Set(tempFirst)
        // LRP first — never-played (0) ahead of everything, oldest download breaking ties.
        // A burn's `songId` is the RESOLVING id, so a substituted (clean/explicit) burn is
        // keyed "sng_…_clean" while its plays are recorded against the BASE song — read
        // recency through `baseId` or every variant burn looks never-played and is evicted
        // first, ahead of genuinely cold files.
        let order = tempFirst + burns.items.values
            .filter { $0.state == .ready && !protected.contains($0.songId) && !tempSet.contains($0.songId) }
            .map { (item: $0, last: playStats.lastPlayedAt(SongVariant.baseId($0.songId)) ?? 0) }
            .sorted { a, b in
                if a.last != b.last { return a.last < b.last }
                return a.item.downloadedAt < b.item.downloadedAt
            }
            .map(\.item.songId)
        let plan = burns.planEviction(order: order, capBytes: capBytes, capSongs: capSongs)
        DiagLog.shared.log("storage", "prune start usage=\(usageBefore) cap=\(cap.bytes ?? 0) capSongs=\(cap.songs ?? 0) songs=\(burns.readyBurnedIds.count) evict=\(plan.evict.count) projected=\(plan.projectedBytes)")
        return PruneRun(cap: cap, usageBefore: usageBefore, plan: plan, itemsBefore: burns.items.count)
    }

    // MARK: Temporary-asset expiry sweep (np-mix-mode §3.5)

    /// The outcome of one temporary sweep.
    struct SweepResult: Equatable {
        var removed = 0          // holds fully removed (songs)
        var freedBytes = 0       // ledger-credited bytes deleted
        var skippedProtected = 0 // eligible holds spared because something is using them
        var kept = 0             // holds kept in part (unreachable folder)
        var remaining = 0        // holds left afterwards
    }

    /// The last completed sweep's outcome (the Storage section's status line).
    private(set) var lastSweep: SweepResult?
    /// Holds removed per main-actor turn — the same chunk the prune uses.
    nonisolated static let sweepChunk = 25
    /// While-active cadence of the expiry sweep (the 15-min tick checks this gate).
    nonisolated static let temporarySweepIntervalMs: Double = 60 * 60 * 1000
    /// A cap sweep scheduled by a hold landing, not yet run (debounce).
    @ObservationIgnored private var capSweepScheduled = false

    /// `protected` plus each id's BASE: a hold keyed by an edition variant ("sng_…_clean") is
    /// spared when the base row is playing and vice versa — over-protecting only ever keeps a
    /// file a little longer.
    nonisolated static func bases(of ids: Set<String>) -> Set<String> { Set(ids.map(SongVariant.baseId)) }
    nonisolated static func isProtected(_ id: String, protected: Set<String>, bases: Set<String>) -> Bool {
        protected.contains(id) || bases.contains(SongVariant.baseId(id))
    }

    /// PURE PLAN (no disk I/O — the ledger's credited bytes only): the holds to delete, in
    /// order — every EXPIRED unprotected hold (soonest expiry first; `ignoreExpiry` = "Clear
    /// now": all of them), then, while the remaining temporary footprint is still over
    /// `capBytes`, the soonest-expiring unprotected holds that haven't expired yet.
    nonisolated static func planSweep(holds: [BurnStore.TemporaryHold], now: Double, capBytes: Int,
                                      protected: Set<String>, ignoreExpiry: Bool = false)
        -> (delete: [String], skippedProtected: Int) {
        let bases = Self.bases(of: protected)
        let ordered = holds.sorted { ($0.expiresAtMs, $0.songId) < ($1.expiresAtMs, $1.songId) }
        var delete: [String] = []
        var skipped = 0
        var footprint = holds.reduce(0) { $0 + $1.bytes }
        var rest: [BurnStore.TemporaryHold] = []
        for h in ordered {
            guard ignoreExpiry || h.expiresAtMs <= now else { rest.append(h); continue }
            if isProtected(h.songId, protected: protected, bases: bases) { skipped += 1; continue }
            delete.append(h.songId)
            footprint -= h.bytes
        }
        for h in rest where footprint > capBytes {
            if isProtected(h.songId, protected: protected, bases: bases) { continue }
            delete.append(h.songId)
            footprint -= h.bytes
        }
        return (delete, skipped)
    }

    /// The EXPIRY SWEEP: delete temporary (buffered) assets past their TTL — and, over the
    /// buffer cap, the soonest-expiring ones — never anything protected (the current song and
    /// the upcoming window, Mix decks, in-flight downloads, the restored session's window: see
    /// `protectedSongIds`). Not gated on the soft cap: the TTL is on by default.
    ///
    /// Main-thread discipline (the 2026-10-23 launch-crash-loop lesson): the stamp is written
    /// FIRST (a process that dies mid-sweep never retries in a tight loop), the plan is ONE pass
    /// over the ledger (no disk scan at all), deletion runs in chunks of `sweepChunk` with a
    /// `Task.yield()` between them, the protected set is RE-READ and each hold RE-VALIDATED per
    /// chunk (a pin, a deck load or a track change mid-sweep is honoured), and the pass is
    /// single-flight with the prune (`isPruning`).
    @discardableResult
    func sweepTemporary(now: Double = Date().timeIntervalSince1970 * 1000, reason: String,
                        ignoreExpiry: Bool = false) async -> SweepResult? {
        guard !isPruning else { return nil }
        guard !burns.temporaryHolds.isEmpty else {
            lastSweep = SweepResult()
            return SweepResult()
        }
        isPruning = true
        defer { isPruning = false }
        settings.lastTemporarySweepAt = now
        settings.persist()
        let capBytes = settings.npMixBufferCapBytes
        let plan = Self.planSweep(holds: Array(burns.temporaryHolds.values), now: now, capBytes: capBytes,
                                  protected: protectedSongIds(), ignoreExpiry: ignoreExpiry)
        DiagLog.shared.log("storage", "sweep start reason=\(reason) holds=\(burns.temporaryHolds.count) footprint=\(burns.temporaryFootprintBytes) cap=\(capBytes) n=\(plan.delete.count) protected=\(plan.skippedProtected)")
        var result = SweepResult(skippedProtected: plan.skippedProtected)
        var start = 0
        while start < plan.delete.count {
            let end = min(start + Self.sweepChunk, plan.delete.count)
            let protected = protectedSongIds()
            let bases = Self.bases(of: protected)
            // Re-validate against the LIVE ledger: still held (not pinned meanwhile), still
            // eligible (an expiry pick whose hold was extended by a fresh landing is spared;
            // cap picks are re-checked against the cap), and not in use right now.
            var footprint = burns.temporaryFootprintBytes
            let chunk = plan.delete[start..<end].filter { id in
                guard let h = burns.temporaryHolds[id] else { return false }
                if Self.isProtected(id, protected: protected, bases: bases) { result.skippedProtected += 1; return false }
                guard ignoreExpiry || h.expiresAtMs <= now || footprint > capBytes else { return false }
                footprint -= h.bytes
                return true
            }
            let r = burns.removeTemporaryAssets(songIds: chunk)
            result.removed += r.songs
            result.freedBytes += r.bytes
            result.kept += r.kept
            start = end
            await Task.yield()
        }
        result.remaining = burns.temporaryHolds.count
        DiagLog.shared.log("storage", "sweep done reason=\(reason) n=\(result.removed) freed=\(result.freedBytes) kept=\(result.kept) protected=\(result.skippedProtected) left=\(result.remaining)")
        lastSweep = result
        return result
    }

    /// The gated sweep for launch / foreground / the while-active tick / the BG task: a no-op
    /// with no holds, or when the last sweep STARTED less than `minIntervalMs` ago.
    func sweepTemporaryIfDue(now: Double = Date().timeIntervalSince1970 * 1000, reason: String,
                             minIntervalMs: Double = StorageManager.temporarySweepIntervalMs) async {
        guard !burns.temporaryHolds.isEmpty, !isPruning else { return }
        if let last = settings.lastTemporarySweepAt, now >= last, now - last < minIntervalMs { return }
        await sweepTemporary(now: now, reason: reason)
    }

    /// A hold just landed (`BurnStore.onTemporaryHoldsChanged`): when the temporary footprint is
    /// over the buffer cap, run ONE cap sweep on a later turn (debounced — a burst of stem parts
    /// schedules a single pass, and the landing call never waits on deletes).
    func scheduleCapSweepIfNeeded() {
        guard !capSweepScheduled, burns.temporaryFootprintBytes > settings.npMixBufferCapBytes else { return }
        capSweepScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.capSweepScheduled = false
            await self.sweepTemporary(reason: "cap")
        }
    }

    private func finishPrune(_ run: PruneRun) -> PruneResult {
        let usage = burns.burnedUsageBytes()
        let result = PruneResult(evicted: max(0, run.itemsBefore - burns.items.count),
                                 freedBytes: max(0, run.usageBefore - usage),
                                 usageBytes: usage, capBytes: run.cap.bytes ?? 0,
                                 usageSongs: burns.readyBurnedIds.count, capSongs: run.cap.songs ?? 0)
        DiagLog.shared.log("storage", "prune done evicted=\(result.evicted) freed=\(result.freedBytes) usage=\(usage)")
        lastResult = result
        return result
    }
}
