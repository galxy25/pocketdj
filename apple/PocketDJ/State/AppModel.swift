import SwiftUI
import Observation

/// Root app state: loads the catalog (one or more configured sources, merged)
/// and indexes it so views resolve albums/songs instantly. Pure of view concerns.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    var state: LoadState = .idle
    /// Effective catalog = raw index with the user's local edits overlaid.
    var albums: [IndexAlbum] = []
    var songs: [IndexSong] = []
    var songsById: [String: IndexSong] = [:]
    var albumsById: [String: IndexAlbum] = [:]

    /// Apple Music artist ids, keyed by `IndexArtist.normalize(artistName)`. Empty for sources
    /// that carry no artist table (vinyl, fixtures, pre-backfill indexes) — every reader must
    /// treat a miss as "no release feed for this artist", never as an error.
    private(set) var artistsByKey: [String: IndexArtist] = [:]

    /// The Apple Music catalog artist id for a raw artist name, or nil if the catalog can't
    /// place it. This is the ONLY supported way to get one — it applies the normalization the
    /// index was built with, which a caller doing its own `lowercased()` would get subtly wrong.
    func artistId(forArtistName raw: String) -> Int? {
        artistsByKey[IndexArtist.normalize(raw)]?.id
    }

    /// Pre-built browse rows for each kind, with album name / origin source / top-tier
    /// genre already resolved per item — the exact shape BrowseState used to derive on
    /// EVERY render. Building these ~90k `BrowseItem`s is the bulk of on-device browse
    /// cost, so we do it ONCE here (rebuilt only in `applyEdits`, i.e. on catalog load
    /// or an edit save) instead of re-mapping the whole catalog each body evaluation.
    /// Observed, so a view reading them re-renders when the catalog changes.
    private(set) var albumBrowseItems: [BrowseItem] = []
    private(set) var songBrowseItems: [BrowseItem] = []
    /// Per-item case/diacritic-folded search haystack (title + artist + album/genre), parallel to
    /// `albumBrowseItems` / `songBrowseItems` and built ONCE alongside them. Lets the text-query
    /// filter be a cheap pre-folded `contains` (run OFF the main actor) instead of ~90k × 3
    /// locale-aware `localizedCaseInsensitiveContains` calls per keystroke ON the main actor — the
    /// multi-second search hang the runloop hang reports captured.
    private(set) var albumSearchKeys: [String] = []
    private(set) var songSearchKeys: [String] = []
    /// Artist-grouping browse rows (one per distinct album-artist) + their folded name keys —
    /// the Artists browse kind. Built once in `buildEffective` like the album/song rows.
    private(set) var artistBrowseItems: [BrowseItem] = []
    private(set) var artistSearchKeys: [String] = []
    /// Bumped whenever the effective catalog changes (load / edit). Part of the browse
    /// results cache key, so a stale memo can never survive a catalog change.
    private(set) var catalogRevision = 0

    /// Memo for `songIds(forArtistId:)`, keyed on `catalogRevision`. Built on FIRST use and only
    /// if something asks — the release feed's TTL math is the only caller, so a launch that never
    /// plays a song never builds it.
    @ObservationIgnored private var songIdsByArtistIdCache: (revision: Int, map: [Int: [String]])?

    /// Every catalog song credited to an Apple Music artist id. The inverse of the index's
    /// `artists` table (name → id), which is stored the other way round because that is the
    /// direction the join needs at play time.
    func songIds(forArtistId artistId: Int) -> [String] {
        if let c = songIdsByArtistIdCache, c.revision == catalogRevision {
            return c.map[artistId] ?? []
        }
        // One artist NAME can map to one id, but several names can map to the SAME id (the
        // `alt` splits in the artist table are compilation/feature credits), so this is built by
        // walking songs → name → id rather than by inverting the table entry-by-entry.
        var map: [Int: [String]] = [:]
        for s in songs {
            guard let id = artistsByKey[IndexArtist.normalize(s.artist)]?.id else { continue }
            map[id, default: []].append(s.id)
        }
        songIdsByArtistIdCache = (catalogRevision, map)
        return map[artistId] ?? []
    }

    /// Memo for `zoneTracks`, keyed on `catalogRevision` — the `membershipSnapshotCache`
    /// precedent. A stale memo can never survive a catalog change because the revision is part
    /// of the key.
    @ObservationIgnored private var zoneTracksCache: (revision: Int, tracks: [ZoneEngine.Track])?

    /// The whole catalog projected into the shape the For You ranking needs (artist join key +
    /// top-tier genre), built ONCE per catalog revision.
    ///
    /// Built lazily rather than in `buildEffective` because For You is one tab: a launch that
    /// never opens it should not pay ~96k rows of projection. Once built it is reused until the
    /// catalog changes, so opening the tab repeatedly costs nothing.
    var zoneTracks: [ZoneEngine.Track] {
        if let c = zoneTracksCache, c.revision == catalogRevision { return c.tracks }
        let tracks = songs.map { s -> ZoneEngine.Track in
            // `Genre.category` folds everything it cannot classify into ONE catch-all bucket
            // ("Other"). Passing that through as a genre would make every unclassified song
            // "similar" to every other one — the single biggest bucket in the catalog acting as
            // a similarity signal. It maps to nil instead, so those songs are ranked on artist
            // affinity alone.
            let cat = Genre.category(s.albumId.flatMap { albumsById[$0] }?.genre)
            // No artist KEY is passed: `Track` derives it (`PuzzleSimilarity.artistKey`) so the
            // 3-per-artist cap cannot mean one thing in `inDaZone` and another in `suggestions`.
            // `IndexArtist.normalize` used to be handed in here, and it does not fold diacritics
            // or strip a leading "the " — which gave "Jaÿ-Z" and "Jay-Z" three slots EACH.
            return ZoneEngine.Track(songId: s.id,
                                    artistName: s.artist,
                                    genre: cat == Genre.other ? nil : cat)
        }
        zoneTracksCache = (catalogRevision, tracks)
        return tracks
    }

    /// song id → top-tier genre category, the map `PuzzleSimilarity` (and therefore In Da Zone)
    /// takes. Derived from the `zoneTracks` memo rather than re-walking the catalog, so the two
    /// projections can never disagree about a song's genre — including about which songs have
    /// none, since the catch-all bucket is already mapped to nil there and simply does not get a
    /// key here. Memoized on the same revision for the same reason.
    var zoneGenreBySongId: [String: String] {
        if let c = zoneGenreCache, c.revision == catalogRevision { return c.map }
        var map: [String: String] = [:]
        map.reserveCapacity(songs.count)
        for t in zoneTracks where t.genre != nil { map[t.songId] = t.genre }
        zoneGenreCache = (catalogRevision, map)
        return map
    }
    @ObservationIgnored private var zoneGenreCache: (revision: Int, map: [String: String])?

    /// The catalog album for a song id (via the song's `albumId`), when both the song and its
    /// album are indexed. Backs the lock-screen / Control Center Now Playing card's cover art —
    /// nil for a track that isn't in the catalog (e.g. an ad-hoc rip), so the card shows title +
    /// artist only.
    func album(forSongId id: String) -> IndexAlbum? {
        songsById[id]?.albumId.flatMap { albumsById[$0] }
    }

    /// Resolve ordered song ids to universal tracklist CSV rows (title/artist/album/year/genre) —
    /// shared by every CSV export (playlist / pocket / setlist / session). Genre + album name live on
    /// the album; year prefers the song's, falling back to the album's. Ids with no catalog song drop.
    func tracklistCSVRows(forSongIds ids: [String]) -> [TracklistCSV.Row] {
        ids.compactMap { id in
            guard let s = songsById[id] else { return nil }
            let album = s.albumId.flatMap { albumsById[$0] }
            return TracklistCSV.Row(title: s.name, artist: s.artist, album: album?.name ?? "",
                                    year: s.year ?? album?.year, genre: album?.genre ?? "",
                                    // F3 Sharing: the direct link we matched, else a per-service SEARCH
                                    // link (Levi 2026-07-25 — a search link beats a blank cell when the
                                    // backfill hasn't resolved a canonical URL). Same resolvers as the
                                    // share-text block, so exports and shares agree.
                                    appleMusicUrl: ShareText.appleMusicURL(url: s.appleMusicUrl, id: s.appleMusicId,
                                                                           kind: "song", title: s.name, artist: s.artist),
                                    spotifyUrl: ShareText.spotifyURL(url: s.spotifyUrl, title: s.name, artist: s.artist),
                                    youtubeUrl: ShareText.youtubeURL(url: s.youtubeUrl, title: s.name, artist: s.artist))
        }
    }
    /// Read-only playlists carried in the enabled sources (e.g. Apple Music user
    /// playlists), merged + deduped by id, each tagged with its source's name.
    var indexPlaylists: [SourcePlaylist] = []
    var manifest: Manifest?

    /// Origin source name per album/song id (FIRST-seen wins, same dedup order as
    /// `merge`) — the merged catalog otherwise loses which source each item came
    /// from. Mirrors how `sourcePlaylists` tags playlists by source.
    private(set) var albumSourceById: [String: String] = [:]
    private(set) var songSourceById: [String: String] = [:]
    /// Distinct source names present in the loaded catalog, in first-seen order
    /// (e.g. "My Vinyl", "Apple Music (Local)"). Drives the source filter options.
    private(set) var availableSources: [String] = []

    /// The un-edited catalog (so edit forms can show originals / compute deltas).
    private var rawAlbums: [IndexAlbum] = []
    private var rawSongs: [IndexSong] = []
    var rawAlbumsById: [String: IndexAlbum] = [:]
    var rawSongsById: [String: IndexSong] = [:]

    // Small LRU-ish memo of fully-derived browse results (query→filter→sort), keyed by
    // BrowseState.resultsKey. Lives HERE (long-lived @Observable) — not on BrowseState,
    // which SwiftUI recreates every time the Browser tab is re-entered — so returning to
    // the tab with the same filters/sort is instant instead of re-sorting the catalog.
    // @ObservationIgnored: mutating the cache while READING results inside a view's body
    // must NOT invalidate that view (that would loop). Bounded so it can't grow unbounded
    // as the user tweaks filters; fully cleared whenever the catalog changes.
    @ObservationIgnored private var browseResultsCache: [String: [BrowseItem]] = [:]
    @ObservationIgnored private var browseResultsOrder: [String] = []
    private static let browseResultsCacheCap = 6

    /// Memo for `recentlyAddedSongIds` — the single most expensive thing the Collections tab
    /// does. Deriving it walks the WHOLE catalog (~96k songs, ~93k of them carrying
    /// `dateAdded`) and then selects the newest `limit`; `PlaylistsView` asks for it TWICE per
    /// body evaluation (the empty-state gate, then the row), and SwiftUI evaluates that body
    /// several times per navigation. Measured on an M-series simulator at real scale: 175 ms a
    /// call, so ~350 ms per body pass — multiple seconds across a navigation on an iPhone.
    /// Keyed by `recentlyAddedKey(limit:)`, which folds in `catalogRevision` plus a cheap
    /// signature of the four add-stores, so any real add/remove still re-derives.
    /// @ObservationIgnored for the same reason as `browseResultsCache`: filling it from inside
    /// a view's body must not invalidate that body.
    @ObservationIgnored private var recentlyAddedMemo: (key: String, ids: [String])?

    /// The indexes the offline-first seed decoded, keyed by source URL, kept so the conditional
    /// refresh that always follows can REUSE them on a 304 instead of decoding the same ~61 MB
    /// of JSON a second time. Cleared once consumed — this is a launch-window hand-off, not a
    /// cache (holding ~109k rows alive for the process lifetime would be a real memory cost).
    @ObservationIgnored private var seededIndexes: [String: IndexJSON] = [:]

    /// A cheap signature of everything the seed merged BESIDES the URL catalogs. If this is
    /// unchanged at refresh time, and no source changed, and the owner gate agrees with the
    /// seed's `false`, then the refresh would rebuild a byte-identical catalog — so it doesn't.
    @ObservationIgnored private var seededProvisionalSignature: String?

    private func provisionalSignature() -> String {
        [
            "\(discoverAdds?.entries.count ?? 0)", "\(discoverAdds?.albums.count ?? 0)",
            "\(importedSongs?.songs.count ?? 0)", "\(importedSongs?.albums.count ?? 0)",
            "\(profileSource?.songs.count ?? 0)", profileSource?.sourceName ?? "",
            "\(appleMusicLibrary?.songs.count ?? 0)", "\(appleMusicLibrary?.albums.count ?? 0)",
            "\(appleMusicLibrary?.playlists.count ?? 0)",
            "\(edits?.doc.albums.count ?? 0)", "\(edits?.doc.songs.count ?? 0)",
        ].joined(separator: "|")
    }

    /// Single-flight guard for `loadIfNeeded`. The seed/refresh now suspend (off-main build), so
    /// `state` is no longer claimed synchronously before the first `await` — this flag stops two
    /// concurrent callers (a multi-window RootView `.task` + an App-Intent launch) from both passing
    /// the state check and building the catalog twice / firing duplicate network refreshes.
    @ObservationIgnored private var loadInFlight = false

    /// This install's resolved catalog-owner identity (`OwnerIdentity.isOwner()`), cached here so
    /// SYNCHRONOUS read paths (e.g. `recentlyAddedSongIds`) can gate on it without a CloudKit await.
    /// Resolved in `performRefresh` (off the launch critical path) and FAILS CLOSED to `false` — a
    /// hybrid/public user is never mistaken for the owner, so the curator's library-add history and
    /// catalog rows never bleed into the user's own surfaces. Same discriminator as the owner-gated
    /// supersede (both replace the earlier, wrong `appleMusicPrivateSync` proxy: private-mode
    /// defaults to TRUE for a hybrid user, who has the curator's rip-server URL). Internal setter
    /// (not `private(set)`) so `@testable` tests can drive the owner/non-owner branch; production
    /// writes it only from `performRefresh`.
    var resolvedIsOwner = false

    /// The last owner answer this install actually RESOLVED, remembered across launches.
    ///
    /// The offline-first seed cannot ask CloudKit — that round trip is exactly what it exists to
    /// avoid — so it used to hard-code "not the owner". For a real owner that guarantees the
    /// seed's merge differs from the refresh's, which forces the ~1.6-2.3 s rebuild on every
    /// single launch. Remembering the answer lets the seed assume it and the refresh confirm it.
    ///
    /// SAFE BECAUSE IT IS ONLY EVER AN ASSUMPTION. It is written only from a genuine resolution
    /// (never from a `nil`/undetermined one, so a non-owner can never acquire a `true`), the live
    /// gate still runs every launch, and any disagreement forces the full rebuild. It changes
    /// which catalog the seed shows for a few hundred milliseconds, never the final one.
    private static let ownerMemoKey = "pdj.catalog.lastKnownIsOwner"
    private var lastKnownIsOwner: Bool {
        get { defaults.bool(forKey: Self.ownerMemoKey) }
        set { defaults.set(newValue, forKey: Self.ownerMemoKey) }
    }
    /// Test seam: a private suite keeps a unit test from reading/writing the real preference.
    @ObservationIgnored var defaults: UserDefaults = .standard
    /// Test seam for the owner gate (CloudKit is untouchable under a fixture run).
    @ObservationIgnored var ownerResolver: () async -> Bool? = { await OwnerIdentity.resolveIsOwner() }
    /// What the seed ASSUMED, so the refresh can tell whether its real answer agrees.
    @ObservationIgnored private var seededSupersede: Bool?

    /// Optional fixed loader (tests / fixtures). When nil, sources come from `settings`.
    private let loader: CatalogLoading?
    /// Settings drive the live multi-source catalog (set by the app at launch).
    var settings: SettingsStore?
    /// Local metadata edits, overlaid onto the catalog (set by the app at launch).
    var edits: EditsStore?
    /// Provisional Discover adds — merged as a synthetic source until the nightly
    /// indexer lands each track for real (set by the app at launch).
    var discoverAdds: DiscoverAddsStore?
    /// Provisional IMPORTED entries (cross-user playlist/pocket transfers) — merged as
    /// a synthetic source appended LAST, so real sources shadow them by merge order
    /// alone and the entries survive as durable fallbacks (set by the app at launch).
    var importedSongs: ImportedSongsStore?
    /// The per-profile "Pocket DJ" custom-audio source — device-local items (samples + demuxes)
    /// merged as a synthetic source appended LAST (like Imported); its DISPLAY name is the profile
    /// name (set at launch, re-tagged on rename via a catalog rebuild). Present once it has ≥1 item.
    var profileSource: ProfileSourceStore?
    /// The user's OWN Apple Music library, indexed ON DEVICE (public-mode parity for the private
    /// catalog's "Apple Music (Local)" source) — merged as a synthetic source; its rows yield to
    /// an indexed twin by `appleMusicId` (the Discover supersede doctrine), so flipping Private
    /// syncing on re-homes the library instead of duplicating it (set by the app at launch).
    var appleMusicLibrary: AppleMusicLibraryStore?
    /// Supersede hook: (provisional id → indexed id) pairs for the collections remap —
    /// Discover amrec_ supersedes AND imported amrec_ remaps ride the same seam
    /// (set by the app at launch).
    var onDiscoverSupersede: (([(from: String, to: String)]) -> Void)?
    /// Fired when the user removes an item from their library via `removeFromLibrary` — wired at
    /// launch to log a `.catalogRemove` History event. The catalog eject itself is handled inline.
    var onCatalogRemove: ((_ itemId: String, _ itemTitle: String) -> Void)?

    /// Last-known "From your sources" rows, so the Shared tab paints its real contents before
    /// the ~61 MB catalog has decoded instead of showing "No source playlists". @ObservationIgnored:
    /// recording into it happens inside `assign`, which is already publishing.
    @ObservationIgnored let sourcePlaylistsCache: SourcePlaylistsCache

    /// `sourcePlaylistsCache` defaults to nil and is built INSIDE the init rather than as a
    /// default argument: default arguments are evaluated in a nonisolated context, and the cache
    /// is `@MainActor`.
    ///
    /// `seedFromCache` is an explicit seam, not an inference. It defaults to "only a real,
    /// loader-less model paints remembered rows" — a fixture-backed model must start clean, or
    /// every test would inherit whatever the developer's app last cached into Application
    /// Support. It is a parameter rather than a hard-coded `loader == nil` check because the
    /// test scheme sets PDJ_USE_FIXTURE for the whole target, which would otherwise leave the
    /// production branch permanently unreachable from tests.
    init(loader: CatalogLoading? = nil,
         sourcePlaylistsCache: SourcePlaylistsCache? = nil,
         seedFromCache: Bool? = nil) {
        let cache = sourcePlaylistsCache ?? SourcePlaylistsCache()
        self.sourcePlaylistsCache = cache
        if let loader {
            self.loader = loader
        } else if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            self.loader = FixtureCatalog()
        } else {
            self.loader = nil
        }
        // Paint the remembered rows immediately. A real catalog assign replaces them wholesale;
        // until then this is the difference between the user's source playlists and an empty state.
        if seedFromCache ?? (self.loader == nil) { indexPlaylists = cache.snapshot() }
    }

    var sourceName: String { manifest?.sourceName ?? "Collection" }
    var albumCount: Int { albums.count }
    var songCount: Int { songs.count }

    func loadIfNeeded() async {
        switch state {
        case .loaded, .loading: return
        default: break
        }
        // Single-flight: the build below suspends, so claim the load with a flag (not `state`, which
        // we intentionally leave `.idle` on the seed path to avoid a loading flash). Without this a
        // second concurrent caller would slip past the `state` check during the first's `await`.
        if loadInFlight { return }
        loadInFlight = true
        defer { loadInFlight = false }
        // OFFLINE-FIRST: render the last-good catalog from the on-disk cache — no waiting on the
        // network — fixing the cold/iOS-kill relaunch that showed an empty UI while it re-downloaded
        // a catalog it already had. The decode + merge + edit-overlay + browse-row build all run OFF
        // the main actor (see `seedFromCache` → `buildDerived`), so a large (~90k-row) catalog never
        // blocks the first frame — the visionOS blank-first-window on cold relaunch was this same
        // build blocking the compositor's first frame. Only show `.loading` when nothing is cached.
        if await seedFromCache() {
            // Seed applied ⇒ state is already `.loaded`. Run the conditional network refresh
            // OFF the caller's critical path: a caller that awaits here (e.g. a Siri playback
            // intent on a cold background launch) must not hang on ~30s-per-source network
            // timeouts for a catalog — and burned songs — that are already on disk. Re-entry
            // is safe: the `.loaded` early-return above keeps this to one refresh per load.
            Task { await self.performRefresh(hadData: true) }
            return
        }
        state = .loading
        await performRefresh(hadData: false)
    }

    /// Populate the catalog from each enabled source's CatalogService disk cache, WITHOUT touching
    /// the network. The heavy work — JSON-decoding each cached index and building the merged,
    /// edit-overlaid, indexed catalog + browse rows — runs on a detached task OFF the main actor;
    /// only the final `assign` of the finished value touches `@MainActor` state. Returns whether
    /// anything was seeded. No-op for the fixture/test loader (no per-URL cache) and on a true
    /// first launch (no cache yet).
    @discardableResult
    private func seedFromCache() async -> Bool {
        guard loader == nil else { return false }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        let albumEdits = edits?.doc.albums ?? [:]
        let songEdits = edits?.doc.songs ?? [:]
        let provisional = discoverAdds?.entries ?? []
        let provisionalAlbums = discoverAdds?.albums ?? []
        let importedS = importedSongs?.songs ?? []
        let importedA = importedSongs?.albums ?? []
        let profileSongs = profileSource?.songs ?? []
        let profileName = profileSource?.sourceName ?? ProfileSourceStore.defaultName
        let amLibSongs = appleMusicLibrary?.songs ?? []
        let amLibAlbums = appleMusicLibrary?.albums ?? []
        let amLibPlaylists = appleMusicLibrary?.playlists ?? []
        // The seed cannot prove owner identity — that needs a CloudKit round trip, and not
        // blocking the first frame on it is the whole point of this path. So it ASSUMES the last
        // answer this install resolved (see `lastKnownIsOwner`), which is `false` until one is
        // resolved, i.e. the old fail-closed behaviour on a fresh install. The `performRefresh`
        // that always follows resolves the real answer and rebuilds if it disagrees.
        let amLibSupersedes = lastKnownIsOwner
        // Decode the caches ONCE and hand the decoded values to the refresh that follows — see
        // `seededIndexes`. Keyed by URL so a per-source 304 can reuse just that source.
        let decodedByURL: [String: IndexJSON] = await Task.detached(priority: .userInitiated) {
            var out: [String: IndexJSON] = [:]
            for url in urls {
                if let idx = CatalogService.loadCachedIndex(for: url) { out[url.absoluteString] = idx }
            }
            return out
        }.value
        let built = await Task.detached(priority: .userInitiated) { () -> (Derived, [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)])? in
            let cached = urls.compactMap { decodedByURL[$0.absoluteString] }
            // Seed when ANY content exists: cached URL catalogs OR the injection sources — a
            // public user with zero URL sources still gets their own library/adds/imports on
            // screen instantly (the audit's confirmed-critical fix; injections must never go
            // dark because no catalog URL is configured or cached).
            let hasSynthetic = !provisional.isEmpty || !provisionalAlbums.isEmpty
                || !importedS.isEmpty || !importedA.isEmpty || !profileSongs.isEmpty
                || !amLibSongs.isEmpty || !amLibPlaylists.isEmpty
            guard !cached.isEmpty || hasSynthetic else { return nil }
            let (indexes, discoverPairs, importedPairs, discoverAlbumPairs, amLibPairs) = AppModel.withProvisionalSources(
                discover: provisional, discoverAlbums: provisionalAlbums,
                importedSongs: importedS, importedAlbums: importedA,
                profileSongs: profileSongs, profileName: profileName,
                amLibrarySongs: amLibSongs, amLibraryAlbums: amLibAlbums,
                amLibraryPlaylists: amLibPlaylists, amLibrarySupersedes: amLibSupersedes, indexes: cached)
            return (AppModel.buildDerived(indexes: indexes, albumEdits: albumEdits, songEdits: songEdits),
                    discoverPairs, importedPairs, discoverAlbumPairs, amLibPairs)
        }.value
        guard let (derived, discoverPairs, importedPairs, discoverAlbumPairs, amLibPairs) = built else { return false }
        // Hand off to the refresh: the decoded indexes (so a 304 skips re-decoding) and the
        // inputs this seed used (so the refresh can prove a rebuild would change nothing).
        seededIndexes = decodedByURL
        seededProvisionalSignature = provisionalSignature()
        seededSupersede = amLibSupersedes
        assign(derived)
        applySupersede(discover: discoverPairs, imported: importedPairs,
                       discoverAlbums: discoverAlbumPairs, amLibrary: amLibPairs)
        reconcileEditsAfterBuild(albumEdits: albumEdits, songEdits: songEdits)
        state = .loaded
        return true
    }

    /// Fold the provisional Discover adds in as a synthetic SOURCE — after the supersede
    /// split: an add the indexer has since landed for real is excluded (its remap pair is
    /// returned instead). Pure; runs inside the off-main build. (Thin wrapper kept for
    /// the existing tests; the live pipeline calls `withProvisionalSources`.)
    nonisolated static func withDiscoverAdds(_ provisional: [DiscoverAddsStore.Entry],
                                             indexes: [IndexJSON])
        -> (indexes: [IndexJSON], superseded: [(from: String, to: String)]) {
        let r = withProvisionalSources(discover: provisional, importedSongs: [],
                                       importedAlbums: [], indexes: indexes)
        return (r.indexes, r.discoverSuperseded)
    }

    /// Trigger seam for the on-device Apple Music library indexer (wired in PocketDJApp; also
    /// driven by the pane's Get verb). Kept a closure so AppModel stays MusicKit-free.
    @ObservationIgnored var refreshAppleMusicLibrary: (() async -> Void)?

    /// Fold BOTH provisional sources in — Discover adds, then imported entries — each as
    /// a synthetic source appended AFTER every real one (merge is first-wins, so a real
    /// source always shadows a provisional twin without deleting it). Discover entries
    /// whose appleMusicId the indexer has landed are excluded with a remap pair; imported
    /// amrec_ entries likewise (catalog sng_ ids are NEVER remapped — the imported id's
    /// manifest identity is the specific recording that was shared). Pure; off-main.
    nonisolated static func withProvisionalSources(discover: [DiscoverAddsStore.Entry],
                                                   discoverAlbums: [DiscoverAddsStore.AlbumEntry] = [],
                                                   importedSongs: [ImportedSongsStore.SongEntry],
                                                   importedAlbums: [ImportedSongsStore.AlbumEntry],
                                                   profileSongs: [ProfileSourceStore.SongEntry] = [],
                                                   profileName: String = ProfileSourceStore.defaultName,
                                                   amLibrarySongs: [AppleMusicLibraryStore.SongEntry] = [],
                                                   amLibraryAlbums: [AppleMusicLibraryStore.AlbumEntry] = [],
                                                   amLibraryPlaylists: [AppleMusicLibraryStore.PlaylistEntry] = [],
                                                   amLibrarySupersedes: Bool = false,
                                                   indexes: [IndexJSON])
        -> (indexes: [IndexJSON],
            discoverSuperseded: [(from: String, to: String)],
            importedSuperseded: [(from: String, to: String)],
            discoverAlbumSuperseded: [(from: String, to: String)],
            amLibrarySuperseded: [(from: String, to: String)]) {
        guard !discover.isEmpty || !discoverAlbums.isEmpty
                || !importedSongs.isEmpty || !importedAlbums.isEmpty || !profileSongs.isEmpty
                || !amLibrarySongs.isEmpty || !amLibraryPlaylists.isEmpty else {
            return (indexes, [], [], [], [])
        }
        var byAppleMusicId: [String: String] = [:]
        var albumByAppleMusicId: [String: String] = [:]
        for index in indexes {
            for s in index.songs where s.appleMusicId != nil {
                if byAppleMusicId[s.appleMusicId!] == nil { byAppleMusicId[s.appleMusicId!] = s.id }
            }
            for a in index.albums where a.appleMusicId != nil {
                if albumByAppleMusicId[a.appleMusicId!] == nil { albumByAppleMusicId[a.appleMusicId!] = a.id }
            }
        }
        let split = DiscoverAddsStore.split(discover, indexedByAppleMusicId: byAppleMusicId)
        let albumSplit = DiscoverAddsStore.splitAlbums(discoverAlbums, indexedByAppleMusicId: albumByAppleMusicId)
        let importedPairs = ImportedSongsStore.supersedePairs(importedSongs,
                                                              indexedByAppleMusicId: byAppleMusicId)
        let remapped = Set(importedPairs.map(\.from))
        let keptImported = importedSongs.filter { !remapped.contains($0.songId) }
        // The on-device Apple Music library yields to an indexed "Apple Music (Local)" twin ONLY
        // when `amLibrarySupersedes` is true — and the CALLER sets that solely for the CATALOG
        // OWNER (see performRefresh: `await OwnerIdentity.isOwner()`). Owner identity is the only
        // signal that proves the indexed "Apple Music (Local)" catalog and this install's
        // on-device MusicKit library belong to the SAME person, so deduping them is correct.
        //
        // WHY NOT sourceName / private-mode. A HYBRID user loads the curator's shared catalog,
        // whose AM index is ALSO named "Apple Music (Local)" (the manifest carries no owner
        // field) — so the name alone cannot tell "mine" from "the curator's". And private-mode
        // (`appleMusicPrivateSync`) DEFAULTS TO TRUE for a hybrid user (they have the curator's
        // rip-server URL), so gating on it left the guard OFF for exactly the user it protects.
        // Non-owner ⇒ false ⇒ this map is empty ⇒ their library NEVER supersedes onto the
        // stranger's rows (which would permanently delete their data + flip its provenance — the
        // audit's top finding). The sourceName scope below is defense-in-depth on top of that
        // owner gate (a "My Vinyl" twin never eats a library row even if the flag were mis-set).
        let ownAMByAppleMusicId: [String: String] = {
            guard amLibrarySupersedes else { return [:] }
            var map: [String: String] = [:]
            for index in indexes where index.manifest.sourceName == Config.appleMusicSourceName {
                for s in index.songs where s.appleMusicId != nil {
                    if map[s.appleMusicId!] == nil { map[s.appleMusicId!] = s.id }
                }
            }
            return map
        }()
        let amSplit = AppleMusicLibraryStore.split(amLibrarySongs, indexedByAppleMusicId: ownAMByAppleMusicId)
        var all = indexes
        if !split.keep.isEmpty || !albumSplit.keep.isEmpty {
            all.append(DiscoverAddsStore.syntheticIndex(split.keep, albums: albumSplit.keep))
        }
        if !keptImported.isEmpty || !importedAlbums.isEmpty {
            all.append(ImportedSongsStore.syntheticIndex(songs: keptImported, albums: importedAlbums))
        }
        // The per-profile "Pocket DJ" source — appended LAST (after Imported). Present only once
        // the user has ≥1 item; carries its 2 default albums + the profile name as source/artist.
        if !profileSongs.isEmpty {
            all.append(ProfileSourceStore.syntheticIndex(songs: profileSongs, profileName: profileName))
        }
        // The on-device "Apple Music" library source (public-mode parity). Appended after every
        // real source (first-wins shadowing); its playlist mirrors ride `index.playlists` into
        // `indexPlaylists` automatically. Playlist song ids that superseded remap onto their
        // indexed twins so the mirrors stay playable either way.
        if !amSplit.keep.isEmpty || !amLibraryPlaylists.isEmpty {
            let remapPairs = Dictionary(uniqueKeysWithValues: amSplit.superseded.map { ($0.from, $0.to) })
            let playlists = amLibraryPlaylists.map { pl in
                var p = pl
                p.songIds = pl.songIds.map { remapPairs[$0] ?? $0 }
                return p
            }
            all.append(AppleMusicLibraryStore.syntheticIndex(songs: amSplit.keep,
                                                             albums: amLibraryAlbums,
                                                             playlists: playlists))
        }
        return (all, split.superseded, importedPairs, albumSplit.superseded, amSplit.superseded)
    }

    /// Land the supersedes: prune each provisional store (Discover entries whose indexed
    /// twin owns the id now; imported amrec_ entries that remapped) and remap collection
    /// references through the shared hook. Discover ALBUM supersedes only prune the
    /// provisional album row — collections reference SONG ids, never album ids, so there
    /// is nothing to remap for a superseded album.
    private func applySupersede(discover: [(from: String, to: String)],
                                imported: [(from: String, to: String)] = [],
                                discoverAlbums: [(from: String, to: String)] = [],
                                amLibrary: [(from: String, to: String)] = []) {
        if !discover.isEmpty { discoverAdds?.remove(ids: discover.map(\.from)) }
        if !imported.isEmpty { importedSongs?.remove(songIds: imported.map(\.from)) }
        if !discoverAlbums.isEmpty { discoverAdds?.remove(albumIds: discoverAlbums.map(\.from)) }
        if !amLibrary.isEmpty { appleMusicLibrary?.supersede(pairs: amLibrary) }
        let all = discover + imported + amLibrary
        guard !all.isEmpty else { return }
        onDiscoverSupersede?(all)
    }

    /// A Discover add landing while the catalog is LIVE: append the provisional row as a
    /// raw song of the synthetic source and rebuild the effective catalog (the edit-save
    /// rebuild path — synchronous, adds are user-initiated and rare).
    func injectDiscoverAdd(_ song: IndexSong) {
        guard rawSongsById[song.id] == nil, songsById[song.id] == nil else { return }
        rawSongs.append(song)
        rawSongsById[song.id] = song
        songSourceById[song.id] = DiscoverAddsStore.sourceName
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// A Discover ALBUM add landing while the catalog is LIVE: append the provisional album
    /// as a raw album of the synthetic source and rebuild (the album twin of
    /// `injectDiscoverAdd`; the per-track songs arrive via `injectDiscoverAdd`).
    func injectDiscoverAlbumAdd(_ album: IndexAlbum) {
        guard rawAlbumsById[album.id] == nil, albumsById[album.id] == nil else { return }
        rawAlbums.append(album)
        rawAlbumsById[album.id] = album
        albumSourceById[album.id] = DiscoverAddsStore.sourceName
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// A Discover ALBUM BATCH landing while the catalog is LIVE: append every provisional
    /// track song AND the album as raw rows of the synthetic source, then ONE effective
    /// rebuild — an album add fans out to N tracks, and the ~90k-row rebuild is the per-batch
    /// cost, never per-track (the album twin of `injectImported`, mirroring its one-rebuild
    /// contract). Known ids are skipped. `album` is nil when only new tracks landed.
    func injectDiscoverAlbumBatch(songs newSongs: [IndexSong], album: IndexAlbum?) {
        var changed = false
        for s in newSongs where rawSongsById[s.id] == nil && songsById[s.id] == nil {
            rawSongs.append(s)
            rawSongsById[s.id] = s
            songSourceById[s.id] = DiscoverAddsStore.sourceName
            changed = true
        }
        if let album, rawAlbumsById[album.id] == nil, albumsById[album.id] == nil {
            rawAlbums.append(album)
            rawAlbumsById[album.id] = album
            albumSourceById[album.id] = DiscoverAddsStore.sourceName
            changed = true
        }
        guard changed else { return }
        if !availableSources.contains(DiscoverAddsStore.sourceName) {
            availableSources.append(DiscoverAddsStore.sourceName)
        }
        applyEdits()
    }

    /// An IMPORT landing while the catalog is LIVE: append every unknown row (songs AND
    /// their albums) as the "Imported" synthetic source, then ONE effective rebuild — a
    /// playlist import can carry hundreds of songs, and the edit-save rebuild is the
    /// per-batch cost, never per-song. Known ids are skipped (a real source or an
    /// earlier import already owns them).
    func injectImported(songs newSongs: [IndexSong], albums newAlbums: [IndexAlbum]) {
        var changed = false
        for s in newSongs where rawSongsById[s.id] == nil && songsById[s.id] == nil {
            rawSongs.append(s)
            rawSongsById[s.id] = s
            songSourceById[s.id] = ImportedSongsStore.sourceName
            changed = true
        }
        for a in newAlbums where rawAlbumsById[a.id] == nil && albumsById[a.id] == nil {
            rawAlbums.append(a)
            rawAlbumsById[a.id] = a
            albumSourceById[a.id] = ImportedSongsStore.sourceName
            changed = true
        }
        guard changed else { return }
        if !availableSources.contains(ImportedSongsStore.sourceName) {
            availableSources.append(ImportedSongsStore.sourceName)
        }
        applyEdits()
    }

    /// A profile-source SAVE (or cloud pull) landing while the catalog is LIVE: append unknown
    /// songs + UPSERT the two default albums (their trackList GROWS — unlike `injectImported`'s
    /// skip-if-known), tag them the profile source, then ONE effective rebuild. Known song ids are
    /// skipped; `pdj_` ids are stripped from rip/CSV downstream (`CollectionsStore.songIds`).
    func injectProfileItem(songs newSongs: [IndexSong], albums newAlbums: [IndexAlbum]) {
        guard let name = profileSource?.sourceName else { return }
        var changed = false
        for s in newSongs where rawSongsById[s.id] == nil && songsById[s.id] == nil {
            rawSongs.append(s); rawSongsById[s.id] = s
            songSourceById[s.id] = name
            changed = true
        }
        // Default albums are UPSERTED (their trackList grew) — replace the raw row if present, else
        // append; always (re)tag the source. `injectImported` skips known albums; profile albums
        // must update because a new item extends the album's trackList.
        for a in newAlbums {
            if let i = rawAlbums.firstIndex(where: { $0.id == a.id }) { rawAlbums[i] = a }
            else { rawAlbums.append(a) }
            rawAlbumsById[a.id] = a
            albumSourceById[a.id] = name
            changed = true
        }
        guard changed else { return }
        if !availableSources.contains(name) { availableSources.append(name) }
        applyEdits()
    }

    /// True when `songId` was USER-ADDED to the library from a provisional streaming source
    /// (Discover ＋Add or an Imported transfer) and can therefore be removed from it — drives the
    /// "Remove from Library" action's visibility. Deliberately EXCLUDES the profile custom-audio
    /// source (its items own device-local media with their own delete lifecycle) and every real
    /// catalog source (Apple Music / vinyl / digital — the user doesn't "un-add" those here).
    func isRemovableFromLibrary(songId: String) -> Bool {
        let src = songSourceById[songId]
        return src == DiscoverAddsStore.sourceName || src == ImportedSongsStore.sourceName
    }

    /// "Remove from Library": drop a user-added provisional song from its backing store, eject it
    /// from the LIVE catalog, and log a `.catalogRemove` History event. No-op for ids that aren't
    /// user-removable (see `isRemovableFromLibrary`). The store removal is DISTINCT from the
    /// supersede `remove(...)` paths (which yield an id to its real indexed twin).
    func removeFromLibrary(songId: String) {
        let src = songSourceById[songId]
        var removed: (id: String, title: String)?
        if src == DiscoverAddsStore.sourceName {
            removed = discoverAdds?.userRemove(songId: songId)
        } else if src == ImportedSongsStore.sourceName {
            removed = importedSongs?.userRemove(songId: songId)
        }
        guard let removed else { return }
        ejectCatalogSong(id: songId)
        onCatalogRemove?(removed.id, removed.title)
    }

    /// Eject a provisional user-added song from the LIVE catalog — the inverse of the `inject*`
    /// methods: drop the raw row + its source tag, rebuild the effective catalog, then prune the
    /// synthetic source from `availableSources` if it holds no more songs OR albums.
    func ejectCatalogSong(id: String) {
        guard rawSongsById[id] != nil else { return }
        let src = songSourceById[id]
        rawSongs.removeAll { $0.id == id }
        rawSongsById[id] = nil
        songSourceById[id] = nil
        applyEdits()
        if let src, !songSourceById.values.contains(src), !albumSourceById.values.contains(src) {
            availableSources.removeAll { $0 == src }
        }
    }

    // MARK: - Recently added (virtual playlist)

    /// The reserved id of the synthetic "Recently added" playlist.
    static let recentlyAddedPlaylistId = "__pdj_recently_added__"
    /// Display name of the synthetic "Recently added" source/playlist.
    static let recentlyAddedName = "Recently added"

    /// The last-`limit` song ids the profile added to its library, NEWEST FIRST — the union of
    /// catalog `dateAdded` (Apple Music library adds, from the indexer) and the in-app add stores'
    /// `addedAtMs` (Discover ＋Add / imports / custom audio), deduped by id (newest add-time wins)
    /// and filtered to songs still resolvable in the live catalog (removed items are already ejected,
    /// so they drop out here automatically). Drives the "Recently added" virtual playlist; `limit`
    /// comes from Settings ▸ Collections (`SettingsStore.defaultRecentlyAddedCount`).
    ///
    /// MEMOIZED (was: "recomputed on read"). Deriving this walks the whole catalog and selects
    /// the newest `limit` of ~93k dated rows — 175 ms at real scale on an M-series simulator,
    /// several times that on an iPhone. `PlaylistsView` reads it twice per body evaluation and
    /// SwiftUI evaluates that body repeatedly across a navigation, which is what made the
    /// Collections tab feel like it hung. The memo key folds in `catalogRevision` and a
    /// signature of the four add-stores, so a real add/remove still re-derives; only redundant
    /// re-reads of an unchanged input are served from cache.
    func recentlyAddedSongIds(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let key = recentlyAddedKey(limit: limit)
        if let memo = recentlyAddedMemo, memo.key == key { return memo.ids }
        let ids = computeRecentlyAddedSongIds(limit: limit)
        recentlyAddedMemo = (key, ids)
        return ids
    }

    /// Cheap change-signature for the memo above. `catalogRevision` covers `songsById` /
    /// `songSourceById` wholesale (it is bumped by every `assign`), and each add-store
    /// contributes count + newest timestamp — an add or a remove moves one or both. Add-times
    /// are stamped once at add time and never edited in place, so this cannot go stale in
    /// practice; all four stores are small (user ＋Adds / imports / recordings), so building
    /// the signature is negligible next to the 93k-row derivation it guards.
    private func recentlyAddedKey(limit: Int) -> String {
        func sig<S: Sequence>(_ xs: S, _ at: (S.Element) -> Double) -> String {
            var n = 0, newest = 0.0
            for x in xs { n += 1; newest = max(newest, at(x)) }
            return "\(n):\(newest)"
        }
        let filterToOwnLibrary = settings != nil && !resolvedIsOwner
        return [
            "\(catalogRevision)", "\(limit)", "\(filterToOwnLibrary)",
            sig(appleMusicLibrary?.supersededAddedAt ?? [:]) { $0.value },
            sig(discoverAdds?.entries ?? []) { $0.addedAtMs },
            sig(importedSongs?.songs ?? []) { $0.addedAtMs },
            sig(profileSource?.songs ?? []) { $0.addedAtMs },
        ].joined(separator: "|")
    }

    /// Newest-first selection of the top `limit` add-times WITHOUT sorting the whole set.
    /// `.sorted()` over ~93k entries is ~1.5M comparisons to keep 3,650 of them; this keeps a
    /// buffer of at most 2·limit, sorting and trimming only when it fills, so the work is O(n)
    /// amortized plus a handful of O(limit log limit) trims. Ties break on id (descending) so
    /// the row order is DETERMINISTIC — the old full sort inherited Swift's unstable sort over
    /// a dictionary's arbitrary iteration order, which let equal-timestamp rows shuffle between
    /// reads.
    private static func newestFirst(_ addedAt: [String: Double], limit: Int,
                                    isResolvable: (String) -> Bool) -> [String] {
        // Strictly-newer comparison, id-tiebroken.
        func newer(_ a: (id: String, at: Double), _ b: (id: String, at: Double)) -> Bool {
            a.at != b.at ? a.at > b.at : a.id > b.id
        }
        var buf: [(id: String, at: Double)] = []
        buf.reserveCapacity(limit * 2)
        var cutoff: (id: String, at: Double)?     // weakest entry currently kept (nil until full)

        for (id, at) in addedAt {
            let cand = (id: id, at: at)
            if let cutoff, !newer(cand, cutoff) { continue }   // can't displace anything
            guard isResolvable(id) else { continue }
            buf.append(cand)
            if buf.count >= limit * 2 {
                buf.sort(by: newer)
                buf.removeLast(buf.count - limit)
                cutoff = buf[limit - 1]
            }
        }
        buf.sort(by: newer)
        if buf.count > limit { buf.removeLast(buf.count - limit) }
        return buf.map(\.id)
    }

    private func computeRecentlyAddedSongIds(limit: Int) -> [String] {
        var addedAt: [String: Double] = [:]
        // NON-OWNER scope (integrity audit): catalog `dateAdded` rows from shared URL catalogs are
        // the CATALOG OWNER's library history, not this user's — for a non-owner count only rows
        // from their own on-device "Apple Music" source. The OWNER (resolvedIsOwner) keeps
        // everything (the shared catalog IS their library history); a nil-settings host
        // (tests/fixtures — identity unknown) doesn't filter. Gated on resolved owner identity, NOT
        // `appleMusicPrivateSync`: that flag defaults TRUE for a hybrid user (curator's rip-server
        // URL), which used to leak the curator's recently-added songs into the user's own list.
        let filterToOwnLibrary = settings != nil && !resolvedIsOwner
        for (id, song) in songsById {
            guard let d = song.dateAdded, d > 0, d > (addedAt[id] ?? 0) else { continue }
            if filterToOwnLibrary, songSourceById[id] != AppleMusicLibraryStore.sourceName { continue }
            addedAt[id] = d
        }
        // The user's OWN add-times for library songs that SUPERSEDED onto a shared-catalog twin
        // (review catch): keyed to the surviving twin id, they intentionally bypass the source
        // filter above — it IS the user's own add, just re-homed onto the indexed row.
        for (id, ms) in appleMusicLibrary?.supersededAddedAt ?? [:] where ms > (addedAt[id] ?? 0) {
            addedAt[id] = ms
        }
        for e in discoverAdds?.entries ?? [] where e.addedAtMs > (addedAt[e.songId] ?? 0) { addedAt[e.songId] = e.addedAtMs }
        for e in importedSongs?.songs ?? [] where e.addedAtMs > (addedAt[e.songId] ?? 0) { addedAt[e.songId] = e.addedAtMs }
        for e in profileSource?.songs ?? [] where e.addedAtMs > (addedAt[e.songId] ?? 0) { addedAt[e.songId] = e.addedAtMs }
        return Self.newestFirst(addedAt, limit: limit) { songsById[$0] != nil }
    }

    /// Is there ANYTHING in the "Recently added" list? The Collections tab's empty-state gate
    /// asks only this, and used to answer it by building the whole 3,650-id playlist. Short-
    /// circuits on the first dated row (so it is O(1) for any real library) and never touches
    /// the memo. Mirrors `computeRecentlyAddedSongIds`'s sources and owner scoping exactly — if
    /// that gains a source, this must too.
    func hasRecentlyAddedItems(limit: Int) -> Bool {
        guard limit > 0 else { return false }
        if let memo = recentlyAddedMemo, memo.key == recentlyAddedKey(limit: limit) {
            return !memo.ids.isEmpty
        }
        let filterToOwnLibrary = settings != nil && !resolvedIsOwner
        for (id, song) in songsById {
            guard let d = song.dateAdded, d > 0 else { continue }
            if filterToOwnLibrary, songSourceById[id] != AppleMusicLibraryStore.sourceName { continue }
            return true
        }
        if (appleMusicLibrary?.supersededAddedAt ?? [:]).contains(where: { songsById[$0.key] != nil }) { return true }
        if (discoverAdds?.entries ?? []).contains(where: { songsById[$0.songId] != nil }) { return true }
        if (importedSongs?.songs ?? []).contains(where: { songsById[$0.songId] != nil }) { return true }
        if (profileSource?.songs ?? []).contains(where: { songsById[$0.songId] != nil }) { return true }
        return false
    }

    /// The synthetic "Recently added" `SourcePlaylist` (nil when there are no adds) — a read-only
    /// virtual collection that inherits the full source-playlist action set (Play / Shuffle /
    /// Duplicate-as-editable / Convert-to-pocket / Rip-Burn) for free via `IndexPlaylistDetailView`.
    /// NOT a persisted Playlist (so adding to it can't recursively log add-events) — it mirrors the
    /// reserved Now Playing setlist's "synthetic, read-derived" pattern.
    func recentlyAddedPlaylist(limit: Int) -> SourcePlaylist? {
        let ids = recentlyAddedSongIds(limit: limit)
        guard !ids.isEmpty else { return nil }
        return SourcePlaylist(playlist: IndexPlaylist(id: Self.recentlyAddedPlaylistId,
                                                      name: Self.recentlyAddedName, songIds: ids),
                              sourceName: Self.recentlyAddedName)
    }

    /// If the user saved a metadata edit DURING an off-main catalog build, that build's `derived`
    /// captured a STALE edit snapshot — re-overlay the current edits so a mid-load save isn't visually
    /// clobbered (the edit itself is already persisted in `EditsStore`). Common case: no change → no-op.
    private func reconcileEditsAfterBuild(albumEdits: [String: AlbumEdit], songEdits: [String: SongEdit]) {
        if (edits?.doc.albums ?? [:]) != albumEdits || (edits?.doc.songs ?? [:]) != songEdits {
            applyEdits()
        }
    }

    /// Conditionally refresh from the network. A 304/offline/failed refresh is NON-DESTRUCTIVE:
    /// CatalogService returns each source's disk cache on failure, so a previously-loaded source
    /// is never dropped, and we only surface `.failed` when there was nothing to show.
    private func performRefresh(hadData: Bool) async {
        do {
            let (indexes, anyChanged) = try await fetchIndexes()
            // Consume the seed hand-off: whatever happens below, these must not outlive this
            // refresh (they are ~109k rows).
            let seedSignature = seededProvisionalSignature
            let seedSupersede = seededSupersede
            seededIndexes = [:]
            seededProvisionalSignature = nil
            seededSupersede = nil
            let albumEdits = edits?.doc.albums ?? [:]
            let songEdits = edits?.doc.songs ?? [:]
            let provisional = discoverAdds?.entries ?? []
            let provisionalAlbums = discoverAdds?.albums ?? []
            let importedS = importedSongs?.songs ?? []
            let importedA = importedSongs?.albums ?? []
            let profileSongs = profileSource?.songs ?? []
            let profileName = profileSource?.sourceName ?? ProfileSourceStore.defaultName
            let amLibSongs = appleMusicLibrary?.songs ?? []
            let amLibAlbums = appleMusicLibrary?.albums ?? []
            let amLibPlaylists = appleMusicLibrary?.playlists ?? []
            // OWNER-GATED supersede (integrity audit). Only the catalog owner's on-device MusicKit
            // library and their server-generated "Apple Music (Local)" index are the same person's
            // library, so only the owner dedups the two. `OwnerIdentity.isOwner()` is cached after
            // the first success and FAILS CLOSED (no iCloud / offline / not-allowlisted ⇒ false ⇒
            // no supersede), so a hybrid/public user NEVER loses their own library to the curator's
            // shared "Apple Music (Local)" rows. Awaited here (off the launch critical path) — not
            // in `seedFromCache` — so the CloudKit round-trip never blocks the first frame.
            // Tri-state on purpose (see `OwnerIdentity.resolveIsOwner`). A `nil` means CloudKit
            // could not be reached — holding the last KNOWN answer through that is what stops an
            // offline launch from un-deduping a catalog the previous launch deduped. Only a real
            // resolution is remembered, so a non-owner can never acquire a `true`.
            let resolvedOwner = await ownerResolver()
            let amLibSupersedes = resolvedOwner ?? lastKnownIsOwner
            if let resolvedOwner { lastKnownIsOwner = resolvedOwner }
            resolvedIsOwner = amLibSupersedes    // cache for synchronous owner-gated read paths
            // SKIP THE SECOND BUILD. On the normal launch the seed has already merged, overlaid
            // and derived exactly this catalog from exactly these bytes — rebuilding it costs a
            // ~1.6-2.3 s detached pass and produces an equal value. It is only skippable when
            // every input matches what the seed used:
            //   • no source body changed (304 / offline fallback everywhere), AND
            //   • the seed's provisional sources (adds / imports / profile / AM library / edits)
            //     are unchanged, AND
            //   • the owner answer the seed ASSUMED matches the one just resolved. Comparing the
            //     two (rather than requiring `false`) is what lets the OWNER skip too: their seed
            //     now assumes `true` from the remembered answer, so it already built the
            //     superseded merge. A disagreement in EITHER direction still forces the rebuild.
            if hadData, !anyChanged, seedSupersede == amLibSupersedes,
               let seedSignature, seedSignature == provisionalSignature() {
                state = .loaded
                return
            }
            // Merge + edit-overlay + sort + browse-row build for the whole (~90k-row) catalog runs
            // OFF the main actor; only the finished value is assigned back on `@MainActor`.
            let built = await Task.detached(priority: .userInitiated) { () -> (Derived, [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)], [(from: String, to: String)]) in
                let (all, discoverPairs, importedPairs, discoverAlbumPairs, amLibPairs) = AppModel.withProvisionalSources(
                    discover: provisional, discoverAlbums: provisionalAlbums,
                    importedSongs: importedS, importedAlbums: importedA,
                    profileSongs: profileSongs, profileName: profileName,
                    amLibrarySongs: amLibSongs, amLibraryAlbums: amLibAlbums,
                    amLibraryPlaylists: amLibPlaylists, amLibrarySupersedes: amLibSupersedes, indexes: indexes)
                return (AppModel.buildDerived(indexes: all, albumEdits: albumEdits, songEdits: songEdits),
                        discoverPairs, importedPairs, discoverAlbumPairs, amLibPairs)
            }.value
            assign(built.0)
            applySupersede(discover: built.1, imported: built.2,
                           discoverAlbums: built.3, amLibrary: built.4)
            reconcileEditsAfterBuild(albumEdits: albumEdits, songEdits: songEdits)
            state = .loaded
        } catch {
            // Refresh failed (e.g. true first launch + offline). Keep whatever is already on
            // screen; only blank to an error when we have nothing seeded/loaded.
            if !hadData && albums.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    /// The fully-derived catalog produced OFF the main actor by `buildDerived`: the merged raw
    /// index + per-source tags + playlists, plus the effective (edit-overlaid, sorted, indexed)
    /// catalog and its pre-built browse rows + search keys. `assign` hands it to `@MainActor`
    /// state in one cheap, atomic step (never a half-applied catalog).
    struct Derived {
        let manifest: Manifest?
        let indexPlaylists: [SourcePlaylist]
        let albumSourceById: [String: String]
        let songSourceById: [String: String]
        let availableSources: [String]
        let rawAlbums: [IndexAlbum]
        let rawSongs: [IndexSong]
        let rawAlbumsById: [String: IndexAlbum]
        let rawSongsById: [String: IndexSong]
        let artistsByKey: [String: IndexArtist]
        let effective: Effective
    }

    /// The edit-overlaid, sorted, indexed catalog + its pre-built browse rows and search keys.
    /// Shared by the launch build (`buildDerived`, off-main) and the edit-save rebuild
    /// (`applyEdits`, on-main) so both produce identical effective state.
    struct Effective {
        let albums: [IndexAlbum]
        let songs: [IndexSong]
        let songsById: [String: IndexSong]
        let albumsById: [String: IndexAlbum]
        let albumBrowseItems: [BrowseItem]
        let songBrowseItems: [BrowseItem]
        let albumSearchKeys: [String]
        let songSearchKeys: [String]
        let artistBrowseItems: [BrowseItem]
        let artistSearchKeys: [String]
    }

    /// Merge source indexes → tag by source → overlay edits → sort → index → build browse rows.
    /// Pure + `nonisolated` so the whole heavy pipeline runs on a background executor; the
    /// `@MainActor` model only assigns the result (see `assign`).
    nonisolated static func buildDerived(indexes: [IndexJSON],
                                         albumEdits: [String: AlbumEdit],
                                         songEdits: [String: SongEdit]) -> Derived {
        let index = merge(indexes)
        let sources = sourceTags(indexes)
        let rawAlbums = index.albums
        let rawSongs = index.songs
        let effective = buildEffective(rawAlbums: rawAlbums, rawSongs: rawSongs,
                                       albumSourceById: sources.albums, songSourceById: sources.songs,
                                       albumEdits: albumEdits, songEdits: songEdits)
        return Derived(
            manifest: index.manifest,
            indexPlaylists: sourcePlaylists(indexes),
            albumSourceById: sources.albums,
            songSourceById: sources.songs,
            availableSources: sources.names,
            rawAlbums: rawAlbums,
            rawSongs: rawSongs,
            rawAlbumsById: Dictionary(rawAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            rawSongsById: Dictionary(rawSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            artistsByKey: Dictionary((index.artists ?? []).map { ($0.key, $0) },
                                     uniquingKeysWith: { first, _ in first }),
            effective: effective)
    }

    /// Overlay edits onto the raw catalog, sort albums, index by id, and pre-build the browse rows
    /// + per-item search keys. Pure + `nonisolated` (the album sort over ~90k rows uses
    /// `localizedCaseInsensitiveCompare`, which was a main-actor cost — moved off it here).
    nonisolated static func buildEffective(rawAlbums: [IndexAlbum], rawSongs: [IndexSong],
                                           albumSourceById: [String: String],
                                           songSourceById: [String: String],
                                           albumEdits: [String: AlbumEdit],
                                           songEdits: [String: SongEdit]) -> Effective {
        let albums = rawAlbums.map { $0.applying(albumEdits[$0.id]) }.sorted {
            let a = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return a == .orderedSame
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : a == .orderedAscending
        }
        let songs = rawSongs.map { $0.applying(songEdits[$0.id]) }
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumsById = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let albumItems = albums.map { BrowseItem.album($0, source: albumSourceById[$0.id]) }
        let albumKeys = albums.map { searchKey($0.name, $0.artist, $0.genre ?? "") }
        let songItems = songs.map { song -> BrowseItem in
            let album = song.albumId.flatMap { albumsById[$0] }
            return .song(song, albumName: album?.name ?? "",
                         source: songSourceById[song.id],
                         genre: Genre.category(album?.genre))
        }
        let songKeys = songs.map { song -> String in
            let albumName = song.albumId.flatMap { albumsById[$0]?.name } ?? ""
            return searchKey(song.name, song.artist, albumName)
        }
        // Artist groupings (the Artists browse kind): one row per distinct album-artist, in the
        // catalog's existing artist/name order. `albums` is already sorted by artist then name, so a
        // single pass groups consecutive same-artist albums (dictionary-free, order-preserving).
        var artistItems: [BrowseItem] = []
        var artistKeys: [String] = []
        var i = 0
        while i < albums.count {
            let artist = albums[i].artist
            var j = i, songCount = 0
            // Group case-INSENSITIVELY to match the case-insensitive sort above — otherwise a
            // merged catalog whose sources disagree on casing ("OutKast" vs "Outkast") would sort
            // the albums adjacent but split them into multiple artist rows (with a duplicate
            // `artist:<name>` id). The FIRST album's casing becomes the row's display name.
            while j < albums.count, albums[j].artist.localizedCaseInsensitiveCompare(artist) == .orderedSame {
                songCount += albums[j].trackList.count
                j += 1
            }
            artistItems.append(.artist(name: artist, albumCount: j - i, songCount: songCount,
                                       artworkAlbumId: albums[i].id))
            artistKeys.append(searchKey(artist))
            i = j
        }
        return Effective(albums: albums, songs: songs, songsById: songsById, albumsById: albumsById,
                         albumBrowseItems: albumItems, songBrowseItems: songItems,
                         albumSearchKeys: albumKeys, songSearchKeys: songKeys,
                         artistBrowseItems: artistItems, artistSearchKeys: artistKeys)
    }

    /// One case- AND diacritic-insensitive haystack from an item's searchable fields, matched with a
    /// plain `contains` against a same-folded query. `folding(…, locale: nil)` is DETERMINISTIC across
    /// locales (unlike the old `localizedCaseInsensitiveContains`, which also missed "İ" U+0130 whose
    /// `lowercased()` gains a combining dot) and ~an order of magnitude cheaper than per-field
    /// locale-aware search; diacritic-insensitivity ("café" ≈ "cafe") is a win for accented artist/
    /// album names. The `\n` separators keep a match within one field — a query never spans two joined
    /// values, mirroring the old per-field OR.
    nonisolated static func searchKey(_ fields: String...) -> String {
        fields.joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Fired after every full catalog assign (cache seed + network refresh) — the one
    /// choke point where a fresh `indexPlaylists` goes live. Wired at app init to the
    /// collections' converted-pocket source sync (gated there by the Settings toggle).
    var onCatalogAssigned: (() -> Void)?

    /// Assign a fully-derived catalog to `@MainActor` state in one atomic step.
    private func assign(_ d: Derived) {
        manifest = d.manifest
        indexPlaylists = d.indexPlaylists
        artistsByKey = d.artistsByKey
        // Remember them for the next cold launch. `record` ignores an empty set, so a build that
        // legitimately produced no source playlists never erases the last good snapshot.
        sourcePlaylistsCache.record(d.indexPlaylists)
        albumSourceById = d.albumSourceById
        songSourceById = d.songSourceById
        availableSources = d.availableSources
        rawAlbums = d.rawAlbums
        rawSongs = d.rawSongs
        rawAlbumsById = d.rawAlbumsById
        rawSongsById = d.rawSongsById
        assign(effective: d.effective)
        onCatalogAssigned?()
    }

    /// Assign the effective (edit-overlaid) catalog + browse rows, bump the revision, and clear the
    /// results memo. Shared by the launch assign and the on-main `applyEdits` rebuild.
    private func assign(effective e: Effective) {
        albums = e.albums
        songs = e.songs
        songsById = e.songsById
        albumsById = e.albumsById
        albumBrowseItems = e.albumBrowseItems
        songBrowseItems = e.songBrowseItems
        albumSearchKeys = e.albumSearchKeys
        songSearchKeys = e.songSearchKeys
        artistBrowseItems = e.artistBrowseItems
        artistSearchKeys = e.artistSearchKeys
        catalogRevision &+= 1
        browseResultsCache.removeAll(keepingCapacity: true)
        browseResultsOrder.removeAll(keepingCapacity: true)
    }

    /// Rebuild the effective catalog by overlaying local edits onto the raw index. Called after an
    /// edit is saved (the launch path builds this OFF the main actor via `buildDerived`). Edit saves
    /// are user-initiated and infrequent, so this stays synchronous.
    func applyEdits() {
        assign(effective: Self.buildEffective(
            rawAlbums: rawAlbums, rawSongs: rawSongs,
            albumSourceById: albumSourceById, songSourceById: songSourceById,
            albumEdits: edits?.doc.albums ?? [:], songEdits: edits?.doc.songs ?? [:]))
    }

    /// The pre-built, unfiltered browse rows for a kind (album name / source / genre
    /// already resolved). O(1) — the array is built once in `buildEffective`.
    func browseItems(_ kind: ItemKind) -> [BrowseItem] {
        switch kind {
        case .album:  return albumBrowseItems
        case .song:   return songBrowseItems
        case .artist: return artistBrowseItems
        }
    }

    /// The pre-built folded search keys parallel to `browseItems(kind)` (same order/count).
    func searchKeys(_ kind: ItemKind) -> [String] {
        switch kind {
        case .album:  return albumSearchKeys
        case .song:   return songSearchKeys
        case .artist: return artistSearchKeys
        }
    }

    /// Build the Browse rows (+ parallel folded search keys) for an ORDERED list of song ids — a
    /// collection's members — so a collection detail view can run the Browse sort/filter pipeline
    /// (`BrowseState.filterSort`) on its own subset. Same construction as `songBrowseItems`.
    /// Unresolved ids (studio/absent songs) are dropped.
    func browseItems(forSongIds ids: [String]) -> (items: [BrowseItem], keys: [String]) {
        var items: [BrowseItem] = []; var keys: [String] = []
        items.reserveCapacity(ids.count); keys.reserveCapacity(ids.count)
        for id in ids {
            guard let song = songsById[id] else { continue }
            let album = song.albumId.flatMap { albumsById[$0] }
            items.append(.song(song, albumName: album?.name ?? "",
                               source: songSourceById[id], genre: Genre.category(album?.genre)))
            keys.append(Self.searchKey(song.name, song.artist, album?.name ?? ""))
        }
        return (items, keys)
    }

    /// A collection's songs (by ordered ids) after applying a `BrowseState`'s sort + filters — the
    /// display list for a collection detail view with sort/filter enabled. At default state (no
    /// clauses, no sort keys, no query, no active read-time filter) it returns the ids' songs in
    /// their STORED order, so the collection's own order is preserved until the user sorts.
    func sortedFilteredSongs(ids: [String], browse: BrowseState,
                             collections: CollectionsStore?, favorites: FavoritesStore?) -> [IndexSong] {
        let (items, keys) = browseItems(forSongIds: ids)
        let filtered = BrowseState.filterSort(base: items, searchKeys: keys, query: browse.query,
                                              clauses: browse.clauses, sortKeys: browse.sortKeys,
                                              playCounts: browse.playCounts)
        let visible = browse.applyReadTimeFilters(to: filtered, collections: collections, favorites: favorites)
        return visible.compactMap { if case .song(let s, _, _, _, _) = $0 { return s } else { return nil } }
    }

    /// Return the memoized browse results for `key`, computing + caching on a miss. The
    /// caller (BrowseState) owns the derivation; this only decides whether to reuse it.
    func cachedBrowseResults(_ key: String, compute: () -> [BrowseItem]) -> [BrowseItem] {
        if let hit = browseResultsCache[key] { return hit }
        let value = compute()
        storeBrowseResults(key, value)
        return value
    }

    /// Memo peek (no compute) — the OFF-main browse pipeline computes on a detached task, then
    /// stores the finished set here (see `BrowseState.refreshResults`).
    func peekBrowseResults(_ key: String) -> [BrowseItem]? { browseResultsCache[key] }

    /// Store a browse result set into the bounded LRU memo (idempotent — a concurrent refresh that
    /// already filled this key wins; recompute of the same key is deterministic anyway).
    func storeBrowseResults(_ key: String, _ value: [BrowseItem]) {
        if browseResultsCache[key] != nil { return }
        browseResultsCache[key] = value
        browseResultsOrder.append(key)
        if browseResultsOrder.count > Self.browseResultsCacheCap {
            let evict = browseResultsOrder.removeFirst()
            browseResultsCache.removeValue(forKey: evict)
        }
    }

    func rawAlbum(_ id: String) -> IndexAlbum? { rawAlbumsById[id] }
    func rawSong(_ id: String) -> IndexSong? { rawSongsById[id] }

    /// Manual refresh (Settings "Reload catalog" / Browse "Retry"). Keeps the current catalog on
    /// screen and refreshes in place — never resets to `.idle`/`.loading`, so it can't blank the
    /// catalog. On a cold model with nothing loaded yet it seeds from cache first.
    func reload() async {
        // Share loadIfNeeded's single-flight gate: reload also awaits an off-main build, so a manual
        // reload racing the launch load (or another reload) would otherwise double-build the catalog.
        if loadInFlight { return }
        loadInFlight = true
        defer { loadInFlight = false }
        let hadData = !albums.isEmpty
        if !hadData { _ = await seedFromCache() }
        await performRefresh(hadData: hadData || !albums.isEmpty)
    }

    /// Per-source tagging derived alongside the merge: id→source maps + the
    /// distinct source names (first-seen order).
    typealias SourceTags = (albums: [String: String], songs: [String: String], names: [String])

    /// Returns the merged source indexes plus whether ANY of them actually changed. A refresh in
    /// which nothing changed can reuse the seed's work wholesale — see `performRefresh`.
    private func fetchIndexes() async throws -> (indexes: [IndexJSON], anyChanged: Bool) {
        if let loader { return ([try await loader.loadIndex()], true) }
        let urls = settings?.enabledSourceURLs ?? [Config.indexURL]
        var indexes: [IndexJSON] = []
        var anyChanged = false
        var firstError: Error?
        for url in urls {
            do {
                // CatalogService does a CONDITIONAL GET and falls back to ITS OWN per-URL disk
                // cache when offline/unchanged — so a previously-loaded source never throws here.
                // Handing it the seed's decoded value means a 304 costs a round trip, not a
                // ~640 ms re-decode of the same bytes.
                let loaded = try await CatalogService(url: url)
                    .load(reusing: seededIndexes[url.absoluteString])
                indexes.append(loaded.index)
                if loaded.changed { anyChanged = true }
            } catch {
                // OFFLINE GRACEFUL DEGRADATION: a source with no cache (never loaded online) +
                // no network is SKIPPED so the OTHER sources' cached catalogs still open. We
                // fail the whole load only when EVERY source failed (indexes empty) — one
                // un-cached source must not hide an already-cached one.
                firstError = firstError ?? error
            }
        }
        // ZERO CONFIGURED SOURCES is a legitimate public-user configuration (their own on-device
        // "Apple Music" library + Discover adds + imports are injection sources that merge in
        // withProvisionalSources) — return [] so the build proceeds on injections alone. Throwing
        // is reserved for "sources configured but EVERY one failed", which must not blank an
        // already-working catalog. (The public-user audit's confirmed-critical fix.)
        guard !indexes.isEmpty else {
            if urls.isEmpty { return ([], false) }
            throw firstError ?? URLError(.cannotLoadFromNetwork)
        }
        // A source that FAILED (and so contributed nothing) must not read as "unchanged" —
        // the set of indexes differs from the seed's, so the rebuild has to run.
        if indexes.count != urls.count { anyChanged = true }
        return (indexes, anyChanged)
    }

    /// Tag each album/song id with the name of the FIRST source that carries it —
    /// same dedup order as `merge` — so the merged catalog keeps its provenance.
    /// Pure + nonisolated so it's unit-testable without the network.
    nonisolated static func sourceTags(_ indexes: [IndexJSON]) -> SourceTags {
        var albums: [String: String] = [:]
        var songs: [String: String] = [:]
        var names: [String] = []
        var seenNames = Set<String>()
        for index in indexes {
            let name = index.manifest.sourceName ?? "Collection"
            if seenNames.insert(name).inserted { names.append(name) }
            for a in index.albums where albums[a.id] == nil { albums[a.id] = name }
            for s in index.songs where songs[s.id] == nil { songs[s.id] = name }
        }
        return (albums, songs, names)
    }

    /// Merge multiple source indexes into one (first occurrence of each id wins).
    /// Pure + synchronous (nonisolated) so it's unit-testable without the network.
    nonisolated static func merge(_ indexes: [IndexJSON]) -> IndexJSON {
        var albums: [IndexAlbum] = []
        var songs: [IndexSong] = []
        var playlists: [IndexPlaylist] = []
        var artists: [IndexArtist] = []
        var seenAlbums = Set<String>(), seenSongs = Set<String>(), seenPlaylists = Set<String>()
        var seenArtists = Set<String>()
        for index in indexes {
            for a in index.albums where seenAlbums.insert(a.id).inserted { albums.append(a) }
            for s in index.songs where seenSongs.insert(s.id).inserted { songs.append(s) }
            for p in index.playlists ?? [] where seenPlaylists.insert(p.id).inserted { playlists.append(p) }
            // First source wins, matching album/song shadowing: the same artist can appear in
            // several sources and they all mean the same Apple Music entity.
            for a in index.artists ?? [] where seenArtists.insert(a.key).inserted { artists.append(a) }
        }
        let manifest = indexes.first?.manifest
            ?? Manifest(source: nil, generatedAt: nil, sourceName: "Collection", counts: nil)
        return IndexJSON(manifest: manifest, albums: albums, songs: songs,
                         playlists: playlists.isEmpty ? nil : playlists,
                         artists: artists.isEmpty ? nil : artists)
    }

    /// Flatten each source's playlists into source-tagged rows (for the badge),
    /// deduped by playlist id across sources (first occurrence wins).
    nonisolated static func sourcePlaylists(_ indexes: [IndexJSON]) -> [SourcePlaylist] {
        var out: [SourcePlaylist] = []
        var seen = Set<String>()
        for index in indexes {
            let name = index.manifest.sourceName ?? "Collection"
            for p in index.playlists ?? [] where seen.insert(p.id).inserted {
                out.append(SourcePlaylist(playlist: p, sourceName: name))
            }
        }
        return out
    }

    /// Resolve an album's ordered tracklist to song records.
    func tracks(for album: IndexAlbum) -> [IndexSong] {
        album.trackList.compactMap { songsById[$0] }
    }

    func albumName(forSong song: IndexSong) -> String {
        song.albumId.flatMap { albumsById[$0]?.name } ?? ""
    }

    /// Origin source name for an album/song id (nil if untagged/unknown).
    func source(ofAlbum id: String) -> String? { albumSourceById[id] }
    func source(ofSong id: String) -> String? { songSourceById[id] }

    // MARK: - Apple Music identity (favorites two-way sync)

    /// Reverse index (Apple Music catalog id → song id), built lazily on first ask and
    /// invalidated by `catalogRevision`. @ObservationIgnored because filling it is a pure
    /// cache fill — observing it would invalidate whatever asked, for no state change.
    @ObservationIgnored private var appleMusicIdIndex: [String: String] = [:]
    @ObservationIgnored private var appleMusicIdIndexRevision = -1

    /// Every catalog song that HAS an Apple Music identity, as (songId, appleMusicId).
    /// This is the id space `FavoritesSyncService`'s inbound pull asks Apple Music about —
    /// vinyl / My Digital / Studio songs carry no catalog id and are excluded by
    /// construction, so they can never be dragged into an Apple Music round-trip.
    func appleMusicCatalogPairs() -> [(songId: String, appleMusicId: String)] {
        songs.compactMap { s in s.appleMusicId.map { (songId: s.id, appleMusicId: $0) } }
    }

    /// Resolve an Apple Music catalog id back to this catalog's song id (the inbound
    /// direction — Apple Music speaks catalog ids, the app speaks PocketDJ song ids).
    /// FIRST-seen wins, matching `merge`'s dedup order, so a song present in two sources
    /// resolves to the same id the rest of the app uses.
    func songId(forAppleMusicId appleMusicId: String) -> String? {
        if appleMusicIdIndexRevision != catalogRevision {
            appleMusicIdIndex = Dictionary(songs.compactMap { s in s.appleMusicId.map { ($0, s.id) } },
                                           uniquingKeysWith: { first, _ in first })
            appleMusicIdIndexRevision = catalogRevision
        }
        return appleMusicIdIndex[appleMusicId]
    }

    /// The ALBUM twin of `songId(forAppleMusicId:)` — same revision-keyed memo, same
    /// first-seen-wins rule. The album PREVIEW asks this before it renders: an album the user
    /// already owns must offer "Open album" (pushing the real `IndexAlbum`), not a ＋ that
    /// would add it twice. It is O(1) after the first call per catalog revision, which is why
    /// the preview can ask from a `body` — unlike `AppleMusicRecognition.indexAlbum(matching:)`,
    /// an O(catalog) normalized scan that must stay inside a `.task`.
    @ObservationIgnored private var appleMusicAlbumIdIndex: [String: String] = [:]
    @ObservationIgnored private var appleMusicAlbumIdIndexRevision = -1

    func albumId(forAppleMusicId appleMusicId: String) -> String? {
        if appleMusicAlbumIdIndexRevision != catalogRevision {
            appleMusicAlbumIdIndex = Dictionary(albums.compactMap { a in a.appleMusicId.map { ($0, a.id) } },
                                                uniquingKeysWith: { first, _ in first })
            appleMusicAlbumIdIndexRevision = catalogRevision
        }
        return appleMusicAlbumIdIndex[appleMusicId]
    }
}
