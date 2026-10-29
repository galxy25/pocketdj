package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.rips.RipStems
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
    val deleted = ArrayList<String>()
    override fun delete(name: String): Boolean {
        if (!reachable) throw IOException("tree delete failed")
        deleted += name
        return files.remove(name) != null
    }
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

    // ---- ANS-COL-4: stems + beat grids mirrored; deleting a burn deletes the folder copy -------

    private class Mirror(val prefs: FakePrefs, val tree: FakeTree, val rig: Rig, val folder: SafBurnFolder) {
        val stage = File(rig.dir, "burns-user")
        fun store() = BurnStore(rig.ledger, folder, rig.rips, lookup = { rig.catalog[it] ?: (null to null) }, clock = { rig.nowMs })
        fun stemmed(id: String) {
            rig.rips.entries[id] = digital(id).copy(
                stems = RipStems("stems/$id/vocals.mp3", "stems/$id/drums.mp3", "stems/$id/bass.mp3", "stems/$id/other.mp3"),
                stemVersion = 1, beatgrid = "rips/analysis/$id.json",
            )
            rig.rips.serve("rips/$id.mp3", 6_000)
            BurnFileNames.STEM_NAMES.forEach { rig.rips.serve("stems/$id/$it.mp3", 1_000) }
            rig.rips.bodies["$BASE/rips/analysis/$id.json"] = """{"beatGridBpm":120.0,"beatsMs":[0,500]}""".toByteArray()
            rig.catalog[id] = song(id) to album("a")
        }
        fun auxNames(id: String) = BurnFileNames.STEM_NAMES.map { BurnFileNames.stemFileName(id, it) } + BurnFileNames.beatgridFileName(id)
    }

    private fun mirror(uri: String? = "content://tree/sd"): Mirror {
        val rig = Rig()
        val p = FakePrefs(uri)
        val t = FakeTree()
        return Mirror(p, t, rig, SafBurnFolder(rig.burns, File(rig.dir, "burns-user"), p) { t })
    }

    @Test fun burnMirrorsStemsAndBeatGridWithTreeUriOnItem() = runTest {
        val m = mirror(); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        m.auxNames("s1").forEach { assertTrue("$it mirrored", it in m.tree.files) }
        assertTrue(m.tree.files.keys.any { it.endsWith(".mp3") && !it.startsWith("stem-") })
        assertEquals("content://tree/sd", store.items.value.getValue("s1").treeUri)
        assertEquals(false, store.items.value.getValue("s1").wasAppStorage)
    }

    @Test fun removeBurnsDeletesEveryFolderCopy() = runTest {
        val m = mirror(); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        assertTrue(m.tree.files.size >= 7) // audio + sidecar + 4 stems + grid
        store.removeBurns(listOf("s1"))
        assertTrue("left: ${m.tree.files.keys}", m.tree.files.isEmpty())
        assertTrue(m.stage.list().orEmpty().isEmpty())
    }

    @Test fun removeStemsAndAllBurnsDeleteFolderCopies() = runTest {
        val m = mirror(); m.stemmed("s1"); m.stemmed("s2")
        val store = m.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        store.removeStems(listOf("s1"))
        BurnFileNames.STEM_NAMES.forEach { assertFalse(BurnFileNames.stemFileName("s1", it) in m.tree.files) }
        assertTrue(BurnFileNames.beatgridFileName("s1") in m.tree.files) // grids stay
        assertTrue(BurnFileNames.stemFileName("s2", "bass") in m.tree.files)
        store.removeAllStems()
        assertTrue(m.tree.files.keys.none { it.startsWith("stem-") })
        store.removeAllBurns()
        assertTrue("left: ${m.tree.files.keys}", m.tree.files.isEmpty())
    }

    @Test fun removeAllBurnsSweepsOrphanFolderAux() = runTest {
        val m = mirror()
        val store = m.store()
        m.folder.activeWritable()
        File(m.stage, "analysis-ghost.json").writeText("{}")
        m.folder.mirrorFiles(m.stage, listOf("analysis-ghost.json"))
        m.rig.rips.entries["ghost"] = digital("ghost") // user-folder aux is owned only when known
        store.removeAllBurns()
        assertFalse("analysis-ghost.json" in m.tree.files)
    }

    @Test fun revokedFolderIsUntouchedAndLocalDeleteStillWorks() = runTest {
        val m = mirror(); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        val before = m.tree.files.keys.toSet()
        m.tree.reachable = false
        store.removeBurns(listOf("s1"))
        assertEquals(before, m.tree.files.keys)
        assertTrue(m.tree.deleted.isEmpty())
        assertNull(store.items.value["s1"])
        assertTrue(m.stage.list().orEmpty().isEmpty())
    }

    @Test fun evictionLeavesFolderCopyButFreesLocal() = runTest {
        val m = mirror(); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        val before = m.tree.files.keys.toSet()
        store.removeBurns(listOf("s1"), mirrored = false)
        assertEquals(before, m.tree.files.keys)
        assertTrue(m.tree.deleted.isEmpty())
        assertNull(store.items.value["s1"])
        store.sweepOrphanAuxFiles()
        assertEquals(before, m.tree.files.keys)
    }

    @Test fun appStorageItemNeverTouchesTheTree() = runTest {
        val m = mirror(uri = null); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        assertTrue(m.tree.files.isEmpty())
        assertNull(store.items.value.getValue("s1").treeUri)
        store.removeBurns(listOf("s1"))
        assertTrue(m.tree.deleted.isEmpty())
    }

    @Test fun burnStemsBeatGridAndPartMirrorWhenWrittenAfterTheBurn() = runTest {
        val m = mirror(); m.stemmed("s1")
        val store = m.store()
        store.burn(listOf(bs("s1")))
        m.tree.files.keys.filter { it.startsWith("stem-") || it.startsWith("analysis-") }.forEach { m.tree.files.remove(it) }
        File(m.stage, BurnFileNames.beatgridFileName("s1")).delete()
        File(m.stage, BurnFileNames.stemFileName("s1", "bass")).delete()
        assertNotNull(store.burnBeatGrid("s1"))
        assertTrue(store.burnStemPart("s1", "bass"))
        assertEquals(setOf(BurnFileNames.beatgridFileName("s1"), BurnFileNames.stemFileName("s1", "bass")), m.tree.files.keys.filter { it.startsWith("stem-") || it.startsWith("analysis-") }.toSet())
    }

    @Test fun deleteMirroredIsNoOpWithoutReachableTree() {
        val m = mirror(uri = null)
        m.folder.deleteMirrored(null, listOf("a.mp3")) // no choice: no-op
        m.tree.files["a.mp3"] = ByteArray(1)
        m.tree.reachable = false
        m.folder.deleteMirrored("content://tree/sd", listOf("a.mp3")) // revoked
        assertTrue("a.mp3" in m.tree.files)
        m.tree.reachable = true
        m.folder.deleteMirrored("content://tree/sd", listOf("a.mp3", "", "absent.mp3"))
        assertFalse("a.mp3" in m.tree.files)
    }

    @Test fun mimeIsJsonForAnalysisSidecars() {
        assertEquals("application/json", mimeFor("analysis-x.json"))
        assertEquals("audio/mpeg", mimeFor("stem-x-bass.mp3"))
        assertEquals("text/plain", mimeFor("x.txt"))
    }
}
