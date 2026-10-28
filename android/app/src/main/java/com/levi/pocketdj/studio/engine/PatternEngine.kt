package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.PullSource
import com.levi.pocketdj.studio.audio.RenderGraph
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioPattern
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.max
import kotlin.math.min

/** One row's loaded voice: the live mirror of its step arrays plus its pre-baked buffers. */
internal class PatternRowVoice(
    val steps: MutableList<Boolean>,
    val loopSteps: MutableList<Boolean>,
    val stepSpans: MutableList<Int>,
    val buffer: PcmBuffer,
    val spanBuffers: Map<Int, PcmBuffer>,
) {
    class Hit(val frame: Long, val buf: PcmBuffer, val loops: Boolean)

    /** Scheduled triggers, time-ordered (slots are armed monotonically). */
    val pending = ArrayDeque<Hit>()
    @Volatile var gain: Float = 1f
    var voice: PcmBuffer? = null
    var voiceLoops = false
    /** Frame cursor into [voice]; reset by every trigger (mono choke). */
    var cursor = 0
}

/**
 * The pattern scheduler: a [PullSource] that triggers pre-rendered row buffers at sample-accurate frame positions
 * against a single pattern-start anchor (frame 0 = step 0 of pass 0). It is the Android analogue of the iOS
 * `AVAudioPlayerNode.scheduleBuffer(at:, options:)` scheme, with the same semantics:
 *
 *  - step time = anchor + slot * [PatternMath.stepFrames] (integer arithmetic, monotonic across re-arm);
 *  - a rolling [PatternMath.HORIZON_SLOTS] (4-bar) horizon is armed ahead of the render cursor by the pull itself
 *    (`armSlot`), so a 100-bar pattern schedules a few bars at a time, never the whole song;
 *  - MONO CHOKE (`.interrupts`): a trigger on a row cuts the ringing previous hit of that row;
 *  - LOOP steps (`.loops`): the hit repeats until the row's next trigger takes over at its own frame;
 *  - SPAN steps use the pre-stretched buffer for that span (natural fallback when missing);
 *  - slot -> step goes through [PatternMath.mappedStep] (startStep offset + infinity loop window).
 *
 * All state is guarded by one lock; the audio thread only holds it for the arming + mixing of a block.
 */
class PatternScheduler : PullSource {
    private val lock = Any()
    private var rows: List<PatternRowVoice?> = emptyList()
    private var bpm = 120.0
    private var stepCount = StudioPattern.DEFAULT_STEP_COUNT
    private var startStep = 0
    private var loopEnabled = false
    private var loopBars = 2
    private var frameCursor = 0L
    private var armedThroughSlot = 0
    @Volatile private var runningFlag = false
    @Volatile private var framesNow = 0L

    /** Slots armed so far (the horizon re-arm count; asserted by tests). */
    @Volatile var armedSlotCount = 0; private set

    /** Fired (under the lock, audio thread) per horizon re-arm with the slot range; the host must only enqueue/rate-limit. */
    @Volatile var onArmed: ((from: Int, through: Int) -> Unit)? = null

    val running: Boolean get() = runningFlag

    /** Frames pulled since the pattern (re)started: the render clock the highlight clock reads. */
    val renderedFrames: Long get() = framesNow

    val patternBpm: Double get() = synchronized(lock) { bpm }
    val patternStepCount: Int get() = synchronized(lock) { stepCount }

    /**
     * Install a pattern's rows. [buffers] maps ROW INDEX -> the row's pre-baked canonical PCM; rows with no usable
     * buffer (missing target, zero frames, non-canonical) are skipped - never a throw. Rows beyond
     * [PatternMath.MAX_PATTERN_ROWS] are dropped. Returns the row indices that will sound (have a buffer).
     */
    fun load(
        pattern: StudioPattern, buffers: Map<Int, PcmBuffer>, spanBuffers: Map<Int, Map<Int, PcmBuffer>> = emptyMap(),
        startStep: Int = 0, loopEnabled: Boolean = false, loopBars: Int = 2,
    ): List<Int> = synchronized(lock) {
        stopLocked()
        val src = pattern.rows.take(PatternMath.MAX_PATTERN_ROWS)
        bpm = if (pattern.bpm > 0) pattern.bpm else 120.0
        stepCount = max(1, pattern.stepCount)
        this.startStep = min(max(0, startStep), stepCount - 1)
        this.loopEnabled = loopEnabled
        this.loopBars = max(1, loopBars)
        val loaded = ArrayList<PatternRowVoice?>(src.size)
        val sounding = ArrayList<Int>()
        src.forEachIndexed { i, row ->
            val buf = buffers[i]
            if (buf == null || buf.frames <= 0 || !StudioAudio.isCanonical(buf)) { loaded += null; return@forEachIndexed }
            val ok = spanBuffers[i].orEmpty().filter { it.value.frames > 0 && StudioAudio.isCanonical(it.value) }
            loaded += PatternRowVoice(row.steps.toMutableList(), row.loopSteps.toMutableList(), row.stepSpans.toMutableList(), buf, ok)
                .also { it.gain = StudioAudio.gainMultiplier(row.gainDb) }
            sounding += i
        }
        rows = loaded
        sounding
    }

