package com.levi.pocketdj.playback.sequencer

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnedLocalFileTest {
    private val f = File("/data/burns/a b.mp3")

    @Test fun digitalFilePlaysWhole() {
        val lf = burnedLocalFile(f, isCut = false, startMs = null, durationMs = 20_000)
        assertNull(lf.startMs); assertNull(lf.endMs)
        assertTrue(lf.url.startsWith("file:/"))
    }

    @Test fun analogSharedFileGetsWindow() {
        val lf = burnedLocalFile(f, isCut = false, startMs = 60_000, durationMs = 30_000)
        assertEquals(60_000L, lf.startMs); assertEquals(90_000L, lf.endMs)
    }

    @Test fun cutIgnoresStart() {
        val lf = burnedLocalFile(f, isCut = true, startMs = 60_000, durationMs = 30_000)
        assertNull(lf.startMs); assertNull(lf.endMs)
    }
}
