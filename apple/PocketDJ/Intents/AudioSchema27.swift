// The iOS/macOS 27 "Siri AI" audio-domain layer: assistant-schema entities +
// intents so the NEW Siri understands natural conversation ("play some optimistic
// funk", "add this to my warmup playlist") with NO fixed phrases — the phrase-based
// App Shortcuts in PocketDJShortcuts keep covering every older OS.
//
// ── COMPILE GATE ─────────────────────────────────────────────────────────────
// Everything here needs the Xcode 27 beta SDK (the audio schema domain, the
// MediaIntents framework, @UnionValue on entities, IndexedEntityQuery). The file
// is `#if canImport(MediaIntents)` — MediaIntents is new in the 27 SDK, so with
// Xcode 26.x this whole file compiles OUT and the app builds exactly as before;
// building with Xcode 27 lights it up, and `@available(iOS 27, macOS 27, *)`
// keeps it runtime-safe on the iOS 18/macOS 15 deployment targets.
// Shapes are ported from Apple's WWDC26 sample "Integrating your music app with
// Apple Intelligence" (CosmoTunes) — the schema macros enforce these exact
// property sets at compile time.
//
// Adopted schemas: audio.song / album / artist / playlist entities,
// audio.playAudio + audio.addToPlaylist intents, audio.playbackAttributes +
// audio.queueInsertionLocation enums, the MediaIntents AudioSearch value query,
// and system.search (in-app search). Deliberately NOT adopted: addToLibrary and
// updateAudioAffinity (PocketDJ has no add-to-library or like/dislike model —
// the audio domain is not all-or-nothing, partial adoption is supported).

#if canImport(MediaIntents)

import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents

/// The named Spotlight index for SCHEMA entities — separate from the 26-era
/// `CollectionsSpotlight.indexName` (which wipe-rewrites playlists/pockets on
/// every collections change; sharing a name would let one layer erase the other).
@available(iOS 27.0, macOS 27.0, *)
let audioSchemaIndexName = "pocketdj-audio"

// MARK: - Entities

/// A catalog song. `duration` falls back to the engine's 3:30 unknown-length default.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.song)
struct AudioSongEntity: IndexedEntity {
    static let defaultQuery = AudioSongQuery()

    // Schema properties (shape enforced by the macro).
    var title: String
    var artistName: String
    var albumTitle: String?
    var composerName: String?
    var internationalStandardRecordingCode: String?
    var album: AudioAlbumEntity?
    var artists: [AudioArtistEntity]
    var composers: [AudioArtistEntity]
    var duration: TimeInterval

