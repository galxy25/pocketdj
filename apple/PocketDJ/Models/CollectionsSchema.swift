import Foundation

// MARK: - Collections schema — pockets, playlists (versioned, portable)
//
// User collections (the "perform from the crate" feature), ported from the PWA's
// `src/types/collections.ts`. Like the edits schema, this is versioned and
// all-optional-where-possible so it round-trips across devices and app versions:
//   • `CollectionsDocument.schemaVersion` is bumped on any shape change and
//     `CollectionsMigration.migrate` upgrades older documents (auto-migrate).
//   • Lenient decode: missing version ⇒ v0 (migrated); missing lists ⇒ empty;
//     unknown keys ignored (a newer app's document loads degraded on an older one).
//   • Additive-only: never remove/repurpose a field; add an optional one + a migration.
//
// Vocabulary (locked with Levi, mirrors the PWA):
//   Pocket   — a named, REUSABLE, nestable (DAG, cycle-guarded) grouping of
//              harmonically-similar items (songs/albums). `performance` kind reserved.
//   Playlist — a TEMPLATE: ordered Sequences (chapters) of Nodes
//              (song | album | pocket | text | sub-sequence). sequences[0] is default.
//   Setlist  — a frozen instance from Play→realize: realize() expands albums →
//              tracks, samples over-budget pockets, and autofills temporal gaps with
//              harmonic bridges, then FREEZES the concrete ordered tracks (each
//              snapshotted so it reads standalone). One playlist → many setlists.
// v1 → v2: pockets gained an ordered `notes: [PocketNote]` list (free-text items,
// orderable AMONG the members — the "poetry pocket"). Additive + lenient: a v1 doc
// migrates forward (each pocket gets `notes: []`); a v2 doc loads degraded on a v1
// app (the unknown `notes` key is simply ignored, members intact).
let collectionsSchemaVersion = 2

enum PocketKind: String, Codable, Hashable, Sendable { case harmonic, performance }

/// A free-text item inside a pocket — a mic cue, a line of poetry, an out-of-index
/// moment. `position` is its slot in the pocket's UNIFIED member ordering (child
/// pockets, then albums, then songs, then notes are laid out in a single list and a
/// note's `position` is its index in that combined list — so a note can sit *between*
/// songs). Lenient/all-optional-where-possible for graceful round-tripping.
struct PocketNote: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var text: String
    var position: Int = 0

    init(id: String, text: String, position: Int = 0) {
        self.id = id; self.text = text; self.position = position
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? CollectionsFactory.newPocketNoteId()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
    }
}

/// A reusable, nestable grouping. Membership is type-agnostic (songs + albums +
/// child pockets + free-text notes), forming a cycle-guarded DAG.
struct Pocket: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: PocketKind = .harmonic
    var description: String?
    var songIds: [String] = []
    var albumIds: [String] = []
    var childPocketIds: [String] = []
    var notes: [PocketNote] = []         // v2: ordered free-text items (poetry/cues)
    var createdAt: Double = 0
    var updatedAt: Double = 0

    // Notes never count toward "members" (songs/albums/pockets) for count/runtime.
    var isEmpty: Bool { songIds.isEmpty && albumIds.isEmpty && childPocketIds.isEmpty && notes.isEmpty }
    var memberCount: Int { songIds.count + albumIds.count + childPocketIds.count }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, description, songIds, albumIds, childPocketIds, notes, createdAt, updatedAt
    }
    init(id: String, name: String, kind: PocketKind = .harmonic, description: String? = nil,
         songIds: [String] = [], albumIds: [String] = [], childPocketIds: [String] = [],
         notes: [PocketNote] = [], createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.description = description
        self.songIds = songIds; self.albumIds = albumIds; self.childPocketIds = childPocketIds
        self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? CollectionsFactory.newPocketId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decode(PocketKind.self, forKey: .kind)) ?? .harmonic
        description = try? c.decode(String.self, forKey: .description)
        songIds = (try? c.decode([String].self, forKey: .songIds)) ?? []
        albumIds = (try? c.decode([String].self, forKey: .albumIds)) ?? []
        childPocketIds = (try? c.decode([String].self, forKey: .childPocketIds)) ?? []
        notes = (try? c.decode([PocketNote].self, forKey: .notes)) ?? []
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// A node in a playlist template. A flat, `kind`-discriminated, recursive shape
/// (matches the PWA JSON): song/album/pocket/text leaves + `sequence` chapters.
struct PlaylistNode: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case song, album, pocket, text, sequence }
    var nodeId: String
    var kind: Kind
    // leaf refs (exactly one set, per kind)
    var songId: String?
    var albumId: String?
    var pocketId: String?
    var text: String?
    // sequence (chapter) fields
    var name: String?
    var targetMs: Int?           // realize budget for this chapter (reserved)
    var children: [PlaylistNode]?
    // shared
    var note: String?            // performer cue

    var id: String { nodeId }
}

