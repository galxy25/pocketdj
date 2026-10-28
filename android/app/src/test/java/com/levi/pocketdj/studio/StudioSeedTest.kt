package com.levi.pocketdj.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class StudioSeedTest {
    @Test fun releaseBuildNeverSeeds() {
        assertEquals(StudioSeed.Request(false, false), StudioSeed.requested(false, true, true))
    }

    @Test fun debugBuildSeedsOnlyWhatTheExtrasAsk() {
        assertEquals(StudioSeed.Request(true, false), StudioSeed.requested(true, true, false))
        assertEquals(StudioSeed.Request(false, true), StudioSeed.requested(true, false, true))
        assertEquals(StudioSeed.Request(false, false), StudioSeed.requested(true, false, false))
    }

    @Test fun extrasMatchTheIosLaunchArgNames() {
        assertEquals("PDJ_SEED_STUDIO", StudioSeed.STUDIO_EXTRA)
        assertEquals("PDJ_SEED_DEMUX", StudioSeed.DEMUX_EXTRA)
    }

    @Test fun toneWavIsAOneSecondMono16BitRiff() {
        val b = StudioSeed.toneWav()
        assertEquals("RIFF", String(b, 0, 4))
        assertEquals("WAVE", String(b, 8, 4))
        assertEquals(44 + 44100 * 2, b.size)
        val bb = java.nio.ByteBuffer.wrap(b).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        assertEquals(1, bb.getShort(22).toInt())      // mono
        assertEquals(44100, bb.getInt(24))            // rate
        assertEquals(16, bb.getShort(34).toInt())     // bits
        var peak = 0
        for (i in 0 until 44100) peak = maxOf(peak, kotlin.math.abs(bb.getShort(44 + 2 * i).toInt()))
        assertTrue("audible tone, not silence", peak > 5000)
    }

    @Test fun bundledFixtureAssetIsAnMp4Container() {
        val f = listOf("src/main/assets", "app/src/main/assets").map { File(it, StudioSeed.FIXTURE_ASSET) }.first { it.isFile }
        val head = f.inputStream().use { it.readNBytes(12) }
        assertEquals("ftyp", String(head, 4, 4))
        assertTrue(f.length() in 1_000..200_000)
        assertFalse(StudioSeed.DEMUX_NAME.isBlank())
    }
}
