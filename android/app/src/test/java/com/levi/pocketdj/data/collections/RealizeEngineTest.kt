package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The realize contract for Phase 2 (specs/playlists-ui.md §11.2/§13): realize
 * expands the template LITERALLY — pocket DAG resolution (order/dedupe/cycle
 * guard), placement ordering + dedupe, text-cue semantics, album expansion — and
 * tags every track `explicit`. The harmonic engine (pocket sampling, targetMs
 * budgets, autofill bridging) is DEFERRED, so those paths must NOT run; the pure
 * harmonic primitives (Harmonics/Interpolate/Prng) are still unit-tested below
 * against the deferred engine's math.
 */
class RealizeEngineTest {

    private fun song(
        id: String,
        bpm: Double? = 120.0,
        camelot: String? = "8A",
        lengthMs: Long? = 60_000,
        albumId: String? = null,
        artist: String = "Artist $id",
    ) = IndexSong(
        id = id,
        albumId = albumId,
        artist = artist,
        name = "Song $id",
        bpm = bpm,
        camelot = camelot,
        length = lengthMs,
    )

    private fun ctx(
        songs: List<IndexSong>,
        albums: List<IndexAlbum> = emptyList(),
        pockets: List<Pocket> = emptyList(),
    ) = RealizeCtx(
        songsById = songs.associateBy { it.id },
        albumsById = albums.associateBy { it.id },
        pocketsById = pockets.associateBy { it.id },
        candidates = songs.filter { it.bpm != null && it.camelot != null },
    )

    private fun songNode(songId: String, repeat: Int? = null) = PlaylistNode(
        nodeId = CollectionsFactory.newNodeId(),
        kind = PlaylistNode.Kind.SONG,
        songId = songId,
        repeatCount = repeat,
    )

    private fun playlist(vararg chapters: PlaylistNode) = Playlist(
        id = "pls_test",
        name = "Test",
        sequences = chapters.toList(),
        createdAt = 0.0,
        updatedAt = 0.0,
    )

    private fun chapter(name: String, targetMs: Long? = null, vararg children: PlaylistNode) =
        PlaylistNode(
            nodeId = "nd_$name",
            kind = PlaylistNode.Kind.SEQUENCE,
            name = name,
            targetMs = targetMs,
            children = children.toList(),
        )

    // MARK: Pocket DAG resolution

    @Test
    fun resolvePocketSongs_ordersOwnThenAlbumsThenChildren_dedupes_guardsCycles() {
        val album = IndexAlbum(id = "alb_1", artist = "A", name = "Album", trackList = listOf("sng_3", "sng_4"))
        val parent = Pocket(
            id = "pkt_parent",
            name = "Parent",
            songIds = listOf("sng_1", "sng_missing"),
            albumIds = listOf("alb_1"),
            childPocketIds = listOf("pkt_child"),
        )
        // Child references the parent back — a cycle — and repeats sng_1.
        val child = Pocket(
            id = "pkt_child",
            name = "Child",
            songIds = listOf("sng_1", "sng_5"),
            childPocketIds = listOf("pkt_parent"),
        )
        val context = ctx(
            songs = listOf("sng_1", "sng_3", "sng_4", "sng_5").map { song(it) },
            albums = listOf(album),
            pockets = listOf(parent, child),
        )
        val seen = HashSet<String>()
        val resolved = RealizeEngine.resolvePocketSongs("pkt_parent", context, seen)
        assertEquals(listOf("sng_1", "sng_3", "sng_4", "sng_5"), resolved.map { it.id })
    }

