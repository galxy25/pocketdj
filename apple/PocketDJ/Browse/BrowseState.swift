import SwiftUI
import Observation

/// View-state for the Browser: item kind, text query, filter clauses, sort keys,
/// and layout. Pure of the data layer — it takes an `AppModel` to read from, so
/// every derivation here is unit-testable against a fixture catalog.
@MainActor
@Observable
final class BrowseState {
    enum Layout: String, Codable { case grid, list }

    var kind: ItemKind = .album
    var query: String = ""           // transient (not persisted)
    var clauses: [Clause] = []
    var sortKeys: [SortKey] = []
    var layout: Layout = .grid
    /// Search mode: false = on-device (local filter), true = online (OpenSearch).
    var searchOnline: Bool = false

    // MARK: Collection-membership filter (song mode only) — mirrors the PWA's
    // BrowserView SHOW/HIDE filters (src/components/browser/BrowserView.tsx). Held as
    // TRANSIENT state (not persisted in the Snapshot), exactly like the PWA keeps it in
    // component useState. Each Set mixes playlist (pls_) AND pocket (pkt_) ids together.
    //   include* → SHOW: keep ONLY songs in ANY selected collection ("in playlist/pocket").
    //   exclude* → HIDE: drop songs in ANY selected collection ("not in playlist/pocket").
    // The *Any flags expand to "every playlist + pocket" (PWA's allIds()).
    var includeAny = false
    var includeIds: Set<String> = []
    var excludeAny = false
    var excludeIds: Set<String> = []

    /// True when any membership constraint is active (drives the song-mode gating).
    var membershipActive: Bool {
        includeAny || !includeIds.isEmpty || excludeAny || !excludeIds.isEmpty
    }

    private let defaults: UserDefaults
    private static let key = "pdj.browse.v1"

    /// Restores the last-used item kind, filters, sort, layout, and search mode so
    /// the user doesn't have to re-set them every launch (cleared only via "Clear All").
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            kind = s.kind; clauses = s.clauses; sortKeys = s.sortKeys
            layout = s.layout; searchOnline = s.searchOnline ?? false
        }
    }

    private struct Snapshot: Codable {
        var kind: ItemKind, clauses: [Clause], sortKeys: [SortKey], layout: Layout
        var searchOnline: Bool?      // optional for back-compat with older snapshots
    }

    func persist() {
        let snap = Snapshot(kind: kind, clauses: clauses, sortKeys: sortKeys,
                            layout: layout, searchOnline: searchOnline)
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: Self.key) }
    }

    var activeFilterCount: Int { clauses.filter { !$0.isIncomplete }.count }

    /// All rows for the current kind (unfiltered), with album names attached to songs.
    func baseItems(_ app: AppModel) -> [BrowseItem] {
        switch kind {
        case .album:
            return app.albums.map { .album($0, source: app.source(ofAlbum: $0.id)) }
        case .song:
            return app.songs.map { song in
                // Resolve the song's top-tier genre category from its owning album, so
                // the genre filter/sort reads it like the PWA reads SongItem.genre.
                let albumGenre = song.albumId.flatMap { app.albumsById[$0]?.genre }
                return .song(song, albumName: app.albumName(forSong: song),
                             source: app.source(ofSong: song.id),
                             genre: Genre.category(albumGenre))
            }
        }
    }

    /// Query → filter clauses → multi-key sort → collection membership. The pipeline
    /// the PWA browser uses (membership applied last, song mode only).
    func results(_ app: AppModel, collections: CollectionsStore? = nil) -> [BrowseItem] {
        var base = baseItems(app)
        if !query.isEmpty { base = base.filter { textMatch($0, query) } }
        let sorted = SortEngine.apply(FilterEngine.apply(base, clauses), sortKeys)
        guard let collections else { return sorted }
        return applyMembership(sorted, collections)
    }

    /// Resolve the union of song ids placed in the selected collection ids (mixed
    /// pls_/pkt_). The native analog of the PWA's `membersOf` + `isMember`: the native
    /// `songIds(forPlaylist:/forPocket:)` resolvers already expand placed albums to their
    /// tracks, so a flat Set of song ids reproduces the PWA's id-OR-albumId membership.
    private func memberSongIds(_ ids: Set<String>, _ collections: CollectionsStore) -> Set<String> {
        var out = Set<String>()
        for id in ids {
            let resolved = id.hasPrefix("pkt_")
                ? collections.songIds(forPocket: id)
                : collections.songIds(forPlaylist: id)
            out.formUnion(resolved)
        }
        return out
    }

    /// Apply the SHOW/HIDE membership filters (song mode only). Mirrors
    /// BrowserView.tsx: SHOW keeps only members of any selected collection; HIDE drops
    /// members of any selected; both active = intersection; "any" = every collection.
    private func applyMembership(_ items: [BrowseItem], _ collections: CollectionsStore) -> [BrowseItem] {
        guard kind == .song, membershipActive else { return items }
        let allIds = Set(collections.playlists.map(\.id) + collections.pockets.map(\.id))
        let showActive = includeAny || !includeIds.isEmpty
        let hideActive = excludeAny || !excludeIds.isEmpty
        let showSet: Set<String>? = showActive
            ? memberSongIds(includeAny ? allIds : includeIds, collections) : nil
        let hideSet: Set<String>? = hideActive
            ? memberSongIds(excludeAny ? allIds : excludeIds, collections) : nil
        return items.filter { item in
            guard case .song = item else { return true }
            if let showSet, !showSet.contains(item.id) { return false }
            if let hideSet, hideSet.contains(item.id) { return false }
            return true
        }
    }

    /// Clear all membership selections (the membership "Clear" action).
    func clearMembership() {
        includeAny = false; includeIds = []; excludeAny = false; excludeIds = []
    }

    private func textMatch(_ item: BrowseItem, _ q: String) -> Bool {
        switch item {
        case .album(let a, _):
            return a.name.localizedCaseInsensitiveContains(q)
                || a.artist.localizedCaseInsensitiveContains(q)
                || (a.genre ?? "").localizedCaseInsensitiveContains(q)
        case .song(let s, let albumName, _, _):
            return s.name.localizedCaseInsensitiveContains(q)
                || s.artist.localizedCaseInsensitiveContains(q)
                || albumName.localizedCaseInsensitiveContains(q)
        }
    }

    /// Distinct values present for an options-backed field (drives `any of` pickers).
    func options(for fieldID: String, in app: AppModel) -> [String] {
        // Source options come straight from the loaded catalog's distinct sources
        // (first-seen order), independent of the current kind.
        if fieldID == "source" { return app.availableSources }
        var set = Set<String>()
        for item in baseItems(app) {
            switch Fields.value(item, fieldID) {
            case .string(let s) where !s.isEmpty: set.insert(s)
            case .strings(let arr): arr.forEach { if !$0.isEmpty { set.insert($0) } }
            default: break
            }
        }
        var arr = Array(set)
        switch fieldID {
        case "camelot": arr.sort { (Camelot.rank($0) ?? 99) < (Camelot.rank($1) ?? 99) }
        case "genre":   arr.sort { Genre.order(of: $0) < Genre.order(of: $1) }
        default:        arr.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return arr
    }
}
