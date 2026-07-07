import SwiftUI

// MARK: - Studio ▸ Cues (spec §9)
//
// Up to 8 cue points per indexed track: pick a track, see its waveform timeline with the cue
// markers + a live playhead, then tap a filled slot to PLAY FROM that cue or an empty slot to
// SET one at the current playhead. The store (`StudioStore`) enforces the 8-slot cap; this view
// maps the slots 1:1 onto a fixed 8-button grid with STABLE per-slot colors (slot index = color
// index, so "the yellow cue" stays yellow across renames/nudges).
//
// Playback routing (the load-bearing ladder — each rung closes a reviewed defect):
//   1. BURNED first: a local file seeks sample-exactly. We hand `playLocalFile` the song's TRUE
//      `startMs` (shared analog album offset) and the cue as `atMs` SEPARATELY — the helper
//      computes the absolute seek (`RipsStore.cueSeekMs`) while `NowPlaying.startMs` keeps
//      anchoring boundary math on the song's real start. Pre-adding the cue into `startMs`
//      would push a shared-album track's end boundary INTO the next song on the side.
//   2. STREAMING via the coordinator: only when `cueSeekSupported(for:)` — a song whose rip is
//      still in flight resolves to live HLS, which cannot seek, so its filled slots are shown
//      in a disabled state with a "still ripping" hint instead of silently playing from 0:00.
//   3. BACKSTOP: the check-then-play race (rip went live between the check and the play) is
//      reported after the fact by `ripProvider.lastCueDropped` / a live `nowPlaying` — we show
//      a one-line notice that the cue was dropped rather than pretending it applied.
struct StudioCuesView: View {
    @Environment(AppModel.self) private var app
    @Environment(StudioStore.self) private var studio
    @Environment(BurnStore.self) private var burns
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator

    /// Track picker query. Cleared on selection so the results list collapses back to the pane.
    @State private var searchText = ""
    /// The selected track — @State ONLY (per spec: "recent selection remembered in @State
    /// only"): it survives sub-tab hops while the shell keeps this view alive, and resets with
    /// the view. Nothing is persisted; the cues themselves live in the studio document.
    @State private var selectedSongId: String?
    /// One-line after-the-fact notice: the cue could not be applied (rip went live between the
    /// seekability check and the play — routing rule 3). Cleared on the next play / selection.
    @State private var cueNotice: String?

    // Rename-alert state (slot being renamed + the draft text).
    @State private var renameSlot: Int?
    @State private var renameText = ""
    @State private var showRename = false

