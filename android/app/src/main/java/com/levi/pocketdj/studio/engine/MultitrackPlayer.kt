package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioTrack
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/** Decode / warp seam so the player's orchestration is testable without MediaCodec or the stretcher. */
interface MultitrackClipLoader {
    /** Canonical (44.1 kHz stereo) PCM for a clip file name, or null when missing/unreadable. */
    suspend fun decode(fileName: String): PcmBuffer?

    /** Warp/pitch the window [from, from+frames) offline (native stretch); null on failure (caller falls back to the raw window). */
    suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer?
}

class StudioClipLoader(private val store: StudioStore, private val render: StudioRender) : MultitrackClipLoader {
    override suspend fun decode(fileName: String): PcmBuffer? {
        val f = store.clipFile(fileName) ?: return null
        val pcm = runCatching { render.decodeBuffer(f.path) }.getOrNull() ?: return null
        return if (StudioAudio.isCanonical(pcm)) pcm else pcm.toCanonical()
    }

    override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? =
        runCatching { render.transformBuffer(source, from, frames, rate, pitchCents) }.getOrNull()
}

/**
 * Plays a [StudioArrangement] through ONE [MultitrackRenderContext] on one [AudioSink] (port of iOS
 * `MultitrackPlayer`). Decode + pre-bake (per-track pitch/tempo and Beat Match through the native stretch,
 * the non-destructive `fileStartMs` window) happen off the render thread; the render callback only sums.
 * A fresh sink pass per Play; [playGeneration] guards every await so a stop() or a second concurrent
 * play() during decode wins (at most one pass runs). Live mix / master FX are pushed by track ID so a
 * delete/duplicate mid-play never shifts another track's mix; changes that alter the baked buffers
 * trigger a debounced re-prime ([REPRIME_DEBOUNCE_MS]).
 */
