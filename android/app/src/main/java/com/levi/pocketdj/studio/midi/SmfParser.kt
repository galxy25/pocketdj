package com.levi.pocketdj.studio.midi

import com.levi.pocketdj.studio.model.StudioNoteEvent

/** A malformed or unsupported Standard MIDI File. */
class SmfException(message: String) : Exception(message)

/**
 * Pure-Kotlin Standard MIDI File parser (no AudioToolbox equivalent on Android). Handles format 0/1/2 (tracks merged), running status,
 * meta/sysex skipping, and a tempo map from every track. Produces ms-timed [StudioNoteEvent]s: channel 10 (0-based 9) percussion is
 * DROPPED, velocity-0 note-ons are note-offs, and notes still open at the end of their track close there.
 */
object SmfParser {
    data class Parsed(val events: List<StudioNoteEvent>, val bpm: Double, val durationMs: Int)

    private class RawNote(val tick: Long, val endTick: Long, val note: Int, val velocity: Int)

    /** (tick, microseconds per quarter), sorted by tick, first entry always tick 0. */
    private class TempoMap(entries: List<Pair<Long, Long>>, private val ticksPerQuarter: Int, private val msPerTickSmpte: Double?) {
        private val tempos: List<Pair<Long, Long>>
        private val cumMs: DoubleArray

        init {
            val sorted = entries.sortedBy { it.first }
            // later tempo at the same tick wins
            val dedup = ArrayList<Pair<Long, Long>>()
            for (e in sorted) { if (dedup.isNotEmpty() && dedup.last().first == e.first) dedup[dedup.size - 1] = e else dedup.add(e) }
            if (dedup.isEmpty() || dedup.first().first != 0L) dedup.add(0, 0L to 500_000L)
            tempos = dedup
            cumMs = DoubleArray(tempos.size)
            for (i in 1 until tempos.size) cumMs[i] = cumMs[i - 1] + (tempos[i].first - tempos[i - 1].first) * msPerTick(tempos[i - 1].second)
        }

        private fun msPerTick(us: Long): Double = msPerTickSmpte ?: (us / 1000.0 / ticksPerQuarter)

        fun ms(tick: Long): Double {
            var lo = 0; var hi = tempos.size - 1
            while (lo < hi) { val mid = (lo + hi + 1) / 2; if (tempos[mid].first <= tick) lo = mid else hi = mid - 1 }
            return cumMs[lo] + (tick - tempos[lo].first) * msPerTick(tempos[lo].second)
        }

        /** Initial tempo as BPM (60e6 / us per quarter). */
        fun initialBpm(): Double = 60_000_000.0 / tempos.first().second
    }

