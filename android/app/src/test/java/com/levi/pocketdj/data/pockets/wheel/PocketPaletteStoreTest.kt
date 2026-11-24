package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.pockets.wheel.PocketPaletteStore.Entry
import com.levi.pocketdj.data.reset.AccountDeletionService
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.math.sqrt

/** Port of iOS PocketPaletteStoreTests (merge, normalize, free, byte-compat). */
class PocketPaletteStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private val day = 86_400_000.0
    private fun file() = File(tmp.root, "pocketdj-pocket-palette.json")

    @Test fun slotsAssignedInDominanceOrderAndNeverMove() {
        val s = PocketPaletteStore(file())
        assertTrue(s.assign(listOf("pot", "late", "fav"), nowMs = 1000.0))
        assertEquals(0, s.slot("pot")); assertEquals(1, s.slot("late")); assertEquals(2, s.slot("fav"))
        s.assign(listOf("road", "fav", "pot"), nowMs = 2000.0)
        assertEquals(0, s.slot("pot"))
        assertEquals("not dominant but not 30d unseen", 1, s.slot("late"))
        assertEquals(2, s.slot("fav")); assertEquals(3, s.slot("road"))
        val rev = s.revision
        assertFalse(s.assign(listOf("pot"), nowMs = 2000.0))
        assertEquals(rev, s.revision)
        assertEquals(3, PocketPaletteStore(file()).slot("road"))
    }

    @Test fun slotFreedThirtyDaysAfterDisappearing() {
        val s = PocketPaletteStore(file())
        s.assign(listOf("a", "b"), nowMs = 0.0)
        s.assign(listOf("a"), nowMs = 29 * day)
        assertEquals(1, s.slot("b"))
        s.assign(listOf("a", "c"), nowMs = 31 * day)
        assertNull(s.slot("b"))
        assertEquals("freed slot reused", 1, s.slot("c"))
        assertEquals(0, s.slot("a"))
        s.assign(emptyList(), deleted = setOf("a"), nowMs = 31 * day)
        assertNull(s.slot("a"))
    }

    @Test fun favSongsIsNeverFreed() {
        val s = PocketPaletteStore(file())
        s.assign(listOf("fav_songs", "x"), nowMs = 0.0)
        s.assign(listOf("x"), nowMs = 400 * day)
        assertEquals(0, s.slot("fav_songs"))
        s.assign(emptyList(), deleted = setOf("fav_songs"), nowMs = 401 * day)
        assertEquals(0, s.slot("fav_songs"))
    }

    @Test fun overflowBeyondTwelve() {
        val s = PocketPaletteStore(file())
        s.assign((0 until 14).map { "c$it" }, nowMs = 0.0)
        assertEquals(12, s.entries.size)
        assertNull(s.slot("c12"))
        val sw = s.swatch("c12") as PocketSwatch.Overflow
        assertEquals(PocketSwatch.overflowHue("c12"), sw.hue, 0.0)
        assertNotEquals(PocketSwatch.overflowHue("c12"), PocketSwatch.overflowHue("c13"), 0.0)
        assertTrue(sw.hue >= 0 && sw.hue < 360)
        assertTrue(sw.isHatched)
        assertEquals(PocketSwatch.Mixed, s.swatch(null))
        assertEquals(PocketSwatch.Slot(0), s.swatch("c0"))
    }

    @Test fun overflowHueMatchesSha256Prefix() {
        // sha256("abc") = ba7816bf... -> 0xba78 / 65536 * 360
        assertEquals(0xba78 / 65536.0 * 360, PocketSwatch.overflowHue("abc"), 1e-9)
    }

    @Test fun mergeIsConvergentEarlierWins() {
        val mine = mapOf("pot" to Entry(0, 100.0, 500.0), "late" to Entry(1, 200.0, 200.0))
        val theirs = mapOf("pot" to Entry(3, 50.0, 300.0), "fav" to Entry(1, 150.0, 150.0))
        val ab = PocketPaletteStore.merge(mine, theirs)
        val ba = PocketPaletteStore.merge(theirs, mine)
        assertEquals(ab, ba)
        assertEquals(3, ab["pot"]!!.slot)
        assertEquals(500.0, ab["pot"]!!.lastSeenMs, 0.0)
        assertEquals(1, ab["fav"]!!.slot)
        assertNotEquals(1, ab["late"]!!.slot)
        assertEquals(ab.size, ab.values.map { it.slot }.toSet().size)
        assertEquals(ab, PocketPaletteStore.merge(ab, ab))
    }

    @Test fun normalizedDropsOutOfRangeAndReseatsBumped() {
        val n = PocketPaletteStore.normalized(mapOf(
            "a" to Entry(5, 1.0, 1.0), "b" to Entry(5, 2.0, 2.0), "bad" to Entry(12, 0.0, 0.0), "neg" to Entry(-1, 0.0, 0.0)))
        assertEquals(setOf("a", "b"), n.keys)
        assertEquals(5, n["a"]!!.slot); assertEquals(0, n["b"]!!.slot)
    }

    @Test fun reloadFromDiskSavesOnlyWhenWeHoldMore() {
        val f = file()
        val s = PocketPaletteStore(f)
        s.assign(listOf("pot"), nowMs = 100.0)
        val peer = """{"schemaVersion":1,"entries":{"pot":{"slot":0,"assignedAtMs":100,"lastSeenMs":100},"late":{"slot":1,"assignedAtMs":120,"lastSeenMs":120}}}"""
        f.writeText(peer)
        assertFalse(s.reloadFromDisk())
        assertEquals(1, s.slot("late"))
        s.assign(listOf("pot", "late", "fav"), nowMs = 200.0)
        f.writeText(peer)
        assertTrue(s.reloadFromDisk())
        assertEquals(2, PocketPaletteStore(f).slot("fav"))
    }

    @Test fun lenientDecodePerEntry() {
        val f = file()
        f.writeText("""{"schemaVersion":1,"entries":{"good":{"slot":2,"assignedAtMs":1,"lastSeenMs":1},"bad":{"slot":"x"},"worse":7}}""")
        assertEquals(listOf("good"), PocketPaletteStore(f).entries.keys.toList())
        f.writeText("not json")
        assertTrue(PocketPaletteStore(f).entries.isEmpty())
    }

    @Test fun iosShapedJsonRoundTripsByteStableAndKeepsUnknownKeys() {
        val f = file()
        val ios = """{"schemaVersion":1,"entries":{"a":{"slot":0,"assignedAtMs":1000,"lastSeenMs":2000},"b":{"slot":4,"assignedAtMs":1500.5,"lastSeenMs":1500.5}}}"""
        f.writeText(ios)
        val s = PocketPaletteStore(f)
        s.assign(listOf("a"), nowMs = 2000.0) // no change
        assertEquals(PocketPaletteStore.encode(s.entries, emptyMap()), PocketPaletteStore.encode(PocketPaletteStore.decode(f)!!.entries, emptyMap()))
        assertTrue(PocketPaletteStore.encode(s.entries, emptyMap()).contains("\"assignedAtMs\":1000,"))
        assertTrue(PocketPaletteStore.encode(s.entries, emptyMap()).contains("1500.5"))
        // Unknown top-level key survives a re-write.
        f.writeText("""{"schemaVersion":1,"future":{"x":1},"entries":{"a":{"slot":0,"assignedAtMs":1,"lastSeenMs":1}}}""")
        val s2 = PocketPaletteStore(f)
        s2.assign(listOf("a", "z"), nowMs = 5.0)
        assertTrue(f.readText().contains("\"future\":{\"x\":1}"))
        assertTrue(f.readText().contains("\"z\""))
    }

    @Test fun clearRemovesFile() {
        val f = file()
        val s = PocketPaletteStore(f)
        s.assign(listOf("a"), nowMs = 1.0)
        assertTrue(f.exists())
        s.clear()
        assertFalse(f.exists()); assertTrue(s.entries.isEmpty())
    }

    @Test fun coloursDistinctAndOklchReproducesTable() {
        for (dark in listOf(true, false)) {
            val cs = (0 until 12).map { PocketSwatch.Slot(it).rgb(dark) }
            cs.forEach { assertTrue(listOf(it.first, it.second, it.third).all { v -> v in 0.0..1.0 }) }
            for (i in 0 until 11) {
                val a = cs[i]; val b = cs[i + 1]
                val d = sqrt((a.first - b.first).let { it * it } + (a.second - b.second).let { it * it } + (a.third - b.third).let { it * it })
                assertTrue("slots $i/${i + 1} too close", d > 0.25)
            }
        }
        val c = PocketSwatch.oklchToSRGB(0.72, 0.15, 25.0)
        assertEquals(0.9574, c.first, 0.001); assertEquals(0.4822, c.second, 0.001)
        assertEquals(0xFF000000.toInt() or (0xF4 shl 16) or (0x7B shl 8) or 0x74, PocketSwatch.Slot(0).argb(true))
    }

    @Test fun registeredForDeletion() {
        assertTrue("pocket-palette" in AccountDeletionService.cloudDocKeys)
        assertTrue("profile-source" in AccountDeletionService.cloudDocKeys)
    }

    @Test fun reloadFromDiskWithMissingOrCorruptFileKeepsStateAndDoesNotRewrite() {
        val f = file()
        val s = PocketPaletteStore(f)
        s.assign(listOf("a"), nowMs = 1000.0)
        f.delete()
        assertFalse(s.reloadFromDisk())
        assertFalse("must not recreate the file", f.exists())
        f.writeText("{ truncated")
        assertFalse(s.reloadFromDisk())
        assertEquals("{ truncated", f.readText())
        assertEquals(0, s.slot("a"))
    }

    private fun src(rel: String): String {
        val r = "app/src/main/java/com/levi/pocketdj/$rel"
        return listOf(File(r), File("android/$r"), File("../$r")).first { it.exists() }.readText()
    }

    @Test fun syncEntriesAreRegistered() {
        assertTrue(Regex("""SyncEntry\(\s*com\.levi\.pocketdj\.data\.pockets\.wheel\.PocketPaletteStore\.SYNC_KEY""")
            .containsMatchIn(src("di/ServicesGraph.kt")))
        assertEquals("pocket-palette", PocketPaletteStore.SYNC_KEY)
        assertTrue(src("di/StudioGraph.kt").contains("SyncEntry(\"profile-source\""))
    }
}
