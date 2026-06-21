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
    @State private var browse = BrowseState(defaults: SettingsStore.launchDefaults())
    @State private var online = OnlineSearchModel()
    @State private var showFilter = false
    @State private var showSort = false
    @FocusState private var searchFocused: Bool
    /// Keyboard-navigation cursor over the SONG results: the focused row's song id.
    /// ↑/↓ move it; ⌘P plays/pauses it. Nil until the first arrow press.
    @State private var focusedSongId: String?

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)] }

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
        .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app) }
        .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
        .onChange(of: browse.kind) { browse.persist(); if browse.searchOnline { triggerOnline() } }
        .onChange(of: browse.layout) { browse.persist() }
        .onChange(of: browse.clauses) { browse.persist(); if browse.searchOnline { triggerOnline() } }
        .onChange(of: browse.sortKeys) { browse.persist() }
        .onChange(of: browse.searchOnline) {
            browse.persist()
            if browse.searchOnline { triggerOnline() } else { online.cancel() }
        }
        .onChange(of: browse.query) { if browse.searchOnline { triggerOnline() } }
        .task { if browse.searchOnline { triggerOnline() } }
    }

    /// The song ids currently shown in the songs list (on-device or online), in order —
    /// the domain over which ↑/↓ arrow-key focus moves.
    private var visibleSongIds: [String] {
        guard browse.kind == .song else { return [] }
        let items = browse.searchOnline ? online.items : browse.results(app)
        return items.compactMap { if case .song(let s, _, _) = $0 { return s.id } else { return nil } }
    }

    /// Move the keyboard-focus cursor by `delta` rows (±1) over the visible songs,
    /// clamping at the ends; seeds at the first row when nothing is focused yet.
    private func moveFocus(_ delta: Int) {
        let ids = visibleSongIds
        guard !ids.isEmpty else { return }
        guard let current = focusedSongId, let idx = ids.firstIndex(of: current) else {
            focusedSongId = delta > 0 ? ids.first : ids.last
            return
        }
        let next = min(max(idx + delta, 0), ids.count - 1)
        focusedSongId = ids[next]
    }

    /// ⌘P: play (or pause/resume) the keyboard-focused song row. If the focused song is
    /// already the now-playing one, toggle the engine; otherwise start it like the row ▶.
    private func toggleFocusedSong() {
        guard let id = focusedSongId ?? visibleSongIds.first,
              let song = app.songsById[id] else { return }
        focusedSongId = id
        if rips.nowPlaying?.songId == id { player.toggle(); return }
        Task {
            if let now = try? await rips.play((id: song.id, title: song.name, artist: song.artist)) {
                player.load(url: now.url, live: now.live, startMs: now.startMs,
                            title: now.title, artist: now.artist)
            }
        }
    }

    private var searchCreds: SigV4Creds? {
        settings.searchConfigured
            ? SigV4Creds(accessKeyId: settings.searchAccessKeyID, secretAccessKey: settings.searchSecretKey)
            : nil
    }

    private func triggerOnline() {
        online.searchDebounced(query: browse.query, kind: browse.kind,
                               clauses: browse.clauses, creds: searchCreds, app: app)
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
                Image(systemName: browse.activeFilterCount > 0
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
            // Song-list keyboard navigation: ↑/↓ move the focus cursor, ⌘P plays/pauses
            // the focused row. Hidden buttons so they work app-wide without stealing the
            // search field's own arrow handling when it's focused on macOS.
            Button("FocusUp-shadow") { moveFocus(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("FocusDown-shadow") { moveFocus(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("PlayFocused-shadow") { toggleFocusedSong() }.keyboardShortcut("p", modifiers: .command)
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
                let items = browse.results(app)
                resultsHeader(items.count)
                if browse.kind == .album { albumResults(items) } else { songResults(items) }
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
            resultsHeader(online.items.count)
            if browse.kind == .album { albumResults(online.items) } else { songResults(online.items) }
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

    private func albumResults(_ items: [BrowseItem]) -> some View {
        ScrollView {
            if browse.layout == .grid {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(items) { item in
                        if case .album(let album, _) = item {
                            NavigationLink(value: album) { AlbumCard(album: album) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("album-\(album.id)")
                        }
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        if case .album(let album, _) = item {
                            NavigationLink(value: album) { AlbumRow(album: album) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("album-\(album.id)")
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Theme.bg)
    }

    private func songResults(_ items: [BrowseItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    if case .song(let song, let albumName, _) = item {
                        // The row's transport ▶/⤓ buttons must stay independently
                        // hit-testable. Wrapping the whole row in a NavigationLink
                        // (a Button on macOS) swallows those nested buttons — XCUITest
                        // can't reach them and a click navigates instead of playing
                        // (the "row ▶ freezes" bug). So the tap-through link rides
                        // BEHIND the row content (zero-size, in the background) and the
                        // real SongRow — buttons and all — sits on top, fully live.
                        SongRow(song: song, albumName: albumName)
                            .contentShape(Rectangle())
                            // The tap-through navigation rides BEHIND the row content as a
                            // full-bleed, hittable-but-clear NavigationLink. Because it's in
                            // the background (lower z-order), the row's own transport ▶/⤓
                            // buttons on top still receive their taps — wrapping the whole
                            // row in the link instead would collapse it into one Button on
                            // macOS and swallow those nested buttons (the inline-player bug).
                            .background(
                                NavigationLink(value: song) {
                                    Color.clear.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("song-\(song.id)")
                            )
                            // Keyboard-focus highlight (↑/↓ cursor; ⌘P plays it).
                            .background(focusedSongId == song.id
                                        ? Theme.accent.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        InlinePlayerSlot(songId: song.id).padding(.horizontal, 2)
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .padding(.horizontal, 8)
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
