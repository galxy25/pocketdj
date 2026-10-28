package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.PullSource
import com.levi.pocketdj.studio.audio.RenderGraph
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.Stretcher
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.audio.StudioRenderCore
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The live sample-audition chain (the AVAudioEngine sample player + timePitch/EQ/reverb/delay/comp of
 * iOS). The RAW decoded file is held; the edit is non-destructive: gain / filter / comp / reverb /
 * delay act live per block through [StudioRenderCore.SampleFx] (the SAME class the bake uses, so
 * audition == Save), rate/pitch are applied by re-fitting the buffer ([reshape], off the audio thread).
 * The window (trim) is a schedule decision read live by [pull], so tightening the out-point mid-audition
 * ends playback at the new mark.
 */
class SampleAuditionSource(
    private val raw: PcmBuffer,
    initial: StudioSampleEdit,
    private val stretcher: Stretcher = ResampleStretcher,
) : PullSource {
    private val lock = Any()
    private var shaped: PcmBuffer = raw
    private var shapedRate = 1.0
    private var shapedPitch = 0.0
    private var edit = initial.clamped()
    private var fx = StudioRenderCore.SampleFx(edit)
    private var cursor = 0L                       // frames into [shaped]
    @Volatile var loop = false
    private var sliceEnd = -1L                    // shaped frames; -1 = trim window
    private var tailLeft = 0L
    @Volatile var reachedEnd = false; private set
    @Volatile var finished = false; private set

    init { synchronized(lock) { rebuildShaped(edit, initialBuild = true) ; cursor = windowStartLocked() } }

    private val rate get() = shapedRate

    private fun rawStart(e: StudioSampleEdit): Long =
        min(StudioAudio.msToFrames(e.trimStartMs, StudioAudio.CANONICAL_RATE.toDouble()), raw.frames.toLong())

    private fun rawEnd(e: StudioSampleEdit): Long =
        if (e.trimEndMs > 0) min(StudioAudio.msToFrames(e.trimEndMs, StudioAudio.CANONICAL_RATE.toDouble()), raw.frames.toLong()) else raw.frames.toLong()

    private fun toShaped(rawFrames: Long): Long = min(shaped.frames.toLong(), Math.round(rawFrames / shapedRate))

    private fun windowStartLocked() = toShaped(rawStart(edit))
    private fun windowEndLocked() = max(windowStartLocked(), toShaped(rawEnd(edit)))

    /** The trim window in SOURCE seconds (end == duration when trimEndMs == 0). */
    fun windowSeconds(): Pair<Double, Double> = synchronized(lock) {
        val sr = StudioAudio.CANONICAL_RATE.toDouble()
        val s = rawStart(edit) / sr
        max(s, rawEnd(edit) / sr).let { s to it }
    }

    val durationSeconds: Double get() = raw.frames.toDouble() / StudioAudio.CANONICAL_RATE

    /** Playhead in SOURCE seconds (shaped frames x rate / 44.1 k). */
    fun playheadSeconds(): Double = synchronized(lock) { cursor * shapedRate / StudioAudio.CANONICAL_RATE }

    /** Seek (source seconds), clamped into the trim window. */
    fun seek(sec: Double) = synchronized(lock) {
        sliceEnd = -1
        val f = Math.round(sec * StudioAudio.CANONICAL_RATE / shapedRate)
        cursor = f.coerceIn(windowStartLocked(), windowEndLocked())
        reachedEnd = false; finished = false; tailLeft = 0
    }

    /** Rewind to the window head and re-arm (stop semantics). */
    fun rewind() = synchronized(lock) {
        sliceEnd = -1; cursor = windowStartLocked(); reachedEnd = false; finished = false; tailLeft = 0
    }

    /** Self-contained one-shot of [startMs, endMs) of the RAW file; never touches the trim window. False when zero frames. */
    fun playSlice(startMs: Int, endMs: Int): Boolean = synchronized(lock) {
        if (endMs <= startMs) return false
        val total = raw.frames.toLong()
        val a = min(total, StudioAudio.msToFrames(startMs, StudioAudio.CANONICAL_RATE.toDouble()))
        val b = min(total, StudioAudio.msToFrames(endMs, StudioAudio.CANONICAL_RATE.toDouble()))
        if (b - a <= 0) return false
        cursor = toShaped(a); sliceEnd = toShaped(b)
        if (sliceEnd <= cursor) return false
        reachedEnd = false; finished = false; tailLeft = 0
        true
    }

    val isSlice: Boolean get() = synchronized(lock) { sliceEnd >= 0 }

    /**
     * Apply an edit LIVE. Gain/filter/comp/FX rebuild the voicing chain (only when their fields changed);
     * trim moves the window; a rate/pitch change requires [reshape] (returns true when one is needed).
     */
    fun applyEdit(e: StudioSampleEdit): Boolean = synchronized(lock) {
        val c = e.clamped()
        val fxChanged = c.gainDb != edit.gainDb || c.filterAmt != edit.filterAmt || c.compWet != edit.compWet ||
            c.reverbWet != edit.reverbWet || c.delayWet != edit.delayWet
        edit = c
        if (fxChanged) fx = StudioRenderCore.SampleFx(c)
        if (reachedEnd && cursor < windowEndLocked()) { reachedEnd = false; finished = false; tailLeft = 0 }
        abs(c.rate - shapedRate) > 1e-9 || abs(c.pitchSemitones - shapedPitch) > 1e-9
    }

    /** Re-fit the buffer to the current edit's rate/pitch. Heavy: call off the audio/UI thread. Keeps the playhead's source position. */
    fun reshape() {
        val target = synchronized(lock) { edit }
        val rateNow = target.rate; val pitch = target.pitchSemitones
        val buf = fit(rateNow, pitch)
        synchronized(lock) {
            val srcPos = cursor * shapedRate
            val sliceSrc = if (sliceEnd >= 0) sliceEnd * shapedRate else -1.0
            shaped = buf; shapedRate = rateNow; shapedPitch = pitch
            cursor = min(buf.frames.toLong(), Math.round(srcPos / rateNow))
            sliceEnd = if (sliceSrc >= 0) min(buf.frames.toLong(), Math.round(sliceSrc / rateNow)) else -1
        }
    }

    private fun fit(rateNow: Double, pitch: Double): PcmBuffer {
        val neutral = abs(rateNow - 1.0) < 1e-9 && abs(pitch) < 1e-9
        if (neutral) return raw
        val out = max(1L, Math.round(raw.frames / rateNow)).toInt()
        return stretcher.stretch(raw, out, pitch)
    }

    private fun rebuildShaped(e: StudioSampleEdit, initialBuild: Boolean) {
        shaped = fit(e.rate, e.pitchSemitones); shapedRate = e.rate; shapedPitch = e.pitchSemitones
    }

    override fun pull(out: FloatArray, frames: Int): Int = synchronized(lock) {
        if (finished) return 0
        var produced = 0
        if (!reachedEnd) {
            val start = windowStartLocked()
            val end = if (sliceEnd >= 0) sliceEnd else windowEndLocked()
            val s = shaped.samples
            while (produced < frames) {
                if (cursor >= end) {
                    if (loop && sliceEnd < 0 && end > start) { cursor = start } else { reachedEnd = true; break }
                }
                val n = min((frames - produced).toLong(), end - cursor).toInt()
                if (n <= 0) { reachedEnd = true; break }
                System.arraycopy(s, (cursor * 2).toInt(), out, produced * 2, n * 2)
                cursor += n; produced += n
            }
            if (produced > 0) fx.process(out, 0, produced)
            if (reachedEnd) tailLeft = if (fx.isNeutral) 0 else StudioAudio.tailCapFrames
        }
        // FX tail rings out after the window ends (zeros through the chain) until below the floor or the cap.
        if (reachedEnd && produced < frames) {
            if (tailLeft <= 0) { finished = true; return produced }
            val n = min((frames - produced).toLong(), tailLeft).toInt()
            java.util.Arrays.fill(out, produced * 2, (produced + n) * 2, 0f)
            fx.process(out, produced, n)
            tailLeft -= n
            if (StudioAudio.isBelowFloor(out, produced * 2, n * 2) && !fx.delayPending()) tailLeft = 0
            produced += n
            if (tailLeft <= 0) finished = true
        }
        produced
    }
}

