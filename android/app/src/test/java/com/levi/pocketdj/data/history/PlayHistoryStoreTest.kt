package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The recording + persistence contract of specs/history.md §2–§3: the 30 s
 * same-song re-count window (with its load-bearing direction guard), max-based
 * last-played index, cap trim, additive-optional decode, and the
 * fresh-log-on-corrupt fallback.
 */
class PlayHistoryStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun newFile(): File = File(tmp.root, "pocketdj-play-history.json")

    private fun newStore(
        file: File = newFile(),
        maxEvents: Int = PlayHistoryStore.DEFAULT_MAX_EVENTS,
    ) = PlayHistoryStore(file = file, json = PdjJson.lenient, maxEvents = maxEvents)

    private val t0 = 1_750_000_000_000L

    // MARK: record + dedup

    @Test
    fun record_appendsEventWithSnapshotsAndContext() {
        val store = newStore()
        val event = store.record(
            songId = "sng_a",
            title = "Song A",
            artist = "Artist A",
            context = PlayContext.album("alb_1", "Album One"),
            nowMs = t0,
        )
        assertNotNull(event)
        assertEquals(1, store.events.size)
        assertEquals("sng_a", event!!.songId)
        assertEquals(t0.toDouble(), event.playedAt, 0.0)
        assertEquals(PlaySource.ALBUM, event.source)
        assertEquals("alb_1", event.contextId)
        assertEquals("Album One", event.contextName)
        assertEquals("Song A", event.title)
        assertEquals(1, store.playCount("sng_a"))
        assertEquals(t0.toDouble(), store.lastPlayedAt("sng_a")!!, 0.0)
    }

    @Test
    fun record_emptySongId_isIgnored() {
        val store = newStore()
        val before = store.revision
        assertNull(store.record(songId = "", nowMs = t0))
        assertEquals(0, store.events.size)
        assertEquals(before, store.revision)
    }

    @Test
    fun record_sameSongInsideWindow_isDropped() {
        val store = newStore()
        assertNotNull(store.record("sng_a", nowMs = t0))
        // 29.999 s later — same listen (seek/restart/double-hook): dropped.
        assertNull(store.record("sng_a", nowMs = t0 + 29_999))
        assertEquals(1, store.events.size)
        assertEquals(1, store.playCount("sng_a"))
    }

    @Test
    fun record_sameSongOutsideWindow_records() {
        val store = newStore()
        assertNotNull(store.record("sng_a", nowMs = t0))
        assertNotNull(store.record("sng_a", nowMs = t0 + 30_000))
        assertEquals(2, store.events.size)
        assertEquals(2, store.playCount("sng_a"))
    }

    @Test
    fun record_differentSongInsideWindow_records() {
        val store = newStore()
        assertNotNull(store.record("sng_a", nowMs = t0))
        assertNotNull(store.record("sng_b", nowMs = t0 + 1_000))
        assertEquals(2, store.events.size)
    }

    @Test
    fun record_olderTimestamp_recordsAndKeepsMaxLastPlayed() {
        // Direction guard: nowMs < last is a genuinely distinct play — a
        // negative delta must never read as "within the window".
        val store = newStore()
        assertNotNull(store.record("sng_a", nowMs = t0))
        val older = store.record("sng_a", nowMs = t0 - 5_000)
        assertNotNull(older)
        assertEquals(2, store.events.size)
        assertEquals(2, store.playCount("sng_a"))
        // Max-based index update: the out-of-order append can't move
        // last-played backwards.
        assertEquals(t0.toDouble(), store.lastPlayedAt("sng_a")!!, 0.0)
    }

    @Test
    fun record_bumpsRevisionPerRealMutationOnly() {
        val store = newStore()
        val base = store.revision
        store.record("sng_a", nowMs = t0)
        assertEquals(base + 1, store.revision)
        store.record("sng_a", nowMs = t0 + 1_000) // deduped — no bump
        assertEquals(base + 1, store.revision)
        store.record("sng_b", nowMs = t0 + 2_000)
        assertEquals(base + 2, store.revision)
    }

    // MARK: cap

    @Test
    fun cap_trimDropsOldestAndRebuildsCounts() {
        val store = newStore(maxEvents = 3)
        store.record("sng_a", nowMs = t0)
        store.record("sng_b", nowMs = t0 + 60_000)
        store.record("sng_c", nowMs = t0 + 120_000)
        val revAtCap = store.revision
        store.record("sng_d", nowMs = t0 + 180_000)
        assertEquals(3, store.events.size) // size pins at the cap…
        assertEquals(revAtCap + 1, store.revision) // …but revision still bumps
        assertEquals(listOf("sng_b", "sng_c", "sng_d"), store.events.map { it.songId })
        // Index rebuild after trim: the dropped oldest is gone from counts.
        assertEquals(0, store.playCount("sng_a"))
        assertNull(store.lastPlayedAt("sng_a"))
        assertEquals(1, store.playCount("sng_d"))
    }

    // MARK: persistence

    @Test
    fun persistence_roundTripAcrossStoreInstances() {
        val file = newFile()
        val first = newStore(file)
        first.record("sng_a", title = "A", artist = "AA", nowMs = t0)
        val installId = first.installId

        val second = newStore(file)
        assertEquals(installId, second.installId)
        assertEquals(1, second.events.size)
        assertEquals("sng_a", second.events[0].songId)
        assertEquals("A", second.events[0].title)
        assertEquals(1, second.playCount("sng_a"))
        assertEquals(t0.toDouble(), second.lastPlayedAt("sng_a")!!, 0.0)
    }

    @Test
    fun decode_oldDocMissingOptionals_andUnknownFields_survives() {
        // A "future" doc: unknown top-level + per-event keys, missing optional
        // fields, and an unknown source token. Additive-optional iron law: the
        // decode must succeed and keep every event.
        val file = newFile()
        file.writeText(
            """
            {
              "schemaVersion": 1,
              "installId": "install-123",
              "someFutureTopLevel": {"a": 1},
              "events": [
                {"id": "ev1", "songId": "sng_a", "playedAt": 1750000000000, "source": "browser"},
                {"id": "ev2", "songId": "sng_b", "playedAt": 1750000060000.0, "source": "hologram",
                 "title": "B", "futureField": [1, 2, 3]}
              ]
            }
            """.trimIndent(),
        )
        val store = newStore(file)
        assertEquals("install-123", store.installId)
        assertEquals(2, store.events.size)
        val ev1 = store.events[0]
        assertEquals(PlaySource.BROWSER, ev1.source)
        assertNull(ev1.contextId)
        assertNull(ev1.title)
        // Unknown future source token coerces to browser instead of wiping the doc.
        assertEquals(PlaySource.BROWSER, store.events[1].source)
        assertEquals("B", store.events[1].title)
        assertEquals(1, store.playCount("sng_a"))
    }

    @Test
    fun decode_corruptFile_fallsBackToFreshLogWithNewInstallId() {
        val file = newFile()
        file.writeText("{ not json !!!")
        val store = newStore(file)
        assertEquals(0, store.events.size)
        assertTrue(store.installId.isNotBlank())
        // Fresh identity is persisted so it stays stable across relaunches.
        val again = newStore(file)
        assertEquals(store.installId, again.installId)
    }

    @Test
    fun clear_wipesEventsButKeepsInstallId() {
        val file = newFile()
        val store = newStore(file)
        store.record("sng_a", nowMs = t0)
        val installId = store.installId
        val rev = store.revision
        store.clear()
        assertEquals(0, store.events.size)
        assertEquals(installId, store.installId)
        assertEquals(0, store.playCount("sng_a"))
        assertEquals(rev + 1, store.revision)
        // And the wipe persisted.
        assertEquals(0, newStore(file).events.size)
    }

    @Test
    fun replaceAll_swapsLogRecapsAndRebuildsIndexes() {
        val store = newStore(maxEvents = 2)
        store.record("sng_x", nowMs = t0)
        val replacement = (1..3).map { n ->
            PlayEvent(
                id = "ev$n",
                songId = "sng_r",
                playedAt = (t0 + n * 60_000L).toDouble(),
                source = PlaySource.SETLIST,
            )
        }
        store.replaceAll(replacement)
        assertEquals(2, store.events.size) // re-capped, oldest dropped
        assertEquals(listOf("ev2", "ev3"), store.events.map { it.id })
        assertEquals(0, store.playCount("sng_x"))
        assertEquals(2, store.playCount("sng_r"))
        assertEquals((t0 + 180_000L).toDouble(), store.lastPlayedAt("sng_r")!!, 0.0)
    }

    @Test
    fun events_haveUniqueStableIds() {
        val store = newStore()
        store.record("sng_a", nowMs = t0)
        store.record("sng_b", nowMs = t0 + 1_000)
        val ids = store.events.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        assertNotEquals("", ids[0])
    }
}