    /// The 8 stable slot colors (slot index = palette index — `StudioCue.slot` doubles as the
    /// color index per the model doc). Distinct hues, all readable on the night-sky background.
    static let slotColors: [Color] = [
        Color(hex: 0xff6e8a),   // 1 red    (Theme.danger)
        Color(hex: 0xffa94d),   // 2 orange
        Color(hex: 0xffce6e),   // 3 gold   (Theme.accent2)
        Color(hex: 0x6ee7a8),   // 4 green
        Color(hex: 0x5ad1e6),   // 5 teal
        Color(hex: 0x6ea8ff),   // 6 blue   (Theme.accent)
        Color(hex: 0xa78bfa),   // 7 purple
        Color(hex: 0xf472b6),   // 8 pink
    ]
    static func slotColor(_ slot: Int) -> Color {
        slotColors[max(0, min(slot, slotColors.count - 1))]
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }
    private var selectedSong: IndexSong? { selectedSongId.flatMap { app.songsById[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Search artist or title", text: $searchText)
                    .pocketField()
                    .accessibilityIdentifier("cue-search")

                if !query.isEmpty {
                    resultsList
                } else if let song = selectedSong {
                    selectedPane(song)
                } else {
                    emptyState
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .onChange(of: selectedSongId) { cueNotice = nil }
        // Rename lives in an alert (works identically on iPhone/iPad/macOS, no custom sheet).
        // Blank collapses to nil in the store, restoring the slot-number default label.
        .alert("Rename Cue", isPresented: $showRename) {
            TextField("Cue name", text: $renameText)
                .accessibilityIdentifier("cue-rename-field")
            Button("Save") {
                if let slot = renameSlot, let id = selectedSongId {
                    studio.renameCue(songId: id, slot: slot, name: renameText)
                }
            }
            .accessibilityIdentifier("cue-rename-save")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A blank name goes back to the slot number.")
        }
    }

    // MARK: Track picker

    /// Search matches over the whole catalog, BURNED FIRST (burned tracks are the ones cues
    /// play sample-exactly, so they belong at the top), then artist/title. With an empty query
    /// the "browse" default is the useful subset — tracks that already have cues plus burned
    /// tracks — instead of dumping the entire multi-thousand-song catalog. Capped for render
    /// cost; the search field narrows past the cap.
    private func matches() -> [IndexSong] {
        let all = app.songsById.values
        let filtered: [IndexSong]
        if query.isEmpty {
            let cued = Set(studio.cues.map(\.songId))
            let burnedSet = Set(burns.readyBurnedIds(in: all.map(\.id)))
            filtered = all.filter { cued.contains($0.id) || burnedSet.contains($0.id) }
        } else {
            filtered = all.filter {
                $0.name.lowercased().contains(query) || $0.artist.lowercased().contains(query)
            }
        }
        // Burned-first ordering via the burn ledger (`readyBurnedIds` = state check, no disk IO —
        // cheap enough per keystroke; actual on-disk existence is re-checked at play time).
        let burned = Set(burns.readyBurnedIds(in: filtered.map(\.id)))
        let sorted = filtered.sorted { a, b in
            let ba = burned.contains(a.id), bb = burned.contains(b.id)
            if ba != bb { return ba }
            if a.artist.lowercased() != b.artist.lowercased() {
                return a.artist.lowercased() < b.artist.lowercased()
            }
            return a.name.lowercased() < b.name.lowercased()
        }
        return Array(sorted.prefix(120))
    }

    @ViewBuilder private var resultsList: some View {
        let items = matches()
        if items.isEmpty {
            Text("No tracks match “\(searchText)”.")
                .font(.caption).foregroundStyle(Theme.fgDim)
        } else {
            // LazyVStack (not List) — this lives inside the tab's ScrollView; a nested List
            // would fight it for scroll gestures and collapse to zero height.
            LazyVStack(spacing: 2) {
                ForEach(items) { song in
                    trackRow(song)
                }
            }
        }
    }

    private func trackRow(_ song: IndexSong) -> some View {
        let cueCount = studio.cues(forSong: song.id).count
        let isBurned = !burns.readyBurnedIds(in: [song.id]).isEmpty
        return Button {
            selectedSongId = song.id
            searchText = ""      // collapse results → the selected pane shows
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Spacer()
                if cueCount > 0 {
                    Label("\(cueCount)", systemImage: "flag.fill")
                        .font(.caption2).foregroundStyle(Theme.accent2)
                        .labelStyle(.titleAndIcon)
                }
                if isBurned {
                    // Same glyph Storage/Burn use for on-device music.
                    Image(systemName: "opticaldisc")
                        .font(.caption).foregroundStyle(Theme.accent)
                        .accessibilityLabel("On device")
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgRaised))
        .accessibilityIdentifier("cue-track-row-\(song.id)")
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Cue Points", systemImage: "flag")
        } description: {
            Text("Search for a track above, then tap an empty slot to drop a cue at the "
                 + "playhead (or at 0:00 when nothing is playing) — up to 8 per track. "
                 + "Tap a filled slot to play from that exact spot. Burned tracks jump "
                 + "sample-exact; streaming tracks need a finished rip first. Long-press a "
                 + "cue to rename, nudge, or delete it.")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Selected-track pane

    @ViewBuilder private func selectedPane(_ song: IndexSong) -> some View {
        // Resolved ONCE per body pass: `localURL` stats the disk (and briefly opens a security
        // scope) — the same per-render existence check CollectionSongRow performs.
        let isBurned = burns.localURL(forSong: song.id) != nil
        // Rule 2 gate — burned files always seek; otherwise ask the coordinator whether a cue
        // offset would actually be APPLIED right now (Apple Music ready, or a durable S3 mp3).
        let seekable = isBurned || coordinator.cueSeekSupported(for: song)
        let cues = studio.cues(forSong: song.id)
        let durMs = displayDurationMs(song)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Spacer()
                if isBurned {
                    Label("On device", systemImage: "opticaldisc")
                        .font(.caption2).foregroundStyle(Theme.accent)
                }
                Text(Fmt.duration(song.length))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }

            CueTimeline(song: song, durationMs: durMs, cues: cues, isBurned: isBurned)
                .frame(height: 64)

            // Transport: play/pause + scrub, so you can audition the track and drop cues anywhere
            // without listening start-to-finish. Starting playback routes through `startPlayback`
            // (burned→local, else streaming) exactly like a cue tap.
            CueTransport(song: song, durationMs: durMs, seekable: seekable) { atMs in
                startPlayback(song: song, atMs: atMs)
            }

            if !seekable {
                // Rule 2's disabled-state hint: live/in-flight (or not-yet-started) rips
                // resolve to HLS, which cannot seek — playing a cue would silently start at
                // 0:00, so the filled slots are dimmed and guarded instead.
                Label("Still ripping — cue playback unlocks when this track’s rip completes (or after you burn it).",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("cue-seek-hint")
            }
            if let cueNotice {
                // Rule 3's backstop: the cue was dropped AFTER the play (check-then-play race).
                Label(cueNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("cue-dropped-notice")
            }

            slotGrid(song: song, cues: cues, seekable: seekable)

            Text("Play & scrub to find a spot, then tap an empty slot to drop a cue at the playhead · long-press a cue for rename / nudge / delete.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.bgRaised))
    }

    /// The timeline denominator: catalog length first (always present for indexed songs and
    /// stable), then the manifest's measured duration, then 1 to keep marker math finite.
    private func displayDurationMs(_ song: IndexSong) -> Int {
        if let len = song.length, len > 0 { return len }
        if let d = rips.manifest[song.id]?.durationMs, d > 0 { return d }
        return 1
    }

    // MARK: Slot grid

    /// Adaptive grid: 8 across on wide (macOS/iPad), wrapping to 4×2 on iPhone portrait —
    /// all in-content (never toolbar-only), per the iPhone toolbar-overflow lesson.
    private func slotGrid(song: IndexSong, cues: [StudioCue], seekable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 160), spacing: 8)], spacing: 8) {
            ForEach(0..<StudioCue.maxSlots, id: \.self) { slot in
                slotCell(slot: slot, song: song,
                         cue: cues.first { $0.slot == slot }, seekable: seekable)
            }
        }
    }

    @ViewBuilder
    private func slotCell(slot: Int, song: IndexSong, cue: StudioCue?, seekable: Bool) -> some View {
        let color = Self.slotColor(slot)
        if let cue {
            // FILLED — tap plays from the cue. When un-seekable we keep the button ENABLED but
            // guard the tap to (re)surface the hint: `.disabled(true)` would also kill the
            // long-press/right-click context menu, locking the user out of rename/nudge/delete
            // exactly when they can't play — the dimmed face + hint carries the disabled look.
            Button {
                if seekable {
                    play(cue: cue, song: song)
                } else {
                    cueNotice = "Can’t jump to this cue yet — the track is still ripping."
                }
            } label: {
                VStack(spacing: 3) {
                    Text(cue.name ?? "Cue \(slot + 1)")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    Text(Self.stamp(cue.positionMs))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5))
                .opacity(seekable ? 1 : 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cue-slot-\(slot)")
            .contextMenu { slotMenu(slot: slot, song: song) }
        } else {
            // EMPTY — tap sets a cue at the current playhead (0:00 when nothing is playing).
            Button {
                let pos = playheadMs(forSong: song.id) ?? 0
                _ = studio.setCue(songId: song.id, slot: slot, positionMs: pos)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                    Text("Set").font(.caption2)
                }
                .foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cue-slot-\(slot)")
        }
    }

    /// Per-slot context menu (long-press on iOS, right-click on macOS). Nudge is ±100 ms per
    /// tap (store-debounced save, so machine-gunning the item is cheap). "Set to playhead" is
    /// disabled when this song isn't the one playing — silently re-setting a cue to 0:00 would
    /// destroy a placed cue.
    @ViewBuilder private func slotMenu(slot: Int, song: IndexSong) -> some View {
        Button {
            renameSlot = slot
            renameText = studio.cue(songId: song.id, slot: slot)?.name ?? ""
            showRename = true
        } label: { Label("Rename", systemImage: "pencil") }
            .accessibilityIdentifier("cue-rename-\(slot)")

        Button {
            studio.nudgeCue(songId: song.id, slot: slot, deltaMs: -100)
        } label: { Label("Nudge −100 ms", systemImage: "gobackward.minus") }
            .accessibilityIdentifier("cue-nudge-back-\(slot)")

        Button {
            studio.nudgeCue(songId: song.id, slot: slot, deltaMs: 100)
        } label: { Label("Nudge +100 ms", systemImage: "goforward.plus") }
            .accessibilityIdentifier("cue-nudge-fwd-\(slot)")

        Button {
            if let pos = playheadMs(forSong: song.id) {
                _ = studio.setCue(songId: song.id, slot: slot, positionMs: pos)
            }
        } label: { Label("Set to playhead", systemImage: "flag") }
            .disabled(playheadMs(forSong: song.id) == nil)
            .accessibilityIdentifier("cue-set-playhead-\(slot)")

        Divider()

        Button(role: .destructive) {
            studio.removeCue(songId: song.id, slot: slot)
        } label: { Label("Delete", systemImage: "trash") }
            .accessibilityIdentifier("cue-delete-\(slot)")
    }

    // MARK: Playback (routing rules 1–3, see the header comment)

    private func play(cue: StudioCue, song: IndexSong) {
        startPlayback(song: song, atMs: cue.positionMs)
    }

    /// Start `song` at a song-relative offset (ms) — shared by cue-slot taps (`atMs = cue.positionMs`)
    /// and the transport's play button (`atMs = 0` from the top, or the scrubbed position). Routing
    /// rules 1–3 from the header comment.
    private func startPlayback(song: IndexSong, atMs: Int) {
        cueNotice = nil
        // (1) BURNED first — sample-exact. `startMs` = the song's TRUE start (shared analog
        // album offset, nil for digital); the cue rides SEPARATELY as `atMs` so boundary math
        // still anchors on the song's start (never pre-add the cue into startMs). The end
        // boundary is only needed for shared analog files (non-nil startMs is exactly that
        // signal — SetlistPlayer.sharedFileEndBoundaryMs doctrine): without it the natural
        // end event would only fire at the end of the WHOLE album side.
        if let res = burns.localURLForPlayback(forSong: song.id) {
            let startMs = burns.startMs(forSong: song.id)
            let endBoundaryMs: Int? = {
                guard let startMs, let len = song.length, len > 0 else { return nil }
                return startMs + len
            }()
            playLocalFile(res.url, songId: song.id, title: song.name, artist: song.artist,
                          startMs: startMs, rips: rips, player: player,
                          endBoundaryMs: endBoundaryMs, atMs: atMs,
                          release: res.release)
            return
        }
        // (2) STREAMING via the coordinator (Apple Music play-then-seek, or a durable S3 mp3).
        // Playing from the TOP (atMs 0 — auditioning an in-flight rip to place cues live) is always
        // allowed; a non-zero OFFSET needs seek support (else it would silently start at 0:00). When
        // the offset can't be applied, still PLAY FROM THE TOP so the transport's play button never
        // dead-ends — the notice explains the scrubbed position was dropped.
        guard atMs == 0 || coordinator.cueSeekSupported(for: song) else {
            cueNotice = "Can’t jump into this track yet — it’s still ripping. Playing from the top."
            Task { await coordinator.play(song, atMs: 0) }
            return
        }
        Task {
            await coordinator.play(song, atMs: atMs)
            // (3) BACKSTOP: the rip went live between the check and the play — the provider
            // records the dropped cue. Scoped to the rip backend: `lastCueDropped` only resets
            // inside the RIP provider's tryPlay, so after an Apple Music win it (and a stale
            // live nowPlaying) would be leftovers from an older play, not this one. Only a
            // non-zero offset can be "dropped" — a top play losing its position is a no-op.
            if atMs > 0, coordinator.activeBackend == .ripServer,
               coordinator.ripProvider.lastCueDropped || rips.nowPlaying?.live == true {
                cueNotice = "Cue dropped — the rip is still in flight, so playback started from the top."
            }
        }
    }

    /// The SONG-RELATIVE playhead (ms) for `songId`, nil when that song isn't what's playing.
    /// Sources mirror the two backends:
    ///   • rip/burned path — `PlayerEngine.clock.currentTime` is the ABSOLUTE file position,
    ///     so subtract the song's start within a shared analog album (`NowPlaying.startMs`);
    ///     a live HLS stream starts at the song's own 0:00, so it maps 1:1 (setting cues while
    ///     listening to an in-flight rip is a legitimate flow — playing them is what's gated);
    ///   • Apple Music — `playbackTime` is already song-relative.
    private func playheadMs(forSong songId: String) -> Int? {
        if let np = rips.nowPlaying, np.songId == songId {
            let base = np.live ? 0 : (np.startMs ?? 0)
            return max(0, Int(player.clock.currentTime * 1000) - base)
        }
        if coordinator.isAppleMusicNowPlaying(songId) {
            return max(0, Int(coordinator.appleMusic.positionSeconds * 1000))
        }
        return nil
    }

    /// "m:ss.mmm" — cues are nudged in 100 ms steps, so the sub-second digits are the feedback.
    static func stamp(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let s = clamped / 1000
        return String(format: "%d:%02d.%03d", s / 60, s % 60, clamped % 1000)
    }
}

// MARK: - Transport (play/pause + scrub for cue creation)

/// Play/pause + a scrub bar under the waveform, so you can audition the track and drop cues
/// ANYWHERE without listening start-to-finish (the whole point: set a cue, jump elsewhere, set
/// another). Both playback backends are handled the same way the rest of this view does: the
/// burned/rip path drives `PlayerEngine` (AVPlayer) directly; the streaming path drives the
/// `PlaybackCoordinator` (Apple Music). Position + play state are SAMPLED on a `TimelineView` off
/// the non-`@Observable` `PlayerClock` (the dropped-clicks doctrine) so the meter tick never
/// invalidates the sibling cue slots. Scrubbing is gated on `seekable` (a live/in-flight HLS rip
/// can't seek); play/pause is always available (auditioning an in-flight rip is legitimate — only
/// the cue OFFSET is gated, per the parent's routing rules).
private struct CueTransport: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator

    let song: IndexSong
    let durationMs: Int
    let seekable: Bool
    /// Start `song` at a song-relative offset (ms) via the parent's shared `startPlayback` routing.
    /// Called by the play button when this song isn't already the active player.
    let start: (Int) -> Void

    /// 0…1 scrub position WHILE dragging (auto-clears on release).
    @GestureState private var dragFraction: Double?
    /// When this song isn't the active player, the scrub bar sets the position PLAY starts from.
    @State private var pendingStartMs: Int = 0

    private var ripCurrent: Bool { rips.nowPlaying?.songId == song.id }
    private var amCurrent: Bool { coordinator.isAppleMusicNowPlaying(song.id) }
    /// Scrub is only meaningful when a seek would actually apply (live seek, or setting a start
    /// position before playback). A live/in-flight HLS rip can't be scrubbed.
    private var canScrub: Bool { seekable }

    /// Song-relative live playhead (ms), nil when this song isn't the active player. Same derivation
    /// as the parent's `playheadMs(forSong:)`: the rip clock is ABSOLUTE, so subtract the shared
    /// analog album's `startMs`; Apple Music's `playbackTime` is already song-relative.
    private func livePlayheadMs() -> Int? {
        if ripCurrent, let np = rips.nowPlaying {
            let base = np.live ? 0 : (np.startMs ?? 0)
            return max(0, Int(player.clock.currentTime * 1000) - base)
        }
        if amCurrent { return max(0, Int(coordinator.appleMusic.positionSeconds * 1000)) }
        return nil
    }

    private func isPlayingNow() -> Bool {
        if ripCurrent { return player.isPlaying }
        if amCurrent { return coordinator.isPlaying }
        return false
    }

    /// Toggle when this song is loaded; otherwise START it from the scrubbed position.
    private func togglePlay() {
        if ripCurrent { player.toggle() }
        else if amCurrent { coordinator.togglePlayPause() }
        else { start(pendingStartMs) }
    }

    /// Seek to a song-relative ms — live when this song is the active player, else remembered as the
    /// play-from position. Only reachable when `canScrub` (the bar is disabled otherwise).
    private func seek(toMs ms: Int) {
        let clamped = min(max(0, ms), durationMs)
        if ripCurrent {
            let base = rips.nowPlaying.map { $0.live ? 0 : ($0.startMs ?? 0) } ?? 0
            player.seek(to: Double(base + clamped) / 1000)
        } else if amCurrent {
            coordinator.seekAppleMusic(to: Double(clamped) / 1000)
        } else {
            pendingStartMs = clamped
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let baseMs = livePlayheadMs() ?? pendingStartMs
            let dur = Double(max(durationMs, 1))
            let liveFraction = min(max(Double(baseMs) / dur, 0), 1)
            let shownFraction = dragFraction ?? liveFraction
            let shownMs = Int(shownFraction * dur)
            let playing = isPlayingNow()
            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.accent.opacity(0.18)))
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cue-transport-playpause")
                .accessibilityLabel(playing ? "Pause" : "Play")

                VStack(spacing: 2) {
                    scrubBar(shownFraction: shownFraction)
                    HStack {
                        Text(StudioCuesView.stamp(shownMs))
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        Spacer()
                        Text(StudioCuesView.stamp(durationMs))
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    }
                }
            }
        }
        .onChange(of: song.id) { pendingStartMs = 0 }   // fresh selection → forget the old start pos
    }

    private func scrubBar(shownFraction: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border).frame(height: 4)
                Capsule().fill(Theme.accent2).frame(width: max(0, w * shownFraction), height: 4)
                Circle().fill(Theme.accent2).frame(width: 16, height: 16)
                    .offset(x: min(max(0, w * shownFraction - 8), w - 16))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, frac, _ in
                        frac = w > 0 ? min(max(value.location.x / w, 0), 1) : 0
                    }
                    .onEnded { value in
                        guard w > 0 else { return }
                        let frac = min(max(value.location.x / w, 0), 1)
                        seek(toMs: Int(frac * Double(durationMs)))
                    }
            )
        }
        .frame(height: 20)
        .opacity(canScrub ? 1 : 0.4)
        .allowsHitTesting(canScrub)
        .accessibilityElement()
        .accessibilityIdentifier("cue-transport-scrub")
        .accessibilityLabel("Scrub position")
        .accessibilityValue(StudioCuesView.stamp(Int(shownFraction * Double(durationMs))))
    }
}

