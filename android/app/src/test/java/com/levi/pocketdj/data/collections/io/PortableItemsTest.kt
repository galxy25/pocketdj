package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PortableItemsTest {
    private val songs = mapOf(
        "sng_1" to IndexSong(id = "sng_1", albumId = "alb_1", artist = "A", name = "One", trackNumber = 1, year = 1999, length = 123_000, appleMusicId = "555"),
        "sng_2" to IndexSong(id = "sng_2", albumId = "alb_1", artist = "A", name = "Two", bpm = 120.5, key = "C", camelot = "8B", sentimentKeywords = listOf("warm"), explicit = true),
    )
    private val albums = mapOf("alb_1" to IndexAlbum(id = "alb_1", artist = "A", name = "Album", trackList = listOf("sng_1", "sng_2"), genre = "Soul", year = 1999, coverArt = "c.jpg"))

    private fun encode(songIds: Set<String>, albumIds: Set<String> = emptySet()): JsonArray =
        IoTestSupport.json(PortableItems.encode(songIds, albumIds, songs, albums, nowMs = 1_000)) as JsonArray

    @Test
    fun nullConventions() {
        val arr = encode(setOf("sng_1"))
        val s = arr.map { it as JsonObject }.first { (it["id"] as JsonPrimitive).content == "sng_1" }
        // PWA field names + REQUIRED fields + explicit nulls for unknown analysis.
        assertEquals("src_imported", (s["sourceId"] as JsonPrimitive).content)
        assertEquals("song", (s["type"] as JsonPrimitive).content)
        assertEquals("One", (s["name"] as JsonPrimitive).content)
        assertTrue(s["title"] == null)
        assertEquals("123000", (s["lengthMs"] as JsonPrimitive).content)
        assertTrue(s["length"] == null)
        assertEquals(JsonArray(emptyList()), s["sentimentKeywords"])
        assertEquals(false, (s["explicit"] as JsonPrimitive).booleanOrNull)
        assertEquals(JsonNull, s["bpm"]); assertEquals(JsonNull, s["key"]); assertEquals(JsonNull, s["camelot"])
        assertEquals("555", (s["appleMusicId"] as JsonPrimitive).content)
        assertEquals("1000", (s["createdAt"] as JsonPrimitive).content)
    }

    @Test
    fun knownAnalysisAndKeywordsTravel() {
        val arr = encode(setOf("sng_2"))
        val s = arr.map { it as JsonObject }.first { (it["id"] as JsonPrimitive).content == "sng_2" }
        assertEquals("120.5", (s["bpm"] as JsonPrimitive).content)
        assertEquals("8B", (s["camelot"] as JsonPrimitive).content)
        assertEquals(true, (s["explicit"] as JsonPrimitive).booleanOrNull)
        assertEquals(1, (s["sentimentKeywords"] as JsonArray).size)
    }

    @Test
    fun closureOverCatalog_albumsPullTracks_songsPullAlbum_albumsFirstSortedById() {
        val arr = encode(emptySet(), setOf("alb_1"))
        assertEquals(listOf("alb_1", "sng_1", "sng_2"), arr.map { ((it as JsonObject)["id"] as JsonPrimitive).content })
        val album = arr[0] as JsonObject
        assertEquals("c.jpg", (album["coverArtUrl"] as JsonPrimitive).content)
        assertEquals(2, (album["trackIds"] as JsonArray).size)
        // and the reverse: a song pulls its album
        val viaSong = encode(setOf("sng_1"))
        assertEquals(listOf("alb_1", "sng_1", "sng_2"), viaSong.map { ((it as JsonObject)["id"] as JsonPrimitive).content })
    }

    @Test
    fun lenientDecode() {
        val raw = """
            [ {"id":"sng_a","type":"song","title":"Legacy","artist":"Z","length":90000,"bpm":100,"extra":{"x":1}},
              {"id":"sng_b","name":"Typeless","artist":"Z"},
              {"id":"alb_a","type":"album","name":"Alb","artist":"Z","trackList":["sng_a"],"coverArtSources":[{"url":"u.jpg"}],"year":2001.0},
              "junk", 5, {"id":"sng_bad","type":"song"}, {"name":"no id","artist":"Z"},
              {"id":"alb_bad","type":"album","name":"NoArtist"} ]
        """.trimIndent().toByteArray()
        val p = PortableItems.decode(raw)
        assertEquals(listOf("sng_a", "sng_b"), p.songs.map { it.id })
        assertEquals("Legacy", p.songs[0].name)           // title fallback
        assertEquals(90_000L, p.songs[0].lengthMs)        // length fallback
        assertEquals(100.0, p.songs[0].bpm!!, 0.0)
        assertNull(p.songs[1].bpm)
        assertEquals(listOf("alb_a"), p.albums.map { it.id })
        assertEquals(listOf("sng_a"), p.albums[0].trackIds)  // trackList fallback
        assertEquals("u.jpg", p.albums[0].coverArtUrl)       // coverArtSources[0].url
        assertEquals(2001, p.albums[0].year)
    }

    @Test
    fun garbageDecodesToEmpty() {
        assertTrue(PortableItems.decode("not json".toByteArray()).isEmpty)
        assertTrue(PortableItems.decode("{\"a\":1}".toByteArray()).isEmpty)
        assertFalse(PortableItems.decode("[{\"id\":\"s\",\"name\":\"n\",\"artist\":\"a\"}]".toByteArray()).isEmpty)
    }

    @Test
    fun studioIdsNeverTravel() {
        val pocket = com.levi.pocketdj.data.collections.Pocket(id = "p", songIds = listOf("sng_1", "smp_local", "ptn_x"), albumIds = listOf("alb_1"))
        val ids = PortableItems.referencedIds(pocket, emptyList())
        assertEquals(setOf("sng_1"), ids.songs)
        assertEquals(setOf("alb_1"), ids.albums)
    }
}
