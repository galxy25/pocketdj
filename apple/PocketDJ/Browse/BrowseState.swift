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

    /// The on-device results the BrowseView renders (filtered + sorted, WITHOUT membership).
    /// Published by `refreshResults`, which does the heavy filter+sort OFF the main actor — the
    /// view reads THIS instead of computing inline, so a large-catalog search/sort never blocks the
    /// main thread (the multi-second `localizedCaseInsensitiveContains` runloop hang). Membership
    /// (song mode) is layered on cheaply at read time in `visibleResults`.
    private(set) var displayItems: [BrowseItem] = []
    /// The `resultsKey` the current `displayItems` were computed for — lets `refreshResults` skip
    /// redundant recomputes and drop a cancelled/stale run's output.
    @ObservationIgnored private var displayKey: String?

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
    /// UserDefaults key for THIS instance's persisted snapshot. Parameterized so History mode
    /// keeps its own filters/sort ("pdj.history.v1") without clobbering the Browser's.
    private let persistenceKey: String

    /// HISTORY mode: song-only, includes the `lastPlayedAt` field in the sheets, filters/sorts
    /// an externally-supplied base (`externalBase`) instead of the catalog, and drops the
    /// collection-membership filter (History rows are per-event, not per-song).
    let historyMode: Bool

    /// History supplies the base rows (built from the play-event log) + parallel search keys
    /// here; when set, `refreshExternal` filter/sorts THESE instead of the catalog and bypasses
    /// the AppModel results memo (history bases change without a catalogRevision bump).
    @ObservationIgnored var externalBase: (() -> (base: [BrowseItem], keys: [String]))?
    /// Memo of the last-built external base, keyed by the caller's `baseKey`. The base (per-event
    /// rows resolved from the catalog) is O(events) to build, so it is reused across query /
    /// filter / sort edits and rebuilt only when `baseKey` changes (a new play, mode toggle, or
    /// catalog load) — mirroring how the catalog Browser hands off a precomputed base.
    @ObservationIgnored private var externalBaseCache: (key: String, base: [BrowseItem], keys: [String])?

    /// Restores the last-used item kind, filters, sort, layout, and search mode so
    /// the user doesn't have to re-set them every launch (cleared only via "Clear All").
    init(defaults: UserDefaults = .standard, persistenceKey: String = "pdj.browse.v1",
         historyMode: Bool = false) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.historyMode = historyMode
        if let data = defaults.data(forKey: persistenceKey),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            kind = s.kind; clauses = s.clauses; sortKeys = s.sortKeys
            layout = s.layout; searchOnline = s.searchOnline ?? false
        }
        if historyMode { kind = .song }   // History is inherently song-mode.
    }

    private struct Snapshot: Codable {
        var kind: ItemKind, clauses: [Clause], sortKeys: [SortKey], layout: Layout
        var searchOnline: Bool?      // optional for back-compat with older snapshots
    }

    func persist() {
        let snap = Snapshot(kind: kind, clauses: clauses, sortKeys: sortKeys,
                            layout: layout, searchOnline: searchOnline)
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: persistenceKey) }
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
    /// Synchronous derivation (base rows → text query → clause filter → multi-key sort → membership).
    /// Kept for tests + any caller that needs the result inline; the BrowseView instead renders the
    /// OFF-main `displayItems` via `visibleResults` (see `refreshResults`) so the heavy work never
    /// runs on the main actor.
    func results(_ app: AppModel, collections: CollectionsStore? = nil) -> [BrowseItem] {
        let sorted = app.cachedBrowseResults(resultsKey(app)) { computeSorted(app) }
        if kind == .song, membershipActive, let collections {
            return applyMembership(sorted, collections)
        }
        return sorted
    }

    /// The rows the BrowseView renders: the OFF-main-computed `displayItems` with the cheap
    /// collection-membership filter (song mode) layered on at read time so it always reflects the
    /// live collections. Never does the heavy filter/sort — that lands in `displayItems`.
    func visibleResults(_ collections: CollectionsStore? = nil) -> [BrowseItem] {
        if kind == .song, membershipActive, let collections {
            return applyMembership(displayItems, collections)
        }
        return displayItems
    }

    /// The `.task(id:)` signature the BrowseView keys its off-main recompute on: changes whenever any
    /// input to the filtered+sorted set changes (kind, query, filters, sort, catalog revision).
    /// Membership is deliberately excluded — it's applied cheaply at read time, not recomputed here.
    func recomputeSignature(_ app: AppModel) -> String { resultsKey(app) }

    /// Recompute the on-device results OFF the main actor and publish to `displayItems`. Driven by
    /// the BrowseView's `.task(id: recomputeSignature)`, so a changed input auto-cancels the in-flight
    /// run (debounce). A memo hit publishes instantly; a miss with an active text query waits out a
    /// short debounce, then filters + sorts on a detached task before assigning back on the main
    /// actor. Membership is NOT applied here (it's layered in `visibleResults`).
    func refreshResults(_ app: AppModel) async {
        let key = resultsKey(app)
        if displayKey == key { return }                       // already current
        if let cached = app.peekBrowseResults(key) {          // memo hit → instant
            displayItems = cached
            displayKey = key
            return
        }
        // Debounce ONLY an active text query (rapid typing); base/filter/sort changes apply at once.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
        }
        // Snapshot the inputs on the main actor, then filter+sort on a detached (off-main) task.
        let base = app.browseItems(kind)
        let keys = app.searchKeys(kind)
        let (q, cl, sk) = (query, clauses, sortKeys)
        let sorted = await Task.detached(priority: .userInitiated) {
            BrowseState.filterSort(base: base, searchKeys: keys, query: q, clauses: cl, sortKeys: sk)
        }.value
        if Task.isCancelled { return }
        app.storeBrowseResults(key, sorted)
        displayItems = sorted
        displayKey = key
    }

    /// HISTORY recompute: filter+sort the externally-supplied base (the play-event rows) OFF the
    /// main actor and publish to `displayItems`. Mirrors `refreshResults` but sources its base
    /// from `externalBase` and BYPASSES the AppModel catalog memo (history bases change with each
    /// play, not with the catalog revision). Driven by the HistoryView's `.task(id:)` on a
    /// signature that captures the event log + toggle + query/filters/sort.
    func refreshExternal(signature: String, baseKey: String) async {
        if displayKey == signature { return }
        // Debounce an active text query FIRST so a burst of keystrokes coalesces BEFORE any
        // expensive work (the base build below is O(events); doing it per-keystroke was the
        // main-thread jank the Browser path was refactored to avoid).
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
        }
        // Reuse the built base across query/filter/sort edits; rebuild only when `baseKey` changed.
        let base: [BrowseItem]; let keys: [String]
        if let c = externalBaseCache, c.key == baseKey {
            base = c.base; keys = c.keys
        } else {
            (base, keys) = externalBase?() ?? ([], [])
            externalBaseCache = (baseKey, base, keys)
        }
        let (q, cl, sk) = (query, clauses, sortKeys)
        let sorted = await Task.detached(priority: .userInitiated) {
            BrowseState.filterSort(base: base, searchKeys: keys, query: q, clauses: cl, sortKeys: sk)
        }.value
        if Task.isCancelled { return }
        displayItems = sorted
        displayKey = signature
    }

    /// A stable signature of the filter/sort inputs (query + complete clauses + sort keys),
    /// WITHOUT the catalog revision — History composes this with its own event-log revision to
    /// drive the `.task(id:)` recompute. Same JSON-encoding rationale as `resultsKey`.
    func filterSortSignature() -> String {
        struct ClauseSig: Encodable { let f: String; let o: String; let v: String; let vs: [String]; let mn: Double?; let mx: Double? }
        struct SortSig: Encodable { let f: String; let d: String }
        struct Sig: Encodable { let q: String; let c: [ClauseSig]; let s: [SortSig] }
        let sig = Sig(
            q: query,
            c: clauses.filter { !$0.isIncomplete }.map {
                ClauseSig(f: $0.field, o: $0.op.rawValue, v: $0.value, vs: $0.values.sorted(), mn: $0.min, mx: $0.max)
            },
            s: sortKeys.map { SortSig(f: $0.field, d: $0.dir.rawValue) })
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(sig) else { return "\(query)-\(clauses.count)-\(sortKeys.count)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The memoized portion: base rows → text query → clause filter → multi-key sort.
    private func computeSorted(_ app: AppModel) -> [BrowseItem] {
        Self.filterSort(base: app.browseItems(kind), searchKeys: app.searchKeys(kind),
                        query: query, clauses: clauses, sortKeys: sortKeys)
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

    /// The pure filter+sort core, `nonisolated` so it runs on a background executor (called from
    /// `refreshResults`'s detached task). The text query is matched with a cheap `contains` over the
    /// pre-folded (case/diacritic-insensitive) `searchKeys` (parallel to `base`, same order/count)
    /// instead of ~90k × 3 per-field `localizedCaseInsensitiveContains` calls — the runloop-hang source.
    nonisolated static func filterSort(base: [BrowseItem], searchKeys: [String],
                                       query: String, clauses: [Clause], sortKeys: [SortKey]) -> [BrowseItem] {
        var items = base
        // Fold the query the SAME way the searchKeys were folded (case- + diacritic-insensitive,
        // locale-independent), and strip newlines: the searchKeys join fields with "\n", so a query
        // containing one could match ACROSS the field boundary (a lone "\n" would match the whole
        // catalog) — the old per-field OR never did. A real query has no newline; the strip keeps
        // "abba\n" matching "abba".
        let q = query.replacingOccurrences(of: "\n", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if !q.isEmpty, base.count == searchKeys.count {
            items = zip(base, searchKeys).compactMap { $0.1.contains(q) ? $0.0 : nil }
        }
        return SortEngine.apply(FilterEngine.apply(items, clauses), sortKeys)
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
