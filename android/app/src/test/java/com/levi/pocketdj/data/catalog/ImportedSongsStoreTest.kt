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

    @Test fun resolveDropsRemappedRowsAndReportsPairs() {
        val entries = listOf(song("amrec_1", "Ad hoc", am = "9"), song("sng_x", "Keep", am = "9"), song("amrec_2", "Unclaimed", am = "5"))
        val real = IndexJson(
            manifest = IndexManifest(sourceName = "AM"),
            songs = listOf(
                IndexSong(id = "sng_real", artist = "A", name = "Real", appleMusicId = "9"),
                IndexSong(id = "sng_late", artist = "A", name = "Later twin", appleMusicId = "9"),
            ),
        )
        val r = ImportedSongsStore.resolveEntries(entries, emptyList(), listOf(real))
        assertEquals("first-seen claimant wins", listOf("amrec_1" to "sng_real"), r.pairs)
        assertEquals(listOf("sng_x", "amrec_2"), r.documents.single().songs.map { it.id })
        // nothing claimed -> no pairs, document unchanged
        val none = ImportedSongsStore.resolveEntries(entries, emptyList(), emptyList())
        assertTrue(none.pairs.isEmpty()); assertEquals(3, none.documents.single().songs.size)
        // all remapped and no albums -> no document at all
        val allGone = ImportedSongsStore.resolveEntries(listOf(song("amrec_1", am = "9")), emptyList(), listOf(real))
        assertTrue(allGone.documents.isEmpty()); assertEquals(1, allGone.pairs.size)
        // the store method delegates and is empty-safe
        assertTrue(ImportedSongsStore(tmp()).resolve(listOf(real)).documents.isEmpty())
    }

    @Test fun supersedeIgnoresBlankIdsAndSelfPairs() {
        assertTrue(ImportedSongsStore.supersedePairs(listOf(song("amrec_1", am = null)), mapOf("9" to "x")).isEmpty())
        assertTrue(ImportedSongsStore.supersedePairs(listOf(song("amrec_1", am = "9")), mapOf("9" to "amrec_1")).isEmpty())
    }

    @Test fun reloadFromDisk_adoptsAPulledDocument_andNotifies() {
        val f = tmp()
        val store = ImportedSongsStore(f)
        store.add(listOf(song("amrec_local")))
        var changed = 0
        store.onChanged = { changed++ }
        // a peer's pull overwrites the file (iOS key "imported-songs")
        f.writeText("""{"schemaVersion":1,"songs":[{"songId":"amrec_peer","title":"P"},{"songId":"amrec_peer","title":"dup"}],"albums":[]}""")
        assertEquals(false, store.reloadFromDisk())
        assertEquals(listOf("amrec_peer"), store.songs().map { it.songId })
        assertEquals(1, changed)
        assertEquals("amrec_peer", store.syntheticDocument()!!.songs.single().id)
    }

    @Test fun syncKeyIsTheIosKey() { assertEquals("imported-songs", ImportedSongsStore.SYNC_KEY) }

    @Test fun writePulled_adoptsBytesUnderLock_andFiresOnlyOnRealChange() {
        val remote = ImportedSongsStore(tmp()).also { it.add(listOf(song("r1"))) }
        val bytes = remoteBytes(remote)
        val file = tmp()
        val local = ImportedSongsStore(file)
        var fired = 0
        local.onChanged = { fired++ }
        local.writePulled(bytes)
        assertEquals(listOf("r1"), local.songs().map { it.songId })
        assertEquals(1, fired)
        local.writePulled(bytes) // identical id sets: no remerge
        assertEquals(1, fired)
        local.add(listOf(song("l1"))) // a later local add saves on top of the pulled list, not a stale one
        assertEquals(setOf("r1", "l1"), ImportedSongsStore(file).songs().map { it.songId }.toSet())
    }

    private fun remoteBytes(s: ImportedSongsStore): ByteArray {
        val f = tmp(); val c = ImportedSongsStore(f); c.add(s.songs()); return f.readBytes()
    }
}
