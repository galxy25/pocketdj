package com.levi.pocketdj.studio.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.random.Random

/**
 * Arpeggiator (iOS `ArpeggiatorEngine.swift`): pure timing/order math ([ArpPattern]) plus the thin transport
 * ([ArpeggiatorEngine]) that sleeps-and-strikes through an [ArpHost]. The math is JVM-pinned; the transport is
 * tested on a virtual clock.
 */

/** Playback order of the recorded note set. `exclusive`/`inclusive` are the up-down variants that EXCLUDE/INCLUDE the repeated endpoints. */
enum class ArpOrder(val raw: String) {
    UP("up"), DOWN("down"), EXCLUSIVE("exclusive"), INCLUSIVE("inclusive"), ORDER("order"), RANDOM("random");
    companion object { fun fromRaw(raw: String): ArpOrder? = entries.firstOrNull { it.raw == raw } }
}

/** Step duration as a note value. [denominator] (4 = quarter … 32 = 1/32) is what persists — changing it would re-time saved knobs. */
enum class ArpStepLength(val denominator: Int) {
    THIRTYSECOND(32), SIXTEENTH(16), EIGHTH(8), QUARTER(4);
    companion object { fun fromDenominator(d: Int): ArpStepLength? = entries.firstOrNull { it.denominator == d } }
}

/** The arp's knob state. `latch` ON loops the cycle until toggled off; OFF plays exactly one full cycle. */
data class ArpSettings(
    val order: ArpOrder = ArpOrder.UP,
    val length: ArpStepLength = ArpStepLength.SIXTEENTH,
    val octaves: Int = 1,
    val swingPct: Double = 50.0,
    val latch: Boolean = true,
) {
    companion object {
        /** Knob state from PERSISTED raw values; unknown/wild values degrade to the defaults (never crash the arp). */
        fun fromPersisted(order: String, length: Int, octaves: Int, swing: Double, latch: Boolean) = ArpSettings(
            order = ArpOrder.fromRaw(order) ?: ArpOrder.UP,
            length = ArpStepLength.fromDenominator(length) ?: ArpStepLength.SIXTEENTH,
            octaves = octaves.coerceIn(1, 4),
            swingPct = if (swing.isFinite()) swing.coerceIn(50.0, 75.0) else 50.0,
            latch = latch,
        )
    }
}

object ArpPattern {
    /** Ceiling for any onset the schedule can produce (shared with the replay clock). */
    const val MAX_ONSET_MS = 86_400_000

    /** Recorded notes shifted up 12k for k in 0 until octaves; insertion order kept within each octave; out-of-range and duplicates dropped. */
    fun pool(notes: List<Int>, octaves: Int): List<Int> {
        val seen = HashSet<Int>()
        val out = ArrayList<Int>()
        for (k in 0 until octaves.coerceIn(1, 4)) for (n in notes) {
            val s = n + 12 * k
            if (s in 0..127 && seen.add(s)) out.add(s)
        }
        return out
    }

    /** One full cycle. Deterministic except RANDOM, which draws each slot uniformly from the pool through the injected [rng]. */
    fun cycle(notes: List<Int>, order: ArpOrder, octaves: Int, rng: Random): List<Int> {
        val p = pool(notes, octaves)
        if (p.isEmpty()) return emptyList()
        val asc = p.sorted()
        return when (order) {
            ArpOrder.UP -> asc
            ArpOrder.DOWN -> asc.reversed()
            // [a,b,c] -> a b c b (period 2n-2); n==2 -> a b; n==1 -> a
            ArpOrder.EXCLUSIVE -> if (asc.size > 2) asc + asc.subList(1, asc.size - 1).reversed() else asc
            // [a,b,c] -> a b c c b a (period 2n)
            ArpOrder.INCLUSIVE -> asc + asc.reversed()
            ArpOrder.ORDER -> p
            ArpOrder.RANDOM -> List(p.size) { p[rng.nextInt(p.size)] }
        }
    }

    /** One step's duration in ms at [bpm]; a non-finite/non-positive bpm degrades to 120. */
    fun stepMs(length: ArpStepLength, bpm: Double): Double {
        val b = if (bpm.isFinite() && bpm > 0) bpm else 120.0
        return 60_000.0 / b * 4.0 / length.denominator
    }

