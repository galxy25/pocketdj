package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PlaylistZipTest {
    private fun node(kind: PlaylistNode.Kind, id: String, songId: String? = null, albumId: String? = null, pocketId: String? = null, text: String? = null) =
        PlaylistNode(nodeId = id, kind = kind, songId = songId, albumId = albumId, pocketId = pocketId, text = text)

    private val kid = Pocket(id = "pkt_kid", name = "Kid", songIds = listOf("sng_k"), createdAt = 1.0, updatedAt = 1.0)
    private val root = Pocket(id = "pkt_root", name = "Root", songIds = listOf("sng_r"), childPocketIds = listOf("pkt_kid"), createdAt = 1.0, updatedAt = 1.0)
    private val playlist = Playlist(
        id = "pls_1", name = "Set A", createdAt = 5.0, updatedAt = 6.0, targetMs = 3_600_000,
        sequences = listOf(
            PlaylistNode(
                nodeId = "nd_seq", kind = PlaylistNode.Kind.SEQUENCE, name = "Default", children = listOf(
                    node(PlaylistNode.Kind.SONG, "nd_1", songId = "sng_1"),
                    node(PlaylistNode.Kind.ALBUM, "nd_2", albumId = "alb_1"),
                    node(PlaylistNode.Kind.POCKET, "nd_3", pocketId = "pkt_root"),
                    node(PlaylistNode.Kind.TEXT, "nd_4", text = "cue"),
                ),
            ),
        ),
    )
    private val pocketsById = mapOf("pkt_root" to root, "pkt_kid" to kid)
    private val catalog = IoTestSupport.catalog(
        songs = listOf(
            IndexSong(id = "sng_1", albumId = "alb_1", artist = "A", name = "One"),
            IndexSong(id = "sng_r", artist = "A", name = "R"),
            IndexSong(id = "sng_k", artist = "A", name = "K"),
        ),
        albums = listOf(IndexAlbum(id = "alb_1", artist = "A", name = "Alb", trackList = listOf("sng_1"))),
    )

    @Test
    fun roundTrip() {
        val bytes = PlaylistZip.export(playlist, pocketsById, catalog.songsById, catalog.albumsById, nowMs = 1_790_000_000_000)
        val b = PlaylistZip.read(bytes)
        assertEquals(playlist, b.playlist)                                   // ids + node ids preserved
        assertEquals(setOf("pkt_root", "pkt_kid"), b.pockets.map { it.id }.toSet())
        assertEquals(root, b.pockets.first { it.id == "pkt_root" })
        assertEquals(setOf("sng_1", "sng_r", "sng_k"), b.items.songs.map { it.id }.toSet())
        assertEquals(listOf("alb_1"), b.items.albums.map { it.id })
    }

    @Test
    fun entryNamesAndManifestShape() {
        val bytes = PlaylistZip.export(playlist, pocketsById, catalog.songsById, catalog.albumsById, nowMs = 1_790_000_000_000)
        val entries = ZipIo.read(bytes)!!
        assertEquals(listOf("items.json", "manifest.json", "playlist.json", "pockets.json"), entries.keys.sorted())
        val man = IoTestSupport.json(entries["manifest.json"]!!) as JsonObject
        assertEquals("pocketdj", (man["app"] as JsonPrimitive).content)
        assertEquals("playlist", (man["kind"] as JsonPrimitive).content)
        assertEquals("Set A", (man["playlistName"] as JsonPrimitive).content)
        assertEquals("true", (man["portable"] as JsonPrimitive).content)
        assertEquals("2026-09-21T01:20:00Z".length, (man["exportedAt"] as JsonPrimitive).content.length)
        assertTrue((man["exportedAt"] as JsonPrimitive).content.endsWith("Z"))
        val counts = man["counts"] as JsonObject
        assertEquals("2", (counts["pockets"] as JsonPrimitive).content)
        assertEquals("4", (counts["items"] as JsonPrimitive).content)
        assertEquals(setOf("items", "pockets", "setlists", "art"), counts.keys)
        // sorted keys, compact
        val text = String(entries["manifest.json"]!!, Charsets.UTF_8)
        assertTrue(text.startsWith("{\"app\":\"pocketdj\",\"counts\":{\"art\":0,"))
    }

    @Test
    fun portableWhenCatalogGiven_slimOtherwise() {
        val slim = ZipIo.read(PlaylistZip.export(playlist, pocketsById))!!
        assertFalse(slim.containsKey("items.json"))
        assertEquals("false", ((IoTestSupport.json(slim["manifest.json"]!!) as JsonObject)["portable"] as JsonPrimitive).content)
        assertTrue(PlaylistZip.read(PlaylistZip.export(playlist, pocketsById)).items.isEmpty)
        val portable = ZipIo.read(PlaylistZip.export(playlist, pocketsById, catalog.songsById, catalog.albumsById))!!
        assertTrue(portable.containsKey("items.json"))
    }

    @Test
    fun referencedPockets_dagExpandedCycleGuarded() {
        val a = Pocket(id = "a", childPocketIds = listOf("b"))
        val b = Pocket(id = "b", childPocketIds = listOf("a"))   // cycle
        val pl = playlist.copy(sequences = listOf(PlaylistNode(nodeId = "s", kind = PlaylistNode.Kind.SEQUENCE, name = "x",
            children = listOf(node(PlaylistNode.Kind.POCKET, "n", pocketId = "a"), node(PlaylistNode.Kind.POCKET, "n2", pocketId = "missing")))))
        val got = PlaylistZip.referencedPockets(pl, mapOf("a" to a, "b" to b))
        assertEquals(setOf("a", "b"), got.map { it.id }.toSet())
        assertEquals(2, got.size)
    }

    @Test
    fun pwaFixtureImports() {
        val b = PlaylistZip.read(IoTestSupport.resource("fixtures/pwa-playlist.pocketdj.zip"))
        assertEquals("pls_pwa0001", b.playlist.id)
        assertEquals("PWA Night", b.playlist.name)
        assertEquals(3_600_000L, b.playlist.targetMs)
        val kids = b.playlist.sequences.single().children!!
        assertEquals(listOf("sng_aaa111", "alb_bbb222", "pkt_pwa_root", null), kids.map { it.songId ?: it.albumId ?: it.pocketId })
        assertEquals("Drop the lights", kids[3].text)
        assertEquals(setOf("pkt_pwa_root", "pkt_pwa_kid"), b.pockets.map { it.id }.toSet())
        // items.json: junk rows dropped, nulls tolerated, unknown fields ignored, art/ + setlists.json unconsumed.
        assertEquals(listOf("sng_aaa111", "sng_bbb001"), b.items.songs.map { it.id })
        assertNull(b.items.songs[0].bpm)
        assertEquals(118.5, b.items.songs[1].bpm!!, 0.0)
        assertEquals("covers/b.jpg", b.items.albums.single().coverArtUrl)
    }

    @Test
    fun iosSlimSampleImports() {
        val b = PlaylistZip.read(IoTestSupport.resource("fixtures/ios-sample-playlist.playlist.pocketdj.zip"))
        assertEquals("1 — take 3", b.playlist.name)
        assertEquals("Openers", b.playlist.sequences.first().name)
        assertTrue(b.pockets.isEmpty())
        assertTrue(b.items.isEmpty)
    }

    @Test
    fun wrongKindUnreadableAndMissingRootAreRefused() {
        val pocketZip = PocketZip.export(root, pocketsById)
        assertReason(CollectionZipException.Reason.NOT_AN_EXPORT) { PlaylistZip.read(pocketZip) }
        assertReason(CollectionZipException.Reason.ARCHIVE_UNREADABLE) { PlaylistZip.read("nope".toByteArray()) }
        val noRoot = ZipIo.write(mapOf("manifest.json" to """{"app":"pocketdj","kind":"playlist"}""".toByteArray()))
        assertReason(CollectionZipException.Reason.MISSING_ROOT) { PlaylistZip.read(noRoot) }
        val badRoot = ZipIo.write(mapOf("playlist.json" to """{"id":"x"}""".toByteArray()))
        assertReason(CollectionZipException.Reason.NOT_AN_EXPORT) { PlaylistZip.read(badRoot) }
    }

    @Test
    fun missingManifestIsTolerated() {
        val bytes = ZipIo.write(ZipIo.read(PlaylistZip.export(playlist, pocketsById))!!.filterKeys { it != "manifest.json" })
        assertEquals("pls_1", PlaylistZip.read(bytes).playlist.id)
    }

    @Test
    fun remintBundleMintsFreshIdsAndRemapsIntraBundleRefs() {
        val b = PlaylistZip.read(PlaylistZip.export(playlist, pocketsById))
        val (pl, pockets) = PlaylistZip.remintBundle(b.playlist.copy(amPlaylistId = "am"), b.pockets.map { it.copy(amPlaylistId = "am") }, nowMs = 9.0)
        assertNotEquals("pls_1", pl.id)
        assertNull(pl.amPlaylistId)
        assertTrue(pockets.all { it.amPlaylistId == null && it.createdAt == 9.0 })
        val newRoot = pockets.first { it.name == "Root" }
        assertEquals(listOf(pockets.first { it.name == "Kid" }.id), newRoot.childPocketIds)
        val pocketNode = pl.sequences.single().children!!.first { it.kind == PlaylistNode.Kind.POCKET }
        assertEquals(newRoot.id, pocketNode.pocketId)
        assertNotEquals("nd_1", pl.sequences.single().children!!.first().nodeId)
        assertTrue(pl.id.startsWith("pls_") && CollectionsFactory.newNodeId().startsWith("nd_"))
    }

    private fun assertReason(reason: CollectionZipException.Reason, body: () -> Unit) {
        try { body(); fail("expected $reason") } catch (e: CollectionZipException) { assertEquals(reason, e.reason) }
    }
}