// MARK: - Timeline (waveform + cue markers + playhead)

/// The selected track's timeline. Waveform resolution ladder (spec §9):
///   • DIGITAL songs: the manifest's per-song waveform PNG, via `AsyncImage`, as-is.
///   • ANALOG songs (shared album-side audio — detected by a non-nil `startMs` or
///     `source == "analog"` on the manifest entry): the PNG spans the WHOLE album side, so
///     – when the song is BURNED, prefer LOCAL peak extraction (`MixWaveform`) — exact, offline,
///       and windowed to the song's `[startMs, startMs+length]` slice;
///     – else CROP the album PNG horizontally to the song's window (denominator = the album
///       file's total span, see `analogCrop`);
///     – else a plain flat bar.
///   • No waveform derivable at all ⇒ the plain bar (an un-ripped track still shows a timeline
///     the cue markers + playhead can live on).
/// Decorative only — the slot buttons carry all semantics — so the whole thing is a11y-hidden.
private struct CueTimeline: View {
    @Environment(AppModel.self) private var app
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator

    let song: IndexSong
    let durationMs: Int
    let cues: [StudioCue]
    let isBurned: Bool

    /// Locally-extracted peaks (analog-burned / PNG-less-burned paths); [] until extracted.
    @State private var localPeaks: [Float] = []

