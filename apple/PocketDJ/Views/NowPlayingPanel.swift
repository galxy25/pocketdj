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
    @State private var detailSong: IndexSong?
    /// Debounced, off-main search results (see the `.task(id:)` below) — the body
    /// must NEVER scan the ~100k-song catalog itself.
    @State private var results: SearchResults = .empty
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

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
        #else
        .searchable(text: $query, placement: .sidebar, prompt: "Add songs or albums")
        #endif
        .searchFocused($searchFocused)
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
            NavigationStack {
                SongDetailView(song: song)
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

    // MARK: - Current track

    private var currentItem: SetlistPlayer.Item? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        return sequencer.queue[sequencer.index]
    }
    private var currentAlbum: IndexAlbum? {
        currentItem.flatMap { app.album(forSongId: $0.id) }
    }
    /// Spin rate source: the measured beat grid (preferred — the rip manifest's
    /// `beatGridBpm`), else the catalog BPM; nil ⇒ the view's 33⅓ RPM fallback.
    private var currentBpm: Double? {
        guard let id = currentItem?.id else { return nil }
        return burns.beatGrid(forSong: id)?.bpm ?? app.songsById[id]?.bpm
    }

    /// Unified play/pause across backends, routed by which engine OWNS the audio
    /// (`activeBackend`) — NOT by whether the deck's current item matches it. Keying off the
    /// item id let a stale deck (an unadopted manual jump) route the toggle to the idle
    /// PlayerEngine: the click was refused, and the ▶/⏸ glyph contradicted what was audible.
    /// When Apple Music is streaming it owns transport, period; every local/rip/burned path
    /// (which has NO coordinator backend) toggles PlayerEngine directly.
    private var isPlayingNow: Bool {
        coordinator.activeBackend == .appleMusic ? coordinator.isPlaying : player.isPlaying
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

    private var recordSize: CGFloat {
        #if os(macOS)
        return 150
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 170 : 210
        #endif
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
    }

    private func togglePlayPause() {
        // A RESTORED (held) deck has no audio loaded yet — the first ▶ resumes real playback
        // at the saved position (blindly toggling would hit the idle engine and be refused).
        if sequencer.isHeldForResume { sequencer.resumeFromHold(); return }
        if coordinator.activeBackend == .appleMusic { coordinator.togglePlayPause() }
        else { player.toggle() }
    }

    // MARK: - The deck row (scrolls away so Up Next can take the whole panel)

    @ViewBuilder private var deckSection: some View {
        Section {
            VStack(spacing: 8) {
                header
                if !compactHeight {
                    RecordPlayerView(album: currentAlbum, artworkURL: currentArtworkURL,
                                     studioId: currentItem?.id, bpm: currentBpm,
                                     spinning: isPlayingNow, progress: playProgress)
                        .frame(width: recordSize, height: recordSize * 0.82)
                        // The record is the door to the current track's metadata:
                        // long-press on iOS opens the detail DIRECTLY; macOS gets
                        // the natural right-click menu.
                        #if os(macOS)
                        .contextMenu {
                            Button { openCurrentSongDetail() } label: {
                                Label("Song details", systemImage: "info.circle")
                            }
                        }
                        #else
                        .onLongPressGesture(minimumDuration: 0.4) { openCurrentSongDetail() }
                        #endif
                }
                transport
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)
        }
    }

    private func openCurrentSongDetail() {
        detailSong = currentItem.flatMap { app.songsById[$0.id] }
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

    @ViewBuilder private var upNextSection: some View {
        // Snapshot ONCE per body: rows are identified by Item.uid (a song can repeat
        // in a set, and the queue can advance underneath an in-flight tap — a stale
        // positional offset would delete whatever shifted into the slot). Removal is
        // uid-verified in SetlistPlayer; the a11y ids stay positional for tests.
        let upcoming = sequencer.upcoming
        Section {
            ForEach(Array(upcoming.enumerated()), id: \.element.uid) { offset, item in
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
                sequencer.removeUpcoming(uids: Set(offsets.compactMap {
                    upcoming.indices.contains($0) ? upcoming[$0].uid : nil
                }))
            }
        } header: {
            HStack {
                Text("Up next (\(sequencer.upcoming.count))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
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
