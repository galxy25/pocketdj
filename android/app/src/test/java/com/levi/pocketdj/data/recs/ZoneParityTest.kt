package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.recs.ZoneEngine.Feedback
import com.levi.pocketdj.data.recs.ZoneEngine.Play
import com.levi.pocketdj.data.recs.ZoneEngine.Pool
import com.levi.pocketdj.data.recs.ZoneEngine.Tuning
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whole-catalog tests over `zone-fixture-catalog.json` (18 artists x 8 songs, 6 genres, tempo/key
 * on a third of the artists, timbre vectors on half the rows): the projection rules and the
 * cross-cutting invariants of both engines, on a catalog shaped like the real one (sparse optional
 * fields, clustered timbre).
 */
class ZoneParityTest {

    private class Fixture(val songs: List<IndexSong>, val albums: List<IndexAlbum>, val timbre: Map<String, Map<String, Double>>)

    private val fx: Fixture by lazy {
        val text = javaClass.getResourceAsStream("/recs/zone-fixture-catalog.json")!!.bufferedReader().readText()
        val root = PdjJson.lenient.parseToJsonElement(text).jsonObject
        Fixture(
            songs = PdjJson.lenient.decodeFromJsonElement<List<IndexSong>>(root.getValue("songs")),
            albums = PdjJson.lenient.decodeFromJsonElement<List<IndexAlbum>>(root.getValue("albums")),
            timbre = (root.getValue("timbre") as JsonObject).mapValues { (_, v) ->
                (v as JsonObject).mapValues { it.value.jsonPrimitive.content.toDouble() }
            },
        )
    }
    private val catalog: ZoneCatalog by lazy { ZoneCatalog.project(fx.songs, fx.albums.associateBy { it.id }) }
    private val noPlays: (String) -> Int = { 0 }
    private val now = 1_800_000_000_000.0
    private fun artistIds(a: Int) = fx.songs.filter { it.artist == "Artist %02d".format(a) }.map { it.id }

    // ── projection ──────────────────────────────────────────────────────────────────────

    @Test fun fixtureShapeIsWhatTheTestsAssume() {
        assertEquals(144, fx.songs.size)
        assertEquals(18, fx.albums.size)
        assertEquals(72, fx.timbre.size)
        assertEquals(144, catalog.tracks.size)
    }

    @Test fun projectionMapsGenreYearAndRawLabelsLikeZoneTracks() {
        val s0 = catalog.tracks.first { it.songId == fx.songs[0].id }
        assertEquals("Artist 00", s0.artistName)
        assertEquals("artist 00", s0.artistKey)
        assertEquals("Hip-Hop/Rap", s0.genreRaw) // RAW, uncollapsed
        assertEquals("hip-hop", s0.genre) // 16-bucket category
        // song 7 of every album has no song-level year ⇒ falls back to the album's
        val noYear = fx.songs.first { it.year == null }
        val album = fx.albums.first { it.id == noYear.albumId }
        assertEquals(album.year, catalog.tracks.first { it.songId == noYear.id }.year)
        // tempo/key survive only where the catalog has them
        assertNotNull(catalog.tracks.first { it.songId == fx.songs[0].id }.bpm)
        assertNull(catalog.tracks.first { it.artistName == "Artist 01" }.bpm)
    }

    @Test fun unclassifiableGenreMapsToNullAndStaysOutOfTheGenreMap() {
        val songs = listOf(
            IndexSong(id = "s1", albumId = "al1", artist = "A", name = "x"),
            IndexSong(id = "s2", albumId = "missing", artist = "A", name = "y", year = 1999),
            IndexSong(id = "s3", artist = "B", name = "z"),
        )
        val albums = mapOf("al1" to IndexAlbum(id = "al1", artist = "A", name = "Al", genre = "Zzqx Unclassifiable", year = 1984))
        val c = ZoneCatalog.project(songs, albums)
        val t1 = c.tracks[0]
        assertNull(t1.genre) // "Other" ⇒ null: the catch-all must not be a similarity signal
        assertEquals("Zzqx Unclassifiable", t1.genreRaw) // ...but the raw label is kept for variety
        assertEquals(1984, t1.year)
        assertNull(c.tracks[1].genreRaw)
        assertEquals(1999, c.tracks[1].year)
        assertTrue(c.genreBySongId.isEmpty())
    }

