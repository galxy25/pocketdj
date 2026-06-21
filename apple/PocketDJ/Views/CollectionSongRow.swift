import SwiftUI

/// The ONE shared, PWA-style song row used EVERYWHERE a song reads as a list row:
/// the Browser song list, collection details (playlists / pockets / index playlists),
/// and the frozen Setlist. Every surface gets the identical look + the identical info.
///
/// Content, left → right:
///   • LEFT: album-art thumbnail (resolved via `app.albumsById`; graceful music-note
///     placeholder when the album is missing/unknown — e.g. a setlist snapshot whose
///     catalog song is gone),
///   • PRIMARY line: song title (+ explicit "E" badge),
///   • SECONDARY line: "artist · year · genre" (size-gated — see below),
///   • MIDDLE music cluster: BPM as tiered play-icons (+ numeric), a Camelot KeyChip
///     (always populated — black-box "U" when unknown), and the length (`Fmt.duration`),
///   • RIGHT: ▶ play / ⤓ download transport (`RowTransport`) — rip-on-demand wired to
///     `RipsStore` + `PlayerEngine`; ▶ reveals the inline slide-out player below the row.
///
/// Responsive: on COMPACT width (iPhone) the year + genre are dropped from the
/// secondary line to keep it uncluttered; on regular width (iPad) and macOS (where
/// `horizontalSizeClass` is nil) they SHOW. Title, the music cluster, and transport
/// are visible at every size.
///
/// Presentation only — wrap in a `NavigationLink` for tap-through and attach
/// swipe / move / delete / notes / context-menus on the enclosing row.
struct SongRowView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    let data: SongRowData
    /// Optional trailing accessory (e.g. a setlist source/sequence badge column) shown
    /// to the left of the play/download buttons.
    var trailing: AnyView?

    /// Show year/genre only when there's room: regular width (iPad) or macOS (nil).
    private var showsExtra: Bool { hSize != .compact }

    /// Secondary descriptor — "artist · year · genre"; year/genre size-gated.
    private var descriptor: String {
        var parts: [String] = []
        if !data.artist.isEmpty { parts.append(data.artist) }
        if showsExtra {
            if let y = data.year { parts.append(String(y)) }
            if let g = data.genre, !g.isEmpty { parts.append(g) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            SongThumbnail(album: data.album).frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(data.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                    if data.explicit {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                            .accessibilityIdentifier("explicit-badge")
                    }
                }
                Text(descriptor.isEmpty ? "—" : descriptor)
                    .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Middle music cluster: BPM tiers · KeyChip · length. The prominent
            // "what does this sound like" block, right-aligned ahead of transport.
            HStack(spacing: 8) {
                BPMTier(bpm: data.bpm)
                KeyChip(key: data.key, camelot: data.camelot)
                Text(Fmt.duration(data.lengthMs))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }

            if let trailing { trailing }

            RowTransport(song: (id: data.songId, title: data.title, artist: data.artist),
                         startMs: data.startMs)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// The inline slide-out player rendered at LIST level, immediately AFTER a song row's
/// `NavigationLink`, when that row's song is the now-playing one. It MUST live outside the
/// nav-link label so its buttons (play/pause, close, chevron) receive taps instead of the
/// link swallowing them. Drop this directly after each song-row `NavigationLink`, passing
/// the row's song id; it shows the panel only for the matching now-playing row and keeps
/// the slide-in/out animation.
struct InlinePlayerSlot: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlaybackCoordinator.self) private var coordinator
    /// The id of the song whose row this slot trails.
    let songId: String

    private var isRipNowPlaying: Bool { rips.nowPlaying?.songId == songId }
    private var isAppleMusicNowPlaying: Bool { coordinator.isAppleMusicNowPlaying(songId) }

    var body: some View {
        // Apple Music streaming is the active backend for this row → show the
        // Apple-Music-flavoured panel (position-only scrubber + "via Apple Music", no
        // waveform). Otherwise the rip path keeps its EXACT verified panel.
        if isAppleMusicNowPlaying {
            AppleMusicInlinePanel()
        } else if isRipNowPlaying {
            // NO `.animation`/`.transition` here: an animating/transitioning container in
            // a macOS `ScrollView`+`LazyVStack` drops hit-testing on its child buttons —
            // the press lands on the frame but the action never fires (the "slide-out
            // play/pause · ✕ · chevron are dead" bug). Render the panel plainly so its
            // controls are live. The slide-in is sacrificed for a working player.
            InlinePlayerPanel()
        }
    }
}

/// The primitives that feed `SongRowView`. Both `IndexSong` (browser / collections)
/// and `SetlistTrack` (frozen setlist snapshot) project into this, so every surface
/// renders identically. Genre / year / thumbnail resolve from the song's album.
struct SongRowData {
    var songId: String
    var title: String
    var artist: String
    var year: Int?
    var genre: String?
    var bpm: Double?
    var key: String?
    var camelot: String?
    var lengthMs: Int?
    var explicit: Bool
    /// Optional analog start offset (ms) within the album rip — when nil the rips
    /// store falls back to the manifest entry's own `startMs`.
    var startMs: Int?
    /// The album behind the song (for cover art + genre/year fallback); nil → placeholder.
    var album: IndexAlbum?

    /// Project a catalog song. Pass the song's resolved album for art + genre/year.
    /// Year prefers the song's own value, falling back to the album's.
    init(song: IndexSong, album: IndexAlbum?) {
        self.songId = song.id
        self.title = song.name
        self.artist = song.artist
        self.year = song.year ?? album?.year
        self.genre = Self.cleanGenre(album?.genre)
        self.bpm = song.bpm
        self.key = song.key
        self.camelot = song.camelot
        self.lengthMs = song.length
        self.explicit = song.explicit == true
        self.startMs = nil   // analog offset resolves from the rips manifest entry
        self.album = album
    }

    /// Project a frozen setlist track (its snapshot) — resolve year/genre/art from the
    /// live catalog album when the backing song still exists, else fall back to the snapshot.
    init(track: SetlistTrack, song: IndexSong?, album: IndexAlbum?) {
        self.songId = track.songId.isEmpty ? track.id : track.songId
        self.title = track.name
        self.artist = track.artist
        self.year = song?.year ?? album?.year
        self.genre = Self.cleanGenre(album?.genre)
        self.bpm = track.bpm
        self.key = nil                 // snapshot carries camelot only
        self.camelot = track.camelot
        self.lengthMs = track.shownMs
        self.explicit = song?.explicit == true
        self.startMs = nil
        self.album = album
    }

    private static func cleanGenre(_ g: String?) -> String? {
        let t = g?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty == false) ? t : nil
    }
}

