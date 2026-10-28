package com.levi.pocketdj.studio.midi

/** The two channel-voice messages the instrument cares about (iOS `MIDIVoice`). Note-on with velocity 0 is a NOTE-OFF. */
sealed interface MidiVoice {
    data class NoteOn(val note: Int, val velocity: Int) : MidiVoice
    data class NoteOff(val note: Int) : MidiVoice
}

/**
 * Byte-stream MIDI 1.0 parser for the wired/USB path (`MidiReceiver.onSend` hands raw bytes, possibly several
 * messages per call, and possibly a message split across calls). Handles RUNNING STATUS (a data byte with no
 * preceding status reuses the last channel-voice status), realtime bytes interleaved mid-message (0xF8+ never
 * disturb running status or a half-built message), SysEx (skipped to 0xF7) and system-common messages (cancel
 * running status). Pure and allocation-light: no Android types, so it is JVM-testable.
 */
class MidiStreamParser {
    private var running = 0                 // last channel-voice status byte, 0 = none
    private var data1 = -1                  // first data byte of a 2-byte message in flight
    private var inSysex = false
    private var skipData = 0                // data bytes left to swallow for a system-common message

    fun reset() { running = 0; data1 = -1; inSysex = false; skipData = 0 }

    fun feed(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size - offset, out: (MidiVoice) -> Unit) {
        for (i in offset until offset + count) byte(bytes[i].toInt() and 0xFF, out)
    }

    fun feed(bytes: IntArray, out: (MidiVoice) -> Unit) { for (b in bytes) byte(b and 0xFF, out) }

    fun byte(b: Int, out: (MidiVoice) -> Unit) {
        if (b >= 0xF8) return                                   // realtime: transparent to everything
        if (b >= 0x80) {
            if (b == 0xF7) { inSysex = false; return }          // EOX
            if (inSysex) inSysex = false                        // any status byte also terminates a SysEx
            data1 = -1; skipData = 0
            when {
                b == 0xF0 -> { inSysex = true; running = 0 }
                b >= 0xF0 -> { running = 0; skipData = when (b) { 0xF1, 0xF3 -> 1; 0xF2 -> 2; else -> 0 } }
                else -> running = b
            }
            return
        }
        if (inSysex) return
        if (skipData > 0) { skipData--; return }
        val st = running
        if (st == 0) return                                     // orphan data byte
        when (st and 0xF0) {
            0x80, 0x90 -> {
                if (data1 < 0) { data1 = b; return }
                val note = data1; data1 = -1
                if ((st and 0xF0) == 0x90 && b > 0) out(MidiVoice.NoteOn(note, b)) else out(MidiVoice.NoteOff(note))
            }
            0xA0, 0xB0, 0xE0 -> { if (data1 < 0) data1 = b else data1 = -1 }   // aftertouch / CC / bend: consumed, ignored
            else -> {}                                                          // 0xC0 / 0xD0: one data byte, ignored
        }
    }
}

/**
 * BLE-MIDI packet parser (MMA "MIDI over BLE"): each GATT notification is a header byte (bit 7 set), then
 * messages each preceded by a timestamp-low byte (bit 7 set); running status is carried across messages AND packets.
 * Timestamps are stripped and the message bytes delegated to a [MidiStreamParser].
 */
class BleMidiParser {
    private val inner = MidiStreamParser()
    private var inSysex = false

    fun reset() { inner.reset(); inSysex = false }

    fun feedPacket(packet: ByteArray, out: (MidiVoice) -> Unit) {
        if (packet.size < 2) return
        var i = 1                                               // skip the header byte
        while (i < packet.size) {
            val b = packet[i].toInt() and 0xFF
            if (inSysex) {
                // inside a SysEx only EOX matters; high-bit bytes before it are timestamps, data bytes are payload
                if (b == 0xF7) { inner.byte(b, out); inSysex = false }
                i++; continue
            }
            if (b and 0x80 != 0) {
                // At a message boundary the first high-bit byte is ALWAYS a timestamp-low; a status byte, if
                // any, follows it. No status after it => running status (data bytes follow).
                i++
                if (i >= packet.size) break
                val s = packet[i].toInt() and 0xFF
                if (s and 0x80 != 0) {
                    inner.byte(s, out)
                    if (s == 0xF0) inSysex = true
                    i++
                }
            } else {
                inner.byte(b, out)
                i++
            }
        }
    }
}
