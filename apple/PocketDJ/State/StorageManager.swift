import Foundation
import Observation

/// The storage manager's PRUNE engine (Settings ▸ Storage). When the user sets a SOFT CAP,
/// the app tries once a day — in the background (iOS BGTask) or on foreground activation —
/// to evict burned media, LEAST-RECENTLY-PLAYED first, until the burned footprint fits
/// under the cap. The cap is UNSET by default: no cap ⇒ the app NEVER deletes media on its
/// own; storage stays fully user-managed via the manual delete tools.
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
    /// The once-a-day gate's interval. 20 h (not 24) so a "daily at breakfast" launch
    /// cadence keeps qualifying instead of drifting ever later.
    nonisolated static let pruneIntervalMs: Double = 20 * 3600 * 1000

    /// The last completed prune's outcome (drives the Storage screen's status line).
    private(set) var lastResult: PruneResult?

    struct PruneResult: Equatable {
        var evicted = 0          // songs removed
        var freedBytes = 0
        var usageBytes = 0       // burned footprint AFTER the prune
        var capBytes = 0
    }

    init(burns: BurnStore, playStats: PlayStatsStore, settings: SettingsStore) {
        self.burns = burns
        self.playStats = playStats
        self.settings = settings
    }

    /// The once-a-day gate: prune only when a cap is SET and the last run is old enough.
    /// Called from the daily BGTask (iOS) and every foreground activation (both platforms).
    func pruneIfDue(now: Double = Date().timeIntervalSince1970 * 1000) {
        guard settings.storageSoftCapGB != nil else { return }   // unset cap ⇒ manual-only
        if let last = settings.lastStoragePruneAt, now - last < Self.pruneIntervalMs { return }
        pruneNow(now: now)
    }

    /// Evict least-recently-played burned songs until the burned footprint fits the cap:
    /// never-played songs first (oldest download first), then by last play time. Usage is
    /// re-measured from disk after each eviction (a shared analog album mp3 only frees
    /// when its LAST song goes). No-op when the cap is unset.
    @discardableResult
    func pruneNow(now: Double = Date().timeIntervalSince1970 * 1000) -> PruneResult? {
        guard let capGB = settings.storageSoftCapGB else { return nil }
        let capBytes = Int(capGB * Self.bytesPerGB)
        var usage = burns.burnedUsageBytes()
        var result = PruneResult(usageBytes: usage, capBytes: capBytes)
        if usage > capBytes {
            let protected = protectedSongIds()
            // LRP first — never-played (0) ahead of everything, oldest download breaking ties.
            let candidates = burns.items.values
                .filter { $0.state == .ready && !protected.contains($0.songId) }
                .sorted { a, b in
                    let lastA = playStats.lastPlayedAt(a.songId) ?? 0
                    let lastB = playStats.lastPlayedAt(b.songId) ?? 0
                    if lastA != lastB { return lastA < lastB }
                    return a.downloadedAt < b.downloadedAt
                }
            for candidate in candidates {
                guard usage > capBytes else { break }
                burns.removeBurns(songIds: [candidate.songId])
                let after = burns.burnedUsageBytes()
                result.freedBytes += max(0, usage - after)
                result.evicted += 1
                usage = after
            }
        }
        result.usageBytes = usage
        settings.lastStoragePruneAt = now
        settings.persist()
        lastResult = result
        return result
    }
}