/// Convenience: the shared row driven straight from an `IndexSong`, resolving the
/// album from the environment's catalog. Used by the Browser + collection details.
struct CollectionSongRow: View {
    @Environment(AppModel.self) private var app
    let song: IndexSong
    /// Optional trailing accessory shown left of the transport buttons.
    var trailing: AnyView?

    private var album: IndexAlbum? { song.albumId.flatMap { app.albumsById[$0] } }

    var body: some View {
        SongRowView(data: SongRowData(song: song, album: album), trailing: trailing)
    }
}

/// BPM rendered as 1–4 `play.fill` icons (tempo tiers) plus the small numeric BPM.
/// nil/0 bpm → a dash, no icons. The tier mapping is a pure function (`BPMTier.tier`)
/// so the boundaries are unit-testable.
struct BPMTier: View {
    let bpm: Double?

    /// Map a BPM to a tempo tier 1…4 (slow→hyper), or nil when bpm is missing/zero.
    ///   0–90 = 1 (slow), 90–120 = 2 (medium), 120–160 = 3 (fast), 160–400 = 4 (hyper).
    /// Upper bound is exclusive of the next tier (e.g. exactly 120 → fast).
    static func tier(_ bpm: Double?) -> Int? {
        guard let bpm, bpm > 0 else { return nil }
        switch bpm {
        case ..<90:   return 1
        case ..<120:  return 2
        case ..<160:  return 3
        default:      return 4   // 160…400+ → hyper
        }
    }