    @Test fun genreMapAndTracksNeverDisagree() {
        for (t in catalog.tracks) assertEquals(t.genre, catalog.genreBySongId[t.songId])
    }

    @Test fun versionKeysAreMemoizedPerCatalog() {
        assertSame(catalog.versionKeys, catalog.versionKeys)
        assertEquals(144, catalog.versionKeys.size)
    }

    @Test fun cacheRebuildsOnlyWhenTheRevisionMoves() {
        val cache = ZoneCatalogCache()
        var builds = 0
        val build = { builds++; catalog }
        val a = cache.get(1, build)
        val b = cache.get(1, build)
        assertSame(a, b)
        assertEquals(1, builds)
        cache.get(2, build)
        assertEquals(2, builds)
    }

    // ── suggestions over the catalog ────────────────────────────────────────────────────

    @Test fun suggestionsInvariantsHoldOnTheFixture() {
        val members = artistIds(0).take(5) // hip-hop crate
        val r = ZoneEngine.rank(members, catalog.tracks, noPlays, versions = catalog.versionKeys)
        assertTrue(r.ids.isNotEmpty())
        assertTrue(r.ids.size <= 25)
        assertTrue(r.ids.none { it in members })
        assertEquals(r.ids.size, r.ids.toSet().size)
        val byId = catalog.tracks.associateBy { it.songId }
        // admission gate artist-or-genre (no timbre passed ⇒ no sound door)
        assertTrue(r.ids.all { byId[it]!!.artistName == "Artist 00" || byId[it]!!.genre == "hip-hop" })
        assertTrue(r.soundAdmitted.isEmpty())
        // ≤ 3 per primary artist
        assertTrue(r.ids.groupBy { byId[it]!!.artistName }.values.all { it.size <= 3 })
        // deterministic
        assertEquals(r, ZoneEngine.rank(members, catalog.tracks, noPlays, versions = catalog.versionKeys))
    }

    @Test fun emptyTimbreIsPreV2AcrossEveryCrateInTheFixture() {
        val sparse = fx.timbre.entries.take(2).associate { it.key to it.value } // < 3 vectors anywhere
        val shut = Tuning(timbreGain = 0.0, soundAdmitMaxShare = 0.0)
        for (a in 0 until 18 step 3) {
            val members = artistIds(a)
            val plain = ZoneEngine.rank(members, catalog.tracks, noPlays)
            assertEquals("crate $a (sparse)", plain, ZoneEngine.rank(members, catalog.tracks, noPlays, timbre = sparse))
            val gated = ZoneEngine.rank(members, catalog.tracks, noPlays, tuning = shut, timbre = fx.timbre)
            assertEquals("crate $a (gain 0, door shut)", plain.ids, gated.ids)
        }
    }

    @Test fun timbreOnlyReordersAndTheDoorAdmitsOnlyFromOutsideTheGate() {
        val byId = catalog.tracks.associateBy { it.songId }
        // a crate whose analysed members cluster tightly: every analysed song of artist 4
        val members = artistIds(4)
        val withT = ZoneEngine.rank(members, catalog.tracks, noPlays, timbre = fx.timbre)
        val noT = ZoneEngine.rank(members, catalog.tracks, noPlays)
        assertTrue(withT.soundAdmitted.size <= 3)
        for (id in withT.soundAdmitted) {
            val t = byId[id]!!
            assertTrue(t.artistName != "Artist 04" && t.genre != byId[members[0]]!!.genre)
            assertTrue(fx.timbre.containsKey(id)) // the door needs an observed vector
        }
        // everything the metadata gate scored is still there: timbre adds at most the quota
        assertTrue(withT.ids.toSet().minus(withT.soundAdmitted).size >= noT.ids.size - 3)
        assertTrue(withT.ids.groupBy { byId[it]!!.artistName }.values.all { it.size <= 3 })
    }

