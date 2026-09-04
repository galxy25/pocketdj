#if os(tvOS)
import SwiftUI

// ============================================================================
// MARK: - Apple TV root shell
// ============================================================================

/// The Apple TV app (Levi's spec, 2026-09-01). The TV is a LEAN-BACK player, so it gets a
/// focus-native `TabView` shell instead of the split-view + resizable Now Playing machinery
/// RootView runs everywhere else — same app-scoped stores, same launch pipeline (RootView
/// attaches `launchActions()` to this view on tvOS), different furniture.
///
/// The tab set IS the TV feature set (reshaped by Levi's on-device pass, 2026-09-02):
///   • **Now Playing** — the DEFAULT tab: the shared home deck (`NowPlayingPanel` whole —
///     record, transport, Up Next, its own add-search). The old bottom NP strip is gone.
///   • **Mix** — Auto DJ, pared down to "pick a collection, Play/Shuffle". The omni search
///     column was removed on-device: Browse owns library search now. No manual decks.
///   • **Browse** — the collections (playlists / pockets / set lists) in the SAME detail
///     views every platform uses (`pocketDJDestinations`), plus a library-wide search bar
///     (songs / artists / albums / collections). Play/Shuffle a long-press away per row.
///   • **For You** — the same tile grid History carries elsewhere; read-only + play.
///   • **Jukebox** — the HOST surface: the session QR on the big screen is the whole point
///     of a TV jukebox (the room scans the television).
///   • **Settings** — profile, the iCloud sync toggle, and the synced connection
///     credentials — EDITABLE here (focusable rows are also what lets tvOS scroll; the
///     read-only LabeledContent rows were a focus trap that pinned the Form at "Sync now").
///     Normally they just arrive via the settings-credentials cloud doc.
///
/// There is deliberately NO Producer tab (owner: "NO Producer surface at all") and no
/// History/Games — the TV is for playing music, not editing it.
struct TVRootView: View {
    enum TVTab: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing"
        case mix = "Mix"
        case browse = "Browse"
        case forYou = "For You"
        case jukebox = "Jukebox"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .nowPlaying: return "play.circle"
            case .mix:      return "wand.and.stars"
            case .browse:   return "music.note.list"
            case .forYou:   return "sparkles"
            case .jukebox:  return "qrcode"
            case .settings: return "gearshape"
            }
        }
    }

    /// Now Playing is the launch tab (Levi, on-device 2026-09-02 — supersedes the original
    /// Mix-default spec); the bottom NP strip is gone with it.
    @State private var tab: TVTab = .nowPlaying
    /// Multi-select plumbing some shared rows read from the environment (CollectionSongRow
    /// etc.). The TV never drag-selects, but the environment object must exist for the
    /// shared detail views to render — one per shell, exactly like RootView's per-window one.
    @State private var rowSelection = RowSelection()

    var body: some View {
        TabView(selection: $tab) {
            TVNowPlayingView()
                .tabItem { Label(TVTab.nowPlaying.rawValue, systemImage: TVTab.nowPlaying.icon) }
                .tag(TVTab.nowPlaying)
            TVMixView()
                .tabItem { Label(TVTab.mix.rawValue, systemImage: TVTab.mix.icon) }
                .tag(TVTab.mix)
            TVBrowseView()
                .tabItem { Label(TVTab.browse.rawValue, systemImage: TVTab.browse.icon) }
                .tag(TVTab.browse)
            TVForYouView()
                .tabItem { Label(TVTab.forYou.rawValue, systemImage: TVTab.forYou.icon) }
                .tag(TVTab.forYou)
            TVJukeboxView()
                // tabItem honors only Text/Image — the custom pride-jukebox VIEW rendered as a
                // BLANK tab (Levi, live 2026-09-02). The tab keeps the qrcode symbol; the pride
                // jukebox lives on the landing page, where a real view context renders it.
                .tabItem { Label(TVTab.jukebox.rawValue, systemImage: TVTab.jukebox.icon) }
                .tag(TVTab.jukebox)
            TVSettingsView()
                .tabItem { Label(TVTab.settings.rawValue, systemImage: TVTab.settings.icon) }
                .tag(TVTab.settings)
        }
        .environment(rowSelection)
        // Telemetry breadcrumb: TV tab changes — the TV's "what is presented" line.
        .onChange(of: tab) { DiagLog.shared.telemetry("screen", "tv tab=\(tab.rawValue)") }
        // The app-level .tint(Theme.accent) makes tvOS draw button platters AND labels in
        // the accent (solid unreadable capsules). Resetting to nil hands the controls back
        // to the system focus chrome; the brand accent stays on explicit icons/text.
        .tint(nil as Color?)
        .background(Theme.bg.ignoresSafeArea())
        // Headless-verification seam (mirrors PDJ_START_SECTION): land on a named tab at
        // launch so `simctl` can screenshot each surface without driving the focus engine.
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["PDJ_TV_TAB"],
               let t = TVTab(rawValue: raw) {
                tab = t
            }
        }
    }
}

// ============================================================================
// MARK: - Now Playing — the default tab
// ============================================================================

