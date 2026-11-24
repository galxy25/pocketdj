package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.rips.RipStems
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TemporaryHoldLedgerTest {
    private val hour = 3_600_000.0

    // ---- pure ledger ---------------------------------------------------------------------------

    @Test fun noHoldMeansPinned() {
        val l = TemporaryHoldLedger()
        assertFalse(l.isTemporary("a")); assertNull(l.expiry("a")); assertEquals(0L, l.footprintBytes)
        assertNull(l.toDocument())
        assertTrue(l.pin(listOf("a")).isEmpty())
    }

    @Test fun creationStampsExpiryAndAccumulatesParts() {
        val l = TemporaryHoldLedger()
        val h = l.noteCreated(TemporaryHoldLedger.Created("a", audioBytes = 100), 1_000.0, 48.0, false)!!
        assertEquals(1_000.0 + 48 * hour, h.expiresAtMs, 0.0)
        assertTrue(l.isTemporary("a"))
        // A later stem landing moves the expiry LATER, never earlier.
        l.noteCreated(TemporaryHoldLedger.Created("a", stemPart = "vocals", stemBytes = 40), 5_000.0, 48.0, false)
        l.noteCreated(TemporaryHoldLedger.Created("a", stemPart = "drums", stemBytes = 60), 2_000.0, 1.0, false)
        val got = l["a"]!!
        assertEquals(5_000.0 + 48 * hour, got.expiresAtMs, 0.0)
        assertEquals(1_000.0, got.createdAtMs, 0.0)
        assertEquals(listOf("vocals", "drums"), got.stemParts)
        assertEquals(200L, got.bytes)
        assertEquals(200L, l.footprintBytes)
    }

    @Test fun keepTtlWritesNoHold() {
        val l = TemporaryHoldLedger()
        assertNull(l.noteCreated(TemporaryHoldLedger.Created("a", audioBytes = 1), 0.0, null, false))
        assertTrue(l.isEmpty)
    }

    @Test fun pickedFolderRules() {
        val l = TemporaryHoldLedger()
        val c = TemporaryHoldLedger.Created("a", audioBytes = 9, inUserFolder = true, folderPath = "/pick", fileName = "a.mp3", fileMtimeMs = 77.0)
        assertNull("keep-picked switch pins at creation", l.noteCreated(c, 0.0, 48.0, keepPickedFolder = true))
        assertNull("unreadable identity pins at creation", l.noteCreated(c.copy(fileMtimeMs = null), 0.0, 48.0, false))
        val h = l.noteCreated(c, 0.0, 48.0, false)!!
        assertEquals("/pick", h.userFolderPath)
        assertEquals(mapOf("a.mp3" to 77.0), h.userFolderFiles)
    }

    @Test fun folderSwitchReleasesEarlierUserFolderAssets() {
        val l = TemporaryHoldLedger()
        l.noteCreated(TemporaryHoldLedger.Created("a", audioBytes = 9, inUserFolder = true, folderPath = "/one", fileName = "a.mp3", fileMtimeMs = 1.0), 0.0, 48.0, false)
        l.noteCreated(TemporaryHoldLedger.Created("a", stemPart = "bass", stemBytes = 5, inUserFolder = true, folderPath = "/one", fileName = "s.mp3", fileMtimeMs = 2.0), 0.0, 48.0, false)
        val h = l.noteCreated(
            TemporaryHoldLedger.Created("a", stemPart = "other", stemBytes = 7, inUserFolder = true, folderPath = "/two", fileName = "o.mp3", fileMtimeMs = 3.0, heldAudioInUserFolder = true),
            0.0, 48.0, false,
        )!!
        assertEquals("/two", h.userFolderPath)
        assertFalse("old-folder audio released (pinned)", h.audio)
        assertEquals(listOf("other"), h.stemParts)
        assertEquals(mapOf("o.mp3" to 3.0), h.userFolderFiles)
    }

    @Test fun pinMatchesByBaseIdAndPinAllClears() {
        val base = "sng_0123456789ab"
        val l = TemporaryHoldLedger()
        l.noteCreated(TemporaryHoldLedger.Created(base, audioBytes = 1), 0.0, 48.0, false)
        l.noteCreated(TemporaryHoldLedger.Created(base + "_clean", audioBytes = 1), 0.0, 48.0, false)
        l.noteCreated(TemporaryHoldLedger.Created("sng_ba9876543210", audioBytes = 1), 0.0, 48.0, false)
        // pinning a variant row pins the base and the sibling variant hold too (over-pinning only keeps files)
        val dropped = l.pin(listOf(base + "_explicit"))
        assertEquals(setOf(base, base + "_clean"), dropped.toSet())
        assertTrue(l.isTemporary("sng_ba9876543210"))
        assertEquals(1, l.pinAll()); assertTrue(l.isEmpty)
    }

    @Test fun forgettingAllStemPartsOfAStemOnlyHoldRemovesIt() {
        val l = TemporaryHoldLedger()
        l.noteCreated(TemporaryHoldLedger.Created("a", stemPart = "bass", stemBytes = 5), 0.0, 48.0, false)
        l.forgetStemParts("a", BurnFileNames.STEM_NAMES)
        assertTrue(l.isEmpty)
    }

    @Test fun assetOriginJoinRule() {
        val e = AssetOrigin.explicit("mix")
        assertEquals(e, AssetOrigin.Buffer.merged(e)); assertEquals(e, e.merged(AssetOrigin.Buffer))
        assertEquals(AssetOrigin.Incidental, AssetOrigin.Buffer.merged(AssetOrigin.Incidental))
        assertEquals(AssetOrigin.Buffer, AssetOrigin.Buffer.merged(AssetOrigin.Buffer))
        assertEquals(e, e.merged(AssetOrigin.Incidental))
    }

    // ---- JSON ----------------------------------------------------------------------------------

    @Test fun iosShapedLedgerWithoutHoldsRoundTripsByteStable() {
        val ios = """{"schemaVersion":1,"items":[{"songId":"a","title":"T","artist":"A","audioFileName":"a.mp3","sidecarFileName":"a.txt","source":"digital","bytes":5,"downloadedAt":1.0,"state":"ready"}],"pendingAfterRip":[]}"""
        val doc = PdjJson.lenient.decodeFromString(BurnDocument.serializer(), ios)
        assertNull(doc.temporaryHolds)
        val out = PdjJson.lenient.encodeToString(BurnDocument.serializer(), doc)
        assertFalse("no new key emitted when absent", out.contains("temporaryHolds"))
        val again = PdjJson.lenient.encodeToString(BurnDocument.serializer(), PdjJson.lenient.decodeFromString(BurnDocument.serializer(), out))
        assertEquals(out, again)
    }

    @Test fun iosShapedTemporaryHoldsDecodeAndReEncode() {
        val ios = """{"schemaVersion":1,"items":[],"temporaryHolds":[{"songId":"a","audio":true,"stemParts":["vocals"],"createdAtMs":1000.0,"expiresAtMs":173800000.0,"audioBytes":4321,"stemBytes":{"vocals":99},"userFolderPath":"/p","userFolderFiles":{"a.mp3":42.0}}]}"""
        val doc = PdjJson.lenient.decodeFromString(BurnDocument.serializer(), ios)
        val h = doc.temporaryHolds!!.single()
        assertEquals("a", h.songId); assertTrue(h.audio); assertEquals(listOf("vocals"), h.stemParts)
        assertEquals(4321L, h.audioBytes); assertEquals(99L, h.stemBytes!!["vocals"]); assertEquals(42.0, h.userFolderFiles!!["a.mp3"]!!, 0.0)
        assertEquals(4420L, h.bytes)
        val re = PdjJson.lenient.decodeFromString(BurnDocument.serializer(), PdjJson.lenient.encodeToString(BurnDocument.serializer(), doc))
        assertEquals(doc, re)
    }

    // ---- BurnStore integration ---------------------------------------------------------------

    private fun Rig.digitalSong(id: String, size: Int = 8_192) {
        rips.entries[id] = digital(id)
        rips.serve("rips/$id.mp3", size)
        catalog[id] = song(id, name = "Song $id") to album("alb_$id")
    }

    private fun Rig.stemmed(id: String) {
        rips.entries[id] = digital(id).copy(
            stems = RipStems("stems/$id/vocals.mp3", "stems/$id/drums.mp3", "stems/$id/bass.mp3", "stems/$id/other.mp3"),
            stemVersion = 1,
        )
        rips.serve("rips/$id.mp3", 6_000)
        BurnFileNames.STEM_NAMES.forEach { rips.serve("stems/$id/$it.mp3", 1_000 + it.length) }
        catalog[id] = song(id) to album("a")
    }

    private fun Rig.stream(name: String, size: Int = 4_000) = File(dir, name).apply { writeBytes(ByteArray(size)) }

    @Test fun explicitBurnsNeverWriteAHold() = runTest {
        val r = Rig(); r.digitalSong("a"); r.digitalSong("b")
        val store = r.store()
        store.burn(listOf(bs("a"), bs("b")))
        assertTrue(store.temporaryHolds.value.isEmpty())
        assertFalse(r.ledger.readText().contains("temporaryHolds"))
        // explicit stream adoption (default origin is Incidental at the store; loader passes explicit)
        val r2 = Rig(); r2.digitalSong("c")
        val s2 = r2.store()
        s2.adoptStreamedFile("c", "T", "A", r2.stream("c.tmp"), AssetOrigin.explicit("mix"))
        assertFalse(s2.isTemporary("c"))
    }

    @Test fun bufferLandingWritesHoldWithTtlExpiryAndPersists() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        var changed = 0
        store.onTemporaryHoldsChanged = { changed++ }
        assertNotNull(store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp", 4_000), AssetOrigin.Buffer))
        val h = store.temporaryHolds.value.getValue("a")
        assertTrue(h.audio); assertEquals(4_000L, h.audioBytes)
        assertEquals(r.nowMs + 48 * hour, h.expiresAtMs, 0.0)
        assertEquals(1, changed)
        assertTrue(store.isTemporary("a")); assertEquals(4_000L, store.temporaryFootprintBytes)
        // per-device ledger persisted; a fresh store over the same file sees it
        val reloaded = r.store()
        assertEquals(h, reloaded.temporaryHolds.value["a"])
    }

    @Test fun bufferLandingOverAnExistingItemWritesNoHold() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.burn(listOf(bs("a")))                       // explicit download first
        assertNull(store.adoptStreamedFile("a", "T", "A", r.stream("again.tmp"), AssetOrigin.Buffer))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun keepTtlMakesBufferLandingsNormalDownloads() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store(ttlHours = { null })
        assertNotNull(store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"), AssetOrigin.Buffer))
        assertTrue(store.temporaryHolds.value.isEmpty())
        assertEquals(BurnState.READY, store.items.value.getValue("a").state)
    }

    @Test fun incidentalLandingIsPermanentAndNoHold() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun explicitBurnPinsBeforeTheFreshnessSkip() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"), AssetOrigin.Buffer)
        assertTrue(store.isTemporary("a"))
        val downloadsBefore = r.rips.downloads.size
        store.burn(listOf(bs("a")))                       // already burned + fresh -> skipped, but pinned
        assertFalse(store.isTemporary("a"))
        assertEquals("freshness skip still downloads nothing", downloadsBefore, r.rips.downloads.size)
        assertFalse(r.ledger.readText().contains("temporaryHolds"))
    }

    @Test fun explicitStreamAdoptionOfABufferedSongPins() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"), AssetOrigin.Buffer)
        assertNull(store.adoptStreamedFile("a", "T", "A", r.stream("b.tmp"), AssetOrigin.explicit("mix"))) // already burned
        assertFalse(store.isTemporary("a"))
    }

    @Test fun pinRemovesHoldsAndIsANoOpWithoutOne() = runTest {
        val r = Rig(); r.digitalSong("a"); r.digitalSong("b")
        val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"), AssetOrigin.Buffer)
        store.adoptStreamedFile("b", "T", "A", r.stream("b.tmp"), AssetOrigin.Buffer)
        assertEquals(0, store.pin(listOf("zzz"), "test"))
        assertEquals(1, store.pin(listOf("a"), "test"))
        assertFalse(store.isTemporary("a")); assertTrue(store.isTemporary("b"))
        assertEquals(1, store.pinAllTemporary("keep-all"))
        assertTrue(store.temporaryHolds.value.isEmpty())
        assertFalse(r.store().isTemporary("b"))
    }

    @Test fun explicitStemPartRePinsAHoldLandedByAConcurrentBufferAdoption() = runTest {
        val r = Rig(); r.stemmed("s")
        val store = r.store()
        var fired = false
        r.rips.onDownload = {
            if (!fired) {
                fired = true
                val parts = BurnFileNames.STEM_NAMES.associateWith { n -> r.stream("$n.tmp", 500) }
                store.adoptStreamedStems("s", parts, AssetOrigin.Buffer)
                assertTrue("buffer landing wrote a hold mid-download", store.isTemporary("s") || store.temporaryHolds.value.containsKey("s"))
            }
        }
        assertTrue(store.burnStemPart("s", "vocals", AssetOrigin.explicit("mix")))
        assertTrue("explicit action must end with no hold", store.temporaryHolds.value.isEmpty())
    }

    @Test fun burnStemsRePinsAfterAConcurrentBufferLanding() = runTest {
        val r = Rig(); r.stemmed("s")
        val store = r.store()
        var fired = false
        r.rips.onDownload = {
            if (!fired) {
                fired = true
                val parts = BurnFileNames.STEM_NAMES.associateWith { n -> r.stream("$n.tmp", 500) }
                store.adoptStreamedStems("s", parts, AssetOrigin.Buffer)
            }
        }
        assertNotNull(store.burnStems("s"))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun bufferStemsHoldOnlyPartsItCreated() = runTest {
        val r = Rig(); r.stemmed("s")
        val store = r.store()
        // one part already on disk (an explicit earlier download) - never temporary
        assertTrue(store.burnStemPart("s", "vocals"))
        val files = BurnFileNames.STEM_NAMES.associateWith { r.stream("$it.tmp", 500) }
        val out = store.adoptStreamedStems("s", files, AssetOrigin.Buffer)
        assertNotNull(out)
        val h = store.temporaryHolds.value.getValue("s")
        assertEquals(setOf("drums", "bass", "other"), h.stemParts.toSet())
        assertFalse(h.audio)
        assertEquals(1_500L, h.bytes)
    }

    @Test fun burnStemPartBufferOriginHoldsAndExplicitPins() = runTest {
        val r = Rig(); r.stemmed("s")
        val store = r.store()
        assertTrue(store.burnStemPart("s", "drums", AssetOrigin.Buffer))
        assertEquals(listOf("drums"), store.temporaryHolds.value.getValue("s").stemParts)
        assertTrue(store.burnStemPart("s", "drums", AssetOrigin.explicit("stems")))   // file exists -> still pins
        assertTrue(store.temporaryHolds.value.isEmpty())
        // legacy default origin writes no hold
        assertTrue(store.burnStemPart("s", "bass"))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun explicitBurnStemsPinsAnExistingStemHold() = runTest {
        val r = Rig(); r.stemmed("s")
        val store = r.store()
        store.burnStemPart("s", "drums", AssetOrigin.Buffer)
        assertNotNull(store.burnStems("s"))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }

    @Test fun removingABurnDropsItsHold() = runTest {
        val r = Rig(); r.digitalSong("a")
        val store = r.store()
        store.adoptStreamedFile("a", "T", "A", r.stream("a.tmp"), AssetOrigin.Buffer)
        store.removeBurns(listOf("a"))
        assertTrue(store.temporaryHolds.value.isEmpty())
    }
}