    @Test fun explainedAndPlainRankingsAreOneAnswer() {
        val members = artistIds(2).take(4)
        val r = ZoneEngine.rank(members, catalog.tracks, noPlays, timbre = fx.timbre)
        val ex = ZoneEngine.explainedSuggestions(members, catalog.tracks, noPlays, timbre = fx.timbre)
        assertEquals(r.ids, ex.rows.map { it.songId })
        assertEquals(r.soundAdmitted, ex.soundAdmitted)
        assertTrue(ex.rows.all { it.why.isNotBlank() })
    }

    @Test fun eraWindowCaptionNamesTheCratesOwnYears() {
        val members = artistIds(0)
        val ex = ZoneEngine.suggestionsExplained(members, catalog.tracks, noPlays)
        val era = SimilarityFamilies.eraWindow(members.mapNotNull { id -> catalog.tracks.first { it.songId == id }.year?.toDouble() })!!
        val caption = ex.firstOrNull { it.why.startsWith("From this collection's") }
        if (caption != null) assertEquals("From this collection's ${era.lo.toInt()}–${era.hi.toInt()} era", caption.why)
    }

    // ── zone over the catalog ───────────────────────────────────────────────────────────

    private val day = 86_400_000.0

    @Test fun zoneInvariantsOnTheFixtureWithTempoAndTimbre() {
        val plays = listOf(
            Play(artistIds(0)[0], now - 2 * day), Play(artistIds(0)[1], now - 3 * day),
            Play(artistIds(3)[0], now - 1 * day), Play(artistIds(6)[2], now - 80 * day), // outside the window
            Play(artistIds(9)[1], now - 30 * 60_000.0), // 30 min ago: cooldown
        )
        val pc: (String) -> Int = { if (it == artistIds(12)[0]) 40 else 0 }
        val q = ZoneEngine.inDaZone(
            songs = fx.songs, genreBySongId = catalog.genreBySongId, plays = plays, playCount = pc,
            timbre = fx.timbre, nowMs = now,
        )
        assertTrue(q.count >= 30)
        assertEquals(q.count, q.songIds.toSet().size)
        assertFalse(artistIds(9)[1] in q.songIds)
        val artistOf = fx.songs.associate { it.id to it.artist }
        assertTrue(q.songIds.groupBy { artistOf[it] }.values.all { it.size <= 3 })
        val recent = setOf(artistIds(0)[0], artistIds(0)[1], artistIds(3)[0])
        assertTrue(q.picks.filter { it.pool == Pool.FAMILIAR }.all { it.songId in recent })
        assertTrue(q.rediscoveryShare >= 0.5)
        // the 80-day-old play is dormant ⇒ it may only ever appear as a rediscovery
        q.picks.firstOrNull { it.songId == artistIds(6)[2] }?.let { assertEquals(Pool.REDISCOVERY, it.pool) }
        // deterministic
        assertEquals(q, ZoneEngine.inDaZone(
            songs = fx.songs, genreBySongId = catalog.genreBySongId, plays = plays, playCount = pc,
            timbre = fx.timbre, nowMs = now,
        ))
    }

    @Test fun cloudShapingOverTheFixtureKeepsEveryLocalRule() {
        val server = fx.songs.map { it.id }.filterIndexed { i, _ -> i % 2 == 0 } + listOf("ghost")
        val q = ZoneEngine.shapeCloudRanking(
            songIds = server, songs = fx.songs,
            plays = listOf(Play(server[0], now - 3_600_000.0)), // cooling down
            feedback = Feedback(suppressed = setOf(server[1])),
            nowMs = now,
        )
        val artistOf = fx.songs.associate { it.id to it.artist }
        assertFalse("ghost" in q.songIds)
        assertFalse(server[0] in q.songIds)
        assertFalse(server[1] in q.songIds)
        assertTrue(q.songIds.groupBy { artistOf[it] }.values.all { it.size <= 3 })
        assertEquals(q.count, q.songIds.toSet().size)
        assertTrue(q.rediscoveryShare >= 0.5)
    }
}
