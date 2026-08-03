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
// v2 → v3: playlists gained an optional `folderId: String?` and the document gained a
//   flat `folders: [PlaylistFolder]` list (organize your playlists into named groups).
//   Additive + lenient: a v2 doc migrates forward (folders defaults to [], every
//   playlist's folderId stays nil ⇒ top level); a v3 doc loads degraded on a v2 app
//   (the unknown `folders`/`folderId` keys are ignored, playlists intact).
// v3 → v4: pockets gained an optional `folderId: String?` so pockets can live in the
//   same heterogeneous folder groups as playlists (folders hold BOTH). Additive + lenient:
//   a v3 doc migrates forward (every pocket's folderId stays nil ⇒ top level); a v4 doc
//   loads degraded on a v3 app (the unknown `folderId` key is simply ignored, pockets intact).
// v4 → v5: playlist decoding became LOSSY per element — the `[Playlist]` list, every
//   chapter array, and every nested `children` recursion decode through
//   `LossyDecodableArray`, so ONE undecodable / unknown-`kind` node drops THAT ELEMENT
//   ONLY, never a chapter, the list, or the document. Structural insurance shipped AHEAD
//   of any new node kind: previously a single unknown kind made the whole synthesized
//   `[Playlist]` decode throw, the document's lenient `try?` silently yielded
//   `playlists = []`, and the next save() DESTROYED every playlist. Studio items
//   (samples `smp_` / loops `lp_` / patterns `ptn_`) ride the EXISTING string arrays
//   (`Pocket.songIds` + `.song` nodes) as namespaced ids — deliberately NO new Kind case
//   — so a v4 app still decodes a v5 doc (studio rows just degrade at resolution time).
// v5 → v6: pockets AND playlists gained optional SOURCE PROVENANCE — `sourcePlaylistId` +
//   `sourceName` identify the catalog ("From your sources") playlist that Convert-to-pocket /
//   Duplicate-as-editable-playlist created the item from, `sourceSongIds` snapshots the
//   source membership at the last sync (the three-way-merge base, so the user's own edits
//   survive source add/remove), `sourceSyncEnabled` is the per-item opt-out (nil ⇒ enabled),
//   `sourceSyncedAt` stamps the last applied sync.
//   Additive + lenient: a v5 doc migrates forward (all nil ⇒ a hand-made item, never
//   synced); a v6 doc loads degraded on a v5 app (unknown keys ignored, members intact).
// v6 → v7: pockets AND playlists gained an optional `lastPlayedAt: Double?` (epoch ms) —
//   stamped by `CollectionsStore.markPlayed(...)` when the user hits ▶ Play on the
//   collection, powering the "Recently played" collection sort. Deliberately stamped
//   OUTSIDE `mutatePocket/mutatePlaylist`, so it never disturbs `updatedAt` (the "Last
//   updated" signal). Additive + lenient: a v6 doc migrates forward (lastPlayedAt nil ⇒
//   never played ⇒ sorts last under Recently-played); a v7 doc loads degraded on a v6 app
//   (the unknown key is simply ignored, members intact).
let collectionsSchemaVersion = 7

enum PocketKind: String, Codable, Hashable, Sendable { case harmonic, performance }

// MARK: - Reserved "Now Playing" identifiers (the reusable, hidden setlist)
//
// ▶ Play / 🔀 Shuffle on a playlist/pocket build a SINGLE, REUSABLE setlist under these
// reserved ids (last-writer-wins). It is never surfaced in any setlist list/history —
// `setlists(forPlaylist:)` filters out `nowPlayingPlaylistId`. Cleared on launch so a
// stale last-session "Now Playing" set never shows.
let nowPlayingSetlistId = "set_now_playing"
let nowPlayingPlaylistId = "pls_now_playing"

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
/// Per-collection Apple Music sync DIRECTION (Levi 2026-07-29: "potential and comfort zone …
/// are actually smart playlists so I don't want those to ever sync from PocketDJ to Apple Music
/// but only from Apple Music to PocketDJ"). Smart playlists are invisible to the write API, so a
/// push mints a regular-playlist duplicate — `pull` is the setting that prevents exactly that.
/// Stored as an OPTIONAL raw string on the collection (nil ⇒ `.both`, the pre-feature behavior;
/// additive, so older documents decode unchanged — the mix-deck-loop schema lesson).
enum CollectionSyncDirection: String, Codable, CaseIterable, Sendable {
    case both, push, pull, off
    /// May this collection be PUSHED to Apple Music (WS2 create/top-up/reconcile + the instant
    /// write-back + the Send backfill)?
    var allowsPush: Bool { self == .both || self == .push }
    /// May this collection be PULLED from Apple Music (the converted-collections source-follow)?
    var allowsPull: Bool { self == .both || self == .pull }
    var label: String {
        switch self {
        case .both: return "Two-way"
        case .push: return "Send only"
        case .pull: return "Get only"
        case .off:  return "Off"
        }
    }
}

