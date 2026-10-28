package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.AndroidStudioCodec
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioPattern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** Why a bounce could not be produced. */
class PatternBounceException(val reason: Reason) : Exception(reason.name) {
    enum class Reason { EMPTY_PATTERN, WRITE_FAILED }
}

/** What a finished bounce wrote. */
data class PatternBounceResult(val frames: Long, val lengthMs: Int)

/**
 * Offline pattern bounce (iOS `StudioRender.bouncePattern` + `StudioPatternBouncer`): the SAME hit rules the live
 * [PatternScheduler] uses, laid out once over a single pass and mixed offline to `pattern-<id>.m4a`.
 *
 *  - rows with no buffer (missing target) are SKIPPED, never a throw; if no sounding row remains the bounce is
 *    refused ([PatternBounceException.Reason.EMPTY_PATTERN]) exactly like playback;
 *  - mono choke: a trigger cuts the ringing previous hit of that row (events are truncated at the row's next trigger);
 *  - LOOP steps bake as FINITE chained repeats from the trigger, the last one trimmed to the row's next trigger or the
 *    bar end (never an endless schedule - that would ring into the tail cap);
 *  - STEADY-STATE WRAP FILL: live playback's last loop trigger rings across the bar wrap until the row's FIRST trigger
 *    of the next pass, so [0, firstTrigger) is filled with the loop's continuing phase (bounce == live pass 2);
 *  - span steps use the pre-stretched [StudioStretchKey] buffer (natural fallback);
 *  - the tail of hits ringing past the bar end is kept until the first 512-frame window under -60 dBFS (3 s cap).
 */
object PatternBouncer {
    /** One placed slice of a row buffer: [length] frames of [buf] starting at buffer frame [offset], at output frame [start]. */
    class Event(val row: Int, val start: Long, val buf: PcmBuffer, val offset: Int, val length: Int)

    /** The bar (full pattern loop) length in frames. */
    fun barFrames(pattern: StudioPattern): Long = PatternMath.stepFrames(pattern.bpm) * pattern.stepCount

    /** Rows that will sound in the bounce: not silent, buffer present + canonical + non-empty. Returns row indices. */
    fun soundingRows(pattern: StudioPattern, buffers: Map<String, PcmBuffer>): List<Int> =
        pattern.rows.take(PatternMath.MAX_PATTERN_ROWS).withIndex().filter { (_, row) ->
            val b = buffers[row.targetId]
            !row.isSilent && b != null && b.frames > 0 && StudioAudio.isCanonical(b)
        }.map { it.index }

    /** The ordered event list for one pass. Pure; the bounce mixes exactly this and tests compare it to live. */
    fun plan(
        pattern: StudioPattern, buffers: Map<String, PcmBuffer>, spanBuffers: Map<StudioStretchKey, PcmBuffer> = emptyMap(),
    ): List<Event> {
        val stepF = PatternMath.stepFrames(pattern.bpm)
        val bar = stepF * pattern.stepCount
        val events = ArrayList<Event>()
        for (ri in soundingRows(pattern, buffers)) {
            val row = pattern.rows[ri]
            val natural = buffers.getValue(row.targetId)
            fun stepBuf(col: Int): PcmBuffer {
                val span = row.stepSpans.getOrNull(col) ?: 0
                return if (span > 0) spanBuffers[StudioStretchKey(row.targetId, span)] ?: natural else natural
            }
            val onCols = row.steps.indices.filter { row.steps[it] }
            if (onCols.isEmpty()) continue
            val first = onCols.first(); val last = onCols.last()
            // Wrap fill, placed FIRST (time-ordered).
            if (first > 0 && row.loopSteps.getOrNull(last) == true) {
                val loopBuf = stepBuf(last)
                val bufFrames = loopBuf.frames.toLong()
                if (bufFrames > 0) {
                    val firstF = first.toLong() * stepF
                    var offset = (bar - last.toLong() * stepF) % bufFrames
                    var pos = 0L
                    while (pos < firstF) {
                        val len = min(bufFrames - offset, firstF - pos)
                        if (len <= 0) break
                        events += Event(ri, pos, loopBuf, offset.toInt(), len.toInt())
                        pos += len
                        offset = 0
                    }
                }
            }
            onCols.forEachIndexed { k, col ->
                val buf = stepBuf(col)
                val start = col.toLong() * stepF
                val nextStart = if (k + 1 < onCols.size) onCols[k + 1].toLong() * stepF else null
                if (row.loopSteps.getOrNull(col) == true) {
                    val cut = nextStart ?: bar
                    var pos = start
                    while (pos < cut) {
                        val rep = min(buf.frames.toLong(), cut - pos)
                        if (rep <= 0) break
                        events += Event(ri, pos, buf, 0, rep.toInt())
                        pos += rep
                    }
                } else {
                    // One-shot: rings until the row's next trigger cuts it (choke); the last one rings into the tail.
                    val len = if (nextStart != null) min(buf.frames.toLong(), nextStart - start) else buf.frames.toLong()
                    if (len > 0) events += Event(ri, start, buf, 0, len.toInt())
                }
            }
        }
        return events.sortedBy { it.start }
    }

