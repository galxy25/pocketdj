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

    /// The once-a-day gate: prune only when a cap is SET and the last run is old enough.
    /// Called from the daily BGTask (iOS) and every foreground activation (both platforms).
    func pruneIfDue(now: Double = Date().timeIntervalSince1970 * 1000) {
        guard activeCap() != nil else { return }   // no active cap ⇒ manual-only
        if let last = settings.lastStoragePruneAt, now - last < Self.pruneIntervalMs { return }
        pruneNow(now: now)
    }

    /// Evict least-recently-played burned songs until the burned footprint fits the active
    /// cap(s) — bytes, song count, or both: never-played songs first (oldest download
    /// first), then by last play time. Usage is re-measured from disk after each eviction
    /// (a shared analog album mp3 only frees when its LAST song goes). No-op when no cap
    /// is active.
    @discardableResult
    func pruneNow(now: Double = Date().timeIntervalSince1970 * 1000) -> PruneResult? {
        guard let cap = activeCap() else { return nil }
        let capBytes = cap.bytes ?? Int.max
        let capSongs = cap.songs ?? Int.max
        var usage = burns.burnedUsageBytes()
        var songCount = burns.readyBurnedIds.count
        var result = PruneResult(usageBytes: usage, capBytes: cap.bytes ?? 0,
                                 usageSongs: songCount, capSongs: cap.songs ?? 0)
        if usage > capBytes {
            // Cheap space first: orphan stem/beat-grid cache (songs with no burned
            // audio) goes before any real burned song is evicted.
            burns.sweepOrphanAuxFiles()
            let afterSweep = burns.burnedUsageBytes()
            result.freedBytes += max(0, usage - afterSweep)
            usage = afterSweep
        }
        if usage > capBytes || songCount > capSongs {
            let protected = protectedSongIds()
            // LRP first — never-played (0) ahead of everything, oldest download breaking ties.
            // A burn's `songId` is the RESOLVING id, so a substituted (clean/explicit) burn is
            // keyed "sng_…_clean" while its plays are recorded against the BASE song — read
            // recency through `baseId` or every variant burn looks never-played and is evicted
            // first, ahead of genuinely cold files.
            let candidates = burns.items.values
                .filter { $0.state == .ready && !protected.contains($0.songId) }
                .sorted { a, b in
                    let lastA = playStats.lastPlayedAt(SongVariant.baseId(a.songId)) ?? 0
                    let lastB = playStats.lastPlayedAt(SongVariant.baseId(b.songId)) ?? 0
                    if lastA != lastB { return lastA < lastB }
                    return a.downloadedAt < b.downloadedAt
                }
            for candidate in candidates {
                guard usage > capBytes || songCount > capSongs else { break }
                burns.removeBurns(songIds: [candidate.songId])
                let after = burns.burnedUsageBytes()
                result.freedBytes += max(0, usage - after)
                result.evicted += 1
                usage = after
                songCount = burns.readyBurnedIds.count
            }
        }
        result.usageBytes = usage
        result.usageSongs = burns.readyBurnedIds.count
        settings.lastStoragePruneAt = now
        settings.persist()
        lastResult = result
        return result
    }
}
