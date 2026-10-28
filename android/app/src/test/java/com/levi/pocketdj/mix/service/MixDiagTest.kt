package com.levi.pocketdj.mix.service

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files

class MixDiagTest {
    private val forwarded = mutableListOf<String>()

    @Before fun setUp() { MixDiag.clear(); MixDiag.forward = { forwarded += it }; MixDiag.clock = { 1_700_000_000_000L } }
    @After fun tearDown() { MixDiag.clear() }

    @Test fun logStampsRingsAndForwards() {
        MixDiag.log("hb render=1 tapAge=0.01 sigAge=0.02")
        assertEquals(listOf("hb render=1 tapAge=0.01 sigAge=0.02"), forwarded)
        assertTrue(MixDiag.snapshot().single().contains("[mix] hb render=1"))
    }

    @Test fun ringIsBounded() {
        repeat(MixDiag.CAPACITY + 50) { MixDiag.log("l$it") }
        val s = MixDiag.snapshot()
        assertEquals(MixDiag.CAPACITY, s.size)
        assertTrue(s.first().endsWith("l50"))
        assertTrue(s.last().endsWith("l${MixDiag.CAPACITY + 49}"))
    }

    @Test fun exportWritesATextFileWithHeaderAndLines() {
        MixDiag.log("recover: sink restarted stall=40ms")
        val dir = Files.createTempDirectory("mixdiag").toFile()
        val f = MixDiag.export(dir, "A:x play=true")
        assertTrue(f.name.startsWith("mixdiag-") && f.name.endsWith(".txt"))
        val t = f.readText()
        assertTrue(t.startsWith("PocketDJ mix diag - 1 lines"))
        assertTrue(t.contains("A:x play=true"))
        assertTrue(t.contains("recover: sink restarted"))
        dir.deleteRecursively()
    }
}
