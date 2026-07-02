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
        collections.playlists.filter { $0.id != nowPlayingPlaylistId }.map(PlaylistEntity.init)
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
        collections.pockets.map(PocketEntity.init)
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

// MARK: - Auto-mix source (a pocket OR a set list, one speakable parameter)

/// Auto-mix's source is `MixSource` (pocket | setlist). Siri phrases can carry only ONE
/// parameter, so both kinds are folded into a single entity whose id reuses
/// `MixSource.id`'s exact encoding ("pocket:<id>" / "setlist:<id>").
struct AutoMixSourceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mix Source")
    static let defaultQuery = AutoMixSourceQuery()

    let id: String
    let name: String
    let kindLabel: String   // "Pocket" / "Set list"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(kindLabel)",
                              image: .init(systemName: "slider.horizontal.3"))
    }

    /// Decode the id back into the Mix tab's source value; nil for a corrupt/stale id.
    var mixSource: MixSource? { Self.mixSource(from: id) }
    static func mixSource(from id: String) -> MixSource? {
        if id.hasPrefix("pocket:") { return .pocket(String(id.dropFirst("pocket:".count))) }
        if id.hasPrefix("setlist:") { return .setlist(String(id.dropFirst("setlist:".count))) }
        return nil
    }

    init(pocket: Pocket) {
        self.id = MixSource.pocket(pocket.id).id
        self.name = pocket.name
        self.kindLabel = "Pocket"
    }
    init(setlist: Setlist) {
        self.id = MixSource.setlist(setlist.id).id
        self.name = setlist.name ?? "Set list"
        self.kindLabel = "Set list"
    }

    /// Pockets first (the primary auto-mix source), then setlist history — the same
    /// two groups the Mix tab's collection picker offers. Now Playing filtered.
    @MainActor static func all(in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        let pockets = collections.pockets.map(AutoMixSourceEntity.init(pocket:))
        let setlists = collections.setlists
            .filter { $0.id != nowPlayingSetlistId }
            .map(AutoMixSourceEntity.init(setlist:))
        return pockets + setlists
    }
    @MainActor static func matching(_ string: String, in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        all(in: collections).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor static func resolve(ids: [String], in collections: CollectionsStore) -> [AutoMixSourceEntity] {
        ids.compactMap { id in
            switch mixSource(from: id) {
            case .pocket(let pid):  return collections.pocket(pid).map(AutoMixSourceEntity.init(pocket:))
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
