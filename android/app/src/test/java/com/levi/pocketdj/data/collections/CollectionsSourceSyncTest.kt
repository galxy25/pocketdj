package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CollectionsSourceSyncTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private var clock = 1_750_000_000_000.0
    private val songs = listOf("a", "b", "c", "d").map { IndexSong(id = it, artist = "Artist $it", name = "Song $it") }

    private fun catalog(vararg pls: SourcePlaylist) =
        MergedCatalog.EMPTY.copy(songs = songs, songsById = songs.associateBy { it.id }, playlists = pls.toList())

    private fun src(ids: List<String>, id: String = "pl1") =
        SourcePlaylist(IndexPlaylist(id = id, name = "Mix", songIds = ids), "Apple Music (Local)")

    private lateinit var writer: VersionedJsonWriter

    private fun store(): CollectionsStore {
        val f = File(tmp.root, CollectionsStore.FILE_NAME)
        writer = VersionedJsonWriter(f)
        return CollectionsStore(file = f, writer = writer, now = { clock })
    }

    @Test fun autoPassRespectsGlobalToggle() {
        val st = store()
        val p = st.convertSourceToPocket(src(listOf("a", "b")))
        val cat = catalog(src(listOf("a", "b", "c")))
        assertEquals(0, SourceSyncSettings.autoPass(false, cat, st))
        assertEquals(listOf("a", "b"), st.pocket(p.id)!!.songIds)
        assertEquals(1, SourceSyncSettings.autoPass(true, cat, st))
        assertEquals(listOf("a", "b", "c"), st.pocket(p.id)!!.songIds)
        assertEquals(0, SourceSyncSettings.autoPass(true, null, st))
    }

    @Test fun userRemovalSurvivesAutoPass() {
        val st = store()
        val p = st.convertSourceToPocket(src(listOf("a", "b")))
        st.removeSongFromPocket("b", p.id)
        SourceSyncSettings.autoPass(true, catalog(src(listOf("a", "b", "c"))), st)
        assertEquals(listOf("a", "c"), st.pocket(p.id)!!.songIds)
    }

    @Test fun pullDisabledSkipsItem() {
        val st = store()
        val push = st.convertSourceToPocket(src(listOf("a")))
        val off = st.convertSourceToPocket(src(listOf("a")))
        val both = st.convertSourceToPocket(src(listOf("a")))
        val pull = st.convertSourceToPocket(src(listOf("a")))
        st.setAMSyncDirectionForPocket(CollectionSyncDirection.PUSH, push.id)
        st.setAMSyncDirectionForPocket(CollectionSyncDirection.OFF, off.id)
        st.setAMSyncDirectionForPocket(CollectionSyncDirection.PULL, pull.id)
        val pl = st.duplicateForSource(src(listOf("a")))
        st.setAMSyncDirectionForPlaylist(CollectionSyncDirection.PUSH, pl.id)
        val n = st.syncConvertedCollections(listOf(src(listOf("a", "b"))))
        assertEquals(2, n)
        assertEquals(listOf("a"), st.pocket(push.id)!!.songIds)
        assertEquals(listOf("a"), st.pocket(off.id)!!.songIds)
        assertEquals(listOf("a", "b"), st.pocket(both.id)!!.songIds)
        assertEquals(listOf("a", "b"), st.pocket(pull.id)!!.songIds)
        assertEquals(1, st.playlist(pl.id)!!.sequences.sumOf { it.children.orEmpty().size })
    }

    @Test fun manualIgnoresToggles() {
        val st = store()
        val p = st.convertSourceToPocket(src(listOf("a")))
        st.setPocketSourceSyncEnabled(false, p.id)
        st.setAMSyncDirectionForPocket(CollectionSyncDirection.OFF, p.id)
        st.catalogProvider = { catalog(src(listOf("a", "d"))) }
        assertEquals(0, SourceSyncSettings.autoPass(true, catalog(src(listOf("a", "d"))), st))
        assertEquals(listOf("a"), st.pocket(p.id)!!.songIds)
        assertTrue(st.syncPocketFromSourceNow(p.id))
        assertEquals(listOf("a", "d"), st.pocket(p.id)!!.songIds)
    }

    @Test fun missingSourceUntouched() {
        val st = store()
        val p = st.convertSourceToPocket(src(listOf("a", "b")))
        val before = st.pocket(p.id)!!
        assertEquals(0, st.syncConvertedCollections(listOf(src(listOf("a"), id = "other"))))
        assertEquals(before, st.pocket(p.id))
    }

    @Test fun noChangeRefreshPersistsNothing() {
        val st = store()
        st.convertSourceToPocket(src(listOf("a", "b")))
        val writes = writer.writeCount
        val rev = st.state.value.revision
        assertEquals(0, st.syncConvertedCollections(listOf(src(listOf("a", "b")))))
        assertEquals(writes, writer.writeCount)
        assertEquals(rev, st.state.value.revision)
    }

    @Test fun linkableSourcesAreAppleMusicOnlyNameOrdered() {
        val other = SourcePlaylist(IndexPlaylist("x", "Zed"), "My Digital")
        val b = SourcePlaylist(IndexPlaylist("b", "banana"), "Apple Music (Local)")
        val a = SourcePlaylist(IndexPlaylist("a", "Apple"), "Apple Music (Local)")
        assertEquals(listOf("a", "b"), SourceSyncSettings.linkableSources(listOf(other, b, a)).map { it.playlist.id })
    }
}
