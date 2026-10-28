package com.levi.pocketdj.data.burns

import java.io.File
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnStoreTest {
    private fun Rig.digitalSong(id: String, size: Int = 8_192) {
        rips.entries[id] = digital(id)
        rips.serve("rips/$id.mp3", size)
        catalog[id] = song(id, name = "Song $id") to album("alb_$id")
    }

    private fun Rig.analogAlbum(albumId: String, ids: List<String>, size: Int = 20_000) {
        ids.forEachIndexed { i, id ->
            rips.entries[id] = analog(albumId, startMs = i * 60_000L)
            catalog[id] = song(id, albumId = albumId) to album(albumId, name = "Live")
        }
        rips.serve("rips/$albumId.mp3", size)
    }

    @Test fun analogAlbumDownloadsSharedFileOnceAndWritesPerSongSidecars() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2", "s3"))
        val store = r.store()
        val res = store.burn(listOf(bs("s1"), bs("s2"), bs("s3")))
        assertEquals(3, res.burned)
        assertEquals(1, r.rips.downloads.count { it.endsWith("rips/alb_1.mp3") })
        val mp3s = r.names().filter { it.endsWith(".mp3") }
        assertEquals(listOf("Artist-Live-1999-Rock-alb_1.mp3"), mp3s)
        assertEquals(3, r.names().count { it.endsWith(".txt") })
        val it2 = store.items.value.getValue("s2")
        assertEquals(60_000L, it2.startMs)
        assertEquals(BurnState.READY, it2.state)
        assertEquals(20_000L, it2.bytes)
    }

    @Test fun digitalSongGetsDescriptiveNameEndingInSongId() = runTest {
        val r = Rig(); r.digitalSong("sng_a")
        r.store().burn(listOf(bs("sng_a")))
        assertTrue(r.names().contains("Artist-Song sng_a-Album-1999-Rock-8A-A minor-120-sng_a.mp3"))
        assertTrue(r.names().contains("Artist-Song sng_a-Album-1999-Rock-8A-A minor-120-sng_a.txt"))
    }

    @Test fun notInManifestIsErrorItemAndLoopContinues() = runTest {
        val r = Rig(); r.digitalSong("ok")
        val store = r.store()
        val res = store.burn(listOf(bs("ghost"), bs("ok")))
        assertEquals(1, res.notRipped); assertEquals(1, res.burned)
        val ghost = store.items.value.getValue("ghost")
        assertEquals(BurnState.ERROR, ghost.state)
        assertEquals("not ripped — Rip first", ghost.error)
        assertEquals("", ghost.audioFileName)
        assertTrue(r.rips.downloads.none { it.contains("ghost") })
        r.rips.server = false
        store.burn(listOf(bs("ghost2")))
        assertEquals("not ripped (no rip server)", store.items.value.getValue("ghost2").error)
    }

    @Test fun presignFailureIsAnErrorItemNotAHang() = runTest {
        val r = Rig(); r.digitalSong("a"); r.rips.presignFails = true
        val res = r.store().burn(listOf(bs("a")))
        assertEquals(1, res.notRipped)
    }

    @Test fun stopHonouredAtTopOfNextItemAndInFlightItemIsComplete() = runTest {
        val r = Rig(); listOf("a", "b", "c").forEach { r.digitalSong(it) }
        val store = r.store()
        r.rips.onDownload = { store.requestStop() } // STOP pressed while item "a" is downloading
        val res = store.burn(listOf(bs("a"), bs("b"), bs("c")))
        assertTrue(res.stopped)
        assertEquals(1, res.burned)
        val a = store.items.value.getValue("a")
        assertEquals(BurnState.READY, a.state)
        assertTrue(File(r.burns, a.audioFileName).isFile && File(r.burns, a.sidecarFileName).isFile)
        assertNull(store.items.value["b"]); assertNull(store.items.value["c"])
        // a fresh run resets the stop signal
        r.rips.onDownload = {}
        val again = store.burn(listOf(bs("b")))
        assertFalse(again.stopped); assertEquals(1, again.burned)
    }

    @Test fun outOfSpaceAbortsTheRemainder() = runTest {
        val r = Rig(); listOf("a", "b", "c").forEach { r.digitalSong(it) }
        r.rips.failWith = { url -> if (url.endsWith("b.mp3")) IOException("write failed: ENOSPC (No space left on device)") else null }
        val store = r.store()
        val res = store.burn(listOf(bs("a"), bs("b"), bs("c")))
        assertTrue(res.outOfSpace)
        assertEquals(1, res.burned); assertEquals(1, res.failed)
        assertEquals("out of space", store.items.value.getValue("b").error)
        assertNull(store.items.value["c"])
    }

    @Test fun otherDownloadFailureIsPartialSuccess() = runTest {
        val r = Rig(); listOf("a", "b").forEach { r.digitalSong(it) }
        r.rips.failWith = { url -> if (url.endsWith("a.mp3")) IOException("HTTP 403") else null }
        val res = r.store().burn(listOf(bs("a"), bs("b")))
        assertEquals(1, res.failed); assertEquals(1, res.burned); assertFalse(res.outOfSpace)
    }

    @Test fun folderProbeFailureReportsFolderUnavailable() = runTest {
        val r = Rig(); r.digitalSong("a")
        r.burns.parentFile!!.mkdirs(); r.burns.writeText("i am a file, not a dir")
        val res = r.store().burn(listOf(bs("a")))
        assertEquals(1, res.failed) // activeWritable() null => whole run dropped, counted failed
    }

    @Test fun isFreshMatrix() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))
        val item = store.items.value.getValue("a")
        val dir = r.burns
        assertTrue(store.isFresh(item, dir, null))
        assertTrue(store.isFresh(item, dir, item.downloadedAt))            // rippedAt == downloadedAt: fresh
        assertFalse(store.isFresh(item, dir, item.downloadedAt + 1))       // re-ripped since: stale
        assertFalse(store.isFresh(item.copy(bytes = item.bytes + 1), dir, null)) // size mismatch
        File(dir, item.audioFileName).delete()
        assertFalse(store.isFresh(item, dir, null))                        // file gone
    }

    @Test fun freshItemIsSkippedAndCountedBurnedStaleIsReDownloaded() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))
        assertEquals(1, r.rips.downloads.size)
        val again = store.burn(listOf(bs("a")))
        assertEquals(1, again.burned); assertEquals(1, r.rips.downloads.size)
        r.nowMs += 10
        r.rips.entries["a"] = digital("a", rippedAt = r.nowMs.toDouble() + 5)
        store.burn(listOf(bs("a")))
        assertEquals(2, r.rips.downloads.size) // re-ripped => re-burn
    }

    @Test fun removeBurnsKeepsSharedAlbumUntilLastSiblingGone() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2"))
        val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        val audio = store.items.value.getValue("s1").audioFileName
        store.removeBurns(listOf("s1"))
        assertTrue(File(r.burns, audio).exists())
        assertNull(store.items.value["s1"]); assertNotNull(store.items.value["s2"])
        assertEquals(1, r.names().count { it.endsWith(".txt") })
        store.removeBurns(listOf("s2"))
        assertFalse(File(r.burns, audio).exists())
        assertTrue(r.names().isEmpty())
    }

    @Test fun removingBothSiblingsInOneBatchFreesTheSharedFile() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2"))
        val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        store.removeBurns(listOf("s1", "s2"))
        assertTrue(r.names().isEmpty())
    }

    @Test fun removeAllBurnsSweepsOrphanStemsToo() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))
        File(r.burns, BurnFileNames.stemFileName("never_burned", "bass")).writeText("x")
        File(r.burns, "my-own-notes.txt").writeText("keep me")
        store.removeAllBurns()
        assertEquals(listOf("my-own-notes.txt"), r.names())
        assertTrue(store.items.value.isEmpty())
    }

    @Test fun usageByArtistCountsSharedAudioOnceAndSortsCaseInsensitively() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2")); r.digitalSong("d")
        val store = r.store()
        store.burn(listOf(bs("s1", artist = "zed"), bs("s2", artist = "zed"), bs("d", artist = "Abba")))
        val u = store.usageByArtist()
        assertEquals(listOf("Abba", "zed"), u.map { it.artist })
        assertEquals(20_000L, u[1].bytes) // one shared album file, not 2x
        assertEquals(listOf("s1", "s2"), u[1].songIds)
        assertEquals(20_000L + 8_192L, store.approximateBytes(listOf("s1", "s2", "d")))
        assertEquals(setOf("s1", "s2", "d"), store.readyBurnedIds)
        assertEquals(listOf("d"), store.readyBurnedIds(listOf("d", "nope")))
    }

    @Test fun burnedUsageBytesCountsOnlyOwnedFiles() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))
        File(r.burns, "foreign.mp3").writeBytes(ByteArray(1000))
        val item = store.items.value.getValue("a")
        val expected = File(r.burns, item.audioFileName).length() + File(r.burns, item.sidecarFileName).length()
        assertEquals(expected, store.burnedUsageBytes())
    }

    @Test fun planEvictionOnTheStoreMatchesPlannerOnDisk() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2"))
        val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        val plan = store.planEviction(listOf("s1", "s2"), capBytes = 0, capSongs = 0)
        assertEquals(store.burnedUsageBytes(), plan.usageBytes)
        assertEquals(0L, plan.projectedBytes)
        assertEquals(listOf("s1", "s2"), plan.evict)
    }

    @Test fun reconcileOnLaunchDropsMissingAndPoisonedAndPersists() = runTest {
        val r = Rig(); listOf("a", "b", "c").forEach { r.digitalSong(it) }
        val store = r.store()
        store.burn(listOf(bs("a"), bs("b"), bs("c")))
        File(r.burns, store.items.value.getValue("a").audioFileName).delete()
        File(r.burns, store.items.value.getValue("b").audioFileName).writeText("<?xml version=\"1.0\"?><Error>" + "x".repeat(500))
        store.reconcileOnLaunch()
        assertEquals(setOf("c"), store.items.value.keys)
        assertEquals(setOf("c"), r.store().items.value.keys) // ledger rewritten
    }

    @Test fun localUrlPlaybackCutAndStartMs() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1", "s2"))
        r.rips.entries["s2"] = analog("alb_1", 60_000, cutKey = "rips/cuts/s2.mp3")
        r.rips.serve("rips/cuts/s2.mp3", 5_000)
        r.rips.lastModified["$BASE/rips/cuts/s2.mp3"] = 777.0
        val store = r.store()
        store.burn(listOf(bs("s1"), bs("s2")))
        assertNotNull(store.localUrl("s1"))
        assertEquals(60_000L, store.startMs("s2"))
        val cut = store.localUrlPreferringCut("s2")!!
        assertTrue(cut.isCut); assertEquals(5_000L, cut.file.length())
        assertEquals(777.0, store.items.value.getValue("s2").cutDownloadedAt!!, 0.0)
        val whole = store.localUrlPreferringCut("s1")!!
        assertFalse(whole.isCut)
        assertNull(store.localUrl("nope"))
        // cut is not re-downloaded while the remote is not newer
        val before = r.rips.downloads.count { it.contains("cuts") }
        store.burn(listOf(bs("s2")))
        assertEquals(before, r.rips.downloads.count { it.contains("cuts") })
        // ...but is when S3 has a newer one
        r.rips.lastModified["$BASE/rips/cuts/s2.mp3"] = 999.0
        store.burn(listOf(bs("s2")))
        assertEquals(before + 1, r.rips.downloads.count { it.contains("cuts") })
        // removal deletes the cut as well
        store.removeBurns(listOf("s2"))
        assertTrue(r.names().none { it.contains("s2") })
    }

    @Test fun staleStoreRecordSelfHealsCutByDeterministicSuffix() = runTest {
        val r = Rig(); r.analogAlbum("alb_1", listOf("s1"))
        val store = r.store()
        store.burn(listOf(bs("s1")))
        File(r.burns, "Artist-Song s1-1999-s1.mp3").writeBytes(ByteArray(10))
        val cut = store.localUrlPreferringCut("s1")!!
        assertTrue(cut.isCut)
        assertEquals("Artist-Song s1-1999-s1.mp3", store.items.value.getValue("s1").cutFileName)
    }

    @Test fun adoptStreamedFileLandsAReadyBurnAndFansOut() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        var fired: Pair<String, Long>? = null
        store.onAnyBurnFinalized = { id, b -> fired = id to b }
        val tmp = File(r.dir, "stream.tmp").apply { writeBytes(ByteArray(4_321)) }
        val out = store.adoptStreamedFile("a", "T", "Artist", tmp)!!
        assertEquals(4_321L, out.length())
        assertFalse(tmp.exists())
        assertEquals("a" to 4_321L, fired)
        assertEquals(BurnState.READY, store.items.value.getValue("a").state)
        assertNull(store.adoptStreamedFile("a", "T", "Artist", File(r.dir, "again.tmp").apply { writeBytes(ByteArray(5)) })) // already burned
        assertNull(store.adoptStreamedFile("ghost", "T", "A", tmp))
    }

    @Test fun adoptOrphanedBurnsRecoversLedgerFromSidecars() = runTest {
        val r = Rig(); r.digitalSong("a"); r.analogAlbum("alb_1", listOf("s1"))
        val first = r.store()
        first.burn(listOf(bs("a", "Song a", "Artist"), bs("s1", "Song s1", "Artist")))
        r.ledger.delete()
        val fresh = r.store()
        assertTrue(fresh.items.value.isEmpty())
        assertEquals(2, fresh.adoptOrphanedBurns())
        assertEquals(first.items.value.getValue("a").audioFileName, fresh.items.value.getValue("a").audioFileName)
        val s1 = fresh.items.value.getValue("s1")
        assertEquals("analog", s1.source)
        assertTrue(s1.audioFileName.endsWith("-alb_1.mp3"))
        assertEquals(0, fresh.adoptOrphanedBurns()) // idempotent
    }

    // ---- ledger shape ----------------------------------------------------------------------

    /** A ledger as Swift's synthesized Codable writes it (nil optionals omitted). */
    private val iosLedger = """
        {"schemaVersion":1,"items":[
          {"songId":"sng_1","title":"One","artist":"A","audioFileName":"A-One-sng_1.mp3","sidecarFileName":"A-One-sng_1.txt",
           "source":"digital","bpm":120.5,"musicalKey":"A minor","camelot":"8A","durationMs":200000,"bytes":4000000,
           "rippedAt":1760000000000,"downloadedAt":1760000100000.5,"state":"ready","wasAppStorage":true},
          {"songId":"sng_2","title":"Two","artist":"B","audioFileName":"","sidecarFileName":"","source":"digital",
           "bytes":0,"downloadedAt":1760000200000,"state":"error","error":"not ripped — Rip first"},
          {"songId":"sng_3","title":"Three","artist":"B","audioFileName":"B-alb_9.mp3","sidecarFileName":"B-sng_3.txt",
           "source":"analog","startMs":61000,"bytes":9,"downloadedAt":1,"state":"ready","cutFileName":"B-Three-sng_3.mp3","cutDownloadedAt":1760000300000}
        ],"pendingAfterRip":[{"songId":"sng_9","title":"Nine","artist":"C","requestedAtMs":1760000400000}]}
    """.trimIndent()

    @Test fun decodesAnIosLedgerFixtureIncludingPending() {
        val r = Rig(); r.ledger.writeText(iosLedger)
        val store = r.store()
        assertEquals(setOf("sng_1", "sng_2", "sng_3"), store.items.value.keys)
        val i1 = store.items.value.getValue("sng_1")
        assertEquals(120.5, i1.bpm!!, 0.0); assertEquals(true, i1.wasAppStorage); assertEquals(4_000_000L, i1.bytes)
        assertEquals(BurnState.ERROR, store.items.value.getValue("sng_2").state)
        assertNull(store.items.value.getValue("sng_2").wasAppStorage)
        assertEquals(61_000L, store.items.value.getValue("sng_3").startMs)
        assertEquals("B-Three-sng_3.mp3", store.items.value.getValue("sng_3").cutFileName)
        assertEquals(setOf("sng_9"), store.pendingAfterRip.value.keys)
    }

    @Test fun androidLedgerUsesTheIosFieldSet() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))
        val root = com.levi.pocketdj.data.PdjJson.lenient.parseToJsonElement(r.ledger.readText()) as kotlinx.serialization.json.JsonObject
        assertEquals(setOf("schemaVersion", "items", "pendingAfterRip"), root.keys)
        val item = (root["items"] as kotlinx.serialization.json.JsonArray)[0] as kotlinx.serialization.json.JsonObject
        val iosFields = setOf(
            "songId", "title", "artist", "audioFileName", "sidecarFileName", "source", "bpm", "musicalKey", "camelot",
            "durationMs", "startMs", "bytes", "rippedAt", "downloadedAt", "state", "error", "wasAppStorage",
            "cutFileName", "cutDownloadedAt",
        )
        assertTrue("unexpected fields ${item.keys - iosFields}", item.keys.all { it in iosFields })
        assertEquals("ready", (item["state"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("true", (item["wasAppStorage"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertFalse(item.containsKey("startMs")) // digital: absent, never null
        // and our own reader round-trips it
        assertEquals(store.items.value, r.store().items.value)
    }

    // ---- pendingAfterRip -------------------------------------------------------------------

    @Test fun drainClearsIntentOnlyWhenBurnedAndPersistsAcrossReinit() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burnWhenRipped("a", "Song a", "Artist", nowMs = 5.0)
        store.burnWhenRipped("a", "Song a", "Artist", nowMs = 6.0) // idempotent
        store.burnWhenRipped("late", "L", "Artist")
        assertTrue(store.isAwaitingBurn("a"))
        // survives a store re-init
        assertEquals(setOf("a", "late"), r.store().pendingAfterRip.value.keys)
        assertEquals(5.0, r.store().pendingAfterRip.value.getValue("a").requestedAtMs, 0.0)
        // "late" isn't ripped yet => untouched; "a" burns => cleared
        assertEquals(1, store.drainPendingAfterRip())
        assertFalse(store.isAwaitingBurn("a")); assertTrue(store.isAwaitingBurn("late"))
        assertEquals(setOf("late"), r.store().pendingAfterRip.value.keys)
        // transient failure keeps the intent
        r.digitalSong("late"); r.rips.presignFails = true
        assertEquals(0, store.drainPendingAfterRip())
        assertTrue(store.isAwaitingBurn("late"))
        r.rips.presignFails = false
        assertEquals(1, store.drainPendingAfterRip())
        assertTrue(store.pendingAfterRip.value.isEmpty())
        store.burnWhenRipped("x", "X", "A"); store.cancelPendingBurn("x")
        assertFalse(store.isAwaitingBurn("x"))
    }
}
