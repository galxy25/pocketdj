import Foundation
import AppIntents

// The AppEntity wrappers Siri/Shortcuts/Spotlight see for the user's collections.
// Lightweight value snapshots (id + display fields) mirroring the store models —
// resolution back to live data always goes through the entity queries, which read
// the registered `IntentServices`' CollectionsStore. Ids are the store's own stable
// prefixed-UUID strings (`pls_…`, `pkt_…`, `set_…`), so a shortcut a user saved
// keeps resolving across launches. The reserved Now Playing scratch setlist (and its
// synthetic parent playlist) is filtered from every query.

// MARK: - Playlist

struct PlaylistEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "PocketDJ playlist",
                              image: .init(systemName: "music.note.list"))
    }

    init(_ playlist: Playlist) {
        self.id = playlist.id
        self.name = playlist.name
    }

    /// All speakable playlists (feeds Siri's phrase vocabulary + Shortcuts pickers).
    @MainActor static func all(in collections: CollectionsStore) -> [PlaylistEntity] {
        collections.playlistsAZ.filter { $0.id != nowPlayingPlaylistId }.map(PlaylistEntity.init)
    }
    @MainActor static func matching(_ string: String, in collections: CollectionsStore) -> [PlaylistEntity] {
        all(in: collections).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {
    @Dependency private var services: IntentServices

    @MainActor func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        identifiers.compactMap { services.collections.playlist($0).map(PlaylistEntity.init) }
    }
    @MainActor func suggestedEntities() async throws -> [PlaylistEntity] {
        PlaylistEntity.all(in: services.collections)
    }
    @MainActor func entities(matching string: String) async throws -> [PlaylistEntity] {
        PlaylistEntity.matching(string, in: services.collections)
    }
}

// MARK: - Pocket

struct PocketEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pocket")
    static let defaultQuery = PocketEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "PocketDJ pocket",
                              image: .init(systemName: "square.stack.3d.up"))
    }

    init(_ pocket: Pocket) {
        self.id = pocket.id
        self.name = pocket.name
    }

    @MainActor static func all(in collections: CollectionsStore) -> [PocketEntity] {
        collections.pocketsAZ.map(PocketEntity.init)
    }
    @MainActor static func matching(_ string: String, in collections: CollectionsStore) -> [PocketEntity] {
        all(in: collections).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct PocketEntityQuery: EntityQuery, EntityStringQuery {
    @Dependency private var services: IntentServices

    @MainActor func entities(for identifiers: [String]) async throws -> [PocketEntity] {
        identifiers.compactMap { services.collections.pocket($0).map(PocketEntity.init) }
    }
    @MainActor func suggestedEntities() async throws -> [PocketEntity] {
        PocketEntity.all(in: services.collections)
    }
    @MainActor func entities(matching string: String) async throws -> [PocketEntity] {
        PocketEntity.matching(string, in: services.collections)
    }
}

// MARK: - Auto-mix source (a pocket, a playlist, OR a set list, one speakable parameter)

/// Auto-mix's source is `MixSource` (pocket | playlist | setlist). Siri phrases can carry only
/// ONE parameter, so all three kinds are folded into a single entity whose id reuses
/// `MixSource.id`'s exact encoding ("pocket:<id>" / "playlist:<id>" / "setlist:<id>").
struct AutoMixSourceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mix Source")
    static let defaultQuery = AutoMixSourceQuery()

    let id: String
    let name: String
    let kindLabel: String   // "Pocket" / "Playlist" / "Set list"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(kindLabel)",
                              image: .init(systemName: "slider.horizontal.3"))
    }

    /// Decode the id back into the Mix tab's source value; nil for a corrupt/stale id.
    var mixSource: MixSource? { Self.mixSource(from: id) }
    static func mixSource(from id: String) -> MixSource? {
        if id.hasPrefix("pocket:") { return .pocket(String(id.dropFirst("pocket:".count))) }
        if id.hasPrefix("playlist:") { return .playlist(String(id.dropFirst("playlist:".count))) }
        if id.hasPrefix("setlist:") { return .setlist(String(id.dropFirst("setlist:".count))) }
        return nil
    }

    init(pocket: Pocket) {
        self.id = MixSource.pocket(pocket.id).id
        self.name = pocket.name
        self.kindLabel = "Pocket"
    }
    init(playlist: Playlist) {
        self.id = MixSource.playlist(playlist.id).id
        self.name = playlist.name
        self.kindLabel = "Playlist"
    }
    init(setlist: Setlist) {
        self.id = MixSource.setlist(setlist.id).id
        self.name = setlist.name ?? "Set list"
        self.kindLabel = "Set list"
    }

    /// Pockets first (the primary auto-mix source), then playlists, then setlist history —
    /// the same groups the Mix tab's collection picker offers. Now Playing filtered.
    @MainActor static func all(in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        let pockets = collections.pocketsAZ.map(AutoMixSourceEntity.init(pocket:))
        let playlists = collections.playlistsAZ.map(AutoMixSourceEntity.init(playlist:))
        let setlists = collections.setlists
            .filter { $0.id != nowPlayingSetlistId }
            .sorted { CollectionsStore.azLess($0.name ?? "Set list", $1.name ?? "Set list") }
            .map(AutoMixSourceEntity.init(setlist:))
        return pockets + playlists + setlists
    }
    @MainActor static func matching(_ string: String, in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        all(in: collections).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor static func resolve(ids: [String], in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        ids.compactMap { id in
            switch mixSource(from: id) {
            case .pocket(let pid):  return collections.pocket(pid).map(AutoMixSourceEntity.init(pocket:))
            case .playlist(let plid): return collections.playlist(plid).map(AutoMixSourceEntity.init(playlist:))
            case .setlist(let sid):
                guard sid != nowPlayingSetlistId else { return nil }
                return collections.setlist(sid).map(AutoMixSourceEntity.init(setlist:))
            case nil: return nil
            }
        }
    }
}

struct AutoMixSourceQuery: EntityQuery, EntityStringQuery {
    @Dependency private var services: IntentServices

    @MainActor func entities(for identifiers: [String]) async throws -> [AutoMixSourceEntity] {
        AutoMixSourceEntity.resolve(ids: identifiers, in: services.collections)
    }
    @MainActor func suggestedEntities() async throws -> [AutoMixSourceEntity] {
        AutoMixSourceEntity.all(in: services.collections)
    }
    @MainActor func entities(matching string: String) async throws -> [AutoMixSourceEntity] {
        AutoMixSourceEntity.matching(string, in: services.collections)
    }
}
