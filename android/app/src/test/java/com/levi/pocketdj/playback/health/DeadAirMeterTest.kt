package com.levi.pocketdj.playback.health

import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeadAirMeterTest {
    private val utc = ZoneId.of("UTC")
    private fun at(y: Int, m: Int, d: Int, h: Int = 12, s: Int = 0): Long =
        ZonedDateTime.of(y, m, d, h, 0, s, 0, utc).toInstant().toEpochMilli()

    private val logs = mutableListOf<String>()
    private fun meter(file: File? = null) = DeadAirMeter(file = file, zone = { utc }, log = { logs += it }, nowMs = { T0 })

    private val T0 = at(2026, 10, 25)

    @Test
    fun advanceTransition_isKeyedFromArrowTo_andLogsTheIosGapLine() {
        val m = meter()
        m.trackStarting("burned") // no open transition: ignored
        m.firstAudio("burned", T0) // lastAudible = burned
        m.transitionBegan("advance", T0 + 1_000)
        m.trackStarting("rip")
        m.firstAudio(ms = T0 + 3_500)
        val d = m.day(T0)
        assertEquals(1, d.transitions)
        assertEquals(2.5, d.transitionGapSeconds, 1e-9)
        assertEquals(1, d.gapsOver1s)
        assertEquals(0, d.gapsOver3s)
        val p = d.byPair["burned→rip"]
        assertNotNull(p)
        assertEquals(1, p!!.n)
        assertEquals(2.5, p.max, 1e-9)
        assertEquals("gap=2.50s from=burned to=rip cause=advance", logs.last())
    }

    @Test
    fun nonAdvanceCause_isFoldedIntoThePairKey() {
        val m = meter()
        m.transitionBegan("skip", T0)
        m.trackStarting("burned")
        m.firstAudio(ms = T0 + 400)
        assertNotNull(m.day(T0).byPair["skip:none→burned"])
    }

    @Test
    fun aHopInsideAnOpenTransition_staysOneTransition_measuredFromTheOriginalStart() {
        val m = meter()
        m.transitionBegan("advance", T0)
        m.trackStarting("rip")
        m.transitionBegan("start", T0 + 6_000) // the hop re-enters playCurrent: must be a no-op
        m.trackStarting("burned")
        m.firstAudio(ms = T0 + 7_000)
        val d = m.day(T0)
        assertEquals(1, d.transitions)
        assertEquals(7.0, d.transitionGapSeconds, 1e-9)
        assertNotNull(d.byPair["none→burned"])
        assertEquals("gap=7.00s from=none to=burned cause=advance", logs.last())
    }

    @Test
    fun gapBuckets_areCumulativeAt1_3_10() {
        val m = meter()
        for (gap in listOf(0.5, 1.0, 3.0, 10.0)) {
            m.transitionBegan("advance", T0)
            m.trackStarting("rip")
            m.firstAudio(ms = T0 + (gap * 1000).toLong())
        }
        val d = m.day(T0)
        assertEquals(4, d.transitions)
        assertEquals(3, d.gapsOver1s)
        assertEquals(2, d.gapsOver3s)
        assertEquals(1, d.gapsOver10s)
        assertEquals(10.0, d.byPair["rip→rip"]!!.max, 1e-9)
    }

    @Test
    fun abandoned_dropsTheGapUnrecorded_andLogs() {
        val m = meter()
        m.transitionBegan("advance", T0)
        m.trackStarting("rip")
        m.transitionAbandoned("paused")
        assertFalse(m.hasOpenTransition)
        m.firstAudio(ms = T0 + 30_000)
        assertEquals(0, m.day(T0).transitions)
        assertEquals("abandoned cause=advance from=none reason=paused", logs.first())
    }

    @Test
    fun abandonedWithNothingOpen_isSilent() {
        val m = meter()
        m.transitionAbandoned("stop")
        assertTrue(logs.isEmpty())
    }

    @Test
    fun accumulate_splitsTransitionAndMidSongDeadAir() {
        val m = meter()
        m.accumulate(active = 10.0, dead = 4.0, transitionDead = 1.5, nowMs = T0)
        m.accumulate(active = 5.0, dead = 0.0, transitionDead = 0.0, nowMs = T0)
        val d = m.day(T0)
        assertEquals(15.0, d.activeSeconds, 1e-9)
        assertEquals(4.0, d.deadSeconds, 1e-9)
        assertEquals(1.5, d.transitionDeadSeconds, 1e-9)
        assertEquals(2.5, d.midSongDeadSeconds, 1e-9)
        assertEquals(4.0 / 15.0, d.deadRatio, 1e-9)
    }

    @Test
    fun accumulate_nothingActive_isIgnored() {
        val m = meter()
        m.accumulate(0.0, 0.0, 0.0, T0)
        assertTrue(m.document.days.isEmpty())
    }

    @Test
    fun daysRollOverAtLocalMidnight() {
        val m = meter()
        m.accumulate(1.0, 0.0, 0.0, at(2026, 10, 25, 23, 59))
        m.accumulate(2.0, 0.0, 0.0, at(2026, 10, 26, 0, 1))
        assertEquals(setOf("2026-10-25", "2026-10-26"), m.document.days.keys)
        assertEquals(1.0, m.day(at(2026, 10, 25)).activeSeconds, 1e-9)
        assertEquals(2.0, m.day(at(2026, 10, 26)).activeSeconds, 1e-9)
    }

    @Test
    fun summaryLine_isCharacterCompatibleWithIosAndTheReportScript() {
        val m = meter()
        m.accumulate(active = 600.0, dead = 19.0, transitionDead = 12.0, nowMs = T0)
        m.transitionBegan("advance", T0)
        m.trackStarting("rip")
        m.firstAudio(ms = T0 + 12_000)
        val line = m.summaryLine(T0)
        assertEquals(
            "day=2026-10-25 active=600s dead=19s ratio=3.17% transitionDead=12s midSongDead=7s transitions=1 gap≥3s=1 gap≥10s=1",
            line,
        )
        // The exact regex scripts/deadair-report.py parses.
        val re = Regex("day=(\\S+) active=(\\d+)s dead=(\\d+)s ratio=([\\d.]+)% transitionDead=(\\d+)s ")
        assertTrue(re.containsMatchIn(line))
    }

    @Test
    fun summaryIsLoggedEveryTenActiveMinutes() {
        val m = meter()
        m.accumulate(599.0, 0.0, 0.0, T0)
        assertTrue(logs.isEmpty())
        m.accumulate(2.0, 0.0, 0.0, T0)
        assertEquals(1, logs.size)
        assertTrue(logs[0].startsWith("day=2026-10-25 active=601s"))
    }

    @Test
    fun flush_logsTheSummaryOnlyWhenTheDayHadActivity() {
        val m = meter()
        m.flush(T0)
        assertTrue(logs.isEmpty())
        m.accumulate(3.0, 0.0, 0.0, T0)
        m.flush(T0)
        assertEquals(1, logs.size)
    }

    @Test
    fun persistedDocument_hasTheIosCodableShape_andRoundTrips() {
        val dir = createTempDir()
        try {
            val f = File(dir, DeadAirMeter.FILE_NAME)
            val m = meter(f)
            m.accumulate(60.0, 6.0, 4.0, T0)
            m.firstAudio("burned", T0)
            m.transitionBegan("advance", T0)
            m.trackStarting("rip")
            m.firstAudio(ms = T0 + 2_000)
            m.flush(T0)
            assertTrue(f.isFile)
            val root = Json.parseToJsonElement(f.readText()).jsonObject
            assertEquals(setOf("days"), root.keys)
            val day = root["days"]!!.jsonObject["2026-10-25"]!!.jsonObject
            assertEquals(
                setOf(
                    "activeSeconds", "deadSeconds", "transitionDeadSeconds", "midSongDeadSeconds", "transitions",
                    "transitionGapSeconds", "gapsOver1s", "gapsOver3s", "gapsOver10s", "byPair",
                ),
                day.keys,
            )
            val pair = day["byPair"]!!.jsonObject["burned→rip"]!!.jsonObject
            assertEquals(setOf("n", "seconds", "max"), pair.keys)
            assertEquals("1", pair["n"]!!.jsonPrimitive.content)

            val reloaded = DeadAirMeter(file = f, zone = { utc }, log = {}, nowMs = { T0 })
            assertEquals(m.document, reloaded.document)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun loadsADocumentWrittenByIos() {
        val dir = createTempDir()
        try {
            val f = File(dir, DeadAirMeter.FILE_NAME)
            f.writeText(
                """{"days":{"2026-10-24":{"activeSeconds":1200,"deadSeconds":293.5,"transitionDeadSeconds":280,"midSongDeadSeconds":13.5,
                "transitions":95,"transitionGapSeconds":280,"gapsOver1s":40,"gapsOver3s":12,"gapsOver10s":3,
                "byPair":{"appleMusic→burned":{"n":4,"seconds":74,"max":18.5}}}}}""",
            )
            val m = DeadAirMeter(file = f, zone = { utc }, log = {}, nowMs = { T0 })
            val d = m.day(at(2026, 10, 24))
            assertEquals(95, d.transitions)
            assertEquals(18.5, d.byPair["appleMusic→burned"]!!.max, 1e-9)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun corruptFile_startsFresh() {
        val dir = createTempDir()
        try {
            val f = File(dir, DeadAirMeter.FILE_NAME)
            f.writeText("{not json")
            assertTrue(DeadAirMeter(file = f, zone = { utc }, log = {}, nowMs = { T0 }).document.days.isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun prune_keepsSixtyDays() {
        val dir = createTempDir()
        try {
            val f = File(dir, DeadAirMeter.FILE_NAME)
            val m = meter(f)
            // 70 consecutive days ending 2026-10-25.
            val start = ZonedDateTime.of(2026, 10, 25, 12, 0, 0, 0, utc)
            for (back in 69 downTo 0) m.accumulate(1.0, 0.0, 0.0, start.minusDays(back.toLong()).toInstant().toEpochMilli())
            m.flush(T0)
            val onDisk = DeadAirMeter(file = f, zone = { utc }, log = {}, nowMs = { T0 }).document.days.keys.sorted()
            assertEquals(61, onDisk.size) // cutoff day inclusive: today - 60 d .. today
            assertEquals("2026-08-26", onDisk.first())
            assertEquals("2026-10-25", onDisk.last())
            assertNull(m.document.days["2026-08-25"])
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun saves_areThrottledTo30Seconds_untilFlush() {
        val dir = createTempDir()
        try {
            val f = File(dir, DeadAirMeter.FILE_NAME)
            val m = meter(f)
            m.accumulate(1.0, 0.0, 0.0, T0) // first write goes out
            val first = f.readText()
            m.accumulate(1.0, 0.0, 0.0, T0 + 10_000)
            assertEquals("inside the throttle window: not rewritten", first, f.readText())
            m.accumulate(1.0, 0.0, 0.0, T0 + 31_000)
            assertFalse(first == f.readText())
        } finally {
            dir.deleteRecursively()
        }
    }
}
