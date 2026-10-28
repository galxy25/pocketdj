package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexAlbum
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

class RemoveDuplicatesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val hooks = mutableListOf<CollectionsStore.ActivityHook>()
    private var clock = 1_750_000_000_000.0

    private fun song(id: String, name: String, artist: String, am: String? = null, album: String? = "alb") =
        IndexSong(id = id, albumId = album, artist = artist, name = name, appleMusicId = am)

    private fun store(): CollectionsStore {
        val songs = listOf(
            song("s1", "Never Let Me Down", "Kanye West, Jay-Z & J-Ivy"),
            song("s2", "All Falls Down", "Kanye West"),
            song("s3", "Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", am = "9"),
            song("s4", "Never Let Me Down", "Kanye West, Jay-Z & J-Ivy"), // exact twin of s1
        )
        val album = IndexAlbum(id = "alb", artist = "Kanye West", name = "The College Dropout")
        val merged = MergedCatalog.EMPTY.copy(
            songs = songs,
            songsById = songs.associateBy { it.id },
            albums = listOf(album),
            albumsById = mapOf("alb" to album),
        )
        return CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { clock }).also {
            it.catalogProvider = { merged }
            it.onActivity = { h -> hooks.add(h) }
        }
    }

    @Test fun pocketSurvivorPrefersAppleMusicId() {
        val st = store()
        val p = st.createPocket("P", listOf("s1", "s2", "s3", "ghost"))
        assertEquals(1, st.removeDuplicatesInPocket(p.id))
        assertEquals(listOf("s3", "s2", "ghost"), st.pocket(p.id)!!.songIds)
        assertEquals(0, st.removeDuplicatesInPocket(p.id)) // idempotent
    }

    @Test fun repeatsFollowSurvivor() {
        val st = store()
        val p = st.createPocket("P", listOf("s1", "s2", "s3", "s4"))
        st.setSongRepeat("s1", 3, p.id)
        st.setSongRepeat("s4", 5, p.id)
        st.setSongRepeat("s2", 2, p.id)
        assertEquals(2, st.removeDuplicatesInPocket(p.id))
        val after = st.pocket(p.id)!!
        assertEquals(listOf("s3", "s2"), after.songIds)
        assertEquals(3, after.songRepeats["s3"])
        assertNull(after.songRepeats["s1"])
        assertNull(after.songRepeats["s4"])
        assertEquals(2, after.songRepeats["s2"])
    }

    @Test fun playlistPruneByOriginalId() {
        val st = store()
        val pl = st.createPlaylist("PL", listOf("s1", "s2", "s3", "s4"))
        assertEquals(2, st.removeDuplicatesInPlaylist(pl.id))
        // s1 renamed to s3 in the earliest slot; the original s3 node is pruned, not the renamed one.
        assertEquals(listOf("s3", "s2"), st.playlist(pl.id)!!.sequences[0].children!!.map { it.songId })
    }

    @Test fun everywhereOneSave() {
        val st = store()
        st.createPocket("P", listOf("s1", "s3"))
        st.createPlaylist("PL", listOf("s1", "s2", "s3"))
        val before = st.state.value.revision
        assertEquals(2, st.removeDuplicatesEverywhere())
        assertEquals(before + 1, st.state.value.revision) // single publish/save
        assertEquals(0, st.removeDuplicatesEverywhere())
        assertEquals(before + 1, st.state.value.revision) // nothing to do ⇒ nothing saved
    }

    @Test fun noActivityEmitted() {
        val st = store()
        val p = st.createPocket("P", listOf("s1", "s3"))
        st.createPlaylist("PL", listOf("s1", "s3"))
        st.removeDuplicatesInPocket(p.id)
        st.removeDuplicatesEverywhere()
        assertTrue(hooks.isEmpty())
    }

    @Test fun reconcileSkipsIdentityTwin() {
        val st = store()
        val src = SourcePlaylist(IndexPlaylist("pl_src", "Src", listOf("s2")), "Apple Music (Local)")
        val pocket = st.convertSourceToPocket(src)
        val pl = st.duplicateForSource(src)
        st.addSongToPocket("s1", pocket.id)
        st.addSongToPlaylist("s1", pl.id)
        // Upstream adds s3 (feat. twin of s1 on the same album) and s2 stays.
        st.syncConvertedCollections(listOf(SourcePlaylist(IndexPlaylist("pl_src", "Src", listOf("s2", "s3")), "Apple Music (Local)")))
        assertEquals(listOf("s2", "s1"), st.pocket(pocket.id)!!.songIds)
        assertEquals(
            listOf("s2", "s1"),
            st.playlist(pl.id)!!.sequences[0].children!!.map { it.songId },
        )
    }
}
