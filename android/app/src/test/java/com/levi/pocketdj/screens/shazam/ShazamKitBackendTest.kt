package com.levi.pocketdj.screens.shazam

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class ShazamKitBackendTest {
    private class FakePcm : PcmSource {
        override val bufferSize = 4096
        val started = AtomicBoolean(false)
        val released = AtomicBoolean(false)
        val reads = AtomicInteger(0)
        var failAfter = Int.MAX_VALUE
        override fun start() { started.set(true) }
        override fun read(buffer: ByteArray): Int {
            Thread.sleep(2)
            return if (reads.incrementAndGet() > failAfter) -3 else 1920
        }
        override fun release() { released.set(true) }
    }

    private class FakeStream(val outcome: StreamOutcome?) : ShazamStream {
        val fed = AtomicInteger(0)
        val lastTs = java.util.concurrent.atomic.AtomicLong(-1)
        override fun matchStream(audio: ByteArray, meaningfulLength: Int, timestampMs: Long) {
            fed.incrementAndGet(); lastTs.set(timestampMs)
        }
        override fun outcomes(): Flow<StreamOutcome> = flow {
            if (outcome == null) { kotlinx.coroutines.awaitCancellation() }
            // emit only after some audio has been fed, like the real session
            while (fed.get() < 3) delay(1)
            emit(outcome)
        }
    }

    @Test fun match_becomes_hit_and_releases_mic() = runBlocking {
        val info = ShazamHitInfo("Song", "Artist", null, "42")
        val pcm = FakePcm()
        val r = ShazamStreamDriver.run(FakeStream(StreamOutcome.Match(info)), pcm, timeoutMs = 5_000)
        assertEquals(RecognitionResult.Hit(info), r)
        assertTrue(pcm.started.get()); assertTrue(pcm.released.get())
    }

    @Test fun no_match_outcome() = runBlocking {
        val pcm = FakePcm()
        assertEquals(RecognitionResult.NoMatch, ShazamStreamDriver.run(FakeStream(StreamOutcome.NoMatch), pcm, timeoutMs = 5_000))
        assertTrue(pcm.released.get())
    }

    @Test fun match_without_item_is_no_match() = runBlocking {
        assertEquals(RecognitionResult.NoMatch, ShazamStreamDriver.run(FakeStream(StreamOutcome.Match(null)), FakePcm(), timeoutMs = 5_000))
    }

    @Test fun error_outcome_maps_to_error() = runBlocking {
        val r = ShazamStreamDriver.run(FakeStream(StreamOutcome.Error("boom")), FakePcm(), timeoutMs = 5_000)
        assertEquals(RecognitionResult.Error("boom"), r)
    }

    @Test fun timeout_is_no_match_and_releases() = runBlocking {
        val pcm = FakePcm()
        val r = ShazamStreamDriver.run(FakeStream(null), pcm, timeoutMs = 150)
        assertEquals(RecognitionResult.NoMatch, r)
        assertTrue(pcm.released.get())
        assertTrue(pcm.reads.get() > 0)
    }

    @Test fun cancel_releases_mic() = runBlocking {
        val pcm = FakePcm()
        val job = async(Dispatchers.Default) { ShazamStreamDriver.run(FakeStream(null), pcm, timeoutMs = 60_000) }
        withTimeout(2_000) { while (!pcm.started.get()) delay(5) }
        job.cancel()
        job.join()
        withTimeout(2_000) { while (!pcm.released.get()) delay(5) }
        assertTrue(pcm.released.get())
    }

    @Test fun mic_read_failure_is_error() = runBlocking {
        val pcm = FakePcm().apply { failAfter = 1 }
        val r = ShazamStreamDriver.run(FakeStream(null), pcm, timeoutMs = 5_000)
        assertTrue(r is RecognitionResult.Error)
        assertTrue(pcm.released.get())
    }

    @Test fun timestamps_advance_by_audio_duration() {
        // 48 kHz mono PCM16 = 96000 bytes/s
        assertEquals(1000L, ShazamStreamDriver.durationMs(96_000, 48_000))
        assertEquals(20L, ShazamStreamDriver.durationMs(1920, 48_000))
        assertEquals(0L, ShazamStreamDriver.durationMs(0, 48_000))
    }

    @Test fun hit_info_blank_fields_become_null() {
        val i = hitInfoOf("  ", "A", null, "")
        assertEquals(null, i.title); assertEquals("A", i.artist); assertEquals(null, i.appleMusicId)
    }
}
