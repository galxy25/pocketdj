import Foundation

/// Wire types for the PocketDJ recommendation engine (`scripts/lambda/rec-engine`) — the
/// upload-batch shape `POST /events` accepts and the lenient decodes of its responses.
///
/// DOCTRINE: never rename the wire `kind`/`source`/`action` string values once shipped (same
/// rule as `PlaySource`/`ActivityKind`); response types decode EVERY field leniently (`try?`
/// per field, defaults) so a newer server can add keys without stranding older clients.
///
/// RESERVED (not sent in v1): a `songFeatures` top-level key on the upload batch — the future
/// carrier for provisional-source song metadata (amrec_/Imported/profile items) the server's
/// features file can't know about. The server accepts and drops it today.

// MARK: - Upload wire types

struct RecPlayEventWire: Codable, Equatable {
    var id: String
    var songId: String
    var atMs: Double
    var source: String?
}

struct RecFavoriteWire: Codable, Equatable {
    var songId: String
    var favorited: Bool
    var atMs: Double
}

struct RecActivityWire: Codable, Equatable {
    var id: String
    var atMs: Double
    var kind: String
    var itemId: String
    var collectionId: String?
    var collectionKind: String?
    var collectionName: String?
}

/// The WS-D (Collector's Puzzle) seam type: the Games workstream produces these through
/// `RecommendationService.puzzleEventsProvider` once its store lands. Shipped now so the wire
/// schema is ready; the provider stays nil until then.
struct RecPuzzleEventWire: Codable, Equatable {
    var id: String
    var atMs: Double
    var gameId: String?
    var songId: String?
    var collectionId: String?
    var action: String
    var points: Int?
}

/// ACCEPT / REJECT on a recommendation — the tuning loop's return path, and the first NEGATIVE
/// signal this wire has ever carried.
///
/// That is the reason it is its own event kind rather than another `RecActivityWire` row: every
/// existing event on this wire means "the user engaged with this", and the server reads them all
/// as positive evidence (a puzzle filing is worth a flat seed bonus; see `PuzzleRecEventBridge`
/// for what happened the last time a negative decision was nearly folded into a positive stream).
/// A rejection has to be unmistakably negative on arrival, so it carries its own `verdict`.
///
/// `verdict` is "accepted" | "rejected" | "cleared" and NEVER renames once shipped (the
/// wire-value doctrine at the top of this file). "cleared" is the undo — an explicit row rather
/// than an absence, so the server can retract an opinion instead of keeping the first one forever.
struct RecFeedbackWire: Codable, Equatable {
    var id: String
    var atMs: Double
    var songId: String
    var verdict: String
    /// Which surface it was given on ("tile" / "nowPlaying" / "carPlay" / "widget" / "songDetail").
    /// Carried because "rejected while it was playing" is stronger evidence than "rejected while
    /// scrolling", and the server may weight them apart later; nothing branches on it today.
    var surface: String?
    /// Which recommendation list produced the song ("zone", "suggested", a collection id).
    var context: String?
}

struct RecCollectionsSnapshotWire: Codable, Equatable {
    var atMs: Double
    var collections: [Entry]
    struct Entry: Codable, Equatable {
        var id: String
        var kind: String
        var name: String
        var songIds: [String]
    }
}

