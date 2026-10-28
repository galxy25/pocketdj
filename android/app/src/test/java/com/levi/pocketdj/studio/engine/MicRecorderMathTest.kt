package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class MicRecorderMathTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun clampedTickDt() {
        assertEquals(0.0, MicRecorderMath.clampedTickDt(10.0, null), 0.0)
        assertEquals(0.25, MicRecorderMath.clampedTickDt(10.25, 10.0), 1e-9)
        assertEquals(0.5, MicRecorderMath.clampedTickDt(100.0, 10.0), 0.0)       // suspension gap capped
        assertEquals(0.0, MicRecorderMath.clampedTickDt(9.0, 10.0), 0.0)         // clock went backwards
    }

    @Test fun nextStallAccum() {
        assertEquals(0.0, MicRecorderMath.nextStallAccum(3.0, 0.5, 1.0, -1.0), 0.0)     // first observation
        assertEquals(0.0, MicRecorderMath.nextStallAccum(3.0, 0.5, 1.5, 1.0), 0.0)     // media advanced
        assertEquals(3.5, MicRecorderMath.nextStallAccum(3.0, 0.5, 1.005, 1.0), 1e-9)  // <10 ms is noise
        assertEquals(3.5, MicRecorderMath.nextStallAccum(3.0, 0.5, 1.0, 1.0), 1e-9)
        // five seconds of frozen capture reaches the warn threshold
        var acc = 0.0
        repeat(11) { acc = MicRecorderMath.nextStallAccum(acc, 0.5, 2.0, 2.0) }
        assertTrue(acc >= MicRecorderMath.STALL_WARN_SECONDS)
    }

    @Test fun mintSampleFileSkipsTakenNames() {
        val ids = ArrayDeque(listOf("smp_a", "smp_b", "smp_c"))
        val (id, name) = MicRecorderMath.mintSampleFile({ it == "sample-smp_a.m4a" || it == "sample-smp_b.m4a" }, { ids.removeFirst() })
        assertEquals("smp_c", id)
        assertEquals(StudioFolders.fileName(StudioFamily.SAMPLES, "smp_c"), name)
    }

    @Test fun mintSampleFileIsBounded() {
        var n = 0
        val (id, _) = MicRecorderMath.mintSampleFile({ true }, { "smp_${n++}" })
        assertEquals(100, n)
        assertEquals("smp_99", id)
    }

    private val rawId = "smp_11111111-1111-1111-1111-111111111111"
    private val raw = StudioFolders.fileName(StudioFamily.SAMPLES, rawId)

    @Test fun adoptsRawUnknownCapture() {
        assertEquals(rawId, MicRecorderMath.adoptableSampleId(raw, emptySet(), null, false))
    }

    @Test fun neverAdoptsRenderCacheKnownOrLooseNames() {
        assertNull(MicRecorderMath.adoptableSampleId("sample-$rawId-r3.m4a", emptySet(), null, false))
        assertNull(MicRecorderMath.adoptableSampleId(raw, setOf(rawId), null, false))
        assertNull(MicRecorderMath.adoptableSampleId("sample-notanid.m4a", emptySet(), null, false))
        assertNull(MicRecorderMath.adoptableSampleId("random.m4a", emptySet(), null, false))
    }

    @Test fun activeTakeIsRootAware() {
        assertNull(MicRecorderMath.adoptableSampleId(raw, emptySet(), raw to false, false))   // same root: live take
        assertEquals(rawId, MicRecorderMath.adoptableSampleId(raw, emptySet(), raw to false, true)) // other root: genuine orphan
    }

    @Test fun peakAndSmoothing() {
        val b = byteArrayOf(0, 0, 0x00, 0x40, 0x00, 0xC0.toByte())   // 0, 16384, -16384
        assertEquals(0.5f, MicRecorderMath.peak16(b, 6), 1e-4f)
        assertEquals(0f, MicRecorderMath.peak16(b, 2), 0f)
        assertEquals(0.8f, MicRecorderMath.smoothLevel(0.2f, 0.8f), 0f)       // instant attack
        assertEquals(0.85f * 0.8f, MicRecorderMath.smoothLevel(0.8f, 0.1f), 1e-6f)
    }

    @Test fun wavTakeWriterIsRecoverableAfterKill() {
        val f = File(tmp.root, raw)
        val w = WavTakeWriter(f, 44100)
        val chunk = ByteArray(44100 * 2) { 1 }                      // 1 s
        repeat(3) { w.append(chunk, chunk.size) }                   // header patched along the way, never closed (a "kill")
        assertEquals(3000, WavTakeWriter.recoveredDurationMs(f))     // byte length wins over a stale header
        WavTakeWriter.repairHeader(f)
        val head = f.readBytes().copyOf(44)
        val data = (head[40].toInt() and 0xFF) or ((head[41].toInt() and 0xFF) shl 8) or ((head[42].toInt() and 0xFF) shl 16)
        assertEquals(44100 * 2 * 3, data)
        w.close()
    }

    @Test fun headerOnlyFileIsNotRecoverable() {
        val f = File(tmp.root, raw)
        WavTakeWriter(f, 44100).close()
        assertNull(WavTakeWriter.recoveredDurationMs(f))
        assertNull(WavTakeWriter.recoveredDurationMs(File(tmp.root, "missing.m4a")))
        f.writeBytes(ByteArray(100) { 7 })
        assertNull(WavTakeWriter.recoveredDurationMs(f))             // not RIFF
    }

    @Test fun micCaptureFlagGuardsPlayback() {
        AudioFocusPolicy.endMicCapture()
        assertTrue(AudioFocusPolicy.mayStartPlayback())
        AudioFocusPolicy.beginMicCapture()
        try {
            assertTrue(AudioFocusPolicy.micCaptureActive)
            assertFalse(AudioFocusPolicy.mayStartPlayback())
        } finally { AudioFocusPolicy.endMicCapture() }
        assertTrue(AudioFocusPolicy.mayStartPlayback())
    }
}
