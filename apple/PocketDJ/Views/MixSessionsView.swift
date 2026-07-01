import SwiftUI
import AVFoundation

// MARK: - Sessions list

/// The Mix tab's **Sessions** screen — every recorded mixing session (what you played + the full
/// timeline of actions). Tapping one opens its replayable timeline. Reached from the Mix toolbar's
/// Sessions button / title menu.
struct MixSessionsView: View {
    @Environment(MixSessionStore.self) private var store
    @State private var renamingId: String?
    @State private var nameDraft = ""

    var body: some View {
        Group {
            if store.sessionsNewestFirst.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Start mixing on the Mix tab — your actions are recorded into a session you can replay here."))
            } else {
                List {
                    ForEach(store.sessionsNewestFirst) { s in
                        NavigationLink(value: MixSessionRoute(sessionId: s.id)) {
                            SessionRow(name: s.name,
                                       isCurrent: s.id == store.currentId,
                                       startedAt: store.startedAt(forSession: s.id),
                                       durationMs: store.durationMs(forSession: s.id),
                                       tracks: store.playedSongIds(forSession: s.id).count,
                                       actions: store.events(forSession: s.id).count,
                                       recordings: store.recordings(forSession: s.id).count)
                        }
                        .accessibilityIdentifier("mix-session-row-\(s.id)")
                        .swipeActions(edge: .leading) {
                            Button { beginRename(s.id, s.name) } label: { Label("Rename", systemImage: "pencil") }
                                .tint(Theme.accent2)
                                .accessibilityIdentifier("mix-session-rename-\(s.id)")
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.delete(s.id) } label: { Label("Delete", systemImage: "trash") }
                                .accessibilityIdentifier("mix-session-delete-\(s.id)")
                        }
                        .contextMenu {       // right-click (macOS) / long-press (iOS)
                            Button { beginRename(s.id, s.name) } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { store.delete(s.id) } label: { Label("Delete session", systemImage: "trash") }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("mix-sessions-list")
            }
        }
        .background(Theme.bg)
        .navigationTitle("Sessions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Rename session", isPresented: Binding(get: { renamingId != nil },
                                                      set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft).accessibilityIdentifier("mix-session-rename-field")
            Button("Save") { if let id = renamingId { store.rename(id, nameDraft) }; renamingId = nil }
                .accessibilityIdentifier("mix-session-rename-confirm")
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
    }

    private func beginRename(_ id: String, _ current: String) {
        nameDraft = current
        renamingId = id
    }
}

/// One row in the sessions list.
private struct SessionRow: View {
    let name: String
    let isCurrent: Bool
    let startedAt: Double
    let durationMs: Int
    let tracks: Int
    let actions: Int
    let recordings: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(isCurrent ? Theme.accent : Theme.fgDim)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                    if isCurrent {
                        Text("Current").font(.caption2.weight(.bold)).foregroundStyle(Theme.bg)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(Self.date(startedAt)).font(.caption).foregroundStyle(Theme.fgDim)
                Text("\(Fmt.duration(durationMs)) · \(tracks) track\(tracks == 1 ? "" : "s") · \(actions) action\(actions == 1 ? "" : "s")\(recordings > 0 ? " · \(recordings) rec" : "")")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private static func date(_ epochMs: Double) -> String {
        guard epochMs > 0 else { return "—" }
        return Date(timeIntervalSince1970: epochMs / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

/// `.sheet(item:)` wrapper for the tapped `.load` action's song (`IndexSong` isn't Identifiable).
private struct SongMetadataItem: Identifiable { let song: IndexSong; var id: String { song.id } }

// MARK: - Session replay (timeline)

/// One session's **replayable timeline**: every recorded action laid out vertically (top→bottom on
/// iPhone) or horizontally (left→right on iPad/macOS), with a real-time replay clock (play/pause,
/// 0.5–4× speed, scrub) that highlights + auto-scrolls to the current action. Replay is VISUAL (it
/// does not re-drive the audio decks — that's a follow-up). The captured events ARE the training
/// corpus; this view is the human-facing read of them.
struct MixSessionDetailView: View {
    @Environment(MixSessionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var app
    let sessionId: String

    /// A tapped `.load` action's song, presented as a metadata sheet (nil ⇒ closed). Wrapped so
    /// `.sheet(item:)` has an Identifiable.
    @State private var metadataItem: SongMetadataItem?

    /// A STABLE snapshot for the duration of the screen (the current session keeps recording).
    @State private var events: [MixSessionEvent] = []
    @State private var recPlayer = RecordingAudioPlayer()

    /// Recordings are read LIVE from the store (not snapshotted) so a take filed while this screen is
    /// open — or one that landed just before it opened — always shows.
    private var recordings: [MixRecording] { store.recordings(forSession: sessionId) }
    @State private var replayMs: Double = 0
    @State private var playing = false
    @State private var speed: Double = 1
    @State private var scrubbing = false
    @State private var clock: Task<Void, Never>?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var horizontal: Bool { hSize != .compact }   // iPad → horizontal; iPhone → vertical
    #else
    private var horizontal: Bool { true }                // macOS → horizontal
    #endif

    private var durationMs: Int { events.last?.tMs ?? 0 }

    /// The event the playhead is "on" for `replayMs` (binary search — events are tMs-sorted). On an
    /// exact-time hit returns the FIRST event at that tMs, so tapping any card in a same-instant cluster
    /// (e.g. Sync emits tempo+seek+sync at one ms) highlights the cluster's head rather than jumping to
    /// a different member; otherwise the last event strictly before `replayMs` (nil before the first).
    private var currentIndex: Int? {
        guard !events.isEmpty else { return nil }
        let t = Int(replayMs)
        var lo = 0, hi = events.count                    // lower-bound: first index with tMs >= t
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].tMs < t { lo = mid + 1 } else { hi = mid }
        }
        if lo < events.count, events[lo].tMs == t { return lo }   // first event exactly at t
        return lo > 0 ? lo - 1 : nil                              // last event strictly before t
    }
    private var currentId: String? { currentIndex.map { events[$0].id } }

    var body: some View {
        VStack(spacing: 12) {
            replayControls
            if !recordings.isEmpty { recordingsPanel }
            timeline
        }
        .background(Theme.bg)
        .navigationTitle(store.session(sessionId)?.name ?? "Session")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Drop unknown (forward-compat) events from the human view.
            events = store.events(forSession: sessionId).filter { !$0.kind.isUnknown }
        }
        .onDisappear { pause(); recPlayer.stop() }
        .sheet(item: $metadataItem) { item in
            NavigationStack {
                SongDetailView(song: item.song)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { metadataItem = nil }.accessibilityIdentifier("mix-replay-song-done")
                        }
                    }
            }
        }
    }

    // MARK: Recordings (captured mix audio)

    /// The session's captured audio takes, each with a play/stop control. Files resolve via
    /// `SessionFolders` (app storage or the user-picked session folder).
    private var recordingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recordings", systemImage: "waveform.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
            ForEach(Array(recordings.enumerated()), id: \.element.id) { idx, rec in
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button {
                            recPlayer.toggle(rec, sessionId: sessionId, bookmark: settings.sessionFolderBookmark)
                        } label: {
                            Image(systemName: recPlayer.playingId == rec.id ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mix-recording-play-\(rec.id)")
                        .accessibilityLabel(recPlayer.playingId == rec.id ? "Stop recording" : "Play recording")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Take \(idx + 1)").font(.caption).foregroundStyle(Theme.fg)
                            Text("\(Self.recDate(rec.startedAt)) · \(Fmt.duration(rec.durationMs))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        }
                        Spacer()
                    }
                    // Scrub bar — only for the take that's currently playing.
                    if recPlayer.playingId == rec.id {
                        RecordingScrubBar(player: recPlayer)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("mix-recordings-panel")
    }

    private static func recDate(_ epochMs: Double) -> String {
        guard epochMs > 0 else { return "—" }
        return Date(timeIntervalSince1970: epochMs / 1000).formatted(date: .omitted, time: .shortened)
    }

    // MARK: Replay controls

    private var replayControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { playing ? pause() : play() } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title)
                }
                .tint(Theme.accent)
                .disabled(events.isEmpty)
                .accessibilityIdentifier("mix-replay-playpause")

                Text(MixEventDisplay.clock(Int(replayMs)))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                Slider(value: $replayMs, in: 0...Double(max(durationMs, 1)),
                       onEditingChanged: { editing in
                           scrubbing = editing
                           if editing { pause() }      // scrubbing takes over from the clock
                       })
                    .tint(Theme.accent)
                    .disabled(events.isEmpty)
                    .accessibilityIdentifier("mix-replay-scrub")
                Text(MixEventDisplay.clock(durationMs))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)

                Menu("\(Fmt.trim(speed))×") {
                    ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { s in
                        Button("\(Fmt.trim(s))×") { speed = s }
                    }
                }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("mix-replay-speed")
            }
            HStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.caption2).foregroundStyle(Theme.fgDim)
                Text("\(store.playedSongIds(forSession: sessionId).count) tracks · \(events.count) actions")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
                Spacer()
            }
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12)
    }

    // MARK: Timeline

    /// How many cards fill one row before wrapping (Mac roomier than iPad). iPhone uses a 1-per-row
    /// vertical list instead (the `horizontal == false` path), so this isn't consulted there.
    #if os(macOS)
    private var perRow: Int { 5 }
    #else
    private var perRow: Int { 3 }
    #endif

    @ViewBuilder private var timeline: some View {
        if events.isEmpty {
            ContentUnavailableView("No actions recorded", systemImage: "waveform",
                description: Text("This session has no recorded mix activity yet."))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {                 // always vertical now — rows WRAP horizontally
                    if horizontal { wrappedTimeline } else { verticalTimeline }
                }
                .accessibilityIdentifier("mix-replay-timeline")
                // Auto-scroll to the current event only while playing and not scrubbing (don't fight
                // the user). The per-frame replayMs mutation is NOT animated; only this scroll is.
                .onChange(of: currentId) { _, id in
                    guard playing, !scrubbing, let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// iPhone: one card per row, top→bottom.
    private var verticalTimeline: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(events) { e in
                TimelineCard(event: e, active: e.id == currentId, horizontal: true) { handleTap(e) }
                    .id(e.id)
            }
        }
        .padding(12)
    }

    /// Mac / iPad: cards WRAP every `perRow`, filling the width — `→` between cards in a row, and a
    /// wrap arrow between rows, so the order reads left-to-right then down (no infinite side-scroll).
    private var wrappedTimeline: some View {
        let rows = stride(from: 0, to: events.count, by: perRow).map { start in
            Array(events[start..<min(start + perRow, events.count)])
        }
        return LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { i, e in
                        TimelineCard(event: e, active: e.id == currentId, horizontal: false) {
                            handleTap(e)                                 // load → metadata sheet; else jump replay
                        }
                        .id(e.id)
                        if i < row.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(Theme.fgDim)
                                .accessibilityHidden(true)
                        }
                    }
                }
                if rowIdx < rows.count - 1 {                          // wrap indicator: down + back to the left
                    Image(systemName: "arrow.turn.down.left")
                        .font(.caption).foregroundStyle(Theme.accent2)
                        .padding(.leading, 6)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(12)
    }

    /// Tap a timeline card: a LOAD action pops up the song's metadata; any other action jumps the
    /// replay playhead to that moment. A load whose song is no longer in the catalog falls back to a jump.
    private func handleTap(_ e: MixSessionEvent) {
        if e.kind == .load, let id = e.songId, let song = app.songsById[id] {
            metadataItem = SongMetadataItem(song: song)
        } else {
            replayMs = Double(e.tMs)
        }
    }

    // MARK: Replay clock (wall-clock driven, ~30 Hz)

    private func play() {
        guard !events.isEmpty else { return }
        if replayMs >= Double(durationMs) { replayMs = 0 }   // restart from the top if at the end
        playing = true
        clock?.cancel()
        clock = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled && playing {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 Hz
                if Task.isCancelled { break }
                let now = Date()
                let dt = now.timeIntervalSince(last); last = now
                let next = min(replayMs + dt * 1000 * speed, Double(durationMs))
                replayMs = next
                if next >= Double(durationMs) { playing = false }
            }
        }
    }

    private func pause() {
        playing = false
        clock?.cancel(); clock = nil
    }
}

