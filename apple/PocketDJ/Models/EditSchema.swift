import Foundation

// MARK: - Edits schema — the version-safe, device-portable contract
//
// This is the CANONICAL schema for user metadata edits. It is the contract
// between every PocketDJ client (iPhone / iPad / Mac) and the iMac merge tool
// that folds edits back into the main, read-only index. Design rules — do not
// break them, or old exports/devices stop interoperating:
//
//  1. EVERY field is OPTIONAL. A `nil`/absent field means "no override" — the
//     original index value is shown. This is what makes the format degrade
//     gracefully: a document written by a NEWER app (with fields this build
//     doesn't know) still decodes here; unknown keys are simply ignored.
//  2. VERSIONED. `EditsDocument.schemaVersion` is bumped on ANY shape change,
//     and `EditsMigration.migrate` upgrades older documents on load
//     (auto-migrate). A document with NO version is treated as v0 and migrated.
//  3. ADDITIVE-ONLY. Never remove or repurpose a field. Add a new optional field
//     plus a migration step. This keeps every historical export valid forever.
//  4. DETERMINISTIC. Export uses sorted keys + pretty printing so diffs/merges
//     (on the iMac) are clean and reviewable.
//
// Bump this on ANY change to AlbumEdit / SongEdit / EditsDocument, and add the
// corresponding step in `EditsMigration.migrate`.
let editsSchemaVersion = 1

// MARK: - Editable objects (tightly typed, all-optional override fields)

/// Overridable fields for an album. Each maps 1:1 to an `IndexAlbum` field; an
/// unset (`nil`) field leaves the original index value intact.
struct AlbumEdit: Codable, Hashable, Sendable {
    var name: String?       // album title
    var artist: String?     // album artist / band
    var genre: String?      // raw genre string (collapsed to a category at display time)
    var year: Int?          // release year (Gregorian)
    var country: String?    // ISO-ish country code or name, e.g. "US"

    var isEmpty: Bool { name == nil && artist == nil && genre == nil && year == nil && country == nil }
}

/// Overridable fields for a song. Each maps 1:1 to an `IndexSong` field.
struct SongEdit: Codable, Hashable, Sendable {
    var name: String?               // track title
    var artist: String?             // track artist
    var year: Int?                  // release year
    var trackNumber: Int?           // 1-based track number
    var bpm: Double?                // beats per minute
    var key: String?                // musical key, e.g. "F# major"
    var camelot: String?            // Camelot wheel code, e.g. "8B" (1–12 + A|B)
    var explicit: Bool?             // explicit lyrics flag
    var sentimentKeywords: [String]? // mood / sentiment tags

    var isEmpty: Bool {
        name == nil && artist == nil && year == nil && trackNumber == nil && bpm == nil
            && key == nil && camelot == nil && explicit == nil && sentimentKeywords == nil
    }
}

// MARK: - Portable document (the Export/Import payload)

/// The versioned envelope that Export writes and Import reads — byte-identical
/// across devices. Keyed by stable content-derived ids (`alb_…` / `sng_…`) so an
/// edit made on one device applies to the same item everywhere.
struct EditsDocument: Codable, Sendable {
    var schemaVersion: Int
    var albums: [String: AlbumEdit]   // albumId → edit
    var songs: [String: SongEdit]     // songId  → edit
    var meta: Meta?

    /// Informational only — never required to apply edits.
    struct Meta: Codable, Sendable {
        var exportedAt: String?   // ISO-8601 timestamp
        var appVersion: String?   // e.g. "0.1.0"
        var platform: String?     // "iOS" | "iPadOS" | "macOS"
    }

    init(schemaVersion: Int = editsSchemaVersion,
         albums: [String: AlbumEdit] = [:],
         songs: [String: SongEdit] = [:],
         meta: Meta? = nil) {
        self.schemaVersion = schemaVersion
        self.albums = albums
        self.songs = songs
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, albums, songs, meta }

    /// Lenient decode: a missing version ⇒ v0 (then migrated); missing maps ⇒
    /// empty; unknown keys ignored. Never throws on a structurally-valid file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
        albums = (try? c.decode([String: AlbumEdit].self, forKey: .albums)) ?? [:]
        songs = (try? c.decode([String: SongEdit].self, forKey: .songs)) ?? [:]
        meta = try? c.decode(Meta.self, forKey: .meta)
    }
}

// MARK: - Codec (encode / decode with auto-migration + graceful degrade)

enum EditsCodec {
    /// Decode an exported document, auto-migrating older schema versions. A
    /// version NEWER than this build keeps whatever decoded (unknown fields are
    /// dropped) — i.e. it degrades, it does not fail.
    static func decode(_ data: Data) throws -> EditsDocument {
        let doc = try JSONDecoder().decode(EditsDocument.self, from: data)
        return doc.schemaVersion < editsSchemaVersion ? EditsMigration.migrate(doc) : doc
    }

    static func encode(_ doc: EditsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }
}

/// Upgrades older documents to the current schema. Each version transition is an
/// explicit, isolated step so migrations stay auditable.
enum EditsMigration {
    static func migrate(_ document: EditsDocument) -> EditsDocument {
        var doc = document
        // v0 → v1: the initial schema; nothing structural to transform yet.
        // Future: `while doc.schemaVersion < editsSchemaVersion { switch doc.schemaVersion { case 1: …; default: break }; doc.schemaVersion += 1 }`
        doc.schemaVersion = editsSchemaVersion
        return doc
    }
}

// MARK: - Overlay (apply an edit onto an index object)

extension IndexAlbum {
    /// Returns a copy with the album-edit's set fields applied (unset fields keep
    /// the original index values).
    func applying(_ e: AlbumEdit?) -> IndexAlbum {
        guard let e else { return self }
        return IndexAlbum(id: id, artist: e.artist ?? artist, name: e.name ?? name,
                          coverArt: coverArt, coverArtSources: coverArtSources,
                          genre: e.genre ?? genre, year: e.year ?? year, country: e.country ?? country,
                          trackList: trackList, fileType: fileType,
                          audioTracks: audioTracks, audioDurationSec: audioDurationSec)
    }
}

extension IndexSong {
    func applying(_ e: SongEdit?) -> IndexSong {
        guard let e else { return self }
        return IndexSong(id: id, albumId: albumId, artist: e.artist ?? artist, name: e.name ?? name,
                         trackNumber: e.trackNumber ?? trackNumber, year: e.year ?? year,
                         sentimentKeywords: e.sentimentKeywords ?? sentimentKeywords,
                         explicit: e.explicit ?? explicit, bpm: e.bpm ?? bpm,
                         key: e.key ?? key, camelot: e.camelot ?? camelot,
                         length: length, fileType: fileType, lyricsStatus: lyricsStatus)
    }
}
