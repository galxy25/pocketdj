package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * USER vs SHARED crossing (specs/collections-schema.md §8): provenance
 * stamping, the duplicateForSource find-or-create primitive (id+sourceName
 * identity, legacy nil-sourceName concession), and the three-way merge
 * (adds/removes/user-edits-survive/no-op-persists-nothing/missing-source-untouched).
 */
class CollectionsSourceSyncTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private var clock = 1_750_000_000_000.0

    private fun newStore(): CollectionsStore =
        CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { clock })

    private fun source(
        id: String = "pl_src",
        name: String = "AM Mix",
        songIds: List<String> = listOf("sng_1", "sng_2"),
        sourceName: String = "Apple Music (Local)",
    ) = SourcePlaylist(IndexPlaylist(id = id, name = name, songIds = songIds), sourceName)

    // MARK: Provenance stamping

    @Test
    fun convertSourceToPocket_stampsProvenance_dedupesOrderPreserving() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source(songIds = listOf("sng_2", "sng_1", "sng_2")))
        assertEquals(listOf("sng_2", "sng_1"), pocket.songIds)
        assertEquals("pl_src", pocket.sourcePlaylistId)
        assertEquals("Apple Music (Local)", pocket.sourceName)
        assertEquals(listOf("sng_2", "sng_1"), pocket.sourceSongIds)
        assertTrue(pocket.syncsWithSource) // nil toggle ⇒ enabled
    }

    @Test
    fun duplicateForSource_stampsProvenance_seedsDefaultChapter() {
        val store = newStore()
        val pl = store.duplicateForSource(source())
        assertEquals("AM Mix", pl.name)
        assertEquals("pl_src", pl.sourcePlaylistId)
        assertEquals("Apple Music (Local)", pl.sourceName)
        assertEquals(listOf("sng_1", "sng_2"), pl.sourceSongIds)
        assertEquals(
            listOf("sng_1", "sng_2"),
            pl.sequences[0].children!!.map { it.songId },
        )
    }

    // MARK: Find-or-create (the ONE primitive)

    @Test
    fun duplicateForSource_findsExisting_neverMintsARival() {
        val store = newStore()
        val first = store.duplicateForSource(source())
        val second = store.duplicateForSource(source())
        assertEquals(first.id, second.id)
        assertEquals(1, store.playlists.size)
    }

    @Test
    fun duplicateForSource_disambiguatesSameIdAcrossSources() {
        val store = newStore()
        val am = store.duplicateForSource(source(sourceName = "Apple Music (Local)"))
        val digital = store.duplicateForSource(source(sourceName = "My Digital"))
        assertFalse(am.id == digital.id)
        assertEquals(2, store.playlists.size)
    }

    @Test
    fun duplicateForSource_legacyNilSourceNameDuplicate_matchesByIdAlone() {
        val store = newStore()
        // A legacy duplicate stamped before sourceName existed.
        val legacy = store.createPlaylist("Old Copy", listOf("sng_1"))
        // Simulate the legacy stamp (provenance id, no sourceName): reconcile
        // fixtures can't create this state through the public API, so decode it.
        val stamped = legacy.copy(sourcePlaylistId = "pl_src", sourceName = null)
        store.deletePlaylist(legacy.id)
        val file = File(tmp.root, CollectionsStore.FILE_NAME)
        val doc = CollectionsDocument(playlists = listOf(stamped))
        file.writeText(CollectionsCodec.encode(com.levi.pocketdj.data.PdjJson.lenient, doc))
        val relaunched = CollectionsStore(file = file, now = { clock })

        val found = relaunched.duplicateForSource(source())
        assertEquals(stamped.id, found.id)
        assertEquals(1, relaunched.playlists.size)
    }

    // MARK: Three-way merge — pocket

    @Test
    fun reconcilePocket_appliesAddsAndRemoves_userEditsSurvive() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source(songIds = listOf("sng_1", "sng_2")))
        // User's own edits: add sng_user, remove nothing, set a repeat on a
        // source song that will be REMOVED upstream.
        store.addSongToPocket("sng_user", pocket.id)
        store.setSongRepeat("sng_1", 4, pocket.id)

        // Upstream: removed sng_1, added sng_3.
        val changed = store.syncConvertedCollections(
            listOf(source(songIds = listOf("sng_2", "sng_3"))),
        )

        assertEquals(1, changed)
        val fresh = store.pocket(pocket.id)!!
        assertEquals(listOf("sng_2", "sng_user", "sng_3"), fresh.songIds)
        assertNull(fresh.songRepeats["sng_1"]) // removed member's repeat cleared
        assertEquals(listOf("sng_2", "sng_3"), fresh.sourceSongIds) // snapshot advanced
        assertEquals(clock, fresh.sourceSyncedAt!!, 0.0)
    }

    @Test
    fun reconcile_sourceAddTheUserAlreadyHas_isNotDuplicated() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source(songIds = listOf("sng_1")))
        store.addSongToPocket("sng_2", pocket.id) // user adds it first

        store.syncConvertedCollections(listOf(source(songIds = listOf("sng_1", "sng_2"))))

        assertEquals(listOf("sng_1", "sng_2"), store.pocket(pocket.id)!!.songIds)
    }

    @Test
    fun reconcile_noChange_persistsNothing() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source())
        val revisionBefore = store.state.value.revision
        val updatedAtBefore = store.pocket(pocket.id)!!.updatedAt

        val changed = store.syncConvertedCollections(listOf(source()))

        assertEquals(0, changed)
        assertEquals(revisionBefore, store.state.value.revision)
        assertEquals(updatedAtBefore, store.pocket(pocket.id)!!.updatedAt, 0.0)
    }

    @Test
    fun reconcile_missingSource_leavesTheItemUntouched() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source())
        val changed = store.syncConvertedCollections(
            listOf(source(id = "pl_other", songIds = emptyList())),
        )
        assertEquals(0, changed)
        assertEquals(listOf("sng_1", "sng_2"), store.pocket(pocket.id)!!.songIds)
    }

    @Test
    fun reconcile_disabledToggle_skipsAutoPass_manualSyncStillWorks() {
        val store = newStore()
        val pocket = store.convertSourceToPocket(source())
        store.setPocketSourceSyncEnabled(false, pocket.id)

        val fresh = source(songIds = listOf("sng_9"))
        assertEquals(0, store.syncConvertedCollections(listOf(fresh)))
        assertEquals(listOf("sng_1", "sng_2"), store.pocket(pocket.id)!!.songIds)

        // Manual "Sync now" ignores the toggle (needs the live catalog).
        store.catalogProvider = {
            com.levi.pocketdj.data.catalog.MergedCatalog.EMPTY.copy(playlists = listOf(fresh))
        }
        assertTrue(store.syncPocketFromSourceNow(pocket.id))
        assertEquals(listOf("sng_9"), store.pocket(pocket.id)!!.songIds)
    }

    @Test
    fun setSourceSyncEnabled_noOpsOnHandMadeItems() {
        val store = newStore()
        val pocket = store.createPocket("Hand Made")
        store.setPocketSourceSyncEnabled(false, pocket.id)
        assertNull(store.pocket(pocket.id)!!.sourceSyncEnabled)
    }

    // MARK: Three-way merge — playlist

    @Test
    fun reconcilePlaylist_prunesRemovedSongNodesRecursively_addsLandInDefaultChapter() {
        val store = newStore()
        val pl = store.duplicateForSource(source(songIds = listOf("sng_1", "sng_2")))
        // User adds a sub-chapter carrying a source song that will be removed,
        // plus their own song and a text cue.
        store.addSequence("Encore", pl.id)
        val encoreId = store.playlist(pl.id)!!.sequences[1].nodeId
        store.addSongToPlaylist("sng_1", pl.id, sequenceId = encoreId) // second node w/ same id
        store.addSongToPlaylist("sng_user", pl.id, sequenceId = encoreId)
        store.addTextToPlaylist("mic break", pl.id)

        // Upstream: removed sng_1, added sng_3.
        val changed = store.syncConvertedCollections(
            listOf(source(songIds = listOf("sng_2", "sng_3"))),
        )
        assertEquals(1, changed)

        val fresh = store.playlist(pl.id)!!
        val defaultIds = fresh.sequences[0].children!!.map { it.songId ?: it.text }
        val encoreIds = fresh.sequences[1].children!!.map { it.songId }
        // EVERY sng_1 node dropped (both chapters); the add landed in Default.
        assertEquals(listOf("sng_2", "mic break", "sng_3"), defaultIds)
        assertEquals(listOf("sng_user"), encoreIds)
        assertEquals(listOf("sng_2", "sng_3"), fresh.sourceSongIds)
    }

    @Test
    fun addSongToIndexPlaylist_secondAddIsAlreadyPresent_noDuplicateNode() {
        val store = newStore()
        val src = source()
        val first = store.addSongToIndexPlaylist("sng_9", src)
        assertTrue(first.createdDuplicate)
        assertFalse(first.alreadyPresent)

        val second = store.addSongToIndexPlaylist("sng_9", src)
        assertFalse(second.createdDuplicate)
        assertTrue(second.alreadyPresent)
        assertEquals(1, store.playlists.size)
        assertEquals(
            1,
            second.playlist.sequences[0].children!!.count { it.songId == "sng_9" },
        )
    }

    // MARK: COL-7 auto pass / direction gate / link

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