/// LIFETIME play counts — a SNAPSHOT, in the same spirit as `RecCollectionsSnapshotWire`, NOT an
/// event stream. Apple's counters are read as a whole and REPLACE the previous reading, so the
/// server stores this wholesale and a re-upload of the same `atMs` is a no-op. Sending increments
/// instead would inflate on every retry — the SET-never-ADD rule, carried onto the wire.
///
/// PRIVACY: this goes to the user's OWN private per-profile state object in the rec engine, which
/// is what already holds their play log and favorites. It is deliberately never written into the
/// shared catalog index.
struct RecPlayCountsWire: Codable, Equatable {
    var atMs: Double
    /// songId → lifetime plays. Sparse: only songs with a non-zero count.
    var counts: [String: Int]
    /// songId → last-played date, as WHOLE DAYS since the epoch. A separate axis from `counts`,
    /// not a refinement of it: "played 40 times, last in 2019" and "played once yesterday" rank
    /// differently and the server weights them independently.
    ///
    /// DAYS, not milliseconds, on purpose — 5 digits per row instead of 13, which is ~200 KB
    /// saved on a 20k-row upload against the server's 4 MB body cap, and a day's resolution is
    /// still ~700× finer than the 2-year half-life it feeds.
    ///
    /// OPTIONAL so the field is invisible to an older server (which ignores unknown keys) and an
    /// older client (which never sends it) — no version bump, the collections-schema doctrine.
    var lastPlayedDays: [String: Int]?
}

/// THE AUDIO-ANALYSIS SHORTLIST — ids and nothing else.
///
/// `RecAudioShortlist.select` picked these on device out of the ranking that was just computed:
/// the most novel and the most similar-to-recent of v1's candidates, in-catalog only, capped at a
/// night's worth. The server holds them as a work queue for the nightly librosa job
/// (`scripts/rec-audio-nightly.mjs`), which returns a timbre vector per song.
///
/// IDS AND NOTHING ELSE, deliberately. The cross-cutting rule for every cloud-touching part of
/// this system is that the DEVICE COMPUTES and the SERVER RECEIVES IDS: everything that decided
/// this list — the play history it was ranked against, the artist familiarity, the genre shares —
/// stays here. The server already knows the catalog metadata for these ids from
/// `rec-features.json`, so sending any of it again would widen what leaves the device for nothing.
///
/// A SET, NOT A LOG. Re-sending an id the server is already holding is a no-op, which is what
/// makes the client safe to retry: a flush that fails after the PUT, a relaunch mid-upload, or two
/// devices refreshing For You within a minute of each other all converge on the same pending set
/// rather than queueing the same song twice.
struct RecAudioQueueWire: Codable, Equatable {
    var atMs: Double
    var songIds: [String]
}

struct RecUploadBatch: Encodable {
    var v = 1
    var deviceId: String
    var sentAtMs: Double
    var plays: [RecPlayEventWire]?
    var favorites: [RecFavoriteWire]?
    var activity: [RecActivityWire]?
    var puzzle: [RecPuzzleEventWire]?
    /// 👍/👎 on suggestions. OPTIONAL so an older server ignores the key and an older client
    /// never sends it — no version bump (the collections-schema doctrine).
    var feedback: [RecFeedbackWire]?
    var collectionsSnapshot: RecCollectionsSnapshotWire?
    var playCounts: RecPlayCountsWire?
    /// Songs this device wants audio-analysed. Same additive-optional doctrine as `feedback`:
    /// invisible to an older server, never sent by an older client.
    var audioQueue: RecAudioQueueWire?
}

// MARK: - Response wire types (ALL fields lenient — the collections-schema doctrine)

struct RecUploadResponse: Decodable {
    var ok: Bool?
    var totalPlays: Int?

    private enum CodingKeys: String, CodingKey { case ok, totals }
    private enum TotalsKeys: String, CodingKey { case plays }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        ok = try? c?.decode(Bool.self, forKey: .ok)
        let t = try? c?.nestedContainer(keyedBy: TotalsKeys.self, forKey: .totals)
        totalPlays = try? t?.decode(Int.self, forKey: .plays)
    }
}

struct RecSongSuggestionWire: Decodable, Equatable {
    var songId: String
    var name: String?
    var artist: String?
    var score: Double?
    var reasons: [String]?

