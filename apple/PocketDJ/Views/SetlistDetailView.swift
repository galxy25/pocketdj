import SwiftUI

/// A navigation value that opens a setlist AND (optionally) autostarts Play-All. Used by
/// the repurposed ▶ Play / 🔀 Shuffle on playlists/pockets, which push the reusable
/// "Now Playing" setlist and want it to begin immediately. The plain `Setlist`
/// destination (history rows, index-play) stays non-autoplay.
struct SetlistLaunch: Hashable, Codable {
    let setlistId: String
    let autoplay: Bool
}

/// The FROZEN, read-only performance produced by ▶ Play. "Spin these tracks, in this
/// order." Each track carries its own snapshot (artist/name/bpm/camelot/length) so it
/// reads standalone even if the catalog or pockets change. Mirrors the PWA's
/// `SetlistView.tsx`: grouped-by-chapter sections, a provenance badge per track, and
/// per-track performer notes.
struct SetlistDetailView: View {
    @Environment(CollectionsStore.self) private var collections
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    // Feature 3 — Play All sources (the sequencer crosses all four into the player path).
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settings
    let setlistId: String
    /// When true (a ▶ Play / 🔀 Shuffle launch), start Play-All on first appear.
    var autoplay: Bool = false
    /// The shared navigation stack — lets a track row open its song's detail on tap.
    @Binding var path: NavigationPath
    /// One-shot guard so the autostart fires exactly once per view lifetime.
    @State private var didAutostart = false

    @State private var nameDraft = ""
    @State private var renaming = false
    @State private var noteEditing: Int?      // track index being edited
    @State private var noteDraft = ""
    @State private var addingNote = false      // top-level "Add note" composer
    @State private var addNoteDraft = ""
    @State private var ripBurn = CollectionRipBurnController()
    /// The sequential Play-All sequencer (Feature 3) — built lazily from the env stores on
    /// first Play, mirroring the `ripBurn` controller pattern.
    @State private var setlistPlayer: SetlistPlayer?

    private var setlist: Setlist? { collections.setlist(setlistId) }

    /// Whether Play All is currently running (drives the toolbar glyph + edit gating).
    private var isPlaying: Bool { setlistPlayer?.isRunning == true }

    /// Build (once) the sequencer from the environment stores.
    private func ensurePlayer() -> SetlistPlayer {
        if let p = setlistPlayer { return p }
        let p = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        // Item 7 — feed the sequencer the live device/cloud mode (read fresh each track, so a
        // mode-flip mid-set takes effect on the NEXT track).
        p.playbackMode = { [weak settings] in settings?.playbackMode ?? .cloud }
        setlistPlayer = p
        return p
    }

    /// The ordered, playable tracks (cue/empty rows stripped), carrying title + artist so
    /// the now-playing label + coordinator.play have what they need.
    private func playableItems(_ setlist: Setlist) -> [SetlistPlayer.Item] {
        setlist.tracks
            .filter { $0.isText != true && !$0.songId.isEmpty }
            .map { SetlistPlayer.Item(id: $0.songId, title: $0.name, artist: $0.artist, lengthMs: $0.shownMs) }
    }