struct Pocket: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: PocketKind = .harmonic
    var description: String?
    var songIds: [String] = []
    var albumIds: [String] = []
    var childPocketIds: [String] = []
    var notes: [PocketNote] = []         // v2: ordered free-text items (poetry/cues)
    var folderId: String?                // v4: optional ⇒ back-compat (nil = top level)
    /// Per-song loop count (a performance item's repeat count), keyed by songId. Pockets store
    /// members as a flat `[String]`, so the count rides a parallel sidecar map (the `notes`
    /// precedent) rather than a per-item object. Absent/≤1 ⇒ play once. Membership is set-like
    /// (`addSong` dedupes), so keying by songId is unambiguous.
    var songRepeats: [String: Int] = [:]
    // v6: SOURCE PROVENANCE — set only by Convert-from-source; all nil on hand-made pockets.
    /// The catalog playlist id this pocket was converted from (e.g. "pl_…"). nil ⇒ no source.
    var sourcePlaylistId: String?
    /// The source's name (e.g. "Apple Music (Local)") — disambiguates playlist ids across sources.
    var sourceName: String?
    /// The source playlist's membership (deduped, ordered) as of the LAST applied sync — the
    /// three-way-merge base: source adds = current − snapshot; source removals = snapshot − current.
    var sourceSongIds: [String]?
    /// Per-pocket sync opt-out. nil ⇒ enabled (a converted pocket syncs unless turned off).
    var sourceSyncEnabled: Bool?
    /// Per-pocket Apple Music sync direction (raw `CollectionSyncDirection`). nil ⇒ two-way.
    var amSyncDirection: String?
    /// The APPLE MUSIC library playlist this collection is bound to, captured from the sync's push
    /// result. ADDITIVE-OPTIONAL (nil = never pushed, or pushed before this field existed), so no
    /// schema bump — a version bump discards existing documents.
    ///
    /// WHY A DURABLE LINK. Without it the push matches by NAME on every pass, so renaming a
    /// playlist in PocketDJ makes the next sync fail to find its counterpart and CREATE A SECOND
    /// one in Apple Music. The id is stable across renames on both sides; the name never was.
    ///
    /// PRIVACY: this is a handle into the user's own Apple Music library, so every import path
    /// STRIPS it. A shared collection must never carry a link to the sharer's library.
    var amPlaylistId: String?
    /// Epoch ms of the last sync that CHANGED the pocket (or refreshed the snapshot). nil = never.
    var sourceSyncedAt: Double?
    /// v7: epoch ms of the last time the user hit ▶ Play on this pocket — the "Recently played"
    /// sort key. Stamped by `CollectionsStore.markPlayed(pocketId:)` (NOT via `mutatePocket`, so
    /// `updatedAt` stays a pure membership/rename signal). nil ⇒ never played ⇒ sorts last.
    var lastPlayedAt: Double?
    var createdAt: Double = 0
    var updatedAt: Double = 0

    // Notes never count toward "members" (songs/albums/pockets) for count/runtime.
    var isEmpty: Bool { songIds.isEmpty && albumIds.isEmpty && childPocketIds.isEmpty && notes.isEmpty }
    var memberCount: Int { songIds.count + albumIds.count + childPocketIds.count }
    /// Was converted from a source playlist (provenance present) — the sync UI shows only then.
    var hasSource: Bool { sourcePlaylistId != nil }
    /// Participates in AUTO sync: has a source and the per-pocket toggle isn't off.
    var syncsWithSource: Bool { hasSource && (sourceSyncEnabled ?? true) }
    /// The effective Apple Music sync direction (nil/unknown raw ⇒ two-way).
    var amSyncDir: CollectionSyncDirection {
        amSyncDirection.flatMap(CollectionSyncDirection.init(rawValue:)) ?? .both
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, description, songIds, albumIds, childPocketIds, notes, folderId, songRepeats,
             sourcePlaylistId, sourceName, sourceSongIds, sourceSyncEnabled, sourceSyncedAt, lastPlayedAt,
             amSyncDirection, createdAt, updatedAt
    }
    init(id: String, name: String, kind: PocketKind = .harmonic, description: String? = nil,
         songIds: [String] = [], albumIds: [String] = [], childPocketIds: [String] = [],
         notes: [PocketNote] = [], folderId: String? = nil, songRepeats: [String: Int] = [:],
         sourcePlaylistId: String? = nil, sourceName: String? = nil, sourceSongIds: [String]? = nil,
         sourceSyncEnabled: Bool? = nil, sourceSyncedAt: Double? = nil, lastPlayedAt: Double? = nil,
         amSyncDirection: String? = nil, createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.description = description
        self.songIds = songIds; self.albumIds = albumIds; self.childPocketIds = childPocketIds
        self.notes = notes; self.folderId = folderId; self.songRepeats = songRepeats
        self.sourcePlaylistId = sourcePlaylistId; self.sourceName = sourceName
        self.sourceSongIds = sourceSongIds; self.sourceSyncEnabled = sourceSyncEnabled
        self.sourceSyncedAt = sourceSyncedAt; self.lastPlayedAt = lastPlayedAt
        self.amSyncDirection = amSyncDirection
        self.createdAt = createdAt; self.updatedAt = updatedAt
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
        folderId = try? c.decode(String.self, forKey: .folderId)
        songRepeats = (try? c.decode([String: Int].self, forKey: .songRepeats)) ?? [:]
        sourcePlaylistId = try? c.decode(String.self, forKey: .sourcePlaylistId)
        sourceName = try? c.decode(String.self, forKey: .sourceName)
        sourceSongIds = try? c.decode([String].self, forKey: .sourceSongIds)
        sourceSyncEnabled = try? c.decode(Bool.self, forKey: .sourceSyncEnabled)
        sourceSyncedAt = try? c.decode(Double.self, forKey: .sourceSyncedAt)
        lastPlayedAt = try? c.decode(Double.self, forKey: .lastPlayedAt)
        amSyncDirection = try? c.decode(String.self, forKey: .amSyncDirection)
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

// MARK: - Repeat-count semantics (shared)

/// The one place the repeat-count convention lives, so every consumer (add UI, in-collection
/// editor, realize, playback, totals) agrees. A performance item's `repeatCount` is the TOTAL
/// number of plays before the setlist advances: nil/≤1 ⇒ once; clamped to a sane ceiling so a
/// fat-fingered value can't wedge playback.
enum CollectionMembership {
    static let maxRepeat = 99

    /// Normalize a stored (optional, possibly out-of-range) repeat to a play count ≥ 1.
    static func normalizedRepeat(_ raw: Int?) -> Int {
        guard let raw else { return 1 }
        return min(maxRepeat, max(1, raw))
    }

    /// The value to PERSIST for a chosen play count: nil for a normal single play (keeps the
    /// serialized node/track free of the key), else the clamped count.
    static func storedRepeat(_ count: Int) -> Int? {
        let n = min(maxRepeat, max(1, count))
        return n <= 1 ? nil : n
    }
}

// MARK: - Lossy per-element array decoding (the v5 insurance)

/// Decodes `[Element]` DROPPING the elements that fail — one bad or unknown-kind element
/// costs that element only, never the whole array. Each element decodes into a
/// `FailableBox` (which swallows the element's error into `nil`), then the boxes are
/// compacted. Applied at every `[Playlist]` / `[PlaylistNode]` site (document list,
/// chapter arrays, nested `children`) so a future node kind — or one corrupt row — can
/// NEVER wipe playlists: pre-v5, the synthesized `[PlaylistNode]` decode threw on a
/// single unknown kind, the document's lenient `try?` yielded `playlists = []`, and the
/// next save() persisted the empty list (total loss on the older app).
struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]

    /// Decodes to `nil` instead of throwing, so the enclosing ARRAY decode survives.
    private struct FailableBox<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        // A non-array value still throws (same as synthesized) — only ELEMENT failures
        // are absorbed. The `try` here surfaces that type-mismatch to the caller.
        let c = try decoder.singleValueContainer()
        elements = try c.decode([FailableBox<Element>].self).compactMap(\.value)
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
    /// How many times a track PLAYS before the setlist advances (a performance item's loop
    /// count — spec: repeat count). nil/absent ⇒ once. Additive + lenient: older apps ignore
    /// the key, and a node without it decodes to nil = normal single play. Clamp/read via
    /// `CollectionMembership.normalizedRepeat`.
    var repeatCount: Int?

    var id: String { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId, kind, songId, albumId, pocketId, text, name, targetMs, children, note, repeatCount
    }

    /// Memberwise init, spelled out because the hand-written `init(from:)` below would
    /// otherwise suppress the compiler's — same parameter order + nil defaults every
    /// existing call site (factories, stores, tests) already relies on.
    init(nodeId: String, kind: Kind, songId: String? = nil, albumId: String? = nil,
         pocketId: String? = nil, text: String? = nil, name: String? = nil,
         targetMs: Int? = nil, children: [PlaylistNode]? = nil, note: String? = nil,
         repeatCount: Int? = nil) {
        self.nodeId = nodeId; self.kind = kind
        self.songId = songId; self.albumId = albumId; self.pocketId = pocketId; self.text = text
        self.name = name; self.targetMs = targetMs; self.children = children
        self.note = note; self.repeatCount = repeatCount
    }

    /// v5 LOSSY decode. Field-for-field identical to the synthesized decoder for the
    /// known kinds — required `nodeId`/`kind` throw when missing, every optional uses
    /// `decodeIfPresent` (so a present-but-wrong-type value still throws) — with two
    /// deliberate differences:
    ///   • an unknown `kind` STRING throws (exactly like synthesized): the point is
    ///     that the enclosing `LossyDecodableArray` then drops just this node;
    ///   • `children` recurses through `LossyDecodableArray`, so an unknown-kind
    ///     grandchild drops that grandchild only and THIS node survives.
    /// `encode(to:)` stays SYNTHESIZED, so round-trip bytes are unchanged for known kinds.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        kind = try c.decode(Kind.self, forKey: .kind)
        songId = try c.decodeIfPresent(String.self, forKey: .songId)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        pocketId = try c.decodeIfPresent(String.self, forKey: .pocketId)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        targetMs = try c.decodeIfPresent(Int.self, forKey: .targetMs)
        children = try c.decodeIfPresent(LossyDecodableArray<PlaylistNode>.self, forKey: .children)?.elements
        note = try c.decodeIfPresent(String.self, forKey: .note)
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount)
    }
}

