package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.StreamHandle
import com.levi.pocketdj.mix.engine.StreamSourceFactory
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.service.MixCard
import com.levi.pocketdj.mix.stream.GrowingFileSchedule.LengthClaim
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P2-MM-7: the Now Playing DSP plays a still-downloading file through the shared growing-file schedule.
 * A synthetic 12 s song at 32 000 B/s (frontier = bytes/32000 - 1.5 s) grows under an offline sink.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EngageStreamingTest {
    private val sr = 44_100
    private val songSec = 12
    private val bps = 32_000L
    private val expected = songSec * bps

    private class Factory(val sr: Int, songSec: Int) : StreamSourceFactory {
        var claim: LengthClaim = LengthClaim.FrameCount
        var opens = 0
        var completes = 0
        val src = SyntheticPcmSource(sr, 2, sr.toLong() * songSec, 0L) { f, _ ->
            (0.5 * Math.sin(2 * Math.PI * 220.0 * f / sr)).toFloat()
        }.also { it.forceIncomplete = true }
        override fun open(h: StreamHandle): PcmSource? { opens++; return src }
        override fun markComplete(src: PcmSource) { completes++; this.src.forceIncomplete = false }
        override fun lengthClaim(h: StreamHandle): LengthClaim = claim
    }

    private inner class Rig {
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        val factory = Factory(sr, songSec)
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = MixSourceOpener { null },
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = object : DspStemSource {
                override fun localParts(songId: String): Map<String, File> = emptyMap()
                override fun obtainable(songId: String) = false
                override suspend fun fetch(songId: String, parts: List<String>) = false
            },
            scope = scope, sampleRate = sr, growing = factory,
        )
        var ends = 0
        var failedAt: Double? = null
        var bytes = 0L
        init {
            engine.onReachedEnd = { ends++ }
            engine.onStreamFailed = { failedAt = it }
        }

        fun engage(at: Double = 0.0, play: Boolean = true, startBytes: Long = 0) =
            engine.engageStreaming(File("song.mp3"), expected, at, play, bytesReceived = startBytes.also { bytes = it })

        /** [sec] seconds of file audio have downloaded: bytes landed and the decoder can read them (torn-frame margin excluded by the schedule). */
        fun download(sec: Double, complete: Boolean = false) {
            bytes = if (complete) expected else (sec * bps).toLong()
            factory.src.available = if (complete) sr.toLong() * songSec else (sec * sr).toLong()
            engine.streamProgressed(bytes, complete)
        }

        fun pump() { var g = 0; do { var any = false; for (v in voices.toList()) while (v.pump()) any = true; g++ } while (any && g < 100) }

        fun render(frames: Int): FloatArray {
            val out = FloatArray(frames * 2)
            var done = 0
            while (done < frames) {
                pump()
                val n = minOf(512, frames - done)
                val b = sink!!.renderFrames(n)
                System.arraycopy(b, 0, out, done * 2, n * 2)
                done += n
                engine.tick()
            }
            return out
        }

        fun renderSec(sec: Double) = render((sec * sr).toInt())
        fun peak(b: FloatArray): Float = b.maxOf { kotlin.math.abs(it) }
    }

    @Test fun engagesImmediatelyHeldUnattachedUntilTheHeaderHasBytes() {
        val r = Rig()
        assertTrue(r.engage())
        assertTrue(r.engine.isEngaged)
        assertTrue(r.engine.isStreaming)
        assertTrue("play intent kept", r.engine.isPlaying)
        assertTrue("no bytes yet: holding", r.engine.isBuffering)
        assertEquals(0, r.factory.opens)
        assertEquals("provisional catalog length", 180.0, r.engine.durationSec, 0.01)
        val silent = r.renderSec(0.5)
        assertEquals(0f, r.peak(silent), 0f)
        assertEquals(0.0, r.engine.currentTimeSec, 0.0)
        assertFalse(r.engine.hasStarted)
    }

    @Test fun startsOnlyWithRunwayAndNeverSchedulesPastTheFrontier() {
        val r = Rig()
        r.engage()
        r.download(2.0)                       // frontier 0.5 s: under the 2 s start runway
        assertEquals(1, r.factory.opens)
        assertEquals("the header's window replaced the catalog guess", songSec.toDouble(), r.engine.durationSec, 0.01)
        assertTrue("still holding: no runway", r.engine.isBuffering)
        assertEquals(0f, r.peak(r.renderSec(0.3)), 0f)
        r.download(5.0)                       // frontier 3.5 s >= 2 s
        assertFalse("runway arrived: it starts", r.engine.isBuffering)
        val out = r.renderSec(1.0)
        assertTrue("audio flows", r.peak(out) > 0.1f)
        assertTrue(r.engine.hasStarted)
        // Run on past the frontier: the playhead freezes at it instead of running over silence.
        r.renderSec(6.0)
        assertTrue("held at the frontier with the intent kept", r.engine.isBuffering && r.engine.isPlaying)
        val held = r.engine.currentTimeSec
        assertTrue("held at <= frontier (3.5 s): $held", held <= 3.5 + 0.01 && held > 2.5)
        assertEquals("playhead is FROZEN while held", held, run { r.renderSec(2.0); r.engine.currentTimeSec }, 0.0)
        assertTrue("the voice was never allowed past the frontier", r.voices.single().playerFrame <= (3.5 * sr).toLong() + 512)
        assertEquals(0f, r.peak(r.renderSec(0.5)), 1e-4f)
    }

    @Test fun aHoldNeedsTheBiggerResumeRunwayThenContinuesWhereItStopped() {
        val r = Rig()
        r.engage(); r.download(6.0)
        r.renderSec(8.0)                      // caught the 4.5 s frontier
        assertTrue(r.engine.isBuffering)
        val held = r.engine.currentTimeSec
        r.download(8.0)                       // frontier 6.5 s: only ~2 s past the playhead (< 4 s resume runway)
        assertTrue("resume needs 4 s, not 2", r.engine.isBuffering)
        r.download(10.0)                      // frontier 8.5 s: 4 s+ of runway
        assertFalse(r.engine.isBuffering)
        val out = r.renderSec(1.0)
        assertTrue(r.peak(out) > 0.1f)
        assertTrue("continues from the held position, not 0:00", r.engine.currentTimeSec in held..(held + 1.2))
    }

    @Test fun completionPlaysOutAndEndsOnceAndBecomesAnOrdinaryFile() {
        val r = Rig()
        r.engage(); r.download(5.0)
        r.renderSec(1.0)
        r.download(12.0, complete = true)
        assertEquals("the decoder drained every byte", 1, r.factory.completes)
        r.renderSec(12.0)
        assertEquals("ended once", 1, r.ends)
        assertFalse("no hold / streaming left", r.engine.isBuffering)
        assertFalse(r.engine.isStreaming)
    }

    @Test fun aHeaderlessMp3IsNeverAttachedOnAPartialLengthEstimate() {
        val r = Rig()
        r.factory.claim = LengthClaim.Absent
        r.engage(); r.download(9.0)           // plenty of bytes: still no verdict on the length
        assertEquals("never opened", 0, r.factory.opens)
        assertTrue(r.engine.isEngaged && r.engine.isBuffering)
        assertEquals(0f, r.peak(r.renderSec(1.0)), 0f)
        r.factory.claim = LengthClaim.Tlen(12_000)      // a TLEN is not trusted either
        r.download(10.0)
        assertEquals(0, r.factory.opens)
        r.download(12.0, complete = true)     // complete: the file is its own length
        assertEquals(1, r.factory.opens)
        assertFalse(r.engine.isBuffering)
        assertTrue(r.peak(r.renderSec(1.0)) > 0.1f)
    }

    @Test fun anUndecidedClaimRetriesOnTheNextProgressEvent() {
        val r = Rig()
        r.factory.claim = LengthClaim.Undetermined
        r.engage(); r.download(3.0)
        assertEquals(0, r.factory.opens)
        r.factory.claim = LengthClaim.FrameCount
        r.download(5.0)
        assertEquals(1, r.factory.opens)
        assertEquals(songSec.toDouble(), r.engine.durationSec, 0.01)
    }

    @Test fun anImplausibleDeclaredLengthIsHeldUnattachedToo() {
        val r = Rig()
        // 12 s of audio claiming a 2 MB file: 170 KB/s is above any mp3 bitrate - the length is not the song's.
        val bigExpected = 2_000_000L
        assertTrue(r.engine.engageStreaming(File("s.mp3"), bigExpected, 0.0, true, bytesReceived = 100_000))
        r.factory.src.available = sr * 10L
        r.engine.streamProgressed(100_000)
        assertTrue("opened to learn the length, then released unattached", r.engine.isBuffering)
        assertEquals(0f, r.peak(r.renderSec(0.5)), 0f)
    }

    @Test fun aDeadStreamBeforeAnyAudioHandsTheRowBack() {
        val r = Rig()
        r.engage(at = 3.0)
        r.engine.streamProgressed(0, failed = true)
        assertFalse(r.engine.isEngaged)
        assertEquals(3.0, r.failedAt!!, 0.0)
    }

    @Test fun aDeadStreamMidSongKeepsWhatArrivedAndEndsThere() {
        val r = Rig()
        r.engage(); r.download(5.0)
        r.renderSec(1.0)
        r.engine.streamProgressed(r.bytes, failed = true)
        assertFalse("truncated: no longer waiting for bytes", r.engine.isBuffering)
        r.renderSec(8.0)
        assertEquals("the bytes we have ARE the song: it ends at the frontier", 1, r.ends)
        assertNull("no stream-failed hand-back mid-song", r.failedAt)
    }

    @Test fun seekingPastTheFrontierHoldsAtTheTargetAndResumesThere() {
        val r = Rig()
        r.engage(); r.download(5.0)
        r.renderSec(0.5)
        r.engine.seekTo(9.0)
        assertTrue(r.engine.isBuffering)
        assertEquals("held AT the target, never at the frontier or 0:00", 9.0, r.engine.currentTimeSec, 0.01)
        r.renderSec(0.3)                      // the stretcher's tail drains
        assertEquals(0f, r.peak(r.renderSec(0.5)), 1e-4f)
        r.download(11.0)                      // frontier 9.5 s: 0.5 s past the target < 4 s
        assertTrue(r.engine.isBuffering)
        r.download(12.0, complete = true)
        assertFalse(r.engine.isBuffering)
        assertTrue(r.peak(r.renderSec(0.5)) > 0.1f)
        assertTrue(r.engine.currentTimeSec in 9.0..10.0)
    }

    @Test fun pausingWhileHeldDropsBufferingAndPlayRaisesItAgain() {
        val r = Rig()
        r.engage()
        assertTrue(r.engine.isBuffering)
        r.engine.pause()
        assertFalse(r.engine.isBuffering)
        assertFalse(r.engine.isPlaying)
        r.download(5.0)
        assertEquals("a paused engage does not start by itself", 0f, r.peak(r.renderSec(0.3)), 0f)
        r.engine.play()
        assertFalse("runway is there: plays at once", r.engine.isBuffering)
        assertTrue(r.peak(r.renderSec(0.5)) > 0.1f)
    }

    @Test fun disengageWhileStreamingReleasesTheSourceAndReportsTheHeldPosition() {
        val r = Rig()
        r.engage(at = 2.5)
        assertEquals(2.5, r.engine.disengage()!!, 0.0)
        assertFalse(r.engine.isEngaged)
        assertFalse(r.engine.isStreaming)
        r.engine.streamProgressed(1000)        // a stale loader event after the release is ignored
        assertFalse(r.engine.isEngaged)
    }

    @Test fun theSessionCardReportsBufferingWhileHeldWithAFrozenPosition() {
        val card = MixCard("s", "T", "A", null, 12_000, 3_500, 1f)
        assertNull(npCardFor(null, true))
        assertSame("not buffering: untouched", card, npCardFor(card, false))
        val held = npCardFor(card, true)!!
        assertTrue(held.held)
        assertEquals(3_500, held.positionMs)
        assertNotNull(com.levi.pocketdj.mix.service.MixPlayerStateMap.model(held, true, true).takeIf {
            it.playbackState == androidx.media3.common.Player.STATE_BUFFERING && it.playWhenReady
        })
    }
}
