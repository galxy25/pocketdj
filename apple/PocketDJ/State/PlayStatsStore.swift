import Foundation
import Observation

/// Tracks WHEN and HOW OFTEN each song is played on this device — the signal the storage
/// manager's soft-cap prune orders by (least-recently-played burned media is evicted
/// first). Plays funnel in from every surface: `RipsStore.nowPlaying` transitions (single
/// rows, set lists, burned local files, rip streaming), `PlaybackCoordinator.play`
/// successes (Apple Music streaming, which never touches `RipsStore.nowPlaying`), and the
/// Mix decks' transport funnel (`MixEngine.setPlaying`). A short re-count window absorbs
/// the overlap between those hooks (a burned play fires both 1 and 2) and seek/restarts.
///
/// Persists to Application Support `pocketdj-play-stats.json` (mirrors CollectionsStore
/// durable-JSON: atomic save, decode-on-init, PDJ_USE_FIXTURE test seam). Syncs across the
/// user's devices via CloudSyncService (whole-document LWW; `reloadFromDisk` applies pulls).
@MainActor
@Observable
final class PlayStatsStore {

    /// One song's play history (all this needs to order an LRP prune).
    struct Stat: Codable, Equatable {
        var playCount: Int
        /// Epoch ms of the most recent play (refreshed even inside the re-count window).
        var lastPlayedAt: Double
        /// How many of `playCount` were streamed through Apple Music — i.e. how many APPLE ALSO
        /// COUNTED on its own side. Subtracting these is what stops a combined lifetime total
        /// from counting one play twice once the next Apple snapshot lands (see
        /// `AMPlayBaselineStore`). OPTIONAL so older documents keep decoding untouched — new
        /// optional field, no schema bump (a bump has previously discarded user data here).
        var appleCount: Int?
    }

    /// The persisted, versioned document.
    struct Document: Codable {
        var schemaVersion: Int = playStatsSchemaVersion
        var stats: [String: Stat] = [:]
    }

    private(set) var stats: [String: Stat] = [:]
    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }

    /// Repeated notes for the SAME song inside this window refresh `lastPlayedAt` but don't
    /// re-count — a seek/restart (or the burned-play double-hook) isn't a second listen.
    nonisolated static let recountWindowMs: Double = 30_000

    init(fileURL: URL = PlayStatsStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            stats = doc.stats
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-play-stats.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches
    /// the user's real stats). Mirrors CollectionsStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-play-stats.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Record a play. `at` is injectable for tests; callers use the default (now).
    ///
    /// `appleCounted` TAGS THE SOURCE and is the whole double-count defence. Apple increments its
    /// OWN counter whenever PocketDJ streams through `ApplicationMusicPlayer`, so such a play will
    /// arrive again in the next `AMPlayBaselineStore` snapshot; recording it here as well is
    /// correct for THIS store (it is a play, and the LRP prune must see it) but must be
    /// subtractable when the two are combined. Everything else — rip, stem, vinyl, digital, local
    /// file, Mix decks — leaves it false and accumulates permanently.
    func notePlayed(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000,
                    appleCounted: Bool = false) {
        guard !songId.isEmpty else { return }
        if var s = stats[songId] {
            if nowMs - s.lastPlayedAt >= Self.recountWindowMs {
                s.playCount += 1
                if appleCounted { s.appleCount = (s.appleCount ?? 0) + 1 }
            }
            s.lastPlayedAt = max(s.lastPlayedAt, nowMs)
            stats[songId] = s
        } else {
            stats[songId] = Stat(playCount: 1, lastPlayedAt: nowMs,
                                 appleCount: appleCounted ? 1 : nil)
        }
        save()
    }

    /// PEER-PLAY SEAM: when this song was last played on ANOTHER device. Wired at app init to
    /// `PlayHistoryStore.lastPlayedAtAnyDevice` once history merges across devices; nil in tests.
    ///
    /// DERIVED, NOT ACCUMULATED — deliberately. The obvious implementation is to feed merged peer
    /// events into `notePlayed`, but that mutates a running counter from a log that can be
    /// re-merged (a re-pull, a device restore, a backup import), and every replay would inflate the
    /// count and drag the eviction order with it. Reading the merged log at query time cannot
    /// double-count by construction, no bookkeeping required.
    @ObservationIgnored var peerLastPlayedAt: ((String) -> Double?)?

    /// Epoch ms of the last play ON ANY DEVICE, or nil if never played (⇒ pruned first).
    /// This is the storage prune's LRP key, so a play on the Mac protects the phone's copy too.
    func lastPlayedAt(_ songId: String) -> Double? {
        let local = stats[songId]?.lastPlayedAt
        guard let peer = peerLastPlayedAt?(songId) else { return local }
        guard let local else { return peer }
        return max(local, peer)
    }

    /// This device's own last play, ignoring peers — for anything that must reason about local
    /// behaviour specifically rather than "was this listened to anywhere".
    func lastPlayedAtLocally(_ songId: String) -> Double? { stats[songId]?.lastPlayedAt }
    func playCount(_ songId: String) -> Int { stats[songId]?.playCount ?? 0 }

    /// Plays Apple did NOT also count — the only part of this store that may be ADDED to an
    /// Apple snapshot without double-counting. See `notePlayed(appleCounted:)`.
    func nonApplePlayCount(_ songId: String) -> Int {
        guard let s = stats[songId] else { return 0 }
        return max(0, s.playCount - (s.appleCount ?? 0))
    }

    /// A pure copy of the NON-APPLE counts, for the combined lifetime total's off-main readers.
    func nonApplePlayCountsSnapshot() -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(stats.count)
        for (id, s) in stats {
            let n = s.playCount - (s.appleCount ?? 0)
            if n > 0 { out[id] = n }
        }
        return out
    }

    /// A pure copy of the play counts for OFF-MAIN weighting (the Collectors Puzzle
    /// sampler snapshots this on the main actor, then samples detached).
    func playCountsSnapshot() -> [String: Int] { stats.mapValues(\.playCount) }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW — see the sync design doc).
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        stats = doc.stats
    }

    /// Wipe all play history: reset the in-memory map (so the UI updates immediately) and
    /// remove the persisted document. `try?` swallows a missing file, mirroring `save()`.
    func clear() {
        stats = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let doc = Document(stats: stats)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let playStatsSchemaVersion = 1
