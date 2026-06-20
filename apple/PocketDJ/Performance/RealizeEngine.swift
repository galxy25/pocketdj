import Foundation

// MARK: - realize() — THE CORE of Playlists/Pockets/Setlists
//
// Pure port of `src/engine/realize.ts`. Turns a Playlist TEMPLATE (an ordered tree
// of sequences/songs/albums/pocket refs/text cues) into a concrete, ordered, FROZEN
// performance (a Setlist's tracks):
//   • albums expand to their tracks (in order),
//   • pocket refs resolve LIVE (so edits to a pocket auto-update the next play) and,
//     when a sequence has a time budget, SAMPLE a coherent harmonic subset to fit,
//   • temporal gaps under a budget are AUTOFILLED with harmonic bridge tracks from
//     the catalog (smoothing the roughest transitions first).
//
// PURE: no store, no UI, no network, no input mutation. DETERMINISTIC: all randomness
// comes from PRNG.seededRng(seed ?? playlist.id), so the same seed reproduces the
// exact same setlist (the seed is what Setlist.seed stores).

/// Read-only catalog + collections the engine resolves ids against.
struct RealizeCtx {
    var songsById: [String: IndexSong]
    var albumsById: [String: IndexAlbum]
    var pocketsById: [String: Pocket]
    /// Autofill pool: the full catalog of songs that have BOTH bpm AND camelot.
    var candidates: [IndexSong]

    /// A song's genre — lives on its album in the native catalog (nil if unknown).
    func genre(of song: IndexSong) -> String? {
        song.albumId.flatMap { albumsById[$0]?.genre }
    }
}

struct RealizeOptions {
    var seed: String?
    var weights: HarmonicWeights = DEFAULT_WEIGHTS
}

struct RealizeStats: Equatable {
    var sequences = 0
    var explicit = 0
    var pocketSampled = 0
    var autofilled = 0
}

struct Performance {
    var tracks: [SetlistTrack]
    var totalMs: Int
    var stats: RealizeStats
}

enum RealizeEngine {
    /// Fallback per-track duration (ms) when a song carries no length.
    static let defaultTrackMs = 210_000
    /// Hard ceiling on autofill inserts per sequence — a safety valve against
    /// pathological candidate pools.
    static let autofillCap = 200

    // MARK: Internal placement record (pre-snapshot)

    private struct Placed {
        var song: IndexSong?     // absent for a free-text cue
        var text: String?
        var source: TrackSource
        var pocketId: String?
        var sequenceName: String
        var note: String?
    }

    /// Duration a song contributes to the budget + totals.
    private static func songMs(_ song: IndexSong) -> Int {
        if let l = song.length, l > 0 { return l }
        return defaultTrackMs
    }
    private static func placedItemMs(_ p: Placed) -> Int { p.song.map(songMs) ?? 0 }
    private static func placedMs(_ placed: [Placed]) -> Int { placed.reduce(0) { $0 + placedItemMs($1) } }

    // MARK: Pocket resolution — flatten the DAG to its effective songs

    /// Flatten a pocket (and its nested pockets) into its effective ordered song
    /// list: own songIds, then songs of own albumIds (album.trackList → songsById),
    /// then recursively each child pocket — in that order. CYCLE-GUARDED via `seen`;
    /// DEDUPED by songId, first-seen order preserved. Missing ids are skipped.
    static func resolvePocketSongs(_ pocketId: String, _ ctx: RealizeCtx,
                                   seen: inout Set<String>) -> [IndexSong] {
        var out: [IndexSong] = []
        var added = Set<String>()
        collectPocket(pocketId, ctx, &seen, &out, &added)
        return out
    }

