package com.levi.pocketdj.studio.midi

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SmfRoundTripTest {
    private fun ev(on: Int, off: Int, note: Int, vel: Int = 100) = StudioNoteEvent(on, off, note, vel)
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    // ---- writer: the iOS hand-decoded fixtures, byte for byte
    @Test fun vlqReferenceVectors() {
        assertArrayEquals(bytes(0x00), SmfWriter.vlq(0))
        assertArrayEquals(bytes(0x40), SmfWriter.vlq(0x40))
        assertArrayEquals(bytes(0x7F), SmfWriter.vlq(0x7F))
        assertArrayEquals(bytes(0x81, 0x00), SmfWriter.vlq(0x80))
        assertArrayEquals(bytes(0xC0, 0x00), SmfWriter.vlq(0x2000))
        assertArrayEquals(bytes(0xFF, 0x7F), SmfWriter.vlq(0x3FFF))
        assertArrayEquals(bytes(0x81, 0x80, 0x00), SmfWriter.vlq(0x4000))
        assertArrayEquals(bytes(0xFF, 0xFF, 0x7F), SmfWriter.vlq(0x1FFFFF))
        assertArrayEquals(bytes(0xFF, 0xFF, 0xFF, 0x7F), SmfWriter.vlq(0x0FFFFFFF))
    }

    @Test fun tempoAndTickConversions() {
        assertEquals(500_000L, SmfWriter.microsecondsPerQuarter(120.0))
        assertEquals(1_000_000L, SmfWriter.microsecondsPerQuarter(60.0))
        assertEquals(500_000L, SmfWriter.microsecondsPerQuarter(0.0))
        assertEquals(480, SmfWriter.ticks(500, 120.0))
        assertEquals(960, SmfWriter.ticks(1000, 120.0))
        assertEquals(1, SmfWriter.ticks(1, 120.0))
        assertEquals(0, SmfWriter.ticks(-5, 120.0))
    }

    @Test fun twoNoteFileHandDecoded() {
        val data = SmfWriter.write(listOf(ev(0, 500, 60), ev(500, 1000, 64, 90)), 120.0, InstrumentKey.PIANO)
        val expected = bytes(
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x20,
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0xC0, 0x00,
            0x00, 0x90, 0x3C, 0x64,
            0x83, 0x60, 0x80, 0x3C, 0x40,
            0x00, 0x90, 0x40, 0x5A,
            0x83, 0x60, 0x80, 0x40, 0x40,
            0x00, 0xFF, 0x2F, 0x00,
        )
        assertArrayEquals(expected, data)
    }

    @Test fun programChangeUsesGmProgram() {
        val d = SmfWriter.write(listOf(ev(0, 500, 60)), 120.0, InstrumentKey.TRUMPET)
        assertEquals(0x00, d[29].toInt()); assertEquals(0xC0, d[30].toInt() and 0xFF); assertEquals(56, d[31].toInt())
    }

    @Test fun velocityClampsAndZeroLengthGetsATick() {
        assertArrayEquals(bytes(0x00, 0x90, 0x3C, 0x01), SmfWriter.write(listOf(ev(0, 500, 60, 0)), 120.0, InstrumentKey.PIANO).copyOfRange(32, 36))
        assertArrayEquals(bytes(0x00, 0x90, 0x3C, 0x7F), SmfWriter.write(listOf(ev(0, 500, 60, 400)), 120.0, InstrumentKey.PIANO).copyOfRange(32, 36))
        assertArrayEquals(bytes(0x60, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40), SmfWriter.write(listOf(ev(100, 100, 60)), 120.0, InstrumentKey.PIANO).copyOfRange(32, 40))
    }

    @Test fun outOfRangeNotesAreSkippedFileStaysValid() {
        val d = SmfWriter.write(listOf(ev(0, 500, 128)), 120.0, InstrumentKey.PIANO)
        assertEquals(14 + 8 + 14, d.size)
        assertArrayEquals(bytes(0x00, 0xFF, 0x2F, 0x00), d.copyOfRange(d.size - 4, d.size))
    }

    // ---- parser
    @Test fun parserRoundTripsWriterOutput() {
        val events = listOf(ev(0, 500, 60, 100), ev(500, 1000, 64, 90), ev(500, 1500, 67, 70), ev(2000, 2250, 72, 127))
        val p = SmfParser.parse(SmfWriter.write(events, 120.0, InstrumentKey.PIANO))
        assertEquals(events, p.events)
        assertEquals(120.0, p.bpm, 0.0)
        assertEquals(2250, p.durationMs)
    }

    @Test fun parserRoundTripsAtOtherTempos() {
        val events = listOf(ev(0, 1000, 48, 80), ev(1000, 1400, 50, 80))
        val p = SmfParser.parse(SmfWriter.write(events, 60.0, InstrumentKey.BASS_GUITAR))
        assertEquals(60.0, p.bpm, 0.0)
        assertEquals(events, p.events)
        val q = SmfParser.parse(SmfWriter.write(events, 93.5, InstrumentKey.BASS_GUITAR))
        assertEquals(93.5, q.bpm, 0.0)
        assertEquals(2, q.events.size)
        assertTrue(kotlin.math.abs(q.events[0].offMs - 1000) <= 1)
    }

    @Test fun parserDropsChannelTenAndHonoursVelocityZeroOff() {
        // hand-built: tempo 120, ch0 note 60 on/off(vel0 on), ch9 note 36 on/off
        val trk = bytes(
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0x90, 0x3C, 0x64,           // ch0 on
            0x00, 0x99, 0x24, 0x64,           // ch9 on (drum)
            0x83, 0x60, 0x90, 0x3C, 0x00,     // ch0 on vel0 = off at 480
            0x00, 0x99, 0x24, 0x00,           // ch9 off
            0x00, 0xFF, 0x2F, 0x00,
        )
        val file = bytes(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, trk.size) + trk
        val p = SmfParser.parse(file)
        assertEquals(listOf(ev(0, 500, 60, 100)), p.events)
    }

    @Test fun parserUsesRunningStatusAndTempoChanges() {
        // 480 ticks/quarter; tempo 120 then at tick 480 -> 60 BPM. Notes via running status.
        val trk = bytes(
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0x90, 0x3C, 0x50,
            0x83, 0x60, 0x3C, 0x00,                       // running status: note-on vel 0 at 480
            0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40,     // tempo 1,000,000 us at 480
            0x00, 0x40, 0x50,                              // running status note-on 64 at 480
            0x83, 0x60, 0x40, 0x00,                        // off at 960 (a 60 BPM quarter = 1000 ms)
            0x00, 0xFF, 0x2F, 0x00,
        )
        val file = bytes(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, trk.size) + trk
        val p = SmfParser.parse(file)
        assertEquals(listOf(ev(0, 500, 60, 80), ev(500, 1500, 64, 80)), p.events)
        assertEquals(120.0, p.bpm, 0.0)
    }

    @Test fun parserMergesFormatOneTracks() {
        fun track(vararg body: Int) = bytes(0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, body.size, *body)
        val head = bytes(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0)
        val conductor = track(0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x2F, 0x00)
        val notes = track(0x00, 0x90, 0x3C, 0x64, 0x83, 0x60, 0x80, 0x3C, 0x40, 0x00, 0xFF, 0x2F, 0x00)
        val p = SmfParser.parse(head + conductor + notes)
        assertEquals(listOf(ev(0, 500, 60, 100)), p.events)
    }

    @Test fun parserRejectsGarbage() {
        assertThrows(SmfException::class.java) { SmfParser.parse(bytes(1, 2, 3)) }
        assertThrows(SmfException::class.java) { SmfParser.parse("RIFF0000000000000000".toByteArray()) }
    }

    @Test fun midiImportMapsErrorsToCopy() {
        val e = assertThrows(MidiImportException::class.java) { MidiImport.parse(bytes(9, 9, 9)) }
        assertEquals(MidiImport.CANNOT_OPEN, e.message)
        // a valid file with only drum notes -> "no playable notes"
        val trk = bytes(0x00, 0x99, 0x24, 0x64, 0x83, 0x60, 0x99, 0x24, 0x00, 0x00, 0xFF, 0x2F, 0x00)
        val file = bytes(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, trk.size) + trk
        assertEquals(MidiImport.NO_NOTES, assertThrows(MidiImportException::class.java) { MidiImport.parse(file) }.message)
        val ok = MidiImport.parse(SmfWriter.write(listOf(ev(0, 500, 60)), 120.0, InstrumentKey.PIANO))
        assertEquals(1, ok.events.size)
        assertEquals("song", MidiImport.baseName("song.mid"))
        assertEquals(null, MidiImport.baseName(".mid"))
    }
}
