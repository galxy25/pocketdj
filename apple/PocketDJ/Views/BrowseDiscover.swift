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
    /// The album NAME rides along whenever MusicKit knows it; the album ID usually does NOT
    /// (a catalog search result carries no album relationship). Resolving one per row would
    /// mean a `song.with([.albums])` fetch per hit — 25 extra round trips per keystroke — so
    /// the id is resolved LAZILY on the detail screen instead (AlbumPreview tier 1).
    static func hit(from track: StreamingTrack, ripURL: URL?) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: track.providerTrackID,
                              title: track.title,
                              artist: track.artist ?? "",
                              album: track.albumTitle,
                              artworkUrl: track.artworkURL?.absoluteString,
                              durationMs: track.durationSeconds.map { $0 * 1000 },
                              songId: "amrec_\(track.providerTrackID)",
                              ripped: ripURL != nil,
                              url: ripURL?.absoluteString,
                              albumAppleMusicId: track.albumStoreID)
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
    @Environment(SettingsStore.self) private var settings
    let model: DiscoverSearchModel
    let query: String
    var artist: String = ""
    /// The Browser's stack, so a row's ALBUM name can open the album preview. Optional so a
    /// preview/host without a stack still compiles (the name renders as plain text there).
    var path: Binding<NavigationPath>? = nil

    /// Edition-preference re-rank at DISPLAY time (pure + stable, so the model's merge
    /// ranking survives): clean editions lead by default; explicit leads when the user
    /// prefers explicit versions. NEW-song discovery defaults clean even while the
    /// tri-state preference is unset (the ruling: only stream substitution waits).
    private var rankedHits: [RipsStore.DiscoverHit] {
        RipsStore.DiscoverExplicitRanking.rank(model.hits,
                                               preferExplicit: settings.preferExplicitVersions)
    }

    var body: some View {
        Group {
            if DiscoverSearchModel.term(title: query, artist: artist) == nil {
                hint
            } else {
                switch model.state {
                case .idle, .loading: loading
                case .loaded:
                    // MusicKit hits render even when the rip-server half errored (public-user
                    // audit fix: "No import server configured" was MASKING working results —
                    // Discover search + AM-library add are serverless; only rip capture isn't).
                    if !model.hits.isEmpty {
                        list
                    } else if let message = rips.discoverError {
                        failure(message)
                    } else {
                        noMatches
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
                ForEach(Array(rankedHits.enumerated()), id: \.element.id) { index, hit in
                    DiscoverRow(hit: hit, index: index, path: path)
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

/// Capability-aware help text for a Discover "＋ Add" (song or album). The ＋ always prepares
/// your own copy (the per-track rip). Where the device can write the Apple Music library
/// (`canAddToLibrary` — iOS/iPadOS with an authorized subscription) it ALSO saves the item
/// there. On macOS `canAddToLibrary` is false: no library write happens — an album, which
/// carries a catalog URL, is opened in Music.app instead (`opensInMusic`); a song hit carries
/// no deep link, so the ＋ just prepares the copy. Pure + platform-agnostic → unit-testable,
/// and shared by `DiscoverRow` and `DiscoverAlbumRow` so their wording can't drift or overstate
/// the macOS library write (F7).
enum DiscoverAddWording {
    static func addHelp(noun: String, canAddToLibrary: Bool, opensInMusic: Bool) -> String {
        if canAddToLibrary {
            return "Save this \(noun) to your Apple Music library and prepare your copy"
        } else if opensInMusic {
            return "Open this \(noun) in Music and prepare your copy"
        } else {
            return "Prepare your copy"
        }
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
    /// The Browser's stack — the ALBUM name in this row's subtitle opens the album preview
    /// when we know the album's identity. Levi's report can be read as "the album shown on
    /// the Discover row should be tappable", so it is: same destination the added song's
    /// detail reaches, one step earlier.
    var path: Binding<NavigationPath>? = nil

    /// Ripped = the server said so at search time OR the manifest has flipped since
    /// (the add-completion `refreshManifest` is what moves a row here live).
    private var ripped: Bool { hit.ripped == true || rips.manifest[hit.songId] != nil }
    private var phase: RipsStore.Phase? { rips.jobs[hit.songId]?.phase }
    /// Recorded as a (serverless-streamable) catalog entry — drives the "Added" state.
    private var added: Bool { rips.discoverAdds?.entries.contains { $0.songId == hit.songId } ?? false }

    /// Whether this device can write the user's Apple Music library — false on macOS (and on
    /// any device with no authorized Apple Music contributor). Drives the ＋ help wording.
    private var canAddToLibrary: Bool {
        streaming.providers.libraryContributors.first?.canAddToLibrary ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                    // "E" edition badge (mirrors CollectionSongRow's) so clean vs explicit
                    // editions of the same track are tellable apart in Discover results.
                    if hit.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                            .accessibilityIdentifier("discover-explicit-badge")
                    }
                }
                subtitleLine
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

    /// "artist · album", with the ALBUM half a live link to its preview when the hit carries
    /// an album id (server hits always do; a MusicKit-only hit may not, and then it stays
    /// plain text rather than becoming a dead tap).
    @ViewBuilder private var subtitleLine: some View {
        if let path, let cid = hit.albumAppleMusicId, !cid.isEmpty,
           let name = hit.album, !name.isEmpty {
            HStack(spacing: 4) {
                if !hit.artist.isEmpty {
                    Text("\(hit.artist) ·").font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Button {
                    path.wrappedValue.append(albumPreviewRef(collectionId: cid, name: name))
                } label: {
                    Text(name).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("discover-album-link-\(index)")
            }
        } else {
            Text(subtitle).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
        }
    }

    private func albumPreviewRef(collectionId: String, name: String) -> AppleMusicAlbumRef {
        AppleMusicAlbumRef(storeID: collectionId, title: name, artist: hit.artist,
                           year: hit.year,
                           artworkURL: (hit.albumArtworkUrl ?? hit.artworkUrl).flatMap(URL.init(string:)),
                           url: nil)
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
        } else if added {
            // Serverless add feedback (review catch): with no rip server the add creates no job
            // and no manifest entry, so the row would sit on "＋ Add" forever. The recorded
            // streamable entry re-renders this (DiscoverAddsStore is @Observable).
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("discover-added-\(index)")
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
            // Capability-aware, honest on macOS: an unripped song hit carries no Apple Music
            // deep link (`hit.url` is nil), so the macOS ＋ can't open in Music — it just
            // prepares the copy. `opensInMusic: false` reflects that.
            .help(DiscoverAddWording.addHelp(noun: "song",
                                             canAddToLibrary: canAddToLibrary,
                                             opensInMusic: false))
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

// ============================================================================
// MARK: - Discover ▸ Albums (nested scope)
// ============================================================================

/// The album twin of `DiscoverSearchModel` — same @MainActor @Observable + off-main
/// debounced task shape (400 ms, cancel-on-retrigger). Never searches synchronously in a
/// view body: the catalog/network work runs inside the `@ObservationIgnored` Task (the
/// main-thread-hang lesson). Two album sources merge by collectionId: the rip-server
/// `/search?entity=album` proxy (reachable by every tester) and MusicKit album search
/// (full catalog coverage when the account is authorized).
@MainActor
@Observable
final class DiscoverAlbumSearchModel {
    enum State: Equatable { case idle, loading, loaded }

    var state: State = .idle
    private(set) var hits: [RipsStore.DiscoverAlbumHit] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func searchDebounced(_ query: String, artist: String = "", rips: RipsStore,
                         catalog: (any StreamingSearch)? = nil) {
        task?.cancel()
        guard let term = DiscoverSearchModel.term(title: query, artist: artist) else {
            hits = []; state = .idle; return
        }
        let refine = artist.trimmingCharacters(in: .whitespaces)
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.state = .loading
            async let proxyHits = rips.discoverSearchAlbums(term)
            var catalogHits: [RipsStore.DiscoverAlbumHit] = []
            if let catalog, catalog.canSearch {
                let albums = (try? await catalog.searchAlbums(term, limit: 25)) ?? []
                catalogHits = albums.map(Self.hit(from:))
            }
            let merged = Self.merge(catalog: catalogHits, server: await proxyHits)
            guard !Task.isCancelled else { return }
            self.hits = Self.refine(merged, artist: refine)
            self.state = .loaded
        }
    }

    /// Map a MusicKit album reference into the Discover album row shape (the
    /// `amrec_album_<collectionId>` provisional-id convention).
    /// Delegates to `DiscoverAlbumHit(ref:)` — the ONE place the provisional album id is
    /// synthesized, shared with the album preview screen's giant ＋ so the two can't drift.
    static func hit(from ref: AppleMusicAlbumRef) -> RipsStore.DiscoverAlbumHit {
        RipsStore.DiscoverAlbumHit(ref: ref)
    }

    /// Merge doctrine: MusicKit's ranking leads; proxy-only albums follow. Dedup by the
    /// Apple Music collectionId (an album has no ripped/url authority to hand back, so the
    /// catalog row simply wins on a tie).
    static func merge(catalog: [RipsStore.DiscoverAlbumHit],
                      server: [RipsStore.DiscoverAlbumHit]) -> [RipsStore.DiscoverAlbumHit] {
        var seen = Set<String>()
        var out: [RipsStore.DiscoverAlbumHit] = []
        for h in catalog where seen.insert(h.appleMusicId).inserted { out.append(h) }
        for h in server where seen.insert(h.appleMusicId).inserted { out.append(h) }
        return out
    }

    /// Client-side artist narrowing — the iTunes term search matches across fields.
    static func refine(_ hits: [RipsStore.DiscoverAlbumHit], artist: String) -> [RipsStore.DiscoverAlbumHit] {
        let a = artist.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return hits }
        return hits.filter { $0.artist.localizedCaseInsensitiveContains(a) }
    }

    func cancel() { task?.cancel(); task = nil; hits = []; state = .idle }
}

/// Browse ▸ Discover ▸ Albums results. Mirrors `DiscoverResultsList`; branches the results
/// area when the nested Songs/Albums scope is on Albums.
struct DiscoverAlbumResultsList: View {
    @Environment(RipsStore.self) private var rips
    let model: DiscoverAlbumSearchModel
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
                    // MusicKit hits render even when the rip-server half errored (public-user
                    // audit fix: "No import server configured" was MASKING working results —
                    // Discover search + AM-library add are serverless; only rip capture isn't).
                    if !model.hits.isEmpty {
                        list
                    } else if let message = rips.discoverError {
                        failure(message)
                    } else {
                        noMatches
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var hint: some View {
        ContentUnavailableView {
            Label("Discover albums", systemImage: "square.stack")
        } description: {
            Text("Search Apple Music for an album — ＋ Add saves it to your Apple Music library and prepares your copy of every track.")
        }
        .accessibilityIdentifier("discover-album-hint")
    }

    private var loading: some View {
        VStack(spacing: 12) { ProgressView(); Text("Searching Apple Music…").foregroundStyle(Theme.fgDim) }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No albums", systemImage: "magnifyingglass")
        } description: {
            Text("No album in the Apple Music catalog matched “\(query)”.")
        }
        .accessibilityIdentifier("discover-album-empty")
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Discover unavailable", systemImage: "wifi.exclamationmark")
        } description: { Text(message) }
        .accessibilityIdentifier("discover-album-error")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                    DiscoverAlbumRow(hit: hit, index: index)
                    Divider().overlay(Theme.border)
                }
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("discover-album-list")
    }
}

/// Settlement state of a fanned-out album add (pure, so it's unit-testable off the view).
/// An album is SETTLED once every track has reached a TERMINAL state — ready (in the rips
/// manifest) OR failed (its rip job exhausted retries → `.error`). A settled album with
/// fewer ready than total tracks is a PARTIAL result: a single track that never lands must
/// NOT pin the row's spinner forever (the poll's 1-hour cap would never resolve it).
enum DiscoverAlbumAddState: Equatable {
    case adding(ready: Int, total: Int)   // still work in flight (non-terminal tracks remain)
    case partial(ready: Int, total: Int)  // settled, but some tracks failed — surface n/m
    case added                            // every track ready

    /// `readyIds` = tracks present in the manifest; `erroredIds` = tracks whose rip job is
    /// in a terminal `.error` phase (failed / retries exhausted). Empty `trackIds` ⇒ `.added`
    /// (nothing to wait on — a legacy provisional album with no recorded tracks).
    static func of(trackIds: [String], readyIds: Set<String>, erroredIds: Set<String>) -> DiscoverAlbumAddState {
        let total = trackIds.count
        let ready = trackIds.reduce(0) { $0 + (readyIds.contains($1) ? 1 : 0) }
        let settled = trackIds.allSatisfy { readyIds.contains($0) || erroredIds.contains($0) }
        if settled && ready >= total { return .added }
        if settled { return .partial(ready: ready, total: total) }
        return .adding(ready: ready, total: total)
    }

    /// The state of a RECORDED album add. An add that never asked for copies has nothing to
    /// wait on, so it reads `.added` the moment it lands — the per-track readout above only
    /// applies when rips were actually requested (`preparedCopies`). Without this a
    /// library-only add spins at 0/n forever: no rip was queued, so no track ever becomes
    /// ready and the album never settles.
    ///
    /// This overload exists so the two surfaces that render the capsule cannot disagree — a
    /// `preparedCopies` check written inline at each call site would have to be fixed twice.
    /// A nil `preparedCopies` (a document written before add and download were split) keeps
    /// the progress readout, which is what those albums were actually doing.
    static func of(entry: DiscoverAddsStore.AlbumEntry,
                   readyIds: Set<String>, erroredIds: Set<String>) -> DiscoverAlbumAddState {
        guard entry.preparedCopies ?? true else { return .added }
        return of(trackIds: entry.trackIds ?? [], readyIds: readyIds, erroredIds: erroredIds)
    }
}

/// One Discover album result row: artwork · title / artist · trailing action. The trailing
/// action is state-driven: not added → ＋ Add · adding → spinner · added → per-track rip
/// progress (n/m) → ✓ Added when every track's copy has landed; a settled-but-partial add
/// (some tracks never prepared) surfaces n/m instead of an eternal spinner.
private struct DiscoverAlbumRow: View {
    @Environment(RipsStore.self) private var rips
    @Environment(StreamingStore.self) private var streaming
    @Environment(\.openURL) private var openURL
    let hit: RipsStore.DiscoverAlbumHit
    let index: Int
    @State private var adding = false

    /// The provisional album entry once the add has recorded it (nil until then).
    private var addedEntry: DiscoverAddsStore.AlbumEntry? {
        rips.discoverAdds?.albums.first { $0.albumId == hit.albumId }
    }

    /// Whether this device can write the user's Apple Music library — false on macOS (and on
    /// any device with no authorized Apple Music contributor). Drives the ＋ help wording.
    private var canAddToLibrary: Bool {
        streaming.providers.libraryContributors.first?.canAddToLibrary ?? false
    }

    /// The macOS ＋ fallback deep-links the album into Music.app (see `add()`): only when the
    /// library can't be written AND we have a catalog URL to open. Mirrors `add()`'s condition
    /// exactly so the help text matches the behavior.
    private var opensInMusic: Bool {
        #if os(macOS)
        return canAddToLibrary == false && hit.url != nil
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-album-row-\(index)")
    }

    private var subtitle: String {
        var parts = [hit.artist]
        if let y = hit.year { parts.append(String(y)) }
        if let n = hit.trackCount { parts.append("\(n) tracks") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var artwork: some View {
        AsyncImage(url: hit.artworkUrl.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(Theme.border)
                .overlay(Image(systemName: "square.stack").foregroundStyle(Theme.fgDim))
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var trailing: some View {
        if let entry = addedEntry {
            let ids = entry.trackIds ?? []
            // Terminal = ready (manifest) OR failed (rip job in .error) — a track that never
            // lands settles the album as PARTIAL rather than spinning forever.
            let readyIds = Set(ids.filter { rips.manifest[$0] != nil })
            let erroredIds = Set(ids.filter { rips.jobs[$0]?.phase == .error })
            switch DiscoverAlbumAddState.of(entry: entry, readyIds: readyIds, erroredIds: erroredIds) {
            case .added:
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).font(.title3).foregroundStyle(.green)
                    .accessibilityIdentifier("discover-album-add-\(index)")
                    .help("All tracks ready")
            case let .partial(ready, total):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(ready)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("discover-album-add-\(index)")
                .help("\(ready) of \(total) tracks ready — the rest couldn’t be prepared")
            case let .adding(ready, total):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(ready)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("discover-album-add-\(index)")
            }
        } else if adding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Adding…").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .accessibilityIdentifier("discover-album-add-\(index)")
        } else {
            Button { add() } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("discover-album-add-\(index)")
                // Capability-aware, honest on macOS: no library write there — the ＋ opens the
                // album in Music.app (see `add()`) and prepares copies, so it must NOT claim a
                // library save (F7). Same helper + capability check as the song row.
                .help(DiscoverAddWording.addHelp(noun: "album",
                                                 canAddToLibrary: canAddToLibrary,
                                                 opensInMusic: opensInMusic))
        }
    }

    /// Add = library write (non-macOS) + per-track rip fan-out + provisional album. On
    /// macOS the library write is unavailable, so open the album in Music.app (the Shazam
    /// macOS fallback) and let the rip fan-out proceed.
    ///
    /// `.andPrepareCopies` — DELIBERATELY UNCHANGED while the album PREVIEW moved to
    /// `.libraryOnly`. This row IS the download gesture on this surface: its entire trailing
    /// control is live per-track rip progress (n/m → ✓ Added), its help text promises prepared
    /// copies, and unlike the preview it offers no separate "Download to device". Making it
    /// library-only would gut that readout and leave no way to ask for the audio at all.
    private func add() {
        let h = hit
        let lib = streaming.providers.libraryContributors.first
        #if os(macOS)
        if (lib?.canAddToLibrary ?? false) == false, let u = h.url.flatMap(URL.init(string:)) {
            openURL(u)
        }
        #endif
        adding = true
        Task {
            await rips.discoverAddAlbum(h, library: lib, intent: .andPrepareCopies)
            adding = false
        }
    }
}