    private static func collectPocket(_ pocketId: String, _ ctx: RealizeCtx,
                                      _ seen: inout Set<String>, _ out: inout [IndexSong],
                                      _ added: inout Set<String>) {
        if seen.contains(pocketId) { return }   // cycle / revisit guard
        seen.insert(pocketId)
        guard let pocket = ctx.pocketsById[pocketId] else { return }

        for songId in pocket.songIds { pushSong(ctx.songsById[songId], &out, &added) }
        for albumId in pocket.albumIds {
            guard let album = ctx.albumsById[albumId] else { continue }
            for trackId in album.trackList { pushSong(ctx.songsById[trackId], &out, &added) }
        }
        for childId in pocket.childPocketIds { collectPocket(childId, ctx, &seen, &out, &added) }
    }

    private static func pushSong(_ song: IndexSong?, _ out: inout [IndexSong], _ added: inout Set<String>) {
        guard let song, !added.contains(song.id) else { return }
        added.insert(song.id)
        out.append(song)
    }

    // MARK: Pocket sampling + harmonic chaining

    /// Order songs as a coherent harmonic chain anchored at `anchorIdx`, then greedily
    /// nearest-neighbour by harmonicDistance. Returns a fresh array.
    private static func harmonicChain(_ songs: [IndexSong], anchorIdx: Int,
                                      _ ctx: RealizeCtx, _ weights: HarmonicWeights) -> [IndexSong] {
        let n = songs.count
        if n <= 1 { return songs }

        var used = [Bool](repeating: false, count: n)
        let idx = ((anchorIdx % n) + n) % n
        var chain = [songs[idx]]
        used[idx] = true
        var current = songs[idx]

        for _ in 1..<n {
            var bestJ = -1
            var bestDist = Double.infinity
            for j in 0..<n where !used[j] {
                let d = Harmonics.harmonicDistance(current, songs[j],
                                                   genreA: ctx.genre(of: current), genreB: ctx.genre(of: songs[j]),
                                                   weights: weights)
                if d < bestDist { bestDist = d; bestJ = j }
            }
            if bestJ < 0 { break }
            used[bestJ] = true
            current = songs[bestJ]
            chain.append(current)
        }
        return chain
    }

    /// Prefix of a chain whose cumulative duration fits `budgetMs`. Always returns ≥1
    /// song when the chain is non-empty and budget > 0.
    private static func fitPrefix(_ chain: [IndexSong], budgetMs: Int) -> [IndexSong] {
        if chain.isEmpty || budgetMs <= 0 { return [] }
        var out: [IndexSong] = []
        var used = 0
        for song in chain {
            let ms = songMs(song)
            if !out.isEmpty && used + ms > budgetMs { break }
            out.append(song)
            used += ms
        }
        return out
    }

    // MARK: Sequence realization

    /// Realize one sequence (chapter). `inheritedRemainingMs` is the budget left in
    /// the PARENT at the point this (sub-)sequence runs (.max == ∞ at top level). The
    /// effective budget is min(own targetMs, inherited).
    private static func realizeSequence(
        _ seq: PlaylistNode, _ ctx: RealizeCtx, _ rng: () -> Double,
        _ weights: HarmonicWeights, _ used: inout Set<String>,
        inheritedRemainingMs: Int = .max
    ) -> [Placed] {
        var placed: [Placed] = []
        let name = seq.name ?? "Set"
        let ownTarget = (seq.targetMs.map { $0 > 0 ? $0 : .max }) ?? .max
        let targetMs = min(ownTarget, inheritedRemainingMs)
        let hasBudget = targetMs != .max && targetMs > 0

        for node in seq.children ?? [] {
            let remaining = hasBudget ? targetMs - placedMs(placed) : .max
            placeNode(node, name, ctx, rng, weights, &used, &placed, remaining)
        }

        if hasBudget { autofill(&placed, name, ctx, weights, &used, targetMs) }
        return placed
    }

