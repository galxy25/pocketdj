package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.Pocket
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PocketZipTest {
    private val kid = Pocket(id = "pkt_kid", name = "Kid", songIds = listOf("s2"), createdAt = 1.0, updatedAt = 1.0)
    private val root = Pocket(
        id = "pkt_root", name = "Root", songIds = listOf("s1"), childPocketIds = listOf("pkt_kid"),
        cleanOnly = true, recsEnabled = false, songRepeats = mapOf("s1" to 3), createdAt = 1.0, updatedAt = 2.0,
    )

    @Test
    fun roundTrip_rootNotDuplicatedInPocketsJson_flagsTravel() {
        val cat = IoTestSupport.catalog(listOf(IndexSong(id = "s1", artist = "A", name = "N")))
        val bytes = PocketZip.export(root, mapOf("pkt_root" to root, "pkt_kid" to kid), cat.songsById, cat.albumsById, nowMs = 1_790_000_000_000)
        val entries = ZipIo.read(bytes)!!
        assertEquals(listOf("items.json", "manifest.json", "pocket.json", "pockets.json"), entries.keys.sorted())
        val man = IoTestSupport.json(entries["manifest.json"]!!) as JsonObject
        assertEquals("pocket", (man["kind"] as JsonPrimitive).content)
        assertEquals("Root", (man["pocketName"] as JsonPrimitive).content)
        assertEquals("2", ((man["counts"] as JsonObject)["pockets"] as JsonPrimitive).content)
        val b = PocketZip.read(bytes)
        assertEquals(root, b.pocket)
        assertEquals(listOf(kid), b.children)
        assertEquals(true, b.pocket.cleanOnly); assertEquals(false, b.pocket.recsEnabled)
        assertEquals(listOf("s1"), b.items.songs.map { it.id })
    }

    @Test
    fun slimWhenNoCatalog() {
        val entries = ZipIo.read(PocketZip.export(root, mapOf("pkt_kid" to kid)))!!
        assertFalse(entries.containsKey("items.json"))
    }

    @Test
    fun wrongKindAndCorruptRefused() {
        val playlistZip = PlaylistZip.export(
            com.levi.pocketdj.data.collections.CollectionsFactory.makePlaylist("p", 1.0), emptyMap(),
        )
        try { PocketZip.read(playlistZip); fail() } catch (e: CollectionZipException) {
            assertEquals(CollectionZipException.Reason.NOT_AN_EXPORT, e.reason)
        }
        try { PocketZip.read(ByteArray(10)); fail() } catch (e: CollectionZipException) {
            assertEquals(CollectionZipException.Reason.ARCHIVE_UNREADABLE, e.reason)
        }
    }

    @Test
    fun iosPdjcollectionFixtureReads() {
        val b = PocketZip.read(IoTestSupport.resource("backup/ios-pocket.pdjcollection"))
        assertEquals("pkt_ios_root", b.pocket.id)
        assertEquals(true, b.pocket.cleanOnly)
        assertEquals(listOf("pkt_ios_kid"), b.pocket.childPocketIds)
        assertEquals("123", b.items.songs.single().appleMusicId)
    }

    @Test
    fun remintMapsChildRefs() {
        val (r, kids) = PocketZip.remintBundle(root, listOf(kid), nowMs = 7.0)
        assertNotEquals("pkt_root", r.id)
        assertEquals(listOf(kids.single().id), r.childPocketIds)
        assertTrue(r.createdAt == 7.0 && true == r.cleanOnly)
    }
}