    private enum CodingKeys: String, CodingKey { case songId, name, artist, score, reasons }
    init(songId: String, name: String? = nil, artist: String? = nil,
         score: Double? = nil, reasons: [String]? = nil) {
        self.songId = songId; self.name = name; self.artist = artist
        self.score = score; self.reasons = reasons
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = (try? c.decode(String.self, forKey: .songId)) ?? ""
        name = try? c.decode(String.self, forKey: .name)
        artist = try? c.decode(String.self, forKey: .artist)
        score = try? c.decode(Double.self, forKey: .score)
        reasons = try? c.decode([String].self, forKey: .reasons)
    }
}

struct RecSongsResponse: Decodable {
    var songs: [RecSongSuggestionWire]

    private enum CodingKeys: String, CodingKey { case songs }
    private struct Lenient: Decodable {
        let row: RecSongSuggestionWire?
        init(from decoder: Decoder) throws { row = try? RecSongSuggestionWire(from: decoder) }
    }
    init(songs: [RecSongSuggestionWire] = []) { self.songs = songs }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        songs = ((try? c?.decode([Lenient].self, forKey: .songs)) ?? [])
            .compactMap(\.row).filter { !$0.songId.isEmpty }
    }
}

struct RecCollectionSuggestionWire: Decodable, Equatable {
    var id: String
    var kind: String?
    var name: String?
    var score: Double?
    var reasons: [String]?

    private enum CodingKeys: String, CodingKey { case id, kind, name, score, reasons }
    init(id: String, kind: String? = nil, name: String? = nil,
         score: Double? = nil, reasons: [String]? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.score = score; self.reasons = reasons
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        kind = try? c.decode(String.self, forKey: .kind)
        name = try? c.decode(String.self, forKey: .name)
        score = try? c.decode(Double.self, forKey: .score)
        reasons = try? c.decode([String].self, forKey: .reasons)
    }
}

struct RecCollectionsResponse: Decodable {
    var songId: String?
    var suggestions: [RecCollectionSuggestionWire]

    private enum CodingKeys: String, CodingKey { case songId, suggestions }
    private struct Lenient: Decodable {
        let row: RecCollectionSuggestionWire?
        init(from decoder: Decoder) throws { row = try? RecCollectionSuggestionWire(from: decoder) }
    }
    init(songId: String? = nil, suggestions: [RecCollectionSuggestionWire] = []) {
        self.songId = songId; self.suggestions = suggestions
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        songId = try? c?.decode(String.self, forKey: .songId)
        suggestions = ((try? c?.decode([Lenient].self, forKey: .suggestions)) ?? [])
            .compactMap(\.row).filter { !$0.id.isEmpty }
    }
}

// MARK: - Suggestion → AddTarget resolution (pure, keeps the Add sheet dumb)

enum RecSuggestionFilter {
    /// Map server collection suggestions to local `AddTarget`s: drop suggestions whose id no
    /// longer resolves locally, drop any already present in `excluding` (dedupe vs the Recent
    /// row by `(kind, id)` — sequenceId ignored, matching the Recent MRU's own dedupe), cap.
    static func resolveTargets(_ suggestions: [RecCollectionSuggestionWire],
                               pockets: [Pocket], playlists: [Playlist],
                               excluding: [AddTarget], limit: Int = 3) -> [AddTarget] {
        let pocketIds = Set(pockets.map(\.id))
        let playlistIds = Set(playlists.map(\.id))
        let excludedPairs = Set(excluding.map { "\($0.kind.rawValue)|\($0.id)" })
        var out: [AddTarget] = []
        for s in suggestions {
            guard out.count < limit else { break }
            let kind: AddTarget.Kind
            switch s.kind {
            case "pocket": kind = .pocket
            case "playlist": kind = .playlist
            default: continue
            }
            let resolves = kind == .pocket ? pocketIds.contains(s.id) : playlistIds.contains(s.id)
            guard resolves, !excludedPairs.contains("\(kind.rawValue)|\(s.id)") else { continue }
            out.append(AddTarget(kind: kind, id: s.id, sequenceId: nil))
        }
        return out
    }
}