    var body: some View {
        Group {
            if let setlist {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spin these tracks, in this order.")
                                .font(.caption).foregroundStyle(Theme.fgDim)
                            HStack(spacing: 14) {
                                stat(Fmt.duration(setlist.totalMs), "total")
                                stat("\(setlist.tracks.count)", setlist.tracks.count == 1 ? "track" : "tracks")
                                if setlist.generatedAt > 0 {
                                    Text(Date(timeIntervalSince1970: setlist.generatedAt / 1000),
                                         style: .date)
                                        .font(.caption2).foregroundStyle(Theme.fgDim)
                                }
                            }
                            .accessibilityIdentifier("setlist-stats")
                        }
                    }

                    Section {
                        ForEach(Array(setlist.tracks.enumerated()), id: \.offset) { idx, track in
                            trackRow(track, index: idx)
                                .contextMenu {   // right-click on macOS, tap-and-hold on iOS
                                    Button(role: .destructive) {
                                        collections.removeSetlistTrack(setlistId: setlistId, at: idx)
                                    } label: { Label("Delete from set list", systemImage: "trash") }
                                    .accessibilityIdentifier("setlist-delete-\(idx)")
                                    .disabled(isPlaying)
                                }
                        }
                        // Disable reorder/delete while Play-All runs so the sequencer's queue
                        // index can't desync from the on-screen rows (Feature 3).
                        .onMove { from, to in
                            guard !isPlaying else { return }
                            collections.moveSetlistTracks(setlistId: setlistId, from: from, to: to)
                        }
                        .onDelete { offsets in
                            guard !isPlaying else { return }
                            // Remove highest-index first so earlier offsets stay valid.
                            offsets.sorted(by: >).forEach { collections.removeSetlistTrack(setlistId: setlistId, at: $0) }
                        }
                    } header: {
                        chapterLegend(setlist.tracks)
                    }
                }
                .navigationTitle(setlist.name ?? "Set list")
            } else {
                ContentUnavailableView("Set list gone", systemImage: "waveform.slash",
                                       description: Text("This set list no longer exists."))
            }
        }
        .accessibilityIdentifier("setlist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
        // Feature 3 — tear down Play-All on REAL teardown only (a setlist switch), NOT on a
        // transient onDisappear (SwiftUI fires that on a navigation push too).
        .onChange(of: setlistId) { setlistPlayer?.stop() }
        // Item 4 — autostart Play-All when this view was opened from a ▶ Play / 🔀 Shuffle.
        .task {
            guard autoplay, !didAutostart, let setlist else { return }
            didAutostart = true
            ensurePlayer().play(playableItems(setlist))
        }
        // CRITIC-I — Shuffle (or re-Play) WHILE this setlist is on screen bumps the reusable
        // "Now Playing" revision. Re-derive the playable items from the freshly-read setlist
        // and restart so the new order plays. The bump-only-on-explicit-playNow contract +
        // the stop()→play() pair guards against an infinite restart loop.
        .onChange(of: collections.nowPlayingRevision) {
            guard autoplay, setlistId == nowPlayingSetlistId, let setlist = collections.setlist(setlistId) else { return }
            setlistPlayer?.stop()
            ensurePlayer().play(playableItems(setlist))
        }
        // CRITIC-D — device-mode set with no on-device files anywhere: a one-shot transient
        // alert so the DJ knows nothing was playable on-device (no silent dead-Play).
        .alert("No burned files", isPresented: Binding(
            get: { setlistPlayer?.deviceQueueUnplayable == true },
            set: { if !$0 { setlistPlayer?.clearDeviceUnplayable() } })) {
            Button("OK", role: .cancel) { setlistPlayer?.clearDeviceUnplayable() }
        } message: {
            Text("Device playback is on, but none of these tracks are burned to this device. Burn them, or switch to cloud streaming.")
        }
        .toolbar {
            if let setlist {
                setlistToolbar(setlist)
            }
        }
        .alert("Add note", isPresented: $addingNote) {
            TextField("Note (mic break, sample, cue…)", text: $addNoteDraft)
            Button("Add") {
                let n = addNoteDraft.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { collections.addSetlistNote(n, toSetlist: setlistId) }
                addNoteDraft = ""
            }
            Button("Cancel", role: .cancel) { addNoteDraft = "" }
        } message: {
            Text("Added to the end — drag it into place with Edit.")
        }
        .alert("Rename set list", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renameSetlist(setlistId, n) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Track note", isPresented: Binding(get: { noteEditing != nil }, set: { if !$0 { noteEditing = nil } })) {
            TextField("Performer note…", text: $noteDraft)
            Button("Save") {
                if let i = noteEditing {
                    let n = noteDraft.trimmingCharacters(in: .whitespaces)
                    collections.setSetlistTrackNote(setlistId, trackIndex: i, note: n.isEmpty ? nil : n)
                }
                noteEditing = nil
            }
            Button("Clear", role: .destructive) {
                if let i = noteEditing { collections.setSetlistTrackNote(setlistId, trackIndex: i, note: nil) }
                noteEditing = nil
            }
            Button("Cancel", role: .cancel) { noteEditing = nil }
        }
    }

    // MARK: Toolbar

    /// The setlist toolbar. On **iOS in play mode** the transport (⏮ · ⏯ · ⏭) is CENTERED in
    /// the nav bar (`.principal`) and every secondary action — including Edit — collapses into a
    /// single ••• menu, so the bar reads as a clean music transport. Otherwise (iOS idle, and
    /// macOS always) it's the flat trailing layout (play/stop · prev/next while running · the
    /// secondary actions). macOS has no `.principal` nav bar, so it keeps the flat row.
    @ToolbarContentBuilder
    private func setlistToolbar(_ setlist: Setlist) -> some ToolbarContent {
        #if os(iOS)
        if isPlaying {
            // The centered cluster already carries play/PAUSE — no separate ⏹ Stop button
            // (play/pause is sufficient). Pausing halts the set; leave the screen to end it.
            ToolbarItem(placement: .principal) { transportCluster }
            ToolbarItem(placement: .topBarTrailing) { PlaybackModeToggle() }
            ToolbarItem(placement: .topBarTrailing) { overflowMenu(setlist) }
        } else {
            ToolbarItem(placement: .topBarTrailing) { startStopButton(setlist) }
            ToolbarItem(placement: .topBarTrailing) { PlaybackModeToggle() }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton().accessibilityIdentifier("setlist-edit-order")
            }
            ToolbarItem(placement: .topBarTrailing) { overflowMenu(setlist) }
        }
        #else
        ToolbarItem(placement: .primaryAction) { PlaybackModeToggle() }
        if isPlaying {
            ToolbarItem(placement: .primaryAction) {
                Button { setlistPlayer?.skipPrevious() } label: { Image(systemName: "backward.fill") }
                    .help("Previous track").accessibilityIdentifier("setlist-play-prev")
            }
        }
        ToolbarItem(placement: .primaryAction) { startStopButton(setlist) }
        if isPlaying {
            ToolbarItem(placement: .primaryAction) {
                Button { setlistPlayer?.skipNext() } label: { Image(systemName: "forward.fill") }
                    .help(setlistPlayer?.waitingForLive == true
                          ? "Skip to the next track (the current one is live)" : "Next track")
                    .accessibilityIdentifier("setlist-play-next")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { addNoteDraft = ""; addingNote = true } label: { Image(systemName: "text.badge.plus") }
                .help("Add a note between tracks").accessibilityIdentifier("setlist-add-note")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forSetlist: setlistId) }, noun: "set list")
            } label: { Image(systemName: "arrow.down.circle") }
                .help("Rip or burn this set list").accessibilityIdentifier("setlist-ripburn-menu")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { nameDraft = setlist.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }
                .accessibilityIdentifier("setlist-rename")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) { collections.deleteSetlist(setlist.id); dismiss() } label: { Image(systemName: "trash") }
                .accessibilityIdentifier("setlist-delete")
        }
        #endif
    }

    /// The centered ⏮ · ⏯ · ⏭ transport shown in the nav bar while a set plays (iOS). The middle
    /// toggles play/pause on whichever backend is active (Apple Music streaming via the
    /// coordinator, else the rip/local `PlayerEngine`); prev/next step the SET.
    private var transportCluster: some View {
        HStack(spacing: 30) {
            Button { setlistPlayer?.skipPrevious() } label: { Image(systemName: "backward.fill") }
                .help("Previous track").accessibilityIdentifier("setlist-play-prev")
            Button { toggleTransport() } label: {
                Image(systemName: transportIsPlaying ? "pause.fill" : "play.fill")
            }
            .help(transportIsPlaying ? "Pause" : "Play").accessibilityIdentifier("setlist-playpause")
            Button { setlistPlayer?.skipNext() } label: { Image(systemName: "forward.fill") }
                .help(setlistPlayer?.waitingForLive == true
                      ? "Skip to the next track (the current one is live)" : "Next track")
                .accessibilityIdentifier("setlist-play-next")
        }
        .font(.title3)
        .tint(Theme.accent)
    }

    /// PLAY / PAUSE the set — no dedicated ⏹ Stop (play/pause is sufficient). Idle ⇒ ▶ starts
    /// the set; while running it pauses/resumes the active backend (the same toggle as the
    /// centered cluster). The set ends by finishing or leaving the screen (which stops it).
    /// This is the idle-iOS button and the macOS toolbar's sole transport.
    private func startStopButton(_ setlist: Setlist) -> some View {
        Button {
            if isPlaying { toggleTransport() }
            else { ensurePlayer().play(playableItems(setlist)) }
        } label: {
            Image(systemName: isPlaying && transportIsPlaying ? "pause.fill" : "play.fill")
        }
        .help(isPlaying ? (transportIsPlaying ? "Pause" : "Resume") : "Play the set list in order")
        .disabled(!isPlaying && playableItems(setlist).isEmpty)
        .accessibilityIdentifier("setlist-play")
    }

    /// The ••• overflow gathering the secondary actions so the play-mode bar stays clean. Stop
    /// is NOT here (it's the play button's place — see startStopButton). Rip and Burn are
    /// SEPARATE flat items, not a nested submenu. While playing it carries a disabled Edit entry
    /// (reordering mid-set would desync the sequencer's queue index).
    private func overflowMenu(_ setlist: Setlist) -> some View {
        Menu {
            Button { addNoteDraft = ""; addingNote = true } label: {
                Label("Add note", systemImage: "text.badge.plus")
            }.accessibilityIdentifier("setlist-add-note")
            // Rip + Burn rendered as TWO separate top-level items (the buttons render flat — they
            // were designed to sit directly in a Menu), not collapsed behind a "Rip / Burn" submenu.
            CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forSetlist: setlistId) }, noun: "set list")
            Button { nameDraft = setlist.name ?? ""; renaming = true } label: {
                Label("Rename", systemImage: "pencil")
            }.accessibilityIdentifier("setlist-rename")
            #if os(iOS)
            if isPlaying {
                Button {} label: { Label("Edit order", systemImage: "arrow.up.arrow.down") }
                    .disabled(true).accessibilityIdentifier("setlist-edit-order")
            }
            #endif
            Divider()
            Button(role: .destructive) { collections.deleteSetlist(setlist.id); dismiss() } label: {
                Label("Delete set list", systemImage: "trash")
            }.accessibilityIdentifier("setlist-delete")
        } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityIdentifier("setlist-overflow")
    }

    /// Play/pause state for the centered transport — mirrors whichever backend is active.
    private var transportIsPlaying: Bool {
        coordinator.activeBackend == .appleMusic ? coordinator.isPlaying : player.isPlaying
    }

    /// Toggle play/pause on the active backend (Apple Music streaming else the rip/local engine).
    private func toggleTransport() {
        if coordinator.activeBackend == .appleMusic { coordinator.togglePlayPause() }
        else { player.toggle() }
    }

    /// The album behind a frozen track, for its cover-art thumbnail — resolved from
    /// the live catalog by the snapshot's songId (nil if the song is gone, so the row
    /// still reads from the snapshot with a graceful placeholder).
    private func album(for track: SetlistTrack) -> IndexAlbum? {
        app.songsById[track.songId]?.albumId.flatMap { app.albumsById[$0] }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
            Text(label).font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder
    private func trackRow(_ track: SetlistTrack, index: Int) -> some View {
        if track.isText == true {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim).frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Badge("cue", color: Theme.fgDim)
                        Text(track.name).foregroundStyle(Theme.fg).italic()
                    }
                    noteButton(track, index: index)
                }
            }
            .accessibilityIdentifier("setlist-track-\(index)")
        } else {
            // The SHARED song row, fed by the frozen snapshot, with the setlist-only
            // bits — sequence # · source/sequence badges · per-track note — composed in.
            let song = app.songsById[track.songId]
            let rowData = SongRowData(track: track, song: song, album: album(for: track))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        .frame(width: 22, alignment: .trailing)
                    SongRowView(
                        data: rowData,
                        trailing: AnyView(provenanceBadges(track))
                    )
                    // Tap-to-open the song's detail (when its catalog song still exists). A
                    // row-level .onTapGesture — NOT a wrapping NavigationLink — so the row's
                    // ▶/⤓ transport buttons keep intercepting their own taps (see BrowseView).
                    .contentShape(Rectangle())
                    .onTapGesture { if let song { path.append(song) } }
                    .accessibilityElement(children: .contain)
                }
                // Inline player below the row when this track's song is the one playing.
                InlinePlayerSlot(songId: rowData.songId).padding(.leading, 30)
                noteButton(track, index: index).padding(.leading, 30)
            }
            .accessibilityIdentifier("setlist-track-\(index)")
        }
    }

    /// The setlist-only provenance column (source + chapter), shown inside the shared
    /// row to the left of the transport placeholders.
    @ViewBuilder
    private func provenanceBadges(_ track: SetlistTrack) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            sourceBadge(track.source)
            // Show the chapter only when it's a real, named one (not the default).
            if let seq = track.sequenceName, !seq.isEmpty, seq != "Default" {
                Badge(seq, color: Theme.fgDim)
            }
        }
    }

    @ViewBuilder
    private func noteButton(_ track: SetlistTrack, index: Int) -> some View {
        Button {
            noteDraft = track.note ?? ""
            noteEditing = index
        } label: {
            Text(track.note.map { "📝 \($0)" } ?? "＋ note")
                .font(.caption2).foregroundStyle(track.note == nil ? Theme.fgDim : Theme.accent2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setlist-note-\(index)")
    }

    // Provenance badge — shown only for non-default placements. An explicitly-placed
    // track gets none (its explicit-LYRICS "E" already shows on the left of the row).
    @ViewBuilder
    private func sourceBadge(_ source: TrackSource) -> some View {
        switch source {
        case .explicit: EmptyView()
        case .pocket:   Badge("pocket", color: Theme.accent2)
        case .autofill: Badge("↔ bridge", color: Theme.accent)
        }
    }

    // MARK: Chapter legend

    /// A single flat, reorderable track list (so `.onMove`/`.onDelete` indices map
    /// straight to `setlist.tracks`). The per-row `sequenceName` badge still names each
    /// track's chapter; this header summarizes which chapters are present + the total.
    @ViewBuilder
    private func chapterLegend(_ tracks: [SetlistTrack]) -> some View {
        let names = orderedChapterNames(tracks)
        HStack {
            Text(names.count <= 1 ? (names.first ?? "Set") : names.joined(separator: " · "))
            Spacer()
            Text("\(tracks.count) · \(Fmt.duration(tracks.reduce(0) { $0 + $1.shownMs }))")
                .foregroundStyle(Theme.fgDim)
        }
        .accessibilityIdentifier("setlist-chapter-legend")
    }

    private func orderedChapterNames(_ tracks: [SetlistTrack]) -> [String] {
        var out: [String] = []
        for t in tracks {
            let name = t.sequenceName?.isEmpty == false ? t.sequenceName! : "Set"
            if out.last != name && !out.contains(name) { out.append(name) }
        }
        return out
    }
}

/// A tiny pill chip matching the PWA's `pdj-badge`.
private struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
