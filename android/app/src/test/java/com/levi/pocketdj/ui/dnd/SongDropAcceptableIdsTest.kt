package com.levi.pocketdj.ui.dnd

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.SongDrop
import com.levi.pocketdj.data.collections.SongTransfer
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SongDropAcceptableIdsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store(): CollectionsStore {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        return CollectionsStore(f, now = { 1_750_000_000_000.0 }, writer = VersionedJsonWriter(f))
    }

    @Test
    fun dedupesPreservingOrderAcrossItems() {
        val out = SongDrop.acceptableIds(
            listOf(SongTransfer(listOf("b", "a", "b")), SongTransfer(listOf("a", "c"))),
        ) { true }
        assertEquals(listOf("b", "a", "c"), out)
    }

    @Test
    fun dropsOverlongAndUnresolvableIds() {
        val long = "x".repeat(SongDrop.MAX_ID_LENGTH + 1)
        val ok = "y".repeat(SongDrop.MAX_ID_LENGTH)
        val out = SongDrop.acceptableIds(listOf(SongTransfer(listOf(long, ok, "ghost", "sng_1")))) { it != "ghost" }
        assertEquals(listOf(ok, "sng_1"), out)
    }

    @Test
    fun emptyAndAllUnresolvedAreNoOps() {
        var calls = 0
        assertFalse(SongDrop.accept(emptyList(), { true }) { calls++; 1 })
        assertFalse(SongDrop.accept(listOf(SongTransfer(listOf("a"))), { false }) { calls++; 1 })
        assertEquals(0, calls)
    }

    @Test
    fun dropOnPlaylistAddsToDefaultChapterThenSelfDropWritesNothing() {
        val s = store()
        val pl = s.createPlaylist("PL")
        val t = SongTransfer(listOf("sng_1", "sng_2"))
        val target = AddTarget(AddTarget.Kind.PLAYLIST, pl.id)
        assertTrue(acceptSongsIntoFn(s, target, t))
        assertEquals(listOf("sng_1", "sng_2"), s.playlist(pl.id)!!.sequences[0].children!!.map { it.songId })
        val file = File(tmp.root, CollectionsStore.FILE_NAME)
        val before = file.readText()
        // Self-drop of songs already present: nothing added, nothing written.
        assertFalse(acceptSongsIntoFn(s, target, t))
        assertEquals(before, file.readText())
        assertEquals(2, s.playlist(pl.id)!!.sequences[0].children!!.size)
    }

    @Test
    fun dropOnPocketAndForeignIdsNeverPersist() {
        val s = store()
        val p = s.createPocket("P")
        val target = AddTarget(AddTarget.Kind.POCKET, p.id)
        assertTrue(SongDrop.accept(listOf(SongTransfer(listOf("sng_1", "hello world"))), { it.startsWith("sng_") }) { s.addSongs(it, target) })
        assertEquals(listOf("sng_1"), s.pocket(p.id)!!.songIds)
        // Store gate with no catalog wired: nothing resolves, so a drop is refused outright.
        assertFalse(s.songResolves("hello world"))
        assertFalse(s.songResolves("sng_1"))
    }

    private fun acceptSongsIntoFn(s: CollectionsStore, target: AddTarget, t: SongTransfer): Boolean =
        SongDrop.accept(listOf(t), { true }) { s.addSongs(it, target) }
}
