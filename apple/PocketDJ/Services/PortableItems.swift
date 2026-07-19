import Foundation

/// The `items.json` codec for PORTABLE playlist/pocket zips — the catalog snapshot that
/// makes a transfer self-contained across catalogs (acceptance test A: user B imports and
/// burns songs outside their enabled sources).
///
/// WIRE FORMAT: the PWA's `MusicItem[]` EXACTLY (src/types/model.ts) — the PWA importer
/// hands items.json raw to `bulkPutItems`, so field names and null-conventions are
/// load-bearing (R8): songs use `name` (never `title`), `lengthMs` (never `length`),
/// REQUIRED `sentimentKeywords` (write `[]`) and `explicit` (write `false`), and
/// bpm/key/camelot are explicitly `null` when unknown (the PWA's "pending analysis"
/// convention). `appleMusicId` rides as an extra field (not in the PWA model; harmless
/// there, consumed by the native importer for streaming/rip). `sourceId` is the fixed
/// sentinel `src_imported` — the PWA-side importer upserts a matching "Imported"
/// DataSource so the items are source-scoped and deletable there (R9).
///
/// DECODE is lenient dict-parsing (never Codable-strict): it accepts the PWA's shape,
/// this file's own output, and unknown extra fields; unknown/missing pieces degrade to
/// nil rather than failing the import.
enum PortableItems {

    /// The fixed `sourceId` stamped on exported items (see header).
    static let sourceId = "src_imported"

    struct Song: Equatable {
        var id: String
        var name: String
        var artist: String
        var albumId: String?
        var trackNumber: Int?
        var year: Int?
        var lengthMs: Int?
        var bpm: Double?
        var key: String?
        var camelot: String?
        var appleMusicId: String?
    }

    struct Album: Equatable {
        var id: String
        var name: String
        var artist: String
        var trackIds: [String]
        var coverArtUrl: String?
        var genre: String?
        var year: Int?
    }

    struct Payload: Equatable {
        var songs: [Song] = []
        var albums: [Album] = []
        var isEmpty: Bool { songs.isEmpty && albums.isEmpty }
    }

    // MARK: - Collect (which ids travel)