/// A playlist template: ordered chapters (every entry is a `.sequence` node).
struct Playlist: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var sequences: [PlaylistNode]      // each .kind == .sequence; sequences[0] is default
    var targetMs: Int?
    var createdAt: Double = 0
    var updatedAt: Double = 0
}

// MARK: - Setlist instance — the frozen performance produced by ▶ Play

/// How a track ended up in the setlist.
enum TrackSource: String, Codable, Hashable, Sendable { case explicit, pocket, autofill }

/// DEFERRED (reserved seam): a ranked "mix it with" candidate for a setlist track —
/// pocket co-members first (curated harmonic similarity), falling back to raw bpm+key
/// compatibility. Computed by a future mixSuggest engine; the field exists now so
/// lighting it up needs no migration. All-optional for lenient round-tripping.
struct MixSuggestion: Codable, Hashable, Sendable {
    var songId: String
    var artist: String
    var name: String
    var bpm: Double?
    var camelot: String?
    var lengthMs: Int?
    var basis: String?       // "pocket" | "bpm-key"
    var pocketId: String?
    var score: Double?
}

/// One frozen track in a setlist. SNAPSHOTTED (artist/name/bpm/camelot/length inline)
/// so the setlist reads standalone even if the catalog or pockets change later.
struct SetlistTrack: Codable, Hashable, Sendable, Identifiable {
    var songId: String
    // snapshot
    var artist: String
    var name: String
    var bpm: Double?
    var camelot: String?
    var lengthMs: Int?
    // provenance
    var source: TrackSource = .explicit
    var sequenceName: String?
    var note: String?
    var isText: Bool?        // true for a free-text cue with no backing item / audio
    var pocketId: String?    // set when source == .pocket
    var mixSuggestions: [MixSuggestion]?   // DEFERRED — per-track mix suggestions

    // Stable per-row id for SwiftUI (songId may repeat for cues / blanks).
    var id: String { "\(songId)#\(name)" }

    /// Duration a row contributes to totals — mirrors the engine's DEFAULT_TRACK_MS
    /// fallback so per-row display never disagrees with Setlist.totalMs.
    var shownMs: Int {
        if isText == true { return 0 }
        if let l = lengthMs, l > 0 { return l }
        return RealizeEngine.defaultTrackMs
    }

    enum CodingKeys: String, CodingKey {
        case songId, artist, name, bpm, camelot, lengthMs, source, sequenceName, note, isText, pocketId, mixSuggestions
    }
    init(songId: String, artist: String, name: String, bpm: Double?, camelot: String?,
         lengthMs: Int? = nil, source: TrackSource = .explicit, sequenceName: String? = nil,
         note: String? = nil, isText: Bool? = nil, pocketId: String? = nil,
         mixSuggestions: [MixSuggestion]? = nil) {
        self.songId = songId; self.artist = artist; self.name = name
        self.bpm = bpm; self.camelot = camelot; self.lengthMs = lengthMs
        self.source = source; self.sequenceName = sequenceName; self.note = note
        self.isText = isText; self.pocketId = pocketId; self.mixSuggestions = mixSuggestions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = (try? c.decode(String.self, forKey: .songId)) ?? ""
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        bpm = try? c.decode(Double.self, forKey: .bpm)
        camelot = try? c.decode(String.self, forKey: .camelot)
        lengthMs = try? c.decode(Int.self, forKey: .lengthMs)
        source = (try? c.decode(TrackSource.self, forKey: .source)) ?? .explicit
        sequenceName = try? c.decode(String.self, forKey: .sequenceName)
        note = try? c.decode(String.self, forKey: .note)
        isText = try? c.decode(Bool.self, forKey: .isText)
        pocketId = try? c.decode(String.self, forKey: .pocketId)
        mixSuggestions = try? c.decode([MixSuggestion].self, forKey: .mixSuggestions)
    }
}