    private static func placeNode(
        _ node: PlaylistNode, _ sequenceName: String, _ ctx: RealizeCtx,
        _ rng: () -> Double, _ weights: HarmonicWeights,
        _ used: inout Set<String>, _ placed: inout [Placed], _ remainingMs: Int
    ) {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = ctx.songsById[id] {
                addPlaced(&placed, &used, Placed(song: song, source: .explicit, sequenceName: sequenceName, note: node.note))
            }
        case .text:
            // Free-text cue: no audio, always placed (never deduped), 0 ms.
            placed.append(Placed(text: node.text, source: .explicit, sequenceName: sequenceName, note: node.note))
        case .album:
            guard let id = node.albumId, let album = ctx.albumsById[id] else { return }
            for trackId in album.trackList {
                if let song = ctx.songsById[trackId] {
                    addPlaced(&placed, &used, Placed(song: song, source: .explicit, sequenceName: sequenceName))
                }
            }
        case .pocket:
            guard let id = node.pocketId else { return }
            var seen = Set<String>()
            let effective = resolvePocketSongs(id, ctx, seen: &seen)
            if effective.isEmpty { return }
            let anchorIdx = Int(rng() * Double(effective.count))
            let chain = harmonicChain(effective, anchorIdx: anchorIdx, ctx, weights)
            let chosen = remainingMs == .max ? chain : fitPrefix(chain, budgetMs: remainingMs)
            for song in chosen {
                addPlaced(&placed, &used, Placed(song: song, source: .pocket, pocketId: id, sequenceName: sequenceName))
            }
        case .sequence:
            let sub = realizeSequence(node, ctx, rng, weights, &used, inheritedRemainingMs: remainingMs)
            placed.append(contentsOf: sub)   // already deduped + used-tracked inside
        }
    }

    /// Append a placement unless its song is already present anywhere (dedupe by songId).
    private static func addPlaced(_ placed: inout [Placed], _ used: inout Set<String>, _ p: Placed) {
        guard let song = p.song else { placed.append(p); return }   // text never deduped
        if used.contains(song.id) { return }
        used.insert(song.id)
        placed.append(p)
    }

    // MARK: Autofill — bridge the worst seams first

    /// Fill the remaining budget by repeatedly bridging the WORST adjacent transition:
    /// rank placed pairs (i,i+1) by harmonicDistance (worst first), interpolate a
    /// midpoint target, snap the nearest unused mixable candidate that FITS the budget.
    /// Re-rank + repeat. Stops when the budget can't fit the shortest candidate, no
    /// seam yields a fitting bridge, or the safety cap trips.
    private static func autofill(
        _ placed: inout [Placed], _ sequenceName: String, _ ctx: RealizeCtx,
        _ weights: HarmonicWeights, _ used: inout Set<String>, _ targetMs: Int
    ) {
        if placed.count < 2 { return }

        for _ in 0..<autofillCap {
            let remaining = targetMs - placedMs(placed)
            guard let shortest = shortestUsableMs(ctx.candidates, used) else { break }
            if remaining < shortest { break }

            // Rank seams worst-first; skip those adjacent to a text cue.
            var seams: [Int] = []
            for i in 0..<(placed.count - 1) where placed[i].song != nil && placed[i + 1].song != nil { seams.append(i) }
            seams.sort { i, j in
                seamDistance(placed, j, ctx, weights) > seamDistance(placed, i, ctx, weights)
            }

            var insertedAt = -1
            var bridgeSong: IndexSong?
            for i in seams {
                let a = placed[i].song!, b = placed[i + 1].song!
                guard let target = Interpolate.interpolatePath(a, b, 1,
                    fromGenre: ctx.genre(of: a), toGenre: ctx.genre(of: b)).first else { continue }
                let bridge = Interpolate.nearestCandidate(target, candidates: ctx.candidates, used: used,
                    genreOf: { ctx.genre(of: $0) }, weights: weights, maxMs: remaining)
                guard let bridge, !used.contains(bridge.id) else { continue }
                insertedAt = i
                bridgeSong = bridge
                break
            }

            guard insertedAt >= 0, let bridgeSong else { break }
            placed.insert(Placed(song: bridgeSong, source: .autofill, sequenceName: sequenceName), at: insertedAt + 1)
            used.insert(bridgeSong.id)
        }
    }

    private static func seamDistance(_ placed: [Placed], _ i: Int, _ ctx: RealizeCtx, _ weights: HarmonicWeights) -> Double {
        let a = placed[i].song!, b = placed[i + 1].song!
        return Harmonics.harmonicDistance(a, b, genreA: ctx.genre(of: a), genreB: ctx.genre(of: b), weights: weights)
    }

    /// Smallest contributing duration among candidates not yet used (nil if none usable).
    private static func shortestUsableMs(_ candidates: [IndexSong], _ used: Set<String>) -> Int? {
        var minMs: Int?
        for c in candidates {
            if used.contains(c.id) { continue }
            guard c.bpm != nil, c.camelot != nil else { continue }   // must be mixable
            let ms = songMs(c)
            if minMs == nil || ms < minMs! { minMs = ms }
        }
        return minMs
    }

    // MARK: Snapshot → SetlistTrack

    private static func snapshot(_ p: Placed) -> SetlistTrack {
        guard let s = p.song else {
            return SetlistTrack(songId: "", artist: "", name: p.text ?? "", bpm: nil, camelot: nil,
                                source: p.source, sequenceName: p.sequenceName, note: p.note, isText: true)
        }
        return SetlistTrack(
            songId: s.id, artist: s.artist, name: s.name,
            bpm: s.bpm, camelot: s.camelot, lengthMs: s.length,
            source: p.source, sequenceName: p.sequenceName, note: p.note,
            isText: nil, pocketId: p.pocketId, mixSuggestions: nil
        )
    }

    // MARK: realize()

    /// Realize a Playlist template into a concrete ordered Performance. Deterministic
    /// per `opts.seed ?? playlist.id`.
    static func realize(_ playlist: Playlist, _ ctx: RealizeCtx, _ opts: RealizeOptions = RealizeOptions()) -> Performance {
        let seed = opts.seed ?? playlist.id
        let weights = opts.weights
        let rng = PRNG.seededRng(seed)

        var used = Set<String>()
        var tracks: [SetlistTrack] = []
        var stats = RealizeStats(sequences: playlist.sequences.count)

        for seq in playlist.sequences {
            let placed = realizeSequence(seq, ctx, rng, weights, &used)
            for p in placed {
                tracks.append(snapshot(p))
                switch p.source {
                case .explicit: stats.explicit += 1
                case .pocket:   stats.pocketSampled += 1
                case .autofill: stats.autofilled += 1
                }
            }
        }

        var totalMs = 0
        for t in tracks {
            if t.isText == true { continue }
            totalMs += (t.lengthMs.map { $0 > 0 ? $0 : defaultTrackMs }) ?? defaultTrackMs
        }

        return Performance(tracks: tracks, totalMs: totalMs, stats: stats)
    }

    /// Wrap realize() into a fresh Setlist (a persisted performance instance). The
    /// track SELECTION is fully seeded; the only non-deterministic bits — the new id
    /// and generatedAt — live HERE in the wrapper.
    static func buildSetlist(_ playlist: Playlist, _ ctx: RealizeCtx,
                             seed: String? = nil, name: String? = nil,
                             weights: HarmonicWeights = DEFAULT_WEIGHTS, now: Double) -> Setlist {
        let theSeed = seed ?? playlist.id
        let perf = realize(playlist, ctx, RealizeOptions(seed: theSeed, weights: weights))
        return Setlist(
            id: CollectionsFactory.newSetlistId(),
            playlistId: playlist.id,
            name: name,
            seed: theSeed,
            generatedAt: now,
            totalMs: perf.totalMs,
            tracks: perf.tracks
        )
    }
}