    /** Any loaded row that would actually sound (has a buffer AND at least one on-step)? */
    val hasContent: Boolean get() = synchronized(lock) { rows.any { it != null && it.steps.contains(true) } }

    /** (Re)anchor at the top: frame 0 = step 0 of pass 0; arms the first horizon. Also the recovery restart. */
    fun restartFromTop(): Boolean = synchronized(lock) {
        if (rows.none { it != null && it.steps.contains(true) }) return false
        resetLocked()
        runningFlag = true
        armHorizonLocked(0)
        true
    }

    fun stop() = synchronized(lock) { stopLocked() }

    private fun stopLocked() {
        runningFlag = false
        resetLocked()
    }

    private fun resetLocked() {
        frameCursor = 0; framesNow = 0; armedThroughSlot = 0
        for (r in rows) r?.let { it.pending.clear(); it.voice = null; it.cursor = 0 }
    }

    fun setRowGain(row: Int, db: Double) = synchronized(lock) { rows.getOrNull(row)?.gain = StudioAudio.gainMultiplier(db) }

    /** Move the playhead: while running this is a live seek that re-anchors from the top of the new start. */
    fun setStartStep(step: Int): Boolean = synchronized(lock) {
        startStep = min(max(0, step), max(0, stepCount - 1))
        if (runningFlag) restartLocked() else true
    }

    fun setLoop(enabled: Boolean, bars: Int): Boolean = synchronized(lock) {
        loopEnabled = enabled; loopBars = max(1, bars)
        if (runningFlag) restartLocked() else true
    }

    private fun restartLocked(): Boolean {
        resetLocked(); runningFlag = true; armHorizonLocked(0); return true
    }

    /**
     * Live step edit: mirror a step on/off into the RUNNING pattern. Off also clears the live loop/span mirror
     * (matching `StudioStore.setPatternStep`). Bounds-guarded; a no-op when the row/col isn't loaded. Matches iOS: only the
     * arrays change, so an edit is heard when the rolling horizon next arms that slot (hits already armed keep their schedule).
     */
    fun updateLiveStep(row: Int, col: Int, on: Boolean) = synchronized(lock) {
        val r = rows.getOrNull(row) ?: return@synchronized
        if (col !in r.steps.indices) return@synchronized
        r.steps[col] = on
        if (!on) {
            if (col in r.loopSteps.indices) r.loopSteps[col] = false
            if (col in r.stepSpans.indices) r.stepSpans[col] = 0
        }
    }

    fun updateLiveStepLoop(row: Int, col: Int, loop: Boolean) = synchronized(lock) {
        val r = rows.getOrNull(row) ?: return@synchronized
        if (col !in r.loopSteps.indices) return@synchronized
        r.loopSteps[col] = loop
    }

    /** Test seam: the row voice's current frame cursor (null = silent / unloaded). Choke resets it to 0. */
    fun rowFrameCursor(row: Int): Int? = synchronized(lock) { rows.getOrNull(row)?.takeIf { it.voice != null }?.cursor }

    /** Test seam: absolute frames of the hits armed (not yet rendered) for [row]. */
    fun pendingHitFrames(row: Int): List<Long> = synchronized(lock) { rows.getOrNull(row)?.pending?.map { it.frame } ?: emptyList() }

    // ---- arming -----------------------------------------------------------------------------------------

    private fun armHorizonLocked(throughFrame: Long) {
        val stepF = PatternMath.stepFrames(bpm)
        val target = (throughFrame / stepF).toInt() + PatternMath.HORIZON_SLOTS
        val from = armedThroughSlot
        while (armedThroughSlot <= target) { armSlot(armedThroughSlot); armedThroughSlot++ }
        if (armedThroughSlot > from) onArmed?.invoke(from, armedThroughSlot - 1)
    }

    /**
     * Schedule ONE playback slot (a monotonic step index since the shared start) onto whichever rows fire on the
     * PATTERN step it maps to. The slot -> step mapping applies the playhead start offset and the loop window.
     */
    private fun armSlot(slot: Int) {
        armedSlotCount++
        for (r in rows) if (r != null) armSlotRow(r, slot)
    }