    let id: String   // IndexSong.id (stable, content-derived)

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)",
                              image: .init(systemName: "music.note"))
    }

    @MainActor
    init(song: IndexSong, app: AppModel, loadRelations: Bool = true) {
        id = song.id
        title = song.name
        artistName = song.artist
        artists = [AudioArtistEntity(name: song.artist)]
        composers = []
        composerName = nil
        internationalStandardRecordingCode = nil
        duration = TimeInterval(song.length ?? PocketFitter.fallbackLengthMs) / 1000
        let indexAlbum = song.albumId.flatMap { app.albumsById[$0] }
        albumTitle = indexAlbum?.name
        album = loadRelations
            ? indexAlbum.map { AudioAlbumEntity(album: $0, app: app, loadRelations: false) }
            : nil
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioSongEntity: Equatable, Hashable {
    static func == (lhs: AudioSongEntity, rhs: AudioSongEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioSongQuery {
    @Dependency var services: IntentServices
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioSongQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudioSongEntity] {
        await services.ensureReady()
        return identifiers.compactMap { id in
            services.app.songsById[id].map { AudioSongEntity(song: $0, app: services.app) }
        }
    }
    // No suggestedEntities: a ~100k-song catalog would flood the picker/vocabulary;
    // songs resolve via the string query and the AudioSearch value query instead.
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioSongQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [AudioSongEntity] {
        await services.ensureReady()
        return AudioSchemaSearch.songs(matching: string, app: services.app)
            .map { AudioSongEntity(song: $0, app: services.app) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioSongQuery: IndexedEntityQuery {
    /// Spotlight reindex-on-request. Songs are indexed ONLY on demand (the full
    /// catalog is ~100k rows — never bulk-indexed proactively).
    func reindexEntities(for identifiers: [String],
                         indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex(name: audioSchemaIndexName).indexAppEntities(entities)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        // Intentionally a no-op for the song set (size); albums/playlists cover
        // browse-scale discovery and songs stay resolvable via the queries above.
    }
}

/// A catalog album.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.album)
struct AudioAlbumEntity: IndexedEntity {
    static let defaultQuery = AudioAlbumQuery()

    var title: String
    var artistName: String
    var artists: [AudioArtistEntity]
    var songs: [AudioSongEntity]
    var universalProductCode: String?

    let id: String   // IndexAlbum.id

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)",
                              image: .init(systemName: "music.note.square.stack"))
    }

    @MainActor
    init(album: IndexAlbum, app: AppModel, loadRelations: Bool = true) {
        id = album.id
        title = album.name
        artistName = album.artist
        artists = [AudioArtistEntity(name: album.artist)]
        universalProductCode = nil
        songs = loadRelations
            ? album.trackList.compactMap { sid in
                app.songsById[sid].map { AudioSongEntity(song: $0, app: app, loadRelations: false) }
            }
            : []
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioAlbumEntity: Equatable, Hashable {
    static func == (lhs: AudioAlbumEntity, rhs: AudioAlbumEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioAlbumQuery {
    @Dependency var services: IntentServices
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioAlbumQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudioAlbumEntity] {
        await services.ensureReady()
        return identifiers.compactMap { id in
            services.app.albumsById[id].map { AudioAlbumEntity(album: $0, app: services.app) }
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioAlbumQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [AudioAlbumEntity] {
        await services.ensureReady()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return services.app.albums
            .filter { $0.name.localizedCaseInsensitiveContains(needle)
                   || $0.artist.localizedCaseInsensitiveContains(needle) }
            .prefix(AudioSchemaSearch.resultCap)
            .map { AudioAlbumEntity(album: $0, app: services.app, loadRelations: false) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioAlbumQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String],
                         indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex(name: audioSchemaIndexName).indexAppEntities(entities)
    }
    @MainActor
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await services.ensureReady()
        try await AudioSchemaIndexer.indexAlbums(services)
    }
}

/// An artist — identity IS the name (the catalog has no artist ids). Relations
/// stay empty; the song/album entities carry the artist name inline.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct AudioArtistEntity {
    static let defaultQuery = AudioArtistQuery()

    var name: String
    var albums: [AudioAlbumEntity]
    var songs: [AudioSongEntity]

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.microphone"))
    }

    init(name: String) {
        self.id = name
        self.name = name
        self.albums = []
        self.songs = []
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioArtistEntity: Equatable, Hashable {
    static func == (lhs: AudioArtistEntity, rhs: AudioArtistEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioArtistQuery {
    @Dependency var services: IntentServices
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioArtistQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AudioArtistEntity] {
        identifiers.map(AudioArtistEntity.init(name:))
    }
}

/// A playlist OR a pocket — both are speakable "playlists" to Siri; the id's
/// `pls_`/`pkt_` prefix routes resolution and playback to the right store call.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct AudioPlaylistEntity: IndexedEntity {
    static let defaultQuery = AudioPlaylistQuery()

    var title: String
    var owner: AudioPlaylistOwner?
    var trackCount: Int
    var totalDuration: TimeInterval
    var createdByMe: Bool?
    var curatedForMe: Bool?

    let id: String   // Playlist.id ("pls_…") or Pocket.id ("pkt_…")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "^[\(trackCount) song](inflect: true)",
            image: .init(systemName: id.hasPrefix("pkt_") ? "square.stack.3d.up" : "music.note.list"),
            synonyms: id.hasPrefix("pkt_") ? ["\(title) pocket"] : ["\(title) playlist"])
    }

    @MainActor
    init(playlist: Playlist, collections: CollectionsStore) {
        let stats = collections.catalog().stats(forPlaylist: playlist.id)
        id = playlist.id
        title = playlist.name
        trackCount = stats.count
        totalDuration = TimeInterval(stats.runtimeMs) / 1000
        owner = nil
        createdByMe = true
        curatedForMe = false
    }

    @MainActor
    init(pocket: Pocket, collections: CollectionsStore) {
        let stats = collections.catalog().stats(forPocket: pocket.id)
        id = pocket.id
        title = pocket.name
        trackCount = stats.count
        totalDuration = TimeInterval(stats.runtimeMs) / 1000
        owner = nil
        createdByMe = true
        curatedForMe = false
    }

    /// Resolve by id prefix; the reserved Now Playing ids never surface.
    @MainActor
    static func resolve(_ id: String, collections: CollectionsStore) -> AudioPlaylistEntity? {
        if id.hasPrefix("pkt_") {
            return collections.pocket(id).map { AudioPlaylistEntity(pocket: $0, collections: collections) }
        }
        guard id != nowPlayingPlaylistId else { return nil }
        return collections.playlist(id).map { AudioPlaylistEntity(playlist: $0, collections: collections) }
    }

    @MainActor
    static func all(in collections: CollectionsStore) -> [AudioPlaylistEntity] {
        collections.playlists.filter { $0.id != nowPlayingPlaylistId }
            .map { AudioPlaylistEntity(playlist: $0, collections: collections) }
        + collections.pockets.map { AudioPlaylistEntity(pocket: $0, collections: collections) }
    }
}

/// The playlist-owner union the schema requires; PocketDJ playlists are always
/// the user's own, so this is carried but never populated.
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum AudioPlaylistOwner {
    case curator(String)
    case person(IntentPerson)
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioPlaylistEntity: Equatable, Hashable {
    static func == (lhs: AudioPlaylistEntity, rhs: AudioPlaylistEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioPlaylistQuery {
    @Dependency var services: IntentServices
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioPlaylistQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudioPlaylistEntity] {
        identifiers.compactMap { AudioPlaylistEntity.resolve($0, collections: services.collections) }
    }
    @MainActor
    func suggestedEntities() async throws -> [AudioPlaylistEntity] {
        AudioPlaylistEntity.all(in: services.collections)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioPlaylistQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [AudioPlaylistEntity] {
        AudioPlaylistEntity.all(in: services.collections)
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioPlaylistQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String],
                         indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex(name: audioSchemaIndexName).indexAppEntities(entities)
    }
    @MainActor
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await AudioSchemaIndexer.indexPlaylists(services)
    }
}

// MARK: - Union + enums

/// One speakable parameter that is either a song or a playlist/pocket — the shape
/// `audio.playAudio` requires.
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum PocketDJAudioEntity {
    case song(AudioSongEntity)
    case playlist(AudioPlaylistEntity)

    var title: String {
        switch self {
        case .song(let song): return song.title
        case .playlist(let playlist): return playlist.title
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum AudioPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [AudioPlaybackAttributes: DisplayRepresentation] = [
        .shuffle: DisplayRepresentation(title: "Shuffle"),
        .repeat: DisplayRepresentation(title: "Repeat"),
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum AudioQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [AudioQueueInsertionLocation: DisplayRepresentation] = [
        .next: DisplayRepresentation(title: "Next"),
        .tail: DisplayRepresentation(title: "Last"),
    ]
}

/// The no-payload warmup marker the playAudio schema carries.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct AudioWarmupQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Warmup Audio Queue Result")
    }
    init() {}
}

// MARK: - Intents

/// Siri AI's natural-language play: "play Neon", "play my warmup pocket",
/// "play something upbeat" (via the AudioSearch value query below).
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audio"
    static let description = IntentDescription("Plays a song, playlist, or pocket from your PocketDJ sources.")

    var audioEntity: PocketDJAudioEntity
    @Parameter(default: [])
    var playbackAttributes: Set<AudioPlaybackAttributes>
    var queueLocation: AudioQueueInsertionLocation?
    var warmupAudioQueueResult: AudioWarmupQueueResult?

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult {
        // PocketDJ has no insert-into-queue — every request plays now (the reusable
        // Now Playing setlist replaces the queue), matching the in-app ▶ semantics.
        let shuffle = playbackAttributes.contains(.shuffle)
        switch audioEntity {
        case .song(let song):
            try await services.playSong(id: song.id)
        case .playlist(let playlist) where playlist.id.hasPrefix("pkt_"):
            try await services.playPocket(id: playlist.id, shuffle: shuffle)
        case .playlist(let playlist):
            try await services.playPlaylist(id: playlist.id, shuffle: shuffle)
        }
        return .result()
    }
}

/// "Add this to my warmup playlist" — appends a song to a playlist OR a pocket.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {
    static let title: LocalizedStringResource = "Add to Playlist"

    var audioEntity: PocketDJAudioEntity
    var playlist: AudioPlaylistEntity

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .song(let song) = audioEntity else {
            throw PocketDJIntentError.songOnlyAction
        }
        await services.ensureReady()
        guard services.app.songsById[song.id] != nil else {
            throw PocketDJIntentError.songNotFound
        }
        // Route through the SAME user-facing choke point the in-app "Add to…" uses
        // (`addSong(_:to:)`) so a Siri/Shortcuts add logs exactly one History▸Activity
        // event AND updates the Recent quick-add MRU — the low-level add(toPocket:)/
        // add(toPlaylist:) skipped both. There's no chapter/sequence here (Siri adds to
        // the collection, not a specific chapter), so a bare AddTarget is correct.
        if playlist.id.hasPrefix("pkt_") {
            guard services.collections.pocket(playlist.id) != nil else {
                throw PocketDJIntentError.pocketNotFound
            }
            services.collections.addSong(song.id, to: AddTarget(kind: .pocket, id: playlist.id))
        } else {
            guard services.collections.playlist(playlist.id) != nil else {
                throw PocketDJIntentError.playlistNotFound
            }
            services.collections.addSong(song.id, to: AddTarget(kind: .playlist, id: playlist.id))
        }
        return .result(dialog: "Added \(song.title) to \(playlist.title).")
    }
}

// MARK: - AudioSearch value query ("play something …")

@available(iOS 27.0, macOS 27.0, *)
extension PocketDJAudioEntity {
    struct AudioValueQuery {
        @Dependency var services: IntentServices
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PocketDJAudioEntity.AudioValueQuery: IntentValueQuery {
    @MainActor
    func values(for input: AudioSearch) async throws -> [PocketDJAudioEntity] {
        await services.ensureReady()
        switch input.criteria {
        case .searchQuery(let query):
            let songs = AudioSchemaSearch.songs(matching: query, app: services.app)
                .map { PocketDJAudioEntity.song(AudioSongEntity(song: $0, app: services.app)) }
            let playlists = AudioPlaylistEntity.all(in: services.collections)
                .filter { $0.title.localizedCaseInsensitiveContains(query) }
                .map(PocketDJAudioEntity.playlist)
            return playlists + songs
        case .unspecified:
            // "Play something": offer the user's own collections (Siri ranks/picks).
            return AudioPlaylistEntity.all(in: services.collections).map(PocketDJAudioEntity.playlist)
        default:
            return []
        }
    }
}

/// Tokenized catalog search shared by the song string query and the value query —
/// each whitespace token must hit title OR artist; ranked by hit count, capped.
@available(iOS 27.0, macOS 27.0, *)
enum AudioSchemaSearch {
    static let resultCap = 25

    @MainActor
    static func songs(matching query: String, app: AppModel) -> [IndexSong] {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(song: IndexSong, hits: Int, order: Int)] = []
        for (i, song) in app.songs.enumerated() {
            let haystack = "\(song.name) \(song.artist)".lowercased()
            let hits = tokens.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            if hits > 0 { scored.append((song, hits, i)) }
        }
        return scored
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
            .prefix(resultCap)
            .map(\.song)
    }
}

// MARK: - Proactive schema indexing

/// Bulk-indexes the SMALL schema sets (albums + playlists/pockets) into the
/// dedicated named index. Hooked into CollectionsSpotlight's debounced reindex by
/// `AudioSchemaBootstrap.install` — songs are never bulk-indexed (catalog scale);
/// they resolve through the string/value queries.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
enum AudioSchemaIndexer {
    static func reindexAll(_ services: IntentServices) async {
        await services.ensureReady()
        try? await CSSearchableIndex(name: audioSchemaIndexName).deleteAllSearchableItems()
        try? await indexPlaylists(services)
        try? await indexAlbums(services)
    }

    static func indexPlaylists(_ services: IntentServices) async throws {
        let entities = AudioPlaylistEntity.all(in: services.collections)
        guard !entities.isEmpty else { return }
        try await CSSearchableIndex(name: audioSchemaIndexName).indexAppEntities(entities)
    }

    static func indexAlbums(_ services: IntentServices) async throws {
        // Relation-free album entities in batches (the album set is ~13k — fine).
        let albums = services.app.albums
            .map { AudioAlbumEntity(album: $0, app: services.app, loadRelations: false) }
        for batch in stride(from: 0, to: albums.count, by: 1000)
            .map({ Array(albums[$0..<min($0 + 1000, albums.count)]) }) {
            try await CSSearchableIndex(name: audioSchemaIndexName).indexAppEntities(batch)
        }
    }
}

/// One-call activation, invoked from `PocketDJApp.init()` (inside the same compile
/// gate): chains the schema reindex onto the 26-era debounced collections hook.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
enum AudioSchemaBootstrap {
    static func install(services: IntentServices) {
        CollectionsSpotlight.schemaReindexHook = {
            await AudioSchemaIndexer.reindexAll(services)
        }
    }
}

#endif
