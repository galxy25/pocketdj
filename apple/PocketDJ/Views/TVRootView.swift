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
/// The tab set IS the TV feature set:
///   • **Mix** — the DEFAULT tab: Auto DJ, pared down to "pick a collection, Play/Shuffle",
///     plus an omni search bar that browses every local collection AND Discover to feed the
///     running auto queue. No manual decks, no per-deck effects — the phone/Mac keep those.
///   • **Browse** — the collections (playlists / pockets / set lists), pushed into the SAME
///     detail views every platform uses (`pocketDJDestinations`), with Play/Shuffle a
///     long-press away on every row.
///   • **For You** — the same tile grid History carries elsewhere; read-only + play.
///   • **Jukebox** — the HOST surface: the session QR on the big screen is the whole point
///     of a TV jukebox (the room scans the television).
///   • **Settings** — minimal: profile, the iCloud sync toggle, and a READ-ONLY status of
///     the synced connection credentials (the TV never grows a credential-typing flow —
///     they arrive via the settings-credentials cloud doc).
///
/// There is deliberately NO Producer tab (owner: "NO Producer surface at all") and no
/// History/Games — the TV is for playing music, not editing it.
struct TVRootView: View {
    enum TVTab: String, CaseIterable, Identifiable {
        case mix = "Mix"
        case browse = "Browse"
        case forYou = "For You"
        case jukebox = "Jukebox"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .mix:      return "wand.and.stars"
            case .browse:   return "music.note.list"
            case .forYou:   return "sparkles"
            case .jukebox:  return "qrcode"
            case .settings: return "gearshape"
            }
        }
    }

    /// Mix is the launch tab BY SPEC (the TV defaults to Auto DJ).
    @State private var tab: TVTab = .mix
    /// Multi-select plumbing some shared rows read from the environment (CollectionSongRow
    /// etc.). The TV never drag-selects, but the environment object must exist for the
    /// shared detail views to render — one per shell, exactly like RootView's per-window one.
    @State private var rowSelection = RowSelection()

    var body: some View {
        TabView(selection: $tab) {
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
// MARK: - Mix (Auto DJ) — the default tab
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
    /// The chosen auto collection (pockets + set lists — the same source kinds MixView's
    /// auto picker offers; both resolve to BURNED loadables via MixResolver).
    @State private var source: MixSource?
    @State private var startError: String?

    // ── Omni search state ────────────────────────────────────────────────────
    @State private var query = ""
    @State private var localHits: [TVLocalHit] = []
    @State private var discoverHits: [RipsStore.DiscoverHit] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    /// songId → first collection it was found in — built LAZILY on the first search and
    /// cached for the view's lifetime (resolving every collection per keystroke would
    /// re-walk pocket DAGs each time).
    @State private var localIndex: [TVLocalHit]?
    /// Accepted-but-not-yet-burned adds headed for the auto queue (the Jukebox's
    /// pending-insert pattern, scoped to this surface): rip+burn kicked, insert lands
    /// when the file exists, let go after 15 minutes or when the mix ends.
    @State private var pending: [TVPendingAdd] = []
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 28) {
                    if engine.autoMixing {
                        liveCard
                        upNext
                    } else {
                        setupCard
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                searchColumn
                    .frame(width: 700)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Mix")
            .pocketDJDestinations(path: $path)
        }
        // Drain loop for rip-in-flight adds: ticks while anything is pending, stops itself
        // when the list empties (the Bool id restarts it when the first add parks).
        .task(id: pending.isEmpty) {
            guard !pending.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                drainPending()
                if pending.isEmpty { break }
            }
        }
    }

    // MARK: Auto DJ — setup (no mix running)

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Auto DJ", systemImage: "wand.and.stars")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.fg)
            Text("Pick a collection and press Play — PocketDJ beat-mixes it for the room.")
                .font(.callout)
                .foregroundStyle(Theme.fgDim)
            Menu {
                sourceMenuItems
            } label: {
                Label(sourceName ?? "Pick a collection", systemImage: "rectangle.stack")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("tv-mix-source")
            HStack(spacing: 20) {
                Button { start(shuffled: false) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(source == nil)
                .accessibilityIdentifier("tv-mix-play")
                Button { start(shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .disabled(source == nil)
                .accessibilityIdentifier("tv-mix-shuffle")
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

    @ViewBuilder private var sourceMenuItems: some View {
        // Same source kinds as MixView's auto picker: pockets + set lists (the two that
        // resolve through MixResolver into burned loadables).
        if collections.pockets.isEmpty && collections.visibleSetlists.isEmpty {
            Text("No pockets or set lists yet — build one on iPhone, iPad, or Mac.")
        }
        if !collections.pockets.isEmpty {
            Section("Pockets") {
                ForEach(collections.pockets) { p in
                    Button(p.name) { source = .pocket(p.id) }
                }
            }
        }
        if !collections.visibleSetlists.isEmpty {
            Section("Set lists") {
                ForEach(collections.visibleSetlists) { s in
                    Button(s.name ?? "Set list") { source = .setlist(s.id) }
                }
            }
        }
    }

    private var sourceName: String? {
        switch source {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }

    private func start(shuffled: Bool) {
        guard let src = source else { return }
        startError = nil
        Task {
            do {
                _ = try await intents.startAutoMix(source: src, shuffle: shuffled)
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
                Button { engine.skipToNext(fadeSeconds: settings.skipFadeSeconds) } label: {
                    Label("Skip", systemImage: "forward.fill")
                }
                .accessibilityIdentifier("tv-mix-skip")
                Button(role: .destructive) { engine.stopAutoMix() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("tv-mix-stop")
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

    // MARK: Omni search (local collections + Discover)

    private var searchColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Search your collections + Apple Music", text: $query)
                .accessibilityIdentifier("tv-mix-search")
                .onChange(of: query) { _, q in scheduleSearch(q) }
                .onSubmit { scheduleSearch(query, immediate: true) }
            if let toast {
                Label(toast, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("tv-mix-toast")
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(engine.autoMixing
                     ? "Find a track anywhere — your collections or the Apple Music catalog — and add it to the queue."
                     : "Find a track anywhere and play it. Start an Auto DJ mix to build a queue.")
                    .font(.callout)
                    .foregroundStyle(Theme.fgDim)
            } else {
                resultsList
            }
        }
        .padding(28)
        .background(Theme.bgRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var resultsList: some View {
        List {
            if !localHits.isEmpty {
                Section("Your collections") {
                    ForEach(localHits) { hit in
                        resultRow(title: hit.song.name, subtitle: "\(hit.song.artist) · \(hit.collection)") {
                            addLocal(hit.song, placement: .end)
                        } menu: {
                            placementMenu { addLocal(hit.song, placement: $0) }
                        }
                        .accessibilityIdentifier("tv-search-local-\(hit.song.id)")
                    }
                }
            }
            if !discoverHits.isEmpty {
                Section("Discover — Apple Music") {
                    ForEach(discoverHits) { hit in
                        resultRow(title: hit.title,
                                  subtitle: hit.album.map { "\(hit.artist) · \($0)" } ?? hit.artist) {
                            addDiscover(hit, placement: .end)
                        } menu: {
                            placementMenu { addDiscover(hit, placement: $0) }
                        }
                        .accessibilityIdentifier("tv-search-discover-\(hit.songId)")
                    }
                }
            }
            if searching {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if localHits.isEmpty && discoverHits.isEmpty {
                Text(rips.discoverError ?? "No matches.")
                    .font(.callout)
                    .foregroundStyle(Theme.fgDim)
            }
        }
        .listStyle(.plain)
        .scrollClipDisabled()
    }

    /// One focusable result row: press = the primary action (queue while mixing, play
    /// otherwise); long-press = the placement menu while a mix runs.
    private func resultRow(title: String, subtitle: String,
                           action: @escaping () -> Void,
                           @ViewBuilder menu: @escaping () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    // No absolute colors on a FOCUSABLE label: the focused tvOS platter is
                    // white, so the style's own primary/secondary must drive the contrast.
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: engine.autoMixing ? "text.badge.plus" : "play.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .contextMenu { menu() }
    }

    /// Play Next / Play Last / Surprise Slot — the Jukebox's placement verbs, reused for
    /// the DJ's own adds so guests and host share one mental model. Only offered while a
    /// mix is running (placement is meaningless otherwise).
    @ViewBuilder private func placementMenu(_ add: @escaping (JukeboxDecisionAction) -> Void) -> some View {
        if engine.autoMixing {
            Button { add(.next) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { add(.end) } label: { Label("Play last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button { add(.random) } label: { Label("Surprise slot", systemImage: "dice") }
        }
    }

    private func scheduleSearch(_ raw: String, immediate: Bool = false) {
        searchTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            localHits = []; discoverHits = []; searching = false
            return
        }
        searchTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            runLocalSearch(q)
            searching = true
            let hits = await rips.discoverSearch(q, limit: 12)
            guard !Task.isCancelled else { return }
            discoverHits = RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: settings.preferExplicitVersions)
            searching = false
        }
    }

    /// Search EVERY local collection (playlists + pockets + set lists), first-seen wins —
    /// the "omni" half. Matches on title + artist, all query tokens required.
    private func runLocalSearch(_ q: String) {
        if localIndex == nil { localIndex = buildLocalIndex() }
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        localHits = Array((localIndex ?? []).filter { hit in
            let hay = "\(hit.song.name) \(hit.song.artist)".lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }.prefix(20))
    }

    private func buildLocalIndex() -> [TVLocalHit] {
        var seen = Set<String>()
        var out: [TVLocalHit] = []
        func add(_ ids: [String], from name: String) {
            for id in ids where !seen.contains(id) {
                guard let song = app.songsById[id] else { continue }
                seen.insert(id)
                out.append(TVLocalHit(song: song, collection: name))
            }
        }
        for p in collections.playlists { add(collections.playableIds(forPlaylist: p.id), from: p.name) }
        for p in collections.pockets { add(collections.playableIds(forPocket: p.id), from: p.name) }
        for s in collections.visibleSetlists { add(collections.playableIds(forSetlist: s.id), from: s.name ?? "Set list") }
        return out
    }

    // MARK: Adding / playing from search

    private func addLocal(_ song: IndexSong, placement: JukeboxDecisionAction) {
        let loadable = MixLoadable(songId: song.id, title: song.name, artist: song.artist,
                                   bpm: song.bpm, camelot: song.camelot, key: song.key,
                                   albumId: song.albumId, lengthMs: song.length)
        if engine.autoMixing {
            queue(loadable, appleMusicId: song.appleMusicId, placement: placement)
        } else {
            // No mix on air: the tap just plays it (the app-scoped Now Playing set).
            Task { _ = try? await intents.playSong(id: song.id) }
            toastShow("Playing “\(song.name)”")
        }
    }

    private func addDiscover(_ hit: RipsStore.DiscoverHit, placement: JukeboxDecisionAction) {
        if engine.autoMixing {
            let loadable = MixLoadable(songId: hit.songId, title: hit.title, artist: hit.artist,
                                       bpm: nil, camelot: nil, key: nil, albumId: nil,
                                       lengthMs: hit.durationMs)
            queue(loadable, appleMusicId: hit.appleMusicId, placement: placement)
        } else if app.songsById[hit.songId] != nil {
            Task { _ = try? await intents.playSong(id: hit.songId) }
            toastShow("Playing “\(hit.title)”")
        } else if !hit.appleMusicId.isEmpty {
            // Apple-Music-only hit with nothing on air: stream it through the sequencer via
            // the namespaced id — the same door a Jukebox accept uses when no mix runs.
            let item = SetlistPlayer.Item(id: AppleMusicCatalog.namespacedSongID(hit.appleMusicId),
                                          title: hit.title, artist: hit.artist,
                                          lengthMs: hit.durationMs)
            if sequencer.isRunning {
                sequencer.appendToQueue([item])
                toastShow("Added to Now Playing")
            } else {
                sequencer.play([item])
                toastShow("Playing “\(hit.title)”")
            }
        }
    }

    /// Insert into the RUNNING auto queue — immediately when the burned file exists;
    /// otherwise kick rip+burn and park the insert (the Jukebox broadcast-accept pattern).
    private func queue(_ loadable: MixLoadable, appleMusicId: String?, placement: JukeboxDecisionAction) {
        let durationMs = loadable.lengthMs ?? 180_000
        if burns.localURL(forSong: loadable.songId) != nil {
            engine.autoQueueInsert(.init(loadable: loadable, durationMs: durationMs), placement: placement)
            toastShow("Queued “\(loadable.title)”")
        } else {
            burns.startRipAndBurn(songId: loadable.songId, title: loadable.title,
                                  artist: loadable.artist, appleMusicId: appleMusicId,
                                  lengthMs: loadable.lengthMs)
            pending.append(TVPendingAdd(loadable: loadable, durationMs: durationMs,
                                        placement: placement,
                                        deadline: Date().timeIntervalSince1970 + 15 * 60))
            toastShow("Preparing “\(loadable.title)” — it joins the queue when ready")
        }
    }

    /// Land parked adds whose burn finished. If the mix ended while the rip ran, the add
    /// is let go — a dead mix doesn't need a queue.
    private func drainPending() {
        let now = Date().timeIntervalSince1970
        var still: [TVPendingAdd] = []
        for p in pending {
            if now > p.deadline { continue }
            guard burns.localURL(forSong: p.loadable.songId) != nil else {
                still.append(p)
                continue
            }
            if engine.autoMixing {
                engine.autoQueueInsert(.init(loadable: p.loadable, durationMs: p.durationMs),
                                       placement: p.placement)
                toastShow("Queued “\(p.loadable.title)”")
            }
        }
        pending = still
    }

    private func toastShow(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

/// One omni-search hit from the local collections: the catalog song + the first
/// collection it was found in (display context).
private struct TVLocalHit: Identifiable {
    let song: IndexSong
    let collection: String
    var id: String { song.id }
}

/// An accepted search add whose burned file doesn't exist yet (rip+burn in flight).
private struct TVPendingAdd: Identifiable {
    let loadable: MixLoadable
    let durationMs: Int
    let placement: JukeboxDecisionAction
    let deadline: TimeInterval
    var id: String { loadable.songId }
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
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if collections.playlists.isEmpty && collections.pockets.isEmpty
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
        .safeAreaInset(edge: .bottom) { TVNowPlayingStrip() }
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
        .safeAreaInset(edge: .bottom) { TVNowPlayingStrip() }
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
        NavigationStack {
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
                Section {
                    LabeledContent("Import / rip server", value: serverStatus(settings.ripServerURL, token: settings.ripToken))
                    LabeledContent("Jukebox server", value: serverStatus(settings.jukeboxServerURL, token: settings.jukeboxToken))
                    LabeledContent("Online search", value: searchStatus)
                    LabeledContent("Apple Music sync", value: settings.appleMusicPrivateSync ? "On" : "Off")
                } header: {
                    Text("Connections")
                } footer: {
                    Text("Read-only here — these sync from the devices where you set them up.")
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

// ============================================================================
// MARK: - Now Playing strip (Browse / For You)
// ============================================================================

/// A slim lean-back transport for the app-scoped sequencer — visible whenever collection
/// playback owns the audio (it yields to a running/suspended Mix exactly like the docked
/// panel does, via the same `NowPlayingPanel.isVisible` rule). Transport routes through
/// the panel's statics so backend ownership (Apple Music vs PlayerEngine) is identical.
struct TVNowPlayingStrip: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(MixEngine.self) private var mix
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        if NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentItem?.title ?? "—")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                        .accessibilityIdentifier("tv-np-title")
                    Text(currentItem?.artist ?? "")
                        .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button { sequencer.skipPrevious() } label: { Image(systemName: "backward.fill") }
                    .accessibilityIdentifier("tv-np-previous")
                Button {
                    NowPlayingPanel.togglePlayPause(sequencer: sequencer, coordinator: coordinator, player: player)
                } label: {
                    Image(systemName: NowPlayingPanel.isPlayingNow(coordinator: coordinator, player: player)
                          ? "pause.fill" : "play.fill")
                }
                .accessibilityIdentifier("tv-np-playpause")
                Button { sequencer.skipNext() } label: { Image(systemName: "forward.fill") }
                    .accessibilityIdentifier("tv-np-next")
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(.thinMaterial)
        }
    }

    private var currentItem: SetlistPlayer.Item? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        return sequencer.queue[sequencer.index]
    }
}

#endif
