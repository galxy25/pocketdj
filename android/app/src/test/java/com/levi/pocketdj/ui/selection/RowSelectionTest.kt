package com.levi.pocketdj.ui.selection

import com.levi.pocketdj.data.collections.SongTransfer
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RowSelectionTest {
    private val ids = listOf("a", "b", "c", "d")

    private fun registered(scope: String = "browse", all: List<String> = ids, sel: RowSelection = RowSelection()): RowSelection {
        sel.registerActiveList(scope, { all }, { SongTransfer(sel.orderedSelection(all)) })
        return sel
    }

    @Test
    fun armPerScopeOnlyInterceptsOwnScope() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        // The swallowed-first-tap bug: a tap in ANOTHER list must navigate, not toggle.
        assertEquals(RowSelection.TapOutcome.NAVIGATE, sel.handleTap("x", "pocket:1"))
        assertFalse("x" in sel.state.value.ids)
        assertFalse(sel.state.value.isActive("pocket:1").and(sel.state.value.isSelectMode("pocket:1")))
        // ...and the armed scope still toggles.
        assertEquals(RowSelection.TapOutcome.SELECTION, sel.handleTap("b", "browse"))
        assertEquals(setOf("a", "b"), sel.state.value.ids)
        assertEquals(RowSelection.TapOutcome.SELECTION, sel.handleTap("b", "browse"))
        assertEquals(setOf("a"), sel.state.value.ids)
    }

    @Test
    fun unarmedTapNavigatesAndLongPressArms() {
        val sel = RowSelection()
        assertEquals(RowSelection.TapOutcome.NAVIGATE, sel.handleTap("a", "browse"))
        sel.handleLongPress("a", "browse")
        assertTrue(sel.state.value.isSelectMode("browse"))
        assertEquals(setOf("a"), sel.state.value.ids)
        sel.handleLongPress("b", "browse") // already armed: toggles
        assertEquals(setOf("a", "b"), sel.state.value.ids)
    }

    @Test
    fun selectAllUsesAllIds() {
        // allIds is the FULL filtered universe, not the rendered page.
        val universe = (1..500).map { "s$it" }
        val sel = registered(all = universe)
        sel.enterSelectMode("browse", "s1")
        sel.selectAll()
        assertEquals(500, sel.state.value.count)
        assertEquals(universe, sel.orderedSelection(universe))
    }

    @Test
    fun selectAllWithoutActiveListIsNoOp() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        sel.selectAll()
        assertEquals(setOf("a"), sel.state.value.ids)
    }

    @Test
    fun pruneKeepsAnchorValid() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        sel.handleTap("b", "browse")
        sel.prune(setOf("b", "c"))
        assertEquals(setOf("b"), sel.state.value.ids)
        assertNull("anchor 'a' left the list", sel.state.value.anchorId)
        sel.enterSelectMode("browse", "b")
        sel.prune(setOf("b"))
        assertEquals("b", sel.state.value.anchorId)
    }

    @Test
    fun orderedSelectionFollowsDisplayOrder() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "c")
        sel.handleTap("a", "browse")
        sel.handleTap("d", "browse")
        assertEquals(listOf("a", "c", "d"), sel.orderedSelection(ids))
        assertEquals(listOf("d", "c", "a"), sel.orderedSelection(listOf("d", "x", "c", "a")))
    }

    @Test
    fun unregisterDisarmsOnlyOwner() {
        val sel = registered("browse")
        sel.enterSelectMode("browse", "a")
        // Another list that never took over unregisters: nothing changes.
        sel.unregisterActiveList("pocket:1")
        assertTrue(sel.state.value.isSelectMode("browse"))
        assertEquals("browse", sel.state.value.activeScope)
        // A list took over, then the old owner leaves: active list stays, mode disarms.
        sel.registerActiveList("pocket:1", { ids }, { null })
        sel.unregisterActiveList("browse")
        assertEquals("pocket:1", sel.state.value.activeScope)
        assertFalse(sel.state.value.selectMode)
        // The selection itself survives the disarm.
        assertEquals(setOf("a"), sel.state.value.ids)
    }

    @Test
    fun canCopyRequiresActiveListScope() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        assertFalse("no registered list", sel.state.value.canCopy)
        assertNull(sel.currentPayload())
        registered("pocket:1", sel = sel)
        assertFalse("selection belongs to browse, active list is the pocket", sel.state.value.canCopy)
        assertNull(sel.currentPayload())
        registered("browse", sel = sel)
        assertTrue(sel.state.value.canCopy)
        assertEquals(listOf("a"), sel.currentPayload()?.songIds)
    }

    @Test
    fun scopeSwitchResetsSelection() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        sel.enterSelectMode("pocket:1", "z")
        assertEquals(setOf("z"), sel.state.value.ids)
        assertEquals("pocket:1", sel.state.value.selectModeScope)
        assertFalse(sel.state.value.isSelected("a", "browse"))
    }

    @Test
    fun clearAndExitUnlatchesScope() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        sel.clearAndExit()
        val s = sel.state.value
        assertNull(s.scopeId); assertFalse(s.selectMode); assertFalse(s.hasSelection)
        assertFalse(s.isActive("browse"))
        sel.enterSelectMode("browse", "a")
        sel.deselectAll()
        assertTrue("deselectAll stays armed", sel.state.value.isActive("browse"))
        assertEquals(0, sel.state.value.count)
    }

    @Test
    fun barVisibleOnlyInOwnScope() {
        val sel = RowSelection()
        sel.enterSelectMode("browse", "a")
        assertTrue(sel.state.value.isActive("browse"))
        assertFalse(sel.state.value.isActive("pocket:1"))
    }

    @Test
    fun pasteTargetRegistration() {
        val sel = RowSelection()
        var got: SongTransfer? = null
        sel.registerPasteTarget("pocket:1") { got = it }
        assertTrue(sel.state.value.canPaste)
        assertFalse(sel.performPaste(SongTransfer(emptyList())))
        assertTrue(sel.performPaste(SongTransfer(listOf("a"))))
        assertEquals(listOf("a"), got?.songIds)
        sel.unregisterPasteTarget("other")
        assertTrue(sel.state.value.canPaste)
        sel.unregisterPasteTarget("pocket:1")
        assertFalse(sel.state.value.canPaste)
    }

    @Test
    fun songTransferJsonRoundTripAndCaps() {
        val songs = (1..250).associate { "s$it" to IndexSong(id = "s$it", artist = "Art", name = "N$it") }
        val t = SongTransfer.make(songs.keys.sortedBy { it.drop(1).toInt() }, songs)
        assertEquals(250, t.songIds.size)
        val lines = t.text!!.lines()
        assertEquals(SongTransfer.TEXT_LINE_CAP + 1, lines.size)
        assertEquals("Art — N1", lines.first())
        assertEquals("…and 50 more", lines.last())
        assertEquals(t, SongTransfer.decode(t.toJson()))
        // iOS shape: {"songIds":[...],"text":"..."}; text optional.
        assertEquals(listOf("a", "b"), SongTransfer.decode("""{"songIds":["a","b"]}""")?.songIds)
        assertEquals("a\nb", SongTransfer(listOf("a", "b")).plainTextExport)
        assertNull(SongTransfer.decode("not json"))
        assertNull(SongTransfer.decode("""{"songIds":"${"x".repeat(SongTransfer.MAX_PAYLOAD_BYTES)}"}"""))
    }
}
