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

    /// All rows for the current kind (unfiltered), with album names / source / genre
    /// already attached. Pre-built once by `AppModel.applyEdits` (see `browseItems`), so
    /// this is an O(1) array hand-off rather than a per-render map over the whole catalog.
    func baseItems(_ app: AppModel) -> [BrowseItem] { app.browseItems(kind) }

    /// A stable signature of everything `results` depends on EXCEPT membership — the
    /// browse results memo key. Built from field VALUES (never a Clause's UUID `id`), so
    /// two logically-identical filter sets share a cache entry; includes the catalog
    /// revision so an edit/reload can never serve a stale memo. Only complete clauses
    /// count (incomplete ones are no-ops in FilterEngine).
    ///
    /// JSON-ENCODED rather than delimiter-joined: a filter `value` or `query` can contain
    /// any character (a title with a comma, a `|`, etc.), so hand-rolled separators could
    /// let two DIFFERENT queries collide onto one key and serve wrong cached rows. JSON's
    /// string escaping + explicit structure makes the encoding unambiguous. `.sortedKeys`
    /// makes it DETERMINISTIC — JSONEncoder does not otherwise emit object keys in a
    /// stable order, which would give the same input a different key each call (a memo
    /// that never hits). Arrays keep their order; `values` is pre-sorted for set stability.
    func resultsKey(_ app: AppModel) -> String {
        struct ClauseSig: Encodable { let f: String; let o: String; let v: String; let vs: [String]; let mn: Double?; let mx: Double? }
        struct SortSig: Encodable { let f: String; let d: String }
        struct KeySig: Encodable { let rev: Int; let k: String; let q: String; let c: [ClauseSig]; let s: [SortSig] }
        let sig = KeySig(
            rev: app.catalogRevision, k: kind.rawValue, q: query,
            c: clauses.filter { !$0.isIncomplete }.map {
                ClauseSig(f: $0.field, o: $0.op.rawValue, v: $0.value, vs: $0.values.sorted(), mn: $0.min, mx: $0.max)
            },
            s: sortKeys.map { SortSig(f: $0.field, d: $0.dir.rawValue) })
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        // Encoding a plain Encodable of scalars/arrays cannot fail; fall back to a coarse
        // (never-cache-friendly but correct) key on the impossible error path.
        guard let data = try? enc.encode(sig) else {
            return "rev\(app.catalogRevision)-\(kind.rawValue)-\(query)-\(clauses.count)-\(sortKeys.count)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Query → filter clauses → multi-key sort → collection membership. The pipeline
    /// the PWA browser uses (membership applied last, song mode only).
    ///
    /// The EXPENSIVE part — build base rows, text-filter, clause-filter, and the multi-key
    /// SORT over the whole catalog — is ALWAYS memoized on `AppModel` (keyed by
    /// `resultsKey`, which captures every input to it). So re-entering the Browser tab and
    /// the frequent body re-evals paging causes (each scroll grows a `@State`) return the
    /// already-sorted set instantly instead of re-sorting ~90k rows.
    ///
    /// Collection membership (song mode) is layered on top as a CHEAP O(n) filter of that
    /// cached sorted array — never memoized, because its inputs (the selected collections'
    /// contents) live outside the key and can change independently, so it always reflects
    /// the current collections. Crucially it does NOT trigger a re-sort: the costly work
    /// stays behind the memo even on the membership path.
    func results(_ app: AppModel, collections: CollectionsStore? = nil) -> [BrowseItem] {
        let sorted = app.cachedBrowseResults(resultsKey(app)) { computeSorted(app) }
        if kind == .song, membershipActive, let collections {
            return applyMembership(sorted, collections)
        }
        return sorted
    }

    /// The memoized portion: base rows → text query → clause filter → multi-key sort.
    private func computeSorted(_ app: AppModel) -> [BrowseItem] {
        var base = baseItems(app)
        if !query.isEmpty { base = base.filter { textMatch($0, query) } }
        return SortEngine.apply(FilterEngine.apply(base, clauses), sortKeys)
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

    /// Remove a single filter clause by id (the per-row remove action), leaving the
    /// other AND-composed clauses intact.
    func removeClause(id: Clause.ID) {
        clauses.removeAll { $0.id == id }
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

// MARK: - On-device paging

/// Incremental rendering for the on-device browser: the full filtered+sorted result
/// set is derived once (and memoized), but only a growing PREFIX is handed to SwiftUI's
/// ForEach. Building the ForEach identity over ~90k rows is the render-side cost that
/// made switching kinds / re-entering the tab stutter; rendering ~a page at a time and
/// growing as the last visible row appears keeps every interaction snappy. This mirrors
/// the online pager (OnlineSearchModel), which is server-paged. Pure so it's unit-tested.
enum BrowsePaging {
    /// Rows in one page. Big enough to fill any screen on the first render (so the grow
    /// trigger doesn't fire repeatedly to catch up), small enough that the ForEach diff
    /// stays cheap regardless of catalog size. Testing seam: `PDJ_PAGE_SIZE=<n>` shrinks
    /// it so a UI test can exercise the grow trigger against the 7-song fixture catalog
    /// (page 1 then fits on one screen and a working trigger chain-grows to the full set).
    static let pageSize: Int = {
        if let raw = ProcessInfo.processInfo.environment["PDJ_PAGE_SIZE"],
           let n = Int(raw), n > 0 { return n }
        return 120
    }()

    /// The visible prefix for the current `visible` budget (the whole set once it fits).
    static func page(_ items: [BrowseItem], visible: Int) -> [BrowseItem] {
        items.count > visible ? Array(items.prefix(visible)) : items
    }

    /// Next budget after the last visible row appears, clamped to the total. Returns the
    /// unchanged budget once everything is shown (so the trailing row's onAppear no-ops).
    static func grow(_ visible: Int, upTo total: Int, by step: Int = pageSize) -> Int {
        min(total, max(visible, visible + step))
    }

    /// Budget needed to reveal a keyboard-focused row at `index` (0-based) in a set of
    /// `total` rows, given the current budget. Grows to include the row ONLY when it sits
    /// within one page of the loaded edge (incremental stepping); a FAR jump — e.g. ↑ from
    /// nothing seeding focus to the last of ~90k rows — returns the budget UNCHANGED, so
    /// focus can move without materializing the whole catalog. Never shrinks.
    static func focusReveal(_ visible: Int, toIndex index: Int, total: Int, step: Int = pageSize) -> Int {
        let need = index + 1
        guard need > visible, need <= visible + step else { return visible }
        return min(total, need)
    }
}
