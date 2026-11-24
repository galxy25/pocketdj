package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.AssetOrigin
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.EvictionPlan
import com.levi.pocketdj.data.burns.FakePrefs
import com.levi.pocketdj.data.burns.FakeTree
import com.levi.pocketdj.data.burns.Rig
import com.levi.pocketdj.data.burns.SafBurnFolder
import com.levi.pocketdj.data.burns.TemporaryHold
import com.levi.pocketdj.data.burns.album
import com.levi.pocketdj.data.burns.digital
import com.levi.pocketdj.data.burns.song
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TemporarySweepTest {
    private val hour = 3_600_000.0
    private val now = 1_000_000_000L

    private fun hold(id: String, expires: Double, bytes: Long = 100, stems: Map<String, Long> = emptyMap()) = TemporaryHold(
        songId = id, audio = bytes > 0, stemParts = stems.keys.toList(), createdAtMs = 0.0, expiresAtMs = expires,
        audioBytes = bytes.takeIf { it > 0 }, stemBytes = stems.takeIf { it.isNotEmpty() },
    )

    // ---- pure plan ----------------------------------------------------------------------------

    @Test fun planDeletesExpiredUnprotectedSoonestFirstAndSpansVariantBases() {
        val base = "sng_0123456789ab"
        val holds = listOf(
            hold("late", now - 10.0), hold("early", now - 500.0),
            hold("future", now + hour), hold("playing", now - 1.0), hold(base + "_clean", now - 2.0),
        )
        val plan = TemporarySweep.planSweep(holds, now.toDouble(), Long.MAX_VALUE, setOf("playing", base))
        assertEquals(listOf("early", "late"), plan.delete)
        // "playing" and the base-protected variant are expired but spared (re-checked next sweep)
        assertEquals(2, plan.skippedProtected)
    }

    @Test fun planOverCapAddsUnexpiredSoonestFirstAfterExpiredAndSkipsProtected() {
        val holds = listOf(
            hold("exp", now - 1.0, 100), hold("f1", now + 1 * hour, 100), hold("f2", now + 2 * hour, 100),
            hold("f3", now + 3 * hour, 100), hold("prot", now + 0.5 * hour, 100),
        )
        // footprint 500 - exp 100 = 400 > cap 250 -> evict prot? no (protected) -> f1 (300) -> f2 (200 <= 250) stop
        val plan = TemporarySweep.planSweep(holds, now.toDouble(), 250, setOf("prot"))
        assertEquals(listOf("exp", "f1", "f2"), plan.delete)
        assertEquals(0, plan.skippedProtected)
    }

    @Test fun planIgnoreExpiryClearsEveryUnprotectedHold() {
        val holds = listOf(hold("a", now + hour), hold("b", now + 2 * hour), hold("c", now + 3 * hour))
        assertEquals(listOf("a", "c"), TemporarySweep.planSweep(holds, now.toDouble(), Long.MAX_VALUE, setOf("b"), ignoreExpiry = true).delete.filter { it != "b" })
        assertEquals(3, TemporarySweep.planSweep(holds, now.toDouble(), Long.MAX_VALUE, emptySet(), ignoreExpiry = true).delete.size)
    }

    @Test fun softCapOrderIsUnprotectedAudioHoldsBySoonestExpiryOnly() {
        val holds = listOf(
            hold("b", 20.0), hold("a", 10.0), hold("prot", 5.0), hold("notReady", 1.0),
            hold("stemsOnly", 2.0, bytes = 0, stems = mapOf("vocals" to 5L)),
        )
        val order = TemporarySweep.softCapTemporaryFirst(holds, readyIds = setOf("a", "b", "prot", "stemsOnly"), protected = setOf("prot"))
        assertEquals(listOf("a", "b"), order)
    }

    @Test fun identityRules() {
        val h = hold("a", 0.0).copy(userFolderFiles = mapOf("a.mp3" to 10_000.0))
        assertTrue(TemporarySweep.fileIsOurs(h, "a.mp3", 11_900.0))
        assertFalse("changed beyond +-2s", TemporarySweep.fileIsOurs(h, "a.mp3", 13_000.0))
        assertFalse("never recorded: not provably ours", TemporarySweep.fileIsOurs(h, "other.mp3", 10_000.0))
        assertTrue("unreadable mtime defers to path rules", TemporarySweep.fileIsOurs(h, "a.mp3", null))
        assertTrue("pre-identity hold", TemporarySweep.fileIsOurs(hold("a", 0.0), "x", 5.0))
    }

    @Test fun afterRemovalNarrowsAndForgetsEmptyHolds() {
        val h = hold("a", 0.0, 50, mapOf("vocals" to 10L, "drums" to 20L)).copy(stemPartsInUserFolder = listOf("drums"), userFolderFiles = mapOf("x" to 1.0))
        val partial = TemporarySweep.afterRemoval(h, audioDone = true, keptParts = listOf("drums"))!!
        assertFalse(partial.audio); assertNull(partial.audioBytes)
        assertEquals(listOf("drums"), partial.stemParts); assertEquals(mapOf("drums" to 20L), partial.stemBytes)
        assertEquals(listOf("drums"), partial.stemPartsInUserFolder)
        assertNull(TemporarySweep.afterRemoval(h, audioDone = true, keptParts = emptyList()))
        assertNotNull(TemporarySweep.afterRemoval(h, audioDone = false, keptParts = emptyList()))
    }

    // ---- StorageManager.sweepTemporary --------------------------------------------------------

    private class Settings(var cap: Long = Long.MAX_VALUE, var last: Long? = null, val events: MutableList<String> = mutableListOf()) : StorageSettingsPort {
        override suspend fun capGB(): Double? = null
        override suspend fun capSongs(): Int? = null
        override suspend fun lastPruneAt(): Long? = null
        override suspend fun stampPrune(nowMs: Long) {}
        override suspend fun lastTemporarySweepAt() = last
        override suspend fun stampTemporarySweep(nowMs: Long) { last = nowMs; events += "stamp" }
        override suspend fun bufferCapBytes() = cap
    }

    private class Burns(holds: List<TemporaryHold>, val settings: Settings) : PruneBurns {
        val held = LinkedHashMap<String, TemporaryHold>().also { m -> holds.forEach { m[it.songId] = it } }
        val removedChunks = mutableListOf<List<String>>()
        var onRemove: (List<String>) -> Unit = {}
        override fun items(): Collection<BurnItem> = held.keys.map {
            BurnItem(songId = it, title = it, artist = "A", audioFileName = "$it.mp3", sidecarFileName = "$it.txt", source = "digital", bytes = 1, downloadedAt = 0.0, state = BurnState.READY)
        }
        override fun plan(order: List<String>, capBytes: Long, capSongs: Int) = EvictionPlan(0, 0, emptyList())
        override fun removeBurns(songIds: List<String>) {}
        override fun temporaryHolds(): Map<String, TemporaryHold> = LinkedHashMap(held)
        override fun removeTemporaryAssets(songIds: List<String>): TemporaryRemoval {
            settings.events += "remove"
            removedChunks += songIds
            var b = 0L
            songIds.forEach { held.remove(it)?.let { h -> b += h.bytes } }
            onRemove(songIds)
            return TemporaryRemoval(songs = songIds.size, bytes = b)
        }
    }

    private fun stats() = PlayStatsStore(File(Files.createTempDirectory("pdj-sw").toFile(), "s.json"), nowMs = 0)

    private fun mgr(b: Burns, s: Settings, protect: () -> Set<String> = { emptySet() }, log: (String) -> Unit = {}) =
        StorageManager(b, stats(), s, protectedSongIds = protect, clock = { now }, log = log, io = Dispatchers.Unconfined)

    @Test fun stampIsWrittenBeforeAnyDeletion() = runTest {
        val s = Settings()
        val b = Burns(listOf(hold("a", now - 1.0)), s)
        val r = mgr(b, s).sweepTemporary(reason = "test")!!
        assertEquals(listOf("stamp", "remove"), s.events)
        assertEquals(now, s.last)
        assertEquals(1, r.removed); assertEquals(100L, r.freedBytes); assertEquals(0, r.remaining)
    }

    @Test fun noHoldsMeansNoStampAndNothingHappens() = runTest {
        val s = Settings()
        val r = mgr(Burns(emptyList(), s), s).sweepTemporary(reason = "test")!!
        assertEquals(SweepResult(), r); assertTrue(s.events.isEmpty()); assertNull(s.last)
    }

    @Test fun deletesInChunksOf25AndRereadsTheProtectedSetPerChunk() = runTest {
        val s = Settings()
        val ids = (1..60).map { "s%02d".format(it) }
        val b = Burns(ids.mapIndexed { i, id -> hold(id, now - 1000.0 + i) }, s)
        var reads = 0
        // After the first chunk, s30 (in chunk 2) becomes the playing song.
        val protect = { reads++; if (b.removedChunks.isNotEmpty()) setOf("s30") else emptySet() }
        val r = mgr(b, s, protect).sweepTemporary(reason = "test")!!
        assertEquals(listOf(25, 25, 9), b.removedChunks.map { it.size })
        assertFalse("s30 spared mid-sweep", "s30" in b.removedChunks.flatten())
        assertEquals(59, r.removed); assertEquals(1, r.skippedProtected); assertEquals(1, r.remaining)
        assertTrue("protected set re-read per chunk (plan + 3 chunks)", reads >= 4)
    }

    @Test fun aHoldPinnedMidSweepIsNotDeleted() = runTest {
        val s = Settings()
        val ids = (1..30).map { "p%02d".format(it) }
        val b = Burns(ids.mapIndexed { i, id -> hold(id, now - 100.0 + i) }, s)
        b.onRemove = { b.held.remove("p28") } // explicit download pins (drops the hold) after chunk 1
        val r = mgr(b, s).sweepTemporary(reason = "test")!!
        assertFalse("p28" in b.removedChunks.flatten())
        assertEquals(29, r.removed)
    }

    @Test fun anExpiryPickWhoseHoldWasExtendedIsSpared() = runTest {
        val s = Settings()
        val ids = (1..30).map { "e%02d".format(it) }
        val b = Burns(ids.mapIndexed { i, id -> hold(id, now - 100.0 + i) }, s)
        b.onRemove = { b.held["e27"] = hold("e27", now + 48 * hour) } // a fresh landing moved the expiry later
        mgr(b, s).sweepTemporary(reason = "test")
        assertFalse("e27" in b.removedChunks.flatten())
        assertNotNull(b.held["e27"])
    }

    @Test fun capOverrideEvictsUnexpiredSoonestFirstAndSettingsCapApplies() = runTest {
        val s = Settings(cap = Long.MAX_VALUE)
        val b = Burns(listOf(hold("a", now + hour), hold("b", now + 2 * hour), hold("c", now + 3 * hour)), s)
        val m = mgr(b, s)
        assertEquals(0, m.sweepTemporary(reason = "none")!!.removed) // nothing expired, cap huge
        val r = m.sweepTemporary(reason = "diskguard", capOverrideBytes = 150)!!
        assertEquals(listOf("a", "b"), b.removedChunks.flatten())
        assertEquals(1, r.remaining)
        s.cap = 0
        assertEquals(1, m.sweepTemporary(reason = "cap")!!.removed)
    }

    @Test fun expiredButProtectedIsKeptAndRecheckedNextSweep() = runTest {
        val s = Settings()
        val b = Burns(listOf(hold("playing", now - 5.0)), s)
        var protectedNow = setOf("playing")
        val m = mgr(b, s, { protectedNow })
        val first = m.sweepTemporary(reason = "a")!!
        assertEquals(1, first.skippedProtected); assertEquals(1, first.remaining)
        protectedNow = emptySet()
        assertEquals(1, m.sweepTemporary(reason = "b")!!.removed)
    }

    @Test fun singleFlightWithTheSweepAndThePrune() = runTest {
        val s = Settings()
        val b = Burns(listOf(hold("a", now - 1.0)), s)
        val m = mgr(b, s)
        var nested: SweepResult? = SweepResult()
        b.onRemove = { nested = kotlinx.coroutines.runBlocking { m.sweepTemporary(reason = "nested") } }
        assertNotNull(m.sweepTemporary(reason = "outer"))
        assertNull("a sweep during a sweep is refused", nested)
        assertFalse(m.isPruning)
    }

    @Test fun dueGateUsesTheStampAndPassesAfterTheInterval() = runTest {
        val s = Settings(last = now - 10 * 60_000L)
        val b = Burns(listOf(hold("a", now - 1.0)), s)
        val m = mgr(b, s)
        assertNull(m.sweepTemporaryIfDue("tick"))
        assertEquals(0, s.events.size)
        assertNotNull(m.sweepTemporaryIfDue("foreground", minIntervalMs = 5 * 60_000L))
        s.last = now - 2 * 3_600_000L; b.held["z"] = hold("z", now - 1.0)
        assertNotNull(m.sweepTemporaryIfDue("tick"))
        assertNull("no holds -> no-op", mgr(Burns(emptyList(), s), s).sweepTemporaryIfDue("tick"))
    }

    @Test fun logsTheGreppableSweepLine() = runTest {
        val s = Settings(); val lines = mutableListOf<String>()
        mgr(Burns(listOf(hold("a", now - 1.0)), s), s, log = { lines += it }).sweepTemporary(reason = "foreground")
        assertTrue(lines.any { it.startsWith("temporary sweep reason=foreground deleted=1") })
    }

    @Test fun softCapPruneEvictsTemporaryHoldsBeforePinnedBurns() = runTest {
        val s = Settings()
        class P(val items: List<BurnItem>, val holds: Map<String, TemporaryHold>) : PruneBurns {
            var order: List<String> = emptyList(); val temp = mutableListOf<String>(); val perm = mutableListOf<String>()
            override fun items() = items
            override fun plan(order: List<String>, capBytes: Long, capSongs: Int): EvictionPlan {
                this.order = order; return EvictionPlan(300, 100, order.take(2))
            }
            override fun removeBurns(songIds: List<String>) { perm += songIds }
            override fun temporaryHolds() = holds
            override fun removeTemporaryAssets(songIds: List<String>): TemporaryRemoval { temp += songIds; return TemporaryRemoval() }
        }
        fun it(id: String, dl: Double) = BurnItem(songId = id, title = id, artist = "A", audioFileName = "$id.mp3", sidecarFileName = "$id.txt", source = "digital", bytes = 100, downloadedAt = dl, state = BurnState.READY)
        val p = P(listOf(it("old", 1.0), it("buf", 9.0), it("buf2", 8.0)), mapOf("buf" to hold("buf", 50.0), "buf2" to hold("buf2", 40.0)))
        val set = object : StorageSettingsPort by s {
            override suspend fun capSongs() = 1
        }
        val m = StorageManager(p, stats(), set, clock = { now }, io = Dispatchers.Unconfined)
        m.prune()
        assertEquals(listOf("buf2", "buf", "old"), p.order)
        assertEquals(listOf("buf2", "buf"), p.temp)
        assertTrue("temporary songs never go through removeBurns", p.perm.isEmpty())
    }

    // ---- ticker --------------------------------------------------------------------------------

    @Test fun tickerFiresHourlyWhileStartedAndStopsOnBackground() = runTest {
        var n = 0
        val t = SweepTicker(this, TemporarySweep.INTERVAL_MS) { n++ }
        t.start(); t.start() // idempotent
        advanceTimeBy(TemporarySweep.INTERVAL_MS * 2 + 1)
        assertEquals(2, n)
        t.stop()
        assertFalse(t.isRunning)
        advanceTimeBy(TemporarySweep.INTERVAL_MS * 3)
        assertEquals(2, n)
    }

    // ---- BurnStore.removeTemporaryAssets (real files) -----------------------------------------

    private fun Rig.landing(id: String, size: Int = 4_000): File {
        rips.entries[id] = digital(id)
        catalog[id] = song(id, name = "Song $id") to album("alb_$id")
        return File(dir, "$id.tmp").apply { writeBytes(ByteArray(size)) }
    }

    @Test fun removesExactlyTheHeldAssetsAndLeavesPinnedAndHoldlessFilesAlone() {
        val r = Rig(); val store = r.store()
        store.adoptStreamedFile("buf", "T", "A", r.landing("buf"), AssetOrigin.Buffer)
        store.adoptStreamedFile("perm", "T", "A", r.landing("perm"), AssetOrigin.Incidental) // no hold = pinned
        // a stem the USER pinned for the buffered song (no hold part) must survive
        val userStem = File(r.burns, BurnFileNames.stemFileName("buf", "vocals")).apply { writeBytes(ByteArray(7)) }
        val before = r.names()
        val out = store.removeTemporaryAssets(listOf("buf", "perm", "ghost"))
        assertEquals(1, out.songs); assertEquals(4_000L, out.bytes)
        assertNull(store.items.value["buf"]); assertNotNull(store.items.value["perm"])
        assertTrue(store.temporaryHolds.value.isEmpty())
        assertTrue(userStem.exists())
        assertEquals(before.size - 2, r.names().size) // audio + sidecar only
        assertTrue(File(r.burns, store.items.value.getValue("perm").audioFileName).exists())
    }

    @Test fun neverDeletesAPinnedBurnEvenWhenListed() {
        val r = Rig(); val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.landing("a"), AssetOrigin.Buffer)
        store.pin(listOf("a"), "download")
        val files = r.names()
        val out = store.removeTemporaryAssets(listOf("a"))
        assertEquals(TemporaryRemoval(), out)
        assertEquals(files, r.names()); assertNotNull(store.items.value["a"])
    }

    private class Saf {
        val base = Files.createTempDirectory("pdj-saf").toFile()
        val tree = FakeTree()
        val prefs = FakePrefs("content://tree/sd")
        val folder = SafBurnFolder(File(base, "burns"), File(base, "burns-user"), prefs) { if (it.startsWith("content://tree/")) tree else null }
    }

    private fun safStore(saf: Saf, r: Rig) = BurnStore(
        r.ledger, saf.folder, r.rips, lookup = { r.catalog[it] ?: (null to null) }, clock = { r.nowMs },
        bufferTtlHours = { 48.0 }, keepPickedFolderBuffers = { false },
    )

    @Test fun pickedFolderFileUnchangedIsDeletedWithItsMirror() {
        val saf = Saf(); val r = Rig(); val store = safStore(saf, r)
        store.adoptStreamedFile("a", "T", "A", r.landing("a"), AssetOrigin.Buffer)
        val item = store.items.value.getValue("a")
        assertEquals(false, item.wasAppStorage)
        val staged = File(File(saf.base, "burns-user"), item.audioFileName)
        assertTrue(staged.exists())
        val out = store.removeTemporaryAssets(listOf("a"))
        assertEquals(1, out.songs)
        assertFalse(staged.exists())
        assertTrue("tree copy deleted too", item.audioFileName in saf.tree.deleted)
    }

    @Test fun pickedFolderFileChangedSinceBufferingIsReleasedNotDeleted() {
        val saf = Saf(); val r = Rig(); val store = safStore(saf, r)
        store.adoptStreamedFile("a", "T", "A", r.landing("a"), AssetOrigin.Buffer)
        val item = store.items.value.getValue("a")
        val staged = File(File(saf.base, "burns-user"), item.audioFileName)
        // another device rewrote the shared file
        assertTrue(staged.setLastModified(staged.lastModified() + 60_000))
        val out = store.removeTemporaryAssets(listOf("a"))
        assertEquals(1, out.songs) // the hold is gone ...
        assertTrue("... but the file and its row are kept", staged.exists() && store.items.value["a"] != null)
        assertTrue(store.temporaryHolds.value.isEmpty()) // released = pinned
        assertTrue(saf.tree.deleted.isEmpty())
    }

    @Test fun folderSwitchReleasesInsteadOfDeleting() {
        val saf = Saf(); val r = Rig(); val store = safStore(saf, r)
        store.adoptStreamedFile("a", "T", "A", r.landing("a"), AssetOrigin.Buffer)
        saf.prefs.uri = "content://tree/usb"   // the user picked another folder
        val item = store.items.value.getValue("a")
        val staged = File(File(saf.base, "burns-user"), item.audioFileName)
        store.removeTemporaryAssets(listOf("a"))
        assertTrue(staged.exists())
        assertNotNull(store.items.value["a"])
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun pickedFolderBuffersPinnedAtCreationWhenKeepSwitchIsOn() {
        val saf = Saf(); val r = Rig()
        val store = BurnStore(r.ledger, saf.folder, r.rips, lookup = { r.catalog[it] ?: (null to null) }, clock = { r.nowMs },
            bufferTtlHours = { 48.0 }, keepPickedFolderBuffers = { true })
        store.adoptStreamedFile("a", "T", "A", r.landing("a"), AssetOrigin.Buffer)
        assertTrue(store.temporaryHolds.value.isEmpty())
        assertEquals(TemporaryRemoval(), store.removeTemporaryAssets(listOf("a")))
    }

    @Test fun sweepEndToEndThroughTheRealStoreDeletesOnlyExpiredHolds() = runTest {
        val r = Rig(); val store = r.store()
        store.adoptStreamedFile("old", "T", "A", r.landing("old"), AssetOrigin.Buffer)
        r.nowMs += 24 * 3_600_000L
        store.adoptStreamedFile("new", "T", "A", r.landing("new"), AssetOrigin.Buffer)
        store.adoptStreamedFile("perm", "T", "A", r.landing("perm"))
        val s = Settings()
        val m = StorageManager(BurnStorePruneAdapter(store), stats(), s, clock = { r.nowMs + 30 * 3_600_000L }, io = Dispatchers.Unconfined)
        val res = m.sweepTemporary(reason = "foreground")!!
        assertEquals(1, res.removed)
        assertNull(store.items.value["old"]); assertNotNull(store.items.value["new"]); assertNotNull(store.items.value["perm"])
        assertEquals(1, store.temporaryHolds.value.size)
    }
}
