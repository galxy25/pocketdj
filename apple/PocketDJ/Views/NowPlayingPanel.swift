import SwiftUI

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
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns

    @State private var query = ""
    @State private var albumsExpanded = true
    @State private var songsExpanded = true
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        VStack(spacing: 8) {
            header
            RecordPlayerView(album: currentAlbum, bpm: currentBpm, spinning: isPlayingNow)
                .frame(width: recordSize, height: recordSize * 0.82)
            transport
            listArea
            searchField
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing-panel")
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

    /// Unified play/pause across backends (CollectionSongRow's proven pattern): an
    /// Apple-Music-backed track toggles the coordinator; every local/rip/burned
    /// path toggles PlayerEngine directly (a burned file has NO coordinator
    /// backend, so `coordinator.togglePlayPause()` would silently no-op).
    private var isAppleMusicCurrent: Bool {
        currentItem.map { coordinator.isAppleMusicNowPlaying($0.id) } ?? false
    }
    private var isPlayingNow: Bool {
        isAppleMusicCurrent ? coordinator.isPlaying : player.isPlaying
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
        if isAppleMusicCurrent { coordinator.togglePlayPause() } else { player.toggle() }
    }

    // MARK: - Queue / search results

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var listArea: some View {
        List {
            if searching {
                searchResults
            } else {
                upNextSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
    }

    @ViewBuilder private var upNextSection: some View {
        Section {
            ForEach(Array(sequencer.upcoming.enumerated()), id: \.offset) { offset, item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                        Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        sequencer.removeUpcoming(atOffsets: IndexSet(integer: offset))
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("np-remove-\(offset)")
                }
                .listRowBackground(Theme.bg)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("np-queue-\(offset)")
            }
            .onMove { from, to in sequencer.moveUpcoming(fromOffsets: from, toOffset: to) }
            .onDelete { offsets in sequencer.removeUpcoming(atOffsets: offsets) }
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
    /// never a restart (see SetlistPlayer.appendToQueue).
    @ViewBuilder private var searchResults: some View {
        let albums = NowPlayingSearch.albums(matching: query, app: app)
        let songs = NowPlayingSearch.songs(matching: query, app: app)
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
    private func add(songs: [IndexSong]) {
        let items = songs.map {
            SetlistPlayer.Item(id: $0.id, title: $0.name, artist: $0.artist, lengthMs: $0.length)
        }
        sequencer.appendToQueue(items)
    }

    // MARK: - Search field (bottom)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.fgDim).font(.caption)
            TextField("Add songs or albums…", text: $query)
                .pocketField()
                .accessibilityIdentifier("np-search")
            if searching {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fgDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("np-search-clear")
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - The record player

/// A gold vinyl record spinning inside a blue (Theme.accent — the app's icon
/// color) record-player chassis with a fixed tonearm. The DISC (grooves + the
/// album-art label) rotates; the chassis and tonearm don't. Spin rate = one
/// revolution per 4-beat bar of the track's BPM (≈ real 33 RPM vinyl at ~133 BPM);
/// 33⅓ RPM when no BPM is known. Battery discipline: a `TimelineView(.animation)`
/// PAUSED whenever playback is paused — zero redraws while frozen (the angle is
/// computed statelessly from the wall clock, mirroring the Mix beat pulse).
struct RecordPlayerView: View {
    let album: IndexAlbum?
    let bpm: Double?
    let spinning: Bool

    /// Revolutions per second: bpm/4 revolutions per minute, or 33⅓ RPM fallback.
    private var revsPerSecond: Double {
        let rpm = bpm.map { max(8, min(120, $0 / 4)) } ?? (100.0 / 3)
        return rpm / 60
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
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (t * revsPerSecond * 360).truncatingRemainder(dividingBy: 360)
                    goldRecord(diameter: disc)
                        .rotationEffect(.degrees(spinning ? angle : 0))
                }
                .frame(width: disc, height: disc)
                .position(x: w * 0.44, y: h / 2)

                tonearm(w: w, h: h)
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
            // Center label = the album art (placeholder disc icon when unknown).
            Group {
                if let album {
                    CoverImage(album: album, corner: diameter * 0.21)
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

    /// Fixed tonearm on the right, in the chassis blue.
    private func tonearm(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
                .position(x: w * 0.88, y: h * 0.16)
            Capsule()
                .fill(Theme.accent)
                .frame(width: 3, height: h * 0.46)
                .rotationEffect(.degrees(24), anchor: .top)
                .position(x: w * 0.855, y: h * 0.40)
        }
    }
}

// MARK: - Add-search

/// Tokenized free-text search for the panel's add field — every whitespace token
/// must hit the name/artist haystack; ranked by hit count then catalog order,
/// capped per section so a ~100k-song catalog stays snappy. (Same shape as the
/// browse text match, kept separate from BrowseState.results so the panel never
/// churns the Browser's memoized result cache.)
enum NowPlayingSearch {
    static let songCap = 25
    static let albumCap = 10

    @MainActor
    static func songs(matching query: String, app: AppModel) -> [IndexSong] {
        rank(query: query, items: app.songs, haystack: { "\($0.name) \($0.artist)" }, cap: songCap)
    }

    @MainActor
    static func albums(matching query: String, app: AppModel) -> [IndexAlbum] {
        rank(query: query, items: app.albums, haystack: { "\($0.name) \($0.artist)" }, cap: albumCap)
    }

    static func rank<T>(query: String, items: [T], haystack: (T) -> String, cap: Int) -> [T] {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(item: T, hits: Int, order: Int)] = []
        for (i, item) in items.enumerated() {
            let hay = haystack(item).lowercased()
            var hits = 0
            for token in tokens {
                guard hay.contains(token) else { hits = 0; break }   // ALL tokens must match
                hits += 1
            }
            if hits > 0 { scored.append((item, hits, i)) }
        }
        return scored
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
            .prefix(cap)
            .map(\.item)
    }
}
