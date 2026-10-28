package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.collections.io.PortableItems
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportedSongsStoreTest {
    private fun tmp(): File = File.createTempFile("imported", ".json").also { it.delete(); it.deleteOnExit() }
    private fun song(id: String, title: String = "T", am: String? = null) =
        ImportedSongsStore.SongEntry(songId = id, title = title, artist = "A", appleMusicId = am)

    @Test fun dedupAgainstSelf() {
        val store = ImportedSongsStore(tmp())
        var fired = 0
        store.onChanged = { fired++ }
        assertEquals(2, store.add(listOf(song("s1"), song("s2"), song("s1", "dup"))))
        assertEquals("a repeat import adds nothing", 0, store.add(listOf(song("s1", "other"), song("s2"))))
        assertEquals(1, fired)
        assertEquals("first wins", "T", store.songs().first { it.songId == "s1" }.title)
        // survives a reload from disk
        val file = tmp()
        val s2 = ImportedSongsStore(file); s2.add(listOf(song("x")))
        assertEquals(listOf("x"), ImportedSongsStore(file).songs().map { it.songId })
    }

    @Test fun realSourceWins() {
        val store = ImportedSongsStore(tmp())
        store.add(listOf(song("shared", "Provisional"), song("only-imported", "Mine")))
        val real = IndexJson(
            manifest = IndexManifest(sourceName = "Vinyl"),
            songs = listOf(IndexSong(id = "shared", artist = "A", name = "Real")),
        )
        val merged = MergedCatalog.merge(listOf(real) + listOfNotNull(store.syntheticDocument()))
        assertEquals("Real", merged.songsById["shared"]!!.name)
        assertEquals("Vinyl", merged.sourceOfSong["shared"])
        assertEquals("Imported", merged.sourceOfSong["only-imported"])
        assertTrue("Imported" in merged.availableSources)
        // un-ticking the real source restores the durable fallback (entry was kept)
        val alone = MergedCatalog.merge(listOfNotNull(store.syntheticDocument()))
        assertEquals("Provisional", alone.songsById["shared"]!!.name)
    }

    @Test fun docLenient() {
        val f = tmp()
        f.writeText("not json at all")
        assertTrue(ImportedSongsStore(f).songs().isEmpty())
        val (songs, albums) = ImportedSongsStore.decodeText(
            """{"schemaVersion":9,"futureField":1,"songs":[{"songId":"s1","title":"X","extra":true}],"albums":[{"albumId":"a1","trackIds":["s1"]}]}""",
        )
        assertEquals("s1", songs.single().songId)
        assertEquals("", albums.single().name) // missing fields default
        assertEquals(listOf("s1"), albums.single().trackIds)
        assertNull(ImportedSongsStore(tmp()).syntheticDocument())
    }

    @Test fun syntheticDocumentIsStableUntilChanged() {
        val store = ImportedSongsStore(tmp())
        store.add(listOf(song("a")))
        val d1 = store.syntheticDocument()
        assertSame(d1, store.syntheticDocument())
        store.add(listOf(song("b")))
        assertNotNull(store.syntheticDocument())
        assertEquals(2, store.syntheticDocument()!!.songs.size)
    }

    @Test fun portablePayloadMapsAndSupersedeIsAmrecOnly() {
        val store = ImportedSongsStore(tmp())
        val added = store.addPortable(
            PortableItems.Payload(
                songs = listOf(PortableItems.Song("sng_1", "Name", "Art", albumId = "alb_1", lengthMs = 1000, appleMusicId = "123")),
                albums = listOf(PortableItems.Album("alb_1", "Alb", "Art", listOf("sng_1"))),
            ),
            nowMs = 5.0,
        )
        assertEquals(2, added)
        val doc = store.syntheticDocument()!!
        assertEquals(1000L, doc.songs.single().length)
        assertEquals(listOf("sng_1"), doc.albums.single().trackList)
        val pairs = ImportedSongsStore.supersedePairs(
            listOf(song("amrec_1", am = "9"), song("sng_2", am = "9"), song("amrec_3", am = "7")),
            mapOf("9" to "sng_real"),
        )
        assertEquals(listOf("amrec_1" to "sng_real"), pairs)
    }
}
