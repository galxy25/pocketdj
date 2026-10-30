package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** ANS-MIX-3: the ON_STOP flush snapshots under the lock but encodes (and writes) OUTSIDE it. */
class MixSessionStoreFlushTest {

    @Test fun sessionsLogEventCompletesWhileAFlushEncodeIsStillRunning() {
        val clock = TestClock()
        val file = tempFile("sessions2.json")
        val gate = AtomicBoolean(false)          // arm only the flush's encode
        val encoding = CountDownLatch(1)
        val release = CountDownLatch(1)
        val seedEncoded = CountDownLatch(1)
        val store = MixSessionStore(
            // Production writes on a background thread; DIRECT would encode queued saves inline under the lock.
            file, VersionedJsonWriter(file) { Thread(it).start() }, clock::read, ManualScheduler(clock),
            encoder = { doc ->
                if (gate.get()) { encoding.countDown(); release.await(10, TimeUnit.SECONDS) } else seedEncoded.countDown()
                PdjJson.lenient.encodeToString(doc)
            },
        )
        store.notePlayed("seed")
        assertTrue("seed save encoded", seedEncoded.await(5, TimeUnit.SECONDS))   // before arming the gate (no timing sleep)
        gate.set(true)
        val flusher = Thread { store.flush() }.also { it.start() }
        assertTrue("flush reached its encode", encoding.await(5, TimeUnit.SECONDS))
        val logged = CountDownLatch(1)
        Thread {
            store.notePlayed("during-flush")      // takes the store lock; must not wait for the encode
            logged.countDown()
        }.start()
        val completedWhileEncoding = logged.await(3, TimeUnit.SECONDS)
        release.countDown()
        flusher.join(5_000)
        assertTrue("store lock was free during the flush encode", completedWhileEncoding)
        assertTrue(store.hasPlayed("during-flush"))
        assertTrue("flush wrote the snapshot taken under the lock", file.readText().contains("seed"))
    }

    @Test fun deckFlushEncodesOffTheLockAndLastWriteWins() {
        val clock = TestClock()
        val file = tempFile("decks.json")
        val gate = AtomicBoolean(false)
        val encoding = CountDownLatch(1)
        val release = CountDownLatch(1)
        val store = MixDeckSessionStore(
            file, VersionedJsonWriter(file), clock::read, ManualScheduler(clock),
            encoder = { snap ->
                if (gate.get()) { encoding.countDown(); release.await(10, TimeUnit.SECONDS) }
                MixDeckSessionStore.encode(snap)
            },
        )
        val track = TrackRef("song1", "T", "A")
        fun snap(xf: Double) = MixDeckSnapshot(
            deckA = DeckSnapshot(
                track = track, positionMs = 1000, volume = 1.0, rate = 1.0, pitch = 0.0,
                compressor = false, reverb = false, flanger = false, filter = false,
                compStrength = 0.0, reverbStrength = 0.0, flangerStrength = 0.0, filterStrength = 0.0,
                stemMode = false, stemMuted = emptyList(), stemVol = emptyMap(),
            ),
            deckB = null, crossfader = xf, wasRunning = false, updatedAt = 0.0,
        )
        store.save(snap(0.1))
        gate.set(true)
        val flusher = Thread { store.flush() }.also { it.start() }
        assertTrue(encoding.await(5, TimeUnit.SECONDS))
        val saved = CountDownLatch(1)
        Thread { store.saveDebounced(snap(0.9)); saved.countDown() }.start()
        val free = saved.await(3, TimeUnit.SECONDS)
        release.countDown()
        flusher.join(5_000)
        assertTrue("deck store lock was free during the flush encode", free)
        assertEquals(0.1, store.load()!!.crossfader, 1e-9)   // the flush wrote the pre-debounce snapshot; the debounced write is still pending
    }
}
