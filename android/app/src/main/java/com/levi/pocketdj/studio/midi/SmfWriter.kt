package com.levi.pocketdj.studio.midi

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import java.io.ByteArrayOutputStream

/**
 * Standard MIDI File writer (iOS `SMFWriter`, spec 7): type-0, PPQ 480, from the take's RAW (unquantized) events. 0 ms = beat 1 lands on
 * tick 0. No running status (every event carries its status byte); note-offs sort before note-ons at equal ticks; velocity clamps to 1..127.
 */
object SmfWriter {
    const val PPQ = 480

    /** Variable-length quantity: big-endian 7-bit groups, high bit on all but the last byte. */
    fun vlq(value: Long): ByteArray {
        val groups = ArrayList<Int>()
        groups.add((value and 0x7F).toInt())
        var rest = value ushr 7
        while (rest > 0) { groups.add(((rest and 0x7F).toInt()) or 0x80); rest = rest ushr 7 }
        return ByteArray(groups.size) { groups[groups.size - 1 - it].toByte() }
    }

    /** ms -> ticks: ms * bpm * PPQ / 60000, rounded; degenerate bpm guards to 120; never negative. */
    fun ticks(fromMs: Int, bpm: Double): Int {
        val b = if (bpm > 0) bpm else 120.0
        val t = Math.round(fromMs.toDouble() * b * PPQ / 60_000.0)
        return if (t < 0) 0 else t.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    /** Tempo meta payload: microseconds per quarter. */
    fun microsecondsPerQuarter(bpm: Double): Long {
        val b = if (bpm > 0) bpm else 120.0
        return Math.round(60_000_000.0 / b)
    }

    private enum class Order { TEMPO, PROGRAM, NOTE_OFF, NOTE_ON }
    private class Ev(val tick: Int, val order: Order, val bytes: ByteArray)

    fun write(events: List<StudioNoteEvent>, bpm: Double, instrument: InstrumentKey): ByteArray {
        val track = ArrayList<Ev>()
        val tempo = microsecondsPerQuarter(bpm)
        track.add(Ev(0, Order.TEMPO, byteArrayOf(0xFF.toByte(), 0x51, 0x03, ((tempo shr 16) and 0xFF).toByte(), ((tempo shr 8) and 0xFF).toByte(), (tempo and 0xFF).toByte())))
        track.add(Ev(0, Order.PROGRAM, byteArrayOf(0xC0.toByte(), instrument.gmProgram.toByte())))
        for (e in events) {
            if (e.note !in 0..127) continue
            val on = ticks(e.onMs, bpm)
            val off = maxOf(on + 1, ticks(e.offMs, bpm))
            val vel = e.velocity.coerceIn(1, 127)
            track.add(Ev(on, Order.NOTE_ON, byteArrayOf(0x90.toByte(), e.note.toByte(), vel.toByte())))
            track.add(Ev(off, Order.NOTE_OFF, byteArrayOf(0x80.toByte(), e.note.toByte(), 0x40)))
        }
        val sorted = track.sortedWith(compareBy<Ev> { it.tick }.thenBy { it.order })
        val body = ByteArrayOutputStream()
        var last = 0
        for (ev in sorted) {
            body.write(vlq((ev.tick - last).toLong())); body.write(ev.bytes); last = ev.tick
        }
        body.write(vlq(0)); body.write(byteArrayOf(0xFF.toByte(), 0x2F, 0x00))
        val bodyBytes = body.toByteArray()

        val out = ByteArrayOutputStream()
        out.write("MThd".toByteArray(Charsets.US_ASCII)); out.write(be32(6))
        out.write(be16(0)); out.write(be16(1)); out.write(be16(PPQ))
        out.write("MTrk".toByteArray(Charsets.US_ASCII)); out.write(be32(bodyBytes.size.toLong()))
        out.write(bodyBytes)
        return out.toByteArray()
    }

    private fun be16(v: Int) = byteArrayOf((v shr 8).toByte(), (v and 0xFF).toByte())
    private fun be32(v: Long) = byteArrayOf(((v shr 24) and 0xFF).toByte(), ((v shr 16) and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte(), (v and 0xFF).toByte())
}