/// A flat, named grouping of playlists (v3). Membership is by `Playlist.folderId`, so a
/// folder carries no member list — it's just an id + name + timestamps. Lenient/all-
/// optional-where-possible (like Pocket) for graceful round-tripping.
struct PlaylistFolder: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Double = 0
    var updatedAt: Double = 0

    enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt }
    init(id: String, name: String, createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? CollectionsFactory.newFolderId()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// A playlist template: ordered chapters (every entry is a `.sequence` node).
struct Playlist: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var sequences: [PlaylistNode]      // each .kind == .sequence; sequences[0] is default
    var targetMs: Int?
    var folderId: String?              // v3: optional ⇒ back-compat (nil = top level)
    // v6: SOURCE PROVENANCE — set only by Duplicate-as-editable-playlist; nil on hand-made
    // playlists. Same shape + semantics as Pocket's (see there for the field-by-field docs).
    var sourcePlaylistId: String?
    var sourceName: String?
    var sourceSongIds: [String]?
    var sourceSyncEnabled: Bool?
    var sourceSyncedAt: Double?
    /// Per-playlist Apple Music sync direction (raw `CollectionSyncDirection`). nil ⇒ two-way.
    var amSyncDirection: String?
    /// The APPLE MUSIC library playlist this collection is bound to, captured from the sync's push
    /// result. ADDITIVE-OPTIONAL (nil = never pushed, or pushed before this field existed), so no
    /// schema bump — a version bump discards existing documents.
    ///
    /// WHY A DURABLE LINK. Without it the push matches by NAME on every pass, so renaming a
    /// playlist in PocketDJ makes the next sync fail to find its counterpart and CREATE A SECOND
    /// one in Apple Music. The id is stable across renames on both sides; the name never was.
    ///
    /// PRIVACY: this is a handle into the user's own Apple Music library, so every import path
    /// STRIPS it. A shared collection must never carry a link to the sharer's library.
    var amPlaylistId: String?
    /// v7: epoch ms of the last time the user hit ▶ Play on this playlist — the "Recently played"
    /// sort key. Stamped by `CollectionsStore.markPlayed(playlistId:)` (NOT via `mutatePlaylist`,
    /// so `updatedAt` stays a pure membership/rename signal). nil ⇒ never played ⇒ sorts last.
    var lastPlayedAt: Double?
    var createdAt: Double = 0
    var updatedAt: Double = 0

    /// Was duplicated from a source playlist (provenance present) — the sync UI shows only then.
    var hasSource: Bool { sourcePlaylistId != nil }
    /// Participates in AUTO sync: has a source and the per-playlist toggle isn't off.
    var syncsWithSource: Bool { hasSource && (sourceSyncEnabled ?? true) }
    /// The effective Apple Music sync direction (nil/unknown raw ⇒ two-way).
    var amSyncDir: CollectionSyncDirection {
        amSyncDirection.flatMap(CollectionSyncDirection.init(rawValue:)) ?? .both
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, sequences, targetMs, folderId,
             sourcePlaylistId, sourceName, sourceSongIds, sourceSyncEnabled, sourceSyncedAt,
             amSyncDirection, lastPlayedAt,
             createdAt, updatedAt
    }

    /// Memberwise init, spelled out because the hand-written `init(from:)` below would
    /// otherwise suppress the compiler's (same parameters/defaults every call site uses).
    init(id: String, name: String, description: String? = nil, sequences: [PlaylistNode],
         targetMs: Int? = nil, folderId: String? = nil,
         sourcePlaylistId: String? = nil, sourceName: String? = nil, sourceSongIds: [String]? = nil,
         sourceSyncEnabled: Bool? = nil, sourceSyncedAt: Double? = nil,
         amSyncDirection: String? = nil, lastPlayedAt: Double? = nil,
         createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.description = description
        self.sequences = sequences; self.targetMs = targetMs; self.folderId = folderId
        self.sourcePlaylistId = sourcePlaylistId; self.sourceName = sourceName
        self.sourceSongIds = sourceSongIds; self.sourceSyncEnabled = sourceSyncEnabled
        self.sourceSyncedAt = sourceSyncedAt; self.amSyncDirection = amSyncDirection
        self.lastPlayedAt = lastPlayedAt
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// v5 LOSSY chapters: `sequences` decodes per-element, so one undecodable /
    /// unknown-kind chapter node drops that chapter slot only — the playlist and its
    /// other chapters survive. Every other field mirrors the synthesized decoder
    /// exactly (required fields throw), so a playlist that is itself undecodable is
    /// dropped by the DOCUMENT's lossy `[Playlist]` — that playlist only, never the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sequences = try c.decode(LossyDecodableArray<PlaylistNode>.self, forKey: .sequences).elements
        targetMs = try c.decodeIfPresent(Int.self, forKey: .targetMs)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        sourcePlaylistId = try c.decodeIfPresent(String.self, forKey: .sourcePlaylistId)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        sourceSongIds = try c.decodeIfPresent([String].self, forKey: .sourceSongIds)
        sourceSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .sourceSyncEnabled)
        sourceSyncedAt = try c.decodeIfPresent(Double.self, forKey: .sourceSyncedAt)
        amSyncDirection = try c.decodeIfPresent(String.self, forKey: .amSyncDirection)
        lastPlayedAt = try c.decodeIfPresent(Double.self, forKey: .lastPlayedAt)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
    }
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
    /// Frozen loop count (a performance item's repeat count, snapshotted from the template
    /// node / pocket at ▶ Play). nil/absent ⇒ once. Read via `CollectionMembership.normalizedRepeat`.
    var repeatCount: Int?

    // Stable per-row id for SwiftUI (songId may repeat for cues / blanks).
    var id: String { "\(songId)#\(name)" }

    /// The length of ONE play (pre-repeat) — mirrors the engine's DEFAULT_TRACK_MS fallback.
    /// This is what the player arms as the per-track position boundary; the track then loops
    /// `repeatCount` times, ending (and repeating) at each single play's end.
    var perPlayMs: Int {
        if isText == true { return 0 }
        return (lengthMs.map { $0 > 0 ? $0 : RealizeEngine.defaultTrackMs }) ?? RealizeEngine.defaultTrackMs
    }

    /// Duration a row contributes to TOTALS — one play × the repeat count, so a looped
    /// performance item counts for all its plays in Setlist.totalMs / the runtime label.
    var shownMs: Int { perPlayMs * CollectionMembership.normalizedRepeat(repeatCount) }

    enum CodingKeys: String, CodingKey {
        case songId, artist, name, bpm, camelot, lengthMs, source, sequenceName, note, isText, pocketId, mixSuggestions, repeatCount
    }
    init(songId: String, artist: String, name: String, bpm: Double?, camelot: String?,
         lengthMs: Int? = nil, source: TrackSource = .explicit, sequenceName: String? = nil,
         note: String? = nil, isText: Bool? = nil, pocketId: String? = nil,
         mixSuggestions: [MixSuggestion]? = nil, repeatCount: Int? = nil) {
        self.songId = songId; self.artist = artist; self.name = name
        self.bpm = bpm; self.camelot = camelot; self.lengthMs = lengthMs
        self.source = source; self.sequenceName = sequenceName; self.note = note
        self.isText = isText; self.pocketId = pocketId; self.mixSuggestions = mixSuggestions
        self.repeatCount = repeatCount
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
        repeatCount = try? c.decode(Int.self, forKey: .repeatCount)
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
    var folders: [PlaylistFolder]     // v3: flat playlist folders (optional/back-compat)
    var lastAddTarget: AddTarget?     // "Add-to remembers last"
    /// The last few "Add to…" targets, most-recent first (the Recent quick-add row). ADDITIVE-
    /// OPTIONAL by design: an older document lacking the key decodes to nil (→ [] in the store),
    /// so it can NEVER wipe the rest of the document. Rides the SAME collections CloudSync as
    /// `lastAddTarget` (the top-of-list entry is exactly that value), so the MRU syncs across
    /// devices. Deduped by (kind,id) IGNORING sequenceId; capped in the store.
    var recentAddTargets: [AddTarget]?

    init(schemaVersion: Int = collectionsSchemaVersion,
         pockets: [Pocket] = [], playlists: [Playlist] = [], setlists: [Setlist] = [],
         folders: [PlaylistFolder] = [], lastAddTarget: AddTarget? = nil,
         recentAddTargets: [AddTarget]? = nil) {
        self.schemaVersion = schemaVersion
        self.pockets = pockets
        self.playlists = playlists
        self.setlists = setlists
        self.folders = folders
        self.lastAddTarget = lastAddTarget
        self.recentAddTargets = recentAddTargets
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pockets, playlists, setlists, folders, lastAddTarget, recentAddTargets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
        pockets = (try? c.decode([Pocket].self, forKey: .pockets)) ?? []
        // v5: the playlists LIST is lossy per element — an undecodable playlist drops
        // that playlist only (previously one bad playlist zeroed the whole list here,
        // and the next save() persisted the loss).
        playlists = (try? c.decode(LossyDecodableArray<Playlist>.self, forKey: .playlists))?.elements ?? []
        setlists = (try? c.decode([Setlist].self, forKey: .setlists)) ?? []
        folders = (try? c.decode([PlaylistFolder].self, forKey: .folders)) ?? []
        lastAddTarget = try? c.decode(AddTarget.self, forKey: .lastAddTarget)
        // Additive-optional: absent in any pre-F11 document → nil (the `try?` also absorbs a
        // malformed value), so an old blob still yields all its collections intact.
        recentAddTargets = try? c.decode([AddTarget].self, forKey: .recentAddTargets)
    }
}