    /** Onset of step [step]: onsetMs(k) = (k/2)*pairMs + (odd ? pairMs*swing : 0), clamped BEFORE the Int conversion. */
    fun onsetMs(step: Int, stepMs: Double, swingPct: Double): Int = clampMs(onsetDouble(step, stepMs, swingPct))

    /** Gate-off: 80% of the gap to the NEXT onset, so a swung short step never overlaps its successor. */
    fun gateOffMs(step: Int, stepMs: Double, swingPct: Double): Int {
        val on = onsetDouble(step, stepMs, swingPct)
        val next = onsetDouble(step + 1, stepMs, swingPct)
        return clampMs(on + 0.8 * (next - on))
    }

    private fun onsetDouble(step: Int, stepMs: Double, swingPct: Double): Double {
        if (!stepMs.isFinite() || stepMs <= 0 || step < 0) return 0.0
        val s = (if (swingPct.isFinite()) swingPct else 50.0).coerceIn(50.0, 75.0) / 100
        val pairMs = 2 * stepMs
        val base = (step / 2).toDouble() * pairMs
        return if (step % 2 == 0) base else base + pairMs * s
    }

    private fun clampMs(ms: Double): Int = if (!ms.isFinite()) 0 else Math.round(ms.coerceIn(0.0, MAX_ONSET_MS.toDouble())).toInt()

    /** The next cycle starts on the grid: cycle length rounded UP to a whole pair so swing phase survives. */
    fun cycleSpanMs(cycleSize: Int, stepMs: Double): Int = Math.round(((cycleSize + 1) / 2).toDouble() * 2 * stepMs).toInt()
}

/** What the arp strikes through (the engine implements it; tests record). */
interface ArpHost {
    /** A scheduled step ONSET: score capture (overdub OR live, never both) + sound. */
    fun arpStrikeOn(note: Int)
    /** A scheduled step GATE-OFF (mirror of [arpStrikeOn]). */
    fun arpStrikeOff(note: Int)
    /** Program-mode audition: sound only, NOTHING logged anywhere. */
    fun arpPreviewOn(note: Int, velocity: Int)
    fun arpPreviewOff(note: Int)
}

data class ArpState(
    val enabled: Boolean = false,
    val programming: Boolean = false,
    val playing: Boolean = false,
    /** Insertion-ordered, deduped programmed set (drives `.order`). */
    val selected: List<Int> = emptyList(),
    val settings: ArpSettings = ArpSettings(),
)

/**
 * The arp's set + transport. PROGRAM mode keys toggle membership and write NOTHING to any score. The transport
 * regenerates the cycle from the current set + knobs at each cycle boundary; latch OFF plays one cycle then pauses.
 */
