import Foundation

/// COLLECTION MEMBERSHIP, FLATTENED — the one place that turns the Pocket DAG + playlist
/// templates + source playlists into "which songs are in collection X" (effective membership:
/// album nodes expanded to their tracklists, child pockets flattened, deduped, first-seen order),
/// and the add history into "when was each CURRENT member last added".
///
/// Shared by the rec engine's `collectionsSnapshot` and the listening-pockets upload
/// (`ListeningPocketsCollectionsWire`), and read by "In the Pocket" (membership vectors). PURE:
/// every input is a value, so the whole thing is unit-testable and runs off the main actor.
///
/// Spec: docs/design/pockets-collections.md ("Membership vector", "Upload contract").
enum CollectionFlattener {

    /// One collection's effective membership.
    struct Collection: Equatable, Sendable {
        var id: String
        /// "pocket" | "playlist" | "source" (the wire's `kind`).
        var kind: String
        /// Display name — LOCAL ONLY (the rec snapshot carries it; the pockets upload never does).
        var name: String
        var songIds: [String]
    }

    /// What the flattener reads. `albumTracks` maps album id → its ordered track ids (absent ⇒ the
    /// album can't be expanded and contributes nothing).
    struct Source: Sendable {
        var pockets: [Pocket] = []
        var playlists: [Playlist] = []
        /// Read-only catalog playlists ("From your sources"): id, name, ordered members.
        var sourcePlaylists: [(id: String, name: String, songIds: [String])] = []
        var albumTracks: [String: [String]] = [:]
    }

    // MARK: - Membership

    /// Every collection, pockets first, then playlists, then source playlists. Uncapped (see
    /// `capped`). A pocket's songs: own songIds, album tracks, then child pockets (cycle-guarded,
    /// mirroring `CollectionCatalog.resolvePocketSongs`). A playlist's songs: every song / album /
    /// pocket leaf of every chapter, in order.
    static func flatten(_ src: Source) -> [Collection] {
        let pocketsById = Dictionary(src.pockets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Collection] = []
        out.reserveCapacity(src.pockets.count + src.playlists.count + src.sourcePlaylists.count)
        for p in src.pockets {
            out.append(Collection(id: p.id, kind: "pocket", name: p.name,
                                  songIds: pocketSongs(p.id, pocketsById: pocketsById, albumTracks: src.albumTracks)))
        }
        for pl in src.playlists {
            out.append(Collection(id: pl.id, kind: "playlist", name: pl.name,
                                  songIds: playlistSongs(pl, pocketsById: pocketsById, albumTracks: src.albumTracks)))
        }
        for s in src.sourcePlaylists {
            var seen = Set<String>()
            out.append(Collection(id: s.id, kind: "source", name: s.name,
                                  songIds: s.songIds.filter { seen.insert($0).inserted }))
        }
        return out
    }

    static func pocketSongs(_ id: String, pocketsById: [String: Pocket],
                            albumTracks: [String: [String]]) -> [String] {
        var out: [String] = []
        var added = Set<String>()
        var visited = Set<String>()
        collectPocket(id, pocketsById, albumTracks, &visited, &added, &out)
        return out
    }

    private static func collectPocket(_ id: String, _ pocketsById: [String: Pocket],
                                      _ albumTracks: [String: [String]], _ visited: inout Set<String>,
                                      _ added: inout Set<String>, _ out: inout [String]) {
        guard visited.insert(id).inserted, let p = pocketsById[id] else { return }
        for s in p.songIds where added.insert(s).inserted { out.append(s) }
        for a in p.albumIds { for s in albumTracks[a] ?? [] where added.insert(s).inserted { out.append(s) } }
        for c in p.childPocketIds { collectPocket(c, pocketsById, albumTracks, &visited, &added, &out) }
    }