/// A persisted performance instance produced by ▶ Play. One playlist → many setlists.
struct Setlist: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var playlistId: String         // parent template
    var name: String?              // auto/edited, e.g. "Family BBQ — take 3"
    var seed: String               // re-running realize with this reproduces the setlist
    var generatedAt: Double = 0
    var totalMs: Int = 0
    var tracks: [SetlistTrack] = []

    enum CodingKeys: String, CodingKey { case id, playlistId, name, seed, generatedAt, totalMs, tracks }
    init(id: String, playlistId: String, name: String? = nil, seed: String,
         generatedAt: Double = 0, totalMs: Int = 0, tracks: [SetlistTrack] = []) {
        self.id = id; self.playlistId = playlistId; self.name = name; self.seed = seed
        self.generatedAt = generatedAt; self.totalMs = totalMs; self.tracks = tracks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? CollectionsFactory.newSetlistId()
        playlistId = (try? c.decode(String.self, forKey: .playlistId)) ?? ""
        name = try? c.decode(String.self, forKey: .name)
        seed = (try? c.decode(String.self, forKey: .seed)) ?? playlistId
        generatedAt = (try? c.decode(Double.self, forKey: .generatedAt)) ?? 0
        totalMs = (try? c.decode(Int.self, forKey: .totalMs)) ?? 0
        tracks = (try? c.decode([SetlistTrack].self, forKey: .tracks)) ?? []
    }
}

// MARK: - Portable document (export/import + persistence)

/// A remembered "Add to…" target so the next add repeats the same collection (and,
/// for a playlist, the same chapter) with one tap.
struct AddTarget: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case pocket, playlist }
    var kind: Kind
    var id: String
    var sequenceId: String?     // playlists only: the chapter last added to
}

struct CollectionsDocument: Codable, Sendable {
    var schemaVersion: Int
    var pockets: [Pocket]
    var playlists: [Playlist]
    var setlists: [Setlist]           // frozen Play→realize instances (optional/back-compat)
    var lastAddTarget: AddTarget?     // "Add-to remembers last"

    init(schemaVersion: Int = collectionsSchemaVersion,
         pockets: [Pocket] = [], playlists: [Playlist] = [], setlists: [Setlist] = [],
         lastAddTarget: AddTarget? = nil) {
        self.schemaVersion = schemaVersion
        self.pockets = pockets
        self.playlists = playlists
        self.setlists = setlists
        self.lastAddTarget = lastAddTarget
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, pockets, playlists, setlists, lastAddTarget }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
        pockets = (try? c.decode([Pocket].self, forKey: .pockets)) ?? []
        playlists = (try? c.decode([Playlist].self, forKey: .playlists)) ?? []
        setlists = (try? c.decode([Setlist].self, forKey: .setlists)) ?? []
        lastAddTarget = try? c.decode(AddTarget.self, forKey: .lastAddTarget)
    }
}

enum CollectionsCodec {
    static func decode(_ data: Data) throws -> CollectionsDocument {
        let doc = try JSONDecoder().decode(CollectionsDocument.self, from: data)
        return doc.schemaVersion < collectionsSchemaVersion ? CollectionsMigration.migrate(doc) : doc
    }
    static func encode(_ doc: CollectionsDocument) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(doc)
    }
}

enum CollectionsMigration {
    static func migrate(_ document: CollectionsDocument) -> CollectionsDocument {
        var doc = document
        // v0 → v1: initial schema; no structural transform yet.
        // v1 → v2: pockets gained `notes: [PocketNote]`. Older pockets simply have
        //   none — lenient decode already defaults the field to [], so the mapping
        //   forward is the no-op identity. Kept explicit so the version bump is
        //   visible + the seam exists for any future note-shape transform.
        for i in doc.pockets.indices where doc.pockets[i].notes.isEmpty {
            doc.pockets[i].notes = []
        }
        doc.schemaVersion = collectionsSchemaVersion
        return doc
    }
}

// MARK: - Factories (mirror collections.ts)

enum CollectionsFactory {
    static func uid() -> String { UUID().uuidString.lowercased() }
    static func newPocketId() -> String { "pkt_" + uid() }
    static func newPlaylistId() -> String { "pls_" + uid() }
    static func newSetlistId() -> String { "set_" + uid() }
    static func newNodeId() -> String { "nd_" + uid() }
    static func newPocketNoteId() -> String { "pnt_" + uid() }

    static func makeSequence(_ name: String, targetMs: Int? = nil) -> PlaylistNode {
        PlaylistNode(nodeId: newNodeId(), kind: .sequence, name: name, targetMs: targetMs, children: [])
    }
    static func makePocket(_ name: String, kind: PocketKind = .harmonic, now: Double) -> Pocket {
        Pocket(id: newPocketId(), name: name, kind: kind, createdAt: now, updatedAt: now)
    }
    static func makePlaylist(_ name: String, now: Double) -> Playlist {
        Playlist(id: newPlaylistId(), name: name, sequences: [makeSequence("Default")],
                 createdAt: now, updatedAt: now)
    }
}
