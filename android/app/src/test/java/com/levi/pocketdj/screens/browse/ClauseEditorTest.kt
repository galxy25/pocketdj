package com.levi.pocketdj.screens.browse

import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClauseEditorTest {
    @Test fun fieldChangeResetsOpAndValues() {
        val c = Clause("year", FilterOp.BETWEEN, value = "x", values = setOf("a"), min = 1.0, max = 2.0)
        val n = ClauseReducer.changeField(c, "genre")
        assertEquals("genre", n.field)
        assertEquals(Fields.byId.getValue("genre").ops.first(), n.op)
        assertEquals("", n.value); assertTrue(n.values.isEmpty()); assertNull(n.min); assertNull(n.max)
        assertEquals(c.id, n.id)
    }

    @Test fun fieldChangeToUnknownIsNoop() {
        val c = Clause("year", FilterOp.EQ, "1999")
        assertEquals(c, ClauseReducer.changeField(c, "nope"))
    }

    @Test fun opChangeKeepsValues() {
        val c = Clause("bpm", FilterOp.EQ, "120", values = setOf("a"), min = 1.0, max = 2.0)
        val n = ClauseReducer.changeOp(c, FilterOp.BETWEEN)
        assertEquals(FilterOp.BETWEEN, n.op)
        assertEquals(c.copy(op = FilterOp.BETWEEN), n)
        assertEquals("120", n.value)
        assertEquals(c, ClauseReducer.changeOp(n, FilterOp.EQ))
    }

    @Test fun opChangeToListKeepsSingleValue() {
        val back = ClauseReducer.changeOp(Clause("genre", FilterOp.EQ, "Rock"), FilterOp.NOT_IN_LIST)
        assertEquals("Rock", back.value)
    }

    @Test fun fieldChangeStillClearsValues() {
        val c = Clause("bpm", FilterOp.EQ, "120", values = setOf("a"))
        val n = ClauseReducer.changeField(c, "genre")
        assertEquals("", n.value); assertTrue(n.values.isEmpty())
    }

    @Test fun newClauseUsesFirstFieldAndOp() {
        val f = Fields.forKind(BrowseKind.SONGS)
        val c = ClauseReducer.newClause(f)!!
        assertEquals(f.first().id, c.field)
        assertEquals(f.first().ops.first(), c.op)
        assertTrue(c.isIncomplete)
    }

    @Test fun commaListParsing() {
        assertEquals(setOf("a", "b c"), ClauseReducer.parseCommaList(" a , b c,, "))
        assertEquals("a, b", ClauseReducer.formatCommaList(setOf("b", "a")))
    }

    @Test fun boundParsing() {
        assertEquals(120.0, ClauseReducer.parseBound(" 120 ")!!, 0.0)
        assertNull(ClauseReducer.parseBound(""))
        assertEquals("120", ClauseReducer.formatBound(120.0))
        assertEquals("1.5", ClauseReducer.formatBound(1.5))
    }

    @Test fun toggleValue() {
        val c = Clause("genre", FilterOp.IN_LIST)
        val on = ClauseReducer.toggleValue(c, "Rock")
        assertEquals(setOf("Rock"), on.values)
        assertTrue(ClauseReducer.toggleValue(on, "Rock").values.isEmpty())
    }

    @Test fun dayBoundsStartAndEndMinusOneMs() {
        val z = ZoneId.of("America/Los_Angeles")
        val day = LocalDate.of(2026, 8, 31)
        val s = ClauseReducer.startOfDayMs(day, z)
        val e = ClauseReducer.endOfDayMs(day, z)
        assertEquals(86_400_000.0 - 1.0, e - s, 0.0)
        assertEquals(LocalDate.of(2026, 9, 1).atStartOfDay(z).toInstant().toEpochMilli().toDouble() - 1.0, e, 0.0)
    }

    @Test fun dstDayIsNot24Hours() {
        val z = ZoneId.of("America/Los_Angeles")
        val day = LocalDate.of(2026, 3, 8) // spring forward
        val span = ClauseReducer.endOfDayMs(day, z) - ClauseReducer.startOfDayMs(day, z)
        assertEquals(23 * 3_600_000.0 - 1.0, span, 0.0)
    }

    @Test fun pickerDayUsesUtcCalendarDay() {
        val utcMidnight = LocalDate.of(2026, 8, 31).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()
        assertEquals(LocalDate.of(2026, 8, 31), ClauseReducer.pickerDay(utcMidnight))
    }

    @Test fun datePickersOnlyForDateFields() {
        assertTrue(ClauseReducer.usesDatePickers("lastPlayedAt"))
        assertTrue(ClauseReducer.usesDatePickers("dateAdded"))
        assertTrue(!ClauseReducer.usesDatePickers("bpm"))
    }
}
