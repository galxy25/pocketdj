import Foundation

/// Maps a remote row onto something THIS device can play — the rights boundary of a Remote
/// session. Rows carry only ids + title/artist (+ the Apple Music store id); each device plays
/// from its own library or its own Apple Music subscription. Order:
///   1. the row's songId is in this device's catalog            → that song
///   2. the row's Apple Music id is a catalog song here          → that song
///   3. the row has an Apple Music id and Apple Music is usable → `am:<id>` (the user's own AM)
///   4. normalized title + artist match in the catalog           → that song (JukeboxMatching)
///   5. otherwise                                                → unavailable on this device
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
    /// Normalized title + artist → a catalog item.
    var matchTitleArtist: (String, String) -> SetlistPlayer.Item? = { _, _ in nil }
    /// Can this device stream Apple Music at all (the opt-in build flag + a linked account)?
    var appleMusicAvailable: () -> Bool = { false }
    /// The Apple Music store id the local catalog knows for a songId (stamped onto OUTBOUND rows).
    var appleMusicIdForSong: (String) -> String? = { _ in nil }
    /// Tried after everything else misses (the showcase's catalog-less fake speaker). nil in
    /// production — a miss there is genuinely unavailable.
    var lastResort: ((RemoteRow) -> SetlistPlayer.Item?)? = nil

    func resolve(_ row: RemoteRow) -> Resolution {
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
                if let id = index.byTitleArtist()[RemoteCatalogIndex.key(title, artist)],
                   let s = app.songsById[id] { return item(s) }
                return index.fuzzyExact(title: title, artist: artist).map(item)
            },
            appleMusicAvailable: { AppleMusicCredentials.isEnabled },
            appleMusicIdForSong: { id in app.songsById[id]?.appleMusicId })
    }
}

/// Lazily-built lookup tables over the catalog for `RemoteSongResolver.live` (rebuilt when the
/// catalog revision moves). Misses for the containment matcher are memoized too.
@MainActor
final class RemoteCatalogIndex {
    private let app: AppModel
    private var builtAt: Int = -1
    private var amIndex: [String: String] = [:]
    private var taIndex: [String: String] = [:]
    private var fuzzyMemo: [String: String?] = [:]

    init(app: AppModel) { self.app = app }

    static func key(_ title: String, _ artist: String) -> String {
        ShazamCatalogMatch.norm(title) + "\u{1F}" + ShazamCatalogMatch.norm(artist)
    }

    private func rebuildIfNeeded() {
        let rev = app.catalogRevision
        guard rev != builtAt else { return }
        builtAt = rev
        amIndex.removeAll(); taIndex.removeAll(); fuzzyMemo.removeAll()
        for s in app.songs {
            if let am = s.appleMusicId, !am.isEmpty, amIndex[am] == nil { amIndex[am] = s.id }
            let k = Self.key(s.name, s.artist)
            if taIndex[k] == nil { taIndex[k] = s.id }
        }
    }

    func byAppleMusicId() -> [String: String] { rebuildIfNeeded(); return amIndex }
    func byTitleArtist() -> [String: String] { rebuildIfNeeded(); return taIndex }

    func fuzzyExact(title: String, artist: String) -> IndexSong? {
        rebuildIfNeeded()
        let k = Self.key(title, artist)
        if let memo = fuzzyMemo[k] { return memo.flatMap { app.songsById[$0] } }
        let hit = JukeboxMatching.exact(title: title, artist: artist, in: app.songs)
        fuzzyMemo[k] = .some(hit?.id)
        return hit
    }
}
