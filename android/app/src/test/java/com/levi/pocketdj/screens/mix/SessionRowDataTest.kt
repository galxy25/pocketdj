package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.store.ManualScheduler
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionStore
import com.levi.pocketdj.mix.store.TestClock
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionRowDataTest {
    @Test fun currentSessionRowReflectsLiveBuffers() {
        val clock = TestClock()
        val file = File.createTempFile("sessions", ".json").also { it.delete(); it.deleteOnExit() }
        var n = 0
        val store = MixSessionStore(file, VersionedJsonWriter(file), clock::read, ManualScheduler(clock)) { "id${++n}".padEnd(12, '0') }
        store.logEvent(MixEventKind.Load, "A", "s1", "T", "A", null, null, null, null, null, null, null)
        store.notePlayed("s1")
        clock.now += 5_000
        store.logEvent(MixEventKind.Play, "A", null, null, null, null, null, null, null, null, null, null)
        val row = SessionRowText.rows(store).single { it.session.id == store.currentId }
        assertEquals(2, row.actions)
        assertEquals(1, row.tracks)
        assertTrue(row.durationMs >= 5_000)
        // The raw flow copy is the stale one the review flagged.
        assertEquals(0, store.sessions.value.single { it.id == store.currentId }.events.size)
    }
}
