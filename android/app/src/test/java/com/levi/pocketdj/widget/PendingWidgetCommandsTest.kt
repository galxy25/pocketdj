package com.levi.pocketdj.widget

import com.levi.pocketdj.widget.WidgetCommand.Kind
import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

class PendingWidgetCommandsTest {
    private var now = 1_000_000L
    private fun q(): PendingWidgetCommands {
        val f = File.createTempFile("pwc", ".json").also { it.delete(); it.deleteOnExit() }
        return PendingWidgetCommands(f) { now }
    }

    @Test fun drainsInEnqueueOrderAndEmpties() {
        val p = q()
        p.enqueue(WidgetCommand(Kind.FAVORITE, songId = "a", value = "1"))
        p.enqueue(WidgetCommand(Kind.NEXT))
        p.enqueue(WidgetCommand(Kind.SHUFFLE, value = "1"))
        assertEquals(listOf(Kind.FAVORITE, Kind.NEXT, Kind.SHUFFLE), p.drain().map { it.kind })
        assertTrue(p.drain().isEmpty())
    }

    @Test fun transportExpiresAfter20sButFavoriteAndVerdictsNever() {
        val p = q()
        p.enqueue(WidgetCommand(Kind.NEXT))
        p.enqueue(WidgetCommand(Kind.FAVORITE, songId = "a"))
        p.enqueue(WidgetCommand(Kind.VERDICT_REJECT, songId = "a"))
        now += 20_001
        assertEquals(listOf(Kind.FAVORITE, Kind.VERDICT_REJECT), p.drain().map { it.kind })
    }

    @Test fun transportAtExactlyTtlSurvives() {
        val p = q()
        p.enqueue(WidgetCommand(Kind.NEXT))
        now += 20_000
        assertEquals(1, p.drain().size)
    }

    @Test fun capTrimsOldest() {
        val p = q()
        repeat(40) { p.enqueue(WidgetCommand(Kind.FAVORITE, songId = "s$it")) }
        assertEquals(32, p.size())
        val d = p.drain()
        assertEquals("s8", d.first().songId)
        assertEquals("s39", d.last().songId)
    }

    @Test fun favoriteKeepsTheSongTheUserSaw() {
        val p = q()
        p.enqueue(WidgetCommand(Kind.FAVORITE, songId = "seen", appleMusicId = "42", value = "1"))
        val c = p.drain().single()
        assertEquals("seen", c.songId); assertEquals("42", c.appleMusicId); assertEquals("1", c.value)
    }

    @Test fun corruptFileIsEmptyAndRecovers() {
        val f = File.createTempFile("pwc", ".json").also { it.deleteOnExit() }
        f.writeText("]]garbage")
        val p = PendingWidgetCommands(f) { now }
        assertEquals(0, p.size())
        p.enqueue(WidgetCommand(Kind.FAVORITE, songId = "a"))
        assertEquals(1, p.drain().size)
    }
}
