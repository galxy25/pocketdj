import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The HOME "Now Playing" element — shown on the iPhone menu screen and under the
/// iPad/macOS sidebar items whenever collection playback (the app-scoped
/// `SetlistPlayer`) is running in any mode EXCEPT Mix (RootView owns that gate).
///
/// Top to bottom: the current track's title + artist · a spinning GOLD record in a
/// BLUE record-player chassis (the disc spins at a rate that reflects the track's
/// measured beat-grid BPM — one revolution per 4-beat bar, so ~133 BPM ≈ 33 RPM
/// vinyl; catalog BPM fallback, 33⅓ RPM when unknown; frozen while paused) ·
/// ⏮ ⏯ ⏭ transport · the reorderable/removable UP NEXT queue · and a free-text
/// add-search over albums + songs (albums above songs, both collapsible) whose
/// field sits at the panel's bottom.
///
/// The queue renders LIVE from `sequencer.queue`/`index` (the ephemeral run), not
/// from the frozen Now Playing setlist — edits here mutate only the upcoming tail
/// (see SetlistPlayer's live-queue contract) and never restart the current track.
struct NowPlayingPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(BurnStore.self) private var burns
    @Environment(CollectionsStore.self) private var collections
    @Environment(IntentServices.self) private var intents
    #if os(iOS)
    // Size classes are iOS-only (unavailable on plain macOS) — guard the env read.
    @Environment(\.verticalSizeClass) private var vSize
    #endif

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var albumsExpanded = true
    @State private var songsExpanded = true
    /// Long-press (iOS) / right-click (macOS) on the record → the current song's
    /// full detail metadata, presented as a sheet with a BACK button top-left.
    /// The ⟲ history toggle next to the transport: shows the played head of the queue
    /// ("previously played") as a section between the deck and Up Next. AppStorage so
    /// the preference survives relaunches like the iOS collapse chevron's.
    @AppStorage("nowPlayingShowPlayed") private var showPlayed = false
    @State private var detailSong: IndexSong?
    /// The song-detail sheet's own navigation stack (see the `.sheet` below).
    @State private var detailPath = NavigationPath()
    /// Debounced, off-main search results (see the `.task(id:)` below) — the body
    /// must NEVER scan the ~100k-song catalog itself.
    @State private var results: SearchResults = .empty
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    /// Windowed Up Next (see `RowWindow`). Shuffling a large collection queues thousands of
    /// rows, and this panel appears as a direct result — so an unwindowed Up Next made the
    /// whole panel construct a row (each with an eagerly-built 4-item context menu) per queued
    /// track before the tap finished. That, not the queue build itself, was the multi-second
    /// wait after Shuffle.
    ///
    /// OUTSIDE the `os(iOS)` fence above — `upNextSection` is shared by every platform, so
    /// gating this on iOS built there and broke the macOS/visionOS archives.
    @State private var upNextShown = RowWindow.page

    struct SearchResults: Equatable {
        var albums: [IndexAlbum] = []
        var songs: [IndexSong] = []
        static let empty = SearchResults()
    }

    /// Single source of truth for "the home Now Playing element is up": collection
    /// playback running and the Mix engines not owning the audio. RootView gates
    /// the panel on it, and BrowseView yields its ⌘L to the panel's while true.
    @MainActor
    static func isVisible(sequencer: SetlistPlayer, mix: MixEngine) -> Bool {
        sequencer.isRunning && !(mix.isRunning || mix.autoMixing)
    }

    /// iPhone landscape: too short for the record player — the panel keeps the
    /// header/transport/queue/search and drops the deck art.
    private var compactHeight: Bool {
        #if os(iOS)
        return vSize == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        // ONE scrollable List (user-tested): the deck — header, record player,
        // transport — is a scrolling ROW above the queue, so pulling up scrolls it
        // out of view and Up Next can take the whole panel (the menu/tab links
        // above stay pinned; RootView owns that split). Search is the NATIVE
        // `.searchable` control (same UI as the Browser tab): the field rides the
        // bar at the top — never buried under the keyboard like a bottom text
        // field — and the results list keyboard-avoids like any List.
        List {
            if searching {
                searchResults
            } else {
                deckSection
                if showPlayed { playedSection }
                upNextSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        // Placement is LOAD-BEARING on macOS/iPad: `.sidebar` renders the field
        // INSIDE the left sidebar column. The automatic placement put it in the
        // window's unified NSToolbar — and when the Browser tab (which has its own
        // `.searchable`) came up, SwiftUI inserted a SECOND toolbar search item and
        // AppKit threw out of `NSToolbar _insertNewItemWithItemIdentifier:` →
        // `_crashOnException` (Levi's macOS 27 crash report; iOS never crashed
        // because each nav bar hosts its own field). Sidebar placement keeps the
        // panel's search out of the toolbar entirely — and puts it on the LEFT,
        // where the user asked for it.
        #if os(iOS)
        .environment(\.editMode, $editMode)
        .searchable(text: $query,
                    placement: UIDevice.current.userInterfaceIdiom == .pad
                        ? .sidebar : .navigationBarDrawer(displayMode: .always),
                    prompt: "Add songs or albums")
        #elseif os(tvOS)
        // NO add-search on the TV (Levi, on-device 2026-09-02): the panel is a lean-back deck
        // there — Browse owns library search, the Jukebox owns requests. `query` stays empty so
        // `searching` never flips and the deck/queue sections always render. `.searchFocused`
        // rides the same fence: there is no field for it to focus.
        #else
        .searchable(text: $query, placement: .sidebar, prompt: "Add songs or albums")
        #endif
        #if !os(tvOS)
        .searchFocused($searchFocused)
        #endif
        // ⌘L — jump the cursor into the add-search so the whole panel is drivable
        // from the keyboard. Registered ONLY while the panel exists; BrowseView's
        // own ⌘L (its search field) yields to this one while the panel is up.
        .background {
            Button("Focus Now Playing search") { searchFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .frame(width: 1, height: 1).opacity(0.01)
        }
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing-panel")
        // The record's song-detail sheet. Close affordance per platform (user-
        // tested): iPhone gets a BACK button in the nav bar (top-left); iPad and
        // macOS get an always-visible ✕ overlaid top-left — the sheet's toolbar
        // isn't a reliable surface there, and Esc alone is power-user-only.
        .sheet(item: $detailSong) { song in
            // The sheet owns its OWN stack + destinations, so the detail's artist/album
            // hotlinks push IN PLACE. This used to be a bare `NavigationStack` with nothing
            // registered — the hotlinks had to dismiss the sheet and route across stacks,
            // which lost the push and landed the user on a blank screen.
            NavigationStack(path: $detailPath) {
                SongDetailView(song: song, path: $detailPath)
                    .pocketDJDestinations(path: $detailPath)
                    .toolbar {
                        if !Self.detailUsesCloseOverlay {
                            ToolbarItem(placement: .navigation) {
                                Button { detailSong = nil } label: {
                                    Label("Back", systemImage: "chevron.backward")
                                        .labelStyle(.titleAndIcon)
                                }
                                .accessibilityIdentifier("np-detail-back")
                            }
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                if Self.detailUsesCloseOverlay {
                    Button { detailSong = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.fg, Theme.bgOverlay)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)   // Esc still works for power users
                    .padding(10)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("np-detail-close")
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        // Debounce + compute OFF the main actor: a keystroke (or any sequencer
        // change while a query is live) must not trigger a synchronous full-catalog
        // scan in body. `.task(id:)` cancels the in-flight search on every change.
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { results = .empty; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let songs = app.songs, albums = app.albums   // value snapshots (main actor)
            let found = await Task.detached(priority: .userInitiated) {
                SearchResults(
                    albums: NowPlayingSearch.albums(matching: trimmed, in: albums),
                    songs: NowPlayingSearch.songs(matching: trimmed, in: songs))
            }.value
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    /// Unified play/pause across backends, routed by which engine OWNS the audio
    /// (`activeBackend`) — NOT by whether the deck's current item matches it. Keying off the
    /// item id let a stale deck (an unadopted manual jump) route the toggle to the idle
    /// PlayerEngine: the click was refused, and the ▶/⏸ glyph contradicted what was audible.
    /// When Apple Music is streaming it owns transport, period; every local/rip/burned path
    /// (which has NO coordinator backend) toggles PlayerEngine directly.
    /// Static so the collapsed `NowPlayingMiniBar` shares the exact routing.
    @MainActor
    static func isPlayingNow(coordinator: PlaybackCoordinator, player: PlayerEngine) -> Bool {
        coordinator.activeBackend == .appleMusic ? coordinator.isPlaying : player.isPlaying
    }

    private var recordSize: CGFloat {
        #if os(macOS)
        return 150
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 170 : 210
        #endif
    }

    /// Static so the collapsed `NowPlayingMiniBar` shares the exact routing.
    @MainActor
    static func togglePlayPause(sequencer: SetlistPlayer, coordinator: PlaybackCoordinator,
                                player: PlayerEngine) {
        // A RESTORED (held) deck has no audio loaded yet — the first ▶ resumes real playback
        // at the saved position (blindly toggling would hit the idle engine and be refused).
        if sequencer.isHeldForResume { sequencer.resumeFromHold(); return }
        if coordinator.activeBackend == .appleMusic { coordinator.togglePlayPause(); return }
        // The deck's current row never started sounding (its cloud resolve produced no audio
        // — a rip still queued, a stream that missed), so the engine holds NOTHING and
        // `toggle()` would be refused outright: ▶ appears dead. Start the displayed row
        // instead, so ▶ always plays what the deck is showing.
        if !player.hasLoadedItem, sequencer.startCurrent() { return }
        player.toggle()
    }

    // MARK: - The deck row (scrolls away so Up Next can take the whole panel)

    @ViewBuilder private var deckSection: some View {
        Section {
            // The deck itself lives in `NowPlayingDeckCluster` (shared with the req-7
            // expanded surface); the docked panel keeps its fixed record size and the
            // iPhone-landscape art drop.
            NowPlayingDeckCluster(recordSize: recordSize, hideRecord: compactHeight,
                                  openDetail: { openSongDetail(for: $0) })
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
        }
    }

    /// The header's SETLIST button: a run tagged to a still-existing setlist routes
    /// straight to it; otherwise (the reserved Now Playing run — its doc is dropped at
    /// every launch — or an unlinked queue) the document is re-materialized from the
    /// live queue and then opened. Edits there drive the live queue (the uid-verified
    /// Now Playing edit path), so this is the full-power view of the running session.
    private func openSetlistView() {
        if let sid = sequencer.sourceSetlistId, collections.setlist(sid) != nil {
            intents.pendingRoute = .setlist(sid)
            return
        }
        let rows = sequencer.queue.map {
            (id: $0.id, title: $0.title, artist: $0.artist,
             lengthMs: $0.lengthMs, repeatCount: $0.repeatCount)
        }
        if let set = collections.materializeNowPlayingSetlist(
            name: sequencer.capturedHistoryContext?.name, queue: rows) {
            intents.pendingRoute = .setlist(set.id)
        }
    }

    /// Open the full Song Detail sheet for ANY queue row (current, up-next, or previously
    /// played). Catalog songs open their full metadata; anything else — a Discover amrec_
    /// rip, a jukebox Apple Music insert, a studio row — still opens, synthesized from the
    /// queue row, so the menu item always answers (and the detail's Apple Music library
    /// section can offer ＋ Add for AM-backed tracks).
    private func openSongDetail(for item: SetlistPlayer.Item) {
        detailSong = app.songsById[item.id]
            ?? IndexSong.minimal(id: item.id, name: item.title, artist: item.artist)
    }

    /// iPhone closes the detail with a nav-bar Back; iPad + macOS get the ✕ overlay.
    static var detailUsesCloseOverlay: Bool {
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    // MARK: - Queue / search results

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The played head of the queue, NEWEST first (the most recently finished track sits
    /// next to the deck). Same snapshot/uid doctrine as Up Next: rows are identified by
    /// `Item.uid`; the a11y ids stay positional for tests. Rows are read-only — the context
    /// menu offers "Play now" (interrupt and play that track immediately, queue unchanged
    /// behind it), "Rewind to here" (move the needle back so that row and everything after it
    /// replays in order), or a re-queue of a FRESH copy (reusing the row would duplicate its
    /// per-instance uid).
    @ViewBuilder private var playedSection: some View {
        let played = Array(sequencer.played.reversed())
        Section {
            if played.isEmpty {
                Text("Nothing played yet")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Theme.bg)
            }
            ForEach(Array(played.enumerated()), id: \.element.uid) { offset, item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                        Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    // "Play now" and "Rewind to here" are DIFFERENT, and both belong here.
                    // Play now interrupts: that track starts immediately and the queue then
                    // carries on exactly where it was. Rewind moves the needle back to that
                    // point, so it and everything after it — including the tracks between it
                    // and what was playing — play through again in order.
                    Button { sequencer.playNow(replay(item)) } label: {
                        Label("Play now", systemImage: "play.fill")
                    }
                    Button { sequencer.jumpToPlayed(uid: item.uid) } label: {
                        Label("Rewind to here", systemImage: "backward.end.fill")
                    }
                    Divider()
                    Button { sequencer.insertNextInQueue([replay(item)]) } label: {
                        Label("Play again next", systemImage: "arrow.up.to.line")
                    }
                    Button { sequencer.appendToQueue([replay(item)]) } label: {
                        Label("Play again last", systemImage: "arrow.down.to.line")
                    }
                    Divider()
                    Button { openSongDetail(for: item) } label: {
                        Label("Song details", systemImage: "info.circle")
                    }
                }
                .listRowBackground(Theme.bg)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("np-played-\(offset)")
            }
        } header: {
            Text("Previously played (\(sequencer.played.count))")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    /// A fresh Item for re-queueing a played row — never reuse the row itself: `uid` is
    /// per-instance identity, and a duplicate would confuse every uid-keyed queue op.
    private func replay(_ item: SetlistPlayer.Item) -> SetlistPlayer.Item {
        .init(id: item.id, title: item.title, artist: item.artist,
              lengthMs: item.lengthMs, repeatCount: item.repeatCount)
    }

    @ViewBuilder private var upNextSection: some View {
        // Snapshot ONCE per body: rows are identified by Item.uid (a song can repeat
        // in a set, and the queue can advance underneath an in-flight tap — a stale
        // positional offset would delete whatever shifted into the slot). Removal is
        // uid-verified in SetlistPlayer; the a11y ids stay positional for tests.
        let upcoming = sequencer.upcoming
        Section {
            // WINDOWED: `prefix` keeps offsets identical to the full queue's, so the
            // positional `onMove`/`onDelete` below (and the positional a11y ids) stay correct.
            ForEach(Array(upcoming.prefix(upNextShown).enumerated()), id: \.element.uid) { offset, item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                        Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        sequencer.removeUpcoming(uids: [item.uid])
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("np-remove-\(offset)")
                }
                .contentShape(Rectangle())
                // Long-press (iOS) / right-click (macOS): re-slot the row without a
                // drag — top = right after the current track, bottom = end of queue.
                .contextMenu {
                    Button { sequencer.moveUpcomingNext(uid: item.uid) } label: {
                        Label("Move to top", systemImage: "arrow.up.to.line")
                    }
                    Button { sequencer.moveUpcomingToEnd(uid: item.uid) } label: {
                        Label("Move to bottom", systemImage: "arrow.down.to.line")
                    }
                    Divider()
                    Button { openSongDetail(for: item) } label: {
                        Label("Song details", systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        sequencer.removeUpcoming(uids: [item.uid])
                    } label: {
                        Label("Remove", systemImage: "xmark")
                    }
                }
                .listRowBackground(Theme.bg)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("np-queue-\(offset)")
            }
            .onMove { from, to in sequencer.moveUpcoming(fromOffsets: from, toOffset: to) }
            .onDelete { offsets in
                // Offset→uid via the sequencer's bridge — `upcoming` is a parent-indexed
                // slice now, so subscripting it with these 0-based row offsets would read
                // the wrong element (or trap).
                sequencer.removeUpcoming(uids: Set(offsets.compactMap {
                    sequencer.upcomingUid(atOffset: $0)
                }))
            }
            RowWindowSentinel(total: upcoming.count, shown: $upNextShown)
                .listRowBackground(Theme.bg)
        } header: {
            HStack {
                Text("Up next (\(sequencer.upcoming.count))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                // The collection button — re-opens the collection this run is playing from
                // (its editable setlist/playlist/pocket view). The ghost-state fix: after a
                // durable-session restore the queue was only editable from this widget; the
                // origin now rides the snapshot, so the richer view is one tap away.
                // ONE pill (Levi 2026-07-18; replaced the origin + setlist icon pair):
                // "Collection" opens the SETLIST of this playback session — the richer
                // editable view of the exact queue. A restored session's Now Playing doc
                // was dropped at launch, so the tap re-materializes it from the live
                // queue first; its id matches the run's sourceSetlistId, so reorder/
                // add/remove there drive the live queue and ride the durable session.
                Button { openSetlistView() } label: {
                    Text("Collection")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.bgOverlay))
                        .overlay(Capsule().stroke(Theme.border))
                }
                .buttonStyle(.borderless)
                .help("Open this session's setlist")
                .accessibilityIdentifier("np-open-setlist")
                Spacer()
                #if os(iOS)
                // .onMove drag handles need edit mode on iOS (macOS drags directly).
                if !sequencer.upcoming.isEmpty {
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .font(.caption2).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    .accessibilityIdentifier("np-reorder")
                }
                #endif
            }
        }
    }

    /// Album results ABOVE songs, each section collapsible so the albums can be
    /// hidden to scroll just the songs. ＋ adds to the END of the running queue —
    /// never a restart (see SetlistPlayer.appendToQueue). Renders the debounced
    /// `results` state — no catalog work happens here.
    @ViewBuilder private var searchResults: some View {
        let albums = results.albums
        let songs = results.songs
        Section {
            if albumsExpanded {
                ForEach(albums) { album in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(album.name).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                            Text("\(album.artist) · \(album.trackList.count) tracks")
                                .font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { add(album: album) } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("np-add-album-\(album.id)")
                    }
                    .contentShape(Rectangle())
                    // Long-press / right-click: the album's WHOLE tracklist lands
                    // where you choose — right after the current track, or the end
                    // (＋ = end, the default) — in album order either way.
                    .contextMenu {
                        Button { addNext(songs: app.tracks(for: album)) } label: {
                            Label("Add next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { add(album: album) } label: {
                            Label("Add to end", systemImage: "text.append")
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
        } header: {
            collapsibleHeader("Albums (\(albums.count))", expanded: $albumsExpanded, id: "np-albums-header")
        }
        Section {
            if songsExpanded {
                ForEach(songs) { song in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(song.name).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                            Text(song.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { add(songs: [song]) } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("np-add-song-\(song.id)")
                    }
                    .contentShape(Rectangle())
                    // Long-press / right-click: choose WHERE the song lands (＋ = end).
                    .contextMenu {
                        Button { addNext(songs: [song]) } label: {
                            Label("Add next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { add(songs: [song]) } label: {
                            Label("Add to end", systemImage: "text.append")
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
        } header: {
            collapsibleHeader("Songs (\(songs.count))", expanded: $songsExpanded, id: "np-songs-header")
        }
    }

    private func collapsibleHeader(_ title: String, expanded: Binding<Bool>, id: String) -> some View {
        Button {
            withAnimation { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(title).font(.caption2.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.fgDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func add(album: IndexAlbum) {
        add(songs: app.tracks(for: album))
    }
    private func addNext(songs: [IndexSong]) {
        sequencer.insertNextInQueue(items(for: songs))
    }
    private func add(songs: [IndexSong]) {
        sequencer.appendToQueue(items(for: songs))
    }
    private func items(for songs: [IndexSong]) -> [SetlistPlayer.Item] {
        songs.map {
            SetlistPlayer.Item(id: $0.id, title: $0.name, artist: $0.artist, lengthMs: $0.length)
        }
    }
}


// MARK: - The deck cluster (header · record · transport · modes · mix panel)

/// The deck itself — title/artist header, the spinning record, transport,
/// shuffle/repeat, the 👍/👎 row, and the collapsible Mix mini-panel — extracted
/// from the docked panel so the RESIZABLE expanded surface (req 7) renders the
/// same cluster at any size. `recordSize` is the one geometry input (the platter
/// scales with it); `openDetail` keeps the song-detail sheet with the OWNER.
/// Behavior-neutral extraction: every a11y id and interaction is unchanged.
struct NowPlayingDeckCluster: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(BurnStore.self) private var burns
    /// The ⟲ played-section preference — same key as the panel's, so the toggle
    /// reads/writes ONE truth from either surface.
    @AppStorage("nowPlayingShowPlayed") private var showPlayed = false

    let recordSize: CGFloat
    /// The docked iPhone-landscape panel drops the deck art (too short); the
    /// expanded surface never does — the platter is its centerpiece.
    var hideRecord: Bool = false
    var openDetail: (SetlistPlayer.Item) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            header
            if !hideRecord {
                RecordPlayerView(album: currentAlbum, artworkURL: currentArtworkURL,
                                 studioId: currentItem?.id, bpm: currentBpm,
                                 spinning: currentItemAudible, progress: playProgress)
                    .frame(width: recordSize, height: recordSize * 0.82)
                    // The record is the door to the current track's metadata:
                    // long-press on iOS opens the detail DIRECTLY; macOS gets
                    // the natural right-click menu.
                    // Right-click (macOS) / long-press (iOS) → Song details + Share (F3).
                    .contextMenu {
                        Button { if let item = currentItem { openDetail(item) } } label: {
                            Label("Song details", systemImage: "info.circle")
                        }
                        if let share = currentShareText {
                            ShareLink(item: share) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                    }
            }
            transport
            shuffleRepeatRow
            feedbackRow
            // F4 — the collapsible Mix mini-panel. Self-gates on `SetlistPlayer.mixAvailable`
            // (hidden entirely for a non-mixable current track or while a Mix session plays),
            // collapsed by default.
            NowPlayingMixPanel()
        }
    }

    // MARK: - Current track

    private var currentItem: SetlistPlayer.Item? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        return sequencer.queue[sequencer.index]
    }
    private var currentAlbum: IndexAlbum? {
        currentItem.flatMap { app.album(forSongId: $0.id) }
    }
    /// F3 share-text block for the current now-playing track — the catalog song when indexed, else a
    /// bare title/artist (search links). nil when the deck is idle.
    private var currentShareText: String? {
        guard let item = currentItem else { return nil }
        if let song = app.songsById[item.id] { return ShareText.forSong(song) }
        return ShareText.forTitleArtist(title: item.title, artist: item.artist)
    }
    /// Spin rate source: the measured beat grid (preferred — the rip manifest's
    /// `beatGridBpm`), else the catalog BPM; nil ⇒ the view's 33⅓ RPM fallback.
    private var currentBpm: Double? {
        guard let id = currentItem?.id else { return nil }
        return burns.beatGrid(forSong: id)?.bpm ?? app.songsById[id]?.bpm
    }

    private var isPlayingNow: Bool {
        NowPlayingPanel.isPlayingNow(coordinator: coordinator, player: player)
    }

    /// The record spins only when the AUDIO is the deck's current track — a Discover/
    /// browser SINGLE playing through the shared engine must not spin the platter under
    /// a paused set (display/audio mismatch; Levi 2026-07-18). Apple Music playback is
    /// always deck-owned; a nil engine songId (burned-local loads) is deck-owned too —
    /// only a KNOWN different song blocks the spin.
    private var currentItemAudible: Bool {
        guard isPlayingNow else { return false }
        if coordinator.activeBackend == .appleMusic { return true }
        guard let playing = player.nowPlayingSongId, let current = currentItem else { return true }
        return playing == current.id
    }

    /// Play-position fraction (0…1) for the tonearm sweep — sampled by the record
    /// view on its own throttled timeline (the clocks are deliberately
    /// non-observable; see PlayerClock). Elapsed comes from whichever engine owns
    /// the track; length prefers the catalog snapshot (Apple Music publishes no
    /// duration), falling back to PlayerEngine's decoded duration.
    private func playProgress() -> Double {
        guard let item = currentItem else { return 0 }
        let am = coordinator.isAppleMusicNowPlaying(item.id)
        let elapsed = am ? coordinator.appleMusic.positionSeconds : player.currentTime
        // Length prefers the catalog snapshot; but an Apple Music (Local) track often has NO
        // `lengthMs` AND the streaming player publishes no duration — so also fall back to the
        // resolved MusicKit catalog duration, else the fraction stays 0 and the tonearm freezes.
        let length = max(item.lengthMs.map { Double($0) / 1000 } ?? 0,
                         player.duration,
                         am ? coordinator.appleMusic.durationSeconds : 0)
        guard length > 0 else { return 0 }
        return min(1, max(0, elapsed / length))
    }

    /// The current track's cover URL when it's an Apple Music stream — our AM-Local catalog has
    /// no `artCandidates`, so the deck falls back to the MusicKit artwork captured at play time.
    private var currentArtworkURL: URL? {
        guard let item = currentItem, coordinator.isAppleMusicNowPlaying(item.id) else { return nil }
        return coordinator.appleMusic.nowPlaying?.artworkURL
    }

    // MARK: - Header (title + artist ABOVE the record player)

    @ViewBuilder private var header: some View {
        VStack(spacing: 2) {
            Text(currentItem?.title ?? "—")
                .font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                .accessibilityIdentifier("np-title")
            Text(currentItem?.artist ?? "")
                .font(.subheadline).foregroundStyle(Theme.fgDim).lineLimit(1)
                .accessibilityIdentifier("np-artist")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 28) {
            Button { sequencer.skipPrevious() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .accessibilityIdentifier("np-previous")
            Button { togglePlayPause() } label: {
                Image(systemName: isPlayingNow ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .accessibilityIdentifier("np-playpause")
            Button { sequencer.skipNext() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .accessibilityIdentifier("np-next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        // History toggle on the leading edge, the ♥ on the trailing edge, so the ⏮⏯⏭ trio
        // stays centered between them.
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { historyToggle }
        .overlay(alignment: .trailing) { favoriteToggle }
    }

    /// 👍 / 👎 on WHAT IS PLAYING — the SYNC half of the tuning loop, and the reason this feature
    /// is not "a list with buttons on it": the listener hears a suggestion, judges it in the
    /// moment, and the next queue is better. Its own row under the transport rather than crowded
    /// beside the ♥, because the two mean different things (a ♥ is a permanent library act that
    /// can reach Apple Music; a 👎 is an instruction to the ranking) and a mis-tap between them
    /// would be silently expensive.
    ///
    /// Neither control touches the transport. Accepting keeps playing; rejecting keeps playing.
    @ViewBuilder private var feedbackRow: some View {
        if currentItem != nil {
            NowPlayingFeedbackButtons(font: .subheadline)
                .padding(.top, 2)
                .accessibilityIdentifier("np-feedback")
        }
    }

    /// ♥ — the current track's favorite, the SAME reusable control every song row uses (reads
    /// FavoritesStore, keyed on songId + appleMusicId, `.borderless` for macOS). Hidden when the
    /// deck is idle (no current item to favorite). A track with no Apple Music id (vinyl / My
    /// Digital / Studio) still favorites — local-only — exactly like its Browse row.
    @ViewBuilder private var favoriteToggle: some View {
        if let item = currentItem {
            FavoriteToggle(songId: item.id,
                           appleMusicId: app.songsById[item.id]?.appleMusicId,
                           font: .subheadline)
                .padding(.trailing, 12)
        }
    }

    /// ⟲ — reveals the durable session's already-played tracks between the deck and Up Next.
    private var historyToggle: some View {
        Button { withAnimation { showPlayed.toggle() } } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.subheadline)
                .foregroundStyle(showPlayed ? Theme.accent : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .help("Previously played")
        .accessibilityLabel("Previously played")
        .accessibilityIdentifier("np-history")
    }

    // MARK: Shuffle / repeat (whole-session modes)

    /// Shuffle (left) + repeat (right) below the transport — set-level modes styled like
    /// `historyToggle` (accent when active, `fgDim` when off). Shown only while a set is running
    /// (a single-track play has no queue to shuffle/repeat).
    @ViewBuilder private var shuffleRepeatRow: some View {
        if sequencer.isRunning {
            HStack {
                shuffleToggle
                Spacer()
                repeatToggle
            }
            .padding(.horizontal, 44)
        }
    }

    private var shuffleToggle: some View {
        Button { sequencer.toggleShuffle() } label: {
            Image(systemName: "shuffle")
                .font(.subheadline)
                .foregroundStyle(sequencer.shuffleEnabled ? Theme.accent : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .help("Shuffle")
        .accessibilityLabel("Shuffle")
        .accessibilityValue(sequencer.shuffleEnabled ? "On" : "Off")
        .accessibilityIdentifier("np-shuffle")
    }

    private var repeatToggle: some View {
        Button { sequencer.cycleRepeatMode() } label: {
            Image(systemName: sequencer.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.subheadline)
                .foregroundStyle(sequencer.repeatMode == .off ? Theme.fgDim : Theme.accent)
        }
        .buttonStyle(.plain)
        .help(repeatHelp)
        .accessibilityLabel("Repeat")
        .accessibilityValue(repeatHelp)
        .accessibilityIdentifier("np-repeat")
    }

    /// off → "Repeat off"; all → "Repeat session"; one → "Repeat song" (matches the user's ask:
    /// toggle between repeat-song and repeat-session).
    private var repeatHelp: String {
        switch sequencer.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat session"
        case .one: return "Repeat song"
        }
    }

    private func togglePlayPause() {
        NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator, player: player)
    }

}

// MARK: - The collapsed strip (iOS)

/// The COLLAPSED Now Playing element (iOS, Levi 2026-07-18): a thin strip pinned at the
/// bottom of the home menu — current track title, ⏮ ⏯ ⏭, and a chevron to expand back to
/// the full deck. RootView owns the swap (the menu list takes the freed height); transport
/// routes through the SAME statics as the full panel, so backend ownership (Apple Music vs
/// PlayerEngine) and held-deck resume behave identically in both shapes.
struct NowPlayingMiniBar: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(AppModel.self) private var app
    /// Opens the queue-builder sheet (owned by RootView). Declared BEFORE `expand` so
    /// the existing trailing-closure call site keeps binding to `expand`.
    ///
    /// Without it this strip was a DEAD END for the builder: RootView picks the strip
    /// over the docked panel while `npCollapsed` (a persisted @AppStorage), the strip
    /// carried no ＋, and the `idleBuilderRow` that would have held one is unreachable
    /// because a set IS running. A user who had ever collapsed the deck had no way to
    /// add anything to a queue at all.
    var openBuilder: () -> Void
    /// The draft count, for the same badge the panel's ＋ carries.
    var draftCount: Int
    /// Flips the collapse state back off (owned by RootView's @AppStorage).
    var expand: () -> Void

    private var current: SetlistPlayer.Item? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        return sequencer.queue[sequencer.index]
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(current?.title ?? "—")
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.fg)
                .lineLimit(1)
                .accessibilityIdentifier("np-mini-title")
            Spacer(minLength: 8)
            // The current track's ♥ — the same reusable control, compact. Hidden while idle.
            if let current {
                FavoriteToggle(songId: current.id,
                               appleMusicId: app.songsById[current.id]?.appleMusicId,
                               font: .footnote)
                // SYNC mode with the deck COLLAPSED — the phone-in-pocket case the whole loop is
                // for. Same pair, same store, same rows; nothing here stops or skips playback.
                // `NowPlayingFeedbackButtons` resolves the scope itself and hides when the running
                // queue is not a recommendation, so the strip never offers to file a decision
                // against a tile the listener never opened.
                NowPlayingFeedbackButtons(font: .footnote)
            }
            Button(action: openBuilder) {
                Image(systemName: draftCount == 0 ? "plus" : "text.badge.plus")
                    .font(.footnote.weight(.semibold))
                    .overlay(alignment: .topTrailing) {
                        if draftCount > 0 {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .offset(x: 4, y: -3)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .help(draftCount == 0 ? "Build a queue" : "Build a queue — \(draftCount) waiting")
            .accessibilityLabel("Build a queue")
            .accessibilityValue(draftCount == 0 ? "Empty" : "\(draftCount) queued")
            // Same id as the panel/idle entries: exactly ONE of the three exists at a time.
            .accessibilityIdentifier("np-builder-open")
            Button { sequencer.skipPrevious() } label: {
                Image(systemName: "backward.fill").font(.footnote)
            }
            .accessibilityIdentifier("np-mini-previous")
            Button {
                NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator,
                                                player: player)
            } label: {
                Image(systemName: NowPlayingPanel.isPlayingNow(coordinator: coordinator,
                                                               player: player)
                        ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .accessibilityIdentifier("np-mini-playpause")
            Button { sequencer.skipNext() } label: {
                Image(systemName: "forward.fill").font(.footnote)
            }
            .accessibilityIdentifier("np-mini-next")
            Button(action: expand) {
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.fgDim)
                    .padding(.leading, 2)
                    // ≥44pt hit area (glyph unchanged) — a thumb-sized target on the
                    // strip's most-used control. Inside the label so the widened area
                    // belongs to the BUTTON, not the row.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("np-expand")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bgRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-mini-bar")
    }
}

// MARK: - The record player

/// A gold vinyl record spinning inside a blue (Theme.accent — the app's icon
/// color) record-player chassis with a fixed tonearm. The DISC (grooves + the
/// album-art label) rotates; the chassis and tonearm don't. Spin rate = one
/// revolution per 4-beat bar of the track's BPM (≈ real 33 RPM vinyl at ~133 BPM);
/// 33⅓ RPM when no BPM is known. Battery discipline: a `TimelineView(.animation)`
/// PAUSED whenever playback is paused — zero redraws while frozen. Pausing keeps
/// the disc AT its current angle (accumulated into `baseAngle`) and resuming
/// continues from there — a real platter doesn't snap back to 12 o'clock.
struct RecordPlayerView: View {
    let album: IndexAlbum?
    /// A direct cover URL that WINS over `album` — used for an Apple Music stream, whose
    /// AM-Local catalog album carries no `artCandidates`, so the MusicKit artwork URL captured
    /// at play time is the only cover. nil for every non-streaming track (uses `album`).
    var artworkURL: URL? = nil
    /// The now-playing song id — when it's a STUDIO performance item (no album), the PocketDJ icon
    /// is the record's center label instead of the generic disc placeholder.
    var studioId: String? = nil
    let bpm: Double?
    let spinning: Bool
    /// Play-position fraction 0…1 — the tonearm starts at the record's OUTER edge
    /// and tracks toward the center label in proportion to elapsed/length, like a
    /// real stylus. A closure (not a value) so the panel body doesn't re-render per
    /// tick: the arm samples it on its own throttled timeline below.
    var progress: () -> Double = { 0 }

    /// Rotation accumulated up to the last pause (degrees).
    @State private var baseAngle: Double = 0
    /// Wall-clock start of the CURRENT spin stretch; nil while paused.
    @State private var spinStart: Date?

    /// Revolutions per second: bpm/4 revolutions per minute, or 33⅓ RPM fallback.
    private var revsPerSecond: Double {
        let rpm = bpm.map { max(8, min(120, $0 / 4)) } ?? (100.0 / 3)
        return rpm / 60
    }

    private func angle(at date: Date) -> Double {
        let running = spinStart.map { date.timeIntervalSince($0) * revsPerSecond * 360 } ?? 0
        return (baseAngle + running).truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let disc = min(w * 0.78, h * 0.94)
            ZStack {
                // Chassis — the record player's outline, in the app's icon blue.
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.bgRaised)
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)

                // The spinning gold record (platter left-of-center, like a deck).
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { timeline in
                    goldRecord(diameter: disc)
                        .rotationEffect(.degrees(angle(at: timeline.date)))
                }
                .frame(width: disc, height: disc)
                .position(x: w * 0.44, y: h / 2)

                // The tonearm sweeps with the play position — sampled at 1 Hz on its
                // own timeline (the position clocks are non-observable by design),
                // paused with playback so a frozen deck costs zero redraws.
                TimelineView(.animation(minimumInterval: 1.0, paused: !spinning)) { _ in
                    tonearm(w: w, h: h, progress: progress())
                }
            }
        }
        .onAppear { if spinning { spinStart = Date() } }
        .onChange(of: spinning) { _, nowSpinning in
            if nowSpinning {
                spinStart = Date()                    // resume from the frozen angle
            } else {
                baseAngle = angle(at: Date())         // freeze in place
                spinStart = nil
            }
        }
        .accessibilityIdentifier("np-record")
    }

    /// The disc: gold vinyl with grooves, the album art as its center label.
    private func goldRecord(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(
                RadialGradient(colors: [Theme.accent2,
                                        Theme.accent2.opacity(0.75),
                                        Theme.accent2.opacity(0.9)],
                               center: .center,
                               startRadius: diameter * 0.18, endRadius: diameter * 0.52))
            // Grooves.
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .inset(by: diameter * (0.06 + CGFloat(i) * 0.055))
                    .strokeBorder(Color.black.opacity(0.22), lineWidth: 1)
            }
            // Center label = the album art (the PocketDJ icon for a studio item; placeholder
            // disc icon when neither is known).
            Group {
                if let artworkURL {
                    // Apple Music stream: the catalog artwork URL (our AM-Local album has none).
                    AsyncImage(url: artworkURL) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(Theme.bgOverlay)
                            .overlay(Image(systemName: "opticaldisc").foregroundStyle(Theme.fgDim))
                    }
                } else if let album {
                    CoverImage(album: album, corner: diameter * 0.21)
                } else if let studioId, StudioFactory.isStudioId(studioId) {
                    Image("PocketDJIcon").resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Theme.bgOverlay)
                        .overlay(Image(systemName: "opticaldisc")
                            .foregroundStyle(Theme.fgDim))
                }
            }
            .frame(width: diameter * 0.42, height: diameter * 0.42)
            .clipShape(Circle())
            // Spindle.
            Circle().fill(Theme.bg).frame(width: diameter * 0.045, height: diameter * 0.045)
        }
    }

    /// The tonearm, in the chassis blue: pivoted top-right, its stylus resting on
    /// the record's OUTER edge at 0:00 and sweeping toward the center label as the
    /// track plays (like a real stylus crossing the grooves). ~14° puts the tip on
    /// the outer edge; ~40° reaches the label; linear in `progress`.
    private func tonearm(w: CGFloat, h: CGFloat, progress: Double) -> some View {
        let sweep = 14.0 + 26.0 * min(1, max(0, progress))
        return ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
                .position(x: w * 0.88, y: h * 0.16)
            Capsule()
                .fill(Theme.accent)
                .frame(width: 3, height: h * 0.46)
                .rotationEffect(.degrees(sweep), anchor: .top)
                .position(x: w * 0.855, y: h * 0.40)
                .animation(.linear(duration: 1), value: sweep)
        }
    }
}

// MARK: - Add-search

/// Tokenized free-text search for the panel's add field — every whitespace token
/// must hit the name+artist haystack. Matches are ranked exact-name > name-prefix
/// > substring (so "Neon" surfaces the song titled Neon even in a ~100k catalog
/// where 25 earlier rows also contain the word), ties in catalog order, capped per
/// section. Pure + nonisolated: the panel runs it on a detached task over value
/// snapshots — never on the main actor, and never through BrowseState.results
/// (that would churn the Browser's memoized cache).
enum NowPlayingSearch {
    static let songCap = 25
    static let albumCap = 10

    static func songs(matching query: String, in songs: [IndexSong]) -> [IndexSong] {
        rank(query: query, items: songs, name: { $0.name }, artist: { $0.artist }, cap: songCap)
    }

    static func albums(matching query: String, in albums: [IndexAlbum]) -> [IndexAlbum] {
        rank(query: query, items: albums, name: { $0.name }, artist: { $0.artist }, cap: albumCap)
    }

    static func rank<T>(query: String, items: [T],
                        name: (T) -> String, artist: (T) -> String, cap: Int) -> [T] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(item: T, score: Int, order: Int)] = []
        for (i, item) in items.enumerated() {
            let itemName = name(item).lowercased()
            let hay = "\(itemName) \(artist(item).lowercased())"
            guard tokens.allSatisfy({ hay.contains($0) }) else { continue }
            let score = itemName == normalized ? 2 : (itemName.hasPrefix(normalized) ? 1 : 0)
            scored.append((item, score, i))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(cap)
            .map(\.item)
    }
}
