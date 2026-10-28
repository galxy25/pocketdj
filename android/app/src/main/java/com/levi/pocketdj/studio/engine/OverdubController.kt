package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Pure overdub math (iOS `InstrumentEngine` statics) — pinned by OverdubInvariantTest. */
object OverdubMath {
    /** Upper clamp for any score-clock position (the replay clock ceiling). */
    const val MAX_REPLAY_MS = 86_400_000
    /** The least room a CONFINED pass needs at the anchor; below this the pass is an instant auto-finalize. */
    const val MIN_REGION_MS = 250
    /** Primary + overdub staffs. Same cap as a saved take (`StudioTake.maxStaffs`). */
    const val MAX_STAFFS = 4

    /** Is there room to overdub at [fromMs]? `scoreEndMs == 0` is an EMPTY score: always overdubbable (unbounded). */
    fun hasOverdubRoom(fromMs: Int, scoreEndMs: Int): Boolean {
        if (scoreEndMs <= 0) return true
        return minOf(scoreEndMs, MAX_REPLAY_MS) - fromMs.coerceIn(0, MAX_REPLAY_MS) >= MIN_REGION_MS
    }

    /** The score's END: last note-off across every staff; 0 for an empty score (read by [OverdubController.start] as unbounded). */
    fun scoreEndMs(staffs: List<List<StudioNoteEvent>>): Int {
        var end = 0
        for (s in staffs) for (e in s) end = maxOf(end, maxOf(0, e.onMs), e.offMs)
        return minOf(end, MAX_REPLAY_MS)
    }

    /** A looping backing's cursor: positions past the wrap point fold back into [startMs, endMs). Identity with no loop. */
    fun wrapIntoLoop(ms: Int, region: Pair<Int, Int>?): Int {
        if (region == null) return ms
        val (start, end) = region
        if (end <= start || ms < end) return ms
        return start + (ms - start) % (end - start)
    }

    /**
     * A pass whose BACKING has not started yet has not started: running the deadline against the button-press
     * anchor in that window would finalize a short-region pass before the user heard a note of backing.
     */
    fun deadlineDeferred(isReplaying: Boolean, backingReady: Boolean, backingPreparing: Boolean = false, capturedCount: Int): Boolean {
        if (capturedCount != 0) return false
        return backingPreparing || (isReplaying && !backingReady)
    }

    /** The user-facing reason an overdub was refused. */
    const val NO_ROOM_MESSAGE = "There's no room to overdub here — the score ends at this point. Move the cursor earlier."
}

/**
 * The overdub capture stream (iOS `InstrumentEventLog.overdub*`): a THIRD stream beside the take stream and the
 * always-on live stream, with its own armed gate + anchor, BASE-OFFSET by the chosen score position so captured
 * events land ABSOLUTE on the one score clock. Nanosecond stamps (`System.nanoTime()` domain). One lock; the
 * synth/MIDI thread does a short lock-append-unlock per note.
 */
class OverdubLog {
    private val lock = Any()
    private var armed = false
    private var anchorNanos = 0L
    private var baseMs = 0
    private var regionEndMs = Int.MAX_VALUE
    private var loop = false
    private var events = ArrayList<StudioNoteEvent>()
    private class Pending(val onMs: Int, val velocity: Int, val iter: Int)
    private val pending = HashMap<Int, Pending>()
    private var dirty = false

    /** Arm: notes from [anchorNanos] on capture at `baseMs + elapsed`, confined to `[baseMs, regionEndMs)`; [loop] wraps into that region. */
    fun arm(anchorNanos: Long, baseMs: Int, regionEndMs: Int = Int.MAX_VALUE, loop: Boolean = false) = synchronized(lock) {
        armed = true
        this.anchorNanos = anchorNanos
        this.baseMs = maxOf(0, baseMs)
        this.regionEndMs = maxOf(this.baseMs, regionEndMs)
        this.loop = loop && this.regionEndMs > this.baseMs && this.regionEndMs < Int.MAX_VALUE
        events = ArrayList(); pending.clear(); dirty = false
    }

    val isArmed: Boolean get() = synchronized(lock) { armed }
    val count: Int get() = synchronized(lock) { if (!armed) 0 else events.size + pending.size }

    /** Raw elapsed -> (position, iteration), or null when OUTSIDE the region (pre-anchor, or at/past the boundary with loop OFF). */
    private fun position(e: Int): Pair<Int, Int>? {
        if (e < 0) return null
        if (loop) { val len = regionEndMs - baseMs; return (baseMs + e % len) to (e / len) }
        val ms = baseMs.toLong() + e
        if (ms >= regionEndMs) return null
        return ms.toInt() to 0
    }

