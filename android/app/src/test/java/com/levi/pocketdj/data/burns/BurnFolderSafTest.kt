package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.transfers.FakeTransferWork
import com.levi.pocketdj.data.transfers.TransferCoordinator
import java.io.File
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** In-memory SAF tree (the fake DocumentFile layer). */
class FakeTree(
    var reachable: Boolean = true,
    var writable: Boolean = true,
    var failCopies: Boolean = false,
) : BurnTree {
    val files = LinkedHashMap<String, ByteArray>()
    override fun isReachable() = reachable
    override fun probeWrite() = reachable && writable
    override fun exists(name: String) = name in files
    override fun copyIn(name: String, src: File) {
        if (failCopies || !reachable) throw IOException("tree write failed")
        files[name] = src.readBytes()
    }
}

class FakePrefs(var uri: String? = null) : BurnFolderPrefs {
    override fun treeUri() = uri
    override fun setTreeUri(uri: String?) { this.uri = uri }
}

class BurnFolderSafTest {
    private val base = tmpDir()
    private val app = File(base, "burns")
    private val stage = File(base, "burns-user")
    private val tree = FakeTree()
    private val prefs = FakePrefs()
    private val folder = SafBurnFolder(app, stage, prefs) { if (it == "content://tree/sd") tree else null }

    @Test fun noFolderChosenUsesAppStorage() {
        val r = folder.activeWritable()!!
        assertFalse(r.isUserFolder)
        assertEquals(app, r.dir)
        assertEquals(1, folder.roots().size)
    }

    @Test fun reachableFolderBecomesActiveWithCapturedUri() {
        prefs.uri = "content://tree/sd"
        val r = folder.activeWritable()!!
        assertTrue(r.isUserFolder)
        assertEquals(stage, r.dir)
        assertEquals(BurnDestination(wasAppStorage = false, treeUri = "content://tree/sd"), SafBurnFolder.destinationOf(r))
        assertEquals(listOf(false, true), folder.roots().map { it.isUserFolder })
        assertTrue(folder.probeWrite(r))
    }

    @Test fun failedProbeFallsBackToAppStorage() {
        prefs.uri = "content://tree/sd"
        tree.writable = false
        val r = folder.activeWritable()!!
        assertFalse(r.isUserFolder)
        assertEquals(BurnDestination(true, null), SafBurnFolder.destinationOf(r))
    }

    @Test fun unknownOrRevokedTreeFallsBack() {
        prefs.uri = "content://tree/other"
        assertFalse(folder.activeWritable()!!.isUserFolder)
        prefs.uri = "content://tree/sd"
        tree.reachable = false
        assertFalse(folder.activeWritable()!!.isUserFolder)
    }

    @Test fun eachItemResolvesAgainstTheRootItWasWrittenTo() {
        prefs.uri = "content://tree/sd"
        folder.activeWritable() // creates the staging root
        assertEquals(app, folder.dirFor(true))
        assertEquals(app, folder.dirFor(null))
        assertEquals(stage, folder.dirFor(false))
        // switching the choice to none never re-points an already-written user item at app storage
        prefs.uri = null
        assertEquals(app, folder.dirFor(true))
        // the staged audio is local: still resolvable (not stranded) once it exists
        assertEquals(stage, folder.dirFor(false))
    }

    @Test fun noStagedDirMeansUserItemsUnresolvable() {
        prefs.uri = "content://tree/sd"
        assertNull(folder.dirFor(false))
        assertEquals(app, folder.dirFor(true))
    }

    @Test fun revokedOrClearedFolderKeepsStagedFilesResolvable() {
        prefs.uri = "content://tree/sd"
        folder.activeWritable() // creates stage
        File(stage, "x.mp3").writeBytes(ByteArray(3))
        tree.reachable = false
        assertEquals(stage, folder.dirFor(false))
        assertEquals(listOf(false, true), folder.roots().map { it.isUserFolder })
        prefs.uri = null
        assertEquals(stage, folder.dirFor(false))
        assertTrue(folder.roots().any { it.dir == stage })
    }

    @Test fun readPathNeverQueriesTreeReachability() {
        var calls = 0
        val counting = object : BurnTree by tree {
            override fun isReachable(): Boolean { calls++; return true }
        }
        prefs.uri = "content://tree/sd"
        val f = SafBurnFolder(app, stage, prefs) { counting }
        stage.mkdirs()
        repeat(20) { f.roots(); f.dirFor(false); f.dirFor(true) }
        assertEquals(0, calls)
    }

    @Test fun fellBackIsReportedWhenChosenFolderIsUnusable() {
        assertFalse(folder.let { it.activeWritable(); it.fellBack() })
        prefs.uri = "content://tree/sd"
        tree.reachable = false
        folder.activeWritable()
        assertTrue(folder.fellBack())
        tree.reachable = true
        folder.activeWritable()
        assertFalse(folder.fellBack())
    }

