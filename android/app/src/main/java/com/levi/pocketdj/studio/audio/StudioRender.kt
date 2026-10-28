package com.levi.pocketdj.studio.audio

import android.media.MediaExtractor
import android.media.MediaFormat
import com.levi.pocketdj.audio.core.AacEncoder
import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.core.AudioDiag
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.WavWriter
import com.levi.pocketdj.mix.model.BeatGrid
import com.levi.pocketdj.mix.model.BeatMath
import com.levi.pocketdj.studio.dsp.Biquad
import com.levi.pocketdj.studio.dsp.TrackFx
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSampleEdit
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/** StudioRender failures. Every case leaves NO partial file behind (temp + atomic move). */
sealed class StudioRenderException(msg: String) : Exception(msg) {
    class UnreadableSource(val path: String) : StudioRenderException("unreadable source: $path")
    class EmptyWindow : StudioRenderException("window resolves to zero frames")
    class NoGrid : StudioRenderException("no usable beat grid for the loop slice")
    class ProtectedSource(val path: String) : StudioRenderException("DRM-protected source: $path")
    class CannotCreateBuffer : StudioRenderException("cannot create buffer")
}

/** Codec seam: MediaCodec/MediaMuxer on device, fakes on the JVM. */
interface StudioCodec {
    /** Whole file -> canonical 44.1 kHz stereo. Null when undecodable. */
    fun decode(path: String): PcmBuffer?
    /** Whole file at its OWN sample rate (no resample) — the varispeed relabel input. */
    fun decodeNativeRate(path: String): PcmBuffer?
    /** Only [startMs, startMs+lenMs) of the file -> canonical (never the whole album side on device). Default: whole decode + slice. */
    fun decodeRange(path: String, startMs: Int, lenMs: Int): PcmBuffer? {
        val full = decode(path) ?: return null
        val rate = full.sampleRate.toDouble()
        val from = StudioAudio.msToFrames(startMs, rate).coerceAtMost(full.frames.toLong())
        val n = minOf(StudioAudio.msToFrames(lenMs, rate), full.frames - from)
        return StudioAudio.slice(full, from, n) ?: PcmBuffer(full.sampleRate, full.channels, FloatArray(0))
    }
    fun isProtected(path: String): Boolean
    fun writeM4a(pcm: PcmBuffer, file: File)
    /** LPCM float WAV with an exact frame count (loops). */
    fun writeWav(pcm: PcmBuffer, file: File)
}

object AndroidStudioCodec : StudioCodec {
    override fun decode(path: String) = runCatching { AudioDecoder.decode(path) }.getOrNull()

    override fun decodeRange(path: String, startMs: Int, lenMs: Int): PcmBuffer? =
        runCatching { AudioDecoder.decode(path, maxSeconds = lenMs / 1000.0, startSeconds = startMs / 1000.0) }.getOrNull()

    override fun decodeNativeRate(path: String): PcmBuffer? = runCatching {
        val rate = probe(path) { it.getInteger(MediaFormat.KEY_SAMPLE_RATE) } ?: return null
        AudioDecoder.decode(path, rate = rate)
    }.getOrNull()

    /** A FairPlay/DRM asset exposes DRM init data (or the legacy .m4p extension). */
    override fun isProtected(path: String): Boolean {
        if (path.endsWith(".m4p", ignoreCase = true)) return true
        val ex = MediaExtractor()
        return try { ex.setDataSource(path); ex.drmInitData != null } catch (_: Throwable) { false } finally { ex.release() }
    }

    override fun writeM4a(pcm: PcmBuffer, file: File) = AacEncoder.encode(pcm, file, AacEncoder.Container.M4A, bitrate = 192_000)
    override fun writeWav(pcm: PcmBuffer, file: File) = WavWriter.write(file, pcm, WavWriter.Format.FLOAT32)

    private fun <T> probe(path: String, read: (MediaFormat) -> T): T? {
        val ex = MediaExtractor()
        return try {
            ex.setDataSource(path)
            val i = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            i?.let { read(ex.getTrackFormat(it)) }
        } catch (_: Throwable) { null } finally { ex.release() }
    }
}

/** Offline time/pitch seam: native Signalsmith on device, a resampler on the JVM. */
interface Stretcher {
    /** [pcm] (canonical stereo) -> EXACTLY [outFrames] frames, pitch shifted by [pitchSemitones] when supported. */
    fun stretch(pcm: PcmBuffer, outFrames: Int, pitchSemitones: Double): PcmBuffer
}

