package com.levi.pocketdj.screens.collections

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AddToActionsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store() = CollectionsStore(File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
    private fun pt(id: String) = AddTarget(AddTarget.Kind.POCKET, id)
    private fun plt(id: String) = AddTarget(AddTarget.Kind.PLAYLIST, id)

    @Test
    fun recentTargetsFiltersDeleted() {
        val s = store()
        val a = s.createPocket("A")
        val b = s.createPlaylist("B")
        val actions = AddToActions(AddToItem.Song("sng_1"), s)
        actions.add(pt(a.id))
        actions.add(plt(b.id))
        assertEquals(listOf(plt(b.id).id, a.id), actions.recentTargets(5).map { it.id })
        s.deletePocket(a.id)
        assertEquals(listOf(b.id), actions.recentTargets(5).map { it.id })
        assertEquals(emptyList<AddTarget>(), actions.recentTargets(0))
    }

    @Test
    fun suggestedExcludesRecent() {
        val s = store()
        val a = s.createPocket("A")
        val b = s.createPocket("B")
        val c = s.createPlaylist("C")
        val actions = AddToActions(AddToItem.Song("sng_1"), s)
        actions.add(pt(a.id))
        val wire = listOf(
            CollectionSuggestion("pocket", a.id), // in recent -> dropped
            CollectionSuggestion("pocket", "gone"), // unresolvable -> dropped
            CollectionSuggestion("weird", b.id), // unknown kind -> dropped
            CollectionSuggestion("pocket", b.id),
            CollectionSuggestion("playlist", c.id),
        )
        val recent = actions.recentTargets(5)
        assertEquals(listOf(b.id, c.id), actions.suggestedTargets(wire, recent, 5).map { it.id })
        assertEquals(listOf(b.id), actions.suggestedTargets(wire, recent, 1).map { it.id })
        // quickTargets: suggested first, then recent, deduped, capped; unwired => recent only.
        assertEquals(listOf(b.id, c.id, a.id), actions.quickTargets(5) { wire }.map { it.id })
        assertEquals(listOf(b.id, c.id), actions.quickTargets(2) { wire }.map { it.id })
        assertEquals(listOf(a.id), actions.quickTargets(5, null).map { it.id })
        // Suggested are song-only: an album item ignores the seam.
        assertEquals(listOf(a.id), AddToActions(AddToItem.Album("alb_1"), s).quickTargets(5) { wire }.map { it.id })
    }

    @Test
    fun inPlaylistMultiAllMembers() {
        val s = store()
        val pl = s.createPlaylist("PL")
        val pk = s.createPocket("PK")
        s.addSongs(listOf("sng_1", "sng_2"), plt(pl.id))
        s.addSongs(listOf("sng_1", "sng_2"), pt(pk.id))
        val all = AddToActions(AddToItem.Songs(listOf("sng_1", "sng_2")), s)
        val partial = AddToActions(AddToItem.Songs(listOf("sng_1", "sng_3")), s)
        val empty = AddToActions(AddToItem.Songs(emptyList()), s)
        assertTrue(all.isMember(plt(pl.id)))
        assertTrue(all.isMember(pt(pk.id)))
        assertFalse(partial.isMember(plt(pl.id)))
        assertFalse(partial.isMember(pt(pk.id)))
        assertFalse(empty.isMember(plt(pl.id)))
    }

    @Test
    fun toggleRemovesEveryChapter() {
        val s = store()
        val pl = s.createPlaylist("PL")
        s.addSequence("Two", pl.id)
        val seqs = s.playlist(pl.id)!!.sequences
        s.addSongToPlaylist("sng_1", pl.id, seqs[0].nodeId)
        s.addSongToPlaylist("sng_1", pl.id, seqs[1].nodeId)
        val actions = AddToActions(AddToItem.Song("sng_1"), s)
        assertTrue(actions.isMember(plt(pl.id)))
        val out = actions.toggle(plt(pl.id))
        assertTrue(out.remove)
        assertFalse(out.fireOnAdded)
        assertFalse(out.dismiss)
        assertFalse(s.playlistContains(pl.id, "sng_1"))
        assertFalse(actions.isMember(plt(pl.id)))
        // toggling again adds back (and would fire onAdded)
        val back = actions.toggle(plt(pl.id))
        assertFalse(back.remove)
        assertTrue(back.fireOnAdded)
        assertTrue(s.playlistContains(pl.id, "sng_1"))
    }

    @Test
    fun albumToggleAndPocketRemove() {
        val s = store()
        val pl = s.createPlaylist("PL")
        val pk = s.createPocket("PK")
        val actions = AddToActions(AddToItem.Album("alb_1"), s)
        actions.add(plt(pl.id))
        actions.add(pt(pk.id))
        assertTrue(actions.isMember(plt(pl.id)) && actions.isMember(pt(pk.id)))
        actions.remove(plt(pl.id))
        actions.remove(pt(pk.id))
        assertFalse(actions.isMember(plt(pl.id)))
        assertFalse(actions.isMember(pt(pk.id)))
    }

    @Test
    fun songsBatchUsesAddSongsOnce() {
        val s = store()
        val pk = s.createPocket("PK")
        var batches = 0
        s.onActivityBatch = { batches++ }
        val actions = AddToActions(AddToItem.Songs(listOf("sng_1", "sng_2", "sng_1")), s)
        assertTrue(actions.add(pt(pk.id)))
        assertEquals(1, batches) // one batch for the whole gesture
        assertEquals(listOf("sng_1", "sng_2"), s.pocket(pk.id)!!.songIds)
        assertFalse(actions.add(pt(pk.id))) // nothing landed
        assertEquals(1, batches)
        // batch remove is one activity batch too
        actions.remove(pt(pk.id))
        assertEquals(2, batches)
        assertEquals(emptyList<String>(), s.pocket(pk.id)!!.songIds)
    }

    @Test
    fun recentMruRecordsAddsButNotRemoves() {
        val s = store()
        val pk = s.createPocket("PK")
        val actions = AddToActions(AddToItem.Song("sng_1"), s)
        assertEquals(emptyList<AddTarget>(), s.state.value.recentAddTargets)
        actions.toggle(pt(pk.id))
        assertEquals(1, s.state.value.recentAddTargets.size)
    }
}
