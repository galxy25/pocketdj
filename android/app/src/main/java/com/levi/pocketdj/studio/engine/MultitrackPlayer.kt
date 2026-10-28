package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
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
/** Result of a play request: only [NOTHING_TO_PLAY] deserves a user-facing message. */
enum class PlayOutcome { STARTED, SUPERSEDED, NOTHING_TO_PLAY, REFUSED, TOO_LARGE }

class MultitrackPlayer(
    private val loader: MultitrackClipLoader,
    private val sinkFactory: () -> AudioSink,
    private val scope: CoroutineScope,
    private val newContext: () -> MultitrackRenderContext = { MultitrackRenderContext() },
    private val reprimeDebounceMs: Long = REPRIME_DEBOUNCE_MS,
    private val onFocus: () -> Unit = {},
    private val onFocusRelease: () -> Unit = {},
    /** Record-to-master tap (STU-13). The default writes its temp WAVs to the JVM temp dir; the app passes the cache dir. */
    val recorder: MasterRecorder = MasterRecorder(),
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
    @Volatile private var primedLoopStartMs = 0
    @Volatile private var primedLoopEndMs = 0
    private var autoStop: Job? = null
    private var reprime: Job? = null

    /** Guards every publish/teardown of the sink + context + jobs: the UI (Main) and the re-prime / auto-stop jobs (any dispatcher) both reach them. */
    private val lock = Any()

    /** Decode + build the render context and start the sink. [fromMs] is a timeline seek (ignored while looping). */
    suspend fun play(arrangement: StudioArrangement, fromMs: Int = 0): Boolean =
        playOutcome(arrangement, fromMs) == PlayOutcome.STARTED

    /** Like [play] but distinguishes "superseded by a newer play/stop" (silent) from "no playable clips" (toast). */
    suspend fun playOutcome(arrangement: StudioArrangement, fromMs: Int = 0, record: Boolean? = null, quantized: Boolean? = null): PlayOutcome =
        // null = carry the active recording (a seek/loop restart must never silently drop the take); an explicit value wins.
        playInternal(arrangement, fromMs, fromReprime = false, record = record ?: recordWanted, quantized = quantized ?: recordQuantized)

    /** True while a master recording tap is active. */
    val isRecording: Boolean get() = recorder.isRecording

    /** Bumped ONLY when a recording ends because playback reached its NATURAL end (the view's single bake signal). */
    val recordingFinishedNonce: StateFlow<Int> get() = recorder.finishedNonce

    /** Hand the finished master capture to the baker (once). Call after [stop]. */
    fun consumeRecording(): MasterCapture? = recorder.consume()

    /** What the last explicit play asked for; a debounced re-prime restart carries it so a restart keeps recording. */
    @Volatile private var recordWanted = false
    @Volatile private var recordQuantized = false

    private suspend fun playInternal(arrangement: StudioArrangement, fromMs: Int, fromReprime: Boolean, record: Boolean = false, quantized: Boolean = false): PlayOutcome {
        if (!AudioFocusPolicy.gateStart("multitrack")) return PlayOutcome.REFUSED
        val gen = synchronized(lock) { stopInternal(keepReprime = fromReprime, reason = if (fromReprime) "reprime" else "restart"); generation.get() }
        val rate = StudioAudio.CANONICAL_RATE
        // The ONE planning path shared with ArrangerBouncer (WYSIWYG): decode once, window, warp, beat-snap.
        // Whole clips are held as float PCM on the Java heap: an over-long arrangement must degrade to a message, never an OOM crash.
        val clips = try {
            ArrangerClipPlan.build(arrangement.tracks, arrangement.bpm, arrangement.beatMatchEnabled, loader, rate) { gen != generation.get() }
        } catch (_: OutOfMemoryError) {
            synchronized(lock) { stopInternal(keepReprime = false, reason = "oom") }
            return PlayOutcome.TOO_LARGE
        } ?: return PlayOutcome.SUPERSEDED // stop-during-decode wins
        if (gen != generation.get()) return PlayOutcome.SUPERSEDED
        if (clips.isEmpty()) return PlayOutcome.NOTHING_TO_PLAY

        val isLoop = arrangement.loopEnabled && arrangement.loopEndMs > arrangement.loopStartMs
        val seekMs = fromMs.coerceIn(0, arrangement.lengthMs)
        val seekFrame = MultitrackRenderContext.msToFrames(seekMs, rate)
        val loopStart = MultitrackRenderContext.msToFrames(arrangement.loopStartMs, rate)
        val loopEnd = MultitrackRenderContext.msToFrames(arrangement.loopEndMs, rate)

        val ctx = newContext()
        ctx.load(clips, arrangement.tracks.size, if (isLoop) loopStart else seekFrame, isLoop, loopStart, loopEnd)
        synchronized(lock) {
            // Re-check under the same lock stop() takes: a Stop that landed since the last await must not be followed by a sink start.
            if (gen != generation.get()) { ctx.release(); return PlayOutcome.SUPERSEDED }
            context = ctx
            trackIds = arrangement.tracks.map { it.id }
            startOffsetMs = if (isLoop) 0 else seekMs
            looping = isLoop
            applyMix(arrangement.tracks, arrangement.bpm)
            applyMasterFX(arrangement)
            latest = arrangement
            primedLoopStartMs = if (isLoop) arrangement.loopStartMs else 0
            primedLoopEndMs = if (isLoop) arrangement.loopEndMs else 0
            primedSignature = bakeSignature(arrangement)

            onFocus()
            val s = sinkFactory()
            sink = s
            recordWanted = record; recordQuantized = quantized
            // begin() always discards the previous partial first (restart keeps recording, never leaks/concats).
            val tapped = recorder.begin(record, s.sampleRate, quantized) && record
            s.start(if (tapped) BlockRenderer { out, n -> ctx.render(out, n); recorder.tap(out, n) } else ctx)
            clock.latencyMs = (s.latencyFrames() * 1000L / rate).toInt()
            clock.start()
            _isPlaying.value = true
            _playingArrangementId.value = arrangement.id
            StudioDiag.play("multitrack", "user-play", started = true, detail = "id=${arrangement.id}")
            logD("play ${arrangement.id} from=${seekMs}ms loop=$isLoop clips=${clips.size}")
            if (!isLoop) scheduleAutoStop(gen, (arrangement.lengthMs - seekMs).coerceAtLeast(0))
        }
        return PlayOutcome.STARTED
    }

    fun stop(reason: String = "user-stop") { stopInternal(keepReprime = false, reason = reason); recordWanted = false; recordQuantized = false }

    private fun stopInternal(keepReprime: Boolean, naturalEnd: Boolean = false, reason: String = if (naturalEnd) "natural-end" else "user-stop") = synchronized(lock) {
        generation.incrementAndGet()
        autoStop?.cancel(); autoStop = null
        if (!keepReprime) { reprime?.cancel(); reprime = null }
        val s = sink
        sink = null
        runCatching { s?.stop(); s?.release() }
        recorder.end(naturalEnd)   // after the sink stopped: no more taps; natural end bumps the bake nonce
        context?.release()
        context = null
        trackIds = emptyList()
        primedSignature = null
        latest = null
        clock.stop()
        val was = _isPlaying.value
        _isPlaying.value = false
        _playingArrangementId.value = null
        if (was) { StudioDiag.stop("multitrack", reason); onFocusRelease() }
    }

    /** Current timeline position while playing (cursor), else null. */
    fun positionMs(arrangement: StudioArrangement): Int? {
        if (!_isPlaying.value) return null
        // The PRIMED loop state (what the audio is actually doing), not the edited arrangement's: a pending loop edit re-primes and re-anchors.
        return clock.timelineMs(startOffsetMs, arrangement.lengthMs, primedLoopStartMs, primedLoopEndMs, looping)
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
        synchronized(lock) {
            latest = arrangement
            applyMix(arrangement.tracks, arrangement.bpm)
            applyMasterFX(arrangement)
            // Loop on/off and region edits are NOT pushed into the running context (iOS restarts instead): the
            // auto-stop schedule, startOffsetMs and the clock anchor all depend on them, so they ride the re-prime.
            if (bakeSignature(arrangement) == primedSignature) { reprime?.cancel(); reprime = null; return }
            reprime?.cancel()
            reprime = scope.launch {
                delay(reprimeDebounceMs)
                val a = latest ?: return@launch
                val at = positionMs(a) ?: return@launch
                playInternal(a, at, fromReprime = true, record = recordWanted, quantized = recordQuantized)
            }
        }
    }

    private fun scheduleAutoStop(gen: Int, lengthMs: Int) {
        synchronized(lock) { autoStop?.cancel() }
        val job = scope.launch {
            delay(lengthMs + 350L + 120L)
            if (gen == generation.get()) { stopInternal(keepReprime = false, naturalEnd = true); recordWanted = false; recordQuantized = false }
        }
        synchronized(lock) { autoStop = job }
    }

    /** Everything that changes the baked clip buffers or their placement (NOT live-mix scalars). */
    data class BakeSignature(val beatMatch: Boolean, val bpmIfBeatMatch: Double, val tracks: List<TrackBake>, val loop: LoopBake = LoopBake())
    /** Loop on/off + region (region only matters while looping). Changing it restarts playback like iOS. */
    data class LoopBake(val on: Boolean = false, val startMs: Int = 0, val endMs: Int = 0)
    data class TrackBake(val id: String, val pitch: Double, val tempo: Double, val clips: List<List<Any?>>)

    companion object {
        const val REPRIME_DEBOUNCE_MS = 350L
        private const val TAG = "MultitrackPlayer"

        /** logcat line (no-op on the plain JVM where android.util.Log is not mocked). */
        internal fun logD(msg: String) { runCatching { android.util.Log.d(TAG, msg) } }

        fun bakeSignature(a: StudioArrangement) = BakeSignature(
            a.beatMatchEnabled, if (a.beatMatchEnabled) a.bpm else 0.0,
            tracks = a.tracks.map { t ->
                val s = t.strip.clamped()
                TrackBake(t.id, s.pitchSemitones, s.tempoRatio,
                    t.clips.map { listOf(it.id, it.startMs, it.durationMs, it.fileStartMs, if (a.beatMatchEnabled) it.grid?.bpm else null) })
            },
            loop = a.loopEnabled.let { on ->
                val usable = on && a.loopEndMs > a.loopStartMs
                if (usable) LoopBake(true, a.loopStartMs, a.loopEndMs) else LoopBake()
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
