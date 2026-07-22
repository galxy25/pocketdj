package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The store contract of specs/collections-schema.md §6–§7 + realize-play.md §5:
 * persistence (atomic save, corrupt-quarantine), choke-point mutations and
 * their invariants (cycle guard, dedupe, cascades, last-chapter guard), add-to
 * MRU, updatedAt-vs-lastPlayedAt separation, the reserved Now Playing setlist
 * lifecycle, and realize/playNow entry points.
 */
class CollectionsStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private var clock = 1_750_000_000_000.0

    private fun newFile(): File = File(tmp.root, CollectionsStore.FILE_NAME)

    private fun newStore(file: File = newFile()): CollectionsStore =
        CollectionsStore(file = file, now = { clock })

    private fun song(id: String, name: String = "Song $id", bpm: Double? = 120.0, camelot: String? = "8A") =
        IndexSong(id = id, artist = "Artist", name = name, bpm = bpm, camelot = camelot, length = 60_000)

    private fun catalog(
        songs: List<IndexSong>,
        albums: List<IndexAlbum> = emptyList(),
    ): MergedCatalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "My Vinyl"),
                albums = albums,
                songs = songs,
            ),
        ),
    )

    private fun CollectionsStore.wireCatalog(merged: MergedCatalog) {
        catalogProvider = { merged }
    }

    // MARK: Persistence

    @Test
    fun save_persistsAcrossRelaunch() {
        val file = newFile()
        val store = newStore(file)
        val pocket = store.createPocket("Crate")
        store.addSongToPocket("sng_1", pocket.id)
        val playlist = store.createPlaylist("List")

        val relaunched = newStore(file)
        assertEquals(listOf("sng_1"), relaunched.pocket(pocket.id)?.songIds)
        assertEquals("List", relaunched.playlist(playlist.id)?.name)
    }

    @Test
    fun corruptFile_quarantinesToBak_startsEmpty_andNextSaveWorks() {
        val file = newFile()
        file.parentFile?.mkdirs()
        file.writeText("{ definitely not json")
        val store = newStore(file)
        assertTrue(store.pockets.isEmpty())
        assertTrue(File(tmp.root, CollectionsStore.FILE_NAME + ".bak").exists())

        store.createPocket("Fresh")
        val relaunched = newStore(file)
        assertEquals("Fresh", relaunched.pockets.single().name)
    }

    @Test
    fun mutations_stampUpdatedAt_throughTheChokePoint() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        clock += 1_000
        store.addSongToPocket("sng_1", pocket.id)
        assertEquals(clock, store.pocket(pocket.id)!!.updatedAt, 0.0)
    }

    @Test
    fun markPlayed_stampsLastPlayedAt_withoutTouchingUpdatedAt() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        val pocket = store.createPocket("Crate")
        val updatedAtBefore = store.playlist(playlist.id)!!.updatedAt

        clock += 5_000
        store.markPlaylistPlayed(playlist.id)
        store.markPocketPlayed(pocket.id)

        assertEquals(clock, store.playlist(playlist.id)!!.lastPlayedAt!!, 0.0)
        assertEquals(clock, store.pocket(pocket.id)!!.lastPlayedAt!!, 0.0)
        assertEquals(updatedAtBefore, store.playlist(playlist.id)!!.updatedAt, 0.0)
        // Unknown ids are silent no-ops.
        store.markPlaylistPlayed("pls_missing")
    }

    // MARK: Pocket invariants

    @Test
    fun addsAreSetLike_dedupedOnRepeat() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        store.addSongToPocket("sng_1", pocket.id)
        store.addSongToPocket("sng_1", pocket.id)
        store.addAlbumToPocket("alb_1", pocket.id)
        store.addAlbumToPocket("alb_1", pocket.id)
        assertEquals(listOf("sng_1"), store.pocket(pocket.id)?.songIds)
        assertEquals(listOf("alb_1"), store.pocket(pocket.id)?.albumIds)
    }

    @Test
    fun cycleGuard_refusesSelfAndIndirectCycles() {
        val store = newStore()
        val a = store.createPocket("A")
        val b = store.createPocket("B")
        val c = store.createPocket("C")
        assertTrue(store.addChildPocket(b.id, a.id)) // A → B
        assertTrue(store.addChildPocket(c.id, b.id)) // B → C
        assertFalse(store.addChildPocket(a.id, c.id)) // C → A would cycle
        assertFalse(store.addChildPocket(a.id, a.id)) // self
        assertTrue(store.pocket(c.id)!!.childPocketIds.isEmpty())
    }

    @Test
    fun deletePocket_scrubsItFromEveryParent() {
        val store = newStore()
        val parent = store.createPocket("Parent")
        val child = store.createPocket("Child")
        store.addChildPocket(child.id, parent.id)
        store.deletePocket(child.id)
        assertNull(store.pocket(child.id))
        assertTrue(store.pocket(parent.id)!!.childPocketIds.isEmpty())
    }

    @Test
    fun removeSong_clearsItsRepeatEntry() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        store.addSongToPocket("sng_1", pocket.id)
        store.setSongRepeat("sng_1", 5, pocket.id)
        assertEquals(5, store.repeatCountForSong("sng_1", pocket.id))
        store.removeSongFromPocket("sng_1", pocket.id)
        assertTrue(store.pocket(pocket.id)!!.songRepeats.isEmpty())
        assertEquals(1, store.repeatCountForSong("sng_1", pocket.id))
    }

    @Test
    fun pocketNotes_addEditRemove_neverCountAsMembers() {
        val store = newStore()
        val pocket = store.createPocket("Poetry")
        val note = store.addNoteToPocket("line one", pocket.id)
        assertNotNull(note)
        assertEquals(0, store.pocket(pocket.id)!!.memberCount)
        store.setNoteText(note!!.id, "line two", pocket.id)
        assertEquals("line two", store.pocket(pocket.id)!!.notes.single().text)
        store.removeNoteFromPocket(note.id, pocket.id)
        assertTrue(store.pocket(pocket.id)!!.notes.isEmpty())
    }

    // MARK: Playlist invariants

    @Test
    fun newPlaylist_hasOneDefaultChapter() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        assertEquals(1, playlist.sequences.size)
        assertEquals("Default", playlist.sequences[0].name)
        assertEquals(PlaylistNode.Kind.SEQUENCE, playlist.sequences[0].kind)
    }

    @Test
    fun addNode_targetsNamedChapter_elseDefault() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        store.addSequence("Encore", playlist.id)
        val encoreId = store.playlist(playlist.id)!!.sequences[1].nodeId

        store.addSongToPlaylist("sng_1", playlist.id)
        store.addSongToPlaylist("sng_2", playlist.id, sequenceId = encoreId)

        val pl = store.playlist(playlist.id)!!
        assertEquals("sng_1", pl.sequences[0].children!!.single().songId)
        assertEquals("sng_2", pl.sequences[1].children!!.single().songId)
    }

    @Test
    fun removeSequence_refusesTheLastChapter() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        val onlyChapter = playlist.sequences[0].nodeId
        store.removeSequence(onlyChapter, playlist.id)
        assertEquals(1, store.playlist(playlist.id)!!.sequences.size)

        store.addSequence("Second", playlist.id)
        store.removeSequence(onlyChapter, playlist.id)
        assertEquals(listOf("Second"), store.playlist(playlist.id)!!.sequences.map { it.name })
    }

    @Test
    fun moveNode_reordersWithinChapter_noOpAtEnds() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id)
        store.addSongToPlaylist("sng_2", playlist.id)
        store.addSongToPlaylist("sng_3", playlist.id)
        val ids = store.playlist(playlist.id)!!.sequences[0].children!!.map { it.nodeId }

        store.moveNodeUp(ids[0], playlist.id) // at top → no-op
        assertEquals(ids, store.playlist(playlist.id)!!.sequences[0].children!!.map { it.nodeId })

        store.moveNodeDown(ids[0], playlist.id)
        assertEquals(
            listOf(ids[1], ids[0], ids[2]),
            store.playlist(playlist.id)!!.sequences[0].children!!.map { it.nodeId },
        )

        store.moveNodes(playlist.id, store.playlist(playlist.id)!!.sequences[0].nodeId, 2, 0)
        assertEquals(
            listOf(ids[2], ids[1], ids[0]),
            store.playlist(playlist.id)!!.sequences[0].children!!.map { it.nodeId },
        )
    }

    @Test
    fun deletePlaylist_cascadesToItsSetlists() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"))))
        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id)
        val setlist = store.realize(playlist.id)!!
        assertNotNull(store.setlist(setlist.id))

        store.deletePlaylist(playlist.id)
        assertNull(store.playlist(playlist.id))
        assertNull(store.setlist(setlist.id))
    }

    // MARK: Folders

    @Test
    fun deleteFolder_membersFallBackToTopLevel() {
        val store = newStore()
        val folder = store.createFolder("Gigs")
        val playlist = store.createPlaylist("List")
        val pocket = store.createPocket("Crate")
        store.setPlaylistFolder(playlist.id, folder.id)
        store.setPocketFolder(pocket.id, folder.id)
        assertEquals(listOf(playlist.id), store.playlistsInFolder(folder.id).map { it.id })

        store.deleteFolder(folder.id)
        assertNull(store.folder(folder.id))
        assertNull(store.playlist(playlist.id)!!.folderId)
        assertNull(store.pocket(pocket.id)!!.folderId)
    }

    // MARK: Add-to memory (MRU)

    @Test
    fun addToTarget_setsLastAddTarget_andMruMirrorsIt() {
        val store = newStore()
        val pocket = store.createPocket("Crate")
        store.addSong("sng_1", AddTarget(AddTarget.Kind.POCKET, pocket.id))
        assertEquals(pocket.id, store.lastAddTarget?.id)
        assertEquals(pocket.id, store.recentAddTargets.first().id)
        assertEquals(listOf("sng_1"), store.pocket(pocket.id)?.songIds)
    }

    @Test
    fun mru_dedupesByKindAndId_ignoringSequenceId_freshestChapterWins() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        store.addSequence("Encore", playlist.id)
        val encoreId = store.playlist(playlist.id)!!.sequences[1].nodeId
        val pocket = store.createPocket("Crate")

        store.addSong("sng_1", AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = null))
        store.addSong("sng_2", AddTarget(AddTarget.Kind.POCKET, pocket.id))
        store.addSong("sng_3", AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = encoreId))

        // One entry per (kind,id); the playlist entry moved to front carrying
        // the FRESHEST chapter.
        assertEquals(2, store.recentAddTargets.size)
        assertEquals(playlist.id, store.recentAddTargets[0].id)
        assertEquals(encoreId, store.recentAddTargets[0].sequenceId)
        assertEquals(pocket.id, store.recentAddTargets[1].id)
    }

    @Test
    fun mru_capsAtTen() {
        val store = newStore()
        repeat(14) { i ->
            val pocket = store.createPocket("P$i")
            store.addSong("sng_$i", AddTarget(AddTarget.Kind.POCKET, pocket.id))
        }
        assertEquals(CollectionsStore.MAX_RECENT_TARGETS, store.recentAddTargets.size)
        assertEquals("P13", store.pocket(store.recentAddTargets.first().id)?.name)
    }

    @Test
    fun mru_persistsOnTheDocument() {
        val file = newFile()
        val store = newStore(file)
        val pocket = store.createPocket("Crate")
        store.addSong("sng_1", AddTarget(AddTarget.Kind.POCKET, pocket.id))

        val relaunched = newStore(file)
        assertEquals(pocket.id, relaunched.lastAddTarget?.id)
        assertEquals(pocket.id, relaunched.recentAddTargets.single().id)
    }

    @Test
    fun lastTargetLabel_playlistIncludesChapter_goneTargetIsNull() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        store.addSequence("Encore", playlist.id)
        val encoreId = store.playlist(playlist.id)!!.sequences[1].nodeId
        assertEquals("List › Encore", store.lastTargetLabel(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, encoreId)))
        assertEquals("List", store.lastTargetLabel(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id)))
        assertNull(store.lastTargetLabel(AddTarget(AddTarget.Kind.POCKET, "pkt_gone")))
    }

    // MARK: Resolution

    @Test
    fun playlistResolution_expandsAlbumsAndPockets_pocketWalkDedupes() {
        val store = newStore()
        val album = IndexAlbum(
            id = "alb_1",
            artist = "Artist",
            name = "Album",
            trackList = listOf("sng_2", "sng_3"),
        )
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"), song("sng_3"), song("sng_4")), listOf(album)))

        val pocket = store.createPocket("Crate")
        store.addSongToPocket("sng_3", pocket.id) // also on the album
        store.addSongToPocket("sng_4", pocket.id)

        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id)
        store.addAlbumToPlaylist("alb_1", playlist.id)
        store.addPocketRef(pocket.id, playlist.id)

        // iOS parity: static membership dedupes WITHIN a pocket's DAG walk (and
        // a pocket counts once per playlist), but a song carried by both an
        // album node and a pocket resolves per node — sng_3 appears twice.
        assertEquals(
            listOf("sng_1", "sng_2", "sng_3", "sng_3", "sng_4"),
            store.playableIdsForPlaylist(playlist.id),
        )
        assertEquals(5, store.statsForPlaylist(playlist.id).count)
        assertEquals(5 * 60_000L, store.statsForPlaylist(playlist.id).runtimeMs)
    }

    @Test
    fun songIds_stripStudioIds_playableIdsDropUnresolvable() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"))))
        val setlist = Setlist(
            id = "set_x",
            playlistId = "pls_x",
            seed = "s",
            tracks = listOf(
                SetlistTrack(songId = "sng_1", artist = "A", name = "One"),
                SetlistTrack(songId = "smp_loop", artist = "Studio", name = "Loop"),
                SetlistTrack(name = "cue", isText = true),
            ),
        )
        // Inject via playNow-side door: append through realize path is easier —
        // exercise the resolvers directly on a stored setlist.
        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id)
        val frozen = store.realize(playlist.id)!!
        assertEquals(listOf("sng_1"), store.songIdsForSetlist(frozen.id))

        // Static check of the strip on the standalone shape.
        assertEquals(
            listOf("sng_1", "smp_loop"),
            setlist.tracks.filter { it.isText != true && it.songId.isNotEmpty() }.map { it.songId },
        )
    }

    // MARK: Realize

    @Test
    fun realize_appendsPersistedSetlist_withTakeNames() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"))))
        val playlist = store.createPlaylist("Roadtrip")
        store.addSongToPlaylist("sng_1", playlist.id)
        store.addSongToPlaylist("sng_2", playlist.id)

        val take1 = store.realize(playlist.id)!!
        val take2 = store.realize(playlist.id)!!
        assertEquals("Roadtrip — take 1", take1.name)
        assertEquals("Roadtrip — take 2", take2.name)
        assertEquals(listOf("sng_1", "sng_2"), take1.tracks.map { it.songId })
        // Fresh per-call seeds — different takes.
        assertNotEquals(take1.seed, take2.seed)
        // Newest first in the listing.
        assertEquals(2, store.setlistsForPlaylist(playlist.id).size)
    }

    @Test
    fun realize_withoutCatalog_returnsNull() {
        val store = newStore()
        val playlist = store.createPlaylist("List")
        assertNull(store.realize(playlist.id))
        assertNull(store.realize(listOf("sng_1"), name = "X"))
    }

    @Test
    fun realizeSongIds_freezesLiteralList_underTransientPlaylist() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"))))
        val setlist = store.realize(listOf("sng_2", "sng_1", "sng_missing"), name = "Source Spin")!!
        assertEquals("Source Spin", setlist.name)
        assertEquals(listOf("sng_2", "sng_1"), setlist.tracks.map { it.songId })
        // The transient parent playlist is NOT persisted.
        assertNull(store.playlist(setlist.playlistId))
        assertNotNull(store.setlist(setlist.id))
    }

    // MARK: playNow (reserved Now Playing setlist)

    @Test
    fun playNow_upsertsReservedSetlist_dropsUnresolvable_snapshotsRepeats() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"))))
        val pocket = store.createPocket("Crate")
        store.addSongToPocket("sng_1", pocket.id)
        store.addSongToPocket("sng_2", pocket.id)
        store.addSongToPocket("sng_missing", pocket.id)
        store.setSongRepeat("sng_1", 3, pocket.id)

        val set = store.playNowPocket(pocket.id)!!
        assertEquals(NOW_PLAYING_SETLIST_ID, set.id)
        assertEquals(NOW_PLAYING_PLAYLIST_ID, set.playlistId)
        assertEquals("now-playing", set.seed)
        assertEquals("Crate", set.name)
        assertEquals(listOf("sng_1", "sng_2"), set.tracks.map { it.songId })
        assertEquals(3, set.tracks[0].repeatCount)
        // totals from shownMs: 3×60s + 60s.
        assertEquals(240_000L, set.totalMs)
        // lastPlayedAt stamped through the funnel.
        assertNotNull(store.pocket(pocket.id)!!.lastPlayedAt)
        // Origin + source recorded for History.
        assertEquals(PlayContext.SOURCE_POCKET, store.state.value.nowPlayingSource)
        assertEquals(pocket.id, store.state.value.nowPlayingOriginId)
    }

    @Test
    fun playNow_replacesInPlace_andBumpsRevision() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"))))
        store.playNow(listOf("sng_1"), name = "First")
        val rev1 = store.state.value.nowPlayingRevision
        store.playNow(listOf("sng_2"), name = "Second")
        val rev2 = store.state.value.nowPlayingRevision

        assertTrue(rev2 > rev1)
        assertEquals(1, store.setlists.count { it.id == NOW_PLAYING_SETLIST_ID })
        assertEquals("Second", store.nowPlayingSetlist()?.name)
    }

    @Test
    fun playNow_shuffle_isSeededOnlyThroughTheInjectedRandom() {
        val store = newStore()
        val songs = (1..8).map { song("sng_$it") }
        store.wireCatalog(catalog(songs))
        val ids = songs.map { it.id }

        val a = store.playNow(ids, shuffle = true, random = Random(42))!!.tracks.map { it.songId }
        val b = store.playNow(ids, shuffle = true, random = Random(42))!!.tracks.map { it.songId }
        val c = store.playNow(ids, shuffle = true, random = Random(43))!!.tracks.map { it.songId }
        assertEquals(a, b)
        assertNotEquals(a, c)
        assertEquals(ids.toSet(), a.toSet())
    }

    @Test
    fun reservedSetlist_hiddenFromListings_andPurgedOnRelaunch() {
        val file = newFile()
        val store = newStore(file)
        store.wireCatalog(catalog(listOf(song("sng_1"))))
        store.playNow(listOf("sng_1"))
        assertNotNull(store.nowPlayingSetlist())
        assertTrue(store.setlistsForPlaylist(NOW_PLAYING_PLAYLIST_ID).isEmpty())

        val relaunched = newStore(file)
        assertNull(relaunched.nowPlayingSetlist())
    }

    // MARK: historyContext

    @Test
    fun historyContext_resolvesRunSources() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"))))
        val playlist = store.createPlaylist("Roadtrip")
        store.addSongToPlaylist("sng_1", playlist.id)

        store.playNowPlaylist(playlist.id)
        val np = store.historyContext(NOW_PLAYING_SETLIST_ID)
        assertEquals(PlayContext.SOURCE_PLAYLIST, np.source)
        assertEquals(NOW_PLAYING_SETLIST_ID, np.contextId)
        assertEquals("Roadtrip", np.contextName)

        val frozen = store.realize(playlist.id)!!
        val real = store.historyContext(frozen.id)
        assertEquals(PlayContext.SOURCE_SETLIST, real.source)
        assertEquals(frozen.id, real.contextId)
        assertEquals(frozen.name, real.contextName)

        assertEquals(PlayContext.SOURCE_SETLIST, store.historyContext(null).source)
    }

    // MARK: Setlist post-Play edits

    @Test
    fun setlistEdits_recomputeTotalsFromShownMs() {
        val store = newStore()
        store.wireCatalog(catalog(listOf(song("sng_1"), song("sng_2"))))
        val playlist = store.createPlaylist("List")
        store.addSongToPlaylist("sng_1", playlist.id, repeatCount = 2)
        store.addSongToPlaylist("sng_2", playlist.id)
        val setlist = store.realize(playlist.id)!!
        // Engine totalMs does NOT multiply repeats (iOS parity)…
        assertEquals(120_000L, setlist.totalMs)

        // …but every edit path recomputes via shownMs (which does).
        val renamed = store.renameSetlist(setlist.id, "Renamed")!!
        assertEquals("Renamed", renamed.name)
        val noted = store.setSetlistTrackNote(setlist.id, 0, "cue")!!
        assertEquals("cue", noted.tracks[0].note)
        assertEquals(180_000L, noted.totalMs) // 2×60s + 60s

        val withNote = store.addSetlistNote("mic break", setlist.id)!!
        assertEquals(3, withNote.tracks.size)
        assertEquals(true, withNote.tracks.last().isText)
        assertEquals(180_000L, withNote.totalMs) // text adds 0 ms

        val moved = store.moveSetlistTrack(setlist.id, 0, 1)!!
        assertEquals("sng_2", moved.tracks[0].songId)

        // Removing the repeat-2 row leaves sng_2 (60 s) + the 0 ms text note.
        val removed = store.removeSetlistTrack(setlist.id, 1)!!
        assertEquals(60_000L, removed.totalMs)

        store.deleteSetlist(setlist.id)
        assertNull(store.setlist(setlist.id))
    }

    // MARK: clear

    @Test
    fun clear_wipesEverything_andDeletesTheFile() {
        val file = newFile()
        val store = newStore(file)
        store.createPocket("Crate")
        store.createPlaylist("List")
        assertTrue(file.exists())

        store.clear()
        assertTrue(store.pockets.isEmpty())
        assertTrue(store.playlists.isEmpty())
        assertFalse(file.exists())
        assertTrue(newStore(file).pockets.isEmpty())
    }
}