    @Test
    fun pocketReferencedTwice_contributesOnce_acrossTheWholePlaylist() {
        val pocket = Pocket(id = "pkt_1", name = "P", songIds = listOf("sng_1", "sng_2"))
        val pocketNode = PlaylistNode(
            nodeId = "nd_p1",
            kind = PlaylistNode.Kind.POCKET,
            pocketId = "pkt_1",
        )
        val pocketNode2 = pocketNode.copy(nodeId = "nd_p2")
        val context = ctx(songs = listOf(song("sng_1"), song("sng_2")), pockets = listOf(pocket))

        val perf = RealizeEngine.realize(
            playlist(chapter("One", null, pocketNode), chapter("Two", null, pocketNode2)),
            context,
            seed = "seed",
        )
        assertEquals(2, perf.tracks.size) // second reference dedupes to nothing
        // Literal realize: pocket songs place in DAG order, all EXPLICIT (no
        // "pocket" badge, no harmonic re-order — the engine is deferred).
        assertEquals(listOf("sng_1", "sng_2"), perf.tracks.map { it.songId })
        assertTrue(perf.tracks.all { it.source == TrackSource.EXPLICIT && it.pocketId == null })
        assertEquals(2, perf.stats.explicit)
        assertEquals(0, perf.stats.pocketSampled)
    }

    // MARK: Placement ordering / dedupe / text

    @Test
    fun realize_placesExplicitOrder_expandsAlbums_dedupesSongs_keepsTexts() {
        val album = IndexAlbum(id = "alb_1", artist = "A", name = "Album", trackList = listOf("sng_2", "sng_3"))
        val context = ctx(
            songs = listOf(song("sng_1"), song("sng_2"), song("sng_3")),
            albums = listOf(album),
        )
        val perf = RealizeEngine.realize(
            playlist(
                chapter(
                    "Main",
                    null,
                    songNode("sng_1"),
                    PlaylistNode(nodeId = "nd_alb", kind = PlaylistNode.Kind.ALBUM, albumId = "alb_1"),
                    songNode("sng_2"), // dup — dropped
                    PlaylistNode(nodeId = "nd_t", kind = PlaylistNode.Kind.TEXT, text = "mic"),
                    PlaylistNode(nodeId = "nd_t2", kind = PlaylistNode.Kind.TEXT, text = "mic"),
                    songNode("sng_missing"),
                ),
            ),
            context,
            seed = "seed",
        )
        assertEquals(listOf("sng_1", "sng_2", "sng_3", "", ""), perf.tracks.map { it.songId })
        // Text cues are never deduped, carry isText, and contribute 0 to totals.
        assertEquals(true, perf.tracks[3].isText)
        assertEquals("mic", perf.tracks[3].name)
        assertEquals(3 * 60_000L, perf.totalMs)
        assertEquals(3 + 2, perf.stats.explicit)
    }

    @Test
    fun realize_snapshotsTrackFields_andStoresRepeats() {
        val context = ctx(songs = listOf(song("sng_1", bpm = 98.5, camelot = "5B", lengthMs = 123_000)))
        val perf = RealizeEngine.realize(
            playlist(chapter("Main", null, songNode("sng_1", repeat = 3), songNode("sng_1", repeat = 1))),
            context,
            seed = "seed",
        )
        val track = perf.tracks.single()
        assertEquals("Song sng_1", track.name)
        assertEquals("Artist sng_1", track.artist)
        assertEquals(98.5, track.bpm!!, 0.0)
        assertEquals("5B", track.camelot)
        assertEquals(123_000L, track.lengthMs)
        assertEquals(3, track.repeatCount)
        // totalMs deliberately does NOT multiply repeats (iOS parity).
        assertEquals(123_000L, perf.totalMs)
    }

    // MARK: Determinism (literal — pocket resolves to its DAG order, seed-inert)