    @Test fun mirrorFilesCopiesStagedFilesAndSwallowsFailure() {
        prefs.uri = "content://tree/sd"
        stage.mkdirs()
        File(stage, "a.mp3").writeBytes(ByteArray(4))
        File(stage, "a.txt").writeText("t")
        folder.mirrorFiles(stage, listOf("a.mp3", "a.txt", "", "missing.mp3"))
        assertEquals(setOf("a.mp3", "a.txt"), tree.files.keys)
        tree.failCopies = true
        folder.mirrorFiles(stage, listOf("a.mp3")) // no throw
        folder.mirrorFiles(app, listOf("a.mp3")) // not the stage: no-op
    }

    @Test fun auxFilesBurnedBeforePickingFolderStayVisible() {
        val r = Rig()
        val f = SafBurnFolder(r.burns, File(r.dir, "burns-user"), prefs) { tree }
        r.burns.mkdirs()
        for (n in BurnFileNames.STEM_NAMES) File(r.burns, BurnFileNames.stemFileName("song1", n)).writeBytes(ByteArray(2))
        File(r.burns, BurnFileNames.beatgridFileName("song1")).writeText("{}")
        val store = BurnStore(r.ledger, f, r.rips, lookup = { null to null }, clock = { r.nowMs })
        prefs.uri = "content://tree/sd"
        f.activeWritable() // creates the user staging root, which becomes the last root
        assertTrue(store.stemsBurned("song1"))
        assertEquals(listOf("song1"), store.localStemSongIds())
        assertTrue(store.beatgridBurned("song1"))
        assertEquals(4, store.localStemPartFiles("song1")!!.size)
    }

    @Test fun userFilesStayPlayableAndDeletableAfterClearingFolder() = runTest {
        val r = Rig()
        val f = SafBurnFolder(r.burns, File(r.dir, "burns-user"), prefs) { tree }
        prefs.uri = "content://tree/sd"
        f.activeWritable()
        val staged = File(r.dir, "burns-user").also { it.mkdirs() }
        File(staged, "u.mp3").writeBytes(ByteArray(5000) { 1 })
        r.ledger.writeText(
            com.levi.pocketdj.data.PdjJson.lenient.encodeToString(
                BurnDocument.serializer(), BurnDocument(items = listOf(item("u", "u.mp3", false))),
            ),
        )
        val store = BurnStore(r.ledger, f, r.rips, lookup = { null to null }, clock = { r.nowMs })
        prefs.uri = null // "Use app storage"
        store.invalidateLocalCache()
        assertNotNull(store.localUrl("u"))
        assertTrue(store.burnedUsageBytes() >= 5000)
        store.removeAllBurns()
        assertFalse(File(staged, "u.mp3").exists())
    }

    private fun item(id: String, file: String, app: Boolean?) = BurnItem(
        songId = id, title = id, artist = "A", audioFileName = file, sidecarFileName = "", source = "digital",
        bytes = 1, state = BurnState.READY, wasAppStorage = app,
    )

    @Test fun reconcileSkipsNeverPrunesItemsWhoseFolderIsUnresolvable() {
        prefs.uri = "content://tree/sd"
        tree.reachable = false
        app.mkdirs()
        File(app, "here.mp3").writeBytes(ByteArray(5000) { 1 })
        val items = listOf(item("u", "sd-song.mp3", false), item("a", "gone.mp3", true), item("ok", "here.mp3", true))
        val out = BurnReconciler.reconcile(items, { folder.dirFor(it.wasAppStorage) })
        assertEquals(setOf("a"), out.dropped) // "u" skipped (folder unresolvable), not dropped
    }

    @Test fun reconcileOnLaunchViaStoreKeepsUnreachableUserItem() = runTest {
        val r = Rig()
        prefs.uri = "content://tree/sd"
        val f = SafBurnFolder(r.burns, File(r.dir, "burns-user"), prefs) { tree }
        r.ledger.writeText(
            com.levi.pocketdj.data.PdjJson.lenient.encodeToString(
                BurnDocument.serializer(), BurnDocument(items = listOf(item("u", "sd-song.mp3", false))),
            ),
        )
        val store = BurnStore(r.ledger, f, r.rips, lookup = { null to null }, clock = { r.nowMs })
        assertNotNull(store.items.value["u"])
        tree.reachable = false
        store.reconcileOnLaunch()
        assertNotNull(store.items.value["u"])
    }

    @Test fun burnQueuesIntoUserFolderAndCapturesTreeOnRecord() = runTest {
        val r = Rig()
        r.rips.entries["s1"] = digital("s1")
        prefs.uri = "content://tree/sd"
        val f = SafBurnFolder(r.burns, File(r.dir, "burns-user"), prefs) { tree }
        val c = TransferCoordinator(File(r.dir, "t.json"), FakeTransferWork())
        val store = BurnStore(r.ledger, f, r.rips, lookup = { null to null }, clock = { r.nowMs }, transfers = c)
        store.burn(listOf(bs("s1")))
        val rec = c.record("s1")!!
        assertFalse(rec.wasAppStorage)
        assertEquals("content://tree/sd", rec.burnFolderTreeUri)
        assertEquals(false, store.items.value.getValue("s1").wasAppStorage)
    }
}
