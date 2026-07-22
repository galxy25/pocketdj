package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong

/**
 * realize() — Playlist TEMPLATE → concrete, ordered, FROZEN performance
 * (a Setlist's tracks).
 *
 * **Phase 2 realizes LITERALLY** (specs/playlists-ui.md §11.2/§13): every node
 * expands in template order —
 *   • songs place in order (deduped by songId),
 *   • albums expand to their `trackList` (in order),
 *   • pocket refs resolve to their DAG order via [resolvePocketSongs] (own songs
 *     → album tracks → nested pockets, cycle-guarded/deduped),
 *   • free-text cues place verbatim,
 * and EVERY placed track is tagged `source = explicit` (no "pocket"/"↔ bridge"
 * badges). The realized order therefore MATCHES the playlist's static membership
 * and what ▶ Play feeds `playNow` — the §10 invariant.
 *
 * The iOS RealizeEngine's harmonic pocket-sampling, budget prefix-fitting, and
 * autofill/bridging are **DEFERRED** on Android (their pure math primitives —
 * [Harmonics] / [Interpolate] / [Prng] — are ported and unit-tested so lighting
 * the engine up later is a contained change). The setlist doc shape is identical
 * either way, so a future engine slice needs no migration.
 *
 * PURE: no store, no I/O, no input mutation.
 */

/** Read-only catalog + collections the engine resolves ids against. */
data class RealizeCtx(
    val songsById: Map<String, IndexSong>,
    val albumsById: Map<String, IndexAlbum>,
    val pocketsById: Map<String, Pocket>,
    /** Autofill pool: every catalog song with BOTH bpm AND camelot. */
    val candidates: List<IndexSong>,
) {
    /** A song's genre — lives on its ALBUM in the native catalog. */
    fun genreOf(song: IndexSong): String? = song.albumId?.let { albumsById[it]?.genre }
}

data class RealizeStats(
    val sequences: Int = 0,
    val explicit: Int = 0,
    val pocketSampled: Int = 0,
    val autofilled: Int = 0,
)

data class RealizePerformance(
    val tracks: List<SetlistTrack>,
    val totalMs: Long,
    val stats: RealizeStats,
)

object RealizeEngine {
    /** Fallback per-track duration (ms) when a song carries no length. */
    const val DEFAULT_TRACK_MS = 210_000L

    /** Internal placement record (pre-snapshot). */
    private data class Placed(
        val song: IndexSong? = null, // absent for a free-text cue
        val text: String? = null,
        val source: TrackSource,
        val sequenceName: String,
        val note: String? = null,
        val repeatCount: Int? = null,
    )

    // MARK: Pocket resolution — flatten the DAG to its effective songs

    /**
     * Flatten a pocket (and its nested pockets) into its effective ordered song
     * list: own songIds, then songs of own albumIds (album.trackList), then
     * recursively each child pocket. CYCLE-GUARDED via `seen` (shared across the
     * whole walk — a pocket contributes ONCE even if referenced twice); DEDUPED
     * by songId, first-seen order preserved. Missing ids are skipped.
     */
    fun resolvePocketSongs(pocketId: String, ctx: RealizeCtx, seen: MutableSet<String>): List<IndexSong> {
        val out = ArrayList<IndexSong>()
        val added = HashSet<String>()
        collectPocket(pocketId, ctx, seen, out, added)
        return out
    }

    private fun collectPocket(
        pocketId: String,
        ctx: RealizeCtx,
        seen: MutableSet<String>,
        out: MutableList<IndexSong>,
        added: MutableSet<String>,
    ) {
        if (!seen.add(pocketId)) return // cycle / revisit guard
        val pocket = ctx.pocketsById[pocketId] ?: return

        for (songId in pocket.songIds) pushSong(ctx.songsById[songId], out, added)
        for (albumId in pocket.albumIds) {
            val album = ctx.albumsById[albumId] ?: continue
            for (trackId in album.trackList) pushSong(ctx.songsById[trackId], out, added)
        }
        for (childId in pocket.childPocketIds) collectPocket(childId, ctx, seen, out, added)
    }

    private fun pushSong(song: IndexSong?, out: MutableList<IndexSong>, added: MutableSet<String>) {
        if (song == null || !added.add(song.id)) return
        out.add(song)
    }

    // MARK: Sequence realization (LITERAL — the harmonic engine is deferred, §13)

    private fun realizeSequence(
        seq: PlaylistNode,
        ctx: RealizeCtx,
        used: MutableSet<String>,
    ): List<Placed> {
        val placed = ArrayList<Placed>()
        val name = seq.name ?: "Set"
        // targetMs budgets, pocket sampling, and autofill are DEFERRED on P2 —
        // every node expands in literal template order.
        for (node in seq.children.orEmpty()) {
            placeNode(node, name, ctx, used, placed)
        }
        return placed
    }

