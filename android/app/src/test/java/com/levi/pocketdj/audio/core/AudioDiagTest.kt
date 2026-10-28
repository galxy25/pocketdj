package com.levi.pocketdj.audio.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AudioDiagTest {
    private val lines = mutableListOf<String>()
    @Before fun setUp() { AudioDiag.reset(); lines.clear(); AudioDiag.emit = { lines += it } }
    @After fun tearDown() { AudioDiag.emit = { com.levi.pocketdj.diag.NPLog.lane(com.levi.pocketdj.diag.NPLog.MIX, it) }; AudioDiag.reset() }

    @Test fun playAndStopExitsAreReasonTaggedAndCounted() {
        AudioDiag.play("deckA", "engine-stopped", started = false)
        AudioDiag.play("deckA", "ok", started = true, detail = "at=1234")
        AudioDiag.stop("deckA", "route-change")
        assertEquals("audio.play.skip owner=deckA reason=engine-stopped", lines[0])
        assertEquals("audio.play owner=deckA reason=ok at=1234", lines[1])
        assertEquals("audio.stop owner=deckA reason=route-change", lines[2])
        assertEquals(1, AudioDiag.count("play.skip", "engine-stopped"))
        assertEquals(0, AudioDiag.count("play", "engine-stopped"))
        assertTrue(AudioDiag.snapshot().keys.contains("stop/route-change"))
    }
}