// MARK: - Recording playback

/// Plays a session's captured recording (a local `.m4a`) with a simple play/stop. One instance per
/// detail screen. Resolves the file (holding its security scope for the duration of playback) via
/// `SessionFolders`, and auto-resets when the take finishes via `AVAudioPlayerDelegate` — NOT a poll
/// loop, which risked stopping playback early on a transient `isPlaying == false`.
@MainActor @Observable final class RecordingAudioPlayer: NSObject, AVAudioPlayerDelegate {
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var release: (() -> Void)?
    /// The recording id currently playing (nil ⇒ stopped) — drives the play/stop button state.
    private(set) var playingId: String?
    /// The playing take's length (seconds), for the scrub slider's range. 0 when stopped.
    private(set) var duration: Double = 0

    override init() { super.init() }

    /// The live playhead (seconds) — polled by the scrub bar's TimelineView (AVAudioPlayer doesn't
    /// publish it). 0 when stopped.
    func currentTime() -> Double { player?.currentTime ?? 0 }

    /// Scrub the playing take to `seconds` (clamped). No-op when nothing is playing.
    func seek(to seconds: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, seconds), p.duration)
    }

    /// Toggle playback of `rec`: stop if it's the one playing, else (stop any other and) start it.
    func toggle(_ rec: MixRecording, sessionId: String, bookmark: Data?) {
        if playingId == rec.id { stop(); return }
        stop()
        guard let resolved = SessionFolders.recordingURL(sessionId: sessionId, fileName: rec.fileName,
                                                         wasUserFolder: rec.wasUserFolder, bookmark: bookmark)
        else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let p = try? AVAudioPlayer(contentsOf: resolved.url) else {
            resolved.release?()
            return
        }
        release = resolved.release
        p.delegate = self
        player = p
        p.prepareToPlay()
        p.play()
        playingId = rec.id
        duration = p.duration
    }

    func stop() {
        player?.stop(); player?.delegate = nil; player = nil
        release?(); release = nil
        playingId = nil
        duration = 0
    }

    /// Reset when the take finishes (or errors) — the callback may arrive off the main actor, so hop.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// A scrub slider + time readout for the currently-playing recording. Its own view so the ~10 Hz