/** Linear-resample "varispeed" fit: exact length, pitch follows tempo (no independent pitch). Fallback + test double. */
object ResampleStretcher : Stretcher {
    override fun stretch(pcm: PcmBuffer, outFrames: Int, pitchSemitones: Double): PcmBuffer {
        val src = pcm.toStereo()
        val n = src.frames
        val out = FloatArray(outFrames * 2)
        if (n == 0) return PcmBuffer(src.sampleRate, 2, out)
        val ratio = n.toDouble() / outFrames
        for (i in 0 until outFrames) {
            val pos = i * ratio
            val i0 = min(pos.toInt(), n - 1)
            val i1 = min(i0 + 1, n - 1)
            val f = (pos - i0).toFloat()
            for (c in 0..1) {
                val a = src.samples[i0 * 2 + c]
                out[i * 2 + c] = a + (src.samples[i1 * 2 + c] - a) * f
            }
        }
        return PcmBuffer(src.sampleRate, 2, out)
    }
}

/** Signalsmith Stretch via JNI (exact mode: aligned, no priming head); resample fallback when too short / unavailable. */
object NativeStretcher : Stretcher {
    override fun stretch(pcm: PcmBuffer, outFrames: Int, pitchSemitones: Double): PcmBuffer {
        val src = pcm.toStereo()
        if (!NativeDsp.available || src.frames == 0) return ResampleStretcher.stretch(src, outFrames, pitchSemitones)
        val out = FloatArray(outFrames * 2)
        val ok = NativeDsp.nativeStretchExact(src.samples, src.frames, out, outFrames, src.sampleRate, pitchSemitones)
        return if (ok) PcmBuffer(src.sampleRate, 2, out) else ResampleStretcher.stretch(src, outFrames, pitchSemitones)
    }
}

/** Result of a sample/loop/carve render. */
data class RenderResult(val frames: Long, val durationMs: Int)
data class LoopRenderResult(val frames: Long, val lengthMs: Int, val bpm: Double)

/**
 * Pure (file-free) render math: everything StudioRender does between "decoded canonical PCM" and
 * "PCM to encode". JVM-tested directly.
 */
object StudioRenderCore {
    private const val CHUNK = 4096

    /** The sample edit voicing chain: comp -> (gain + resonant LP) -> reverb -> slap delay. State persists across [process] calls (tail drain). */
    class SampleFx(edit: StudioSampleEdit, sr: Double = StudioAudio.CANONICAL_RATE.toDouble()) {
        private val e = edit.clamped()
        private val gain = StudioAudio.gainMultiplier(e.gainDb)
        private val lp: Array<Biquad>? = if (e.filterAmt > 0) {
            val f = 18_000.0 * (250.0 / 18_000.0).pow(e.filterAmt)
            val w0 = 2 * Math.PI * f / sr
            val alpha = sin(w0) / (2 * 1.2)
            val a0 = 1 + alpha
            val c = doubleArrayOf((1 - cos(w0)) / 2 / a0, (1 - cos(w0)) / a0, (1 - cos(w0)) / 2 / a0, -2 * cos(w0) / a0, (1 - alpha) / a0)
            Array(2) { Biquad().also { b -> b.set(c) } }
        } else null
        private val reverb: TrackFx? = if (e.reverbWet > 0) TrackFxKernel(sr, 2).also { it.update(TrackFxParams(reverb = e.reverbWet)) } else null
        private val delayLen = (0.3 * sr).toInt()
        private val delayBuf: Array<FloatArray>? = if (e.delayWet > 0) Array(2) { FloatArray(delayLen) } else null
        private var delayPos = 0
        // compressor
        private val compOn = e.compWet > 0
        private val compThreshDb = -30.0 * e.compWet
        private val compMakeup = 10.0.pow(15.0 * e.compWet / 20.0).toFloat()
        private val atk = exp(-1.0 / (0.005 * sr)); private val rel = exp(-1.0 / (0.12 * sr))
        private var env = 0.0
        private val planar = arrayOf(FloatArray(CHUNK), FloatArray(CHUNK))

        /** True while the slap-delay line still holds audible energy (a silent gap before an echo must not end the drain). */
        fun delayPending(): Boolean {
            val db = delayBuf ?: return false
            val floor = 10.0.pow(StudioAudio.TAIL_FLOOR_DB / 20.0).toFloat()
            for (c in 0..1) for (v in db[c]) if (abs(v) > floor) return true
            return false
        }

