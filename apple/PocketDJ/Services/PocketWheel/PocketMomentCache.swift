import Foundation
import Observation

/// The app-scoped, memoised Pocket Wheel (§1.6 "Cost"): rebuilt OFF the main actor when play
/// history changes (debounced 5 s), persisted as a device-local cache
/// (`pocketdj-pocket-wheel-cache.json`) so the wheel paints instantly at launch, and folded into
/// the synced palette after every build. Views read `snapshot` only — nothing is derived in a body.
@MainActor
@Observable
final class PocketMomentCache {

    private(set) var snapshot: PocketWheelSnapshot
    private(set) var isBuilding = false
    /// Bumped whenever `snapshot` changes (view recompute key).
    private(set) var revision = 0

    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored let palette: PocketPaletteStore
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var debounceSeconds: Double = 5

    // Seams (closures, so tests need no app graph). All default to empty.
    @ObservationIgnored var catalogSnapshot: () -> (songs: [String: IndexSong], albums: [String: IndexAlbum]) = { ([:], [:]) }
    @ObservationIgnored var collectionsInput: () -> ListeningPocketsCollections.Input = { .init() }
    @ObservationIgnored var favoriteIds: () -> Set<String> = { [] }
    @ObservationIgnored var setlistToPlaylist: () -> [String: String] = { [:] }
    @ObservationIgnored var timbreVectors: () async -> [String: SimilarityFamilies.TimbreVector] = { [:] }
    @ObservationIgnored var cloudPatterns: () -> [PocketMomentEngine.CloudPatternRef] = { [] }
    /// Ids of collections that no longer exist (frees their palette slots at once).
    @ObservationIgnored var liveCollectionIds: () -> Set<String>? = { nil }

    @ObservationIgnored private var pending: Task<Void, Never>?
    /// `PDJ_SEED_POCKET_WHEEL`: the seeded wheel must not be rebuilt away from under a screenshot.
    @ObservationIgnored private(set) var pinnedForDemo = false
    /// The APP's automatic rebuilds (history revision / catalog landing). Off in the unit-test
    /// host, whose own tests drive their own caches — the host must stay inert.
    @ObservationIgnored var autoRebuild = true
    @ObservationIgnored private var builtRevision = -1

    init(history: PlayHistoryStore, palette: PocketPaletteStore,
         fileURL: URL = PocketMomentCache.defaultURL()) {
        self.history = history
        self.palette = palette
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let snap = try? JSONDecoder().decode(PocketWheelSnapshot.self, from: data) {
            // Paint instantly from the cache, but ALWAYS rebuild once this launch: the history
            // revision is a per-process counter, so a stored revision proves nothing now.
            snapshot = snap
        } else {
            snapshot = PocketWheelSnapshot()
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-pocket-wheel-cache.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-pocket-wheel-cache.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// History changed (or the app foregrounded): rebuild after the debounce, unless the cache
    /// already reflects this history revision.
    func historyDidChange() {
        guard autoRebuild, !pinnedForDemo, history.revision != builtRevision else { return }
        pending?.cancel()
        let wait = debounceSeconds
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.rebuildNow()
        }
    }

    /// Build now (off-main), adopt, fold into the palette, persist.
    func rebuildNow() async {
        pending?.cancel(); pending = nil
        isBuilding = true
        defer { isBuilding = false }
        let rev = history.revision
        let events = history.events
        let cat = catalogSnapshot()
        let colls = collectionsInput()
        let favs = favoriteIds()
        let setlists = setlistToPlaylist()
        let patterns = cloudPatterns()
        let nowMs = now().timeIntervalSince1970 * 1000
        let vectors = await timbreVectors()
        let snap = await Task.detached(priority: .utility) {
            let input = PocketMomentCache.makeInput(events: events, songs: cat.songs, albums: cat.albums,
                                                    collections: colls, favorites: favs,
                                                    setlistToPlaylist: setlists, timbre: vectors,
                                                    cloudPatterns: patterns, nowMs: nowMs, revision: rev)
            return PocketMomentEngine.build(input)
        }.value
        adopt(snap)
    }

    /// Adopt a built snapshot (also the seed/test seam).
    func adopt(_ snap: PocketWheelSnapshot) {
        let live = liveCollectionIds()
        let deleted = live.map { l in Set(palette.entries.keys.filter { !l.contains($0) && $0 != PocketWheelIds.favorites }) } ?? []
        palette.assign(dominantOrder: snap.dominanceOrder, deleted: deleted, nowMs: snap.builtAtMs)
        builtRevision = snap.historyRevision
        guard snap != snapshot else { return }
        snapshot = snap
        revision &+= 1
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Screenshot / XCUITest seam: paint the deterministic demo scenario through the real engine.
    func seedDemoIfRequested() {
        guard PocketWheelDemo.isRequested else { return }
        let date = now()
        adopt(PocketMomentEngine.build(PocketWheelDemo.input(nowMs: date.timeIntervalSince1970 * 1000,
                                                             tzOffsetMin: TimeZone.current.secondsFromGMT(for: date) / 60)))
        pinnedForDemo = true
    }

    func clearLocal() {
        pending?.cancel(); pending = nil
        snapshot = PocketWheelSnapshot()
        builtRevision = -1
        revision &+= 1
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Off-main: catalog + collections + history → the engine's input. Only songs in the history
    /// are converted (the catalog is ~100k rows; the wheel needs the played slice).
    nonisolated static func makeInput(events: [PlayHistoryStore.PlayEvent], songs: [String: IndexSong],
                                      albums: [String: IndexAlbum], collections: ListeningPocketsCollections.Input,
                                      favorites: Set<String>, setlistToPlaylist: [String: String],
                                      timbre: [String: SimilarityFamilies.TimbreVector],
                                      cloudPatterns: [PocketMomentEngine.CloudPatternRef],
                                      nowMs: Double, revision: Int) -> PocketMomentEngine.Input {
        let flat = CollectionFlattener.flatten(collections.source)
        let adds = CollectionFlattener.addTimes(collections: flat, activity: collections.activity,
                                                pockets: collections.source.pockets,
                                                albumTracks: collections.source.albumTracks)
        var infos = flat.map {
            PocketMomentEngine.CollectionInfo(id: $0.id, name: $0.name, songIds: Set($0.songIds), addedAtMs: adds[$0.id] ?? [:])
        }
        if !favorites.isEmpty {
            infos.append(.init(id: PocketWheelIds.favorites, name: PocketWheelIds.favoritesName, songIds: favorites))
        }
        var genreByAlbum: [String: String?] = [:]
        var info: [String: PocketMomentEngine.SongInfo] = [:]
        for e in events {
            let id = SongVariant.baseId(e.songId)
            guard info[id] == nil, let s = songs[id] else { continue }
            var genre: String?
            if let aid = s.albumId {
                if let g = genreByAlbum[aid] { genre = g } else {
                    let cat = Genre.category(albums[aid]?.genre)
                    genre = cat == Genre.other ? nil : cat.lowercased()
                    genreByAlbum[aid] = genre
                }
            }
            info[id] = .init(artist: s.artist, genre: genre, bpm: s.bpm, year: s.year, timbre: timbre[id])
        }
        return PocketMomentEngine.Input(events: events, collections: infos, songs: info,
                                        setlistToPlaylist: setlistToPlaylist,
                                        extraNames: [PocketWheelIds.favorites: PocketWheelIds.favoritesName],
                                        librarySize: songs.count, nowMs: nowMs, historyRevision: revision,
                                        cloudPatterns: cloudPatterns)
    }
}