class ArpeggiatorEngine(
    private val scope: CoroutineScope,
    private val host: ArpHost,
    /** Monotonic ms clock (the delay target base). */
    private val nowMs: () -> Long,
    private val rng: () -> Random = { Random.Default },
    private val onPlayingChanged: (Boolean) -> Unit = {},
) {
    private val _state = MutableStateFlow(ArpState())
    val state: StateFlow<ArpState> = _state.asStateFlow()
    @Volatile private var enabledFast = false
    @Volatile private var programmingFast = false
    private var generation = 0L
    private var job: Job? = null
    private val sounding = LinkedHashSet<Int>()
    private val lock = Any()

    val isPlaying: Boolean get() = _state.value.playing
    val selectedNotes: List<Int> get() = _state.value.selected

    /** Master switch. Turning it OFF pauses the transport and leaves program mode but KEEPS the set. */
    fun setEnabled(on: Boolean) {
        val was = _state.value.enabled
        _state.update { it.copy(enabled = on, programming = if (on) it.programming else false) }
        enabledFast = on
        if (!on) { programmingFast = false; if (was) stop() }
    }

    fun setProgramming(on: Boolean) {
        val v = on && _state.value.enabled
        programmingFast = v
        _state.update { it.copy(programming = v) }
    }

    fun setSettings(s: ArpSettings) { _state.update { it.copy(settings = s) } }

    /** Program mode intercept for a key press: true = consumed (the caller must NOT log or sound it). */
    fun consumeKeyOn(note: Int, velocity: Int): Boolean {
        if (!(enabledFast && programmingFast)) return false
        toggleSelection(note, velocity)
        return true
    }

    /** The matching key-up of a consumed press (the once-sound self-terminates). */
    fun consumeKeyOff(): Boolean = enabledFast && programmingFast

    private fun toggleSelection(note: Int, velocity: Int) {
        val n = note.coerceIn(0, 127)
        var added = false
        _state.update {
            if (n in it.selected) it.copy(selected = it.selected - n) else { added = true; it.copy(selected = it.selected + n) }
        }
        if (!added) return
        host.arpPreviewOn(n, velocity)
        scope.launch {
            delay(PREVIEW_MS)
            // Deliberately NOT generation-guarded: a transport flip must not strand a preview sounding forever.
            // The one note this must not cut is one the scheduler is sounding; that one owns its own gate-off.
            if (synchronized(lock) { n in sounding }) return@launch
            host.arpPreviewOff(n)
        }
    }

    /** Empty the set (explicit Clear). */
    fun clearSelection() {
        _state.update { it.copy(selected = emptyList()) }
        if (isPlaying) stop()
    }

    /**
     * Transport play. [exclusiveReplay] runs before starting (outside an overdub the old exclusivity holds and
     * the caller stops the replay; during an overdub the replay IS the backing and must keep running).
     */
    fun start(bpm: Double, exclusiveReplay: () -> Unit = {}): Boolean {
        if (_state.value.selected.isEmpty()) return false
        exclusiveReplay()
        stop()
        val gen: Long
        synchronized(lock) { gen = ++generation }
        setPlaying(true)
        val t0 = nowMs()
        val r = rng()
        job = scope.launch {
            var cycleBase = 0
            while (true) {
                if (!current(gen)) return@launch
                val st = _state.value
                val s = st.settings
                val cycle = ArpPattern.cycle(st.selected, s.order, s.octaves, r)
                if (cycle.isEmpty()) break
                val step = ArpPattern.stepMs(s.length, bpm)
                for ((k, note) in cycle.withIndex()) {
                    val onAt = cycleBase + ArpPattern.onsetMs(k, step, s.swingPct)
                    val offAt = cycleBase + ArpPattern.gateOffMs(k, step, s.swingPct)
                    sleepUntil(t0 + onAt)
                    if (!current(gen)) return@launch
                    synchronized(lock) { sounding.add(note) }
                    host.arpStrikeOn(note)
                    sleepUntil(t0 + offAt)
                    if (!current(gen)) return@launch
                    strikeOff(note)
                }
                cycleBase += ArpPattern.cycleSpanMs(cycle.size, step)
                if (cycleBase > ArpPattern.MAX_ONSET_MS) break
                if (!s.latch) break                       // latch OFF => exactly one cycle
            }
            if (current(gen)) finish()
        }
        return true
    }

    private suspend fun sleepUntil(targetMs: Long) { val w = targetMs - nowMs(); if (w > 0) delay(w) }
    private fun current(gen: Long) = synchronized(lock) { generation == gen }

    /** Pause (the transport's pause): bump the generation and silence anything sounding NOW. */
    fun stop() {
        synchronized(lock) { generation++ }
        job?.cancel(); job = null
        if (_state.value.playing) finish()
    }

    private fun strikeOff(note: Int) {
        val had = synchronized(lock) { sounding.remove(note) }
        if (had) host.arpStrikeOff(note)
    }

    private fun finish() {
        // Close every sounding step through the SAME gate-off path a scheduled step takes (no hanging onsets).
        val copy = synchronized(lock) { sounding.toList() }
        copy.forEach { strikeOff(it) }
        setPlaying(false)
    }

    private fun setPlaying(on: Boolean) {
        _state.update { it.copy(playing = on) }
        onPlayingChanged(on)
    }

    /** TEST/seam: drive ONE step through the shipped write path. */
    fun stepForTesting(note: Int, on: Boolean) {
        if (on) { synchronized(lock) { sounding.add(note) }; host.arpStrikeOn(note) } else strikeOff(note)
    }

    companion object {
        const val PREVIEW_MS = 250L
        /** The arp's fixed strike velocity (a machine, not a performance). */
        const val VELOCITY = 96
    }
}