    static func playlistSongs(_ pl: Playlist, pocketsById: [String: Pocket],
                              albumTracks: [String: [String]]) -> [String] {
        var out: [String] = []
        var added = Set<String>()
        var visited = Set<String>()
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                switch n.kind {
                case .song:
                    if let id = n.songId, added.insert(id).inserted { out.append(id) }
                case .album:
                    if let a = n.albumId { for s in albumTracks[a] ?? [] where added.insert(s).inserted { out.append(s) } }
                case .pocket:
                    if let p = n.pocketId { collectPocket(p, pocketsById, albumTracks, &visited, &added, &out) }
                case .text, .sequence:
                    break
                }
                if let kids = n.children { walk(kids) }
            }
        }
        walk(pl.sequences)
        return out
    }

    /// Trim to the server caps (≤ `collectionCap` collections, ≤ `songCap` songs each, ≤
    /// `totalCap` songs overall) — in order, so the hash describes what the server stores.
    static func capped(_ collections: [Collection], collectionCap: Int = 500, songCap: Int = 5_000,
                       totalCap: Int = 100_000) -> [Collection] {
        var budget = totalCap
        var out: [Collection] = []
        for c in collections.prefix(collectionCap) {
            let take = min(c.songIds.count, songCap, max(0, budget))
            budget -= take
            var t = c
            t.songIds = Array(c.songIds.prefix(take))
            out.append(t)
        }
        return out
    }

    // MARK: - Add history

    /// The song ids an activity item stands for in collection context: a pocket id → its flattened
    /// songs, an album id → its tracks, anything else → itself.
    static func expand(_ itemId: String, pocketsById: [String: Pocket], albumTracks: [String: [String]]) -> [String] {
        if pocketsById[itemId] != nil {
            return pocketSongs(itemId, pocketsById: pocketsById, albumTracks: albumTracks)
        }
        if let tracks = albumTracks[itemId] { return tracks }
        return [itemId]
    }

    /// Per collection id → song id → epoch ms that CURRENT member was last added.
    ///
    /// Replays the `.add` / `.remove` events in time order per (collection, ITEM): an item's add
    /// stands unless a later remove of that item follows it. Each standing item then credits the
    /// songs it expands to with its add time; a standing CHILD POCKET credits each song with the
    /// later of (pocket added here, song added to that pocket) — along that path the song became
    /// a member at whichever happened last. A song reachable through several standing items takes
    /// the EARLIEST path (it has been a member since then; a second route in is not a fresh add).
    /// Songs the log never saw added (older than the log, synced in, source playlists) are absent.
    static func addTimes(collections: [Collection], activity: [CollectionActivityStore.ActivityEvent],
                         pockets: [Pocket], albumTracks: [String: [String]]) -> [String: [String: Double]] {
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // collection → item → standing add time
        var standing: [String: [String: Double]] = [:]
        for e in activity.sorted(by: { $0.at < $1.at }) {
            guard let cid = e.collectionId, !cid.isEmpty else { continue }
            switch e.kind {
            case .add: standing[cid, default: [:]][e.itemId] = e.at
            case .remove: standing[cid]?[e.itemId] = nil
            default: continue
            }
        }
        var memo: [String: [String: Double]] = [:]
        func times(_ cid: String, _ visiting: inout Set<String>) -> [String: Double] {
            if let m = memo[cid] { return m }
            guard visiting.insert(cid).inserted else { return [:] }
            var out: [String: Double] = [:]
            for (item, t) in standing[cid] ?? [:] {
                if pocketsById[item] != nil {
                    let inner = times(item, &visiting)
                    for s in pocketSongs(item, pocketsById: pocketsById, albumTracks: albumTracks) {
                        let v = max(t, inner[s] ?? t)
                        out[s] = min(out[s] ?? v, v)
                    }
                } else {
                    for s in albumTracks[item] ?? [item] { out[s] = min(out[s] ?? t, t) }
                }
            }
            visiting.remove(cid)
            memo[cid] = out
            return out
        }
        var result: [String: [String: Double]] = [:]
        for c in collections {
            var visiting = Set<String>()
            let all = times(c.id, &visiting)
            guard !all.isEmpty else { continue }
            var mine: [String: Double] = [:]
            for s in c.songIds { if let t = all[s] { mine[s] = t } }
            if !mine.isEmpty { result[c.id] = mine }
        }
        return result
    }

    /// One song-level add/remove (an album / pocket add expands into one row per song).
    struct AddEvent: Equatable, Sendable {
        var songId: String
        var collectionId: String
        var atMs: Double
        /// "add" | "remove"
        var kind: String
    }

    /// Song-level add history: `.add` / `.remove` events with a collection, at or after
    /// `sinceMs`, expanded to songs, NEWEST FIRST, at most `cap` rows.
    static func addEvents(activity: [CollectionActivityStore.ActivityEvent], pockets: [Pocket],
                          albumTracks: [String: [String]], sinceMs: Double, cap: Int = 5_000) -> [AddEvent] {
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [AddEvent] = []
        for e in activity.sorted(by: { $0.at != $1.at ? $0.at > $1.at : $0.id.uuidString < $1.id.uuidString }) {
            guard out.count < cap else { break }
            guard e.at >= sinceMs, let cid = e.collectionId, !cid.isEmpty,
                  e.kind == .add || e.kind == .remove else { continue }
            for s in expand(e.itemId, pocketsById: pocketsById, albumTracks: albumTracks) where out.count < cap {
                out.append(AddEvent(songId: s, collectionId: cid, atMs: e.at, kind: e.kind.rawValue))
            }
        }
        return out
    }
}
