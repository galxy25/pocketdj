import SwiftUI
import Observation

/// Debounced driver for Browse ▸ Discover. Kept out of BrowseView (and BrowseState)
/// so the on-device filter/sort pipeline stays untouched — this owns only the query
/// debounce + the current hit list. The network call itself lives on RipsStore
/// (`discoverSearch`), which owns the rip-server config + error surface.
@MainActor
@Observable
final class DiscoverSearchModel {
    enum State: Equatable { case idle, loading, loaded }

    var state: State = .idle
    private(set) var hits: [RipsStore.DiscoverHit] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    /// ~400 ms debounce so a burst of keystrokes coalesces into one search round-trip
    /// (the on-device recompute's `.task(id:)` debounce doesn't run in discover mode).
    /// Re-triggering cancels the pending run; an all-empty query clears to idle.
    /// `artist` is the Discover tab's refine field: it WIDENS the search term (term
    /// search matches across fields) and NARROWS the hit list client-side.
    ///
    /// TWO catalogs run in parallel and merge:
    ///   • `catalog` (MusicKit, when authorized) — FULL Apple Music coverage + real
    ///     relevance ranking. The legacy iTunes Search API behind the proxy misses
    ///     whole tracks (e.g. "Witchy (feat. Childish Gambino)" never surfaces for any
    ///     term while its Instrumental does), so MusicKit leads when available.
    ///   • the rip-server `/search` proxy — reachable by every tester (no Apple Music
    ///     subscription needed) and the authority on ripped/streamable state.
    func searchDebounced(_ query: String, artist: String = "", rips: RipsStore,
                         catalog: (any StreamingSearch)? = nil) {
        task?.cancel()
        guard let term = Self.term(title: query, artist: artist) else {
            hits = []; state = .idle; return
        }
        let refine = artist.trimmingCharacters(in: .whitespaces)
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.state = .loading
            async let proxyHits = rips.discoverSearch(term)
            var catalogHits: [RipsStore.DiscoverHit] = []
            if let catalog, catalog.canSearch {
                let tracks = (try? await catalog.search(term, limit: 25)) ?? []
                catalogHits = tracks.map { t in
                    Self.hit(from: t, ripURL: rips.cachedURL("amrec_\(t.providerTrackID)"))
                }
            }
            let merged = Self.merge(catalog: catalogHits, server: await proxyHits)
            guard !Task.isCancelled else { return }
            self.hits = Self.refine(merged, artist: refine)
            self.state = .loaded
        }
    }

    /// Map a MusicKit catalog hit into the Discover row shape (the `amrec_` ad-hoc-rip
    /// id convention); `ripURL` is the LOCAL manifest's answer for that id (the add
    /// flow may already have prepared this song's copy).
    static func hit(from track: StreamingTrack, ripURL: URL?) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: track.providerTrackID,
                              title: track.title,
                              artist: track.artist ?? "",
                              artworkUrl: track.artworkURL?.absoluteString,
                              durationMs: track.durationSeconds.map { $0 * 1000 },
                              songId: "amrec_\(track.providerTrackID)",
                              ripped: ripURL != nil,
                              url: ripURL?.absoluteString)
    }

    /// Merge doctrine: MusicKit's ranking leads; where the proxy knows the same track
    /// its ROW wins (the server manifest is the authority on ripped/url); proxy-only
    /// hits follow. Dedup by Apple Music store id.
    static func merge(catalog: [RipsStore.DiscoverHit],
                      server: [RipsStore.DiscoverHit]) -> [RipsStore.DiscoverHit] {
        let serverById = Dictionary(server.map { ($0.appleMusicId, $0) },
                                    uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [RipsStore.DiscoverHit] = []
        for h in catalog where seen.insert(h.appleMusicId).inserted {
            out.append(serverById[h.appleMusicId] ?? h)
        }
        for h in server where seen.insert(h.appleMusicId).inserted {
            out.append(h)
        }
        return out
    }

    /// The server search term: title + artist joined (either alone works — an
    /// artist-only search is a valid way in). nil ⇒ nothing to search.
    static func term(title: String, artist: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = artist.trimmingCharacters(in: .whitespaces)
        let joined = [t, a].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Client-side artist narrowing — iTunes term search matches across fields, so a
    /// refine like "daft" must still drop hits whose artist doesn't carry it.
    static func refine(_ hits: [RipsStore.DiscoverHit], artist: String) -> [RipsStore.DiscoverHit] {
        let a = artist.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return hits }
        return hits.filter { $0.artist.localizedCaseInsensitiveContains(a) }
    }

    func cancel() { task?.cancel(); task = nil; hits = []; state = .idle }
}

