package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.studio.audio.NativeDsp
import com.levi.pocketdj.studio.audio.Sf2Synth
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/** The slice of the native SF2 synth the engine and offline renderer need (a fake in JVM tests). */
interface SynthVoice {
    fun load(path: String): Boolean
    fun setPreset(bank: Int, program: Int): Boolean
    fun noteOn(key: Int, velocity: Int)
    fun noteOff(key: Int)
    fun allOff()
    /** Interleaved stereo; [mix] adds into [out] instead of overwriting. */
    fun render(out: FloatArray, frames: Int, mix: Boolean)
    fun close()
}

class Sf2SynthVoice(sampleRate: Int = 44_100) : SynthVoice {
    // The JNI library loads lazily; load it BEFORE the first native SF2 call, and fail with an Exception (callers map
    // it to a load error) rather than letting an UnsatisfiedLinkError take the app down.
    private val synth: Sf2Synth = if (NativeDsp.available) Sf2Synth(sampleRate) else throw IllegalStateException("native synth library unavailable")
    override fun load(path: String) = synth.load(path)
    override fun setPreset(bank: Int, program: Int) = synth.setPreset(bank, program)
    override fun noteOn(key: Int, velocity: Int) = synth.noteOn(key, velocity)
    override fun noteOff(key: Int) = synth.noteOff(key)
    override fun allOff() = synth.allOff()
    override fun render(out: FloatArray, frames: Int, mix: Boolean) = synth.render(out, frames, mix)
    override fun close() = synth.close()
}

/** What a finished take hands the UI to file via [TakeFiler]. Events are ms from beat 1 (end of the count-in). */
data class TakeResult(
    val takeId: String,
    val fileName: String,
    val durationMs: Int,
    val events: List<StudioNoteEvent>,
    val bpm: Double,
    val instrument: InstrumentKey,
)

/** Observable engine state (the Instruments tab renders off this). */
data class InstrumentEngineState(
    val isLoadingInstrument: Boolean = false,
    val currentInstrument: InstrumentKey? = null,
    val loadError: String? = null,
    val isRecordingTake: Boolean = false,
    val isCountingIn: Boolean = false,
    val clickEnabled: Boolean = false,
    val isReplaying: Boolean = false,
    /** Keys currently held (coalesced ~30 Hz from the event log). */
    val pressedNotes: Set<Int> = emptySet(),
    /** Completed free-play notes (the live staff). */
    val liveEvents: List<StudioNoteEvent> = emptyList(),
    val liveCaptureFull: Boolean = false,
)

/**
 * The instrument engine (iOS `InstrumentEngine`): a native TinySoundFont voice rendered into an [AudioSink]
 * (Oboe on device, AudioTrack on the emulator), on-screen keys that reach the synth on the CALLING thread (no
 * main-thread hop — the native synth serializes note/render with a spinlock), a metronome + 1-bar count-in mixed
 * into the live output only, take recording (the event log anchored at beat 1 = end of the count-in), and replay
 * of a score through the synth. Take AUDIO is rendered offline from the events ([TakeRenderer]), so the click is
 * structurally never in a take.
 */
