package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The choke-point contract of specs/activity-favorites.md §4: the ONLY
 * activity emissions are the AddTarget-wrapper adds and the five user-facing
 * removes; low-level membership methods, whole-collection deletes,
 * index-playlist adds, and source-sync reconcile NEVER fire.
 */
class CollectionsActivityChokePointsTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val hooks = mutableListOf<CollectionsStore.ActivityHook>()

    private fun newStore(): CollectionsStore =
        CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
            .also { store -> store.onActivity = { hooks.add(it) } }

    private fun wireCatalog(store: CollectionsStore, vararg songs: IndexSong) {
        val merged = MergedCatalog.merge(
            listOf(IndexJson(manifest = IndexManifest(sourceName = "My Vinyl"), songs = songs.toList())),
        )
        store.catalogProvider = { merged }
    }

    private fun song(id: String, name: String) = IndexSong(id = id, artist = "A", name = name)

    // MARK: ADD events — only the AddTarget funnel

    @Test
    fun addSongToTarget_emitsOneAdd_withSnapshots() {
        val store = newStore()
        wireCatalog(store, song("sng_1", "Tiny Dancer"))
        val pocket = store.createPocket("Crate")

        store.addSong("sng_1", AddTarget(AddTarget.Kind.POCKET, pocket.id))

        val hook = hooks.single()
        assertEquals(CollectionsStore.ActivityHook.Kind.ADD, hook.kind)
        assertEquals("sng_1", hook.itemId)
        assertEquals("Tiny Dancer", hook.itemTitle)
        assertEquals(pocket.id, hook.collectionId)
        assertEquals("pocket", hook.collectionKind)
        assertEquals("Crate", hook.collectionName)
    }

    @Test
    fun addAlbumToTarget_emitsOneAdd_playlistUsesPlainName() {
        val store = newStore()
        val playlist = store.createPlaylist("Roadtrip")
        store.addSequence("Encore", playlist.id)
        val encoreId = store.playlist(playlist.id)!!.sequences[1].nodeId

        store.addAlbum("alb_1", AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = encoreId))

        val hook = hooks.single()
        assertEquals(CollectionsStore.ActivityHook.Kind.ADD, hook.kind)
        assertEquals("alb_1", hook.itemId)
        // PLAIN name — never the "Playlist › Chapter" form.
        assertEquals("Roadtrip", hook.collectionName)
        assertEquals("playlist", hook.collectionKind)
    }

    @Test
    fun lowLevelAdds_emitNothing() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        val playlist = store.createPlaylist("List")

        store.addSongToPocket("sng_1", pocket.id)
        store.addAlbumToPocket("alb_1", pocket.id)
        store.addChildPocket(store.createPocket("Child").id, pocket.id)
        store.addSongToPlaylist("sng_1", playlist.id)
        store.addAlbumToPlaylist("alb_1", playlist.id)
        store.addNode(
            PlaylistNode(nodeId = CollectionsFactory.newNodeId(), kind = PlaylistNode.Kind.TEXT, text = "hi"),
            playlist.id,
        )

        assertTrue(hooks.isEmpty())
    }

    // MARK: REMOVE events — the five user-facing paths, exactly once each

    @Test
    fun removePaths_emitExactlyOnce_withPreMutationCollectionName() {
        val store = newStore()
        wireCatalog(store, song("sng_1", "Tiny Dancer"))
        val pocket = store.createPocket("Crate")
        val child = store.createPocket("Child")
        store.addSongToPocket("sng_1", pocket.id)
        store.addAlbumToPocket("alb_1", pocket.id)
        store.addChildPocket(child.id, pocket.id)
        hooks.clear()

        store.removeSongFromPocket("sng_1", pocket.id)
        store.removeAlbumFromPocket("alb_1", pocket.id)
        store.removeChildPocket(child.id, pocket.id)

        assertEquals(3, hooks.size)
        assertTrue(hooks.all { it.kind == CollectionsStore.ActivityHook.Kind.REMOVE })
        assertTrue(hooks.all { it.collectionName == "Crate" && it.collectionKind == "pocket" })
        assertEquals("Tiny Dancer", hooks[0].itemTitle)
        // Child pocket: itemTitle is the child's OWN name (the catalog can't name it).
        assertEquals(child.id, hooks[2].itemId)
        assertEquals("Child", hooks[2].itemTitle)
    }

    @Test
    fun removeNode_itemIdFallbackChain_songAlbumPocketThenNodeId() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id)
        store.addAlbumToPlaylist("alb_1", playlist.id)
        store.addPocketRef("pkt_1", playlist.id)
        store.addTextToPlaylist("mic break", playlist.id)
        val nodes = store.playlist(playlist.id)!!.sequences[0].children!!
        hooks.clear()

        nodes.forEach { store.removeNode(it.nodeId, playlist.id) }

        assertEquals(4, hooks.size)
        assertEquals("sng_1", hooks[0].itemId)
        assertEquals("alb_1", hooks[1].itemId)
        assertEquals("pkt_1", hooks[2].itemId)
        assertEquals(nodes[3].nodeId, hooks[3].itemId) // text node falls back to nodeId
        assertTrue(hooks.all { it.collectionName == "List" && it.collectionKind == "playlist" })
    }

    @Test
    fun wholeCollectionDeletes_emitNothing() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        val playlist = store.createPlaylist("List")
        hooks.clear()

        store.deletePocket(pocket.id)
        store.deletePlaylist(playlist.id)

        assertTrue(hooks.isEmpty())
    }

    // MARK: NEVER-fire paths

    @Test
    fun indexPlaylistAdd_emitsNothing_andDoesNotTouchAddMemory() {
        val store = newStore()
        wireCatalog(store, song("sng_1", "One"), song("sng_2", "Two"))
        val source = SourcePlaylist(
            playlist = IndexPlaylist(id = "pl_src", name = "AM Mix", songIds = listOf("sng_1")),
            sourceName = "Apple Music (Local)",
        )

        val result = store.addSongToIndexPlaylist("sng_2", source)

        assertTrue(hooks.isEmpty())
        assertNull(store.lastAddTarget)
        assertTrue(store.recentAddTargets.isEmpty())
        assertTrue(result.createdDuplicate)
        assertEquals(false, result.writeBackEligible)
        // And it must NOT advance the three-way-merge base snapshot.
        assertEquals(listOf("sng_1"), result.playlist.sourceSongIds)
    }

    @Test
    fun sourceSyncReconcile_emitsNothing() {
        val store = newStore()
        val source = SourcePlaylist(
            playlist = IndexPlaylist(id = "pl_src", name = "AM Mix", songIds = listOf("sng_1", "sng_2")),
            sourceName = "Apple Music (Local)",
        )
        val pocket = store.convertSourceToPocket(source)
        hooks.clear()

        // The source now adds sng_3 and removes sng_1 — reconcile mutates
        // membership but must never route through the emitting funnel.
        val fresh = SourcePlaylist(
            playlist = IndexPlaylist(id = "pl_src", name = "AM Mix", songIds = listOf("sng_2", "sng_3")),
            sourceName = "Apple Music (Local)",
        )
        val changed = store.syncConvertedCollections(listOf(fresh))

        assertEquals(1, changed)
        assertEquals(listOf("sng_2", "sng_3"), store.pocket(pocket.id)!!.songIds)
        assertTrue(hooks.isEmpty())
    }
}
