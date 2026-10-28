package com.levi.pocketdj.ui.selection

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SelectionBarSemanticsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store() = CollectionsStore(File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
    private val target = AddTarget(AddTarget.Kind.POCKET, "p1")

    private fun selecting(all: List<String>, picked: List<String>): RowSelection {
        val sel = RowSelection()
        sel.registerActiveList("browse", { all }, { SongTransfer(sel.orderedSelection(all)) })
        sel.enterSelectMode("browse", picked.first())
        picked.drop(1).forEach { sel.handleTap(it, "browse") }
        return sel
    }

    @Test
    fun addToCallsAddSongsOnceWithDisplayOrderedIds() {
        val sel = selecting(listOf("a", "b", "c", "d"), picked = listOf("d", "a", "c"))
        val calls = ArrayList<Pair<List<String>, AddTarget>>()
        val r = SelectionBarSemantics.addTo(sel, target) { ids, t -> calls += ids to t; ids.size }
        assertEquals(1, calls.size)
        assertEquals(listOf("a", "c", "d"), calls[0].first)
        assertEquals(target, calls[0].second)
        assertEquals(SelectionBarSemantics.AddResult.Added(3, 3), r)
        assertTrue("selection survives an add", sel.state.value.hasSelection)
    }

    @Test
    fun staleSelectionClearsInsteadOfAdvertisingCount() {
        val all = mutableListOf("a", "b")
        val sel = RowSelection()
        sel.registerActiveList("browse", { all }, { SongTransfer(sel.orderedSelection(all)) })
        sel.enterSelectMode("browse", "a")
        all.clear() // the songs left the list under the selection
        var called = false
        val r = SelectionBarSemantics.addTo(sel, target) { _, _ -> called = true; 1 }
        assertEquals(SelectionBarSemantics.AddResult.StaleCleared, r)
        assertFalse(called)
        assertFalse(sel.state.value.hasSelection)
        assertFalse(sel.state.value.selectMode)
    }

    @Test
    fun playlistChapterPayloadTranslatesNodeIdsToSongIds() {
        // Playlist scope: ids are NODE ids; the registered payload maps them to song ids.
        val nodeToSong = mapOf("n1" to "s1", "n2" to "s2", "n3" to "s1")
        val order = listOf("n1", "n2", "n3")
        val sel = RowSelection()
        sel.registerActiveList("playlist:p", { order }, {
            SongTransfer(sel.orderedSelection(order).mapNotNull { nodeToSong[it] })
        })
        sel.enterSelectMode("playlist:p", "n3")
        sel.handleTap("n1", "playlist:p")
        val s = store()
        val pocket = s.createPocket("P")
        val r = SelectionBarSemantics.addTo(sel, AddTarget(AddTarget.Kind.POCKET, pocket.id)) { ids, t ->
            s.addSongs(ids, t)
        }
        // n1,n3 both -> s1: translated in order, store dedupes to ONE song.
        assertEquals(SelectionBarSemantics.AddResult.Added(2, 1), r)
        assertEquals(listOf("s1"), s.pocket(pocket.id)!!.songIds)
    }

    @Test
    fun copyAndCountSemantics() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        assertFalse(SelectionBarSemantics.copyEnabled(sel.state.value))
        sel.registerActiveList("browse", { listOf("a") }, { SongTransfer(listOf("a")) })
        assertTrue(SelectionBarSemantics.copyEnabled(sel.state.value))
        assertEquals("1 selected", SelectionBarSemantics.countLabel(sel.state.value.count))
        val (text, json) = SelectionBarSemantics.clipTexts(SongTransfer(listOf("a", "b"), "A — x"))
        assertEquals("A — x", text)
        assertEquals(listOf("a", "b"), SongTransfer.decode(json)?.songIds)
    }

    @Test
    fun recentRowsDropDeletedAndCapAtThree() {
        val s = store()
        val ps = (1..5).map { s.createPocket("P$it") }
        ps.forEach { s.addSong("sng", AddTarget(AddTarget.Kind.POCKET, it.id)) }
        s.deletePocket(ps[4].id) // most recent is gone
        val rows = SelectionBarSemantics.recentRows(s)
        assertEquals(listOf("P4", "P3", "P2"), rows.map { it.second })
        assertEquals(listOf("alpha", "Beta", "gamma"), SelectionBarSemantics.sortedAZ(listOf("gamma", "Beta", "alpha")) { it })
    }
}
