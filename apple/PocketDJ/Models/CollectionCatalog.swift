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
//
// Runtime = Σ song.length (ms); a song with missing/zero length counts as 0 ms
// (so the figure is a floor — it never invents the engine's 210s fallback here,
// which is reserved for the realize budget, not a "library duration" readout).
struct CollectionCatalog {
    var songsById: [String: IndexSong]
    var albumsById: [String: IndexAlbum]
    var pocketsById: [String: Pocket]

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

    /// Resolve one playlist node to its contributed songs (album → tracks, pocket →
    /// resolvePocketSongs, sub-sequence → its children recursively). `seenPockets`
    /// is shared across the whole walk so a pocket counts ONCE per container even if
    /// referenced twice (matching realize's dedupe intent).
    private func songs(forNode node: PlaylistNode, seenPockets: inout Set<String>) -> [IndexSong] {
        switch node.kind {
        case .song:
            return node.songId.flatMap { songsById[$0] }.map { [$0] } ?? []
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
        for songId in pocket.songIds { push(songsById[songId], &out, &added) }
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