    /** Close a sounding note at raw elapsed [e]: same iteration -> its wrapped position; a LATER iteration (or past the end) -> AT the boundary. */
    private fun closeMs(p: Pending, e: Int): Int {
        val off: Int = if (loop) {
            val len = regionEndMs - baseMs
            if (e >= 0 && e / len == p.iter) baseMs + e % len else regionEndMs
        } else minOf(baseMs.toLong() + maxOf(0, e), regionEndMs.toLong()).toInt()
        return maxOf(p.onMs, off)
    }

    fun on(note: Int, velocity: Int, nanos: Long) = synchronized(lock) {
        if (!armed) return@synchronized
        val e = InstrumentEventLog.msFrom(anchorNanos, nanos)
        val pos = position(e) ?: return@synchronized
        pending.remove(note)?.let { prev -> events.add(StudioNoteEvent(prev.onMs, closeMs(prev, e), note, prev.velocity)); dirty = true }
        pending[note] = Pending(pos.first, velocity, pos.second)
    }

    fun off(note: Int, nanos: Long) = synchronized(lock) {
        if (!armed) return@synchronized
        val p = pending.remove(note) ?: return@synchronized
        events.add(StudioNoteEvent(p.onMs, closeMs(p, InstrumentEventLog.msFrom(anchorNanos, nanos)), note, p.velocity))
        dirty = true
    }

    /** Disarm and close every still-sounding note at [endNanos]; the capture sorted by onset (absolute score ms). */
    fun disarmAndFinish(endNanos: Long): List<StudioNoteEvent> = synchronized(lock) {
        if (!armed) return@synchronized emptyList()
        armed = false
        val e = InstrumentEventLog.msFrom(anchorNanos, endNanos)
        for ((note, p) in pending) events.add(StudioNoteEvent(p.onMs, closeMs(p, e), note, p.velocity))
        pending.clear()
        val out = events.sortedBy { it.onMs }
        events = ArrayList(); dirty = false
        out
    }

    /** Coalesced drain of the armed pass's COMPLETED captures iff changed; the sort runs outside the lock. */
    fun snapshotIfDirty(): List<StudioNoteEvent>? {
        val snap = synchronized(lock) { if (!dirty) return null; dirty = false; events.toList() }
        return snap.sortedBy { it.onMs }
    }

    /** True only for an armed, NON-looping, bounded pass whose elapsed time reached the region's end. */
    fun regionExhausted(nanos: Long): Boolean = synchronized(lock) {
        if (!armed || loop || regionEndMs >= Int.MAX_VALUE) return@synchronized false
        baseMs.toLong() + InstrumentEventLog.msFrom(anchorNanos, nanos) >= regionEndMs
    }
}

/** One in-memory LIVE overdub staff (staffs 2..4 of the free-play score; the live score never persists). */
data class LiveExtraStaff(val id: String, val instrument: InstrumentKey, val events: List<StudioNoteEvent>)

data class OverdubState(
    val active: Boolean = false,
    val baseMs: Int = 0,
    /** EXCLUSIVE region end; Int.MAX_VALUE = unbounded (empty score only). */
    val regionEndMs: Int = Int.MAX_VALUE,
    val loop: Boolean = false,
    /** The ARMED pass's capture so far (completed notes), published ~30 Hz. */
    val events: List<StudioNoteEvent> = emptyList(),
    /** A non-looping pass ran out of region; the owning view finalizes it. */
    val reachedEnd: Boolean = false,
    val backingPreparing: Boolean = false,
    val backingReady: Boolean = false,
    val staffs: List<LiveExtraStaff> = emptyList(),
)

/**
 * Overdub mode (iOS `startOverdub`/`stopOverdub`/`overdubDeadlineTick`/`reanchorOverdubIfEmpty` + live extra staffs).
 * While armed, played notes (hand, MIDI or arp) capture into a NEW staff — INSTEAD of the live staff, never both.
 * The pass is confined to `[from, scoreEnd)` (an overdub can never extend the score).
 */
class OverdubController(private val nanoClock: () -> Long = System::nanoTime, private val log: (String) -> Unit = {}) {
    val capture = OverdubLog()
    private val _state = MutableStateFlow(OverdubState())
    val state: StateFlow<OverdubState> = _state.asStateFlow()
    @Volatile var isActive = false
        private set