    @Test
    fun realize_pocketPlacesLiteralDagOrder_seedInert() {
        val songs = (1..12).map {
            song("sng_$it", bpm = 80.0 + it * 7, camelot = "${(it % 12) + 1}A")
        }
        val pocket = Pocket(id = "pkt_1", name = "P", songIds = songs.map { it.id })
        val context = ctx(songs = songs, pockets = listOf(pocket))
        val pl = playlist(
            chapter("Main", null, PlaylistNode(nodeId = "nd_p", kind = PlaylistNode.Kind.POCKET, pocketId = "pkt_1")),
        )

        val a = RealizeEngine.realize(pl, context, seed = "seed-a").tracks.map { it.songId }
        val b = RealizeEngine.realize(pl, context, seed = "seed-a").tracks.map { it.songId }
        assertEquals(a, b)
        // Literal DAG order (the pocket's own songIds, in order) — NOT a harmonic
        // chain anchored by the seed.
        assertEquals(songs.map { it.id }, a)
        // A different seed produces the IDENTICAL literal order (seed is inert).
        val c = RealizeEngine.realize(pl, context, seed = "seed-b").tracks.map { it.songId }
        assertEquals(a, c)
    }

    @Test
    fun realize_seedDefaultsAreEquivalent() {
        val songs = (1..5).map { song("sng_$it") }
        val pocket = Pocket(id = "pkt_1", name = "P", songIds = songs.map { it.id })
        val context = ctx(songs = songs, pockets = listOf(pocket))
        val pl = playlist(
            chapter("Main", null, PlaylistNode(nodeId = "nd_p", kind = PlaylistNode.Kind.POCKET, pocketId = "pkt_1")),
        )
        val defaulted = RealizeEngine.realize(pl, context).tracks.map { it.songId }
        val explicit = RealizeEngine.realize(pl, context, seed = pl.id).tracks.map { it.songId }
        assertEquals(explicit, defaulted)
        assertEquals(songs.map { it.id }, defaulted)
    }

    // MARK: Deferred engine — budgets + autofill must NOT run on P2

    @Test
    fun budget_isDeferred_pocketPlacesAllSongsLiterally() {
        val songs = (1..6).map { song("sng_$it", lengthMs = 60_000) }
        val pocket = Pocket(id = "pkt_1", name = "P", songIds = songs.map { it.id })
        val context = ctx(songs = songs, pockets = listOf(pocket))
        // A targetMs is present but IGNORED — the whole pocket places (no prefix
        // fitting / sampling on P2).
        val pl = playlist(
            chapter(
                "Main",
                150_000,
                PlaylistNode(nodeId = "nd_p", kind = PlaylistNode.Kind.POCKET, pocketId = "pkt_1"),
            ),
        )
        val perf = RealizeEngine.realize(pl, context, seed = "seed")
        assertEquals(songs.map { it.id }, perf.tracks.map { it.songId })
        assertTrue(perf.tracks.all { it.source == TrackSource.EXPLICIT })
        assertEquals(0, perf.stats.pocketSampled)
    }

    @Test
    fun autofill_isDeferred_noBridgeTracksInjected() {
        // Two placed songs + a spare catalog candidate that the engine WOULD
        // bridge with — literal realize must not inject it.
        val placedA = song("sng_a", bpm = 100.0, camelot = "8A")
        val placedB = song("sng_b", bpm = 140.0, camelot = "2B")
        val bridge = song("sng_bridge", bpm = 120.0, camelot = "5A")
        val context = ctx(songs = listOf(placedA, placedB, bridge))
        val pl = playlist(
            chapter("Main", 200_000, songNode("sng_a"), songNode("sng_b")),
        )
        val perf = RealizeEngine.realize(pl, context, seed = "seed")
        assertEquals(listOf("sng_a", "sng_b"), perf.tracks.map { it.songId })
        assertTrue(perf.tracks.all { it.source == TrackSource.EXPLICIT })
        assertEquals(0, perf.stats.autofilled)
    }

    @Test
    fun subSequences_expandLiterally() {
        val songs = (1..4).map { song("sng_$it", lengthMs = 60_000) }
        val context = ctx(songs = songs)
        val sub = PlaylistNode(
            nodeId = "nd_sub",
            kind = PlaylistNode.Kind.SEQUENCE,
            name = "Sub",
            children = listOf(songNode("sng_2"), songNode("sng_3"), songNode("sng_4")),
        )
        // Sub-chapter songs place explicitly, in order, after the parent's — no
        // budget gating (targetMs is inert on P2).
        val perf = RealizeEngine.realize(
            playlist(chapter("Main", 120_000, songNode("sng_1"), sub)),
            context,
            seed = "seed",
        )
        assertEquals(listOf("sng_1", "sng_2", "sng_3", "sng_4"), perf.tracks.map { it.songId })
    }