/// The DEFAULT TV tab (Levi, on-device 2026-09-02): the same home Now Playing deck every
/// other platform gets — gold record, transport, Up Next, played history, and the panel's
/// own add-search — reused whole rather than rebuilt. `NowPlayingPanel` hides its deck
/// machinery behind `isVisible`, so an idle app gets an honest empty state with focusable
/// jump-offs instead of a blank screen (a TV tab must never render nothing).
struct TVNowPlayingView: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(MixEngine.self) private var mix

    var body: some View {
        Group {
            if NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix) {
                // The sequencer gets the same owner-spec CARD shape the mix already has —
                // NOT the shared NowPlayingPanel. The panel's body is a `List`, and mounting
                // a List inside this tab's ScrollView collapses it to ZERO height on tvOS:
                // the field "Now Playing tab blank during an external Apple Music set"
                // (device tvos-8E34293E, build 1788407269) — isVisible TRUE, panel MOUNTED
                // (no "np EMPTY" marker), nothing laid out. The card sources everything from
                // the sequencer's queue + the coordinator/player clocks, so it renders the
                // same for a burned-local set and an external AM stream (whose LOCAL engine
                // is idle — data was never the panel's problem; layout was).
                TVSetlistNowPlayingCard()
            } else if mix.autoMixing || mix.isRunning {
                // The shared panel is SEQUENCER-only — mounting it for a Mix-owned session
                // rendered a blank deck here (Levi, live TV 2026-09-02). Owner's spec for this
                // tab, verbatim shape: "the main title card for the current track with the
                // album art, artist and title and playback [position] and then the queue of up
                // next songs and button to show the previously played songs" — ONE presentation
                // regardless of source. The mix gets that card here; the Mix tab keeps its
                // control-room surface.
                TVMixNowPlayingCard()
            } else {
                ContentUnavailableView {
                    Label("Nothing playing", systemImage: "play.circle")
                } description: {
                    Text("Start a collection from Browse, an Auto DJ mix from Mix, or a For You pick — playback lands here.")
                }
                // Field diagnosability: an empty Now Playing while audio is audible is a GATE
                // bug — stream the gate's actual inputs so the session log names the flag.
                .onAppear {
                    DiagLog.shared.telemetry(
                        "screen", "np EMPTY seq=\(sequencer.isRunning) mixRun=\(mix.isRunning) auto=\(mix.autoMixing) autoPaused=\(mix.autoPaused)")
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .accessibilityIdentifier("tv-now-playing")
    }
}

// ============================================================================
// MARK: - Mix (Auto DJ)
// ============================================================================

/// TV Mix = Auto DJ only. Everything rides the SAME app-scoped `MixEngine` + intent door
/// (`IntentServices.startAutoMix`) the phone uses, so a mix started on the TV persists,
/// snapshots, and honors lead/fade settings identically. The manual two-deck board is
/// deliberately absent — a remote is no place to ride a crossfader.
struct TVMixView: View {
    @Environment(MixEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(SettingsStore.self) private var settings
    @Environment(IntentServices.self) private var intents
    @Environment(RipsStore.self) private var rips
    @Environment(CollectionMixDownloader.self) private var downloader
    @Environment(BurnStore.self) private var burns
    @Environment(SetlistPlayer.self) private var sequencer

    @State private var path = NavigationPath()
    /// The chosen crates — one per deck, mirroring the CarPlay Mix tab. Deck A is required;
    /// Deck B nil means "same as Deck A" (the ordinary single-crate mix). Pockets + set lists,
    /// the same source kinds MixView's auto picker offers (both resolve to BURNED loadables).
    @State private var deckA: MixSource?
    @State private var deckB: MixSource?
    @State private var startError: String?

    var body: some View {
        NavigationStack(path: $path) {
            // Single centered column — the omni-search side column was removed on Levi's
            // on-device call (2026-09-02): Browse owns library search, the Now Playing tab's
            // panel owns add-to-queue search, and the Mix surface stays a clean Auto DJ deck.
            // ScrollView so the (focusable) queue tail is reachable — tvOS scrolls by focus.
            ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if engine.autoMixing {
                    TVMixLiveSurface()
                } else {
                    setupCard
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 1100, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 64)
            .padding(.vertical, 40)
            .frame(maxHeight: .infinity, alignment: .top)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Mix")
            .pocketDJDestinations(path: $path)
            // A durable mix session restored at launch stays PARKED until a Mix surface
            // materializes it — same contract as MixView's `.task` on the phone/Mac, honored
            // here so a force-quit TV mix comes back cued + suspended instead of never.
            .task { engine.materializePendingRestoreIfNeeded() }
        }
    }

    // MARK: Auto DJ — setup (no mix running)

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Auto DJ", systemImage: "wand.and.stars")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.fg)
            Text("Pick a crate per deck and press Start — PocketDJ shuffles both and beat-mixes them for the room.")
                .font(.callout)
                .foregroundStyle(Theme.fgDim)
            // Two deck selectors, mirroring the CarPlay Mix tab: A is required, B defaults to
            // "same as A". Menu is tvOS's picker idiom (focusable; no segmented style exists).
            HStack(spacing: 20) {
                Menu {
                    crateMenuItems { deckA = $0 }
                } label: {
                    Label("A · \(crateName(deckA) ?? "Pick a crate")", systemImage: "a.circle.fill")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("tv-mix-source")
                Menu {
                    Button("Same as Deck A") { deckB = nil }
                    crateMenuItems { deckB = $0 }
                } label: {
                    Label("B · \(crateName(deckB) ?? "Same as Deck A")", systemImage: "b.circle.fill")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("tv-mix-source-b")
            }
            TVGlideToggles()
            HStack(spacing: 20) {
                Button { start(shuffled: true) } label: {
                    Label("Start Mix", systemImage: "shuffle")
                }
                .disabled(deckA == nil)
                .accessibilityIdentifier("tv-mix-shuffle")
                // The in-order start stays for a prepared set (a wedding's set list plays as
                // written); the shuffled Start above is the room's default.
                Button { start(shuffled: false) } label: {
                    Label("In order", systemImage: "play.fill")
                }
                .disabled(deckA == nil)
                .accessibilityIdentifier("tv-mix-play")
            }
            if let startError {
                Label(startError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("tv-mix-error")
            }
            // ZERO-START state: nothing was on disk, the download run is pulling, and the mix
            // starts itself on the first landing — same contract as the phone's Mix tab.
            if downloader.isActive && downloader.downloadedCount < downloader.totalCount {
                Label {
                    Text("Downloading \(downloader.downloadedCount) of \(downloader.totalCount)"
                         + (downloader.rippingCount > 0 ? " · \(downloader.rippingCount) ripping" : "")
                         + " — the mix starts when the first track lands")
                        .font(.callout.monospacedDigit())
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("tv-mix-downloading")
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }


    /// Crate rows for one deck's Menu — pockets + set lists (the two kinds that resolve
    /// through MixResolver into burned loadables), same as MixView's auto picker.
    @ViewBuilder private func crateMenuItems(pick: @escaping (MixSource) -> Void) -> some View {
        if collections.pockets.isEmpty && collections.visibleSetlists.isEmpty {
            Text("No pockets or set lists yet — build one on iPhone, iPad, or Mac.")
        }
        if !collections.pockets.isEmpty {
            Section("Pockets") {
                ForEach(collections.pockets) { p in
                    Button(p.name) { pick(.pocket(p.id)) }
                }
            }
        }
        if !collections.visibleSetlists.isEmpty {
            Section("Set lists") {
                ForEach(collections.visibleSetlists) { s in
                    Button(s.name ?? "Set list") { pick(.setlist(s.id)) }
                }
            }
        }
    }

    private func crateName(_ source: MixSource?) -> String? {
        switch source {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }

    private func start(shuffled: Bool) {
        guard let a = deckA else { return }
        startError = nil
        Task {
            do {
                // The two-crate start (deck B = A when unset) — per-crate shuffle + interleave,
                // same path as the CarPlay Mix tab, so both remotes behave identically.
                // allowPendingStart: an unburned collection kicks the download run and the mix
                // starts on the first landing (the setup card's downloading line says so).
                _ = try await intents.startAutoMix(deckA: a, deckB: deckB ?? a, shuffle: shuffled,
                                                   allowPendingStart: true)
            } catch {
                // The intent error strings are already user-facing ("no burned songs…").
                startError = String(localized: (error as? PocketDJIntentError)?.localizedStringResource
                    ?? "That collection can’t start a mix right now.")
            }
        }
    }



}




// ============================================================================
// MARK: - Unified Now Playing card (mix-owned playback)
// ============================================================================

/// The Now Playing tab's ONE presentation when the MIX owns playback: big album art, artist +
/// title, live position, whole-mix transport, the Up Next queue, and a toggle revealing the
/// previously-played list. Mirrors what the shared panel gives a sequencer set, sourced from
/// the engine instead — the tab never again renders blank while music is audibly playing.
/// The Now Playing tab's SEQUENCER card — the owner's verbatim shape ("main title card …
/// album art, artist and title and playback [position] … queue of up next songs and button
/// to show the previously played songs"), for collection playback, mirroring
/// `TVMixNowPlayingCard`. Current track = `sequencer.queue[index]` (the ephemeral run's
/// truth on every platform); elapsed/length prefer the Apple Music coordinator clock when
/// the stream is external, falling back to the local engine + the catalog snapshot — the
/// `NowPlayingDeckCluster.playProgress` chain, without the List that couldn't lay out here.
struct TVSetlistNowPlayingCard: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(AppModel.self) private var app
    @State private var showPlayed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 26) {
                if let item = current {
                    artwork(for: item)
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("tv-np-set-title")
                        Text(item.artist)
                            .font(.title2)
                            .foregroundStyle(Theme.fgDim)
                            .lineLimit(1)
                    }
                    positionLine(for: item)
                    transport
                }
                queueSection
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 64)
            .padding(.vertical, 40)
        }
    }

    private var current: SetlistPlayer.Item? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        return sequencer.queue[sequencer.index]
    }

    /// Catalog album art first; an external Apple Music stream with no indexed album (a
    /// jukebox/AM insert) falls back to the artwork MusicKit captured at play time.
    @ViewBuilder private func artwork(for item: SetlistPlayer.Item) -> some View {
        if let album = app.album(forSongId: item.id) {
            CoverImage(album: album, corner: 20)
                .frame(width: 420, height: 420)
                .accessibilityIdentifier("tv-np-set-art")
        } else if coordinator.isAppleMusicNowPlaying(item.id),
                  let url = coordinator.appleMusic.nowPlaying?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bgRaised)
            }
            .frame(width: 420, height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("tv-np-set-art")
        }
    }

    /// m:ss / m:ss — elapsed from whichever engine OWNS the audio (external Apple Music
    /// streams publish via the coordinator; the local engine is idle then), length from the
    /// catalog snapshot → decoded duration → resolved MusicKit duration, in that order.
    private func positionLine(for item: SetlistPlayer.Item) -> some View {
        let am = coordinator.isAppleMusicNowPlaying(item.id)
        let elapsed = am ? coordinator.appleMusic.positionSeconds : player.currentTime
        let length = max(item.lengthMs.map { Double($0) / 1000 } ?? 0,
                         player.duration,
                         am ? coordinator.appleMusic.durationSeconds : 0)
        return Text("\(Self.mmss(elapsed))\(length > 0 ? " / \(Self.mmss(length))" : "")")
            .font(.title3.monospacedDigit())
            .foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("tv-np-set-position")
    }

    private static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Button { sequencer.skipPrevious() } label: {
                Label("Previous", systemImage: "backward.fill")
            }
            .accessibilityIdentifier("tv-np-set-prev")
            Button {
                NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator,
                                                player: player)
            } label: {
                let playing = NowPlayingPanel.isPlayingNow(coordinator: coordinator, player: player)
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
            }
            .accessibilityIdentifier("tv-np-set-toggle")
            Button { sequencer.skipNext() } label: {
                Label("Next", systemImage: "forward.fill")
            }
            .accessibilityIdentifier("tv-np-set-next")
            Button { showPlayed.toggle() } label: {
                Label(showPlayed ? "Up next" : "Played",
                      systemImage: showPlayed ? "list.bullet" : "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("tv-np-set-played")
        }
    }

    /// Up Next by default; the Played toggle swaps in the consumed head, newest first —
    /// the same focusable no-op rows as the mix card (tvOS scrolls by focus).
    @ViewBuilder private var queueSection: some View {
        let rows: [SetlistPlayer.Item] = showPlayed
            ? sequencer.queue[..<min(sequencer.index, sequencer.queue.count)].reversed()
            : Array(sequencer.queue.dropFirst(sequencer.index + 1))
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(showPlayed ? "Previously played" : "Up next")
                    .font(.headline)
                    .foregroundStyle(Theme.fgDim)
                ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { i, item in
                    Button {} label: {
                        HStack(spacing: 12) {
                            Text("\(i + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.fgDim)
                                .frame(width: 36, alignment: .trailing)
                            Text(item.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                            Text("· \(item.artist)").font(.callout).foregroundStyle(Theme.fgDim).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if rows.count > 50 {
                    Text("+ \(rows.count - 50) more")
                        .font(.callout)
                        .foregroundStyle(Theme.fgDim)
                        .padding(.leading, 48)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVMixNowPlayingCard: View {
    @Environment(MixEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var app
    @Environment(FavoritesStore.self) private var favorites
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    @State private var showPlayed = false



    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 26) {
                if let track = engine.onAirTrack {
                    if let albumId = track.albumId, let album = app.albumsById[albumId] {
                        CoverImage(album: album, corner: 20)
                            .frame(width: 420, height: 420)
                            .accessibilityIdentifier("tv-np-mix-art")
                    }
                    VStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("tv-np-mix-title")
                        Text(track.artist)
                            .font(.title2)
                            .foregroundStyle(Theme.fgDim)
                            .lineLimit(1)
                    }
                    positionLine
                    transport
                    secondStrip
                    if let status = engine.autoStatus {
                        Text(status).font(.callout.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    }
                }
                queueSection
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 64)
            .padding(.vertical, 40)
        }
    }

    /// m:ss / m:ss for the on-air deck. Reads the 10 Hz observable position — fine for one Text.
    private var positionLine: some View {
        let deck = engine.nowPlayingDeck
        let pos = deck.map { engine.position($0) } ?? 0
        let dur = deck.map { engine.duration($0) } ?? 0
        return Text("\(Self.mmss(pos)) / \(Self.mmss(dur))")
            .font(.title3.monospacedDigit())
            .foregroundStyle(Theme.fgDim)
    }

    private static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var transport: some View {
        HStack(spacing: 20) {
            if engine.autoPaused {
                Button {
                    engine.remotePlay()
                    if engine.autoMixing, engine.autoPaused { engine.resumeAuto() }
                } label: { Label("Resume", systemImage: "play.fill") }
                    .accessibilityIdentifier("tv-np-mix-resume")
            } else {
                Button { engine.remotePause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .accessibilityIdentifier("tv-np-mix-pause")
            }
            Button { engine.remoteSkip(fadeSeconds: 5) } label: {
                Label("Skip · quick", systemImage: "forward.fill")
            }
            Button { engine.remoteSkip(fadeSeconds: settings.skipFadeSeconds) } label: {
                Label("Skip · blend", systemImage: "forward.end.fill")
            }
            TVRepeatButton(a11yId: "tv-np-mix-repeat")
            Button { showPlayed.toggle() } label: {
                Label(showPlayed ? "Up next" : "Played", systemImage: showPlayed ? "list.bullet" : "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("tv-np-mix-played")
        }
    }

    /// Second strip (owner's spec): ♥ · shuffle the queue · 👍 · 👎. The repeat toggle lives
    /// on the transport row above (`TVRepeatButton` — engine-backed, task #52).
    private var secondStrip: some View {
        HStack(spacing: 20) {
            if let track = engine.onAirTrack {
                let fav = favorites.isFavorite(track.songId)
                Button {
                    _ = favorites.toggle(track.songId,
                                         appleMusicId: app.songsById[track.songId]?.appleMusicId)
                } label: {
                    Label(fav ? "Loved" : "Love", systemImage: fav ? "heart.fill" : "heart")
                        .foregroundStyle(fav ? Theme.accent : Theme.fg)
                }
                .accessibilityIdentifier("tv-np-mix-heart")
            }
            Button { engine.autoQueueShuffleUpcoming() } label: {
                Label("Shuffle queue", systemImage: "shuffle")
            }
            .accessibilityIdentifier("tv-np-mix-shuffle")
            // 👍/👎 ONLY when the playing track is a RECOMMENDATION (owner: show them only
            // where they actually have effect) — the same hide-when-inert rule every other
            // surface uses (`scope(forPlaying:)` membership check). An ordinary crate mix has
            // no rec scope, so the pair simply isn't there.
            if let feedback, let track = engine.onAirTrack,
               let scope = feedback.scope(forPlaying: track.songId) {
                let verdict = feedback.verdict(songId: track.songId, scope: scope)
                Button {
                    _ = feedback.toggle(songId: track.songId, to: .accepted, scope: scope,
                                        surface: .nowPlaying, artistKey: nil, genre: nil)
                } label: {
                    Image(systemName: verdict == .accepted ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .accessibilityIdentifier("tv-np-mix-thumbsup")
                Button {
                    _ = feedback.toggle(songId: track.songId, to: .rejected, scope: scope,
                                        surface: .nowPlaying, artistKey: nil, genre: nil)
                } label: {
                    Image(systemName: verdict == .rejected ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .accessibilityIdentifier("tv-np-mix-thumbsdown")
            }
        }
        .font(.callout)
    }

    /// Up Next by default; the Played toggle swaps in the consumed head, newest first.
    @ViewBuilder private var queueSection: some View {
        let rows = showPlayed ? engine.autoPlayedDetailed : engine.autoUpcomingDetailed
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(showPlayed ? "Previously played" : "Up next")
                    .font(.headline)
                    .foregroundStyle(Theme.fgDim)
                // FOCUSABLE rows (no-op Buttons) — tvOS scrolls by focus, so display-only
                // rows capped the list at a screenful (owner: both queues must scroll).
                let locked = engine.autoUpcomingLockedCount
                ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { i, row in
                    let l = row.loadable
                    Button {} label: {
                        HStack(spacing: 12) {
                            Text("\(i + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.fgDim)
                                .frame(width: 36, alignment: .trailing)
                            Text(l.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                            Text("· \(l.artist)").font(.callout).foregroundStyle(Theme.fgDim).lineLimit(1)
                            Text(tvQueueProvenance(index: i, liveDeck: engine.autoLiveDeck,
                                                   sourceLabel: row.sourceLabel))
                                .font(.callout)
                                .foregroundStyle(Theme.fgDim)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    // Long-press (owner's spec): play next / play last / remove (up-next only).
                    // Committed rows (a deck holds them) omit the menu — moving them is the
                    // in-mix-precedence violation autoQueueInsert documents.
                    .contextMenu {
                        if showPlayed {
                            Button("Play next") {
                                engine.autoQueueInsert(
                                    MixEngine.AutoMixItem(loadable: l, durationMs: l.lengthMs ?? 180_000),
                                    placement: .next)
                            }
                            Button("Play last") {
                                engine.autoQueueInsert(
                                    MixEngine.AutoMixItem(loadable: l, durationMs: l.lengthMs ?? 180_000),
                                    placement: .end)
                            }
                        } else if i >= locked {
                            Button("Play next") { engine.autoQueueMoveUpcoming(offset: i, toEnd: false) }
                            Button("Play last") { engine.autoQueueMoveUpcoming(offset: i, toEnd: true) }
                            Button("Remove from queue", role: .destructive) {
                                engine.autoQueueRemoveUpcoming(offset: i)
                            }
                        }
                    }
                }
                if rows.count > 50 {
                    Text("+ \(rows.count - 50) more")
                        .font(.callout)
                        .foregroundStyle(Theme.fgDim)
                        .padding(.leading, 48)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// ============================================================================
// MARK: - Mix live surface (shared: Mix tab + Now Playing tab)
// ============================================================================

/// The Auto-DJ repeat toggle — ENGINE state (`MixEngine.autoRepeat`, persisted with the
/// durable auto session), cycling off → all → one on each press (standard transport
/// convention, standard glyphs: `repeat` / `repeat.1`). One view, two surfaces (the Now
/// Playing card's second strip + the live surface's transport row) — the a11y id tells
/// them apart for UI tests.
struct TVRepeatButton: View {
    @Environment(MixEngine.self) private var engine
    let a11yId: String
    var body: some View {
        Button { engine.cycleAutoRepeat() } label: {
            Label(title, systemImage: engine.autoRepeat == .one ? "repeat.1" : "repeat")
                .foregroundStyle(engine.autoRepeat == .off ? Theme.fgDim : Theme.accent)
        }
        .accessibilityIdentifier(a11yId)
    }
    private var title: String {
        switch engine.autoRepeat {
        case .off: "Repeat"
        case .all: "Repeat · all"
        case .one: "Repeat · one"
        }
    }
}

/// One queue row's provenance suffix: "— A · Crate name" (deck letter + the crate the row
/// came from). The deck letter is derived in the VIEW from strict alternation: row i of
/// EITHER list lands on `i % 2 == 0 ? standby : live` — upcoming[i] = queue[livePos+1+i]
/// and played[j] = queue[livePos-1-j] sit at the same parity distance from the live slot.
/// BEST-EFFORT by design: it drifts after unloadable drops, which is accepted (the crate
/// name is the load-bearing half).
private func tvQueueProvenance(index: Int, liveDeck: MixEngine.Deck,
                               sourceLabel: String?) -> String {
    let live = liveDeck.rawValue
    let standby = liveDeck == .a ? "B" : "A"
    let letter = index % 2 == 0 ? standby : live
    guard let sourceLabel, !sourceLabel.isEmpty else { return "— \(letter)" }
    return "— \(letter) · \(sourceLabel)"
}

/// FX Glide + Audio Glide — ENGINE state (persists with the durable mix session), not
/// settings; safe to flip mid-mix (applies from the next transition). A standalone view so
/// the Mix setup card AND the shared live surface both render the one pair.
struct TVGlideToggles: View {
    @Environment(MixEngine.self) private var engine
    var body: some View {
        HStack(spacing: 28) {
            Toggle("FX Glide", isOn: Binding(
                get: { engine.fxGlideEnabled },
                set: { engine.setFXGlide($0) }))
                .accessibilityIdentifier("tv-mix-fx-glide")
            Toggle("Audio Glide", isOn: Binding(
                get: { engine.mixGlideEnabled },
                set: { engine.setMixGlide($0) }))
                .accessibilityIdentifier("tv-mix-audio-glide")
        }
        .toggleStyle(.button)
        .font(.callout)
    }
}

/// The FX / STEMS / TEMPO / PITCH row above the Auto DJ box. Every control scopes to the
/// LEAD (currently playing) deck — the owner's tvOS call: the TV drives what the room hears;
/// the per-deck board stays on the other platforms. Long-press (contextMenu) on an
/// FX button offers preset strengths; on a stem button, preset volumes — the TV stand-ins for
/// the other platforms' long-press sliders, driving the same engine setters.
struct TVMixControlsRow: View {
    @Environment(MixEngine.self) private var engine

    private static let fxLabels: [(MixEngine.Effect, String, String)] = [
        (.compressor, "Comp", "waveform.badge.minus"),
        (.reverb, "Reverb", "building.columns"),
        (.flanger, "Flanger", "water.waves"),
        (.filter, "Filter", "slider.horizontal.3"),
    ]
    private static let stemLabels: [(String, String)] = [
        ("vocals", "Vocals"), ("drums", "Drums"), ("bass", "Bass"), ("other", "Other"),
    ]

    /// The LEAD deck — every control here scopes to what the room is HEARING (owner's call:
    /// per-deck board semantics stay on the other platforms; the TV drives the live deck).
    private var deck: MixEngine.Deck { engine.nowPlayingDeck ?? .a }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(Self.fxLabels, id: \.1) { fx, label, icon in
                    let on = engine.isEnabled(fx, on: deck)
                    Button {
                        engine.setEffect(fx, enabled: !on, on: deck)
                    } label: {
                        Label(label, systemImage: icon)
                            .foregroundStyle(on ? Theme.accent : Theme.fg)
                    }
                    .accessibilityIdentifier("tv-mix-fx-\(fx.rawValue)")
                    .contextMenu {
                        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { v in
                            Button("Strength \(Int(v * 100))%") {
                                engine.setEffectStrength(fx, v, on: deck)
                                if !on { engine.setEffect(fx, enabled: true, on: deck) }
                            }
                        }
                    }
                }
                // Tempo / pitch nudges for the LEAD deck — grayed while a transition (incl.
                // glide) owns the decks, so a manual nudge can't fight the Auto DJ's ramps.
                let inTransition = engine.autoTransitioning
                HStack(spacing: 8) {
                    Button { engine.setRate(engine.rate(deck) - 0.01, on: deck) } label: {
                        Label("Tempo −", systemImage: "minus")
                    }
                    .accessibilityIdentifier("tv-mix-tempo-down")
                    Text("\(Int((engine.rate(deck) * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Button { engine.setRate(engine.rate(deck) + 0.01, on: deck) } label: {
                        Label("Tempo ＋", systemImage: "plus")
                    }
                    .accessibilityIdentifier("tv-mix-tempo-up")
                }
                .disabled(inTransition)
                HStack(spacing: 8) {
                    Button { engine.setPitch(engine.pitch(deck) - 1, on: deck) } label: {
                        Label("Pitch −", systemImage: "arrow.down")
                    }
                    .accessibilityIdentifier("tv-mix-pitch-down")
                    Text("\(Int(engine.pitch(deck).rounded()))")
                        .font(.callout.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Button { engine.setPitch(engine.pitch(deck) + 1, on: deck) } label: {
                        Label("Pitch ＋", systemImage: "arrow.up")
                    }
                    .accessibilityIdentifier("tv-mix-pitch-up")
                }
                .disabled(inTransition)
            }
            HStack(spacing: 18) {
                // Stem MODE + mutes for the LEAD deck only.
                let stemsOn = engine.stemModeOn(deck)
                Button {
                    engine.setStemMode(!stemsOn, on: deck)
                } label: {
                    Label("Stems", systemImage: "square.stack.3d.up")
                        .foregroundStyle(stemsOn ? Theme.accent : Theme.fg)
                }
                .accessibilityIdentifier("tv-mix-stems")
                ForEach(Self.stemLabels, id: \.0) { name, label in
                    let muted = engine.isStemMuted(name, on: deck)
                    Button {
                        if !stemsOn { engine.setStemMode(true, on: deck) }
                        engine.toggleStemMute(name, on: deck)
                    } label: {
                        Label(label, systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                            .foregroundStyle(muted ? Theme.fgDim : Theme.fg)
                    }
                    .accessibilityIdentifier("tv-mix-stem-\(name)")
                    .contextMenu {
                        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { v in
                            Button("Volume \(Int(v * 100))%") {
                                engine.setStemVolume(name, v, on: deck)
                            }
                        }
                    }
                }
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
    }
}

/// The RUNNING mix's whole surface — live card (on-air, status, transport, glide, download
/// line) + Up Next — extracted from TVMixView so the Now Playing tab renders the SAME thing
/// when the mix owns playback (the shared NowPlayingPanel is sequencer-only and mounted
/// blank for a Mix session; Levi, live TV 2026-09-02).
struct TVMixLiveSurface: View {
    @Environment(MixEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    @Environment(CollectionMixDownloader.self) private var downloader

    var body: some View {
        // Owner (live TV, 2026-09-02): "above the auto DJ ui box we should have buttons for
        // enabling the effects and toggling off or on stems, with long click triggering the
        // sliders" — long-press (contextMenu, the proven tvOS idiom) offers preset strengths/
        // volumes in place of sliders, which tvOS does not have (TVCompat's Slider is
        // read-only); the presets drive the SAME setEffectStrength/setStemVolume the other
        // platforms' sliders do.
        TVMixControlsRow()
        liveCard
        upNext
    }

    
    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                Text(engine.autoPaused ? "Auto DJ — paused" : "Auto DJ")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.fg)
                if let label = engine.autoSourceLabel {
                    Text(label).font(.callout).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
            }
            if let track = engine.onAirTrack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(2)
                        .accessibilityIdentifier("tv-mix-nowplaying-title")
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                }
            }
            if let status = engine.autoStatus {
                Text(status)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
            }
            HStack(spacing: 20) {
                if engine.autoPaused {
                    // The lock-screen seam is the ONE pause that silences the decks and
                    // freezes the transition clock (in-app pauseAuto keeps audio running
                    // for hand-mixing — meaningless on a TV). An explicit "Resume" must also
                    // clear a pause that ORIGINATED in-app, which remotePlay alone no-ops on.
                    Button {
                        engine.remotePlay()
                        if engine.autoMixing, engine.autoPaused { engine.resumeAuto() }
                    } label: { Label("Resume", systemImage: "play.fill") }
                        .accessibilityIdentifier("tv-mix-resume")
                } else {
                    Button { engine.remotePause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .accessibilityIdentifier("tv-mix-pause")
                }
                // FAST vs SLOW skip — the lock-screen pair (⏭ 5 s sweep / ⏮ long blend), as
                // two labeled buttons. `remoteSkip` (not `skipToNext`) so a skip pressed while
                // the mix is PAUSED un-suspends the machine first instead of being swallowed.
                Button { engine.remoteSkip(fadeSeconds: 5) } label: {
                    Label("Skip · quick", systemImage: "forward.fill")
                }
                .accessibilityIdentifier("tv-mix-skip")
                Button { engine.remoteSkip(fadeSeconds: settings.skipFadeSeconds) } label: {
                    Label("Skip · blend", systemImage: "forward.end.fill")
                }
                .accessibilityIdentifier("tv-mix-skip-slow")
                TVRepeatButton(a11yId: "tv-mix-repeat")
                Button(role: .destructive) { engine.stopAutoMix() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("tv-mix-stop")
            }
            TVGlideToggles()
            // A running mix that is still pulling its collection(s): late landings append to
            // the queue automatically — this line just says so.
            if downloader.isActive && downloader.downloadedCount < downloader.totalCount {
                Text("Downloading \(downloader.downloadedCount) of \(downloader.totalCount) · ~\(CollectionMixDownloader.etaLabel(downloader.etaSeconds)) left — new tracks join the queue")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The queue's not-yet-reached tail — displayed, not focusable (the queue is fed from
    /// the search column; showing ~8 rows + a "+N more" line avoids trapping TV focus in a
    /// list with no actions).
    @ViewBuilder private var upNext: some View {
        let upcoming = engine.autoUpcomingDetailed
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Up next")
                    .font(.headline)
                    .foregroundStyle(Theme.fgDim)
                // FOCUSABLE rows (no-op Buttons): tvOS scrolls BY FOCUS, so display-only rows
                // capped the queue at a screenful — the owner wants to browse the whole tail.
                ForEach(Array(upcoming.prefix(50).enumerated()), id: \.offset) { i, row in
                    let l = row.loadable
                    Button {} label: {
                        HStack(spacing: 12) {
                            Text("\(i + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.fgDim)
                                .frame(width: 36, alignment: .trailing)
                            Text(l.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                            Text("· \(l.artist)").font(.callout).foregroundStyle(Theme.fgDim).lineLimit(1)
                            Text(tvQueueProvenance(index: i, liveDeck: engine.autoLiveDeck,
                                                   sourceLabel: row.sourceLabel))
                                .font(.callout)
                                .foregroundStyle(Theme.fgDim)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if upcoming.count > 50 {
                    Text("+ \(upcoming.count - 50) more")
                        .font(.callout)
                        .foregroundStyle(Theme.fgDim)
                        .padding(.leading, 48)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// ============================================================================
// MARK: - Browse (collections)
// ============================================================================

/// The TV Browse tab: playlists / pockets / set lists as focusable rows. Press opens the
/// SAME detail screen every platform uses (via `pocketDJDestinations`); long-press offers
/// Play / Shuffle right from the row (the fastest remote path to sound). Playback goes
/// through `CollectionPlayback.start` — the app's one "start a set" door — so the durable
/// session, lock screen, and Now Playing behave exactly as everywhere else.
struct TVBrowseView: View {
    @Environment(CollectionsStore.self) private var collections
    @Environment(IntentServices.self) private var intents
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    /// Library-wide search (Levi, on-device 2026-09-02): songs, artists, albums, and
    /// collections that exist in YOUR catalog — local only, no Discover here.
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else if collections.playlists.isEmpty && collections.pockets.isEmpty
                    && collections.visibleSetlists.isEmpty {
                    ContentUnavailableView {
                        Label("No collections yet", systemImage: "music.note.list")
                    } description: {
                        Text("Build playlists and pockets on iPhone, iPad, or Mac — iCloud sync brings them here.")
                    }
                } else {
                    collectionList
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Browse")
            .pocketDJDestinations(path: $path)
        }
        .searchable(text: $query, prompt: "Songs, artists, albums, collections")
    }

    // MARK: Library search

    /// Ranked local results via the shared `NowPlayingSearch` helpers (same scorer the home
    /// panel's add-search uses), plus name-matched collections. Everything pushes the SAME
    /// shared detail screens; songs also offer Play from the context menu.
    private var searchResults: some View {
        let q = query
        let songHits = NowPlayingSearch.songs(matching: q, in: app.songs)
        let albumHits = NowPlayingSearch.albums(matching: q, in: app.albums)
        let artistHits = Array(Set(songHits.map(\.artist)).union(
            Set(albumHits.map(\.artist))).filter { $0.localizedCaseInsensitiveContains(q) })
            .sorted().prefix(6)
        let norm = q.lowercased()
        let playlistHits = collections.playlists.filter { $0.name.lowercased().contains(norm) }.prefix(6)
        let pocketHits = collections.pockets.filter { $0.name.lowercased().contains(norm) }.prefix(6)
        let setlistHits = collections.visibleSetlists.filter { ($0.name ?? "").lowercased().contains(norm) }.prefix(6)
        let empty = songHits.isEmpty && albumHits.isEmpty && artistHits.isEmpty
            && playlistHits.isEmpty && pocketHits.isEmpty && setlistHits.isEmpty
        return List {
            if empty {
                ContentUnavailableView.search(text: q)
            }
            if !playlistHits.isEmpty || !pocketHits.isEmpty || !setlistHits.isEmpty {
                Section("Collections") {
                    ForEach(Array(playlistHits)) { p in
                        row(value: p, icon: "music.note.list", name: p.name,
                            ids: { collections.playableIds(forPlaylist: p.id) })
                    }
                    ForEach(Array(pocketHits)) { p in
                        row(value: p, icon: "rectangle.stack", name: p.name,
                            ids: { collections.playableIds(forPocket: p.id) })
                    }
                    ForEach(Array(setlistHits)) { s in
                        row(value: s, icon: "list.number", name: s.name ?? "Set list",
                            ids: { collections.playableIds(forSetlist: s.id) })
                    }
                }
            }
            if !artistHits.isEmpty {
                Section("Artists") {
                    ForEach(Array(artistHits), id: \.self) { name in
                        NavigationLink(value: Artist(name: name)) {
                            HStack(spacing: 16) {
                                Image(systemName: "music.microphone").foregroundStyle(Theme.accent)
                                Text(name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            if !albumHits.isEmpty {
                Section("Albums") {
                    ForEach(albumHits) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 16) {
                                Image(systemName: "square.stack").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            if !songHits.isEmpty {
                Section("Songs") {
                    ForEach(songHits) { song in
                        NavigationLink(value: song) {
                            HStack(spacing: 16) {
                                Image(systemName: "music.note").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.name).lineLimit(1)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .contextMenu {
                            Button {
                                CollectionPlayback.start([song.id], title: song.name,
                                                         shuffle: false, intents: intents)
                            } label: { Label("Play", systemImage: "play.fill") }
                        }
                    }
                }
            }
        }
        .listStyle(.grouped)
    }

    private var collectionList: some View {
        List {
            if !collections.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(collections.playlists) { p in
                        row(value: p, icon: "music.note.list", name: p.name,
                            ids: { collections.playableIds(forPlaylist: p.id) })
                            .accessibilityIdentifier("tv-browse-playlist-\(p.id)")
                    }
                }
            }
            if !collections.pockets.isEmpty {
                Section("Pockets") {
                    ForEach(collections.pockets) { p in
                        row(value: p, icon: "rectangle.stack", name: p.name,
                            ids: { collections.playableIds(forPocket: p.id) })
                            .accessibilityIdentifier("tv-browse-pocket-\(p.id)")
                    }
                }
            }
            if !collections.visibleSetlists.isEmpty {
                Section("Set lists") {
                    ForEach(collections.visibleSetlists) { s in
                        row(value: s, icon: "list.number", name: s.name ?? "Set list",
                            ids: { collections.playableIds(forSetlist: s.id) })
                            .accessibilityIdentifier("tv-browse-setlist-\(s.id)")
                    }
                }
            }
        }
        .listStyle(.grouped)
    }

    /// One focusable collection row: push the shared detail on press; Play/Shuffle on
    /// long-press. `ids` is a closure so a pocket's DAG resolve only runs when the menu
    /// actually plays it, not per render.
    private func row(value: some Hashable, icon: String, name: String,
                     ids: @escaping () -> [String]) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 16) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(name).lineLimit(1)   // platter-adaptive (focused platter is white)
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            Button { CollectionPlayback.start(ids(), title: name, shuffle: false, intents: intents) } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button { CollectionPlayback.start(ids(), title: name, shuffle: true, intents: intents) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
    }
}

// ============================================================================
// MARK: - For You
// ============================================================================

/// The same For You tile grid History carries on the other platforms, wrapped in its own
/// stack. Tiles push their shared detail screens (New releases / ranked song lists), whose
/// toolbars already offer Play/Shuffle — read-only + play, per the TV spec.
struct TVForYouView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            // ForYouTilesView is its own ScrollView — no outer scroll wrapper.
            ForYouTilesView(path: $path)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle("For You")
                .pocketDJDestinations(path: $path)
        }
    }
}

// ============================================================================
// MARK: - Jukebox (host surface)
// ============================================================================

/// The TV Jukebox tab, reshaped to the owner's live-session spec (2026-09-02): a LIST of the
/// account's live jukebox sessions (from the broker's host-authed GET /sessions), and picking
/// one shows that session's QR FULL-SCREEN — the room scans the television; the phone stays
/// the hosting/management surface (queue, requests, decisions). A Start row creates a session
/// through the same store the phone uses.
///
/// Picking a LISTED session first ADOPTS it (`JukeboxStore.adopt`, added same night as this
/// spec): only the device that STARTED a session holds its `hostKey` and publishes state, so
/// sharing a session's QR from a device that didn't create it — e.g. Levi's phone started a
/// party, then he showed its QR off the TV — published nothing and guests saw a dead page.
/// Adoption fetches the session's real hostKey (host-authed GET /sessions/:id) and makes THIS
/// Apple TV its active publisher from that moment on, ending whatever it was hosting before
/// (never two publish loops at once).
struct TVJukeboxView: View {
    @Environment(JukeboxStore.self) private var jukebox
    @State private var rows: [JukeboxClient.SessionRow] = []
    @State private var loadError: String?
    @State private var fullScreen: JukeboxClient.SessionRow?
    /// The row currently mid-adopt (end-previous + fetch-hostKey + start loop) — disables the
    /// list and shows a spinner in place of that row's status text.
    @State private var adoptingId: String?

    var body: some View {
        Group {
            if let s = fullScreen {
                // FULL-SCREEN QR: the tab's whole point. Any remote press returns to the list.
                Button { fullScreen = nil } label: {
                    VStack(spacing: 24) {
                        JukeboxQRView(text: s.url.absoluteString)
                            .frame(width: 640, height: 640)
                        Text(s.name).font(.title2.weight(.semibold)).foregroundStyle(Theme.fg)
                        Text(s.url.absoluteString).font(.callout).foregroundStyle(Theme.fgDim)
                        if jukebox.session?.jukeboxId == s.jukeboxId {
                            Label("Hosting from this Apple TV", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.callout).foregroundStyle(Theme.accent)
                        } else if let err = jukebox.lastError {
                            Label(err, systemImage: "wifi.exclamationmark")
                                .font(.caption).foregroundStyle(Theme.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tv-jukebox-fullscreen")
            } else {
                sessionList
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await refresh() }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                // The pride jukebox, big, as the landing mark — live-colored while a session
                // runs (same mode rule as the iOS sidebar row).
                JukeboxIcon(mode: JukeboxIconMode.resolve(sessionActive: jukebox.session != nil, isPlaying: false))
                    .frame(width: 44, height: 56)
                Text("Jukebox sessions")
                    .font(.title2.weight(.semibold)).foregroundStyle(Theme.fg)
            }
            Text("Pick a session to host it from this Apple TV and show its QR.")
                .font(.callout).foregroundStyle(Theme.fgDim)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.danger)
            }
            ForEach(rows) { s in
                Button { Task { await select(s) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "qrcode")
                        Text(s.name).lineLimit(1)
                        Spacer()
                        if jukebox.session?.jukeboxId == s.jukeboxId {
                            Label("Hosting here", systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(Theme.accent)
                        } else if adoptingId == s.jukeboxId {
                            ProgressView()
                        } else {
                            Text("Host & show QR")
                                .font(.callout).foregroundStyle(Theme.fgDim)
                        }
                    }
                }
                .disabled(adoptingId != nil)
                .accessibilityIdentifier("tv-jukebox-session-\(s.jukeboxId)")
            }
            if rows.isEmpty && loadError == nil {
                Text("No live sessions.")
                    .font(.callout).foregroundStyle(Theme.fgDim)
            }
            Button {
                Task {
                    await jukebox.start(name: "Living Room")
                    await refresh()
                }
            } label: {
                Label("Start a session", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("tv-jukebox-start")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 900, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 64)
        .padding(.vertical, 40)
    }

    /// Picking a session makes THIS Apple TV its host from now on. If it's already the one
    /// this device is hosting, `adopt` below is a no-op and this just re-shows the QR. If the
    /// TV is hosting a DIFFERENT session, end that one first — `adopt`'s guard (mirroring
    /// `start()`) refuses to clobber an active session, and the point is one publish loop at
    /// a time, never two.
    private func select(_ s: JukeboxClient.SessionRow) async {
        adoptingId = s.jukeboxId
        defer { adoptingId = nil }
        if let active = jukebox.session, active.jukeboxId != s.jukeboxId {
            await jukebox.end()
        }
        await jukebox.adopt(jukeboxId: s.jukeboxId)
        fullScreen = s
    }

    private func refresh() async {
        do {
            rows = try await jukebox.listSessions()
            loadError = nil
        } catch {
            loadError = "Couldn't reach the jukebox server — check Settings."
        }
    }
}

// ============================================================================
// MARK: - Settings (minimal)
// ============================================================================

/// TV Settings = profile + iCloud sync + a READ-ONLY view of the synced connection
/// credentials. The TV deliberately has no credential-typing flow: servers and search
/// keys arrive via the settings-credentials cloud doc (sign in once on iPhone/Mac and
/// every device — this one included — picks them up).
struct TVSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(ProfileStore.self) private var profile
    @Environment(StreamingStore.self) private var streaming
    @Environment(StorageManager.self) private var storage
    @Environment(BurnStore.self) private var burns

    /// Burned-media footprint for the Storage section's readout (nil = not measured yet).
    /// Measured on appear + re-measured after every prune / cap change / readout tap —
    /// `burnedUsageBytes()` walks the burns folder, so it is never computed per-render.
    @State private var usageBytes: Int?
    @State private var usageSongs: Int?

    var body: some View {
        @Bindable var settings = settings
        return NavigationStack {
            Form {
                Section {
                    LabeledContent("PocketDJ name",
                                   value: profile.name.isEmpty ? "—" : profile.name)
                        .accessibilityIdentifier("tv-settings-name")
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Edit your profile on iPhone, iPad, or Mac — iCloud keeps every device in step.")
                }
                // Apple Music lives HERE because authorization is per-device and only ever
                // fires from an explicit tap (`MusicAuthorization.request()` is never called
                // automatically — see AppleMusicProvider's header): without this row the TV
                // simply never asks, and streaming + the MusicKit cover-art fallback stay dead
                // on the one device with no other way in. The consent sheet uses the TV's
                // signed-in Apple Account — no typing.
                Section {
                    appleMusicRow
                } header: {
                    Text("Apple Music")
                } footer: {
                    Text("Streaming and cover art use this Apple TV's Apple Account. Connect once per device.")
                }
                Section {
                    Toggle("Sync with iCloud", isOn: Binding(
                        get: { settings.cloudSyncEnabled },
                        set: { on in
                            settings.cloudSyncEnabled = on
                            settings.persist()
                            if on { Task { await cloudSync.syncNow() } }
                        }))
                        .accessibilityIdentifier("tv-settings-sync-toggle")
                    // Remote telemetry — the SAME owner-opt-in stream the phone's Debug panel
                    // offers, reachable on TV because the TV is exactly the device with no
                    // tethered debugging (the reason DiagLog exists). Toggle = the TVSettings
                    // Binding+persist pattern; push into the logger mirrors DebugView.
                    Toggle("Remote telemetry", isOn: Binding(
                        get: { settings.remoteTelemetryEnabled },
                        set: { on in
                            settings.remoteTelemetryEnabled = on
                            settings.persist()
                            DiagLog.shared.telemetryEnabled = on
                        }))
                        .accessibilityIdentifier("tv-settings-telemetry-toggle")
                    if settings.cloudSyncEnabled {
                        LabeledContent("Status", value: syncStatusLine)
                            .accessibilityIdentifier("tv-settings-sync-status")
                        Button {
                            Task { await cloudSync.syncNow() }
                        } label: {
                            Label(cloudSync.syncing ? "Syncing…" : "Sync now",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(cloudSync.syncing)
                        .accessibilityIdentifier("tv-settings-sync-now")
                    }
                } header: {
                    Text("iCloud sync")
                } footer: {
                    Text("Profile, collections, history, playback sessions, and connection settings sync through your private iCloud database.")
                }
                // EDITABLE connection fields (Levi, on-device 2026-09-02). Two reasons this
                // is TextFields and not LabeledContent: (1) you can actually set config on
                // the TV when sync hasn't delivered yet; (2) tvOS scrolls BY FOCUS, and
                // LabeledContent isn't focusable — the old read-only rows pinned the Form at
                // "Sync now" with everything below unreachable. Edits persist on commit and
                // ride the settings-credentials cloud doc back to every other device.
                Section {
                    TextField("Import server URL", text: $settings.ripServerURL)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-rip-url")
                    SecureField("Import server token", text: $settings.ripToken)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-rip-token")
                } header: {
                    Text("Import server")
                } footer: {
                    Text(serverStatus(settings.ripServerURL, token: settings.ripToken))
                }
                Section {
                    TextField("Jukebox server URL", text: $settings.jukeboxServerURL)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-jukebox-url")
                    SecureField("Jukebox token", text: $settings.jukeboxToken)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-jukebox-token")
                } header: {
                    Text("Jukebox")
                } footer: {
                    Text(serverStatus(settings.jukeboxServerURL, token: settings.jukeboxToken))
                }
                Section {
                    TextField("Search endpoint", text: $settings.searchEndpoint)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-search-endpoint")
                    TextField("Search access key", text: $settings.searchAccessKeyID)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-search-key")
                    SecureField("Search secret key", text: $settings.searchSecretKey)
                        .onSubmit { settings.persist() }
                        .accessibilityIdentifier("tv-settings-search-secret")
                } header: {
                    Text("Online search")
                } footer: {
                    Text("\(searchStatus) · Apple Music sync \(settings.appleMusicPrivateSync ? "on" : "off"). These sync across your devices through iCloud — set them anywhere once.")
                }
                // Auto-managed storage (task #48). The TV burns into Caches
                // (RipsStore.burnsDirectory), so it must keep itself bounded: the toggle is
                // the master switch (ON by default on tvOS — SettingsStore
                // .storageAutoManageDefault), the cap picker is a Menu (tvOS's picker
                // idiom, same as the Mix crate menus) offering size AND song-count caps —
                // picking one kind clears the other — and every row is a focusable control
                // (Toggle/Menu/Button): LabeledContent is a focus trap, the lesson this
                // Form already carries twice.
                Section {
                    Toggle("Auto-manage storage", isOn: Binding(
                        get: { settings.storageAutoManage },
                        set: { on in
                            settings.storageAutoManage = on
                            settings.persist()
                            // A freshly-opened gate deserves an immediate pass — don't
                            // leave the TV over-cap for up to a day.
                            if on { pruneAndRemeasure() }
                        }))
                        .accessibilityIdentifier("tv-settings-storage-automanage")
                    if settings.storageAutoManage {
                        Menu {
                            Section("By size") {
                                ForEach(Self.sizeCapChoicesGB, id: \.self) { gb in
                                    Button { setCap(gb: gb) } label: {
                                        if settings.storageSoftCapSongs == nil && settings.storageSoftCapGB == gb {
                                            Label(Self.sizeLabel(gb), systemImage: "checkmark")
                                        } else {
                                            Text(Self.sizeLabel(gb))
                                        }
                                    }
                                }
                            }
                            Section("By song count") {
                                ForEach(Self.songCapChoices, id: \.self) { n in
                                    Button { setCap(songs: n) } label: {
                                        if settings.storageSoftCapSongs == n {
                                            Label("\(n) songs", systemImage: "checkmark")
                                        } else {
                                            Text("\(n) songs")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("Storage cap")
                                Spacer()
                                Text(capLabel).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("tv-settings-storage-cap")
                        Button { pruneAndRemeasure() } label: {
                            Label("Prune now", systemImage: "scissors")
                        }
                        .accessibilityIdentifier("tv-settings-storage-prune-now")
                        // The usage readout is a BUTTON, not LabeledContent — tvOS scrolls
                        // by focus and a non-focusable row pins the Form. Tap = re-measure.
                        Button { refreshUsage() } label: {
                            HStack {
                                Label("Downloaded", systemImage: "internaldrive")
                                Spacer()
                                Text(usageLine).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("tv-settings-storage-usage")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(storageFooter)
                }
                Section("About") {
                    LabeledContent("Version", value: Self.versionLine)
                }
            }
            .navigationTitle("Settings")
            .task { refreshUsage() }
        }
    }

    // MARK: Storage section plumbing

    /// The cap picker's size choices (decimal GB; 0.5 renders as "500 MB") and song-count
    /// choices. `tvDefaultCapGB` (the no-choice default) is deliberately among the sizes.
    static let sizeCapChoicesGB: [Double] = [0.5, 1, 2, 5, 10]
    static let songCapChoices: [Int] = [100, 250, 500, 1000]
    static func sizeLabel(_ gb: Double) -> String {
        gb < 1 ? "\(Int((gb * 1000).rounded())) MB" : "\(Int(gb)) GB"
    }

    private var capLabel: String {
        if let n = settings.storageSoftCapSongs { return "\(n) songs" }
        if let gb = settings.storageSoftCapGB { return Self.sizeLabel(gb) }
        return "\(Self.sizeLabel(StorageManager.tvDefaultCapGB)) (default)"
    }

    private var usageLine: String {
        guard let bytes = usageBytes, let songs = usageSongs else { return "—" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(songs) song\(songs == 1 ? "" : "s") · \(size)"
    }

    private var storageFooter: String {
        var line = "Least-recently-played downloads are removed automatically to stay under the cap. Anything pruned re-downloads on its next play."
        if let r = storage.lastResult, r.evicted > 0 {
            line += " Last prune removed \(r.evicted) song\(r.evicted == 1 ? "" : "s")."
        }
        return line
    }

    /// Picking a size clears the songs cap (and vice versa) — the Menu offers ONE cap, in
    /// two currencies. Every cap change prunes immediately (spec: prune on cap change).
    private func setCap(gb: Double) {
        settings.storageSoftCapGB = gb
        settings.storageSoftCapSongs = nil
        settings.persist()
        pruneAndRemeasure()
    }

    private func setCap(songs: Int) {
        settings.storageSoftCapSongs = songs
        settings.storageSoftCapGB = nil
        settings.persist()
        pruneAndRemeasure()
    }

    /// Deferred past the current UI tick so the Menu/Toggle animation never waits on the
    /// disk walk (`burnedUsageBytes` measures the burns folder file-by-file).
    private func pruneAndRemeasure() {
        Task {
            storage.pruneNow()
            refreshUsage()
        }
    }

    private func refreshUsage() {
        usageBytes = burns.burnedUsageBytes()
        usageSongs = burns.readyBurnedIds.count
    }

    /// The Connect row, by provider state. Buttons throughout — tvOS scrolls BY FOCUS, and a
    /// non-focusable row is a trap (the LabeledContent lesson this Form already carries).
    @ViewBuilder private var appleMusicRow: some View {
        if let am = streaming.appleMusicProvider {
            switch am.state {
            case .connected(let account), .linked(let account):
                Button {
                    am.login()      // re-runs the consent/subscription probe — a harmless refresh
                } label: {
                    Label(account.map { "Connected — \($0)" } ?? "Connected",
                          systemImage: "checkmark.circle.fill")
                }
                .accessibilityIdentifier("tv-settings-am-connected")
            case .authorizing:
                Button {} label: { Label("Connecting…", systemImage: "hourglass") }
                    .disabled(true)
            case .failed(let message):
                Button { am.login() } label: {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("tv-settings-am-retry")
            case .unavailable(let reason):
                Button {} label: { Label(reason, systemImage: "xmark.circle") }
                    .disabled(true)
            case .loggedOut:
                Button { am.login() } label: {
                    Label("Connect Apple Music", systemImage: "music.note")
                }
                .accessibilityIdentifier("tv-settings-am-connect")
            }
        } else {
            Button {} label: {
                Label("Apple Music is not available in this build", systemImage: "xmark.circle")
            }
            .disabled(true)
        }
    }

    private var syncStatusLine: String {
        if cloudSync.accountAvailable == false { return "iCloud unavailable" }
        if let err = cloudSync.lastError { return err }
        guard let at = cloudSync.lastSyncAt else { return "Not synced yet" }
        let time = at.formatted(date: .omitted, time: .shortened)
        if let summary = cloudSync.lastSummary { return "\(summary) · \(time)" }
        return time
    }

    /// "host · token set" / "Not set" — presence, never the secret itself.
    private func serverStatus(_ rawURL: String, token: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Not set" }
        let host = URL(string: trimmed)?.host ?? trimmed
        return token.isEmpty ? host : "\(host) · token set"
    }

    private var searchStatus: String {
        let hasKeys = !settings.searchAccessKeyID.isEmpty && !settings.searchSecretKey.isEmpty
        guard hasKeys else { return "Off (no credentials)" }
        let ep = settings.searchEndpoint.trimmingCharacters(in: .whitespaces)
        return ep.isEmpty ? "Credentials set" : (URL(string: ep)?.host ?? ep)
    }

    private static var versionLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }
}


#endif