class InstrumentEngine(
    private val sinkFactory: () -> AudioSink,
    private val scope: CoroutineScope,
    private val synthFactory: () -> SynthVoice = { Sf2SynthVoice() },
    private val loadDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val nanoClock: () -> Long = System::nanoTime,
    private val focus: () -> Unit = {},
    private val focusRelease: () -> Unit = {},
    private val log: (String) -> Unit = {},
    private val tickMs: Long = 33,
) {
    val eventLog = InstrumentEventLog()
    private val click = ClickTrack.Voice()

    private val _state = MutableStateFlow(InstrumentEngineState())
    val state: StateFlow<InstrumentEngineState> = _state.asStateFlow()

    @Volatile private var primary: SynthVoice? = null
    @Volatile private var backing: List<SynthVoice> = emptyList()
    private var sink: AudioSink? = null
    private var sinkRunning = false
    private val framesRendered = AtomicLong(0)
    private val sampleRate: Int get() = sink?.sampleRate ?: 44_100
    private val lock = Any()
    @Volatile private var lastActivityNanos = 0L
    private var loadGeneration = 0
    private var pump: Job? = null
    private var onTakeAutoStopped: ((TakeResult) -> Unit)? = null

    // ---- take state
    private var takeId = ""
    private var takeBpm = ClickTrack.DEFAULT_BPM
    private var takeInstrument: InstrumentKey? = null
    private var beat1Nanos = 0L
    /** Output frame of the take's beat 1 (the click grid); -1 outside a take. */
    @Volatile private var takeBeat1Frame = -1L
    private var takeHadCountIn = false
    private var clickBpm = ClickTrack.DEFAULT_BPM

    // ---- replay state
    private var replayJob: Job? = null
    private var replayAnchorNanos = 0L
    private var replayFromMs = 0
    private var parkedMs: Int? = null

    private val renderer = BlockRenderer { out, frames ->
        java.util.Arrays.fill(out, 0, frames * 2, 0f)
        primary?.render(out, frames, true)
        for (v in backing) v.render(out, frames, true)
        click.mixInto(out, frames, framesRendered.get())
        for (i in 0 until frames * 2) { val x = out[i]; if (x > 1f) out[i] = 1f else if (x < -1f) out[i] = -1f }
        framesRendered.addAndGet(frames.toLong())
    }

    /** Wire the callback that files a take the engine had to end itself (outage / length cap). */
    fun setOnTakeAutoStopped(cb: ((TakeResult) -> Unit)?) { onTakeAutoStopped = cb }

    // ---- output lifecycle

    /** Start the ~30 Hz publisher (highlights + live staff) without waking the audio output. */
    private fun ensurePump() {
        lastActivityNanos = nanoClock()
        synchronized(lock) { if (pump == null) pump = scope.launch { pumpLoop() } }
    }

    private fun ensureRunning() {
        ensurePump()
        synchronized(lock) {
            if (!sinkRunning) {
                val k = sink ?: sinkFactory().also { sink = it }
                focus()
                k.start(renderer)
                sinkRunning = true
                log("instr: sink start")
            }
        }
    }

    private fun stopSink() {
        synchronized(lock) {
            if (!sinkRunning) return
            sink?.stop(); sinkRunning = false
            focusRelease()
            log("instr: sink idle-stop")
        }
    }

    /** ~30 Hz: publish coalesced highlights + live staff, flip count-in, auto-end runaway takes, stop the sink when idle. */
    private suspend fun pumpLoop() {
        var tick = 0
        while (scope.isActive) {
            delay(tickMs)
            eventLog.drainHighlightsIfDirty()?.let { h -> _state.update { it.copy(pressedNotes = h) } }
            eventLog.snapshotLiveIfDirty()?.let { l -> _state.update { it.copy(liveEvents = l, liveCaptureFull = eventLog.liveCaptureFull) } }
            val s = _state.value
            val now = nanoClock()
            if (s.isCountingIn && now >= beat1Nanos) _state.update { it.copy(isCountingIn = false) }
            if (s.isRecordingTake && !s.isCountingIn && (now - beat1Nanos) / 1_000_000 > MAX_TAKE_MS) autoStopTake("length cap")
            tick++
            if (tick % 15 == 0) {
                // Decide, stop the sink and retire the pump in ONE locked step, re-checking under the lock: a
                // noteOn that bumped lastActivity first keeps us alive; one that comes later sees pump == null.
                synchronized(lock) {
                    if (isIdle(nanoClock())) { stopSink(); pump = null; return }
                }
            }
        }
    }

    private fun isIdle(now: Long): Boolean {
        val s = _state.value
        if (s.isRecordingTake || s.isReplaying || s.clickEnabled || s.pressedNotes.isNotEmpty()) return false
        return now - lastActivityNanos > IDLE_NANOS
    }

    // ---- instrument loading

    /**
     * Load [key]'s preset from [bank] OFF the calling thread (parsing a 32 MB bank takes a while), publishing a
     * loading state. A newer load supersedes this one (the stale result is closed, never swapped in).
     */
    suspend fun loadInstrument(key: InstrumentKey, bank: File, program: Int = key.gmProgram): Boolean {
        val gen: Int
        synchronized(lock) { gen = ++loadGeneration }
        _state.update { it.copy(isLoadingInstrument = true, loadError = null) }
        val voice = withContext(loadDispatcher) {
            val v = try { synthFactory() } catch (e: Exception) { log("instr: synth unavailable — ${e.message}"); null } catch (e: LinkageError) { log("instr: native synth missing — ${e.message}"); null }
            if (v == null) null
            else if (try { v.load(bank.path) && v.setPreset(0, program) } catch (e: Exception) { false } catch (e: LinkageError) { false }) v
            else { runCatching { v.close() }; null }
        }
        synchronized(lock) {
            if (gen != loadGeneration) { voice?.let { retire(it) }; return false }   // superseded
        }
        if (voice == null) {
            _state.update { it.copy(isLoadingInstrument = false, loadError = "Couldn't load the ${key.displayName} sound bank") }
            return false
        }
        val old = primary
        primary = voice
        old?.let { retire(it) }
        _state.update { it.copy(isLoadingInstrument = false, currentInstrument = key, loadError = null) }
        log("instr: loaded ${key.raw} program $program")
        return true
    }

    /** Close a swapped-out voice after any in-flight render block is long done. */
    private fun retire(v: SynthVoice) {
        scope.launch { delay(RETIRE_DELAY_MS); runCatching { v.allOff() }; runCatching { v.close() } }
    }

    val isReady: Boolean get() = primary != null

    /** A fresh, unloaded voice from the engine's factory (callers own it unless they hand it to [replay]). */
    fun createVoice(): SynthVoice = synthFactory()

    // ---- on-screen keys / MIDI (calling thread; no dispatcher hop)

    fun noteOn(note: Int, velocity: Int = 96) {
        val n = nanoClock()
        // Live capture BEFORE the audible guard: a free-play staff fills even with no instrument loaded.
        eventLog.liveOn(note, velocity, n)
        ensurePump()
        val v = primary ?: return
        ensureRunning()
        v.noteOn(note.coerceIn(0, 127), velocity.coerceIn(1, 127))
        eventLog.noteOn(note, velocity, n)
        if (DEBUG_THREADS) log("instr: noteOn $note on ${Thread.currentThread().name}")
    }

    fun noteOff(note: Int) {
        val n = nanoClock()
        eventLog.liveOff(note, n)
        lastActivityNanos = n
        primary?.noteOff(note.coerceIn(0, 127))
        eventLog.noteOff(note, n)
    }

    fun allNotesOff() {
        primary?.allOff(); backing.forEach { it.allOff() }
        eventLog.clearHighlights()
    }

    /** Commit an EDITED live score (STU-9 live staff). Re-sorted by onset like the iOS host, and published immediately (the pump may be idle). */
    fun setLiveEvents(events: List<StudioNoteEvent>) {
        val sorted = events.sortedWith(compareBy({ it.onMs }, { it.note }))
        eventLog.setLive(sorted)
        _state.update { it.copy(liveEvents = sorted, liveCaptureFull = sorted.size >= InstrumentEventLog.MAX_LIVE_EVENTS) }
    }

    fun clearLive() { eventLog.clearLive(); _state.update { it.copy(liveEvents = emptyList(), liveCaptureFull = false) } }

    // ---- click

    /** Flip the metronome live (free play or mid-take). Mid-take the take's own BPM wins. */
    fun setClickEnabled(on: Boolean, bpm: Double? = null) {
        if (!on) { click.stop(); _state.update { it.copy(clickEnabled = false) }; return }
        val s = _state.value
        val b = if (s.isRecordingTake) takeBpm else ClickTrack.clampBpm(bpm ?: clickBpm)
        clickBpm = b
        ensureRunning()
        val sr = sampleRate
        val g = takeBeat1Frame
        if (s.isRecordingTake && g >= 0) {
            // Re-enter ON the take's grid: next beat boundary, bar phase kept so the accent lands on beat 1 only.
            val beatFrames = ClickTrack.beatFrames(b, sr).toLong()
            val nowFrame = framesRendered.get()
            val next = ClickTrack.nextBeatOnGrid(nowFrame.toDouble() / sr, g.toDouble() / sr, beatFrames.toDouble() / sr)
            val beatIdx = next.beatInBar
            val atFrame = g + Math.round((next.atSec - g.toDouble() / sr) * sr / beatFrames) * beatFrames
            click.start(b, sr, atFrame - beatIdx * beatFrames, audibleFromFrame = atFrame)
        } else {
            click.start(b, sr, framesRendered.get() + (ClickTrack.START_LEAD_SEC * sr).toLong())
        }
        _state.update { it.copy(clickEnabled = true) }
        log("instr: click ON at ${b.toInt()} BPM")
    }

    // ---- take recording

    /**
     * Begin a take: optionally one bar of count-in click, then beat 1 — where the event log's clock starts. The
     * recording gate is PRE-LATCHED with the beat-1 stamp, so a warm-up note in the count-in is heard, not logged.
     * False when nothing is loaded / a take or load is running.
     */
    fun startTake(bpm: Double, click: Boolean, countIn: Boolean): Boolean {
        val s = _state.value
        val instrument = s.currentInstrument ?: return false
        if (primary == null || s.isRecordingTake || s.isLoadingInstrument) return false
        stopReplay()
        val b = ClickTrack.clampBpm(bpm)
        ensureRunning()
        val sr = sampleRate
        val now = nanoClock()
        val countSec = if (countIn) ClickTrack.barSeconds(b) else 0.0
        // Beat 1 is when the user HEARS it: scheduled click time + output latency (ring buffer + device).
        val latencyNanos = runCatching { sink?.latencyFrames() ?: 0 }.getOrDefault(0).coerceAtLeast(0).toLong() * 1_000_000_000L / sr
        beat1Nanos = now + ((ClickTrack.START_LEAD_SEC + countSec) * 1e9).toLong() + latencyNanos
        val startFrame = framesRendered.get() + (ClickTrack.START_LEAD_SEC * sr).toLong()
        takeBeat1Frame = startFrame + (if (countIn) ClickTrack.beatFrames(b, sr).toLong() * 4 else 0L)
        takeHadCountIn = countSec > 0
        takeId = StudioFactory.newTakeId()
        takeBpm = b; clickBpm = b; takeInstrument = instrument
        eventLog.arm(beat1Nanos)
        if (click) this.click.start(b, sr, startFrame) else this.click.stop()
        _state.update { it.copy(isRecordingTake = true, isCountingIn = countSec > 0, clickEnabled = click) }
        log("instr: take START $takeId bpm=${b.toInt()} click=$click countIn=$countIn")
        return true
    }

    /**
     * End the take: close open notes at NOW and hand back what the caller files. Stopping DURING the count-in is
     * a cancel (nothing recorded) -> null.
     */
    fun stopTake(): TakeResult? {
        val s = _state.value
        if (!s.isRecordingTake) return null
        val wasCountingIn = takeHadCountIn && nanoClock() < beat1Nanos
        val endNanos = nanoClock()
        click.stop()
        takeBeat1Frame = -1L
        val events = eventLog.disarmAndFinish(endNanos)
        _state.update { it.copy(isRecordingTake = false, isCountingIn = false, clickEnabled = false) }
        primary?.allOff()
        if (wasCountingIn) { log("instr: take $takeId cancelled during count-in"); return null }
        val durationMs = max(InstrumentEventLog.msFrom(beat1Nanos, endNanos), events.maxOfOrNull { it.offMs } ?: 0)
        log("instr: take STOP $takeId — $durationMs ms, ${events.size} events")
        return TakeResult(takeId, StudioFolders.fileName(StudioFamily.TAKES, takeId), durationMs, events, takeBpm, takeInstrument ?: InstrumentKey.PIANO)
    }

    private fun autoStopTake(reason: String) {
        log("instr: take auto-stop — $reason")
        stopTake()?.let { onTakeAutoStopped?.invoke(it) }
    }

    // ---- replay (a score back through the synth)

    /**
     * Replay [events] through the loaded synth from [fromMs], scheduled against the monotonic clock. [staffs]
     * adds extra voices (each its own bank/preset) for a multi-staff take. Stopping parks the position.
     */
    fun replay(events: List<StudioNoteEvent>, fromMs: Int = 0, extraStaffs: List<Pair<SynthVoice, List<StudioNoteEvent>>> = emptyList()): Boolean {
        if (primary == null || _state.value.isRecordingTake) return false
        stopReplay()
        val all = ArrayList<Pair<SynthVoice?, List<NoteAction>>>()
        all.add(null to TakeScore.actions(events, fromMs))
        extraStaffs.forEach { (v, ev) -> all.add(v to TakeScore.actions(ev, fromMs)) }
        if (all.all { it.second.isEmpty() }) return false
        synchronized(lock) { backing = extraStaffs.map { it.first } }
        ensureRunning()
        replayFromMs = fromMs; parkedMs = null
        replayAnchorNanos = nanoClock()
        _state.update { it.copy(isReplaying = true) }
        val endMs = max(events.maxOfOrNull { max(it.onMs, it.offMs) } ?: 0, extraStaffs.maxOfOrNull { s -> s.second.maxOfOrNull { it.offMs } ?: 0 } ?: 0)
        val anchor = replayAnchorNanos
        replayJob = scope.launch {
            val merged = all.flatMap { (v, acts) -> acts.map { v to it } }
                .sortedWith(compareBy<Pair<SynthVoice?, NoteAction>>({ it.second.ms }, { it.second.on }))
            for ((v, a) in merged) {
                val dueNanos = anchor + (a.ms - fromMs).toLong() * 1_000_000L
                val wait = (dueNanos - nanoClock()) / 1_000_000L
                if (wait > 0) delay(wait)
                lastActivityNanos = nanoClock()
                val voice = v ?: primary ?: continue
                if (a.on) { voice.noteOn(a.note.coerceIn(0, 127), a.velocity.coerceIn(1, 127)); eventLog.noteOn(a.note, a.velocity, nanoClock()) }
                else { voice.noteOff(a.note.coerceIn(0, 127)); eventLog.noteOff(a.note, nanoClock()) }
            }
            // let the last release ring a moment, then finish
            delay(300)
            finishReplay(parkAtMs = null)
        }
        log("instr: replay from ${fromMs}ms (end ${endMs}ms)")
        return true
    }

    /** Current replay position on the score clock, or the parked position, or null. */
    fun replayPositionMs(): Int? {
        if (_state.value.isReplaying) return replayFromMs + ((nanoClock() - replayAnchorNanos) / 1_000_000L).toInt()
        return parkedMs
    }

    fun stopReplay() {
        if (!_state.value.isReplaying && replayJob == null) return
        val pos = replayPositionMs()
        replayJob?.cancel(); replayJob = null
        finishReplay(parkAtMs = pos)
    }

    private fun finishReplay(parkAtMs: Int?) {
        primary?.allOff()
        val extra = synchronized(lock) { backing.also { backing = emptyList() } }   // swap once: never retired twice
        extra.forEach { it.allOff(); retire(it) }    // the engine owns replay voices once handed to replay()
        eventLog.clearHighlights()
        parkedMs = parkAtMs
        replayJob = null
        _state.update { it.copy(isReplaying = false) }
    }

    // ---- teardown

    fun release() {
        stopReplay()
        click.stop()
        pump?.cancel(); pump = null
        stopSink()
        sink?.let { runCatching { it.release() } }; sink = null
        primary?.let { runCatching { it.close() } }; primary = null
        _state.value = InstrumentEngineState()
    }

    companion object {
        /** A take is auto-ended past this (runaway guard): 30 minutes of score. */
        const val MAX_TAKE_MS = 30 * 60 * 1000L
        const val IDLE_NANOS = 5_000_000_000L
        const val RETIRE_DELAY_MS = 1_000L
        /** Debug: log the calling thread name on every note-on (acceptance: no main-thread hop). */
        var DEBUG_THREADS = false
    }
}
