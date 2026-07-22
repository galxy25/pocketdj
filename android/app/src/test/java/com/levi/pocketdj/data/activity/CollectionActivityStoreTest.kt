package com.levi.pocketdj.data.activity

import com.levi.pocketdj.data.PdjJson
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The activity-log contract of specs/activity-favorites.md §2–§3: record
 * semantics (NO dedup window — deliberate contrast with the play log), cap
 * trim, lenient decode, corrupt-quarantine, and clear-keeps-installId.
 */
class CollectionActivityStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun newFile(): File = File(tmp.root, CollectionActivityStore.FILE_NAME)

    private fun newStore(
        file: File = newFile(),
        maxEvents: Int = CollectionActivityStore.DEFAULT_MAX_EVENTS,
    ) = CollectionActivityStore(file = file, json = PdjJson.lenient, maxEvents = maxEvents)

    private val t0 = 1_750_000_000_000.0

    @Test
    fun record_roundTripsEveryField_andPersists() {
        val file = newFile()
        val store = newStore(file)
        val event = store.record(
            kind = ActivityKind.ADD,
            itemId = "sng_1",
            itemTitle = "Tiny Dancer",
            collectionId = "pkt_1",
            collectionKind = "pocket",
            collectionName = "Crate",
            atMs = t0,
        )
        assertEquals(ActivityKind.ADD, event!!.kind)
        assertEquals("sng_1", event.itemId)
        assertEquals("Tiny Dancer", event.itemTitle)
        assertEquals("pkt_1", event.collectionId)
        assertEquals("pocket", event.collectionKind)
        assertEquals("Crate", event.collectionName)
        assertEquals(t0, event.at, 0.0)

        val relaunched = newStore(file)
        assertEquals(listOf(event), relaunched.events)
        assertEquals(store.installId, relaunched.installId)
    }

    @Test
    fun record_emptyItemId_isIgnored() {
        val store = newStore()
        assertNull(store.record(ActivityKind.ADD, itemId = ""))
        assertTrue(store.events.isEmpty())
        assertEquals(0, store.revision)
    }

    @Test
    fun record_hasNoDedupWindow_twoQuickActsAreTwoEvents() {
        val store = newStore()
        store.record(ActivityKind.ADD, "sng_1", atMs = t0)
        store.record(ActivityKind.ADD, "sng_1", atMs = t0 + 1_000)
        store.record(ActivityKind.REMOVE, "sng_1", atMs = t0 + 2_000)
        assertEquals(3, store.events.size)
        // Distinct event ids (the merge/dedupe key).
        assertEquals(3, store.events.map { it.id }.toSet().size)
    }

    @Test
    fun allFourKinds_recordAndRoundTrip() {
        val file = newFile()
        val store = newStore(file)
        for (kind in ActivityKind.entries) store.record(kind, "sng_1", atMs = t0)
        val relaunched = newStore(file)
        assertEquals(ActivityKind.entries.toList(), relaunched.events.map { it.kind })
    }

    @Test
    fun capTrim_dropsTheOldest_revisionKeepsBumping() {
        val store = newStore(maxEvents = 3)
        repeat(5) { i -> store.record(ActivityKind.ADD, "sng_$i", atMs = t0 + i) }
        assertEquals(listOf("sng_2", "sng_3", "sng_4"), store.events.map { it.itemId })
        val revisionAtCap = store.revision
        store.record(ActivityKind.ADD, "sng_5", atMs = t0 + 9)
        assertEquals(3, store.events.size) // size pins…
        assertNotEquals(revisionAtCap, store.revision) // …revision does not
    }

    @Test
    fun lenientDecode_missingFields_loadDegraded_neverReset() {
        val file = newFile()
        file.parentFile?.mkdirs()
        // Missing installId + schemaVersion, unknown key, minimal event.
        file.writeText(
            """{"events": [{"id": "evt-1", "at": 1, "kind": "heart", "itemId": "sng_1"}],
                "futureKey": true}""",
        )
        val store = newStore(file)
        assertEquals(1, store.events.size)
        assertEquals(ActivityKind.HEART, store.events[0].kind)
        assertNull(store.events[0].collectionId)
        assertTrue(store.installId.isNotBlank()) // fresh identity minted
    }

    @Test
    fun corruptJson_quarantinesToBak_andStartsFresh() {
        val file = newFile()
        file.parentFile?.mkdirs()
        file.writeText("{ nope")
        val store = newStore(file)
        assertTrue(store.events.isEmpty())
        assertTrue(File(tmp.root, CollectionActivityStore.FILE_NAME + ".bak").exists())
        store.record(ActivityKind.ADD, "sng_1", atMs = t0)
        assertEquals(1, newStore(file).events.size)
    }

    @Test
    fun replaceAll_swapsAndRecaps() {
        val store = newStore(maxEvents = 2)
        val events = (0 until 4).map { i ->
            ActivityEvent(id = "evt-$i", at = t0 + i, kind = ActivityKind.ADD, itemId = "sng_$i")
        }
        store.replaceAll(events)
        assertEquals(listOf("sng_2", "sng_3"), store.events.map { it.itemId })
    }

    @Test
    fun clear_deletesTheFile_keepsInstallId_bumpsRevision() {
        val file = newFile()
        val store = newStore(file)
        store.record(ActivityKind.ADD, "sng_1", atMs = t0)
        val installId = store.installId
        val revision = store.revision

        store.clear()
        assertTrue(store.events.isEmpty())
        assertEquals(installId, store.installId)
        assertTrue(store.revision > revision)
        assertFalse(file.exists()) // no residual empty JSON
    }

    @Test
    fun eventIds_travelVerbatim_noCaseNormalization() {
        val file = newFile()
        file.parentFile?.mkdirs()
        file.writeText(
            """{"installId": "INSTALL-UPPER",
                "events": [{"id": "ABC-DEF", "at": 1, "kind": "add", "itemId": "sng_1"}]}""",
        )
        val store = newStore(file)
        assertEquals("ABC-DEF", store.events[0].id)
        assertEquals("INSTALL-UPPER", store.installId)
    }
}