    /**
     * Arm from [fromMs] anchored at [anchorNanos]. [scoreEndMs] == Int.MAX_VALUE is the EMPTY-score unbounded pass;
     * a REAL score always confines, and is REFUSED (false) when there is no room at the anchor. [loop] is ignored for an unbounded pass.
     * [midTake] must be true while a take is recording (refused: the take owns the streams).
     */
    fun start(fromMs: Int, scoreEndMs: Int = Int.MAX_VALUE, loop: Boolean = false, anchorNanos: Long = nanoClock(), midTake: Boolean = false): Boolean {
        if (midTake || isActive) return false
        val base = fromMs.coerceIn(0, OverdubMath.MAX_REPLAY_MS)
        var end = Int.MAX_VALUE
        if (scoreEndMs != Int.MAX_VALUE) {
            end = minOf(scoreEndMs, OverdubMath.MAX_REPLAY_MS)
            if (end - base < OverdubMath.MIN_REGION_MS) { log("instr: overdub REFUSED — no room at $base ms (score ends at $end ms)"); return false }
        }
        val lp = loop && end < Int.MAX_VALUE
        capture.arm(anchorNanos, base, end, lp)
        isActive = true
        _state.update { it.copy(active = true, baseMs = base, regionEndMs = end, loop = lp, events = emptyList(), reachedEnd = false, backingPreparing = false, backingReady = false) }
        log("instr: overdub ARM at $base ms region→${if (end == Int.MAX_VALUE) "∞" else end.toString()} loop=$lp")
        return true
    }

    /** End the pass; returns the captured events (ABSOLUTE score-clock ms, onset-sorted). Empty => the caller files no staff. */
    fun stop(): List<StudioNoteEvent> {
        if (!isActive) return emptyList()
        isActive = false
        val ev = capture.disarmAndFinish(nanoClock())
        _state.update { it.copy(active = false, events = emptyList(), reachedEnd = false, regionEndMs = Int.MAX_VALUE, loop = false, backingPreparing = false, backingReady = false) }
        log("instr: overdub END — ${ev.size} events from ${_state.value.baseMs} ms")
        return ev
    }

    fun setBackingPreparing(on: Boolean) { _state.update { it.copy(backingPreparing = on) } }
    fun setBackingReady(on: Boolean) { _state.update { it.copy(backingReady = on, backingPreparing = false) } }

    /** The ~30 Hz pump: publish the in-progress staff and run the deadline (loop OFF only). */
    fun tick(isReplaying: Boolean) {
        if (!isActive) return
        capture.snapshotIfDirty()?.let { ev -> _state.update { it.copy(events = ev) } }
        val s = _state.value
        if (s.loop || s.reachedEnd) return
        if (OverdubMath.deadlineDeferred(isReplaying, s.backingReady, s.backingPreparing, capture.count)) return
        if (!capture.regionExhausted(nanoClock())) return
        _state.update { it.copy(reachedEnd = true) }
        log("instr: overdub region END at ${s.regionEndMs} ms — auto-finalize")
    }

    /**
     * Re-anchor an EMPTY capture to NOW (the backing became audible later than the press, or refused after burning
     * time). A capture with notes keeps its anchor — re-basing captured events corrupts them.
     */
    fun reanchorIfEmpty(): Boolean {
        if (!isActive || capture.count != 0) return false
        val s = _state.value
        capture.arm(nanoClock(), s.baseMs, s.regionEndMs, s.loop)
        log("overdub RE-ANCHORED at ${s.baseMs} ms")
        return true
    }

    val capturedCount: Int get() = if (isActive) capture.count else 0

    // ---- live extra staffs (in memory only)

    /** Append a finished capture as a new staff; null when empty (no junk staffs) or at the 4-staff cap with the primary. */
    fun appendStaff(instrument: InstrumentKey, events: List<StudioNoteEvent>, newId: () -> String = StudioFactory::newStaffId): String? {
        if (events.isEmpty() || 1 + _state.value.staffs.size >= OverdubMath.MAX_STAFFS) return null
        val id = newId()
        _state.update { it.copy(staffs = it.staffs + LiveExtraStaff(id, instrument, events)) }
        return id
    }

    fun setStaffEvents(id: String, events: List<StudioNoteEvent>) =
        _state.update { s -> s.copy(staffs = s.staffs.map { if (it.id == id) it.copy(events = events) else it }) }

    fun setStaffInstrument(id: String, instrument: InstrumentKey) =
        _state.update { s -> s.copy(staffs = s.staffs.map { if (it.id == id) it.copy(instrument = instrument) else it }) }

    fun deleteStaff(id: String) = _state.update { s -> s.copy(staffs = s.staffs.filter { it.id != id }) }
    fun clearStaffs() = _state.update { it.copy(staffs = emptyList()) }
}
