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
        assertEquals(app, folder.dirFor(true))
        assertEquals(app, folder.dirFor(null))
        assertEquals(stage, folder.dirFor(false))
        // switching the choice to none never re-points an already-written user item at app storage
        prefs.uri = null
        assertEquals(app, folder.dirFor(true))
        assertNull(folder.dirFor(false))
    }

    @Test fun revokedTreeMakesUserItemsUnresolvable() {
        prefs.uri = "content://tree/sd"
        tree.reachable = false
        assertNull(folder.dirFor(false))
        assertEquals(app, folder.dirFor(true))
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
