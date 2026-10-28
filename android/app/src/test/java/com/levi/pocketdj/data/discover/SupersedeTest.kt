package com.levi.pocketdj.data.discover

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SupersedeTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun e(id: String, am: String, albumId: String? = null) =
        DiscoverAddsStore.Entry(songId = id, appleMusicId = am, title = "T$am", artist = "A", albumId = albumId, addedAtMs = 1.0)

    private fun al(id: String, am: String, tracks: List<String> = emptyList()) =
        DiscoverAddsStore.AlbumEntry(albumId = id, appleMusicId = am, title = "L$am", artist = "A", trackIds = tracks, addedAtMs = 1.0)

    private fun real(name: String, songs: List<IndexSong> = emptyList(), albums: List<IndexAlbum> = emptyList()) =
        IndexJson(manifest = IndexManifest(sourceName = name), songs = songs, albums = albums)

    private fun rs(id: String, am: String?) = IndexSong(id = id, artist = "A", name = "n", appleMusicId = am)

    @Test fun splitYieldsToIndexedClaimantAndKeepsTheRest() {
        val (keep, pairs) = DiscoverAddsStore.split(
            listOf(e("amrec_1", "1"), e("amrec_2", "2"), e("amrec_3", "3")),
            mapOf("1" to "real_1", "3" to "amrec_3"), // 3 claims ITSELF (the synthetic source in a later pass)
        )
        assertEquals(listOf("amrec_2", "amrec_3"), keep.map { it.songId })
        assertEquals(listOf("amrec_1" to "real_1"), pairs)
    }

    @Test fun splitAlbumsNeverSelfSupersedes() {
        val (keep, pairs) = DiscoverAddsStore.splitAlbums(
            listOf(al("amrec_album_1", "1"), al("amrec_album_2", "2")),
            mapOf("1" to "alb_real", "2" to "amrec_album_2"),
        )
        assertEquals(listOf("amrec_album_2"), keep.map { it.albumId })
        assertEquals(listOf("amrec_album_1" to "alb_real"), pairs)
    }

    @Test fun resolveExcludesSupersededAndReportsRemapPairs() {
        val r = ProvisionalSource.resolve(
            listOf(e("amrec_1", "1"), e("amrec_2", "2")), emptyList(),
            listOf(real("Apple Music", listOf(rs("real_1", "1"), rs("other", null)))),
        )
        assertEquals(listOf("amrec_1" to "real_1"), r.supersededSongs)
        assertEquals(listOf("amrec_2"), r.documents.single().songs.map { it.id })
        assertEquals("Discover", r.documents.single().manifest.displayName)
    }

    @Test fun firstSeenRealClaimantWins() {
        val r = ProvisionalSource.resolve(
            listOf(e("amrec_1", "1")), emptyList(),
            listOf(real("A", listOf(rs("first", "1"))), real("B", listOf(rs("second", "1")))),
        )
        assertEquals(listOf("amrec_1" to "first"), r.supersededSongs)
        assertTrue(r.documents.isEmpty())
    }

    @Test fun supersededAlbumRepointsItsSurvivingTracksAtTheRealAlbum() {
        val r = ProvisionalSource.resolve(
            listOf(e("amrec_1", "1", albumId = "amrec_album_9"), e("amrec_2", "2", albumId = "amrec_album_9")),
            listOf(al("amrec_album_9", "9", listOf("amrec_1", "amrec_2"))),
            listOf(real("AM", listOf(rs("real_1", "1")), listOf(IndexAlbum(id = "alb_real", artist = "A", name = "L", appleMusicId = "9")))),
        )
        assertEquals(listOf("amrec_album_9" to "alb_real"), r.supersededAlbums)
        assertEquals(listOf("amrec_1" to "real_1"), r.supersededSongs)
        val doc = r.documents.single()
        assertEquals(listOf("alb_real"), doc.songs.map { it.albumId })
        assertTrue(doc.albums.isEmpty())
    }

    @Test fun nothingProvisionalYieldsNoDocument() {
        assertTrue(ProvisionalSource.resolve(emptyList(), emptyList(), emptyList()).none)
    }

    @Test fun storeResolveKeepsTheDocumentInstanceWhileSurvivorsAreUnchanged() {
        val s = DiscoverAddsStore(File(tmp.root, "d.json"))
        s.add(e("amrec_1", "1").copy(addedAtMs = 1.0)); s.add(e("amrec_2", "2"))
        val real = listOf(real("AM", listOf(rs("real_1", "1"))))
        val first = s.resolve(real)
        // The merge reported amrec_1 superseded; the app prunes it. The survivors (and so the doc) are unchanged.
        s.remove(first.supersededSongs.map { it.first })
        val second = s.resolve(real)
        assertSame("no spurious catalog rebuild", first.documents.single(), second.documents.single())
        assertTrue(second.supersededSongs.isEmpty())
    }

    @Test fun mergeOrderRealSourceShadowsProvisionalTwinWithoutDeletingIt() {
        // Same id in both (e.g. a real index that also carries amrec_1): first-wins keeps the real row.
        val realDoc = real("AM", listOf(IndexSong(id = "amrec_1", artist = "R", name = "Real")))
        val s = DiscoverAddsStore(File(tmp.root, "d.json"))
        s.add(e("amrec_1", "1"))
        val r = s.resolve(listOf(realDoc))
        val merged = MergedCatalog.merge(listOf(realDoc) + r.documents)
        assertEquals("Real", merged.songsById["amrec_1"]?.name)
        assertEquals("AM", merged.sourceOfSong["amrec_1"])
        assertEquals("the provisional entry is still on disk", 1, s.entries.size)
    }

    @Test fun collectionsFollowTheSupersede() {
        val store = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        val cat = MergedCatalog.merge(listOf(real("AM", listOf(rs("amrec_1", "1"), rs("amrec_2", "2"), rs("real_1", "1")))))
        store.catalogProvider = { cat }
        val pocket = store.createPocket("P")
        store.addSongToPocket("amrec_1", pocket.id)
        store.addSongToPocket("amrec_2", pocket.id)
        store.setSongRepeat("amrec_1", 3, pocket.id)
        val pl = store.createPlaylist("PL")
        store.addSongToPlaylist("amrec_1", pl.id)
        store.addSongToPlaylist("amrec_2", pl.id)
        val setlist = store.realize(pl.id, seed = "s")
        assertTrue(setlist != null && setlist.tracks.any { it.songId == "amrec_1" })

        store.remapSongIds(listOf("amrec_1" to "real_1"))

        val p = store.pocket(pocket.id)!!
        assertEquals(listOf("real_1", "amrec_2"), p.songIds)
        assertEquals(mapOf("real_1" to 3), p.songRepeats)
        val leaves = store.playlist(pl.id)!!.sequences.flatMap { it.children.orEmpty() + it }.mapNotNull { it.songId }
        assertEquals(listOf("real_1", "amrec_2"), leaves)
        assertFalse(store.setlists.flatMap { it.tracks }.any { it.songId == "amrec_1" })
        assertTrue(store.setlists.flatMap { it.tracks }.any { it.songId == "real_1" })
        // Persisted: a reopened store sees the remap.
        val again = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        assertEquals(listOf("real_1", "amrec_2"), again.pocket(pocket.id)!!.songIds)
        assertNull(again.pocket(pocket.id)!!.songRepeats["amrec_1"])
        // Unrelated / empty remaps are no-ops.
        again.remapSongIds(emptyList()); again.remapSongIds(listOf("zzz" to "yyy"))
        assertEquals(listOf("real_1", "amrec_2"), again.pocket(pocket.id)!!.songIds)
    }
}