    private fun armSlotRow(r: PatternRowVoice, slot: Int) {
        val col = PatternMath.mappedStep(slot, startStep, loopEnabled, loopBars, stepCount)
        if (r.steps.getOrNull(col) != true) return
        val span = r.stepSpans.getOrNull(col) ?: 0
        val buf = if (span > 0) (r.spanBuffers[span] ?: r.buffer) else r.buffer
        val loops = r.loopSteps.getOrNull(col) == true
        r.pending.addLast(PatternRowVoice.Hit(PatternMath.stepTime(0, slot, bpm), buf, loops))
    }

    // ---- render -----------------------------------------------------------------------------------------

    override fun pull(out: FloatArray, frames: Int): Int = synchronized(lock) {
        if (!runningFlag || frames <= 0) return 0
        val start = frameCursor
        val end = start + frames
        armHorizonLocked(end)
        for (r in rows) if (r != null) mixRow(r, out, start, frames)
        frameCursor = end
        framesNow = end
        frames
    }

    private fun mixRow(r: PatternRowVoice, out: FloatArray, blockStart: Long, frames: Int) {
        val blockEnd = blockStart + frames
        var pos = blockStart
        while (true) {
            val next = r.pending.firstOrNull()
            val stop = if (next != null && next.frame < blockEnd) max(next.frame, pos) else blockEnd
            if (stop > pos) { mixVoice(r, out, (pos - blockStart).toInt(), (stop - pos).toInt()); pos = stop }
            if (next == null || next.frame >= blockEnd) break
            r.pending.removeFirst()
            r.voice = next.buf; r.voiceLoops = next.loops; r.cursor = 0     // .interrupts: retrigger cuts the ringing hit
        }
    }

    private fun mixVoice(r: PatternRowVoice, out: FloatArray, outFrame: Int, n: Int) {
        val v = r.voice ?: return
        val s = v.samples
        val total = v.frames
        val g = r.gain
        var done = 0
        while (done < n) {
            if (r.cursor >= total) {
                if (r.voiceLoops && total > 0) r.cursor = 0 else { r.voice = null; return }
            }
            val m = min(n - done, total - r.cursor)
            var si = r.cursor * 2
            var oi = (outFrame + done) * 2
            for (i in 0 until m * 2) out[oi + i] += s[si + i] * g
            r.cursor += m; done += m
        }
    }
}

/**
 * The sequencer's playback engine (iOS StudioEngine "pattern playback" duty). Owns one [RenderGraph] + sink, the
 * [PatternScheduler] and the [PatternClock]. Starting consults [AudioFocusPolicy] (never while the mic captures)
 * and the host's focus/park hooks (one audible owner). A pattern with zero sounding content REFUSES to play.
 */