    fun parse(bytes: ByteArray): Parsed {
        var p = 0
        fun need(n: Int) { if (p + n > bytes.size) throw SmfException("truncated file") }
        fun u8(): Int { need(1); return bytes[p++].toInt() and 0xFF }
        fun u16(): Int = (u8() shl 8) or u8()
        fun u32(): Long = (u16().toLong() shl 16) or u16().toLong()
        fun tag(): String { need(4); val s = String(bytes, p, 4, Charsets.ISO_8859_1); p += 4; return s }

        if (bytes.size < 14 || tag() != "MThd") throw SmfException("not a MIDI file")
        val hdrLen = u32()
        if (hdrLen < 6) throw SmfException("bad header")
        val format = u16()
        val nTracks = u16()
        val division = u16()
        p += (hdrLen - 6).toInt().coerceAtLeast(0)
        if (format > 2) throw SmfException("unsupported MIDI format $format")

        val smpteMsPerTick: Double? = if (division and 0x8000 != 0) {
            val fps = 256 - (division shr 8)          // two's-complement negative frames/sec
            val sub = division and 0xFF
            if (fps <= 0 || sub <= 0) throw SmfException("bad SMPTE division")
            1000.0 / (fps.toDouble() * sub)
        } else null
        val tpq = if (smpteMsPerTick == null) division else 1
        if (smpteMsPerTick == null && tpq <= 0) throw SmfException("bad division")

        val tempoEntries = ArrayList<Pair<Long, Long>>()
        val notes = ArrayList<RawNote>()
        var tracksRead = 0
        while (p + 8 <= bytes.size && tracksRead < nTracks) {
            val t = tag()
            val len = u32()
            val end = minOf(bytes.size.toLong(), p + len).toInt()
            if (t != "MTrk") { p = end; continue }
            tracksRead++
            var tick = 0L
            var running = -1
            // open notes keyed (channel,note) -> stack of (startTick, velocity)
            val open = HashMap<Int, ArrayDeque<Pair<Long, Int>>>()
            fun vlq(): Long {
                var v = 0L
                for (i in 0 until 4) { if (p >= end) throw SmfException("truncated track"); val b = bytes[p++].toInt() and 0xFF; v = (v shl 7) or (b and 0x7F).toLong(); if (b and 0x80 == 0) return v }
                throw SmfException("bad variable-length value")
            }
            fun closeNote(ch: Int, note: Int, at: Long) {
                val st = open[ch * 128 + note] ?: return
                val s = st.removeFirstOrNull() ?: return
                if (ch != 9) notes.add(RawNote(s.first, at, note, s.second))
            }
            try {
                while (p < end) {
                    tick += vlq()
                    if (p >= end) break
                    var status = bytes[p].toInt() and 0xFF
                    if (status < 0x80) {
                        if (running < 0) throw SmfException("running status without a status byte")
                        status = running                       // data byte follows; do not consume
                    } else p++
                    when {
                        status == 0xFF -> {
                            if (p >= end) break
                            val type = bytes[p++].toInt() and 0xFF
                            val mlen = vlq().toInt()
                            if (p + mlen > end) break
                            if (type == 0x51 && mlen == 3) {
                                val us = ((bytes[p].toLong() and 0xFF) shl 16) or ((bytes[p + 1].toLong() and 0xFF) shl 8) or (bytes[p + 2].toLong() and 0xFF)
                                if (us > 0) tempoEntries.add(tick to us)
                            }
                            p += mlen
                            if (type == 0x2F) break
                        }
                        status == 0xF0 || status == 0xF7 -> { val l = vlq().toInt(); p += l; running = -1 }
                        else -> {
                            running = status
                            val ch = status and 0x0F
                            when (status and 0xF0) {
                                0x80, 0x90 -> {
                                    if (p + 2 > end) break
                                    val note = bytes[p++].toInt() and 0x7F
                                    val vel = bytes[p++].toInt() and 0x7F
                                    if ((status and 0xF0) == 0x90 && vel > 0) open.getOrPut(ch * 128 + note) { ArrayDeque() }.addLast(tick to vel)
                                    else closeNote(ch, note, tick)
                                }
                                0xC0, 0xD0 -> p += 1
                                else -> p += 2                  // 0xA0 aftertouch, 0xB0 controller, 0xE0 pitch bend
                            }
                        }
                    }
                }
            } catch (e: SmfException) {
                if (notes.isEmpty() && tracksRead == 1) throw e   // nothing salvageable
            }
            // notes still open at the end of the track close at the last tick
            for ((k, st) in open) for (s in st) if (k / 128 != 9 && tick > s.first) notes.add(RawNote(s.first, tick, k % 128, s.second))
            p = end
        }
        if (tracksRead == 0) throw SmfException("no tracks")

        val map = TempoMap(tempoEntries, tpq, smpteMsPerTick)
        val bpm0 = map.initialBpm()
        val bpm = if (smpteMsPerTick != null) 120.0 else if (bpm0.isFinite() && bpm0 > 0) bpm0.coerceIn(20.0, 300.0) else 120.0
        val events = ArrayList<StudioNoteEvent>()
        for (n in notes) {
            val on = Math.round(map.ms(n.tick)).toInt()
            val off = Math.round(map.ms(n.endTick)).toInt()
            if (off > on) events.add(StudioNoteEvent(on, off, n.note, n.velocity))
        }
        events.sortWith(compareBy<StudioNoteEvent> { it.onMs }.thenBy { it.note })
        val duration = events.maxOfOrNull { it.offMs } ?: 0
        return Parsed(events, Math.round(bpm * 100) / 100.0, duration)
    }
}