    private var entry: RipsStore.ManifestEntry? { rips.manifest[song.id] }
    /// Shared album-side audio? (Analog rips carve one mp3 into songs — the entry carries the
    /// song's `startMs` within it; `source == "analog"` covers entries missing the offset.)
    private var isAnalogShared: Bool {
        guard let e = entry else { return false }
        return e.startMs != nil || e.source == "analog"
    }
    private var waveformPNG: URL? {
        RipsStore.waveformURL(for: entry, ripsBase: Config.ripsBase)
    }
    /// Should this render use the local extractor? Burned analog always (the PNG is the whole
    /// side); burned digital only when there's no per-song PNG (e.g. fully offline / old rip).
    private var usesLocalPeaks: Bool { isBurned && (isAnalogShared || waveformPNG == nil) }

    var body: some View {
        waveformLayer
            .frame(maxWidth: .infinity)
            .background(Theme.bgOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(cueMarkers)
            .overlay(playheadLine)
            // Re-extract when the selection (or its burned-ness) changes; guarded inside so the
            // common digital-PNG case never touches the disk.
            .task(id: "\(song.id)|\(isBurned)") {
                localPeaks = []
                guard usesLocalPeaks else { return }
                localPeaks = await MixWaveform.peaks(forSong: song.id, lengthMs: song.length,
                                                     burns: burns)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var waveformLayer: some View {
        if usesLocalPeaks {
            // MixWaveformView renders a flat baseline for [] — the "still extracting" state.
            MixWaveformView(peaks: localPeaks)
        } else if isAnalogShared {
            if let crop = analogCrop() {
                CroppedRemoteWaveform(url: crop.url, startFraction: crop.start,
                                      widthFraction: crop.width)
            } else {
                MixWaveformView(peaks: [])   // window not derivable → plain bar
            }
        } else if let url = waveformPNG {
            // Digital per-song PNG, as-is. Failure/loading phases show the plain bar.
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable()
                } else {
                    MixWaveformView(peaks: [])
                }
            }
        } else {
            MixWaveformView(peaks: [])
        }
    }

    /// The analog album PNG's crop window for THIS song: `[startMs, startMs+durationMs]` over
    /// the album side's total span. The PNG covers the whole shared file, so the denominator is
    /// that FILE's length — best derived as the max of (a) the last song's end across every
    /// manifest entry sharing this entry's `key` (the same shared mp3) and (b) the catalog
    /// album's measured `audioDurationSec` (the indexer analyzed the same source file; it also
    /// covers trailing run-out the last song's end misses). nil when the window isn't derivable
    /// — the caller falls back per the ladder.
    private func analogCrop() -> (url: URL, start: CGFloat, width: CGFloat)? {
        guard let e = entry, let s = e.startMs, let d = e.durationMs, d > 0,
              let url = waveformPNG else { return nil }
        var total = rips.manifest.values
            .filter { $0.key == e.key }
            .compactMap { ent -> Int? in
                guard let st = ent.startMs, let du = ent.durationMs else { return nil }
                return st + du
            }
            .max() ?? 0
        if let sec = app.album(forSongId: song.id)?.audioDurationSec, sec > 0 {
            total = max(total, Int(sec * 1000))
        }
        total = max(total, s + d)   // a window can never overrun its own file
        guard total > 0 else { return nil }
        return (url, CGFloat(s) / CGFloat(total), CGFloat(d) / CGFloat(total))
    }

    /// The 8 cue markers at `positionMs / durationMs` — slot-colored line with a head dot.
    private var cueMarkers: some View {
        GeometryReader { geo in
            ForEach(cues) { cue in
                let f = min(1, max(0, Double(cue.positionMs) / Double(max(durationMs, 1))))
                let color = StudioCuesView.slotColor(cue.slot)
                VStack(spacing: 0) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Rectangle().fill(color).frame(width: 2)
                }
                .frame(height: geo.size.height)
                .offset(x: CGFloat(f) * max(0, geo.size.width - 2))
            }
        }
        .allowsHitTesting(false)
    }

