import Foundation

// MARK: - CollectionCatalog — pure count + runtime helpers for containers
//
// "How many songs, and how long, is this container?" — for a Playlist, a single
// chapter (sequence), or a Pocket. PURE + DETERMINISTIC (no store, no UI): it
// resolves ids against read-only catalog dictionaries, exactly like RealizeEngine.
//
// Definition of "songs in a container" (mirrors realize()'s expansion, minus the
// budget sampling / autofill — this is the FULL static membership):
//   • song node      → that song
//   • album node     → the album's trackList expanded to songs (in order)
//   • pocket node    → resolvePocketSongs (own songs, album tracks, then nested
//                      pockets — CYCLE-GUARDED, DEDUPED by songId)
//   • text / empty   → contributes nothing
//   • studio id      → a SYNTHESIZED pseudo-song (title + real length) when the
//                      optional `studio` lookup carries it (spec §8: counts/runtime
//                      INCLUDE studio items; a loop counts its real 4 s, never 0
//                      and never the engine's 210 s) — otherwise it drops like any
//                      unknown id. Callers that must stay catalog-only (rip/burn/
//                      CSV via CollectionsStore.songIds) strip studio ids AFTER
//                      this resolution; this type stays policy-free.
//
// Runtime = Σ song.length (ms); a song with missing/zero length counts as 0 ms
// (so the figure is a floor — it never invents the engine's 210s fallback here,
// which is reserved for the realize budget, not a "library duration" readout).
struct CollectionCatalog {
    var songsById: [String: IndexSong]
    var albumsById: [String: IndexAlbum]
    var pocketsById: [String: Pocket]
    /// STUDIO ids (`smp_`/`lp_`/`ptn_`) referenced by the collections, resolved to
    /// title + REAL lengthMs (threaded in by `CollectionsStore.catalog()` from its
    /// `studioLookup` seam; empty when unwired — the pre-Studio behavior exactly).
    var studio: [String: (title: String, lengthMs: Int)] = [:]

    /// Count + summed runtime of a list of resolved songs.
    struct Stats: Equatable {
        var count: Int = 0
        var runtimeMs: Int = 0
    }

    private func runtime(of songs: [IndexSong]) -> Int {
        songs.reduce(0) { $0 + (($1.length.map { $0 > 0 ? $0 : 0 }) ?? 0) }
    }

    private func stats(of songs: [IndexSong]) -> Stats {
        Stats(count: songs.count, runtimeMs: runtime(of: songs))
    }

    // MARK: Resolution

    /// Resolve one member id: the live catalog first, then a SYNTHESIZED pseudo-song
    /// for a studio id the `studio` lookup knows (its real length feeds `runtime`).
    /// nil ⇒ unknown to both worlds — dropped, as missing ids always were.
    private func song(for id: String) -> IndexSong? {
        if let s = songsById[id] { return s }
        if let info = studio[id] {
            return IndexSong.studioSynthetic(id: id, title: info.title, lengthMs: info.lengthMs)
        }
        return nil
    }

    /// Resolve one playlist node to its contributed songs (album → tracks, pocket →
    /// resolvePocketSongs, sub-sequence → its children recursively). `seenPockets`
    /// is shared across the whole walk so a pocket counts ONCE per container even if
    /// referenced twice (matching realize's dedupe intent).
    private func songs(forNode node: PlaylistNode, seenPockets: inout Set<String>) -> [IndexSong] {
        switch node.kind {
        case .song:
            // `song(for:)` (not a raw songsById hit) so a studio node counts too.
            return node.songId.flatMap { song(for: $0) }.map { [$0] } ?? []
        case .album:
            guard let id = node.albumId, let album = albumsById[id] else { return [] }
            return album.trackList.compactMap { songsById[$0] }
        case .pocket:
            guard let id = node.pocketId else { return [] }
            return resolvePocketSongs(id, seen: &seenPockets)
        case .text:
            return []
        case .sequence:
            return (node.children ?? []).flatMap { songs(forNode: $0, seenPockets: &seenPockets) }
        }
    }

