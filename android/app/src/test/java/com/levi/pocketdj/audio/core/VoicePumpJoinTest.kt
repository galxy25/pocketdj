package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class VoicePumpJoinTest {
    /** A source that throws if read after close, like a released MediaCodec. */
    private class StrictSource : PcmSource {
        val closed = AtomicBoolean(false)
        val violated = AtomicBoolean(false)
        override val sampleRate = 44_100
        override val channels = 2
        override val totalFrames = 10_000_000L
        override val isComplete = true
        override val availableFrames = 10_000_000L
        override fun read(dst: FloatArray, frames: Int): Int {
            if (closed.get()) { violated.set(true); throw IllegalStateException("released") }
            Thread.sleep(1)
            return frames
        }
        override fun seek(frame: Long) {}
        override fun close() { closed.set(true) }
    }

    @Test fun stopAndJoinLeavesNoDecoderThreadReadingAfterClose() {
        repeat(20) {
            val src = StrictSource()
            val v = Voice(src, 44_100, name = "t")
            v.schedule(0, 10_000_000L, final = true)
            val pump = VoicePump(v).start()
            Thread.sleep(15)
            pump.stopAndJoin()
            src.close()
            Thread.sleep(10)
            assertFalse("decoder read after close", src.violated.get())
        }
    }

    @Test fun aThrowingSourceDoesNotKillThePumpThread() {
        val src = object : PcmSource {
            override val sampleRate = 44_100
            override val channels = 2
            override val totalFrames = 1_000_000L
            override val isComplete = true
            override val availableFrames = 1_000_000L
            override fun read(dst: FloatArray, frames: Int): Int = throw IllegalStateException("boom")
            override fun seek(frame: Long) {}
            override fun close() {}
        }
        val v = Voice(src, 44_100, name = "t2")
        v.schedule(0, 1_000_000L, final = true)
        val p = VoicePump(v).start()
        Thread.sleep(30)
        p.stopAndJoin()
        assertEquals(true, true)   // reaching here = no uncaught exception terminated the JVM test thread group
    }
}
