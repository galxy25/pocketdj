import Foundation

/// Maps a remote row onto something THIS device can play — the rights boundary of a Remote
/// session. Rows carry only ids + title/artist (+ the Apple Music store id); each device plays
/// from its own library or its own Apple Music subscription. Order:
///   1. the row's songId is in this device's catalog            → that song
///   2. the row's Apple Music id is a catalog song here          → that song
///   3. the row has an Apple Music id and Apple Music is usable → `am:<id>` (the user's own AM)
///   4. normalized title + artist EXACT key in the catalog       → that song (O(1) lookup)
///   5. the containment-tolerant fuzzy matcher (JukeboxMatching) → that song — EXPENSIVE (a scan
///      of the catalog per miss), so callers ask for it only for the rows about to play
///   6. otherwise                                                → unavailable on this device
/// The closures are the seams (tests feed dictionaries; production wires the live catalog).
@MainActor
struct RemoteSongResolver {
    enum Resolution: Equatable {
        case catalog(SetlistPlayer.Item)
        case appleMusic(SetlistPlayer.Item)
        case matched(SetlistPlayer.Item)
        case unavailable

        var item: SetlistPlayer.Item? {
            switch self {
            case .catalog(let i), .appleMusic(let i), .matched(let i): return i
            case .unavailable: return nil
            }
        }
    }

    /// songId → a playable item from this device's catalog.
    var catalogItem: (String) -> SetlistPlayer.Item?
    /// Apple Music store id → a catalog item carrying that id.
    var catalogItemForAppleMusicId: (String) -> SetlistPlayer.Item? = { _ in nil }
    /// Normalized title + artist → a catalog item (an O(1) exact-key lookup).
    var matchTitleArtist: (String, String) -> SetlistPlayer.Item? = { _, _ in nil }
    /// The containment-tolerant matcher — a catalog scan per call. nil ⇒ none (tests).
    var fuzzyTitleArtist: ((String, String) -> SetlistPlayer.Item?)? = nil
    /// Can this device stream Apple Music at all (the opt-in build flag + a linked account)?
    var appleMusicAvailable: () -> Bool = { false }
    /// The Apple Music store id the local catalog knows for a songId (stamped onto OUTBOUND rows).
    var appleMusicIdForSong: (String) -> String? = { _ in nil }
    /// Tried after everything else misses (the showcase's catalog-less fake speaker). nil in
    /// production — a miss there is genuinely unavailable.
    var lastResort: ((RemoteRow) -> SetlistPlayer.Item?)? = nil
    /// A session is starting: warm whatever the lookups need (production: build the catalog
    /// index OFF the main actor now, so the first resolve doesn't have to).
    var prepare: () -> Void = {}

    /// Every path, the fuzzy matcher included.
    func resolve(_ row: RemoteRow) -> Resolution {
        resolve(row, allowFuzzy: true) ?? .unavailable
    }

    /// `allowFuzzy: false` stops before the expensive fuzzy matcher: a row the cheap paths miss
    /// returns nil (UNDECIDED — neither playable nor reported unavailable yet).
    func resolve(_ row: RemoteRow, allowFuzzy: Bool) -> Resolution? {
        let r = row.row
        let variant = r.variant.flatMap(SongVariant.init(rawValue:))
        func stamped(_ base: SetlistPlayer.Item) -> SetlistPlayer.Item {
            var it = SetlistPlayer.Item(id: base.id, title: base.title, artist: base.artist,
                                        lengthMs: base.lengthMs ?? r.lengthMs, repeatCount: r.repeatCount)
            if base.id == r.songId { it.variant = variant; it.editionLocked = r.editionLocked ?? false }
            return it
        }
        if let hit = catalogItem(r.songId) { return .catalog(stamped(hit)) }
        // A row that is ALREADY an Apple-Music-only id (`am:<storeID>`, e.g. a jukebox request).
        let amId = r.appleMusicId ?? Self.storeId(fromNamespaced: r.songId)
        if let amId, !amId.isEmpty {
            if let hit = catalogItemForAppleMusicId(amId) { return .catalog(stamped(hit)) }
            if appleMusicAvailable() {
                return .appleMusic(SetlistPlayer.Item(id: AppleMusicCatalog.namespacedSongID(amId),
                                                      title: r.title, artist: r.artist, lengthMs: r.lengthMs))
            }
        }
        if let hit = matchTitleArtist(r.title, r.artist) { return .matched(stamped(hit)) }
        if let fuzzy = fuzzyTitleArtist {
            guard allowFuzzy else { return nil }
            if let hit = fuzzy(r.title, r.artist) { return .matched(stamped(hit)) }
        }
        if let hit = lastResort?(row) { return .matched(hit) }
        return .unavailable
    }

    /// `am:<storeID>` → storeID (nil for any other id shape, incl. `am:album:…`).
    static func storeId(fromNamespaced id: String) -> String? {
        let prefix = AppleMusicCatalog.idPrefix + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return rest.isEmpty || rest.contains(":") ? nil : rest
    }
}