    /// Songs contributed by a chapter's children (album/pocket expanded). Pockets are
    /// cycle-guarded + counted once across the chapter.
    func songs(inChapter chapter: PlaylistNode) -> [IndexSong] {
        var seen = Set<String>()
        return (chapter.children ?? []).flatMap { songs(forNode: $0, seenPockets: &seen) }
    }

    /// All songs contributed by a playlist (every chapter). A pocket referenced in
    /// more than one chapter is counted once for the whole playlist.
    func songs(inPlaylist playlist: Playlist) -> [IndexSong] {
        var seen = Set<String>()
        return playlist.sequences.flatMap { ($0.children ?? []).flatMap { songs(forNode: $0, seenPockets: &seen) } }
    }

    /// A pocket's effective ordered songs — own songIds, then album tracks, then
    /// nested child pockets — CYCLE-GUARDED and DEDUPED by songId (mirrors
    /// RealizeEngine.resolvePocketSongs, kept here so count/runtime needs no engine ctx).
    func resolvePocketSongs(_ pocketId: String, seen: inout Set<String>) -> [IndexSong] {
        var out: [IndexSong] = []
        var added = Set<String>()
        collectPocket(pocketId, &seen, &out, &added)
        return out
    }

    private func collectPocket(_ pocketId: String, _ seen: inout Set<String>,
                               _ out: inout [IndexSong], _ added: inout Set<String>) {
        if !seen.insert(pocketId).inserted { return }   // cycle / revisit guard
        guard let pocket = pocketsById[pocketId] else { return }
        // `song(for:)` so a pocket's studio members (loops/samples riding songIds —
        // spec §8) contribute their real title + length to counts/runtime/playNow.
        for songId in pocket.songIds { push(song(for: songId), &out, &added) }
        for albumId in pocket.albumIds {
            guard let album = albumsById[albumId] else { continue }
            for trackId in album.trackList { push(songsById[trackId], &out, &added) }
        }
        for childId in pocket.childPocketIds { collectPocket(childId, &seen, &out, &added) }
    }

    private func push(_ song: IndexSong?, _ out: inout [IndexSong], _ added: inout Set<String>) {
        guard let song, added.insert(song.id).inserted else { return }
        out.append(song)
    }

    // MARK: Public stats

    func stats(forPlaylist playlist: Playlist) -> Stats { stats(of: songs(inPlaylist: playlist)) }
    func stats(forChapter chapter: PlaylistNode) -> Stats { stats(of: songs(inChapter: chapter)) }
    func stats(forPocket pocketId: String) -> Stats {
        var seen = Set<String>()
        return stats(of: resolvePocketSongs(pocketId, seen: &seen))
    }
}

extension CollectionCatalog.Stats {
    /// "12 songs · 47:31" — the standard container subtitle (count + Fmt.duration).
    var summary: String {
        "\(count) song\(count == 1 ? "" : "s") · \(Fmt.duration(runtimeMs))"
    }
}

extension IndexSong {
    /// A synthesized catalog entry for a STUDIO id (sample/loop/pattern — spec §8).
    /// `IndexSong` is Decodable-only (no memberwise init), so — exactly like
    /// `IndexSong.minimal` — it's built by decoding a JSON object; this variant
    /// extends the dict with `length` (MANDATORY: the caller's real lengthMs, so a
    /// 4 s loop never counts as 0 in stats nor realizes as the engine's 210 s
    /// default) plus `bpm`/`camelot` when known (they let realize's harmonic math
    /// see the item; they do NOT admit it to the autofill pool — candidates are
    /// assembled from the catalog before injection, see CollectionsStore.makeCtx).
    /// Artist is the fixed "Studio" label every studio surface shows.
    static func studioSynthetic(id: String, title: String, lengthMs: Int,
                                bpm: Double? = nil, camelot: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": title, "artist": "Studio", "length": lengthMs]
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        // Force-unwrap is safe for the same reason as `IndexSong.minimal`: every key is
        // a JSON scalar and every IndexSong field beyond id/name/artist is optional.
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }
}
