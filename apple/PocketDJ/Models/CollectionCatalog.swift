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
    /// STUDIO ids (`smp_`/`lp_`/`ptn_`) resolved to title + REAL lengthMs — LAZY, consulted
    /// only for an id that misses `songsById` and looks like a studio id. It used to be a
    /// prebuilt dictionary, which meant `CollectionsStore.catalog()` had to walk every pocket's
    /// members and every playlist's whole node tree just to populate it — the cost of the
    /// ENTIRE collections document, paid on every `catalog()` call, and `catalog()` is called
    /// once per row inside the Collections list body. Studio ids are rare, so resolving on
    /// demand does strictly less work and needs no cache (hence no invalidation bugs).
    /// nil = unwired, the pre-Studio behavior exactly. Takes `CollectionsStore.studioLookup`'s
    /// exact shape so the seam threads through untouched; only title + length matter here
    /// (bpm/camelot ride the synthesized song for the realize path, not for counts).
    var studioLookup: ((String) -> (title: String, lengthMs: Int, bpm: Double?, camelot: String?)?)?

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

    /// One song's contribution to a `Stats` fold — the same arithmetic `runtime(of:)` does,
    /// applied without materializing an array.
    private static func fold(_ song: IndexSong, into stats: inout Stats) {
        stats.count += 1
        stats.runtimeMs += (song.length.map { $0 > 0 ? $0 : 0 }) ?? 0
    }

    // MARK: Resolution

    /// Resolve one member id: the live catalog first, then a SYNTHESIZED pseudo-song
    /// for a studio id the `studio` lookup knows (its real length feeds `runtime`).
    /// nil ⇒ unknown to both worlds — dropped, as missing ids always were.
    private func song(for id: String) -> IndexSong? {
        if let s = songsById[id] { return s }
        // Gate on the id SHAPE before calling the seam, exactly as the old prebuilt table did
        // (`studioEntries` only added ids passing `StudioFactory.isStudioId`) — so a plain
        // unknown catalog id still drops without touching StudioStore.
        guard StudioFactory.isStudioId(id), let info = studioLookup?(id) else { return nil }
        return IndexSong.studioSynthetic(id: id, title: info.title, lengthMs: info.lengthMs)
    }

    /// Resolve one playlist node to its contributed songs (album → tracks, pocket →
    /// resolvePocketSongs, sub-sequence → its children recursively). `seenPockets`
    /// is shared across the whole walk so a pocket counts ONCE per container even if
    /// referenced twice (matching realize's dedupe intent).
    // The resolution walk is written ONCE, streaming each resolved song to a `sink`. The
    // ordered-array accessors below collect into an array; `stats(…)` folds into a counter
    // without allocating anything. Before this split, a subtitle that only needed "N songs ·
    // 2h 25m" materialized the collection's entire membership as IndexSong VALUES — a
    // ~20-field struct with three optional arrays — which for a converted pocket mirroring a
    // large Apple Music playlist meant tens of thousands of struct copies per render, per row.
    private func emit(forNode node: PlaylistNode, seenPockets: inout Set<String>,
                      _ sink: (IndexSong) -> Void) {
        switch node.kind {
        case .song:
            // `song(for:)` (not a raw songsById hit) so a studio node counts too.
            if let id = node.songId, let s = song(for: id) { sink(s) }
        case .album:
            guard let id = node.albumId, let album = albumsById[id] else { return }
            for trackId in album.trackList { if let s = songsById[trackId] { sink(s) } }
        case .pocket:
            guard let id = node.pocketId else { return }
            emitPocket(id, seen: &seenPockets, sink)
        case .text:
            return
        case .sequence:
            for child in node.children ?? [] { emit(forNode: child, seenPockets: &seenPockets, sink) }
        }
    }

    /// Every song a playlist contributes, streamed in play order. `seen` is shared across the
    /// whole walk so a pocket contributes ONCE per container even if referenced twice.
    private func emit(inPlaylist playlist: Playlist, _ sink: (IndexSong) -> Void) {
        var seen = Set<String>()
        for sequence in playlist.sequences {
            for node in sequence.children ?? [] { emit(forNode: node, seenPockets: &seen, sink) }
        }
    }

    private func emit(inChapter chapter: PlaylistNode, _ sink: (IndexSong) -> Void) {
        var seen = Set<String>()
        for node in chapter.children ?? [] { emit(forNode: node, seenPockets: &seen, sink) }
    }

    /// Songs contributed by a chapter's children (album/pocket expanded). Pockets are
    /// cycle-guarded + counted once across the chapter.
    func songs(inChapter chapter: PlaylistNode) -> [IndexSong] {
        var out: [IndexSong] = []
        emit(inChapter: chapter) { out.append($0) }
        return out
    }

    /// All songs contributed by a playlist (every chapter). A pocket referenced in
    /// more than one chapter is counted once for the whole playlist.
    func songs(inPlaylist playlist: Playlist) -> [IndexSong] {
        var out: [IndexSong] = []
        emit(inPlaylist: playlist) { out.append($0) }
        return out
    }

    /// A pocket's effective ordered songs — own songIds, then album tracks, then
    /// nested child pockets — CYCLE-GUARDED and DEDUPED by songId (mirrors
    /// RealizeEngine.resolvePocketSongs, kept here so count/runtime needs no engine ctx).
    func resolvePocketSongs(_ pocketId: String, seen: inout Set<String>) -> [IndexSong] {
        var out: [IndexSong] = []
        emitPocket(pocketId, seen: &seen) { out.append($0) }
        return out
    }

    /// Streaming form of `resolvePocketSongs`. `added` (the songId dedupe) is per-call, exactly
    /// as it was when this built a fresh array — it is the pocket-subtree's dedupe, while
    /// `seen` is the cross-container cycle guard.
    private func emitPocket(_ pocketId: String, seen: inout Set<String>, _ sink: (IndexSong) -> Void) {
        var added = Set<String>()
        collectPocket(pocketId, &seen, &added, sink)
    }

    private func collectPocket(_ pocketId: String, _ seen: inout Set<String>,
                               _ added: inout Set<String>, _ sink: (IndexSong) -> Void) {
        if !seen.insert(pocketId).inserted { return }   // cycle / revisit guard
        guard let pocket = pocketsById[pocketId] else { return }
        // `song(for:)` so a pocket's studio members (loops/samples riding songIds —
        // spec §8) contribute their real title + length to counts/runtime/playNow.
        for songId in pocket.songIds { push(song(for: songId), &added, sink) }
        for albumId in pocket.albumIds {
            guard let album = albumsById[albumId] else { continue }
            for trackId in album.trackList { push(songsById[trackId], &added, sink) }
        }
        for childId in pocket.childPocketIds { collectPocket(childId, &seen, &added, sink) }
    }

    private func push(_ song: IndexSong?, _ added: inout Set<String>, _ sink: (IndexSong) -> Void) {
        guard let song, added.insert(song.id).inserted else { return }
        sink(song)
    }

    // MARK: Public stats

    func stats(forPlaylist playlist: Playlist) -> Stats {
        var s = Stats()
        emit(inPlaylist: playlist) { Self.fold($0, into: &s) }
        return s
    }
    func stats(forChapter chapter: PlaylistNode) -> Stats {
        var s = Stats()
        emit(inChapter: chapter) { Self.fold($0, into: &s) }
        return s
    }
    func stats(forPocket pocketId: String) -> Stats {
        var seen = Set<String>()
        var s = Stats()
        emitPocket(pocketId, seen: &seen) { Self.fold($0, into: &s) }
        return s
    }
}

extension CollectionCatalog.Stats {
    /// "12 songs · 2h 25m" — the standard container subtitle (count + Fmt.longDuration).
    var summary: String {
        "\(count) song\(count == 1 ? "" : "s") · \(Fmt.longDuration(runtimeMs))"
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
    /// Artist is the performer label every studio surface shows (the user's "PocketDJ name",
    /// defaulting to "Studio" — passed in by the caller from `CollectionsStore.studioArtist`).
    static func studioSynthetic(id: String, title: String, lengthMs: Int, artist: String = "Studio",
                                bpm: Double? = nil, camelot: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": title, "artist": artist, "length": lengthMs]
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        // Force-unwrap is safe for the same reason as `IndexSong.minimal`: every key is
        // a JSON scalar and every IndexSong field beyond id/name/artist is optional.
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }
}