    var body: some View {
        if let t = BPMTier.tier(bpm) {
            // BPM number above the tempo-tier play icons.
            VStack(spacing: 1) {
                Text(Fmt.bpm(bpm)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                HStack(spacing: 1) {
                    ForEach(0..<t, id: \.self) { _ in
                        Image(systemName: "play.fill").font(.system(size: 7))
                    }
                }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("bpm-tier-\(t)")
            }
        } else {
            Text("–").font(.caption2).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("bpm-tier-none")
        }
    }
}

/// The shared LEFT album-art thumbnail — the resolved album's cover, or a graceful
/// music-note placeholder when the album is unknown (e.g. a setlist snapshot whose
/// catalog song is gone).
struct SongThumbnail: View {
    let album: IndexAlbum?
    var body: some View {
        if let album {
            CoverImage(album: album, corner: 6)
        } else {
            ZStack {
                LinearGradient(colors: [Theme.bgOverlay, Theme.bgRaised],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(Theme.fgDim)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

/// ▶ / ⤓ — the real rip-on-demand transport (replaces the old placeholders). ▶ rips
/// (or plays the cached mp3), loads the `PlayerEngine`, and reveals the inline player
/// for this row; ⤓ resolves the durable mp3 and saves it to the user's Documents. The
/// button area shows the live rip phase (Searching… / Ripping mm:ss / ● Streaming live /
/// Uploading…, ⚠ on error), matching the PWA's `RipButtons`.
struct RowTransport: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    let song: (id: String, title: String, artist: String)
    var startMs: Int?

    @State private var busy: Busy?
    @State private var alertMessage: String?
    /// The just-saved file, surfaced via a share sheet so the user can keep it in Files
    /// / AirDrop it / open it elsewhere.
    @State private var shareItem: ShareItem?

    enum Busy { case play, download }

    /// Wraps the saved file URL so it's `Identifiable` for `.sheet(item:)`.
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    /// The current rip job, only while it's actively in flight (not ready/error).
    private var activeJob: RipsStore.Job? {
        guard let j = rips.jobs[song.id], j.phase != .ready, j.phase != .error else { return nil }
        return j
    }
    private var errored: Bool { rips.jobs[song.id]?.phase == .error }
    private var cached: Bool { rips.cachedURL(song.id) != nil }
    /// Actionable when already ripped, or there's a (configured) server to rip it.
    private var canAct: Bool { cached || rips.hasServer }

    /// True when THIS row's song is the live now-playing one — on EITHER backend: the rip
    /// path (keyed off `RipsStore.nowPlaying`, unchanged) OR Apple Music streaming (keyed
    /// off the coordinator). The ▶ then becomes a pause/resume toggle instead of replaying.
    private var isNowPlaying: Bool {
        rips.nowPlaying?.songId == song.id || coordinator.isAppleMusicNowPlaying(song.id)
    }
    /// Is the Apple Music streaming backend the active one for this row? (Selects the
    /// glyph/toggle source — `coordinator` vs. the rip `PlayerEngine`.)
    private var isAppleMusic: Bool { coordinator.isAppleMusicNowPlaying(song.id) }

    var body: some View {
        Group {
            if let job = activeJob {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(RowTransport.phaseLabel(job))
                        .font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                .accessibilityIdentifier("rip-status-\(song.id)")
            } else {
                HStack(spacing: 2) {
                    Button { doPlay() } label: {
                        Image(systemName: rowPlayIcon).font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle((canAct || isNowPlaying) ? Theme.accent : Theme.fgDim)
                    .disabled((!canAct && !isNowPlaying) || busy != nil)
                    .accessibilityIdentifier("row-play-\(song.id)")

                    Button { doDownload() } label: {
                        Image(systemName: busy == .download ? "ellipsis" : "arrow.down.circle").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(canAct ? Theme.fgDim : Theme.fgDim.opacity(0.4))
                    .disabled(!canAct || busy != nil)
                    .accessibilityIdentifier("row-download-\(song.id)")
                }
            }
        }
        .alert("Couldn’t play", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
    }

    /// Pure phase → label mapping (mirrors the PWA's `RipButtons` switch).
    static func phaseLabel(_ job: RipsStore.Job) -> String {
        switch job.phase {
        case .queued:    return "Queued…"
        case .searching: return "Searching…"
        case .uploading: return "Uploading…"
        case .streaming: return "● Streaming live"
        case .ripping:
            if let total = job.progress?.totalMs {
                return "Ripping \(clock(job.progress?.elapsedMs)) / \(clock(total))"
            }
            return "Ripping…"
        case .ready, .error: return ""
        }
    }

    /// mm:ss for a millisecond value (matches the PWA's `clock`).
    static func clock(_ ms: Int?) -> String {
        guard let ms else { return "" }
        let s = Int((Double(ms) / 1000).rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// ▶ icon: while busy → ellipsis; on error → warning; when THIS song is the live
    /// now-playing one → pause/play mirroring the ACTIVE backend (Apple Music streaming via
    /// the coordinator, else the rip `PlayerEngine`); otherwise the plain ▶.
    private var rowPlayIcon: String {
        if busy == .play { return "ellipsis" }
        if isNowPlaying {
            let playing = isAppleMusic ? coordinator.isPlaying : player.isPlaying
            return playing ? "pause.fill" : "play.fill"
        }
        if errored { return "exclamationmark.triangle" }
        return "play.fill"
    }

    private func doPlay() {
        // Now-playing row: toggle the ACTIVE backend (pause / resume) — don't replay.
        // For the rip backend this delegates to `PlayerEngine.toggle()` exactly as before
        // (so the verified rip play/pause + its toggleCount probe are unchanged); for Apple
        // Music it pauses/resumes `ApplicationMusicPlayer`.
        if isNowPlaying { coordinator.togglePlayPause(); return }
        busy = .play
        Task {
            // Hand the song to the matching engine: it tries Apple Music streaming FIRST for
            // an Apple Music (Local) song (when ready), else falls back to the rip server —
            // which rips/streams on demand and loads the SAME `PlayerEngine` the inline
            // waveform/scrubber binds to, EXACTLY as before. A surfaced failure (no rip
            // server / rip error) comes back on `coordinator.lastErrorMessage`.
            await coordinator.play(id: song.id, title: song.title, artist: song.artist)
            if let msg = coordinator.lastErrorMessage { alertMessage = msg }
            busy = nil
        }
    }

    private func doDownload() {
        busy = .download
        Task {
            do { shareItem = ShareItem(url: try await rips.download(song)) }
            catch { alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            busy = nil
        }
    }
}

/// A cross-platform share/export sheet for a saved rip file. On iOS/iPadOS it presents
/// `UIActivityViewController` ("Save to Files", AirDrop, Messages, …); on macOS it wraps
/// `NSSharingServicePicker`. Either way the user keeps the downloaded mp3 wherever they want.
struct ShareSheet: View {
    let url: URL
    var body: some View {
        #if os(macOS)
        MacSharePicker(url: url)
            .frame(width: 320, height: 220)
        #else
        ActivityView(items: [url])
            .ignoresSafeArea()
        #endif
    }
}

#if os(iOS)
import UIKit

/// `UIActivityViewController` bridge — the iOS share sheet (Save to Files / AirDrop / …).
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#if os(macOS)
import AppKit

/// `NSSharingServicePicker` bridge — the macOS share menu (AirDrop / Mail / Save …).
private struct MacSharePicker: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

/// The inline slide-out player rendered directly below the now-playing row: play/pause,
/// a scrubber bound to `PlayerEngine` time (drag to seek), elapsed / duration labels, the
/// waveform image (or a "● live" badge for a live stream), and a chevron to collapse /
/// expand the panel. Lives inside `SongRowView`, so it works wherever a song row appears.
struct InlinePlayerPanel: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @State private var collapsed = false

    private var now: RipsStore.NowPlaying? { rips.nowPlaying }

    var body: some View {
        if let now {
            VStack(spacing: 8) {
                header(now)
                if !collapsed { InlinePlayerExpanded(now: now) }
            }
            .padding(10)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            // The border is a `RoundedRectangle` shape drawn in an `.overlay` — i.e. ON TOP
            // of the panel's controls. A Shape is hit-testable by default, so on macOS this
            // border was swallowing every click to the play/pause · chevron · ✕ buttons
            // beneath it (their actions never fired — the "dead slide-out buttons" bug).
            // `.allowsHitTesting(false)` lets clicks pass through to the controls.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .padding(.vertical, 4)
            // IMPORTANT: do NOT put an `.accessibilityIdentifier` on this container — on
            // macOS SwiftUI PROPAGATES a container id down to every descendant, clobbering
            // the children's own ids (`player-toggle` / `player-chevron` / `player-close` /
            // `player-seek`) so they all read back as "inline-player" and become
            // unaddressable. The panel's presence is instead detected via those child
            // controls. (This was why the slide-out buttons looked "dead" to any driver.)
        }
    }

    /// Always-visible header: play/pause · title · collapse chevron · close.
    ///
    /// The controls use `.buttonStyle(.borderless)` — NOT `.plain`. On macOS a `.plain`
    /// button hosted inside a panel that lives in a `ScrollView` + `LazyVStack` (this
    /// inline player) silently drops its tap: the press hit-tests onto the button frame
    /// but the action never fires (the user's "slide-out play/pause · ✕ · chevron are
    /// dead" bug, confirmed by a UI test reading a toggle-count probe). `.borderless`
    /// — the same style the row's working ▶/⤓ transport uses — fires reliably there.
    private func header(_ now: RipsStore.NowPlaying) -> some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("player-toggle")

            VStack(alignment: .leading, spacing: 1) {
                Text(now.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(now.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if now.live {
                Text("● live").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("player-live")
            }
            Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("player-chevron")

            Button { player.stop(); rips.setNowPlaying(nil) } label: {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("player-close")
        }
    }

}

/// The time-updating part of the panel — waveform + scrubber + time labels. Extracted
/// into its OWN view so reading `player.currentTime` (updates ~4×/s) re-renders only this
/// subview, NOT `InlinePlayerPanel`'s control buttons. On macOS those buttons would
/// otherwise be rebuilt 4×/s and intermittently drop clicks (the "freeze until you click
/// the slide-out" bug); isolating the churn here keeps play/pause · ✕ · chevron responsive.
private struct InlinePlayerExpanded: View {
    @Environment(PlayerEngine.self) private var player
    @State private var scrubbing: Double?
    let now: RipsStore.NowPlaying

    var body: some View {
        if now.live {
            // A live HLS stream has no static duration to scrub against — show a live state.
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent2)
                Text("Streaming live as it rips").font(.caption2).foregroundStyle(Theme.fgDim)
                Spacer()
            }
            .frame(height: 36)
            .accessibilityIdentifier("player-wave-live")
        } else {
            VStack(spacing: 8) {
                if let wave = now.waveform {
                    // The waveform thumbnail. We do NOT use `AsyncImage`: on macOS its
                    // internal phase-transition churn, sitting next to the inline player's
                    // control buttons, makes those buttons drop clicks (the "dead slide-out
                    // play/pause · chevron · ✕" bug — proven by a UI test toggle-count
                    // probe). `WaveformView` loads the bytes once via URLSession and shows
                    // the result with a single state update, so the controls stay live.
                    WaveformView(url: wave)
                }
                scrubber
            }
        }
    }

    private var scrubber: some View {
        // The live position is SAMPLED on a `TimelineView` schedule rather than observed:
        // `player.clock.currentTime` is a plain, non-`@Observable` value, so a tick redraws
        // ONLY this TimelineView's content and never invalidates Observation state in the
        // panel — keeping the sibling control buttons' identity stable so their clicks
        // aren't dropped. Duration is observable (changes once per track) → slider range.
        let duration = max(player.duration, 0.01)
        return TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = scrubbing ?? player.clock.currentTime
            // Full-width slider so it lines up edge-to-edge with the waveform above it;
            // the elapsed / duration labels sit BELOW, flanking the two ends.
            VStack(spacing: 2) {
                Slider(value: Binding<Double>(get: { now }, set: { scrubbing = $0 }),
                       in: 0...duration) { editing in
                    if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                }
                .accessibilityIdentifier("player-seek")
                HStack {
                    Text(Self.clock(now))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Text(Self.clock(duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// The waveform thumbnail. Loads the image bytes ONCE with `URLSession` into a single
/// `@State`, rather than using `AsyncImage` — whose phase-transition churn, hosted next
/// to the inline player's control buttons, dropped their clicks on macOS (the dead
/// slide-out-buttons bug). A placeholder shows until the one-shot load resolves; the
/// resulting single state update doesn't disturb the sibling buttons' hit-testing.
private struct WaveformView: View {
    let url: URL
    @State private var image: Image?

    var body: some View {
        // A FIXED-SIZE container whose content swaps via `.overlay` (not an `if/else`
        // structural branch). Loading the image therefore neither resizes nor restructures
        // this view, so the enclosing panel never re-lays-out — and the sibling control
        // buttons keep their identity (their clicks aren't dropped) when the waveform
        // resolves. This is why we avoid `AsyncImage`, whose phase swaps DID restructure.
        // The image is the BACKGROUND of a fixed 36-pt container, scaled to FILL so it spans
        // the panel EDGE-TO-EDGE (lining up with the full-width scrubber below it), with any
        // vertical overflow CLIPPED to the fixed container by the `.clipShape`. The container
        // is non-interactive and can't resize the panel or reach the control buttons above —
        // so edge-to-edge fill does NOT reintroduce the slide-out-button breakage.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .background {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.bgOverlay)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .allowsHitTesting(false)
            .accessibilityIdentifier("player-wave")
            .task(id: url) {
                guard image == nil else { return }
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    #if canImport(UIKit)
                    if let ui = UIImage(data: data) { image = Image(uiImage: ui) }
                    #elseif canImport(AppKit)
                    if let ns = NSImage(data: data) { image = Image(nsImage: ns) }
                    #endif
                }
            }
    }
}
