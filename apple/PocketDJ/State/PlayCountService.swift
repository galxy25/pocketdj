import Foundation
import Observation

/// THE one place that answers "how many times has this song been played?" — the value the
/// Browser's `#NN` badge renders, the "Plays" sort orders by, the Gem Collector weights by, and
/// the rec engine ranks with.
///
/// Three buckets, added exactly once each:
///
///   1. `baseline` — Apple's lifetime counter as of the last snapshot. The bulk of the signal
///      (~144k plays vs this app's ~900).
///   2. `stats.nonApplePlayCount` — plays PocketDJ made that Apple never saw: rips, stems, vinyl,
///      digital files, local burns, the Mix decks. These accumulate forever; no snapshot can
///      retire them, because no snapshot ever contained them.
///   3. `baseline.provisionalCount` — Apple-Music plays PocketDJ made SINCE the last snapshot.
///      Shown immediately so the badge moves the moment you press play, then retired by the next
///      capture (which now contains them). Adding `stats.playCount` wholesale instead would count
///      every one of these twice the day a capture runs.
///
/// The split is why `PlayStatsStore.notePlayed` carries an `appleCounted` tag at all.
@MainActor
@Observable
final class PlayCountService {

    @ObservationIgnored let baseline: AMPlayBaselineStore
    @ObservationIgnored private let stats: PlayStatsStore

    /// Bumped whenever any bucket changes. Memo keys (the Browse results cache, the row badges)
    /// fold this in — the maps themselves are far too big to diff per render.
    private(set) var revision: Int = 0

    init(baseline: AMPlayBaselineStore, stats: PlayStatsStore) {
        self.baseline = baseline
        self.stats = stats
        revision = baseline.revision
    }

    /// The lifetime total for one song. Never negative; 0 for a song nothing has ever played.
    func combinedPlayCount(_ songId: String) -> Int {
        guard !songId.isEmpty else { return 0 }
        return baseline.count(songId)
            + stats.nonApplePlayCount(songId)
            + baseline.provisionalCount(songId)
    }

    /// Apple's own last-played date, when it knows one — strictly reference data for the UI.
    /// Deliberately NOT wired into `PlayStatsStore.lastPlayedAt`: that is the storage manager's
    /// LRP eviction key, and seeding it from Apple would reshuffle the whole downloaded set.
    func applePlayedAt(_ songId: String) -> Double? { baseline.lastPlayed(songId) }

    /// Every song with a non-zero lifetime total, as a plain value map — the snapshot the OFF-MAIN
    /// Browse filter/sort and the Gem Collector sampler take on the main actor and then read from
    /// a detached task.
    func snapshot() -> [String: Int] {
        var out = baseline.countsSnapshot()
        for (id, n) in stats.nonApplePlayCountsSnapshot() { out[id, default: 0] += n }
        for (id, stamps) in baseline.provisional where !stamps.isEmpty {
            out[id, default: 0] += stamps.count
        }
        return out
    }

    // MARK: - Writes (the ONE funnel every play surface goes through)

    /// Record a play. `backend` decides which bucket it lands in:
    ///   • `.appleMusic` → `PlayStatsStore` (tagged) AND the provisional bucket, so it shows now
    ///     and is retired by the capture that absorbs it.
    ///   • everything else → `PlayStatsStore` only, permanently.
    func notePlayed(_ songId: String, backend: PlaybackBackend?,
                    at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        let apple = backend == .appleMusic
        stats.notePlayed(songId, at: nowMs, appleCounted: apple)
        if apple { baseline.noteApplePlay(songId, at: nowMs) }
        revision &+= 1
    }

    /// Adopt a fresh Apple snapshot (SET semantics — see `AMPlayBaselineStore.replaceAll`).
    /// Returns `false` when the capture was rejected for being all-zero.
    @discardableResult
    func applyCapture(counts: [String: AMPlayBaselineStore.Entry], capturedAtMs: Double,
                      source: String? = nil, sourceName: String? = nil,
                      lastPlayedHighWaterMs: Double? = nil) -> Bool {
        let ok = baseline.replaceAll(counts: counts, capturedAtMs: capturedAtMs, source: source,
                                     sourceName: sourceName,
                                     lastPlayedHighWaterMs: lastPlayedHighWaterMs)
        revision &+= 1
        return ok
    }

    /// Import the exporter's `playcounts.json` (or a previously saved snapshot).
    @discardableResult
    func importBaseline(from url: URL) throws -> Bool {
        defer { revision &+= 1 }
        return try baseline.importFile(at: url)
    }

    @discardableResult
    func importBaseline(json data: Data) throws -> Bool {
        defer { revision &+= 1 }
        return try baseline.importJSON(data)
    }
}
