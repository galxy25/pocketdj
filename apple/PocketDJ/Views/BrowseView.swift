import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The filterable browser — albums (grid/list) or songs (table), with search,
/// a multi-clause filter, and multi-key sort. Mirrors the PWA browser pipeline.
struct BrowseView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(BurnStore.self) private var burns
    @Environment(CollectionsStore.self) private var collections
    @Environment(IntentServices.self) private var intents
    /// Shared navigation path (owned by RootView) — lets keyboard "open" push an
    /// album/song detail programmatically, alongside the row-tap NavigationLinks.
    @Binding var path: NavigationPath
    @State private var browse = BrowseState(defaults: SettingsStore.launchDefaults())
    @State private var online = OnlineSearchModel()
    @State private var showFilter = false
    @State private var showSort = false
    @FocusState private var searchFocused: Bool
    /// Keyboard-navigation cursor over the visible results: the focused row's id —
    /// a SONG id in song mode, an ALBUM id in album mode. ↑/↓ move it; ⌘P plays the
    /// focused song; Return/⌘O opens the focused item. Nil until the first arrow press.
    @State private var focusedRowId: String?
    /// On-device incremental rendering budget: how many of the (memoized) full result rows
    /// are handed to ForEach. Grows as the last visible row appears. Paired with the
    /// `pagingKey` it was grown against (`visibleKey`) so a result-set change collapses it
    /// back to one page SYNCHRONOUSLY in the same render (see `liveVisible`) — never a
    /// stale large prefix rendered for a frame on a kind/filter switch. The online path is
    /// server-paged (OnlineSearchModel) and ignores this.
    @State private var visibleCount = BrowsePaging.pageSize
    @State private var visibleKey = ""

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)] }

    /// Signature of everything the on-device result set depends on: the results memo key
    /// plus the song-mode membership selections (which live outside that key). Recomputed
    /// per body eval; cheap. A change means a DIFFERENT set, so paging restarts at the top.
    private var pagingKey: String {
        browse.resultsKey(app)
            + "|m:\(browse.includeAny),\(browse.includeIds.sorted().joined(separator: "+"))"
            + ",\(browse.excludeAny),\(browse.excludeIds.sorted().joined(separator: "+"))"
    }

    /// The render budget for the CURRENT result set: the grown `visibleCount` only while it
    /// still refers to the current `pagingKey`; otherwise one page. Deriving it (rather than
    /// resetting `visibleCount` in an after-the-fact onChange) guarantees a kind/filter
    /// switch never renders the previous set's large prefix, even for one frame.
    private var liveVisible: Int { visibleKey == pagingKey ? visibleCount : BrowsePaging.pageSize }

    var body: some View {
        @Bindable var browse = browse
        return VStack(spacing: 0) {
            Picker("Show", selection: $browse.kind) {
                Text("Albums").tag(ItemKind.album)
                Text("Songs").tag(ItemKind.song)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("kind-picker")

            // "?♪?" listen-and-identify button — sits at the TOP of the browser
            // list, wired to the ShazamKit recognizer. Additive: a no-op-with-message
            // when the ShazamKit entitlement / framework is absent.
            HStack {
                Spacer()
                ShazamButton()
                    .accessibilityIdentifier("shazam-button")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            content
        }
        .background { kindShortcuts }
        .navigationTitle("Browser")
        .background(Theme.bg)
        .searchable(text: $browse.query, prompt: "Search artist, album, genre")
        .searchFocused($searchFocused)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app, collections: collections) }
        .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
        .onChange(of: browse.kind) { browse.persist(); if browse.searchOnline { triggerOnline() } }
        .onChange(of: browse.layout) { browse.persist() }
        .onChange(of: browse.clauses) { browse.persist(); if browse.searchOnline { triggerOnline() } }
        // Sort changes RESET + re-fetch online (the server sorts the full result
        // set; the client only holds loaded pages so it can't re-order them).
        .onChange(of: browse.sortKeys) { browse.persist(); if browse.searchOnline { triggerOnline() } }
        .onChange(of: browse.searchOnline) {
            browse.persist()
            // Coming back to on-device: restart its paging (the pre-online budget may be
            // huge). Invalidating the committed key makes `liveVisible` fall back to a page.
            visibleKey = ""
            if browse.searchOnline { triggerOnline() } else { online.cancel() }
        }
        .onChange(of: browse.query) { if browse.searchOnline { triggerOnline() } }
        // "Search PocketDJ for …" (the system.search intent): the term is parked on
        // the intents bridge; consume it into the search field — whether the browser
        // is already up (onChange) or the intent launched the app (task).
        .onChange(of: intents.pendingBrowseQuery) { _, _ in consumeIntentSearch() }
        .task {
            consumeIntentSearch()
            if browse.searchOnline { triggerOnline() }
        }
    }

    /// Atomically take the pending intent search term into the search field (live
    /// re-read + clear, so multi-window consumers race safely — see RootView's
    /// consumeIntentRoute for the same pattern).
    private func consumeIntentSearch() {
        guard let term = intents.pendingBrowseQuery else { return }
        intents.pendingBrowseQuery = nil
        browse.query = term
    }

    /// The visible items (on-device or online) for the current kind, in display order.
    private var visibleItems: [BrowseItem] {
        browse.searchOnline ? online.items : browse.results(app, collections: collections)
    }

    /// The row ids currently shown in WHICHEVER list is up (on-device or online), in
    /// order — SONG ids in song mode, ALBUM ids in album mode. The domain over which
    /// ↑/↓ arrow-key focus moves. Linear order, so grid focus walks album order 1D.
    private var visibleRowIds: [String] {
        visibleItems.compactMap { item in
            switch (browse.kind, item) {
            case (.song, .song(let s, _, _, _)):  return s.id
            case (.album, .album(let a, _)):   return a.id
            default:                           return nil
            }
        }
    }

    /// The visible SONG ids — used by ⌘P's "play focused song" fallback in song mode.
    private var visibleSongIds: [String] {
        guard browse.kind == .song else { return [] }
        return visibleRowIds
    }

    /// Move the keyboard-focus cursor by `delta` rows (±1) over the visible rows (songs
    /// or albums), clamping at the ends; seeds at the first row when nothing is focused.
    private func moveFocus(_ delta: Int) {
        let ids = visibleRowIds
        guard !ids.isEmpty else { return }
        guard let current = focusedRowId, let idx = ids.firstIndex(of: current) else {
            focusedRowId = delta > 0 ? ids.first : ids.last
            return
        }
        let next = min(max(idx + delta, 0), ids.count - 1)
        focusedRowId = ids[next]
        // Reveal the newly-focused row by growing the render budget to include it — but only
        // for incremental stepping near the loaded edge. A FAR jump (e.g. ↑ from nothing
        // seeds focus to the LAST of ~90k rows) leaves the budget untouched rather than
        // materializing the whole catalog — the exact stutter paging exists to prevent
        // (its highlight just waits until the user scrolls there). Device only.
        if !browse.searchOnline {
            let grown = BrowsePaging.focusReveal(liveVisible, toIndex: next, total: ids.count)
            if grown != liveVisible { visibleCount = grown; visibleKey = pagingKey }
        }
    }

    /// ⌘P: play (or pause/resume) the keyboard-focused song row. Song mode only; in
    /// album mode there's no single song to play, so it's a no-op. If the focused song
    /// is already now-playing, toggle the engine; otherwise start it like the row ▶.
    private func toggleFocusedSong() {
        guard browse.kind == .song else { return }
        guard let id = focusedRowId ?? visibleSongIds.first,
              let song = app.songsById[id] else { return }
        focusedRowId = id
        if rips.nowPlaying?.songId == id { player.toggle(); return }
        // OFFLINE-FIRST: prefer a BURNED local file (zero-latency, no network) before any rip —
        // mirrors the row ▶ so ⌘P also plays burned songs with no connection.
        if let res = burns.localURLForPlayback(forSong: id) {
            playLocalFile(res.url, songId: id, title: song.name, artist: song.artist,
                          startMs: burns.startMs(forSong: id), rips: rips, player: player,
                          release: res.release)
            return
        }
        Task {
            if let now = try? await rips.play((id: song.id, title: song.name, artist: song.artist)) {
                player.load(url: now.url, live: now.live, startMs: now.startMs,
                            title: now.title, artist: now.artist, songId: now.songId)
            }
        }
    }

    /// Return / ⌘O: OPEN the keyboard-focused item — push its detail view onto the
    /// shared navigation path (the same destination a row tap reaches). A focused album
    /// → AlbumDetailView; a focused song → SongDetailView. Seeds focus to the first row
    /// if nothing is focused yet, so a bare Return opens the top result.
    private func openFocusedRow() {
        let id = focusedRowId ?? visibleRowIds.first
        guard let id else { return }
        focusedRowId = id
        switch browse.kind {
        case .album:
            if let album = focusedItemAlbum(id) { path.append(album) }
        case .song:
            if let song = focusedItemSong(id) { path.append(song) }
        }
    }

    /// Resolve the focused album id to its IndexAlbum — prefers the visible item (so
    /// online-only results that aren't in the on-device catalog still open), then the
    /// merged catalog as a fallback.
    private func focusedItemAlbum(_ id: String) -> IndexAlbum? {
        for case .album(let a, _) in visibleItems where a.id == id { return a }
        return app.albumsById[id]
    }

    private func focusedItemSong(_ id: String) -> IndexSong? {
        for case .song(let s, _, _, _) in visibleItems where s.id == id { return s }
        return app.songsById[id]
    }

    private var searchCreds: SigV4Creds? {
        settings.searchConfigured
            ? SigV4Creds(accessKeyId: settings.searchAccessKeyID, secretAccessKey: settings.searchSecretKey)
            : nil
    }

    private func triggerOnline() {
        // Apply the user's optional host override (Settings ▸ Endpoint) before searching;
        // resolution is user override → global search-config.json → baked default.
        let endpoint = settings.searchEndpoint
        Task { await SearchConfig.shared.setUserHost(endpoint) }
        online.searchDebounced(query: browse.query, kind: browse.kind,
                               clauses: browse.clauses, sortKeys: browse.sortKeys,
                               creds: searchCreds, app: app)
    }

    /// SF Symbol for the current device — shown when searching on-device.
    private var deviceIcon: String {
        #if os(macOS)
        "macbook"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // On-device ⇄ online (OpenSearch) search mode — device icon vs cloud.
            Button { browse.searchOnline.toggle() } label: {
                Image(systemName: browse.searchOnline ? "cloud" : deviceIcon)
            }
            .accessibilityIdentifier("search-mode")
            .help(browse.searchOnline ? "Online search (OpenSearch)" : "On-device search")

            if browse.kind == .album {
                Button {
                    browse.layout = browse.layout == .grid ? .list : .grid
                } label: {
                    Image(systemName: browse.layout == .grid ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityIdentifier("layout-toggle")
            }
            Button { showSort = true } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityIdentifier("sort-button")
            Button { showFilter = true } label: {
                Image(systemName: (browse.activeFilterCount > 0
                                   || (browse.kind == .song && browse.membershipActive))
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("filter-button")
        }
    }

    /// Hidden buttons that bind keyboard commands to the browser actions:
    /// ⌘1 Albums · ⌘2 Songs · ⌥⌘F Filter · ⌥⌘S Sort · ⌘V grid/list · ⌘L Search.
    /// Handy in normal use, and the reliable way to drive the segmented Picker +
    /// toolbar in macOS XCUITests (where neither is tappable).
    private var kindShortcuts: some View {
        // "-shadow"-suffixed labels give these keyboard-only buttons context (for
        // menus / VoiceOver) while staying distinct from the real controls' labels
        // so they never collide in XCUITest queries.
        Group {
            Button("Albums-shadow") { browse.kind = .album }.keyboardShortcut("1", modifiers: .command)
            Button("Songs-shadow") { browse.kind = .song }.keyboardShortcut("2", modifiers: .command)
            Button("Filter-shadow") { showFilter = true }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Sort-shadow") { showSort = true }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Layout-shadow") {
                if browse.kind == .album { browse.layout = browse.layout == .grid ? .list : .grid }
            }.keyboardShortcut("v", modifiers: .command)
            Button("Search-shadow") { searchFocused = true }.keyboardShortcut("l", modifiers: .command)
            // List keyboard navigation: ↑/↓ move the focus cursor over the visible song
            // OR album list, ⌘P plays/pauses the focused song, Return / ⌘O opens the
            // focused item (album → AlbumDetailView, song → SongDetailView). Left LIVE
            // even while the search field is focused: ↑/↓ aren't a single-line field's
            // cursor keys (←/→ are), so they don't fight typing — Spotlight-style, you
            // can type a query then arrow into the results and Return to open one.
            Button("FocusUp-shadow") { moveFocus(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("FocusDown-shadow") { moveFocus(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("PlayFocused-shadow") { toggleFocusedSong() }.keyboardShortcut("p", modifiers: .command)
            Button("OpenFocused-shadow") { openFocusedRow() }.keyboardShortcut(.return, modifiers: [])
            Button("OpenFocusedAlt-shadow") { openFocusedRow() }.keyboardShortcut("o", modifiers: .command)
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
    }

    @ViewBuilder private var content: some View {
        switch app.state {
        case .idle, .loading:
            loadingView
        case .failed(let message):
            failureView(message)
        case .loaded:
            if browse.searchOnline {
                onlineContent
            } else {
                // Full ordered set is memoized (cheap); render only a growing prefix so the
                // ForEach stays small no matter how large the catalog is.
                let items = browse.results(app, collections: collections)
                let page = BrowsePaging.page(items, visible: liveVisible)
                resultsHeader(items.count)
                if browse.kind == .album { albumResults(page, fullCount: items.count) }
                else { songResults(page, fullCount: items.count) }
            }
        }
    }

    @ViewBuilder private var onlineContent: some View {
        switch online.state {
        case .loading:
            VStack(spacing: 12) { ProgressView(); Text("Searching online…").foregroundStyle(Theme.fgDim) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .failed(let message):
            ContentUnavailableView {
                Label("Online search unavailable", systemImage: "cloud.slash")
            } description: { Text(message) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .idle, .loaded:
            // Header shows the FULL match count (online.total), not just the rows
            // loaded so far — the pager appends more as you scroll.
            resultsHeader(online.total)
            if browse.kind == .album { albumResults(online.items, fullCount: online.total) }
            else { songResults(online.items, fullCount: online.total) }
        }
    }

    private func resultsHeader(_ count: Int) -> some View {
        HStack {
            Text("\(count) \(browse.kind == .album ? "albums" : "songs")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.fgDim)
            Spacer()
            if !browse.sortKeys.isEmpty {
                Label(sortSummary, systemImage: "arrow.up.arrow.down")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
        .accessibilityIdentifier("results-count")
        .accessibilityValue("\(count)")
    }

    private var sortSummary: String {
        browse.sortKeys.compactMap { Fields.byID[$0.field]?.label }.joined(separator: " › ")
    }

    private func albumResults(_ items: [BrowseItem], fullCount: Int) -> some View {
        ScrollView {
            if browse.layout == .grid {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(items) { item in
                        if case .album(let album, _) = item {
                            NavigationLink(value: album) { AlbumCard(album: album) }
                                .buttonStyle(.plain)
                                // Keyboard-focus highlight — ↑/↓ cursor walks album order
                                // linearly through the grid; Return/⌘O opens the album.
                                .padding(6)
                                .background(focusedRowId == album.id
                                            ? Theme.accent.opacity(0.16) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("album-\(album.id)")
                                .onAppear { onRowAppear(item, rendered: items, fullCount: fullCount) }
                        }
                    }
                }
                .padding(16)
                pagingFooter
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        if case .album(let album, _) = item {
                            NavigationLink(value: album) { AlbumRow(album: album) }
                                .buttonStyle(.plain)
                                // Keyboard-focus highlight (↑/↓ cursor; Return/⌘O opens).
                                .background(focusedRowId == album.id
                                            ? Theme.accent.opacity(0.16) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("album-\(album.id)")
                                .onAppear { onRowAppear(item, rendered: items, fullCount: fullCount) }
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .padding(.horizontal, 8)
                pagingFooter
            }
        }
        .background(Theme.bg)
    }

    /// The last RENDERED row scrolled into view — page in more. Online: pull the next
    /// server page (`loadMore` self-guards on `hasMore && !isLoadingPage`). On-device:
    /// grow the local render budget toward the full result count (no-op once it's all
    /// shown). Wiring both through one place keeps the two lists' behavior identical.
    private func onRowAppear(_ item: BrowseItem, rendered: [BrowseItem], fullCount: Int) {
        guard item.id == rendered.last?.id else { return }
        if browse.searchOnline {
            Task { await online.loadMore() }
        } else if liveVisible < fullCount {
            // Commit the grown budget against the CURRENT key so `liveVisible` keeps it.
            visibleCount = BrowsePaging.grow(liveVisible, upTo: fullCount)
            visibleKey = pagingKey
        }
    }

    /// Bottom-of-list spinner shown while a NEXT page is paging in (online only).
    @ViewBuilder private var pagingFooter: some View {
        if browse.searchOnline && online.isLoadingPage {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading more…").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityIdentifier("paging-indicator")
        }
    }

    private func songResults(_ items: [BrowseItem], fullCount: Int) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    if case .song(let song, let albumName, _, _) = item {
                        // The row's transport ▶/⤓ buttons must stay independently
                        // hit-testable. Wrapping the whole row in a NavigationLink
                        // (a Button on macOS) swallows those nested buttons — XCUITest
                        // can't reach them and a click navigates instead of playing
                        // (the "row ▶ freezes" bug). So the tap-to-open is a row-level
                        // .onTapGesture (NOT a wrapping link), and the transport buttons
                        // sit on top and intercept their own taps first — only taps
                        // OUTSIDE them fall through here and navigate.
                        SongRow(song: song, albumName: albumName)
                            .contentShape(Rectangle())
                            .onTapGesture { path.append(song) }
                            // `.contain` keeps the row a CONTAINER (not a merged leaf), so its
                            // own `song-<id>` id stays queryable for the tap-to-navigate test
                            // WHILE the nested transport buttons keep their own `row-play-<id>`
                            // / `row-download-<id>` ids on iOS. (A bare identifier on a row with
                            // an onTapGesture merges the row into one element and clobbers those
                            // child ids — the "row-play-<id> missing on iOS" bug.)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("song-\(song.id)")
                            // Keyboard-focus highlight (↑/↓ cursor; ⌘P plays it).
                            .background(focusedRowId == song.id
                                        ? Theme.accent.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            // The paging trigger MUST sit on the SongRow — the row that
                            // always renders. InlinePlayerSlot renders NOTHING unless its
                            // song is now-playing, and SwiftUI never fires .onAppear on a
                            // no-content view, so a trigger there leaves the song list
                            // stuck on page 1 (albums page from their always-rendered
                            // NavigationLink — same trigger, working placement).
                            .onAppear { onRowAppear(item, rendered: items, fullCount: fullCount) }
                        InlinePlayerSlot(songId: song.id).padding(.horizontal, 2)
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .padding(.horizontal, 8)
            pagingFooter
        }
        .background(Theme.bg)
        .accessibilityIdentifier("song-list")
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(app.sourceName)…").foregroundStyle(Theme.fgDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load the collection", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await app.reload() } }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Rows

struct AlbumCard: View {
    let album: IndexAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(album: album).aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(album.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                HStack(spacing: 6) {
                    if let g = album.genre { Tag(text: g, color: Theme.accent) }
                    if let y = album.year { Text(String(y)).font(.caption2).foregroundStyle(Theme.fgDim) }
                }
            }
        }
    }
}

struct AlbumRow: View {
    let album: IndexAlbum
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(album: album, corner: 6).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(album.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if let g = album.genre { Tag(text: g, color: Theme.accent) }
            if let y = album.year {
                Text(String(y)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Browser song row — the SHARED `SongRowView`, so it reads identically to the
/// collection + setlist rows (now gaining a thumbnail, explicit badge, year, genre,
/// BPM tiers, and the transport slot it previously lacked). No delete/reorder/notes here.
struct SongRow: View {
    @Environment(AppModel.self) private var app
    let song: IndexSong
    /// Accepted for source compatibility with the browser pipeline; the shared row
    /// resolves the album (and thus year/genre/art) from the catalog itself.
    var albumName: String = ""

    private var album: IndexAlbum? { song.albumId.flatMap { app.albumsById[$0] } }

    var body: some View {
        SongRowView(data: SongRowData(song: song, album: album))
            .padding(.horizontal, 2)
    }
}

struct Tag: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
