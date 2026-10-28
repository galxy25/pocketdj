package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.SourcePlaylist
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CollectionsLinkTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store() = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })

    private fun src(ids: List<String>, id: String = "pl1") =
        SourcePlaylist(IndexPlaylist(id = id, name = "Mix $id", songIds = ids), "Apple Music (Local)")

    @Test fun linkSnapshotsCurrentMembership() {
        val st = store()
        val p = st.createPocket("Hand made", listOf("a", "x"))
        assertFalse(st.pocket(p.id)!!.hasSource)
        assertTrue(st.linkPocketToSource(p.id, src(listOf("a", "b", "b", "c"))))
        val linked = st.pocket(p.id)!!
        assertTrue(linked.hasSource)
        assertEquals("pl1", linked.sourcePlaylistId)
        assertEquals("Apple Music (Local)", linked.sourceName)
        assertEquals(listOf("a", "b", "c"), linked.sourceSongIds) // deduped current membership
        assertEquals(listOf("a", "x"), linked.songIds) // the user's own songs untouched
        assertNull(linked.sourceSyncEnabled) // not forced
        assertTrue(linked.syncsWithSource)
        // The user's extra "x" must read as a user add, never a source removal.
        st.syncConvertedCollections(listOf(src(listOf("a", "b", "c"))))
        assertEquals(listOf("a", "x"), st.pocket(p.id)!!.songIds)
        assertFalse(st.linkPocketToSource("ghost", src(emptyList())))
    }

    @Test fun relinkCancelsOldWriteBacks() {
        val st = store()
        val calls = mutableListOf<Pair<String, Set<String>>>()
        st.cancelPendingWriteBacks = { id, songs -> calls.add(id to songs) }
        val p = st.createPocket("P", listOf("a", "b"))
        st.linkPocketToSource(p.id, src(listOf("a"), id = "old"))
        assertTrue(calls.isEmpty()) // first link: nothing to cancel
        st.linkPocketToSource(p.id, src(listOf("a"), id = "old")) // same source: nothing
        assertTrue(calls.isEmpty())
        st.linkPocketToSource(p.id, src(listOf("b"), id = "new"))
        assertEquals(listOf("old" to setOf("a", "b")), calls)
        assertEquals("new", st.pocket(p.id)!!.sourcePlaylistId)
    }

    @Test fun relinkPreservesExplicitOff() {
        val st = store()
        val p = st.createPocket("P", listOf("a"))
        st.linkPocketToSource(p.id, src(listOf("a"), id = "one"))
        st.setPocketSourceSyncEnabled(false, p.id)
        st.linkPocketToSource(p.id, src(listOf("a", "b"), id = "two"))
        val after = st.pocket(p.id)!!
        assertEquals(false, after.sourceSyncEnabled)
        assertFalse(after.syncsWithSource)
        assertEquals(listOf("a", "b"), after.sourceSongIds)
    }
}
