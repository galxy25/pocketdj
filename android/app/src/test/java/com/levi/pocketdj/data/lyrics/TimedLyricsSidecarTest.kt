package com.levi.pocketdj.data.lyrics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimedLyricsSidecarTest {
    // Shape produced by scripts/stem-worker.mjs: {version, model, lang, durationMs, words}
    private val fixture = """{"version":1,"model":"large-v3","lang":"en","durationMs":215000,
      "words":[{"text":"hello","startMs":1000,"endMs":1400},{"text":"world","startMs":1500,"endMs":1900},
               {"text":"again","startMs":4000,"endMs":4400}]}"""

    @Test fun decodesIosFixture() {
        val d = TimedLyricsSidecar.decode(fixture)!!
        assertEquals(1, d.version); assertEquals("large-v3", d.model); assertEquals("en", d.lang)
        assertEquals(215000L, d.durationMs)
        assertEquals(TimedWord("hello", 1000, 1400), d.words[0])
        assertEquals(3, d.words.size)
    }

    @Test fun malformedWordsAreDroppedNotFatal() {
        val d = TimedLyricsSidecar.decode(
            """{"words":[{"text":"ok","startMs":0,"endMs":10},{"text":"nostart","endMs":5},
            {"text":"","startMs":1,"endMs":2},{"text":"str","startMs":"1","endMs":2},
            {"text":"backwards","startMs":9,"endMs":3},"junk",null,{"text":"neg","startMs":-1,"endMs":2},
            {"text":"two","startMs":20,"endMs":30.0}]}""",
        )!!
        assertEquals(listOf("ok", "two"), d.words.map { it.text })
        assertNull(d.version)
    }

    @Test fun docLevelFailuresReturnNull() {
        assertNull(TimedLyricsSidecar.decode("not json"))
        assertNull(TimedLyricsSidecar.decode("[1,2]"))
        assertNull(TimedLyricsSidecar.decode("""{"words":"x"}"""))
        assertNull(TimedLyricsSidecar.decode("""{"model":"m"}"""))
    }

    @Test fun linesBreakOnGapAndWordCap() {
        val d = TimedLyricsSidecar.decode(fixture)!!
        assertEquals(listOf("hello world", "again"), d.lines().map { it.text })
        assertEquals("hello world\nagain", TimedLyricsSidecar.plainText(d))
        val many = (0 until 25).map { TimedWord("w$it", it * 100L, it * 100L + 50) }
        assertEquals(listOf(12, 12, 1), TimedLyricsSidecar.lines(many).map { it.words.size })
        assertEquals(emptyList<TimedLine>(), TimedLyricsSidecar.lines(emptyList()))
    }

    @Test fun gapExactlyAtThresholdBreaks() {
        val w = listOf(TimedWord("a", 0, 100), TimedWord("b", 1300, 1400))
        assertEquals(2, TimedLyricsSidecar.lines(w).size) // 1300-100 = 1200 >= gap
        assertEquals(1, TimedLyricsSidecar.lines(listOf(w[0], TimedWord("b", 1299, 1400))).size)
    }
}
