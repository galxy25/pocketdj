import SwiftUI

/// History mode — a scrollable timeline of every song you've played, in whichever Mix /
/// Playlist / Pocket / Set list / Browser it happened in, with the SAME filter + sort controls
/// as the Browser PLUS a "Last played" sort (most/least recently) and a date-range filter
/// ("played between May and August 2026"). Opened from anywhere with ⌘H.
///
/// It reuses the Browser's filter/sort machinery by driving its own `BrowseState` in
/// `historyMode`: the base rows come from the append-only `PlayHistoryStore` (one row per play
/// event in Timeline mode; one row per song in Group-by-song mode) instead of the catalog, and
/// the heavy filter/sort still runs OFF the main actor (see `BrowseState.refreshExternal`).
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayHistoryStore.self) private var history
    @Environment(CollectionsStore.self) private var collections
    @Binding var path: NavigationPath

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
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            // The Timeline/By-song mode picker is GONE (Levi 2026-07-18: the two reads
            // were indistinguishable in practice) — History is always the timeline. The
            // groupBySong plumbing stays (false forever) so the grouped engine remains
            // one flag away if a future view wants it.
            if browse.displayItems.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
    }

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
