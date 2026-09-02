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
            if NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix) || mix.autoMixing {
                ScrollView {
                    NowPlayingPanel()
                        .frame(maxWidth: 1120)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)   // center the panel column
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing playing", systemImage: "play.circle")
                } description: {
                    Text("Start a collection from Browse, an Auto DJ mix from Mix, or a For You pick — playback lands here.")
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
            VStack(alignment: .leading, spacing: 28) {
                if engine.autoMixing {
                    liveCard
                    upNext
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
            glideToggles
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
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// FX Glide + Audio Glide — ENGINE state (persists with the durable mix session), not
    /// settings; safe to flip mid-mix (applies from the next transition). Toggle is focusable
    /// on tvOS (the TVSettingsView pattern); explicit Binding because the engine is the store.
    private var glideToggles: some View {
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
                _ = try await intents.startAutoMix(deckA: a, deckB: deckB ?? a, shuffle: shuffled)
            } catch {
                // The intent error strings are already user-facing ("no burned songs…").
                startError = String(localized: (error as? PocketDJIntentError)?.localizedStringResource
                    ?? "That collection can’t start a mix right now.")
            }
        }
    }

    // MARK: Auto DJ — live (mix running)

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
                    // for hand-mixing — meaningless on a TV).
                    Button { engine.remotePlay() } label: { Label("Resume", systemImage: "play.fill") }
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
                Button(role: .destructive) { engine.stopAutoMix() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("tv-mix-stop")
            }
            glideToggles
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The queue's not-yet-reached tail — displayed, not focusable (the queue is fed from
    /// the search column; showing ~8 rows + a "+N more" line avoids trapping TV focus in a
    /// list with no actions).
    @ViewBuilder private var upNext: some View {
        let upcoming = engine.autoUpcoming
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Up next")
                    .font(.headline)
                    .foregroundStyle(Theme.fgDim)
                ForEach(Array(upcoming.prefix(8).enumerated()), id: \.element.songId) { i, l in
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.fgDim)
                            .frame(width: 36, alignment: .trailing)
                        Text(l.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                        Text("· \(l.artist)").font(.callout).foregroundStyle(Theme.fgDim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if upcoming.count > 8 {
                    Text("+ \(upcoming.count - 8) more")
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

/// The TV is the ideal Jukebox HOST: the session QR lives on the big screen where the whole
/// room can scan it, with the live queue + request inbox beside it. The shared JukeboxView
/// already renders exactly that (QR section, mode, now playing, requests), so the TV wraps
/// it unchanged — same store, same server, same decisions.
struct TVJukeboxView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            JukeboxView()
                .pocketDJDestinations(path: $path)
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
                Section("About") {
                    LabeledContent("Version", value: Self.versionLine)
                }
            }
            .navigationTitle("Settings")
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
