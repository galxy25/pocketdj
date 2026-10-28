package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The take recorder's note-event log + key-highlight mirror (iOS `InstrumentEventLog`). Every producer — the
 * on-screen keys (UI thread), MIDI, the replay scheduler — funnels through here, so takes sound and record
 * identically whatever the input. Times are monotonic NANOSECONDS (`System.nanoTime()` domain); the log only
 * ever subtracts two stamps, so any consistent clock works (tests pass synthetic ones).
 *
 * Threading: one lock around all state. A producer does a short lock-append-unlock per note (no allocation-
 * heavy work); the UI reads highlights via a COALESCED dirty-flag drain — never per-note publishing.
 */
class InstrumentEventLog {
    private val lock = Any()

    // ---- take stream: armed BEFORE beat 1 (during count-in); only stamps at/after beat 1 are logged.
    private var armed = false
    private var beat1Nanos = 0L
    private val events = ArrayList<StudioNoteEvent>()
    private val pending = HashMap<Int, Pending>()

    // ---- key-highlight mirror
    private val active = HashSet<Int>()
    private var highlightsDirty = false

    // ---- always-on LIVE (free-play) stream, anchored at the FIRST note, capped
    private var liveEvents = ArrayList<StudioNoteEvent>()
    private val livePending = HashMap<Int, Pending>()
    private var liveAnchor: Long? = null
    private var liveDirty = false
    private var liveFull = false

    private class Pending(val onMs: Int, val velocity: Int)

    /**
     * Arm recording. Called BEFORE beat 1: notes sound immediately but only stamps at/after [beat1Nanos] enter
     * the log — a warm-up note during the count-in is heard, not recorded.
     */
    fun arm(beat1Nanos: Long) = synchronized(lock) {
        armed = true
        this.beat1Nanos = beat1Nanos
        events.clear(); pending.clear()
    }

    val isArmed: Boolean get() = synchronized(lock) { armed }

    /** Disarm + close every still-sounding note at [endNanos]; the take's events sorted by onset. */
    fun disarmAndFinish(endNanos: Long): List<StudioNoteEvent> = synchronized(lock) {
        armed = false
        val endMs = msFrom(beat1Nanos, endNanos)
        for ((note, p) in pending) events.add(StudioNoteEvent(p.onMs, max(p.onMs, endMs), note, p.velocity))
        pending.clear()
        events.sortedBy { it.onMs }.also { events.clear() }
    }

    /**
     * Note-on (any thread). Always feeds the highlight mirror; enters the log only when armed AND at/after
     * beat 1. A re-trigger with no off closes the previous sounding at the new onset (no per-note overlap).
     */
    fun noteOn(note: Int, velocity: Int, nanos: Long) = synchronized(lock) {
        active.add(note); highlightsDirty = true
        if (!armed) return@synchronized
        val ms = msFrom(beat1Nanos, nanos)
        if (ms < 0) return@synchronized                       // count-in: audible, not recorded
        pending.remove(note)?.let { prev -> events.add(StudioNoteEvent(prev.onMs, max(prev.onMs, ms), note, prev.velocity)) }
        pending[note] = Pending(ms, velocity)
    }

    /** Note-off (any thread). An off with no armed onset (released after stop / started in the count-in) only updates highlights. */
    fun noteOff(note: Int, nanos: Long) = synchronized(lock) {
        active.remove(note); highlightsDirty = true
        if (!armed) return@synchronized
        val p = pending.remove(note) ?: return@synchronized
        events.add(StudioNoteEvent(p.onMs, max(p.onMs, msFrom(beat1Nanos, nanos)), note, p.velocity))
    }

    /** The coalesced drain: the held-key set iff it changed since the last drain, else null. */
    fun drainHighlightsIfDirty(): Set<Int>? = synchronized(lock) {
        if (!highlightsDirty) return null
        highlightsDirty = false
        active.toSet()
    }

    /** Release every highlight (all-notes-off / teardown). */
    fun clearHighlights() = synchronized(lock) { if (active.isNotEmpty()) { active.clear(); highlightsDirty = true } }

    /** Events recorded so far, including held notes (diagnostics only). */
    val recordedCount: Int get() = synchronized(lock) { events.size + pending.size }

    // ---- live stream

    /** Live note-on — ALWAYS captured (independent of the take gate and of whether a sound was made). */
    fun liveOn(note: Int, velocity: Int, nanos: Long) = synchronized(lock) {
        if (liveEvents.size >= MAX_LIVE_EVENTS) { liveFull = true; return@synchronized }
        val anchor = liveAnchor ?: nanos.also { liveAnchor = it }
        val ms = max(0, msFrom(anchor, nanos))
        livePending.remove(note)?.let { prev -> liveEvents.add(StudioNoteEvent(prev.onMs, max(prev.onMs, ms), note, prev.velocity)) }
        livePending[note] = Pending(ms, velocity)
        liveDirty = true
    }

    /** Live note-off — closes the note into the live stream (completed events only). */
    fun liveOff(note: Int, nanos: Long) = synchronized(lock) {
        val lp = livePending.remove(note) ?: return@synchronized
        val anchor = liveAnchor ?: return@synchronized
        liveEvents.add(StudioNoteEvent(lp.onMs, max(lp.onMs, msFrom(anchor, nanos)), note, lp.velocity))
        liveDirty = true
    }

    /** Coalesced drain of completed live notes (onset-sorted) iff changed; the sort runs OUTSIDE the lock. */
    fun snapshotLiveIfDirty(): List<StudioNoteEvent>? {
        val snapshot = synchronized(lock) {
            if (!liveDirty) return null
            liveDirty = false
            liveEvents.toList()
        }
        return snapshot.sortedBy { it.onMs }
    }

    val liveCaptureFull: Boolean get() = synchronized(lock) { liveFull }

    /** Replace the live stream (score editing); keeps the anchor + held notes so later notes stay on the same time base. */
    fun setLive(newEvents: List<StudioNoteEvent>) = synchronized(lock) {
        liveEvents = ArrayList(newEvents)
        liveFull = newEvents.size >= MAX_LIVE_EVENTS
        liveDirty = true
    }

    /** Reset the live stream (new session / after "Save as take"). */
    fun clearLive() = synchronized(lock) {
        liveEvents = ArrayList(); livePending.clear(); liveAnchor = null; liveFull = false; liveDirty = true
    }

    companion object {
        /** Hard cap on the always-on live capture (a latched arp could otherwise grow it without bound). */
        const val MAX_LIVE_EVENTS = 4_000

        /** ms between two nanos stamps, subtracted as longs so a stamp before the anchor is just negative. */
        fun msFrom(anchorNanos: Long, nanos: Long): Int = ((nanos - anchorNanos) / 1_000_000.0).roundToInt()
    }
}
