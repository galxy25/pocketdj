package com.levi.pocketdj.data.burns

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BurnStemsTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun touch(dir: File, name: String) = File(dir, name).also { it.writeText("x") }

    @Test fun resolutionIsAllOrNothing() {
        val d = tmp.newFolder()
        listOf("vocals", "drums", "bass").forEach { touch(d, "stem-s1-$it.mp3") }
        assertNull(BurnStems.resolveAll(d, "s1"))
        assertFalse(BurnStems.allPresent(d, "s1"))
        assertEquals(setOf("vocals", "drums", "bass"), BurnStems.resolveParts(d, "s1")?.keys)
        assertEquals(listOf("other"), BurnStems.missingParts(d, "s1"))
        touch(d, "stem-s1-other.mp3")
        assertEquals(listOf("vocals", "drums", "bass", "other"), BurnStems.resolveAll(d, "s1")?.keys?.toList())
        assertTrue(BurnStems.missingParts(d, "s1").isEmpty()) // idempotent: nothing to download
        assertNull(BurnStems.resolveParts(d, "nope"))
    }

    @Test fun beatGridValidationRejectsTruncatedAndHtml() {
        assertTrue(BurnStems.isValidBeatGrid("""{"beatGridBpm":120.0,"beatsMs":[0,500],"unknown":1}""".toByteArray()))
        assertTrue(BurnStems.isValidBeatGrid("{}".toByteArray()))
        assertFalse(BurnStems.isValidBeatGrid("""{"beatGridBpm":120.0,"beatsMs":[0,5""".toByteArray()))
        assertFalse(BurnStems.isValidBeatGrid("<html>502 Bad Gateway</html>".toByteArray()))
        assertFalse(BurnStems.isValidBeatGrid(ByteArray(0)))
    }

    @Test fun removeAuxDeletesStemsAndGridOnlyForThatSong() {
        val d = tmp.newFolder()
        BurnFileNames.STEM_NAMES.forEach { touch(d, "stem-s1-$it.mp3"); touch(d, "stem-s2-$it.mp3") }
        touch(d, "analysis-s1.json"); touch(d, "analysis-s2.json")
        assertEquals(5, BurnStems.removeAux(d, "s1"))
        assertEquals(5, d.list()!!.size)
        assertTrue(d.list()!!.none { it.contains("s1") })
        assertEquals(0, BurnStems.removeAux(d, "s1"))
    }

    @Test fun auxFileSongIdParsing() {
        assertEquals("alb_1", BurnFileNames.auxFileSongId("stem-alb_1-vocals.mp3"))
        assertEquals("a-b", BurnFileNames.auxFileSongId("stem-a-b-other.mp3")) // ids may contain '-'
        assertEquals("s9", BurnFileNames.auxFileSongId("analysis-s9.json"))
        assertNull(BurnFileNames.auxFileSongId("stem-s1-guitar.mp3"))
        assertNull(BurnFileNames.auxFileSongId("stem--vocals.mp3"))
        assertNull(BurnFileNames.auxFileSongId("Artist-Song-s1.mp3"))
        assertNull(BurnFileNames.auxFileSongId("analysis-s1.mp3"))
        assertTrue(BurnFileNames.isStemFile("stem-s1-drums.mp3")); assertFalse(BurnFileNames.isStemFile("analysis-s1.json"))
    }

    @Test fun orphanSweepSelectsAuxFilesWithoutBurnedAudio() {
        val names = listOf("Artist-Song-s1.mp3", "stem-s1-vocals.mp3", "stem-s2-vocals.mp3", "analysis-s2.json", "notes.txt")
        val burned = setOf("s1")
        assertEquals(listOf("stem-s2-vocals.mp3", "analysis-s2.json"), BurnStems.auxToSweep(names) { it !in burned })
    }

    @Test fun fullyStemmedIdsNeedAllFourParts() {
        val names = BurnFileNames.STEM_NAMES.map { "stem-a-$it.mp3" } + listOf("stem-b-vocals.mp3", "stem-b-drums.mp3")
        assertEquals(listOf("a"), BurnStems.fullyStemmedIds(names))
    }
}