    /// The live playhead. SAMPLED on a TimelineView schedule, not observed —
    /// `player.clock.currentTime` is a plain (non-@Observable) value, so each tick redraws
    /// ONLY this overlay and never invalidates the sibling slot buttons (the inline-player
    /// dropped-clicks lesson, CollectionSongRow).
    private var playheadLine: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            GeometryReader { geo in
                if let ms = currentPlayheadMs() {
                    let f = min(1, max(0, Double(ms) / Double(max(durationMs, 1))))
                    Rectangle()
                        .fill(Theme.fg)
                        .frame(width: 1.5)
                        .offset(x: CGFloat(f) * max(0, geo.size.width - 1.5))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Song-relative playhead for the timeline — same derivation as the parent's
    /// `playheadMs(forSong:)` (duplicated locally because this subview samples it at 5 Hz and
    /// keeping it self-contained avoids threading closures through the TimelineView).
    private func currentPlayheadMs() -> Int? {
        if let np = rips.nowPlaying, np.songId == song.id {
            let base = np.live ? 0 : (np.startMs ?? 0)
            return max(0, Int(player.clock.currentTime * 1000) - base)
        }
        if coordinator.isAppleMusicNowPlaying(song.id) {
            return max(0, Int(coordinator.appleMusic.positionSeconds * 1000))
        }
        return nil
    }
}

/// A horizontal crop of the shared album-side waveform PNG: the full image is scaled so the
/// song's `[start, start+width]` fraction fills the container, then shifted left and clipped.
/// Pure layout math — no CGImage slicing — so it works straight off `AsyncImage`.
private struct CroppedRemoteWaveform: View {
    let url: URL
    /// Fractions of the ALBUM file's total span (0…1).
    let startFraction: CGFloat
    let widthFraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            // Scale the full-side image so the song's window spans the container width…
            let scale = 1 / max(widthFraction, 0.0005)   // floor keeps a degenerate window finite
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable()
                        .frame(width: geo.size.width * scale, height: geo.size.height)
                        // …then slide it left so the window's start lands at x = 0.
                        .offset(x: -geo.size.width * scale * startFraction)
                } else {
                    MixWaveformView(peaks: [])
                }
            }
        }
        .clipped()   // everything outside the song's window is cropped away
    }
}
