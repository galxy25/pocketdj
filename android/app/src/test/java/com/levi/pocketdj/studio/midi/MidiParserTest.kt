package com.levi.pocketdj.studio.midi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MidiParserTest {
    private fun parse(vararg bytes: Int): List<MidiVoice> {
        val p = MidiStreamParser(); val out = ArrayList<MidiVoice>()
        p.feed(bytes) { out.add(it) }
        return out
    }
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    @Test fun plainNoteOnAndOff() {
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOff(60)), parse(0x90, 60, 100, 0x80, 60, 0))
    }

    @Test fun runningStatusStreamParsesEveryNote() {
        // One status byte, then four note-ons with no repeated status.
        val out = parse(0x90, 60, 90, 62, 91, 64, 92, 65, 93)
        assertEquals(listOf(MidiVoice.NoteOn(60, 90), MidiVoice.NoteOn(62, 91), MidiVoice.NoteOn(64, 92), MidiVoice.NoteOn(65, 93)), out)
    }

    @Test fun noteOnWithVelocityZeroIsNoteOffEvenUnderRunningStatus() {
        val out = parse(0x90, 60, 100, 60, 0, 62, 80, 62, 0)
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOff(60), MidiVoice.NoteOn(62, 80), MidiVoice.NoteOff(62)), out)
    }

    @Test fun channelIsIgnoredAndStatusSwitchesMidStream() {
        val out = parse(0x93, 40, 70, 0x84, 40, 0, 0x91, 41, 60)
        assertEquals(listOf(MidiVoice.NoteOn(40, 70), MidiVoice.NoteOff(40), MidiVoice.NoteOn(41, 60)), out)
    }

    @Test fun controlChangeBetweenNotesDoesNotDesyncRunningStatus() {
        // CC consumes two data bytes and replaces the running status; the next note needs its own status.
        val out = parse(0x90, 60, 90, 0xB0, 64, 127, 0x90, 62, 90)
        assertEquals(listOf(MidiVoice.NoteOn(60, 90), MidiVoice.NoteOn(62, 90)), out)
    }

    @Test fun realtimeBytesInterleavedDoNotBreakAMessageOrRunningStatus() {
        val out = parse(0x90, 60, 0xF8, 100, 0xFE, 62, 0xF8, 90)
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOn(62, 90)), out)
    }

    @Test fun messageSplitAcrossReceiverCallsStillParses() {
        val p = MidiStreamParser(); val out = ArrayList<MidiVoice>()
        p.feed(bytes(0x90, 60), 0, 2) { out.add(it) }
        assertTrue(out.isEmpty())
        p.feed(bytes(100, 62, 80), 0, 3) { out.add(it) }       // finishes the first, running-status second
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOn(62, 80)), out)
    }

    @Test fun feedHonoursOffsetAndCountOfTheReceiverBuffer() {
        val p = MidiStreamParser(); val out = ArrayList<MidiVoice>()
        p.feed(bytes(0xFF, 0xFF, 0x90, 60, 100, 0xFF), 2, 3) { out.add(it) }
        assertEquals(listOf<MidiVoice>(MidiVoice.NoteOn(60, 100)), out)
    }

    @Test fun sysexIsSkippedAndCancelsRunningStatus() {
        val out = parse(0x90, 60, 90, 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7, 62, 90, 0x90, 64, 90)
        // The orphan "62 90" after EOX has no status (running status was cancelled) and is dropped.
        assertEquals(listOf(MidiVoice.NoteOn(60, 90), MidiVoice.NoteOn(64, 90)), out)
    }

    @Test fun systemCommonSwallowsItsDataAndCancelsRunningStatus() {
        val out = parse(0x90, 60, 90, 0xF2, 1, 2, 62, 90, 0x90, 64, 90)
        assertEquals(listOf(MidiVoice.NoteOn(60, 90), MidiVoice.NoteOn(64, 90)), out)
    }

    @Test fun orphanDataBytesAreDropped() {
        assertTrue(parse(60, 100, 62, 90).isEmpty())
    }

    @Test fun programChangeTakesOneDataByte() {
        val out = parse(0xC0, 5, 0x90, 60, 90)
        assertEquals(listOf<MidiVoice>(MidiVoice.NoteOn(60, 90)), out)
    }

    @Test fun dispatchRoutesToTheSink() {
        val log = ArrayList<String>()
        val sink = object : MidiNoteSink {
            override fun noteOn(note: Int, velocity: Int) { log.add("on $note $velocity") }
            override fun noteOff(note: Int) { log.add("off $note") }
        }
        parse(0x90, 61, 70, 61, 0).forEach { it.dispatch(sink) }
        assertEquals(listOf("on 61 70", "off 61"), log)
    }

    // ---- BLE-MIDI packets

    private fun ble(parser: BleMidiParser, vararg b: Int): List<MidiVoice> {
        val out = ArrayList<MidiVoice>()
        parser.feedPacket(bytes(*b)) { out.add(it) }
        return out
    }

    @Test fun blePacketWithTimestampsParsesNotes() {
        // header, ts, status, d, d,  ts, status, d, d
        val out = ble(BleMidiParser(), 0x80, 0x81, 0x90, 60, 100, 0x82, 0x80, 60, 0)
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOff(60)), out)
    }

    @Test fun bleRunningStatusWithinAndAcrossPackets() {
        val p = BleMidiParser()
        // Second message has a timestamp but NO status -> running status.
        val a = ble(p, 0x80, 0x81, 0x90, 60, 100, 0x82, 62, 90)
        assertEquals(listOf(MidiVoice.NoteOn(60, 100), MidiVoice.NoteOn(62, 90)), a)
        // A later packet that starts with only a timestamp + data continues the same running status.
        val b = ble(p, 0x80, 0x83, 64, 80)
        assertEquals(listOf<MidiVoice>(MidiVoice.NoteOn(64, 80)), b)
    }

    @Test fun bleSysexIsSkippedUntilEox() {
        val p = BleMidiParser()
        val out = ble(p, 0x80, 0x81, 0xF0, 0x01, 0x02, 0x83, 0xF7, 0x84, 0x90, 60, 100)
        assertEquals(listOf<MidiVoice>(MidiVoice.NoteOn(60, 100)), out)
    }

    @Test fun bleTooShortPacketIsIgnored() {
        assertTrue(ble(BleMidiParser(), 0x80).isEmpty())
    }

    // ---- device list helpers

    @Test fun displayNameFallsBackAndNeverBlank() {
        assertEquals("Keystation", midiDisplayName("Keystation", "x", "y"))
        assertEquals("Prod", midiDisplayName("  ", "Prod", "Mfr"))
        assertEquals("Mfr", midiDisplayName(null, "", "Mfr"))
        assertEquals("MIDI device", midiDisplayName(null, null, null))
    }

    @Test fun bleListUpsertUpdatesInPlaceAndKeepsKnownName() {
        var l = BleMidiList.upsert(emptyList(), "AA", "Roli")
        l = BleMidiList.upsert(l, "BB", null)
        l = BleMidiList.upsert(l, "AA", null)               // re-advertisement without a name keeps the old one
        assertEquals(listOf("Roli", "MIDI keyboard"), l.map { it.name })
        l = BleMidiList.setConnected(BleMidiList.setConnecting(l, "AA", true), "AA", true)
        assertTrue(l[0].connected); assertTrue(!l[0].connecting)
    }
}