    // MARK: Harmonic helpers (spot checks)

    @Test
    fun camelotDistance_matchesTheWheelRules() {
        assertEquals(0.0, Harmonics.camelotDistance("8A", "8A")!!, 0.0)
        assertEquals(1.0, Harmonics.camelotDistance("8A", "9A")!!, 0.0) // adjacent same mode
        assertEquals(1.0, Harmonics.camelotDistance("8A", "8B")!!, 0.0) // relative major/minor
        assertEquals(2.0, Harmonics.camelotDistance("8A", "9B")!!, 0.0) // gap 1 + mode
        assertEquals(1.0, Harmonics.camelotDistance("12A", "1A")!!, 0.0) // wraps
        assertEquals(7.0, Harmonics.camelotDistance("1A", "7B")!!, 0.0) // max
        assertEquals(null, Harmonics.camelotDistance("8A", "junk"))
    }

    @Test
    fun bpmDistance_isHalfDoubleTimeAware() {
        assertEquals(0.0, Harmonics.bpmDistance(120.0, 120.0)!!, 1e-12)
        assertEquals(0.0, Harmonics.bpmDistance(120.0, 60.0)!!, 1e-12) // folds ×2
        assertEquals(0.0, Harmonics.bpmDistance(60.0, 240.0)!!, 1e-12) // folds ÷2 twice
        assertEquals(10.0 / 30.0, Harmonics.bpmDistance(60.0, 100.0)!!, 1e-12) // folds 100→50, gap 10
        assertEquals(1.0, Harmonics.bpmDistance(100.0, 135.0)!!, 1e-12) // folded gap 32.5 clamps
        assertEquals(null, Harmonics.bpmDistance(null, 120.0))
        assertEquals(null, Harmonics.bpmDistance(120.0, 0.0))
    }

    @Test
    fun harmonicDistance_dropsNilAxes_renormalizes_allNilIsNeutral() {
        val mixableA = song("a", bpm = 120.0, camelot = "8A")
        val mixableB = song("b", bpm = 120.0, camelot = "8A", artist = "Artist a")
        val bare = IndexSong(id = "x", artist = "", name = "X")
        val bare2 = IndexSong(id = "y", artist = "", name = "Y")

        // Same key/bpm/artist + same (null→Other) genre + neutral sentiment.
        val d = Harmonics.harmonicDistance(mixableA.copy(artist = "Z"), mixableB.copy(artist = "Z"))
        assertTrue(d < 0.1)
        // No signal at all → 0.5 exactly on every axis-empty pair… artist axis
        // still resolves (empty ⇒ distance 1), genre Other==Other ⇒ 0, so the
        // blend stays defined; the ALL-nil case needs zero weights:
        val neutral = Harmonics.harmonicDistance(
            bare,
            bare2,
            weights = HarmonicWeights(key = 1.0, bpm = 1.0, genre = 0.0, artist = 0.0, sentiment = 0.0),
        )
        assertEquals(0.5, neutral, 0.0)
    }

    @Test
    fun interpolatePath_stepsTheShorterArc_andLerpsBpm() {
        val from = song("f", bpm = 100.0, camelot = "12A")
        val to = song("t", bpm = 140.0, camelot = "2A")
        val points = Interpolate.interpolatePath(from, to, 1, fromGenre = null, toGenre = null)
        val p = points.single()
        assertEquals(120.0, p.bpm!!, 1e-9)
        assertEquals("1A", p.camelot) // wraps 12A → 1A → 2A, midpoint 1A
        assertEquals(0.5, p.ratio, 1e-12)
        assertTrue(Interpolate.interpolatePath(from, to, 0, null, null).isEmpty())
    }
}
