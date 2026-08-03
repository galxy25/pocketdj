import Foundation

// MARK: - SourcePlaylistsCache — last-known "From your sources" rows
//
// The Collections tab's SHARED sub-tab renders `AppModel.indexPlaylists`, which only exists
// once the catalog has been decoded and derived. That is ~61 MB of JSON across three sources
// (measured 636 ms to decode plus ~1.7 s to derive on an M-series Mac, several seconds on an
// iPhone), so for the whole of that window the tab shows its "No source playlists" empty state
// — as if the user had none.
//
// The rows themselves are tiny: id, name, source, and the member ids. Persisting just those
// lets the tab paint its real contents immediately and correct itself when the catalog lands.
// Same offline-first shape as CatalogService's per-source disk cache and CollectionStatsCache:
// remember the last real answer, show it while no better one exists, never overwrite a real
// answer with an empty one.
//
// NOT AUTHORITATIVE. `record` ignores an empty set, and `AppModel` serves the cache only while
// `indexPlaylists` is empty — so a user who genuinely removed every source playlist still sees
// them disappear the moment the catalog says so. The cache can delay bad news, never invent
// good news.
@MainActor
final class SourcePlaylistsCache {
    /// The persisted shape. Deliberately its OWN Codable type rather than reusing
    /// `SourcePlaylist`/`IndexPlaylist`, so the on-disk format doesn't move when those gain a
    /// field (and a decode of an older file can't fail because of one).
    struct Row: Codable, Equatable {
        var id: String
        var name: String
        var sourceName: String
        var songIds: [String]
    }

    private var rows: [Row] = []
    private let fileURL: URL
    private var dirty = false

    init(fileURL: URL = SourcePlaylistsCache.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Row].self, from: data) {
            rows = decoded
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-source-playlists.json")
    }

    /// The remembered rows, rebuilt into the type the UI renders.
    func snapshot() -> [SourcePlaylist] {
        rows.map {
            SourcePlaylist(playlist: IndexPlaylist(id: $0.id, name: $0.name, songIds: $0.songIds),
                           sourceName: $0.sourceName)
        }
    }

    /// Remember a freshly-derived set. An EMPTY set is ignored: at launch the catalog is empty
    /// before it is loaded, and recording that would erase the very thing this exists to show.
    func record(_ playlists: [SourcePlaylist]) {
        guard !playlists.isEmpty else { return }
        let next = playlists.map {
            Row(id: $0.playlist.id, name: $0.playlist.name,
                sourceName: $0.sourceName, songIds: $0.playlist.songIds)
        }
        guard next != rows else { return }
        rows = next
        dirty = true
    }

    func flushIfNeeded() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