        /** True when the chain does nothing to the signal except (possibly) unity gain. */
        val isNeutral: Boolean get() = !compOn && lp == null && reverb == null && delayBuf == null && gain == 1f

        /** Process [frames] interleaved stereo frames starting at frame [from] of [buf], in place. */
        fun process(buf: FloatArray, from: Int, frames: Int) {
            var done = 0
            while (done < frames) {
                val n = min(CHUNK, frames - done)
                chunk(buf, (from + done) * 2, n)
                done += n
            }
        }

        private fun chunk(buf: FloatArray, o: Int, n: Int) {
            if (compOn) {
                for (i in 0 until n) {
                    val l = buf[o + 2 * i]; val r = buf[o + 2 * i + 1]
                    val level = max(abs(l), abs(r)).toDouble()
                    env = if (level > env) atk * env + (1 - atk) * level else rel * env + (1 - rel) * level
                    val db = if (env > 1e-9) 20 * log10(env) else -180.0
                    val over = db - compThreshDb
                    val gr = if (over > 0) -(over - over / 4.0) else 0.0 // 4:1 above threshold
                    val g = 10.0.pow(gr / 20.0).toFloat() * compMakeup
                    buf[o + 2 * i] = l * g; buf[o + 2 * i + 1] = r * g
                }
            }
            if (gain != 1f || lp != null) {
                for (i in 0 until n) for (c in 0..1) {
                    var x = buf[o + 2 * i + c].toDouble() * gain
                    if (lp != null) x = lp[c].process(x)
                    buf[o + 2 * i + c] = x.toFloat()
                }
            }
            reverb?.let { rv ->
                for (i in 0 until n) { planar[0][i] = buf[o + 2 * i]; planar[1][i] = buf[o + 2 * i + 1] }
                rv.process(planar, n)
                for (i in 0 until n) { buf[o + 2 * i] = planar[0][i]; buf[o + 2 * i + 1] = planar[1][i] }
            }
            delayBuf?.let { db ->
                val w = e.delayWet.toFloat()
                for (i in 0 until n) {
                    for (c in 0..1) {
                        val x = buf[o + 2 * i + c]
                        val echo = db[c][delayPos]
                        db[c][delayPos] = x + echo * 0.3f
                        buf[o + 2 * i + c] = x * (1 - w) + echo * w
                    }
                    delayPos = (delayPos + 1) % delayLen // one shared write head for L/R
                }
            }
        }
    }

    /** Fit [window] to the edit's rate/pitch via the stretcher: exactly [outFrames] frames (identity when neutral). */
    fun applyTempoPitch(window: PcmBuffer, edit: StudioSampleEdit, outFrames: Long, stretcher: Stretcher): PcmBuffer {
        val neutral = abs(edit.rate - 1.0) < 1e-9 && abs(edit.pitchSemitones) < 1e-9
        if (neutral) return StudioAudio.trimmedOrPadded(window, outFrames) ?: throw StudioRenderException.CannotCreateBuffer()
        return stretcher.stretch(window, outFrames.toInt(), edit.pitchSemitones)
    }