class PatternEngine(
    private val sinkFactory: () -> AudioSink,
    private val focus: (() -> Boolean)? = null,
    private val focusRelease: (() -> Unit)? = null,
    private val diag: (String) -> Unit = {},
) {
    private val graph = RenderGraph()
    private var sink: AudioSink? = null
    val scheduler = PatternScheduler()
    val clock = PatternClock(renderedFrames = { scheduler.renderedFrames }, latencyFrames = { sink?.latencyFrames()?.toLong() ?: 0L })

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    private val _loadedPatternId = MutableStateFlow<String?>(null)
    val loadedPatternId: StateFlow<String?> = _loadedPatternId.asStateFlow()
    private val _soloedRow = MutableStateFlow<Int?>(null)
    val soloedRow: StateFlow<Int?> = _soloedRow.asStateFlow()
    /** Why the last start was refused ("no-content", "mic-capture-active", "no-focus", "output-unavailable"). */
    @Volatile var lastRefusal: String? = null; private set

    private var trackAdded = false

    /** Latched interruption park: set by [parkForInterruption], cleared by an explicit start/stop/load. */
    @Volatile var parkedForInterruption = false; private set
    private var lastArmDiagNs = 0L

    init {
        scheduler.onArmed = { from, through ->
            val now = System.nanoTime()
            if (now - lastArmDiagNs > 1_000_000_000L) {      // rate-limited: never log per audio block
                lastArmDiagNs = now
                diag("armed slots $from..$through (count=${scheduler.armedSlotCount})")
            }
        }
    }

    /**
     * Transient audio-focus loss (notification, nav prompt, call ring): silence the sink but KEEP the loaded pattern
     * and the focus request so [resumeFromInterruption] can restart from the top on AUDIOFOCUS_GAIN (iOS parity:
     * park on .began, resume on .ended+shouldResume).
     */
    fun parkForInterruption() {
        if (!_isPlaying.value) return
        parkedForInterruption = true
        scheduler.stop()
        clock.running = false
        _isPlaying.value = false
        _soloedRow.value = null
        sink?.stop()
        diag("pattern parked (interruption)")
    }

    /** Restart from the top iff parked and still loaded. Returns whether a restart happened. */
    fun resumeFromInterruption(): Boolean {
        if (!parkedForInterruption) return false
        parkedForInterruption = false
        if (_loadedPatternId.value == null) return false
        val ok = startPattern()
        diag("pattern resume after interruption ok=$ok")
        return ok
    }

    /** Swaps only while stopped (a running pattern is stopped first). */
    fun loadPattern(
        pattern: StudioPattern, buffers: Map<Int, PcmBuffer>, spanBuffers: Map<Int, Map<Int, PcmBuffer>> = emptyMap(),
        soloedRow: Int? = null, startStep: Int = 0, loopEnabled: Boolean = false, loopBars: Int = 2,
    ) {
        if (_isPlaying.value) stopPattern()
        parkedForInterruption = false
        if (pattern.rows.size > PatternMath.MAX_PATTERN_ROWS) diag("loadPattern ${pattern.id}: rows capped at ${PatternMath.MAX_PATTERN_ROWS} (had ${pattern.rows.size})")
        val sounding = scheduler.load(pattern, buffers, spanBuffers, startStep, loopEnabled, loopBars)
        clock.bpm = scheduler.patternBpm; clock.stepCount = scheduler.patternStepCount
        clock.startStep = min(max(0, startStep), scheduler.patternStepCount - 1)
        clock.loopEnabled = loopEnabled; clock.loopBars = max(1, loopBars)
        _loadedPatternId.value = pattern.id
        _soloedRow.value = soloedRow
        diag("loadPattern ${pattern.id} bpm=${scheduler.patternBpm} rows=${min(pattern.rows.size, PatternMath.MAX_PATTERN_ROWS)} sounding=${sounding.size} solo=${soloedRow ?: "-"}")
    }

    val hasContent: Boolean get() = scheduler.hasContent

    /** Start the loaded pattern from the top of the bar. False (and [lastRefusal]) when it cannot start. */
    fun startPattern(): Boolean {
        parkedForInterruption = false
        if (_loadedPatternId.value == null) { lastRefusal = "no-pattern"; return false }
        if (!scheduler.hasContent) { lastRefusal = "no-content"; diag("startPattern REFUSED: no sounding steps with buffers"); return false }
        if (!AudioFocusPolicy.gateStart("pattern")) { lastRefusal = "mic-capture-active"; diag("startPattern refused: mic capture active"); return false }
        if (focus != null && !focus.invoke()) { lastRefusal = "no-focus"; diag("startPattern refused: no audio focus"); return false }
        if (!scheduler.restartFromTop()) { lastRefusal = "no-content"; return false }
        if (!trackAdded) { graph.addTrack(TRACK, scheduler); trackAdded = true }
        val k = sink ?: sinkFactory().also { sink = it }
        if (!k.isRendering) k.start(graph)
        if (!k.isRendering) {
            scheduler.stop(); lastRefusal = "output-unavailable"; diag("startPattern: output failed to open")
            focusRelease?.invoke()
            return false
        }
        lastRefusal = null
        clock.running = true
        _isPlaying.value = true
        diag("pattern start bpm=${scheduler.patternBpm} from=${clock.startStep} loop=${if (clock.loopEnabled) clock.loopBars else 0}")
        return true
    }

    /** Stop (rows keep their buffers - start replays from the top). Read [clock] BEFORE this to park the cursor. */
    fun stopPattern() {
        val was = _isPlaying.value
        val wasParked = parkedForInterruption
        parkedForInterruption = false
        scheduler.stop()
        clock.running = false
        _isPlaying.value = false
        _soloedRow.value = null
        if (was) { sink?.stop(); focusRelease?.invoke(); diag("stopPattern") }
        else if (wasParked) { focusRelease?.invoke(); diag("stopPattern (parked)") }
    }

    /** Live row-gain tweak while a pattern plays (no schedule impact). */
    fun setPatternRowGain(row: Int, gainDb: Double) = scheduler.setRowGain(row, gainDb)

    fun setPatternStartStep(step: Int) {
        if (_loadedPatternId.value == null) return
        scheduler.setStartStep(step)
        clock.startStep = min(max(0, step), max(0, scheduler.patternStepCount - 1))
    }

    fun setPatternLoop(enabled: Boolean, bars: Int) {
        if (_loadedPatternId.value == null) return
        scheduler.setLoop(enabled, bars)
        clock.loopEnabled = enabled; clock.loopBars = max(1, bars)
    }

    fun updateLiveStep(row: Int, col: Int, on: Boolean) = scheduler.updateLiveStep(row, col, on)
    fun updateLiveStepLoop(row: Int, col: Int, loop: Boolean) = scheduler.updateLiveStepLoop(row, col, loop)

    fun release() {
        stopPattern()
        sink?.let { runCatching { it.release() } }
        sink = null
        graph.release()
    }

    companion object { private const val TRACK = "pattern" }
}
