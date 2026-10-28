package com.levi.pocketdj.data.stats

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayStarted
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayStatsStoreTest {
    private fun file() = File(Files.createTempDirectory("pdj-stats").toFile(), PlayStatsStore.FILE_NAME)

    @Test fun twoPlaysTenSecondsApartCountOnceButRefreshLastPlayed() {
        val s = PlayStatsStore(file(), nowMs = 0)
        s.notePlayed("sng_a", 1_000_000)
        s.notePlayed("sng_a", 1_010_000)
        assertEquals(1, s.playCount("sng_a"))
        assertEquals(1_010_000.0, s.lastPlayedAt("sng_a")!!, 0.0)
        s.notePlayed("sng_a", 1_040_000) // 30 s after the last stamp => a new listen
        assertEquals(2, s.playCount("sng_a"))
    }

    @Test fun anOlderTimestampNeverMovesLastPlayedBackwards() {
        val s = PlayStatsStore(file(), nowMs = 0)
        s.notePlayed("a", 5_000_000)
        s.notePlayed("a", 1_000_000)
        assertEquals(5_000_000.0, s.lastPlayedAt("a")!!, 0.0)
    }

    @Test fun appleCountTagsOnlyCountedPlaysAndNewRowsCarryPreTagZero() {
        val s = PlayStatsStore(file(), nowMs = 0)
        s.notePlayed("a", 100_000, appleCounted = true)
        s.notePlayed("a", 200_000, appleCounted = false)
        s.notePlayed("a", 300_000, appleCounted = true)
        val st = s.stat("a")!!
        assertEquals(3, st.playCount); assertEquals(2, st.appleCount); assertEquals(0, st.preTagPlayCount)
        assertEquals(1, s.nonApplePlayCount("a"))
        s.notePlayed("b", 100_000)
        assertNull(s.stat("b")!!.appleCount)
    }

    @Test fun iosFixtureDecodesAndMigrationStampsLegacyRowsOnce() {
        val f = file()
        f.writeText("""{"schemaVersion":1,"stats":{"sng_old":{"playCount":7,"lastPlayedAt":1700000000000.0,"appleCount":2},
            "sng_new":{"playCount":1,"lastPlayedAt":5.0,"preTagPlayCount":0,"skipCount":3}}}""")
        val s = PlayStatsStore(f, nowMs = 42)
        assertEquals(7, s.stat("sng_old")!!.preTagPlayCount)          // legacy row stamped with its count
        assertEquals(0, s.stat("sng_new")!!.preTagPlayCount)          // tagged row untouched
        assertEquals(3, s.skipCount("sng_new"))
        assertEquals(42.0, s.appleTaggingMigratedAtMs!!, 0.0)
        // legacy plays are untrusted when Apple knows the song: 7 - 2 apple - 7 untrusted => 0
        assertEquals(0, s.nonApplePlayCount("sng_old", appleKnowsSong = true))
        assertEquals(5, s.nonApplePlayCount("sng_old", appleKnowsSong = false))
        // second launch must not re-stamp
        val again = PlayStatsStore(f, nowMs = 99_999)
        assertEquals(42.0, again.appleTaggingMigratedAtMs!!, 0.0)
    }

    @Test fun savedDocUsesIosShapeAndRoundTrips() {
        val f = file()
        PlayStatsStore(f, nowMs = 10).apply { notePlayed("sng_x", 123_456, appleCounted = true) }
        val text = f.readText()
        assertTrue(text, text.contains("\"schemaVersion\":1"))
        assertTrue(text, text.contains("\"stats\""))
        assertTrue(text, text.contains("\"appleTaggingMigratedAtMs\""))
        val back = PlayStatsStore(f, nowMs = 0)
        assertEquals(1, back.playCount("sng_x")); assertEquals(1, back.stat("sng_x")!!.appleCount)
    }

    @Test fun reloadReplacesMapBumpsRevisionAndKeepsOlderMigrationMark() {
        val f = file()
        val s = PlayStatsStore(f, nowMs = 100)
        s.notePlayed("local", 1_000_000)
        val rev = s.revision.value
        f.writeText("""{"schemaVersion":1,"stats":{"cloud":{"playCount":4,"lastPlayedAt":9.0,"preTagPlayCount":0}},"appleTaggingMigratedAtMs":50.0}""")
        s.reloadFromDisk(nowMs = 500)
        assertTrue(s.revision.value > rev)
        assertEquals(0, s.playCount("local"))
        assertEquals(4, s.playCount("cloud"))
        assertEquals(50.0, s.appleTaggingMigratedAtMs!!, 0.0)
    }

    @Test fun clearWipesMemoryAndDiskAndBumpsRevision() {
        val f = file()
        val s = PlayStatsStore(f, nowMs = 0)
        s.notePlayed("a", 1)
        val rev = s.revision.value
        s.clear()
        assertTrue(s.revision.value > rev); assertEquals(0, s.playCount("a")); assertFalse(f.exists())
    }

    @Test fun peerPlayExtendsLastPlayedWithoutCounting() {
        val s = PlayStatsStore(file(), nowMs = 0)
        s.peerLastPlayedAt = { if (it == "a") 9_000.0 else null }
        assertEquals(9_000.0, s.lastPlayedAt("a")!!, 0.0)       // never local, peer only
        s.notePlayed("a", 20_000)
        assertEquals(20_000.0, s.lastPlayedAt("a")!!, 0.0)
        assertEquals(1, s.playCount("a"))
        assertNull(s.lastPlayedAt("zzz"))
    }

    @Test fun skipsAreCumulativeAndSnapshotted() {
        val s = PlayStatsStore(file(), nowMs = 0)
        s.noteSkipped("a"); s.noteSkipped("a")
        assertEquals(2, s.skipCount("a"))
        assertEquals(0, s.playCount("a"))
        assertEquals(mapOf("a" to 2), s.skipCountsSnapshot())
    }

    @Test fun recorderCountsStartsAndTagsAppleFromTheEventNotTheLiveBackend() {
        val s = PlayStatsStore(file(), nowMs = 0)
        val r = PlayStatsRecorder(s)
        r.onStarted(PlayStarted("a", null, null, PlayContext.BROWSER, 1_000_000, appleCounted = true))
        r.onStarted(PlayStarted("b", null, null, PlayContext.BROWSER, 1_000_000))
        r.onStarted(PlayStarted("sng_0123456789ab_clean", null, null, PlayContext.BROWSER, 1_000_000))
        assertEquals(1, s.stat("a")!!.appleCount); assertNull(s.stat("b")!!.appleCount)
        assertNotNull("variant plays are recorded against the base id", s.lastPlayedAt("sng_0123456789ab"))
    }

    @Test fun mixDeckPlayUpdatesLastPlayedAtUnderTheBaseId() {
        val s = PlayStatsStore(file(), nowMs = 0)
        val hooks = com.levi.pocketdj.mix.engine.MixRecordingHooks()
        PlayStatsRecorder.attachMix(hooks) { s.notePlayed(it, 2_000_000) }
        assertNull(s.lastPlayedAt("sng_0123456789ab"))
        hooks.notePlay(com.levi.pocketdj.mix.model.Deck.A, "sng_0123456789ab_clean")
        assertEquals(2_000_000.0, s.lastPlayedAt("sng_0123456789ab")!!, 0.0)
    }
}