enum CollectionsCodec {
    static func decode(_ data: Data) throws -> CollectionsDocument {
        let doc = try JSONDecoder().decode(CollectionsDocument.self, from: data)
        return doc.schemaVersion < collectionsSchemaVersion ? CollectionsMigration.migrate(doc) : doc
    }
    static func encode(_ doc: CollectionsDocument) throws -> Data {
        // COMPACT, not pretty-printed. This document is re-encoded and rewritten in full on
        // every collection mutation, and on a real library it is big: measured 6.97 MB
        // pretty-printed vs 4.02 MB compact — 42% of every write was indentation whitespace,
        // and all of it had to be re-parsed on the next launch too. `.sortedKeys` STAYS: the
        // cloud sync is whole-document last-writer-wins and compares serialized bytes, so a
        // stable key order is load-bearing; indentation never was.
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
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
        // v2 → v3: playlists gained `folderId` + the doc gained `folders`. Older docs
        //   have neither — lenient decode already defaults `folders` to [] and each
        //   playlist's `folderId` to nil (top level), so the mapping forward is the
        //   no-op identity. Kept explicit so the version bump is visible + the seam
        //   exists for any future folder-shape transform.
        // v3 → v4: pockets gained `folderId`. Older pockets simply have none — lenient
        //   decode already defaults the field to nil (top level), so the mapping forward
        //   is the no-op identity. Kept explicit so the version bump is visible + the
        //   seam exists for any future pocket-folder-shape transform.
        // v4 → v5: no shape change — v5 = lossy per-element playlist decode + studio
        //   namespaced ids (smp_/lp_/ptn_) riding the EXISTING songIds arrays. Both are
        //   decoder/consumer behaviour, not stored shape, so the mapping forward is the
        //   no-op identity. Kept explicit so the version bump is visible + the seam
        //   exists for any future studio-shape transform.
        // v5 → v6: pockets AND playlists gained optional source provenance
        //   (`sourcePlaylistId` / `sourceName` / `sourceSongIds` / `sourceSyncEnabled` /
        //   `sourceSyncedAt`). Older items simply have none — lenient decode already
        //   defaults them all to nil (hand-made item, never synced), so the mapping
        //   forward is the no-op identity. Kept explicit so the version bump is visible +
        //   the seam exists for any future provenance-shape transform.
        // v6 → v7: pockets AND playlists gained optional `lastPlayedAt` (the "Recently played"
        //   sort key). Older items simply have none — lenient decode already defaults it to nil
        //   (never played), so the mapping forward is the NO-OP IDENTITY. Kept explicit so the
        //   version bump is visible + the seam exists for any future playback-stat transform.
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
    static func newFolderId() -> String { "fld_" + uid() }

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

// MARK: - Collection sorting

/// The fields the user-selectable collection sort (`CollectionSortOrder`) needs from a
/// listable collection. Playlists + pockets conform directly; read-only source playlists
/// conform with neutral defaults (no timestamps) so the SAME comparator can order them.
protocol CollectionSortable {
    var name: String { get }
    var updatedAt: Double { get }
    var lastPlayedAt: Double? { get }
}

extension Playlist: CollectionSortable {}
extension Pocket: CollectionSortable {}
