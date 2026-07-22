import SwiftUI

/// History mode — a scrollable timeline of what you've done: every song you've played (in whichever
/// Mix / Playlist / Pocket / Set list / Browser it happened in) AND every collection change (adding
/// a song, hearting/unhearting, removing), with the Browser's filter + sort controls on the plays.
/// Opened from anywhere with ⌘H.
///
/// Three views over two event streams:
///  • **Playback** — song PLAYS from the append-only `PlayHistoryStore`, driven through the Browser's
///    own filter/sort/paged machinery (see `BrowseState.refreshExternal`, which runs off the main actor).
///  • **Collection** — collection ACTIVITY (add / heart / unheart / remove) from `CollectionActivityStore`.
///  • **Unified** (default) — both streams interleaved newest-first.
///
/// The tab control shows the TWO views you're NOT currently in — tap one to switch. So from Unified you
/// see [Playback | Collection]; from either single view you see [the other | Unified] to cross over or
/// return to the combined timeline.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayHistoryStore.self) private var history
    @Environment(CollectionActivityStore.self) private var activity
    @Environment(CollectionsStore.self) private var collections
    @Binding var path: NavigationPath

    enum HistoryTab: String, CaseIterable {
        case unified = "Unified", playback = "Playback", collection = "Collection"
        var symbol: String {
            switch self {
            case .unified:    return "square.stack.3d.up.fill"
            case .playback:   return "play.circle.fill"
            case .collection: return "rectangle.stack.fill"
            }
        }
    }
    @State private var tab: HistoryTab = .unified

    /// History's own filter/sort state — distinct persistence key so it never clobbers the
    /// Browser's, defaulting to most-recently-played first.
    @State private var browse: BrowseState = {
        let b = BrowseState(persistenceKey: "pdj.history.v1", historyMode: true)
        if b.sortKeys.isEmpty { b.sortKeys = [SortKey(field: "lastPlayedAt", dir: .desc)] }
        return b
    }()
    @State private var groupBySong = false
    @State private var showFilter = false
    @State private var showSort = false
    /// On-device incremental rendering budget — History can grow to tens of thousands of
    /// events, so (exactly like the Browser) only a growing PREFIX of the filtered+sorted rows
    /// is handed to ForEach; it grows as the last visible row appears. Paired with the
    /// `recomputeSignature` it was grown against so a filter/sort/mode change restarts paging.
    @State private var visibleCount = BrowsePaging.pageSize
    @State private var visibleKey = ""

    /// The merged Unified timeline (newest-first), rebuilt off `unifiedSignature`. Kept in state
    /// (not a computed property) so the O(n) merge+sort runs only when its inputs change, and only
    /// while the Unified tab is showing.
    @State private var unified: [HistoryEntry] = []
    @State private var uVisibleCount = BrowsePaging.pageSize
    @State private var uVisibleKey = ""

    /// Recompute signature: the CATALOG revision (rows resolve title/album/artwork from the live
    /// catalog, so a load/edit while History is on screen must re-fire), the event-log revision,
    /// the mode toggle, and the filter/sort inputs. Any change re-runs `refreshExternal`
    /// (auto-cancelling the prior run) AND restarts paging.
    private var recomputeSignature: String {
        "\(app.catalogRevision)-\(history.revision)-\(groupBySong)-\(browse.filterSortSignature())"
    }

    /// Identifies the BASE rows (catalog + event log + mode) independent of the filter/sort/query,
    /// so `refreshExternal` rebuilds the expensive per-event base only when it actually changes and
    /// reuses it across query/filter/sort edits.
    private var baseKey: String { "\(app.catalogRevision)-\(history.revision)-\(groupBySong)" }

    /// Paging key = what makes the RESULT SET different (mode, filters/sort, event log, and the
    /// row count). Deliberately EXCLUDES app.catalogRevision: a catalog load bumps the recompute
    /// signature (rows re-resolve metadata) but must NOT strand a scrolled-in budget back at page
    /// one every time the catalog churns. The count catches a catalog load that changes which rows
    /// pass a catalog-derived filter.
    private var pagingKey: String {
        "\(history.revision)-\(groupBySong)-\(browse.filterSortSignature())-\(browse.displayItems.count)"
    }

    /// The render budget for the CURRENT result set: the grown `visibleCount` only while it still
    /// refers to the current paging key; otherwise one page. Derived (not reset in an onChange) so
    /// a filter/sort/mode switch never renders the previous set's large prefix.
    private var liveVisible: Int { visibleKey == pagingKey ? visibleCount : BrowsePaging.pageSize }

    /// Unified rebuilds when the catalog, either event stream, the search query, or the tab changes
    /// (the tab is included so switching TO Unified triggers a build; the build no-ops for other tabs).
    private var unifiedSignature: String {
        "\(tab)-\(app.catalogRevision)-\(history.revision)-\(activity.revision)-\(browse.query)"
    }
    private var unifiedPagingKey: String { "\(history.revision)-\(activity.revision)-\(browse.query)-\(unified.count)" }
    private var liveUnifiedVisible: Int { uVisibleKey == unifiedPagingKey ? uVisibleCount : BrowsePaging.pageSize }

    var body: some View {
        content
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $browse.query, prompt: "Search title or artist")
            .toolbar { toolbar }
            .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app, collections: collections) }
            .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
            .background { shortcuts }
            .onChange(of: browse.query) { browse.persist() }
            .onChange(of: browse.clauses) { browse.persist() }
            .onChange(of: browse.sortKeys) { browse.persist() }
            .task(id: recomputeSignature) {
                browse.externalBase = buildItems
                await browse.refreshExternal(signature: recomputeSignature, baseKey: baseKey)
            }
            .task(id: unifiedSignature) {
                guard tab == .unified else { return }
                unified = buildUnified()
            }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            tabBar
            switch tab {
            case .unified:
                unifiedContent
            case .playback:
                // The Timeline/By-song mode picker is GONE (Levi 2026-07-18: the two reads
                // were indistinguishable in practice) — Playback is always the timeline. The
                // groupBySong plumbing stays (false forever) so the grouped engine remains
                // one flag away if a future view wants it.
                if browse.displayItems.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            case .collection:
                activityContent
            }
        }
    }

    // MARK: - Tab control (two destinations = the views you're NOT in)

    private var altTabs: [HistoryTab] {
        switch tab {
        case .unified:    return [.playback, .collection]
        case .playback:   return [.collection, .unified]
        case .collection: return [.playback, .unified]
        }
    }

    /// Custom two-button control (not a segmented `Picker`) so it renders prominently and identically
    /// on iOS, macOS, and visionOS. Each button is a destination; tapping switches the view and the
    /// pair re-renders to the two views you can now reach.
    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(altTabs, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold))
                        Text(t.rawValue).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fg)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
                )
                .accessibilityIdentifier("history-tab-\(t.rawValue.lowercased())")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        // NB: no container accessibilityIdentifier here — a parent id absorbs the child buttons'
        // identifiers and makes `history-tab-<mode>` unqueryable in XCUITest.
    }

    // MARK: - Unified timeline (plays + activity interleaved)

    @ViewBuilder private var unifiedContent: some View {
        if unified.isEmpty {
            unifiedEmptyState
        } else {
            let page = Array(unified.prefix(liveUnifiedVisible))
            List {
                ForEach(page) { entry in
                    unifiedRow(entry)
                        .onAppear { onUnifiedRowAppear(entry, rendered: page) }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func unifiedRow(_ entry: HistoryEntry) -> some View {
        switch entry {
        case .play(_, let song, let play):
            row(song: song, play: play)
                .contentShape(Rectangle())
                .onTapGesture { path.append(song) }
        case .activity(let e):
            activityRow(e)
                .contentShape(Rectangle())
                .onTapGesture { if let song = app.songsById[e.itemId] { path.append(song) } }
        }
    }

    /// Merge plays + activity into one newest-first timeline, filtered by the search query
    /// (title/artist for plays; item title + collection name for activity). Runs on the main actor
    /// (reads the catalog); paged on render, so only a prefix is ever materialized into rows.
    private func buildUnified() -> [HistoryEntry] {
        let q = browse.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var entries: [HistoryEntry] = []
        entries.reserveCapacity(history.events.count + activity.events.count)
        for e in history.events {
            let (item, key) = makeRow(e, count: 1)
            guard case .song(let song, _, _, _, let play) = item, let play else { continue }
            if q.isEmpty || key.contains(q) {
                entries.append(.play(eventId: e.id, song: song, play: play))
            }
        }
        for ev in activity.events where q.isEmpty || activitySearchKey(ev).contains(q) {
            entries.append(.activity(ev))
        }
        entries.sort { $0.at > $1.at }
        return entries
    }

    private func onUnifiedRowAppear(_ entry: HistoryEntry, rendered: [HistoryEntry]) {
        guard entry.id == rendered.last?.id, liveUnifiedVisible < unified.count else { return }
        uVisibleCount = BrowsePaging.grow(liveUnifiedVisible, upTo: unified.count)
        uVisibleKey = unifiedPagingKey
    }

    private var unifiedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text(history.events.isEmpty && activity.events.isEmpty ? "No history yet" : "Nothing matches your search")
                .font(.headline).foregroundStyle(Theme.fg)
            Text("Songs you play — and changes you make to your collections (adds, hearts, removals) — show up here together.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("history-unified-empty")
    }

    // MARK: - Collection activity timeline (F11)

    /// Activity events, NEWEST FIRST (the log is append-only oldest→newest), filtered by the search
    /// query. Its own simple list — distinct rows per kind, an SF Symbol + relative time, tap → the
    /// item where the id resolves to a catalog song.
    @ViewBuilder private var activityContent: some View {
        let q = browse.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let events = q.isEmpty
            ? Array(activity.events.reversed())
            : activity.events.reversed().filter { activitySearchKey($0).contains(q) }
        if events.isEmpty {
            activityEmptyState
        } else {
            List {
                ForEach(events) { event in
                    activityRow(event)
                        .contentShape(Rectangle())
                        .onTapGesture { if let song = app.songsById[event.itemId] { path.append(song) } }
                }
            }
            .listStyle(.plain)
        }
    }

    private func activityRow(_ e: CollectionActivityStore.ActivityEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(e.kind == .heart ? Theme.accent : Theme.accent2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(activityHeadline(e)).font(.callout).foregroundStyle(Theme.fg).lineLimit(2)
                Text(Self.relative(e.at)).font(.caption2).foregroundStyle(Theme.fgDim)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("activity-row")
    }

    /// "Added <item> to <collection>" / "Hearted <item>" / "Removed heart from <item>" /
    /// "Removed <item> from <collection>", from the event's snapshots (falls back to the id).
    private func activityHeadline(_ e: CollectionActivityStore.ActivityEvent) -> String {
        let item = displayTitle(e)
        let coll = e.collectionName ?? "a collection"
        switch e.kind {
        case .add:     return "Added \(item) to \(coll)"
        case .heart:   return "Hearted \(item)"
        case .unheart: return "Removed heart from \(item)"
        case .remove:  return "Removed \(item) from \(coll)"
        }
    }

    private func activitySearchKey(_ e: CollectionActivityStore.ActivityEvent) -> String {
        (displayTitle(e) + "\n" + (e.collectionName ?? ""))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Prefer the LIVE catalog title (fresh renames), fall back to the event's snapshot, then the id.
    private func displayTitle(_ e: CollectionActivityStore.ActivityEvent) -> String {
        if let s = app.songsById[e.itemId] { return "“\(s.name)”" }
        if let a = app.albumsById[e.itemId] { return "“\(a.name)”" }
        if let t = e.itemTitle, !t.isEmpty { return "“\(t)”" }
        return e.itemId
    }

    private var activityEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text("No collection activity yet").font(.headline).foregroundStyle(Theme.fg)
            Text("Adding a song to a playlist or pocket, hearting a song, or removing one shows up here.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("activity-empty")
    }

    // MARK: - Playback (plays) timeline

    /// The paged list: renders only the current `liveVisible` prefix of the full result set and
    /// grows the budget as the last rendered row scrolls into view.
    private var historyList: some View {
        let items = browse.displayItems
        let page = BrowsePaging.page(items, visible: liveVisible)
        return List {
            ForEach(page) { item in
                if case .song(let song, _, _, _, let play) = item, let play {
                    row(song: song, play: play)
                        .contentShape(Rectangle())
                        .onTapGesture { path.append(song) }
                        .onAppear { onRowAppear(item, rendered: page, fullCount: items.count) }
                }
            }
        }
        .listStyle(.plain)
    }

    /// The last RENDERED row scrolled into view → grow the render budget toward the full result
    /// count (no-op once everything is shown). Mirrors BrowseView.onRowAppear.
    private func onRowAppear(_ item: BrowseItem, rendered: [BrowseItem], fullCount: Int) {
        guard item.id == rendered.last?.id, liveVisible < fullCount else { return }
        visibleCount = BrowsePaging.grow(liveVisible, upTo: fullCount)
        visibleKey = pagingKey
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text(history.events.isEmpty ? "No plays yet" : "No plays match your filters")
                .font(.headline).foregroundStyle(Theme.fg)
            Text(history.events.isEmpty
                 ? "Songs you play in a Mix, Playlist, Pocket, Set list, or the Browser show up here."
                 : "Adjust the filters or date range to see more.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("history-empty")
    }

    /// One history row: the shared song row, with a context line ("Mix · Friday Mix · 2h ago")
    /// beneath it so you see WHERE and WHEN you played it.
    private func row(song: IndexSong, play: PlayRef) -> some View {
        let album = song.albumId.flatMap { app.albumsById[$0] }
        return VStack(alignment: .leading, spacing: 3) {
            SongRowView(data: SongRowData(song: song, album: album))
            HStack(spacing: 5) {
                Image(systemName: play.source.symbol).font(.system(size: 9))
                Text(contextLabel(play)).lineLimit(1)
                Text("·")
                Text(Self.relative(play.playedAt))
                Spacer()
                if play.count > 1 {
                    Text("\(play.count) plays")
                        .accessibilityIdentifier("history-count-\(song.id)")
                }
            }
            .font(.caption2).foregroundStyle(Theme.fgDim)
            .padding(.leading, 52)   // align under the row's text, past the thumbnail
        }
        .padding(.vertical, 2)
    }

    private func contextLabel(_ play: PlayRef) -> String {
        if let name = play.contextName, !name.isEmpty { return "\(play.source.label) · \(name)" }
        return play.source.label
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Sort/filter drive the Playback timeline only — hidden on Unified and Collection.
            if tab == .playback {
                Button { showSort = true } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityIdentifier("history-sort")
                Button { showFilter = true } label: {
                    Image(systemName: browse.activeFilterCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("history-filter")
            }
        }
    }

    /// Hidden shortcut buttons (mirrors BrowseView): ⌥⌘F filter, ⌥⌘S sort within History.
    private var shortcuts: some View {
        Group {
            Button("HistoryFilter-shadow") { showFilter = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("HistorySort-shadow") { showSort = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        .frame(width: 1, height: 1).opacity(0.01)
    }

    // MARK: - Base rows from the event log

    /// Build the `[BrowseItem]` + parallel search keys the filter/sort engine works over.
    /// Timeline: one row per event. Group-by-song: one row per song (latest event as the
    /// representative, with a play count). Called on the main actor (reads the catalog), then
    /// the pure filter/sort runs off-main.
    private func buildItems() -> (base: [BrowseItem], keys: [String]) {
        var items: [BrowseItem] = []
        var keys: [String] = []
        if groupBySong {
            var latest: [String: PlayHistoryStore.PlayEvent] = [:]
            var counts: [String: Int] = [:]
            var order: [String] = []
            for e in history.events {
                counts[e.songId, default: 0] += 1
                if let cur = latest[e.songId] {
                    if e.playedAt >= cur.playedAt { latest[e.songId] = e }
                } else {
                    latest[e.songId] = e
                    order.append(e.songId)
                }
            }
            for sid in order {
                guard let e = latest[sid] else { continue }
                let (item, key) = makeRow(e, count: counts[sid] ?? 1)
                items.append(item); keys.append(key)
            }
        } else {
            items.reserveCapacity(history.events.count)
            keys.reserveCapacity(history.events.count)
            for e in history.events {
                let (item, key) = makeRow(e, count: 1)
                items.append(item); keys.append(key)
            }
        }
        return (items, keys)
    }

    private func makeRow(_ e: PlayHistoryStore.PlayEvent, count: Int) -> (BrowseItem, String) {
        // Resolve the live catalog song; fall back to the event's snapshot when the song has
        // left the catalog, so history stays readable.
        let song = app.songsById[e.songId]
            ?? IndexSong.minimal(id: e.songId, name: e.title ?? "Unknown", artist: e.artist ?? "")
        let album = app.album(forSongId: e.songId)
        let albumName = album?.name ?? ""
        let play = PlayRef(eventId: e.id, playedAt: e.playedAt, source: e.source,
                           contextName: e.contextName, count: count)
        let item = BrowseItem.song(song, albumName: albumName, source: app.source(ofSong: e.songId),
                                   genre: Genre.category(album?.genre), play: play)
        let key = (song.name + "\n" + song.artist + "\n" + albumName)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return (item, key)
    }

    // MARK: - Relative time

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ epochMs: Double) -> String {
        relativeFormatter.localizedString(for: Date(timeIntervalSince1970: epochMs / 1000), relativeTo: Date())
    }
}

/// A single row in the unified History timeline: either a song play (reusing the play row) or a
/// collection-activity event, each carrying its own timestamp for the merge sort.
private enum HistoryEntry: Identifiable {
    case play(eventId: UUID, song: IndexSong, play: PlayRef)
    case activity(CollectionActivityStore.ActivityEvent)

    var id: String {
        switch self {
        case .play(let eid, _, _): return "p:\(eid.uuidString)"
        case .activity(let e):     return "a:\(e.id.uuidString)"
        }
    }
    var at: Double {
        switch self {
        case .play(_, _, let p): return p.playedAt
        case .activity(let e):   return e.at
        }
    }
}