/// Browse ▸ Discover — search the Apple Music catalog through the rip server's `/search`
/// proxy. "＋ Add" saves the song to the user's own Apple Music library and asks the rip
/// server to prepare the user's own copy (the ad-hoc `amrec_` path); if the server can
/// honour that, the row flips to a ▶ wired to the standard rip-play path.
///
/// This view is AGNOSTIC to how the server fulfils the request — see `discoverAdd`. The
/// server's contract is that it prepares ONLY media the user already owns in their cloud
/// library, and serves each user their own copy; a request it cannot honour is simply a
/// miss and the row stays as it was. Apple Music is playback only — nothing on this
/// screen captures, records or downloads audio from it.
///
/// #TOUPDATE: that contract is the TARGET. Today the server does not restrict itself to
/// the requester's owned cloud media (it captures from Apple Music), does not authenticate
/// the requester (auth fails open), and does not serve per-user copies (one flat,
/// public-read rips/<songId>.mp3 namespace shared across users). Remove this marker only
/// once all three are true.
struct DiscoverResultsList: View {
    @Environment(RipsStore.self) private var rips
    let model: DiscoverSearchModel
    let query: String
    var artist: String = ""

    var body: some View {
        Group {
            if DiscoverSearchModel.term(title: query, artist: artist) == nil {
                hint
            } else {
                switch model.state {
                case .idle, .loading: loading
                case .loaded:
                    if let message = rips.discoverError {
                        failure(message)
                    } else if model.hits.isEmpty {
                        noMatches
                    } else {
                        list
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var hint: some View {
        ContentUnavailableView {
            Label("Discover Apple Music", systemImage: "sparkle.magnifyingglass")
        } description: {
            // #TOUPDATE: both halves of this sentence are the TARGET, not today's code.
            // (1) The prepare step (discoverAdd → discoverAddRip) must operate ONLY on media
            //     the user owns in their cloud library, and return a miss for anything else —
            //     today the server captures the track from Apple Music unconditionally.
            // (2) "your own copy" needs per-user storage + an authenticated requester; today
            //     every rip lands in one flat, public-read rips/<songId>.mp3 shared by all
            //     users, and the server's auth fails open.
            // (3) The library save is conditional on `canAddToLibrary` (false on macOS) and
            //     swallowed by `try?`, so it is not yet the guarantee this claims.
            Text("Search Apple Music — ＋ Add saves the song to your Apple Music library, then prepares your own copy. Only music you already own in your cloud library can be prepared.")
        }
        .accessibilityIdentifier("discover-hint")
    }

    private var loading: some View {
        VStack(spacing: 12) { ProgressView(); Text("Searching Apple Music…").foregroundStyle(Theme.fgDim) }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing in the Apple Music catalog matched “\(query)”.")
        }
        .accessibilityIdentifier("discover-empty")
    }

    /// Server unreachable / bad token — `discoverError` strings already name the
    /// Settings ▸ Rip server field to fix.
    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Discover unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("discover-error")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Index-keyed a11y ids (`discover-row-<i>`), identity by songId.
                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                    DiscoverRow(hit: hit, index: index)
                    // Same inline player the browser song rows get — a playing
                    // discover hit shows the standard transport under its row.
                    InlinePlayerSlot(songId: hit.songId).padding(.horizontal, 2)
                    Divider().overlay(Theme.border)
                }
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("discover-list")
    }
}

/// One Discover result row: artwork · title / artist · album · duration · trailing
/// action. The trailing action is state-driven per songId: ripped → ▶ (standard play
/// path) · rip job in flight → spinner + phase · else → ＋ Add.
private struct DiscoverRow: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    @Environment(StreamingStore.self) private var streaming
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(AppModel.self) private var app
    let hit: RipsStore.DiscoverHit
    let index: Int

    /// Ripped = the server said so at search time OR the manifest has flipped since
    /// (the add-completion `refreshManifest` is what moves a row here live).
    private var ripped: Bool { hit.ripped == true || rips.manifest[hit.songId] != nil }
    private var phase: RipsStore.Phase? { rips.jobs[hit.songId]?.phase }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if let ms = hit.durationMs, ms > 0 {
                Text(Self.mmss(ms)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            trailing
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        // `.contain` keeps the row a container so the nested play/add buttons keep
        // their own ids under the row id (the browser SongRow lesson).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-row-\(index)")
        // Long-press (iOS) / right-click (macOS) on a RIPPED row: queue it into the
        // running Now Playing session, and backfill the provisional catalog entry for
        // songs added before the eventual-consistency store existed (Levi 2026-07-18).
        .contextMenu { if ripped { rowMenu } }
    }

    @ViewBuilder private var rowMenu: some View {
        if sequencer.isRunning {
            Button { enqueue(next: true) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { enqueue(next: false) } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        if app.songsById[hit.songId] == nil {
            Button { addToCatalog() } label: {
                Label("Add to Catalog", systemImage: "plus.rectangle.on.folder")
            }
        }
    }

    /// Queue into the live session — the catalog entry lands first so the queue row
    /// (and everything downstream: collections, burn, mix) resolves the id.
    private func enqueue(next: Bool) {
        addToCatalog()
        let item = SetlistPlayer.Item(id: hit.songId, title: hit.title, artist: hit.artist,
                                      lengthMs: hit.durationMs)
        if next { sequencer.insertNextInQueue([item]) } else { sequencer.appendToQueue([item]) }
    }

    /// Backfill the provisional catalog entry (a no-op once the song is in any source —
    /// including adds recorded by discoverAdd itself).
    private func addToCatalog() {
        guard app.songsById[hit.songId] == nil else { return }
        rips.discoverAdds?.add(songId: hit.songId, appleMusicId: hit.appleMusicId,
                               title: hit.title, artist: hit.artist, album: hit.album,
                               artworkUrl: hit.artworkUrl, durationMs: hit.durationMs)
    }

    private var subtitle: String {
        [hit.artist, hit.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var artwork: some View {
        AsyncImage(url: hit.artworkUrl.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(Theme.border)
                .overlay(Image(systemName: "music.note").foregroundStyle(Theme.fgDim))
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Non-terminal rip phases → the working spinner (mirrors RipsStore.inFlightPhases).
    private static let working: Set<RipsStore.Phase> = [.queued, .searching, .ripping, .streaming, .uploading]

    @ViewBuilder private var trailing: some View {
        if ripped {
            Button { play() } label: {
                Image(systemName: rips.nowPlaying?.songId == hit.songId
                      ? "waveform.circle.fill" : "play.circle.fill")
                    .font(.title3).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("discover-play-\(index)")
            .help("Ready to play")
        } else if let phase, Self.working.contains(phase) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.phaseLabel(phase)).font(.caption).foregroundStyle(Theme.fgDim)
            }
            .accessibilityIdentifier("discover-progress-\(index)")
        } else {
            Button {
                // Pass a library contributor when this device can write the user's Apple
                // Music library, so the ＋ also saves the song there — a complete action in
                // its own right, independent of what the server does. See `discoverAdd`.
                let h = hit
                let lib = streaming.providers.libraryContributors.first
                Task { await rips.discoverAdd(h, library: lib) }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("discover-add-\(index)")
            // #TOUPDATE: honest once (a) discoverAdd asks the server to prepare only the
            // user's own cloud-library media instead of capturing from Apple Music, and
            // (b) the ＋ is gated on `canAddToLibrary` — false on macOS, where no library
            // write happens at all, so today this help overstates the library half there.
            .help("Save to your Apple Music library and prepare your copy")
        }
    }

    /// Standard single-song play: RipsStore resolves the manifest mp3 (a ripped
    /// discover hit is always cached, so this never falls into a live rip) and the
    /// caller owns the one-and-only `player.load` — the InlinePlayerSlot contract.
    private func play() {
        if rips.nowPlaying?.songId == hit.songId { player.toggle(); return }
        let song = (id: hit.songId, title: hit.title, artist: hit.artist)
        Task {
            if let now = try? await rips.play(song) {
                player.load(url: now.url, live: now.live, startMs: now.startMs,
                            title: now.title, artist: now.artist, songId: now.songId)
            }
        }
    }

    private static func phaseLabel(_ p: RipsStore.Phase) -> String {
        switch p {
        case .queued:              return "Queued"
        case .searching:           return "Searching…"
        case .ripping, .streaming: return "Ripping…"
        case .uploading:           return "Uploading…"
        case .ready, .error:       return ""
        }
    }

    private static func mmss(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