    /** Mix [events] (per-row gain from [pattern]) and apply the tail drain. Peak > 1 scales the whole bounce (never clips). */
    fun mix(pattern: StudioPattern, events: List<Event>): PcmBuffer {
        val bar = barFrames(pattern)
        val end = max(bar, events.maxOfOrNull { it.start + it.length } ?: 0L)
        val total = min(end, bar + StudioAudio.tailCapFrames)
        val out = FloatArray(total.toInt() * 2)
        for (e in events) {
            val g = StudioAudio.gainMultiplier(pattern.rows[e.row].gainDb)
            val s = e.buf.samples
            val from = e.start.toInt()
            val n = min(e.length.toLong(), total - e.start).toInt()
            for (i in 0 until n * 2) out[from * 2 + i] += s[e.offset * 2 + i] * g
        }
        // Tail drain: keep ringing hits until the first window under the floor (or the cap).
        var frames = total.toInt()
        if (total > bar) {
            var w = bar.toInt()
            frames = bar.toInt()
            while (w < total) {
                val n = min(StudioAudio.TAIL_WINDOW_FRAMES, total.toInt() - w)
                frames = w + n
                if (StudioAudio.isBelowFloor(out, w * 2, n * 2)) break
                w += n
            }
        }
        val trimmed = if (frames * 2 == out.size) out else out.copyOf(frames * 2)
        var peak = 0f
        for (v in trimmed) { val a = kotlin.math.abs(v); if (a > peak) peak = a }
        if (peak > 1f) { val inv = 1f / peak; for (i in trimmed.indices) trimmed[i] *= inv }
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, trimmed)
    }

    /** Plan + mix one bounce. Throws [PatternBounceException] when nothing can sound. */
    fun render(pattern: StudioPattern, buffers: Map<String, PcmBuffer>, spanBuffers: Map<StudioStretchKey, PcmBuffer> = emptyMap()): PcmBuffer {
        if (!pattern.hasSoundingSteps) throw PatternBounceException(PatternBounceException.Reason.EMPTY_PATTERN)
        val events = plan(pattern, buffers, spanBuffers)
        if (events.isEmpty()) throw PatternBounceException(PatternBounceException.Reason.EMPTY_PATTERN)
        return mix(pattern, events)
    }

    /** Render and write [dest] atomically (temp sibling + rename; a throw never leaves a partial file). */
    suspend fun bounce(
        pattern: StudioPattern, buffers: Map<String, PcmBuffer>, spanBuffers: Map<StudioStretchKey, PcmBuffer>, dest: File,
        write: (PcmBuffer, File) -> Unit = AndroidStudioCodec::writeM4a,
    ): PatternBounceResult = withContext(Dispatchers.Default) {
        val pcm = render(pattern, buffers, spanBuffers)
        val dir = dest.absoluteFile.parentFile ?: throw PatternBounceException(PatternBounceException.Reason.WRITE_FAILED)
        dir.mkdirs()
        val tmp = File(dir, ".studio-render-${UUID.randomUUID()}-${dest.name}")
        try {
            write(pcm, tmp)
            dest.delete()
            if (!tmp.renameTo(dest)) throw PatternBounceException(PatternBounceException.Reason.WRITE_FAILED)
        } catch (t: Throwable) {
            tmp.delete(); throw t
        }
        PatternBounceResult(pcm.frames.toLong(), Math.round(pcm.frames.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt())
    }

    /**
     * Pre-stretch every span variant the pattern's ON steps demand, deduped by [StudioStretchKey] (shared by the
     * Bounce button and the sequencer's Play prepare). A failed stretch leaves its key absent: the schedule falls
     * back to the natural buffer for that step (degraded, never a block).
     */
    suspend fun stretchSpanBuffers(
        pattern: StudioPattern, natural: Map<String, PcmBuffer>, stretch: suspend (PcmBuffer, Long) -> PcmBuffer,
    ): Map<StudioStretchKey, PcmBuffer> {
        val out = LinkedHashMap<StudioStretchKey, PcmBuffer>()
        val stepF = PatternMath.stepFrames(pattern.bpm)
        for (key in PatternMath.stretchKeys(pattern)) {
            val base = natural[key.targetId] ?: continue
            val b = try { stretch(base, stepF * key.span) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { null } ?: continue
            out[key] = b
        }
        return out
    }
}