/**
 * Studio playback engine - sample audition + slice one-shot part (loops/pattern/instrument sections are
 * later Studio packages). One sample is loaded at a time. Starting audition consults [AudioFocusPolicy]
 * (never while the mic is capturing) and requests audio focus; the sink only runs while auditioning.
 */
class StudioEngine(
    private val sinkFactory: () -> AudioSink,
    private val stretcher: Stretcher,
    private val scope: CoroutineScope,
    private val focus: (() -> Boolean)? = null,
    private val focusRelease: (() -> Unit)? = null,
    private val diag: (String) -> Unit = {},
) {
    private val graph = RenderGraph()
    private var sink: AudioSink? = null
    private var source: SampleAuditionSource? = null
    private var tick: Job? = null
    private var reshapeJob: Job? = null
    private val generation = AtomicLong()

    private val _isPlayingSample = MutableStateFlow(false)
    val isPlayingSample: StateFlow<Boolean> = _isPlayingSample.asStateFlow()
    private val _loadedSampleId = MutableStateFlow<String?>(null)
    val loadedSampleId: StateFlow<String?> = _loadedSampleId.asStateFlow()
    private val _sampleLooping = MutableStateFlow(false)
    val sampleLooping: StateFlow<Boolean> = _sampleLooping.asStateFlow()
    /** Why the last play was refused ("mic-capture-active", "no-focus", "no-sample"); null after success. */
    @Volatile var lastRefusal: String? = null; private set

    fun loadSample(sample: StudioSample, canonical: PcmBuffer) {
        unloadSample()
        val src = SampleAuditionSource(canonical.toCanonicalIfNeeded(), sample.edit, stretcher)
        source = src
        graph.removeTrack(TRACK)
        graph.addTrack(TRACK, src)
        _loadedSampleId.value = sample.id
        _sampleLooping.value = false
        diag("loadSample ${sample.id} frames=${canonical.frames}")
    }

    private fun PcmBuffer.toCanonicalIfNeeded() = if (StudioAudio.isCanonical(this)) this else toCanonical()

    fun unloadSample() {
        stopSampleInternal()
        graph.removeTrack(TRACK)
        source = null
        reshapeJob?.cancel()
        _loadedSampleId.value = null
        _sampleLooping.value = false
        releaseSink()
    }

    fun playSample(): Boolean {
        val s = source ?: run { lastRefusal = "no-sample"; diag("playSample refused: no sample"); return false }
        if (!AudioFocusPolicy.mayStartPlayback()) { lastRefusal = "mic-capture-active"; diag("playSample refused: mic capture active"); return false }
        if (focus != null && !focus.invoke()) { lastRefusal = "no-focus"; diag("playSample refused: no audio focus"); return false }
        lastRefusal = null
        if (s.reachedEnd) s.rewind()
        startSink()
        _isPlayingSample.value = true
        startTick()
        return true
    }

    fun pauseSample() {
        if (!_isPlayingSample.value) return
        _isPlayingSample.value = false
        stopSinkSoon()
    }

    /** Stop and rewind to the trim window's start. */
    fun stopSample() { stopSampleInternal(); source?.rewind() }

    private fun stopSampleInternal() {
        _isPlayingSample.value = false
        tick?.cancel(); tick = null
        sink?.stop()
    }

    /** One-shot audition of a RAW-file window [startMs, endMs); never disturbs the trim window. */
    fun playSlice(startMs: Int, endMs: Int): Boolean {
        val s = source ?: return false
        if (!AudioFocusPolicy.mayStartPlayback()) { lastRefusal = "mic-capture-active"; return false }
        if (focus != null && !focus.invoke()) { lastRefusal = "no-focus"; return false }
        if (!s.playSlice(startMs, endMs)) return false
        lastRefusal = null
        startSink()
        _isPlayingSample.value = true
        startTick()
        return true
    }

    fun seekSample(sec: Double) { source?.seek(sec) }

    fun setSampleLoopAudition(on: Boolean) {
        source?.loop = on
        _sampleLooping.value = on
    }

    /** Apply an edit LIVE; a rate/pitch change re-fits the buffer on Default (latest wins). */
    fun applyEdit(edit: StudioSampleEdit) {
        val s = source ?: return
        if (s.applyEdit(edit)) {
            reshapeJob?.cancel()
            val gen = generation.incrementAndGet()
            reshapeJob = scope.launch(Dispatchers.Default) { if (gen == generation.get()) s.reshape() }
        }
    }

    fun samplePlayheadSeconds(): Double = source?.playheadSeconds() ?: 0.0
    fun sampleWindowSeconds(): Pair<Double, Double>? = source?.windowSeconds()
    val sampleDurationSeconds: Double get() = source?.durationSeconds ?: 0.0

    private fun startSink() {
        val k = sink ?: sinkFactory().also { sink = it }
        if (!k.isRendering) k.start(graph)
    }

    private fun stopSinkSoon() { sink?.stop() }

    private fun releaseSink() {
        sink?.let { runCatching { it.stop() }; runCatching { it.release() } }
        sink = null
        focusRelease?.invoke()
    }

    /** Ends the audition when the source reports the window (and tail) done - the render clock is the only truthful end signal. */
    private fun startTick() {
        tick?.cancel()
        tick = scope.launch {
            while (isActive) {
                val s = source
                if (s == null) break
                if (s.reachedEnd && !s.loop) _isPlayingSample.value = false
                if (s.finished) { sink?.stop(); break }
                delay(33)
            }
        }
    }

    fun release() {
        unloadSample()
        graph.release()
    }

    companion object { private const val TRACK = "sample" }
}
