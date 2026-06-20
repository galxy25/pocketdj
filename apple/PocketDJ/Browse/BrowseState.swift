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

    /// Active `source` filter values (any-of), for pushing into the online query as
    /// a keyword term/terms filter. Empty when no complete source clause is set.
    /// `is`/`is not` carry a single value; `any of` carries a set (we ignore `neq`
    /// online since OpenSearch can't express it via a single positive term filter).
    var activeSourceValues: [String] {
        clauses.filter { $0.field == "source" && !$0.isIncomplete }.flatMap { c -> [String] in
            switch c.op {
            case .eq: return [c.value]
            case .inList: return Array(c.values)
            default: return []   // neq has no positive online term equivalent
            }
        }.filter { !$0.isEmpty }
    }

    /// All rows for the current kind (unfiltered), with album names attached to songs.
    func baseItems(_ app: AppModel) -> [BrowseItem] {
        switch kind {
        case .album:
            return app.albums.map { .album($0, source: app.source(ofAlbum: $0.id)) }
        case .song:
            return app.songs.map { .song($0, albumName: app.albumName(forSong: $0),
                                         source: app.source(ofSong: $0.id)) }
        }
    }

    /// Query → filter clauses → multi-key sort. The pipeline the PWA browser uses.
    func results(_ app: AppModel) -> [BrowseItem] {
        var base = baseItems(app)
        if !query.isEmpty { base = base.filter { textMatch($0, query) } }
        return SortEngine.apply(FilterEngine.apply(base, clauses), sortKeys)
    }

    private func textMatch(_ item: BrowseItem, _ q: String) -> Bool {
        switch item {
        case .album(let a, _):
            return a.name.localizedCaseInsensitiveContains(q)
                || a.artist.localizedCaseInsensitiveContains(q)
                || (a.genre ?? "").localizedCaseInsensitiveContains(q)
        case .song(let s, let albumName, _):
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