/// playhead poll (AVAudioPlayer doesn't publish position) re-renders only the bar. Dragging seeks the
/// take on release; while dragging it shows the finger position (an `onEditingChanged` scrub flag, like
/// the replay clock's slider).
private struct RecordingScrubBar: View {
    let player: RecordingAudioPlayer
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let dur = max(player.duration, 0.01)
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let pos = scrubbing ? scrubValue : min(player.currentTime(), dur)
            VStack(spacing: 1) {
                Slider(value: Binding(get: { pos }, set: { scrubValue = $0 }), in: 0...dur,
                       onEditingChanged: { editing in
                           scrubbing = editing
                           if !editing { player.seek(to: scrubValue) }   // commit the scrub on release
                       })
                    .controlSize(.small)
                    .tint(Theme.accent2)
                    .accessibilityIdentifier("mix-recording-scrub")
                HStack {
                    Text(Self.clock(pos)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Text(Self.clock(dur)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    private static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// One action card in the replay timeline.
private struct TimelineCard: View {
    let event: MixSessionEvent
    let active: Bool
    let horizontal: Bool
    let onTap: () -> Void

    var body: some View {
        let d = MixEventDisplay.describe(event)
        Button(action: onTap) {
            HStack(spacing: 8) {
                deckChip
                Image(systemName: d.icon).foregroundStyle(d.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.text).font(.caption).foregroundStyle(Theme.fg).lineLimit(2)
                    Text(MixEventDisplay.clock(event.tMs))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                if event.kind == .load {                 // hint: a load card opens the song's metadata
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(Theme.fgDim)
                } else if !horizontal {
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .frame(width: horizontal ? 210 : nil, alignment: .leading)
            .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
            .background(active ? d.tint.opacity(0.18) : Theme.bgRaised,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? d.tint : Theme.border, lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mix-replay-event-\(event.id)")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var deckChip: some View {
        if let deck = event.deck {
            Text(deck).font(.caption2.weight(.bold)).foregroundStyle(Theme.bg)
                .frame(width: 18, height: 18)
                .background(deck == "A" ? Theme.accent : Theme.accent2, in: Circle())
        } else {
            Image(systemName: "circle.grid.cross").font(.caption2).foregroundStyle(Theme.fgDim)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Event → human display

/// Maps a recorded event to an (icon, sentence, tint) for the timeline. Pure + reusable (testable).
enum MixEventDisplay {
    static func describe(_ e: MixSessionEvent) -> (icon: String, text: String, tint: Color) {
        switch e.kind {
        case .load:
            let who = e.artist.map { " — \($0)" } ?? ""
            return ("tray.and.arrow.down", "Load: \(e.title ?? "track")\(who)", Theme.accent)
        case .play:        return ("play.fill", "Play", .green)
        case .pause:       return ("pause.fill", "Pause", Theme.fgDim)
        case .seek:        return ("arrow.left.and.right", "Seek → \(mmss(e.value ?? 0))", Theme.accent2)
        case .tempo:       return ("metronome", "Tempo → " + String(format: "%.2f×", e.value ?? 1), Theme.accent)
        case .pitch:       return ("tuningfork", "Pitch → " + String(format: "%+.1f", e.value ?? 0), Theme.accent)
        case .volume:      return ("speaker.wave.2.fill", "Vol → \(pct(e.value))", Theme.accent)
        case .crossfader:  return ("arrow.left.arrow.right", "Crossfader → " + String(format: "%.2f", e.value ?? 0.5), Theme.accent2)
        case .effectToggle:
            return (fxIcon(e.param), "\(cap(e.param, "FX")) " + ((e.flag ?? false) ? "on" : "off"), Theme.accent)
        case .effectStrength:
            return (fxIcon(e.param), "\(cap(e.param, "FX")) \(pct(e.value))", Theme.accent)
        case .stemMode:    return ("square.split.2x2", "Stems " + ((e.flag ?? false) ? "on" : "off"), Theme.accent2)
        case .stemMute:
            let muted = e.flag ?? false
            return (muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    "\(cap(e.param, "Stem")) " + (muted ? "muted" : "unmuted"), stemColor(e.param))
        case .stemVolume:  return ("waveform", "\(cap(e.param, "Stem")) \(pct(e.value))", stemColor(e.param))
        case .lead:        return ("star.fill", "Lead " + ((e.flag ?? false) ? "set" : "cleared"), Theme.accent2)
        case .sync:        return ("arrow.triangle.2.circlepath", "Sync → " + String(format: "%.2f×", e.value ?? 1), Theme.accent2)
        case .resetDeck:   return ("arrow.counterclockwise", "Reset deck", Theme.accent)
        case .glide:
            let from = e.fromValue ?? 0, to = e.value ?? 0
            switch e.param {
            case "crossfader":
                return ("arrow.left.arrow.right", "Glide · Crossfader " + String(format: "%.2f→%.2f", from, to), Theme.accent2)
            case "tempo":
                return ("metronome", "Glide · Tempo " + String(format: "%.2f×→%.2f×", from, to), Theme.accent)
            case "pitch":
                return ("tuningfork", "Glide · Pitch " + String(format: "%+.1f→%+.1f", from, to), Theme.accent)
            default:
                return (fxIcon(e.param), "Glide · \(cap(e.param, "FX")) \(pct(from))→\(pct(to))", Theme.accent)
            }
        case .unknown:     return ("questionmark", "—", Theme.fgDim)
        }
    }

    /// ms → "m:ss.S" (the session-relative timeline stamp).
    static func clock(_ ms: Int) -> String {
        let v = max(0, ms)
        return String(format: "%d:%02d.%d", v / 60000, (v / 1000) % 60, (v % 1000) / 100)
    }
    /// seconds → "m:ss" (a seek target).
    static func mmss(_ sec: Double) -> String {
        let t = Int(max(0, sec).rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
    private static func pct(_ v: Double?) -> String { "\(Int(((v ?? 0) * 100).rounded()))%" }
    private static func cap(_ s: String?, _ fallback: String) -> String { (s ?? fallback).capitalized }

    static func fxIcon(_ name: String?) -> String {
        switch name {
        case "compressor": return "waveform.path.ecg"
        case "reverb":     return "dot.radiowaves.left.and.right"
        case "flanger":    return "wind"
        case "filter":     return "line.3.horizontal.decrease.circle"
        default:           return "slider.horizontal.3"
        }
    }
    static func stemColor(_ name: String?) -> Color {
        switch name {
        case "bass":   return .red
        case "drums":  return .yellow
        case "other":  return .green
        case "vocals": return .purple
        default:       return Theme.accent
        }
    }
}