    /** Sample bake: trim window -> tempo/pitch -> FX chain -> tail drain (-60 dBFS RMS window or 3 s cap). */
    fun sampleBuffer(canonical: PcmBuffer, editIn: StudioSampleEdit, stretcher: Stretcher): PcmBuffer {
        val edit = editIn.clamped()
        val total = canonical.frames.toLong()
        val start = min(StudioAudio.msToFrames(edit.trimStartMs, StudioAudio.CANONICAL_RATE.toDouble()), total)
        val end = if (edit.trimEndMs > 0) min(StudioAudio.msToFrames(edit.trimEndMs, StudioAudio.CANONICAL_RATE.toDouble()), total) else total
        val count = end - start
        if (count <= 0) throw StudioRenderException.EmptyWindow()
        val window = StudioAudio.slice(canonical, start, count) ?: throw StudioRenderException.EmptyWindow()
        val nominal = StudioAudio.nominalSampleFrames(count, StudioAudio.CANONICAL_RATE.toDouble(), edit.rate)
        val shaped = applyTempoPitch(window, edit, nominal, stretcher)
        val fx = SampleFx(edit)
        val body = shaped.samples.copyOf()
        fx.process(body, 0, nominal.toInt())
        // tail drain: windows are always written, the first below-floor window ends it
        var out = body
        var len = body.size
        val cap = StudioAudio.tailCapFrames
        var tail = 0L
        val win = StudioAudio.TAIL_WINDOW_FRAMES
        while (tail < cap) {
            val w = FloatArray(win * 2)
            fx.process(w, 0, win)
            if (out.size < len + w.size) out = out.copyOf(max(out.size * 2, len + w.size))
            System.arraycopy(w, 0, out, len, w.size)
            len += w.size
            tail += win
            if (StudioAudio.isBelowFloor(w, 0, w.size) && !fx.delayPending()) break
        }
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, out.copyOf(len))
    }

    /** Loop bake: EXACT post-rate window length, sonic edits baked, tails truncated, short source zero-padded. */
    fun loopBuffer(
        canonical: PcmBuffer, editIn: StudioSampleEdit, anchorMs: Int, beats: LoopBeats, grid: StudioGrid, stretcher: Stretcher,
    ): Pair<PcmBuffer, LoopRenderResult> {
        val edit = editIn.clamped()
        val slice = BeatMath.sliceBoundaries(anchorMs, beats.beatCount, BeatGrid(grid.bpm, grid.firstDownbeatMs, grid.beatsMs))
            ?.takeIf { it.lengthMs > 0 } ?: throw StudioRenderException.NoGrid()
        val exact = StudioAudio.exactLoopFrames(slice.lengthMs, edit.rate)
        if (exact <= 0) throw StudioRenderException.EmptyWindow()
        val total = canonical.frames.toLong()
        val rate = StudioAudio.CANONICAL_RATE.toDouble()
        val start = max(0L, StudioAudio.msToFrames(slice.startMs, rate))
        if (start >= total) throw StudioRenderException.EmptyWindow()
        val end = min(StudioAudio.msToFrames(slice.endMs, rate), total)
        val count = end - start
        if (count <= 0) throw StudioRenderException.EmptyWindow()
        val window = StudioAudio.slice(canonical, start, count) ?: throw StudioRenderException.EmptyWindow()
        // available source (may be short of the full window) tempo-fit proportionally, then pad to the exact length
        val fitted = max(1L, Math.round(count.toDouble() / edit.rate))
        val shaped = applyTempoPitch(window, edit, fitted, stretcher)
        val exactBuf = StudioAudio.trimmedOrPadded(shaped, exact) ?: throw StudioRenderException.CannotCreateBuffer()
        val body = exactBuf.samples.copyOf()
        SampleFx(edit).process(body, 0, exact.toInt()) // no drain: the seam lands on the musical boundary
        val lengthMs = Math.round(exact.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt()
        val bpm = if (lengthMs > 0) beats.beatCount * 60_000.0 / lengthMs else grid.bpm * edit.rate
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, body) to LoopRenderResult(exact, lengthMs, bpm)
    }

    /** Neutral region carve: [startMs, endMs) of canonical PCM (clamped to the file). */
    fun carve(canonical: PcmBuffer, startMs: Int, endMs: Int): PcmBuffer {
        if (startMs < 0 || endMs <= startMs) throw StudioRenderException.EmptyWindow()
        val total = canonical.frames.toLong()
        val rate = StudioAudio.CANONICAL_RATE.toDouble()
        val s = min(StudioAudio.msToFrames(startMs, rate), total)
        val e = min(StudioAudio.msToFrames(endMs, rate), total)
        return StudioAudio.slice(canonical, s, e - s) ?: throw StudioRenderException.EmptyWindow()
    }

    /** Sum stems' [startMs, endMs) windows into one accumulator sized by the window (no attenuation). */
    fun stemMix(stems: List<PcmBuffer>, startMs: Int, endMs: Int): PcmBuffer {
        if (startMs < 0 || endMs <= startMs || stems.isEmpty()) throw StudioRenderException.EmptyWindow()
        val window = max(1, Math.round((endMs - startMs) / 1000.0 * StudioAudio.CANONICAL_RATE).toInt())
        val acc = FloatArray(window * 2)
        var summed = 0
        for (s in stems) {
            val total = s.frames.toLong()
            val rate = StudioAudio.CANONICAL_RATE.toDouble()
            val a = min(StudioAudio.msToFrames(startMs, rate), total)
            val b = min(StudioAudio.msToFrames(endMs, rate), total)
            if (b <= a) continue
            StudioAudio.addInto(acc, StudioAudio.slice(s, a, b - a) ?: continue)
            summed++
        }
        if (summed == 0) throw StudioRenderException.EmptyWindow()
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, acc)
    }

    /** Tempo-fit to EXACTLY [frames] frames; rate clamped to 1/32...32 (extreme fits are the user's call). */
    fun stretchTo(source: PcmBuffer, frames: Long, stretcher: Stretcher): PcmBuffer {
        if (frames <= 0 || source.frames == 0) throw StudioRenderException.EmptyWindow()
        if (source.frames.toLong() == frames) return source
        val rate = (source.frames.toDouble() / frames).coerceIn(1.0 / 32.0, 32.0)
        val natural = max(1L, Math.round(source.frames / rate))
        val out = stretcher.stretch(source, natural.toInt(), 0.0)
        return StudioAudio.trimmedOrPadded(out, frames) ?: throw StudioRenderException.CannotCreateBuffer()
    }

    /** Pitch + tempo of a canonical WINDOW (arranger pre-bake). Neutral request = plain slice. */
    fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double, stretcher: Stretcher): PcmBuffer {
        if (frames <= 0 || from < 0 || from + frames > source.frames) throw StudioRenderException.EmptyWindow()
        val window = StudioAudio.slice(source, from, frames) ?: throw StudioRenderException.CannotCreateBuffer()
        val r = rate.coerceIn(1.0 / 32.0, 32.0)
        if (abs(r - 1) < 0.0005 && abs(pitchCents) < 0.5) return window
        val outFrames = max(1L, Math.round(frames / r))
        return stretcher.stretch(window, outFrames.toInt(), pitchCents / 100.0)
    }
}