    /// The catalog ids a playlist (+ its bundled pockets) references: song nodes + album
    /// nodes recursively, plus every pocket's songIds/albumIds. Studio ids never travel
    /// (spec §8 — user creations must not leak through the transfer surface).
    static func referencedIds(playlist: Playlist, pockets: [Pocket]) -> (songs: Set<String>, albums: Set<String>) {
        var songIds = Set<String>(), albumIds = Set<String>()
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                switch n.kind {
                case .song: if let id = n.songId, !StudioFactory.isStudioId(id) { songIds.insert(id) }
                case .album: if let id = n.albumId { albumIds.insert(id) }
                case .sequence: walk(n.children ?? [])
                default: break
                }
            }
        }
        for seq in playlist.sequences { walk(seq.children ?? []) }
        collect(pockets: pockets, into: &songIds, albums: &albumIds)
        return (songIds, albumIds)
    }

    /// The catalog ids a pocket bundle references (root + DAG-expanded children).
    static func referencedIds(pocket: Pocket, children: [Pocket]) -> (songs: Set<String>, albums: Set<String>) {
        var songIds = Set<String>(), albumIds = Set<String>()
        collect(pockets: [pocket] + children, into: &songIds, albums: &albumIds)
        return (songIds, albumIds)
    }

    private static func collect(pockets: [Pocket], into songIds: inout Set<String>, albums albumIds: inout Set<String>) {
        for p in pockets {
            for id in p.songIds where !StudioFactory.isStudioId(id) { songIds.insert(id) }
            for id in p.albumIds { albumIds.insert(id) }
        }
    }

    // MARK: - Encode (export)

    /// Build the items.json bytes for the referenced ids, closed over the catalog the
    /// PWA way (two passes: albums pull their track songs, songs pull their album) so
    /// album nodes expand and songs resolve their album names on the importing device.
    static func encode(songIds: Set<String>, albumIds: Set<String>,
                       songsById: [String: IndexSong], albumsById: [String: IndexAlbum]) throws -> Data {
        var songs: [String: IndexSong] = [:]
        var albums: [String: IndexAlbum] = [:]
        for id in songIds { if let s = songsById[id] { songs[id] = s } }
        for id in albumIds { if let a = albumsById[id] { albums[id] = a } }
        for _ in 0..<2 {
            var need = false
            for a in albums.values {
                for t in a.trackList where songs[t] == nil {
                    if let s = songsById[t] { songs[t] = s; need = true }
                }
            }
            for s in songs.values {
                if let aid = s.albumId, albums[aid] == nil, let a = albumsById[aid] {
                    albums[aid] = a; need = true
                }
            }
            if !need { break }
        }

        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        var items: [[String: Any]] = []
        for a in albums.values.sorted(by: { $0.id < $1.id }) {
            var obj: [String: Any] = [
                "id": a.id, "sourceId": sourceId, "type": "album",
                "createdAt": now, "updatedAt": now,
                "artist": a.artist, "name": a.name, "trackIds": a.trackList,
            ]
            if let v = a.coverArt { obj["coverArtUrl"] = v }
            if let sources = a.coverArtSources, !sources.isEmpty {
                obj["coverArtSources"] = sources.map { s -> [String: Any] in
                    var d: [String: Any] = ["type": s.type, "url": s.url]
                    if let c = s.cors { d["cors"] = c }
                    return d
                }
            }
            if let v = a.genre { obj["genre"] = v }
            if let v = a.year { obj["year"] = v }
            items.append(obj)
        }
        for s in songs.values.sorted(by: { $0.id < $1.id }) {
            var obj: [String: Any] = [
                "id": s.id, "sourceId": sourceId, "type": "song",
                "createdAt": now, "updatedAt": now,
                "artist": s.artist, "name": s.name,
                // PWA-required fields with PWA null-conventions (R8).
                "sentimentKeywords": s.sentimentKeywords ?? [],
                "explicit": s.explicit ?? false,
                "bpm": s.bpm ?? NSNull(),
                "key": s.key ?? NSNull(),
                "camelot": s.camelot ?? NSNull(),
            ]
            if let v = s.albumId { obj["albumId"] = v }
            if let v = s.trackNumber { obj["trackNumber"] = v }
            if let v = s.year { obj["year"] = v }
            if let v = s.length { obj["lengthMs"] = v }
            if let v = s.appleMusicId { obj["appleMusicId"] = v }
            items.append(obj)
        }
        return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
    }

    // MARK: - Decode (import)

    /// Lenient parse of an items.json payload (PWA or native). Unknown fields ignored;
    /// a row missing its essentials (id + name/title + artist for songs; + trackIds for
    /// albums) is skipped, never fatal.
    static func decode(_ data: Data) -> Payload {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return Payload()
        }
        var out = Payload()
        for obj in raw {
            guard let id = obj["id"] as? String else { continue }
            let type = obj["type"] as? String
            let name = (obj["name"] as? String) ?? (obj["title"] as? String)
            let artist = obj["artist"] as? String
            if type == "album" || (type == nil && obj["trackIds"] != nil) {
                guard let name, let artist else { continue }
                let trackIds = (obj["trackIds"] as? [String]) ?? (obj["trackList"] as? [String]) ?? []
                let cover = (obj["coverArtUrl"] as? String)
                    ?? ((obj["coverArtSources"] as? [[String: Any]])?.first?["url"] as? String)
                    ?? (obj["coverArt"] as? String)
                out.albums.append(Album(id: id, name: name, artist: artist, trackIds: trackIds,
                                        coverArtUrl: cover,
                                        genre: obj["genre"] as? String,
                                        year: intValue(obj["year"])))
            } else if type == "song" || type == nil {
                guard let name, let artist else { continue }
                out.songs.append(Song(id: id, name: name, artist: artist,
                                      albumId: obj["albumId"] as? String,
                                      trackNumber: intValue(obj["trackNumber"]),
                                      year: intValue(obj["year"]),
                                      lengthMs: intValue(obj["lengthMs"]) ?? intValue(obj["length"]),
                                      bpm: doubleValue(obj["bpm"]),
                                      key: obj["key"] as? String,
                                      camelot: obj["camelot"] as? String,
                                      appleMusicId: obj["appleMusicId"] as? String))
            }
        }
        return out
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}