    private fun placeNode(
        node: PlaylistNode,
        sequenceName: String,
        ctx: RealizeCtx,
        used: MutableSet<String>,
        placed: MutableList<Placed>,
    ) {
        when (node.kind) {
            PlaylistNode.Kind.SONG -> {
                val song = node.songId?.let { ctx.songsById[it] } ?: return
                addPlaced(
                    placed,
                    used,
                    Placed(
                        song = song,
                        source = TrackSource.EXPLICIT,
                        sequenceName = sequenceName,
                        note = node.note,
                        repeatCount = node.repeatCount,
                    ),
                )
            }
            PlaylistNode.Kind.TEXT -> {
                // Free-text cue: no audio, always placed (never deduped), 0 ms.
                placed.add(
                    Placed(
                        text = node.text,
                        source = TrackSource.EXPLICIT,
                        sequenceName = sequenceName,
                        note = node.note,
                    ),
                )
            }
            PlaylistNode.Kind.ALBUM -> {
                val album = node.albumId?.let { ctx.albumsById[it] } ?: return
                for (trackId in album.trackList) {
                    val song = ctx.songsById[trackId] ?: continue
                    addPlaced(
                        placed,
                        used,
                        Placed(song = song, source = TrackSource.EXPLICIT, sequenceName = sequenceName),
                    )
                }
            }
            PlaylistNode.Kind.POCKET -> {
                // LITERAL: resolve the pocket's DAG order and place each song as
                // EXPLICIT (no harmonic re-order, no "pocket" badge, no budget
                // sampling). Matches ▶ Play's resolved order (§10 invariant).
                val id = node.pocketId ?: return
                val seen = HashSet<String>()
                for (song in resolvePocketSongs(id, ctx, seen)) {
                    addPlaced(
                        placed,
                        used,
                        Placed(song = song, source = TrackSource.EXPLICIT, sequenceName = sequenceName),
                    )
                }
            }
            PlaylistNode.Kind.SEQUENCE -> {
                val sub = realizeSequence(node, ctx, used)
                placed.addAll(sub) // already deduped + used-tracked inside
            }
        }
    }

    /** Append a placement unless its song is already present anywhere (dedupe by songId). */
    private fun addPlaced(placed: MutableList<Placed>, used: MutableSet<String>, p: Placed) {
        val song = p.song ?: run {
            placed.add(p) // text never deduped
            return
        }
        if (!used.add(song.id)) return
        placed.add(p)
    }

    // MARK: Snapshot → SetlistTrack

    private fun snapshot(p: Placed): SetlistTrack {
        val s = p.song ?: return SetlistTrack(
            songId = "",
            artist = "",
            name = p.text ?: "",
            bpm = null,
            camelot = null,
            source = p.source,
            sequenceName = p.sequenceName,
            note = p.note,
            isText = true,
        )
        return SetlistTrack(
            songId = s.id,
            artist = s.artist,
            name = s.name,
            bpm = s.bpm,
            camelot = s.camelot,
            lengthMs = s.length,
            source = p.source,
            sequenceName = p.sequenceName,
            note = p.note,
            isText = null,
            pocketId = null, // P2 literal realize never emits pocket-sourced tracks
            mixSuggestions = null,
            repeatCount = CollectionMembership.storedRepeat(p.repeatCount ?: 1),
        )
    }

    // MARK: realize()

    /**
     * Realize a Playlist template into a literal, all-explicit performance.
     *
     * `seed`/`weights` are accepted for API stability (and so `Setlist.seed`
     * round-trips) but are INERT under P2's literal realize — the deterministic
     * harmonic engine that consumed them is deferred (§13). Output depends only
     * on the template + catalog, so re-realizing always reproduces the tracks.
     */
    @Suppress("UNUSED_PARAMETER")
    fun realize(
        playlist: Playlist,
        ctx: RealizeCtx,
        seed: String? = null,
        weights: HarmonicWeights = DEFAULT_WEIGHTS,
    ): RealizePerformance {
        val used = HashSet<String>()
        val tracks = ArrayList<SetlistTrack>()
        var explicit = 0
        var pocketSampled = 0
        var autofilled = 0

        for (seq in playlist.sequences) {
            val placed = realizeSequence(seq, ctx, used)
            for (p in placed) {
                tracks.add(snapshot(p))
                when (p.source) {
                    TrackSource.EXPLICIT -> explicit++
                    TrackSource.POCKET -> pocketSampled++
                    TrackSource.AUTOFILL -> autofilled++
                }
            }
        }

        // NOTE: totalMs here does NOT multiply by repeatCount (iOS parity —
        // the store's edit paths recompute via shownMs, which does).
        var totalMs = 0L
        for (t in tracks) {
            if (t.isText == true) continue
            val l = t.lengthMs
            totalMs += if (l != null && l > 0) l else DEFAULT_TRACK_MS
        }

        return RealizePerformance(
            tracks = tracks,
            totalMs = totalMs,
            stats = RealizeStats(
                sequences = playlist.sequences.size,
                explicit = explicit,
                pocketSampled = pocketSampled,
                autofilled = autofilled,
            ),
        )
    }

    /**
     * Wrap [realize] into a fresh Setlist. The track SELECTION is fully seeded;
     * the only non-deterministic bits — the new id and generatedAt — live here.
     */
    fun buildSetlist(
        playlist: Playlist,
        ctx: RealizeCtx,
        seed: String? = null,
        name: String? = null,
        weights: HarmonicWeights = DEFAULT_WEIGHTS,
        now: Double,
    ): Setlist {
        val theSeed = seed ?: playlist.id
        val perf = realize(playlist, ctx, seed = theSeed, weights = weights)
        return Setlist(
            id = CollectionsFactory.newSetlistId(),
            playlistId = playlist.id,
            name = name,
            seed = theSeed,
            generatedAt = now,
            totalMs = perf.totalMs,
            tracks = perf.tracks,
        )
    }
}