/**
 * The Studio OFFLINE renderer (port of StudioRender.swift's non-engine surface). Serialized on a
 * single-permit [Mutex] (the iOS actor): concurrent bakes would only thrash the encoder. Heavy work
 * runs on [dispatcher]. Outputs are written to a hidden temp sibling and atomically moved, so a
 * throwing render never leaves a partial file.
 *
 * Formats: samples + carves + imports -> AAC `.m4a`; loops -> float LPCM `.wav` with an
 * authoritative frame count (AAC priming/padding ticks at a loop seam).
 *
 * Not ported here (later Studio packages own their inputs): pattern bounce (needs the step clock) and
 * SoundFont take renders (use [Sf2Synth] + [mixPcm]).
 */
class StudioRender(
    private val codec: StudioCodec = AndroidStudioCodec,
    private val stretcher: Stretcher = NativeStretcher,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val log: (String) -> Unit = { msg -> runCatching { AudioDiag.emit("studio.render $msg") } },
) {
    private val mutex = Mutex()

    private suspend fun <T> serial(block: () -> T): T = mutex.withLock { withContext(dispatcher) { block() } }

    private fun decodeOrThrow(path: String): PcmBuffer {
        val pcm = codec.decode(path) ?: throw StudioRenderException.UnreadableSource(path)
        if (pcm.frames <= 0) throw StudioRenderException.EmptyWindow()
        return pcm
    }

    /** Bake a sample's edit (trim, gain, rate, pitch, FX + tail) into an AAC m4a at [dest]. */
    suspend fun renderSample(edit: StudioSampleEdit, sourcePath: String, dest: File): RenderResult = serial {
        val out = StudioRenderCore.sampleBuffer(decodeOrThrow(sourcePath), edit, stretcher)
        writeAtomically(dest) { codec.writeM4a(out, it) }
        result(out.frames).also { log("sample ${dest.name}: ${it.frames}f/${it.durationMs}ms rate=${edit.rate}") }
    }

    /** Render a beat-window slice to a seamless LPCM loop with EXACT frames; returns the loop's standalone bpm. */
    suspend fun renderLoop(
        edit: StudioSampleEdit, sourcePath: String, anchorMs: Int, beats: LoopBeats, grid: StudioGrid, dest: File,
    ): LoopRenderResult = serial {
        val (pcm, res) = StudioRenderCore.loopBuffer(decodeOrThrow(sourcePath), edit, anchorMs, beats, grid, stretcher)
        writeAtomically(dest) { codec.writeWav(pcm, it) }
        log("loop ${dest.name}: ${res.frames}f/${res.lengthMs}ms bpm=${"%.2f".format(res.bpm)}")
        res
    }

    suspend fun carveTrackRegion(sourcePath: String, startMs: Int, endMs: Int, dest: File): RenderResult = serial {
        if (startMs < 0 || endMs <= startMs) throw StudioRenderException.EmptyWindow()
        val win = codec.decodeRange(sourcePath, startMs, endMs - startMs) ?: throw StudioRenderException.UnreadableSource(sourcePath)
        if (win.frames <= 0) throw StudioRenderException.EmptyWindow()
        val out = StudioRenderCore.carve(win, 0, endMs - startMs)
        writeAtomically(dest) { codec.writeM4a(out, it) }
        result(out.frames).also { log("carve ${File(sourcePath).name} [$startMs-${endMs}ms] -> ${it.frames}f") }
    }

    /** Stems are SONG-relative (0:00 = song start): sum their windows, all-or-nothing on unreadable stems. */
    suspend fun carveStemMix(stemPaths: List<String>, startMs: Int, endMs: Int, dest: File): RenderResult = serial {
        if (stemPaths.isEmpty()) throw StudioRenderException.EmptyWindow()
        val out = StudioRenderCore.stemMix(stemPaths.map { decodeOrThrow(it) }, startMs, endMs)
        writeAtomically(dest) { codec.writeM4a(out, it) }
        result(out.frames).also { log("stem-carve ${stemPaths.size} stems -> ${it.frames}f") }
    }

    /** Import an arbitrary audio file as a sample. DRM-protected files are rejected up front. */
    suspend fun importAudioFile(sourcePath: String, dest: File): RenderResult = serial {
        if (codec.isProtected(sourcePath)) throw StudioRenderException.ProtectedSource(sourcePath)
        val out = decodeOrThrow(sourcePath)
        writeAtomically(dest) { codec.writeM4a(out, it) }
        result(out.frames).also { log("import ${File(sourcePath).name} -> ${it.frames}f") }
    }

    /** Re-interpret the frames at the canonical rate WITHOUT resampling (Quantized record mode). */
    suspend fun importAudioFileRelabeled(sourcePath: String, dest: File): RenderResult = serial {
        val raw = codec.decodeNativeRate(sourcePath) ?: throw StudioRenderException.UnreadableSource(sourcePath)
        if (raw.frames <= 0) throw StudioRenderException.EmptyWindow()
        val out = StudioAudio.relabeled(raw)
        writeAtomically(dest) { codec.writeM4a(out, it) }
        result(out.frames).also { log("import-relabel ${File(sourcePath).name} -> ${it.frames}f") }
    }

    suspend fun decodeBuffer(path: String): PcmBuffer = serial { decodeOrThrow(path) }

    /** Ranged decode: just [startMs, startMs+lenMs) of [path] (null when unreadable/empty). */
    suspend fun decodeRangeBuffer(path: String, startMs: Int, lenMs: Int): PcmBuffer? =
        serial { codec.decodeRange(path, startMs, lenMs)?.takeIf { it.frames > 0 } }

    suspend fun stretchBuffer(source: PcmBuffer, toFrames: Long): PcmBuffer = serial {
        if (!StudioAudio.isCanonical(source)) throw StudioRenderException.CannotCreateBuffer()
        StudioRenderCore.stretchTo(source, toFrames, stretcher)
    }

    suspend fun transformBuffer(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer = serial {
        if (!StudioAudio.isCanonical(source)) throw StudioRenderException.CannotCreateBuffer()
        StudioRenderCore.transform(source, from, frames, rate, pitchCents, stretcher)
    }

    private fun result(frames: Int) =
        RenderResult(frames.toLong(), Math.round(frames.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt())

    /** Hidden temp sibling keeping the extension, atomically moved; any throw removes the temp. */
    private fun writeAtomically(dest: File, body: (File) -> Unit) {
        val dir = dest.absoluteFile.parentFile ?: throw StudioRenderException.CannotCreateBuffer()
        dir.mkdirs()
        val tmp = File(dir, ".studio-render-${UUID.randomUUID()}-${dest.name}")
        try {
            body(tmp)
            dest.delete() // replace an older render
            if (!tmp.renameTo(dest)) throw java.io.IOException("rename failed: ${tmp.name} -> ${dest.name}")
        } catch (t: Throwable) {
            tmp.delete()
            throw t
        }
    }

    companion object {
        /** Pure polyphonic mixdown (see [StudioAudio.mixPcm]). */
        fun mixPCM(buffers: List<PcmBuffer>): PcmBuffer = StudioAudio.mixPcm(buffers)
    }
}
