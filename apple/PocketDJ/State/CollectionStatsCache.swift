import Foundation

// MARK: - CollectionStatsCache — last-known "N songs · 2h 25m" per collection
//
// A collection's subtitle is derived by resolving its members against the CATALOG, so it reads
// "0 songs · 0m" for as long as the catalog is empty — and the catalog is a ~50 MB JSON decode
// that cannot possibly be finished before the first frame. The collections themselves decode
// synchronously at init and are on screen immediately, so without this the user watches their
// real playlists sit there claiming to be empty on every cold launch.
//
// This is the same offline-first shape the catalog itself already uses (`CatalogService`'s
// per-source disk cache → `AppModel.seedFromCache`), applied to the one derived value the list
// shows: remember what each collection last resolved to, render THAT until a real answer is
// available, and never overwrite a real answer with a placeholder.
//
// STICKY, NOT AUTHORITATIVE: `record` only stores stats derived against a non-empty catalog, and
// a cached value is only READ while no real answer exists. So a genuinely emptied collection
// still drops to 0 the moment the catalog is loaded and says so — the cache can delay bad news,
// never invent good news.
@MainActor
final class CollectionStatsCache {
    /// count + runtime, mirroring `CollectionCatalog.Stats` (kept as its own Codable type so the
    /// on-disk shape doesn't move when that struct gains a field).
    struct Entry: Codable, Equatable {
        var count: Int
        var runtimeMs: Int
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL
    /// Set when `entries` has changed since the last write — the flush is debounced through this
    /// rather than writing on every row that resolves.
    private var dirty = false

    init(fileURL: URL = CollectionStatsCache.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-collection-stats.json")
    }

    /// The last-known stats for a collection, or nil if we've never resolved it.
    func stats(for id: String) -> CollectionCatalog.Stats? {
        entries[id].map { CollectionCatalog.Stats(count: $0.count, runtimeMs: $0.runtimeMs) }
    }

    /// Remember a freshly-derived value. `catalogReady` is the caller's assertion that the stats
    /// were computed against a loaded catalog; a false here is ignored, which is what keeps a
    /// cold-launch "0 songs" from being written over a good cached value.
    func record(_ stats: CollectionCatalog.Stats, for id: String, catalogReady: Bool) {
        guard catalogReady else { return }
        let entry = Entry(count: stats.count, runtimeMs: stats.runtimeMs)
        guard entries[id] != entry else { return }
        entries[id] = entry
        dirty = true
    }

    /// Drop collections that no longer exist, so the file can't grow forever.
    func prune(keeping ids: Set<String>) {
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        if entries.count != before { dirty = true }
    }

    /// Write if anything changed. Cheap (a few hundred small entries), and a lost write costs
    /// nothing but one launch's worth of placeholder subtitles.
    func flushIfNeeded() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
