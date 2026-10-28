package com.levi.pocketdj.mix.recording

import android.media.MediaExtractor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AacAdtsWriterInstrumentedTest {
    @Test fun encodeTwoSecondsTruncateStillDecodes() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(ctx.cacheDir, "adts-test.aac").also { it.delete() }
        val tap = RecordingTapSink(44_100 * 4)
        val w = AacAdtsWriter(file, tap)
        tap.setCapturing(true)
        w.start()
        val block = FloatArray(1024 * 2) { i -> kotlin.math.sin(i / 2 * 0.05).toFloat() * 0.5f }
        repeat(86) { tap.onHouse(block, 1024); Thread.sleep(5) }
        tap.setCapturing(false)
        w.stop()
        assertTrue("appended ~2 s", w.appendedSeconds > 1.5)
        // Simulate a kill mid-frame: chop the tail.
        val full = file.length()
        java.io.RandomAccessFile(file, "rw").use { it.setLength(full - 37) }
        val ex = MediaExtractor()
        ex.setDataSource(file.path)
        assertTrue(ex.trackCount >= 1)
        ex.selectTrack(0)
        var n = 0
        while (ex.sampleSize >= 0) { n++; if (!ex.advance()) break }
        assertTrue("decodable frames", n > 50)
        ex.release()
    }
}