class MultitrackPlayer(
    private val loader: MultitrackClipLoader,
    private val sinkFactory: () -> AudioSink,
    private val scope: CoroutineScope,
    private val newContext: () -> MultitrackRenderContext = { MultitrackRenderContext() },
    private val reprimeDebounceMs: Long = REPRIME_DEBOUNCE_MS,
    private val onFocus: () -> Unit = {},
    private val onFocusRelease: () -> Unit = {},
) {
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying
    private val _playingArrangementId = MutableStateFlow<String?>(null)
    val playingArrangementId: StateFlow<String?> = _playingArrangementId

    /** The timeline ms playback STARTED from (a ruler seek); the view adds it to the clock. */
    @Volatile var startOffsetMs = 0
        private set

    /** Non-observable playhead clock (sampled per frame by the view; never snapshot state). */
    val clock = MultitrackClock()

    private val generation = AtomicInteger(0)
    /** Bumped by every stop(); play() snapshots it after its own stop() and bails if it changed across a decode await. */
    val playGeneration: Int get() = generation.get()

    @Volatile private var context: MultitrackRenderContext? = null
    @Volatile private var sink: AudioSink? = null
    @Volatile private var trackIds: List<String> = emptyList()
    @Volatile private var primedSignature: BakeSignature? = null
    @Volatile private var latest: StudioArrangement? = null
    @Volatile private var looping = false
    private var autoStop: Job? = null
    private var reprime: Job? = null

    /** Decode + build the render context and start the sink. [fromMs] is a timeline seek (ignored while looping). */
    suspend fun play(arrangement: StudioArrangement, fromMs: Int = 0): Boolean = playInternal(arrangement, fromMs, fromReprime = false)

    private suspend fun playInternal(arrangement: StudioArrangement, fromMs: Int, fromReprime: Boolean): Boolean {
        stopInternal(keepReprime = fromReprime)
        val gen = generation.get()
        val rate = StudioAudio.CANONICAL_RATE
        val clips = ArrayList<MultitrackRenderContext.Clip>()
        val beatMatch = arrangement.beatMatchEnabled
        val masterBpm = arrangement.bpm
        val beatFrames = if (masterBpm > 0) 60.0 / masterBpm * rate else 0.0
        for ((ti, track) in arrangement.tracks.withIndex()) {
            val strip = track.strip.clamped()
            for (clip in track.clips) {
                val buf = loader.decode(clip.fileName)
                if (gen != generation.get()) return false // stop-during-decode wins
                if (buf == null || buf.frames <= 0) continue
                val r = ArrangerBeatMatch.rate(clip.grid?.bpm ?: 0.0, masterBpm, strip.tempoRatio, beatMatch)
                val pitchCents = strip.pitchSemitones * 100
                val needsBake = Math.abs(r - 1) > 0.0005 || Math.abs(pitchCents) > 0.5
                val startFrame = ArrangerBeatMatch.snappedStartFrame(
                    MultitrackRenderContext.msToFrames(clip.startMs, rate), beatFrames, beatMatch)
                val window = clipWindow(buf.frames, clip.fileStartMs, clip.durationMs, rate)
                if (window.frameLength <= 0) continue
                val warped = if (needsBake) loader.transform(buf, window.srcStart.toLong(), window.frameLength.toLong(), r, pitchCents) else null
                if (gen != generation.get()) return false
                if (warped != null && warped.frames > 0) {
                    clips += MultitrackRenderContext.Clip(ti, startFrame, warped.frames, 0, warped.toStereo().samples)
                } else {
                    clips += MultitrackRenderContext.Clip(ti, startFrame, window.frameLength, window.srcStart, buf.toStereo().samples)
                }
            }
        }
        if (clips.isEmpty() || gen != generation.get()) return false

        val isLoop = arrangement.loopEnabled && arrangement.loopEndMs > arrangement.loopStartMs
        val seekMs = fromMs.coerceIn(0, arrangement.lengthMs)
        val seekFrame = MultitrackRenderContext.msToFrames(seekMs, rate)
        val loopStart = MultitrackRenderContext.msToFrames(arrangement.loopStartMs, rate)
        val loopEnd = MultitrackRenderContext.msToFrames(arrangement.loopEndMs, rate)

        val ctx = newContext()
        ctx.load(clips, arrangement.tracks.size, if (isLoop) loopStart else seekFrame, isLoop, loopStart, loopEnd)
        context = ctx
        trackIds = arrangement.tracks.map { it.id }
        startOffsetMs = if (isLoop) 0 else seekMs
        looping = isLoop
        applyMix(arrangement.tracks, arrangement.bpm)
        applyMasterFX(arrangement)
        latest = arrangement
        primedSignature = bakeSignature(arrangement)

        onFocus()
        val s = sinkFactory()
        sink = s
        s.start(ctx)
        clock.latencyMs = (s.latencyFrames() * 1000L / rate).toInt()
        clock.start()
        _isPlaying.value = true
        _playingArrangementId.value = arrangement.id
        logD("play ${arrangement.id} from=${seekMs}ms loop=$isLoop clips=${clips.size}")
        if (!isLoop) scheduleAutoStop(gen, (arrangement.lengthMs - seekMs).coerceAtLeast(0))
        return true
    }

    fun stop() = stopInternal(keepReprime = false)

    private fun stopInternal(keepReprime: Boolean) {
        generation.incrementAndGet()
        autoStop?.cancel(); autoStop = null
        if (!keepReprime) { reprime?.cancel(); reprime = null }
        val s = sink
        sink = null
        runCatching { s?.stop(); s?.release() }
        context?.release()
        context = null
        trackIds = emptyList()
        primedSignature = null
        latest = null
        clock.stop()
        val was = _isPlaying.value
        _isPlaying.value = false
        _playingArrangementId.value = null
        if (was) onFocusRelease()
    }

    /** Current timeline position while playing (cursor), else null. */
    fun positionMs(arrangement: StudioArrangement): Int? {
        if (!_isPlaying.value) return null
        return clock.timelineMs(startOffsetMs, arrangement.lengthMs, arrangement.loopStartMs, arrangement.loopEndMs, looping)
    }

    /** Recompute each track's audible gain + pan and live strip FX, MATCHED BY TRACK ID (mid-play delete safe). */
    fun applyMix(tracks: List<StudioTrack>, bpm: Double) {
        val ctx = context ?: return
        val ids = trackIds
        val anySolo = tracks.any { it.soloed }
        for (t in tracks) {
            val i = ids.indexOf(t.id)
            if (i < 0) continue
            ctx.setTrackMix(i, MultitrackRenderContext.audibleGain(t.gainDb, t.muted, t.soloed, anySolo), t.pan.toFloat())
            ctx.setTrackFx(i, t.strip.clamped().toKernelParams(bpm))
        }
        logD("applyMix tracks=${tracks.size} anySolo=$anySolo")
    }

    /** Master FX + master gain, live. allowFreeze=false: the Tracks grid has no Freezer, a stale persisted flag must not silence the mix. */
    fun applyMasterFX(arrangement: StudioArrangement) {
        context?.setMasterFx(arrangement.masterFX.toKernelParams(arrangement.bpm, allowFreeze = false))
    }

    /**
     * Push every live change from an edited arrangement: mix, master FX, loop region, and schedule a
     * debounced re-prime when something baked into the clip buffers changed (pitch / tempo / Beat Match /
     * clip set). The re-prime restarts from the current playhead.
     */
    fun onArrangementChanged(arrangement: StudioArrangement) {
        if (!_isPlaying.value || _playingArrangementId.value != arrangement.id) return
        latest = arrangement
        applyMix(arrangement.tracks, arrangement.bpm)
        applyMasterFX(arrangement)
        val isLoop = arrangement.loopEnabled && arrangement.loopEndMs > arrangement.loopStartMs
        looping = isLoop
        context?.setLoop(isLoop,
            MultitrackRenderContext.msToFrames(arrangement.loopStartMs), MultitrackRenderContext.msToFrames(arrangement.loopEndMs))
        if (bakeSignature(arrangement) == primedSignature) { reprime?.cancel(); reprime = null; return }
        reprime?.cancel()
        reprime = scope.launch {
            delay(reprimeDebounceMs)
            val a = latest ?: return@launch
            val at = positionMs(a) ?: return@launch
            playInternal(a, at, fromReprime = true)
        }
    }

    private fun scheduleAutoStop(gen: Int, lengthMs: Int) {
        autoStop?.cancel()
        autoStop = scope.launch {
            delay(lengthMs + 350L + 120L)
            if (gen == generation.get()) stop()
        }
    }

    /** Everything that changes the baked clip buffers or their placement (NOT live-mix scalars). */
    data class BakeSignature(val beatMatch: Boolean, val bpmIfBeatMatch: Double, val tracks: List<TrackBake>)
    data class TrackBake(val id: String, val pitch: Double, val tempo: Double, val clips: List<List<Any?>>)

    companion object {
        const val REPRIME_DEBOUNCE_MS = 350L
        private const val TAG = "MultitrackPlayer"

        /** logcat line (no-op on the plain JVM where android.util.Log is not mocked). */
        internal fun logD(msg: String) { runCatching { android.util.Log.d(TAG, msg) } }

        fun bakeSignature(a: StudioArrangement) = BakeSignature(
            a.beatMatchEnabled, if (a.beatMatchEnabled) a.bpm else 0.0,
            a.tracks.map { t ->
                val s = t.strip.clamped()
                TrackBake(t.id, s.pitchSemitones, s.tempoRatio,
                    t.clips.map { listOf(it.id, it.startMs, it.durationMs, it.fileStartMs, it.grid?.bpm) })
            },
        )

        class ClipWindow(val srcStart: Int, val frameLength: Int)

        /** The non-destructive scissor window: file frames [srcStart, srcStart+frameLength), clamped to the decoded buffer. */
        fun clipWindow(bufFrames: Int, fileStartMs: Int, durationMs: Int, rate: Int): ClipWindow {
            val srcStart = MultitrackRenderContext.msToFrames(fileStartMs, rate).coerceIn(0, bufFrames)
            val avail = bufFrames - srcStart
            val dur = if (durationMs > 0) MultitrackRenderContext.msToFrames(durationMs, rate) else avail
            return ClipWindow(srcStart, dur.coerceAtMost(avail).coerceAtLeast(0))
        }
    }
}