extension RemoteSongResolver {
    /// The production resolver over the live catalog. The title/artist and Apple-Music-id
    /// indexes are built lazily ONCE per catalog revision (a 100k-song scan per miss on the main
    /// actor would stall the speaker); the exact-key index uses the canonical
    /// `ShazamCatalogMatch.norm`, and the containment-tolerant `JukeboxMatching.exact` covers the
    /// rest of a miss.
    static func live(app: AppModel) -> RemoteSongResolver {
        let index = RemoteCatalogIndex(app: app)
        func item(_ s: IndexSong) -> SetlistPlayer.Item {
            SetlistPlayer.Item(id: s.id, title: s.name, artist: s.artist, lengthMs: s.length)
        }
        return RemoteSongResolver(
            catalogItem: { id in app.songsById[id].map(item) },
            catalogItemForAppleMusicId: { am in index.byAppleMusicId()[am].flatMap { app.songsById[$0] }.map(item) },
            matchTitleArtist: { title, artist in
                index.byTitleArtist()[RemoteCatalogIndex.key(title, artist)]
                    .flatMap { app.songsById[$0] }.map(item)
            },
            fuzzyTitleArtist: { title, artist in index.fuzzyExact(title: title, artist: artist).map(item) },
            appleMusicAvailable: { AppleMusicCredentials.isEnabled },
            appleMusicIdForSong: { id in app.songsById[id]?.appleMusicId },
            prepare: { index.prepare() })
    }
}

/// Lookup tables over the catalog for `RemoteSongResolver.live`. Built OFF the main actor
/// (`Task.detached` over a value snapshot of the song list) and swapped in when done — a
/// catalog-revision bump (a sync, a rip landing) never stalls a speaker with a full scan; the
/// previous tables keep answering meanwhile. Only a lookup that finds NO tables at all (the
/// session's very first resolve beat `prepare`'s background build) builds synchronously, once.
/// Misses for the containment matcher are memoized per tables.
@MainActor
final class RemoteCatalogIndex {
    struct Tables: Sendable {
        var byAppleMusicId: [String: String] = [:]
        var byTitleArtist: [String: String] = [:]
    }

    private let songs: () -> [IndexSong]
    private let revision: () -> Int
    private let songById: (String) -> IndexSong?
    private var tables: Tables?
    /// The catalog revision `tables` were built from.
    private var builtAt: Int = -1
    /// The revision a background build is running for.
    private var buildingFor: Int?
    private var buildTask: Task<Void, Never>?
    private var fuzzyMemo: [String: String?] = [:]
    /// Test seam: synchronous (main-actor) builds so far.
    private(set) var syncBuilds = 0

    convenience init(app: AppModel) {
        self.init(songs: { [weak app] in app?.songs ?? [] },
                  revision: { [weak app] in app?.catalogRevision ?? 0 },
                  songById: { [weak app] in app?.songsById[$0] })
    }

    init(songs: @escaping () -> [IndexSong], revision: @escaping () -> Int,
         songById: @escaping (String) -> IndexSong?) {
        self.songs = songs
        self.revision = revision
        self.songById = songById
    }

    nonisolated static func key(_ title: String, _ artist: String) -> String {
        ShazamCatalogMatch.norm(title) + "\u{1F}" + ShazamCatalogMatch.norm(artist)
    }

    /// The pure table build (runs detached).
    nonisolated static func build(_ songs: [IndexSong]) -> Tables {
        var t = Tables()
        for s in songs {
            if let am = s.appleMusicId, !am.isEmpty, t.byAppleMusicId[am] == nil { t.byAppleMusicId[am] = s.id }
            let k = key(s.name, s.artist)
            if t.byTitleArtist[k] == nil { t.byTitleArtist[k] = s.id }
        }
        return t
    }

    /// Start a background build if the catalog moved since the tables were built.
    func prepare() { refresh(allowSync: false) }

    /// Wait for a background build in flight (tests).
    func awaitBuild() async { await buildTask?.value }

    private func refresh(allowSync: Bool) {
        let rev = revision()
        guard rev != builtAt else { return }
        if tables == nil, allowSync {
            // Nothing to answer with yet: build once, here.
            syncBuilds += 1
            install(Self.build(songs()), rev)
            return
        }
        guard buildingFor != rev else { return }
        buildingFor = rev
        let snapshot = songs()                       // a value copy — the detached build reads only it
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .utility) { RemoteCatalogIndex.build(snapshot) }.value
            guard let self, !Task.isCancelled, self.buildingFor == rev else { return }
            self.install(built, rev)
        }
    }

    private func install(_ t: Tables, _ rev: Int) {
        tables = t
        builtAt = rev
        if buildingFor == rev || (buildingFor ?? .min) < rev { buildingFor = nil }
        fuzzyMemo.removeAll()
    }

    func byAppleMusicId() -> [String: String] { refresh(allowSync: true); return tables?.byAppleMusicId ?? [:] }
    func byTitleArtist() -> [String: String] { refresh(allowSync: true); return tables?.byTitleArtist ?? [:] }

    func fuzzyExact(title: String, artist: String) -> IndexSong? {
        refresh(allowSync: true)
        let k = Self.key(title, artist)
        if let memo = fuzzyMemo[k] { return memo.flatMap { songById($0) } }
        let hit = JukeboxMatching.exact(title: title, artist: artist, in: songs())
        fuzzyMemo[k] = .some(hit?.id)
        return hit
    }
}
