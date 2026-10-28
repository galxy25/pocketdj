package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.backup.BackupZip
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ImportMergeIdempotenceTest {
    @get:Rule val tmp = TemporaryFolder()
    private var clock = 1_750_000_000_000.0
    private fun store() = CollectionsStore(file = File(tmp.newFolder(), CollectionsStore.FILE_NAME), now = { clock })

    private fun snapshot(s: CollectionsStore) = listOf(s.pockets, s.playlists, s.setlists, s.folders)

    private fun leaf(id: String, kind: PlaylistNode.Kind, ref: String) = when (kind) {
        PlaylistNode.Kind.SONG -> PlaylistNode(nodeId = id, kind = kind, songId = ref)
        PlaylistNode.Kind.POCKET -> PlaylistNode(nodeId = id, kind = kind, pocketId = ref)
        else -> error("n/a")
    }

    private fun playlistWith(vararg songs: String) = Playlist(
        id = "pls_x", name = "X", createdAt = 1.0, updatedAt = 1.0,
        sequences = listOf(PlaylistNode(nodeId = "nd_seq", kind = PlaylistNode.Kind.SEQUENCE, name = "Default",
            children = songs.mapIndexed { i, s -> leaf("nd_$i$s", PlaylistNode.Kind.SONG, s) })),
    )

    @Test
    fun reimportNoop_everyFileKind() {
        val files = listOf(
            "fixtures/pwa-playlist.pocketdj.zip",
            "fixtures/ios-sample-playlist.playlist.pocketdj.zip",
            "backup/ios-pocket.pdjcollection",
            "backup/ios-backup.pocketdj.zip",
        ).map { IoTestSupport.resource(it) }
        val s = store()
        files.forEach { s.importAny(it) }
        val once = snapshot(s)
        val oncePockets = s.pockets; val oncePlaylists = s.playlists
        val rev = s.state.value.revision
        clock += 5_000
        files.forEach { s.importAny(it) }
        s.pockets.forEachIndexed { i, p -> assertEquals("pocket ${p.id}", oncePockets[i], p) }
        s.playlists.forEachIndexed { i, p -> assertEquals("playlist ${p.id}", oncePlaylists[i], p) }
        assertEquals(once, snapshot(s))                      // identical, incl. updatedAt (no re-stamp)
        assertEquals(rev, s.state.value.revision)            // not even a publish
        // no duplicate collection or song anywhere
        assertEquals(s.pockets.size, s.pockets.map { it.id }.toSet().size)
        assertEquals(s.playlists.size, s.playlists.map { it.id }.toSet().size)
        s.pockets.forEach { assertEquals(it.songIds.size, it.songIds.toSet().size) }
        assertTrue(s.pocket("pkt_pwa_root") != null && s.playlist("pls_ios_1") != null && s.pocket("pkt_ios_root") != null)
    }

    @Test
    fun reimportAfterRoundTripThroughDisk_noop() {
        val file = File(tmp.newFolder(), CollectionsStore.FILE_NAME)
        val s = CollectionsStore(file = file, now = { clock })
        val bytes = IoTestSupport.resource("backup/ios-backup.pocketdj.zip")
        s.importAny(bytes); s.flushNow(); s.awaitWrites()
        val relaunched = CollectionsStore(file = file, now = { clock })
        val before = snapshot(relaunched)
        relaunched.importAny(bytes)
        assertEquals(before, snapshot(relaunched))
    }

    @Test
    fun modifiedReimportUnionsOnly() {
        val s = store()
        val a = Pocket(id = "pkt_a", name = "A", songIds = listOf("s1", "s2"), albumIds = listOf("al1"), createdAt = 1.0, updatedAt = 1.0)
        s.importCollection(CollectionFile.pocketEnvelope(a))
        s.importCollection(CollectionFile.playlistEnvelope(playlistWith("s1", "s2")))
        clock += 1_000
        // The sharer added s3 / al2 and removed s2; the local copy keeps s2 (union never deletes).
        val a2 = a.copy(songIds = listOf("s1", "s3"), albumIds = listOf("al1", "al2"), songRepeats = mapOf("s3" to 2))
        s.importCollection(CollectionFile.pocketEnvelope(a2))
        s.importCollection(CollectionFile.playlistEnvelope(playlistWith("s2", "s1", "s9")))
        assertEquals(1, s.pockets.size)
        assertEquals(listOf("s1", "s2", "s3"), s.pocket("pkt_a")!!.songIds)
        assertEquals(listOf("al1", "al2"), s.pocket("pkt_a")!!.albumIds)
        assertEquals(mapOf("s3" to 2), s.pocket("pkt_a")!!.songRepeats)
        assertEquals(clock, s.pocket("pkt_a")!!.updatedAt, 0.0)
        assertEquals(1, s.playlists.size)
        val songs = s.playlist("pls_x")!!.sequences.single().children!!.map { it.songId }
        assertEquals(listOf("s1", "s2", "s9"), songs)         // order of the local chapter kept, s9 appended once
    }

    @Test
    fun newChapterAppendsExistingChapterMatchesByNodeId() {
        val s = store()
        s.importCollection(CollectionFile.playlistEnvelope(playlistWith("s1")))
        val withExtra = playlistWith("s1").let {
            it.copy(sequences = it.sequences + PlaylistNode(nodeId = "nd_seq2", kind = PlaylistNode.Kind.SEQUENCE, name = "Encore",
                children = listOf(leaf("nd_e", PlaylistNode.Kind.SONG, "s5"))))
        }
        s.importCollection(CollectionFile.playlistEnvelope(withExtra))
        s.importCollection(CollectionFile.playlistEnvelope(withExtra))
        assertEquals(listOf("Default", "Encore"), s.playlist("pls_x")!!.sequences.map { it.name })
    }

    @Test
    fun danglingRefsDropped() {
        val s = store()
        val p = Pocket(id = "pkt_p", name = "P", folderId = "fld_nowhere", childPocketIds = listOf("pkt_missing", "pkt_kid"), createdAt = 1.0)
        val kid = Pocket(id = "pkt_kid", name = "Kid", createdAt = 1.0)
        val pl = playlistWith("s1").copy(folderId = "fld_nowhere")
        val folder = PlaylistFolder(id = "fld_ok", name = "Ok", createdAt = 1.0, updatedAt = 1.0)
        val sum = s.mergeImported(pockets = listOf(p, kid), playlists = listOf(pl, playlistWith("s1").copy(id = "pls_y", folderId = "fld_ok")), folders = listOf(folder))
        assertEquals(2, sum.pockets)
        assertNull(s.pocket("pkt_p")!!.folderId)
        assertEquals(listOf("pkt_kid"), s.pocket("pkt_p")!!.childPocketIds)
        assertNull(s.playlist("pls_x")!!.folderId)
        assertEquals("fld_ok", s.playlist("pls_y")!!.folderId)       // resolvable refs survive
    }

    @Test
    fun refToLocallyExistingFolderAndPocketSurvives() {
        val s = store()
        val f = s.createFolder("Local")
        val kid = s.createPocket("Local kid")
        val inc = Pocket(id = "pkt_in", name = "In", folderId = f.id, childPocketIds = listOf(kid.id), createdAt = 1.0)
        s.mergeImported(pockets = listOf(inc))
        assertEquals(f.id, s.pocket("pkt_in")!!.folderId)
        assertEquals(listOf(kid.id), s.pocket("pkt_in")!!.childPocketIds)
    }

    @Test
    fun amPlaylistIdStripped() {
        val s = store()
        s.mergeImported(
            pockets = listOf(Pocket(id = "pkt_am", name = "AM", amPlaylistId = "p.THEIRS", createdAt = 1.0)),
            playlists = listOf(playlistWith("s1").copy(amPlaylistId = "p.THEIRS2")),
        )
        assertNull(s.pocket("pkt_am")!!.amPlaylistId)
        assertNull(s.playlist("pls_x")!!.amPlaylistId)
        // and an EXISTING local link is never replaced or cleared by a merge
        s.linkPocketToAppleMusic("pkt_am", "p.MINE")
        s.mergeImported(pockets = listOf(Pocket(id = "pkt_am", name = "AM", songIds = listOf("new"), amPlaylistId = "p.THEIRS")))
        assertEquals("p.MINE", s.pocket("pkt_am")!!.amPlaylistId)
        assertEquals(listOf("new"), s.pocket("pkt_am")!!.songIds)
        // nothing on the wire ever carries it
        val bytes = String(CollectionFile.pocketEnvelope(s.pocket("pkt_am")!!), Charsets.UTF_8)
        assertFalse(bytes.contains("p.MINE"))
    }

    @Test
    fun cleanOnlyTravels() {
        val s = store()
        s.importAny(IoTestSupport.resource("backup/ios-pocket.pdjcollection"))
        assertEquals(true, s.pocket("pkt_ios_root")!!.cleanOnly)
        s.importAny(IoTestSupport.resource("backup/ios-backup.pocketdj.zip"))
        val warm = s.pocket("pkt_ios_a")!!
        assertEquals(true, warm.cleanOnly)
        assertEquals(false, warm.recsEnabled)
        assertEquals(mapOf("sng_1" to 2), warm.songRepeats)
        assertEquals(1, warm.notes.size)
        // and through our own export
        val back = PocketZip.read(s.exportPocketZip("pkt_ios_root")!!)
        assertEquals(true, back.pocket.cleanOnly)
    }

    @Test
    fun zipImportsClearFolderOnNewPocketsOnly() {
        val s = store()
        s.importAny(IoTestSupport.resource("backup/ios-pocket.pdjcollection"))
        assertNull(s.pocket("pkt_ios_root")!!.folderId)              // "fld_elsewhere" cleared
        // an already-present pocket keeps ITS folder when re-imported
        val f = s.createFolder("Mine")
        s.setPocketFolder("pkt_ios_root", f.id)
        s.importAny(IoTestSupport.resource("backup/ios-pocket.pdjcollection"))
        assertEquals(f.id, s.pocket("pkt_ios_root")!!.folderId)
    }

    @Test
    fun backupKeepsFoldersAndDropsOrphanSetlistsAndGhostRefs() {
        val s = store()
        s.importAny(IoTestSupport.resource("backup/ios-backup.pocketdj.zip"))
        assertEquals("fld_ios1", s.pocket("pkt_ios_a")!!.folderId)
        assertNull(s.pocket("pkt_ios_b")!!.folderId)                  // fld_missing dropped
        assertEquals(listOf("pkt_ios_b"), s.pocket("pkt_ios_a")!!.childPocketIds)   // pkt_ghost dropped
        assertEquals(listOf("set_ios_1"), s.setlists.map { it.id })   // orphan setlist dropped
        assertEquals(1, s.folders.size)
    }

    @Test
    fun importAnyRoutesByContentNotExtension() {
        val s = store()
        val playlistZip = IoTestSupport.resource("fixtures/pwa-playlist.pocketdj.zip")
        assertEquals(ImportKind.PLAYLIST, CollectionFile.detectKind(playlistZip))
        assertEquals(ImportKind.POCKET, CollectionFile.detectKind(IoTestSupport.resource("backup/ios-pocket.pdjcollection")))
        assertEquals(ImportKind.BACKUP, CollectionFile.detectKind(IoTestSupport.resource("backup/ios-backup.pocketdj.zip")))
        val json = CollectionFile.pocketEnvelope(Pocket(id = "pkt_j", name = "J", createdAt = 1.0))
        assertEquals(ImportKind.COLLECTIONS_JSON, CollectionFile.detectKind(json))
        assertEquals(ImportKind.PLAYLIST, s.importAny(playlistZip).kind)
        assertEquals(ImportKind.COLLECTIONS_JSON, s.importAny(json).kind)
        assertEquals("J", s.pocket("pkt_j")!!.name)
        // a PWA backup (no `kind`) and a bare zip with only collections entries route to backup
        val pwaBackup = ZipIo.write(mapOf("manifest.json" to """{"app":"pocketdj","schemaVersion":2,"exportedAt":"x","counts":{}}""".toByteArray(),
            "pockets.json" to "[]".toByteArray()))
        assertEquals(ImportKind.BACKUP, CollectionFile.detectKind(pwaBackup))
        // a corrupt zip falls to the JSON path (and fails loudly there)
        assertEquals(ImportKind.COLLECTIONS_JSON, CollectionFile.detectKind(byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1, 2, 3)))
    }

    @Test
    fun portableItemsSeamSkipsCatalogIdsAndFiresOnce() {
        val s = store()
        s.catalogProvider = { IoTestSupport.catalog(listOf(IndexSong(id = "sng_aaa111", artist = "Artist A", name = "Song A"))) }
        val got = ArrayList<PortableItems.Payload>()
        s.onPortableItems = { got += it }
        s.importAny(IoTestSupport.resource("fixtures/pwa-playlist.pocketdj.zip"))
        assertEquals(1, got.size)
        assertEquals(listOf("sng_bbb001"), got[0].songs.map { it.id })    // sng_aaa111 already in the live catalog
        assertEquals(listOf("alb_bbb222"), got[0].albums.map { it.id })
    }

    @Test
    fun exportThenImportIntoFreshStoreReproducesCollections() {
        val src = store()
        val kid = src.createPocket("Kid"); src.addSongToPocket("s2", kid.id)
        val root = src.createPocket("Root"); src.addSongToPocket("s1", root.id); src.addChildPocket(kid.id, root.id)
        val pl = src.createPlaylist("PL"); src.addSongToPlaylist("s1", pl.id); src.addPocketRef(root.id, pl.id)
        val dst = store()
        dst.importAny(src.exportPlaylistZip(pl.id)!!)
        assertEquals(src.playlist(pl.id)!!.sequences, dst.playlist(pl.id)!!.sequences)
        assertEquals(setOf(root.id, kid.id), dst.pockets.map { it.id }.toSet())
        assertEquals(listOf(kid.id), dst.pocket(root.id)!!.childPocketIds)
        val dst2 = store()
        dst2.importAny(src.exportPocketZip(root.id)!!)
        dst2.importAny(src.exportPocketZip(root.id)!!)
        assertEquals(2, dst2.pockets.size)
        assertEquals(null, src.exportPocketZip("nope")); assertEquals(null, src.exportPlaylist("nope"))
    }

    @Test
    fun csvExportsFromStore() {
        val s = store()
        s.catalogProvider = { IoTestSupport.catalog(listOf(IndexSong(id = "s1", artist = "A", name = "One"), IndexSong(id = "s2", artist = "B", name = "Two"))) }
        val p = s.createPocket("P"); s.addSongToPocket("s1", p.id); s.addSongToPocket("s2", p.id); s.addSongToPocket("ghost", p.id)
        val lines = String(s.exportPocketCsv(p.id)!!, Charsets.UTF_8).trimEnd().split("\r\n")
        assertEquals(3, lines.size)                       // header + 2 resolved rows (ghost dropped)
        assertTrue(lines[1].startsWith("1,One,A,"))
        assertNull(s.exportPocketCsv("nope"))
        val pl = s.createPlaylist("PL"); s.addSongToPlaylist("s2", pl.id)
        assertTrue(String(s.exportPlaylistCsv(pl.id)!!, Charsets.UTF_8).contains("1,Two,B,"))
    }

    @Test
    fun summaryDistinguishesAddedMergedUnchanged_andAsCopyAdds() {
        val zip = IoTestSupport.resource("fixtures/pwa-playlist.pocketdj.zip")
        val s = store()
        val first = s.importPlaylistZip(zip)
        assertTrue(first.added > 0); assertEquals(0, first.merged); assertFalse(first.alreadyUpToDate)
        clock += 1_000
        val again = s.importPlaylistZip(zip)
        assertEquals(0, again.added); assertEquals(0, again.merged)
        assertTrue(again.unchanged > 0); assertTrue(again.alreadyUpToDate)
        assertEquals(first.added + first.merged + first.unchanged, first.playlists + first.pockets + first.setlists + first.folders)
        val n = s.playlists.size
        val copy = s.importPlaylistZipAsCopy(zip)
        assertEquals(n + 1, s.playlists.size)
        assertTrue(copy.added > 0)
    }
}
