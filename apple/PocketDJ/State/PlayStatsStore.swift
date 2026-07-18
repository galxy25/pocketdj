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
    func notePlayed(_ songId: String, at nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard !songId.isEmpty else { return }
        if var s = stats[songId] {
            if nowMs - s.lastPlayedAt >= Self.recountWindowMs { s.playCount += 1 }
            s.lastPlayedAt = max(s.lastPlayedAt, nowMs)
            stats[songId] = s
        } else {
            stats[songId] = Stat(playCount: 1, lastPlayedAt: nowMs)
        }
        save()
    }

    /// Epoch ms of the last play, or nil if never played (⇒ pruned first).
    func lastPlayedAt(_ songId: String) -> Double? { stats[songId]?.lastPlayedAt }
    func playCount(_ songId: String) -> Int { stats[songId]?.playCount ?? 0 }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW — see the sync design doc).
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        stats = doc.stats
    }

    private func save() {
        let doc = Document(stats: stats)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let playStatsSchemaVersion = 1
