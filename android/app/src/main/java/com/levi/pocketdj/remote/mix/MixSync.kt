package com.levi.pocketdj.remote.mix

import com.levi.pocketdj.mix.engine.Gesture
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.remote.RemoteSessionController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One deck as the multiplayer layer reads it off THIS device's engine (iOS `MixSyncDeckStatus`). */
data class MixSyncDeckStatus(
    /** The LOCAL song id on the deck (null = empty). */
    val songId: String?,
    val isPlaying: Boolean,
    /** The AUDIBLE playhead (source ms): the render clock projected to now, minus output latency, folded into a loop. */
    val playheadMs: Int,
    val durationMs: Int,
    val rate: Double,
    /** Loaded and not waiting on bytes. */
    val ready: Boolean,
    /** A loop is engaged: its playhead wraps inside [loopStartMs, loopEndMs). */
    val looping: Boolean = false,
    val loopStartMs: Int? = null,
    val loopEndMs: Int? = null,
)

/**
 * The engine surface [MixSync] drives ([MixEnginePort] in the app, a fake in the unit tests). Every mutating call is
 * applied as a REMOTE event (the engine's `applyingRemote` guard: no gesture tap, no session-log record), so nothing
 * echoes back onto the wire.
 */
interface MixSyncDeckPort {
    /** Local gestures (set by [MixSync]). */
    var gestureTap: ((Gesture) -> Unit)?
    fun syncStatus(deck: Deck): MixSyncDeckStatus
    fun syncLoad(item: MixLoadable, deck: Deck)
    fun syncEject(deck: Deck)

    /** Start [deck] from [fromMs] at the LOCAL wall-clock instant [atLocalMs] (epoch ms): the instant it must be HEARD. */
    fun syncPlay(deck: Deck, fromMs: Int, atLocalMs: Double)

    /** Pause [deck] and cue it at [atMs]. */
    fun syncPause(deck: Deck, atMs: Int)

    /** One live non-transport event (tempo, FX, EQ, stems, lead, crossfader...). */
    fun syncApplyControl(e: MixSyncEvent)

    /** The deck's WHOLE control state ([controls] folded over defaults, diffed). Loop + transport excluded. */
    fun syncSetControls(deck: Deck, controls: List<MixSyncEvent>)

    /** Engage / re-place / release the loop on EXACTLY the owner's window (phase kept). */
    fun syncSetLoop(deck: Deck, on: Boolean, units: Double?, startMs: Int?, endMs: Int?)

    /** A temporary rate multiplier (<= +-1 %) on top of the deck's tempo; 1.0 restores it exactly. */
    fun syncNudgeRate(deck: Deck, factor: Double)

    /** What a fresh session starts from: this device's decks as events (load, every control, transport). */
    fun syncSeedEvents(deck: Deck): List<MixSyncEvent>
    val syncCrossfader: Double
    fun setAutoDjBlocked(reason: String?)

    /** A session is driving the decks: suspend durable persistence, drop a parked restore. */
    fun syncSessionActive(on: Boolean)
}

/** The shared clock's uncertainty, for the drift threshold (the rest of the clock rides [MixSyncSession]). */
interface MixSyncClockPort {
    /** Half of the best round trip to the host (0 until measured); the host's own clock is exact. */
    fun bestRttMs(): Double?
}

/** The pure arithmetic of the drift loop (iOS `MixSync.driftThreshold` / `offsetMs`). */
object MixSyncDrift {
    /**
     * The drift threshold: never under 40 ms, and never under what the two clocks can't tell apart (both uncertainties
     * + a margin): a relayed 200 ms RTT makes 40 ms of "drift" pure measurement noise.
     */
    fun threshold(ownUncertaintyMs: Double, theirUncertaintyMs: Double = 0.0): Int =
        max(MixSyncTunables.DRIFT_THRESHOLD_MS, ceil(ownUncertaintyMs + theirUncertaintyMs + MixSyncTunables.DRIFT_MARGIN_MS).toInt())

    /** local - expected, in ms. On a looping deck: the shortest way around the loop window (PHASE inside the loop). */
    fun offsetMs(st: MixSyncDeckStatus, expected: Int): Int {
        val s = st.loopStartMs
        val e = st.loopEndMs
        if (!st.looping || s == null || e == null || e <= s) return st.playheadMs - expected
        val len = e - s
        fun fold(x: Int): Int = s + Math.floorMod(x - s, len)
        var diff = fold(st.playheadMs) - fold(expected)
        if (diff > len / 2) diff -= len else if (diff < -len / 2) diff += len
        return diff
    }

    /** The scheduled start's instant + position for an anchor at [localAt]: never sooner than the minimum lead, never beyond the max. */
    fun startInstant(localAt: Double, nowMs: Double): Double =
        min(max(localAt, nowMs + MixSyncTunables.MIN_LEAD_MS), nowMs + MixSyncTunables.MAX_LEAD_MS)
}

/** Everything the Mix Together UI observes (published only when it actually changes). */
data class MixSyncUi(
    val active: Boolean = false,
    val owners: Map<Deck, String> = emptyMap(),
    /** Deck -> label of who drives it ("You", a device name, "Free"); only while active. */
    val ownerLabels: Map<Deck, String> = emptyMap(),
    /** Decks the local device may drive. */
    val controllable: Set<Deck> = Deck.entries.toSet(),
    val myDecks: List<Deck> = emptyList(),
    /** Decks whose session song can't be mixed on THIS device -> that song's title. */
    val unavailable: Map<Deck, String> = emptyMap(),
    /** Per deck: OTHER (or this) devices that can't sound it ("this device" first). */
    val unavailableOn: Map<Deck, List<String>> = emptyMap(),
    /** Decks THIS device's system paused (Rejoin offered). */
    val systemHeld: Set<Deck> = emptySet(),
    val statusMessage: String? = null,
    val participantNames: List<String> = emptyList(),
    val canStart: Boolean = false,
    val startBlockedReason: String? = null,
    val isHost: Boolean = false,
)

/**
 * MULTIPLAYER MIX over a Remote session, the engine-facing half (iOS `MixSync`): the ordering / echo / ownership core is
 * [MixSyncCore]; this class owns everything that touches THIS device's decks and clocks:
 *
 *  - local gestures become proposals (owned decks only; a gesture on a deck you don't own is undone from the mirror on
 *    the next tick); the SYSTEM's pause is local (the deck is HELD silent until the system resumes it, then it REJOINS at
 *    the anchor), engine housekeeping is ignored outright;
 *  - the host's anchors are applied as scheduled starts ([MixSyncDeckPort.syncPlay], `startLead` 300 ms ahead, 60 ms min /
 *    2 s max), the owner proposes a play only once its deck can SOUND, the host waits <= 4 s for its ready report;
 *  - the owner's deck sends a 2 s heartbeat; every other device compares it with its own deck and corrects drift past
 *    `40 ms + both clocks' uncertainty + 20 ms` seen on 2 consecutive beats: under 250 ms by a <= 1 % rate nudge, else a
 *    re-seek, with a 4 s cooldown. Beats staler than 1.5 s are ignored. Looping decks compare PHASE inside the loop;
 *  - readiness reports (`mix.ready`): a song this device can't mix leaves the deck EMPTY (silent) and says so.
 *
 * LOCAL ONLY: cue / PFL, the meter, recording and the session log. Single-threaded: confine to Main; [tick] runs every
 * 250 ms while a Remote session is live ([scope] non-null) or by hand in tests.
 */
class MixSync(
    private val session: MixSyncSession,
    private val clock: MixSyncClockPort,
    private val engine: MixSyncDeckPort,
    /** A session song -> something THIS device can put on a deck (null = not mixable here). */
    private val resolve: (MixSyncEvent) -> MixLoadable?,
    /** The Apple Music store id the local catalog knows for a song (stamped onto outbound loads). */
    private val appleMusicIdForSong: (String) -> String? = { null },
    /** The host's mix start yields the speakers to the decks (the Remote set stops). */
    private val onMixStarted: () -> Unit = {},
    private val logSink: (String) -> Unit = {},
    /** null = no auto tick / flush (unit tests drive [tick] / [core.flushOutbox] by hand). */
    private val scope: CoroutineScope? = null,
) : MixSyncSink {
    val core: MixSyncCore = MixSyncCore(session, this)

    private val _ui = MutableStateFlow(MixSyncUi())
    val ui: StateFlow<MixSyncUi> = _ui.asStateFlow()

    // ---- state

    /** The SESSION song id each deck currently mirrors on this device (absent = nothing loaded for it). */
    private val localSong = HashMap<Deck, String>()
    private val unavailableMap = LinkedHashMap<Deck, String>()
    private val reportedReady = HashMap<Deck, MixSyncReady>()
    private val repairQueue = LinkedHashSet<Deck>()
    private val readinessDirty = LinkedHashSet<Deck>()

    /** Decks this device's SYSTEM paused: silent here, not repaired, not heart-beaten, until the system resumes them / Rejoin. */
    val systemHeld: Set<Deck> get() = held.toSet()
    private val held = LinkedHashSet<Deck>()

    /** Owned decks whose play waits for the deck to be able to SOUND before it is proposed. */
    private val deferredPlay = LinkedHashSet<Deck>()
    private val lastBeatAt = HashMap<Deck, Double>()
    private val lastDriftFixAt = HashMap<Deck, Double>()
    private val driftStrikes = HashMap<Deck, Int>()

    /** A rate nudge in progress -> when it ends (local ms). */
    private val nudgeUntil = HashMap<Deck, Double>()

    /** Test seams: drift corrections made per deck (nudges + re-seeks), and the nudges alone. */
    val driftFixCount = HashMap<Deck, Int>()
    val nudgeCount = HashMap<Deck, Int>()

    private var tickJob: Job? = null
    private var flushJob: Job? = null

    private val now: Double get() = session.localNow()
    private val localId: String? get() = session.localId
    private val isHost: Boolean get() = localId != null && localId == session.hostId

    /** Test seam: the production tick loop is running. */
    val isTicking: Boolean get() = tickJob != null

    init {
        engine.gestureTap = { g -> localGesture(g) }
    }

    // ---- surface

    val isActive: Boolean get() = core.isActive
    val canStart: Boolean get() = core.canStart
    fun owner(deck: Deck): String? = core.owner(deck)
    val myDecks: List<Deck> get() = core.myDecks
    fun canControl(deck: Deck): Boolean = core.canControl(deck)
    fun start() = core.start().also { publish() }
    fun end() = core.end().also { publish() }
    fun claim(deck: Deck) = core.claim(deck).also { publish() }
    fun release(deck: Deck) = core.release(deck).also { publish() }
    fun name(id: String): String = core.name(id)
    val unavailable: Map<Deck, String> get() = unavailableMap

    /** The roster for the banner ("You" for this device). */
    val participantNames: List<String>
        get() = session.roster.sorted().map { if (it == localId) "You" else session.peerName(it) ?: "Someone" }

    /** The devices that can't mix [deck]'s song. */
    fun unavailableDevices(deck: Deck): List<String> {
        val out = ArrayList<String>()
        if (unavailableMap[deck] != null) out += "this device"
        for ((peer, decks) in core.peerReadiness) {
            if (peer != localId && decks[deck.label]?.status == MixSyncReady.Status.UNAVAILABLE) out += core.name(peer)
        }
        return out
    }

    private fun publish() {
        val active = core.isActive
        val owners = core.owners
        val ui = MixSyncUi(
            active = active,
            owners = owners,
            ownerLabels = if (active) Deck.entries.associateWith { d -> owners[d]?.let { core.name(it) } ?: "Free" } else emptyMap(),
            controllable = Deck.entries.filter { core.canControl(it) }.toSet(),
            myDecks = core.myDecks,
            unavailable = unavailableMap.toMap(),
            unavailableOn = if (active) Deck.entries.associateWith { unavailableDevices(it) }.filterValues { it.isNotEmpty() } else emptyMap(),
            systemHeld = held.toSet(),
            statusMessage = core.statusMessage,
            participantNames = participantNames,
            canStart = core.canStart,
            startBlockedReason = core.startBlockedReason,
            isHost = isHost,
        )
        if (ui != _ui.value) _ui.value = ui
    }

    // ---- lifecycle

    /** The Remote session went live / ended: the tick runs only while a session is live (never from launch). */
    fun sessionChanged(live: Boolean) {
        val sc = scope
        if (live) {
            if (sc == null || tickJob != null) return
            tickJob = sc.launch {
                while (true) {
                    tick()
                    delay(MixSyncTunables.TICK_INTERVAL_MS.toLong())
                }
            }
        } else {
            tick() // sees the session gone -> the mix ends here
            tickJob?.cancel(); tickJob = null
            flushJob?.cancel(); flushJob = null
        }
    }

    /** The Banner's Rejoin: every deck this device's system silenced comes back at the session's anchor. */
    fun rejoin() {
        if (!core.isActive || held.isEmpty()) return
        val decks = held.toList().sortedBy { it.label }
        held.clear()
        logSink("mix rejoin decks=${decks.joinToString("") { it.label }}")
        for (d in decks) reconcileDeck(d)
        publish()
    }

    // ---- tick

    /** One heartbeat (250 ms in production; tests call it directly). */
    fun tick() {
        core.tick()
        if (!session.isSessionActive || !core.isActive) { publish(); return }
        val t = now
        for (d in Deck.entries) reportReadiness(d)
        readinessDirty.clear()
        flushDeferredPlays()
        for ((d, until) in nudgeUntil.entries.toList()) {
            if (t >= until) {
                nudgeUntil.remove(d)
                engine.syncNudgeRate(d, 1.0) // the deck's own tempo, exactly
                lastDriftFixAt[d] = t // the cooldown runs from the nudge's END
            }
        }
        val repairs = repairQueue.filter { it !in held }.sortedBy { it.label }
        repairQueue.removeAll(repairs.toSet())
        for (d in repairs) reconcileDeck(d)
        sendHeartbeats(t)
        publish()
    }

    // ---- sink (the core's callbacks)

    override fun onActive(on: Boolean) {
        engine.syncSessionActive(on)
        if (on) {
            engine.setAutoDjBlocked(MixSyncTunables.AUTO_DJ_BLOCKED_REASON)
        } else {
            engine.setAutoDjBlocked(null)
            for (d in nudgeUntil.keys.toList()) engine.syncNudgeRate(d, 1.0)
            nudgeUntil.clear()
            driftStrikes.clear()
            unavailableMap.clear()
            repairQueue.clear()
            reportedReady.clear()
            held.clear()
            deferredPlay.clear()
            readinessDirty.clear()
            localSong.clear()
            lastBeatAt.clear()
            lastDriftFixAt.clear()
        }
        publish()
    }

    override fun onApply(e: MixSyncEvent) {
        applyToEngine(e)
        publish()
    }

    override fun onMirrorChanged(deck: Deck, kind: String) {
        // The mirror names this deck's song: say at once whether it can sound here (a held start of the owner's waits on
        // exactly this report). When this device hasn't applied the load yet, onApply reports it itself.
        val sid = core.model.deck(deck).track?.songId
        if (kind == MixSyncKind.EJECT || localSong[deck] == sid) reportReadiness(deck) else readinessDirty += deck
    }

    override fun onSnapshotAdopted(model: MixSyncModel) {
        val x = model.crossfader
        if (x != null && abs(engine.syncCrossfader - x) > 1e-6) {
            engine.syncApplyControl(MixSyncEvent(MixSyncKind.CROSSFADER, value = x))
        }
        for (d in Deck.entries) reconcileDeck(d)
        publish()
    }

    override fun onRepair(deck: Deck) { repairQueue += deck }
    override fun onOwnersChanged(owners: Map<Deck, String>) = publish()
    override fun onStatus(message: String?) = publish()
    override fun onBeat(deck: Deck, beat: MixSyncBeat, from: String) = driftCheck(deck, beat.anchor, beat.songId, beat.uncertaintyMs ?: 0.0)
    override fun onSessionStarted() { onMixStarted(); publish() }
    override fun log(line: String) = logSink(line)
    override fun localCrossfader(): Double = engine.syncCrossfader

    override fun localDeckReady(deck: Deck, songId: String): Boolean =
        localSong[deck] == songId && engine.syncStatus(deck).ready

    override fun seedEvents(deck: Deck): List<MixSyncEvent> = engine.syncSeedEvents(deck).map { e ->
        if (e.kind == MixSyncKind.LOAD && e.songId != null) {
            localSong[deck] = e.songId
            e.copy(appleMusicId = appleMusicIdForSong(e.songId))
        } else e
    }

    override fun scheduleFlush(atLocalMs: Double) {
        val sc = scope ?: return // tests flush from tick / core.flushOutbox
        if (flushJob != null) return
        flushJob = sc.launch {
            while (true) {
                val due = core.nextOutboxDue ?: break
                delay(max(5.0, due - now).toLong())
                core.flushOutbox(now)
                if (core.nextOutboxDue == null) break
            }
            flushJob = null
        }
    }

    // ---- local gestures -> proposals

    /** A gesture of THIS device's engine (the engine's tap; never fires for a remote apply). */
    internal fun localGesture(g: Gesture) {
        if (!core.isActive || localId == null) return
        val me = localId ?: return
        when (g.cause) {
            Gesture.Cause.ENGINE -> return // the engine's own housekeeping: never shared
            Gesture.Cause.SYSTEM -> {
                // THIS device's system transport: local only. A pause holds the deck silent here; a resume rejoins at the anchor.
                val d = g.deck ?: return
                if (g.kind == MixSyncKind.PAUSE) {
                    held += d
                    deferredPlay -= d
                } else if (g.kind == MixSyncKind.PLAY) {
                    held -= d
                    repairQueue += d
                }
                publish()
                return
            }
            Gesture.Cause.USER -> Unit
        }
        var e = MixSyncEvent(
            kind = g.kind, deck = g.deck?.label, param = g.param, value = g.value, flag = g.flag, slot = g.slot, posMs = g.posMs,
        )
        if (g.kind == MixSyncKind.CROSSFADER) { core.propose(e); publish(); return }
        val d = g.deck ?: return // auto-DJ markers etc.: not shared
        val wasHeld = held.remove(d)
        if (g.kind == MixSyncKind.PLAY && held.isNotEmpty()) {
            // The DJ is back: EVERY deck the system silenced here rejoins (a deck another DJ owns has a read-only play).
            repairQueue += held
            held.clear()
        }
        if (wasHeld && g.kind == MixSyncKind.PLAY && core.model.deck(d).anchor?.isPlaying == true) {
            // Play on a deck the system silenced while the session kept playing: REJOIN, never re-anchor everyone onto here.
            repairQueue += d
            publish()
            return
        }
        if (core.model.owner(d) != me) {
            // Not my deck: the gesture is undone from the mirror next tick. A deck that ran out of track isn't a gesture at all.
            val st = engine.syncStatus(d)
            if (g.kind == MixSyncKind.PAUSE && st.durationMs > 0 && st.playheadMs >= st.durationMs - 500) return
            repairQueue += d
            // Undo it NOW (a posted hop, so the engine finishes the gesture first), not on the next 250 ms tick.
            scope?.launch {
                if (d in repairQueue && d !in held) {
                    repairQueue -= d
                    reconcileDeck(d)
                    publish()
                }
            }
            return
        }
        when (g.kind) {
            MixSyncKind.LOAD -> {
                val t = g.track ?: return
                e = e.copy(
                    songId = t.songId, title = t.title, artist = t.artist, bpm = t.bpm, camelot = t.camelot, key = t.key,
                    albumId = t.albumId, lengthMs = g.lengthMs, appleMusicId = appleMusicIdForSong(t.songId),
                )
                localSong[d] = t.songId
                setUnavailable(d, null)
                deferredPlay -= d
            }
            MixSyncKind.EJECT -> {
                localSong.remove(d)
                setUnavailable(d, null)
                deferredPlay -= d
            }
            MixSyncKind.PLAY -> {
                // Propose a start only once this deck can SOUND: a buffering owner would otherwise anchor everyone to a playhead that isn't moving yet.
                if (!engine.syncStatus(d).ready) { deferredPlay += d; return }
                deferredPlay -= d
                e = e.copy(anchor = currentAnchor(d))
            }
            MixSyncKind.PAUSE -> {
                deferredPlay -= d
                e = e.copy(anchor = currentAnchor(d))
            }
            MixSyncKind.SEEK -> {
                val st = engine.syncStatus(d)
                // A scrub on a LOOPING deck moves the loop: share the new window FIRST, so receivers place it before the seek lands inside it.
                if (st.looping) {
                    core.propose(MixSyncEvent(MixSyncKind.LOOP, deck = d.label, flag = true, loopStartMs = st.loopStartMs, loopEndMs = st.loopEndMs))
                }
                e = e.copy(anchor = currentAnchor(d))
            }
            MixSyncKind.RESET_DECK -> e = e.copy(anchor = currentAnchor(d)) // reset rewinds everyone at ONE shared instant
            MixSyncKind.LOOP, MixSyncKind.LOOP_UNITS -> {
                // One loop state per deck: the window travels with every loop / length / edge change.
                e = e.copy(kind = MixSyncKind.LOOP, loopStartMs = g.loopStartMs, loopEndMs = g.loopEndMs)
                if (e.flag == null) e = e.copy(flag = engine.syncStatus(d).looping)
            }
        }
        core.propose(e)
        if (g.kind == MixSyncKind.LOAD || g.kind == MixSyncKind.EJECT) reportReadiness(d)
        publish()
    }

    private fun currentAnchor(d: Deck): MixSyncAnchor {
        val st = engine.syncStatus(d)
        return MixSyncAnchor(st.playheadMs, session.sharedNow(), st.isPlaying)
    }

    /** Owned decks whose play waited for bytes: propose the start the moment the deck can sound (anchor off the moving playhead). */
    private fun flushDeferredPlays() {
        for (d in deferredPlay.toList().sortedBy { it.label }) {
            val st = engine.syncStatus(d)
            if (!st.isPlaying || core.model.owner(d) != localId) { deferredPlay -= d; continue }
            if (!st.ready) continue
            deferredPlay -= d
            core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = d.label, posMs = st.playheadMs, anchor = currentAnchor(d)))
        }
    }

    // ---- apply (every device, host order)

    private fun applyToEngine(e: MixSyncEvent) {
        val d = e.engineDeck
        if (d == null) {
            if (e.kind == MixSyncKind.CROSSFADER) engine.syncApplyControl(e)
            return
        }
        when (e.kind) {
            MixSyncKind.LOAD -> {
                loadLocally(d, e)
                // A joiner's / follower's deck takes the SESSION's board with the song (never this device's own leftovers).
                if (localSong[d] != null) engine.syncSetControls(d, core.model.deck(d).controls)
            }
            MixSyncKind.EJECT -> {
                if (engine.syncStatus(d).songId != null) engine.syncEject(d)
                localSong.remove(d)
                setUnavailable(d, null)
                reportReadiness(d)
            }
            MixSyncKind.PLAY, MixSyncKind.PAUSE, MixSyncKind.SEEK -> {
                // A deck the system silenced here stays silent until it rejoins (never mid-call).
                if (d in held) return
                e.anchor?.let { applyAnchor(d, it) }
            }
            MixSyncKind.RESET_DECK -> {
                if (localSong[d] == null) return
                engine.syncSetControls(d, core.model.deck(d).controls) // the model already folded the reset
                val a = e.anchor ?: core.model.deck(d).anchor
                if (d !in held && a != null) applyAnchor(d, a)
            }
            MixSyncKind.LOOP, MixSyncKind.LOOP_UNITS -> {
                if (localSong[d] == null) return
                applyLoop(d, e)
            }
            else -> {
                if (localSong[d] == null) return // nothing here to apply it to (unavailable)
                engine.syncApplyControl(e)
            }
        }
    }

    private fun applyLoop(d: Deck, e: MixSyncEvent?) {
        if (e == null) {
            if (engine.syncStatus(d).looping) engine.syncSetLoop(d, false, null, null, null)
            return
        }
        engine.syncSetLoop(d, e.flag ?: engine.syncStatus(d).looping, e.value, e.loopStartMs, e.loopEndMs)
    }

    /** Put the session's song for [d] on this device's deck, or, when this device can't mix it, leave the deck EMPTY (silent) and say so. */
    private fun loadLocally(d: Deck, e: MixSyncEvent) {
        val loadable = resolve(e)
        if (loadable == null) {
            if (engine.syncStatus(d).songId != null) engine.syncEject(d)
            localSong.remove(d)
            setUnavailable(d, e.title ?: "This song")
            reportReadiness(d)
            logSink("mix deck ${d.label}: ${e.songId ?: "-"} not mixable here")
            return
        }
        if (engine.syncStatus(d).songId != loadable.songId) engine.syncLoad(loadable, d)
        e.songId?.let { localSong[d] = it }
        setUnavailable(d, null)
        reportReadiness(d)
    }

    /**
     * Make the deck match the mirror EXACTLY (a joiner, a snapshot, a refused / stray local gesture, a system resume): the
     * song, its whole board (unlisted controls -> default), the transport at the anchor, THEN the loop window.
     */
    private fun reconcileDeck(d: Deck) {
        if (!core.isActive) return
        val ds = core.model.deck(d)
        val t = ds.track
        if (t == null) {
            if (engine.syncStatus(d).songId != null) engine.syncEject(d)
            localSong.remove(d)
            setUnavailable(d, null)
            reportReadiness(d)
            return
        }
        loadLocally(d, t)
        if (localSong[d] == null) return
        engine.syncSetControls(d, ds.controls)
        val a = ds.anchor
        if (a != null && d !in held) applyAnchor(d, a)
        applyLoop(d, ds.controls.lastOrNull { it.kind == MixSyncKind.LOOP || it.kind == MixSyncKind.LOOP_UNITS })
    }

    // ---- timing math

    /** My clock's uncertainty against the shared timeline (1/2 the best RTT; 0 on the host). */
    private val clockUncertaintyMs: Double get() = if (isHost) 0.0 else (clock.bestRttMs() ?: 0.0) / 2

    fun driftThreshold(theirUncertaintyMs: Double = 0.0): Int = MixSyncDrift.threshold(clockUncertaintyMs, theirUncertaintyMs)

    /** local->shared: shared = local + offset (null until the clock has a sample on THIS host). */
    private fun localTime(forShared: Double): Double? = session.offsetToCurrentHost()?.let { forShared - it }

    /**
     * Drive the deck to the anchor: start at the shared instant (position-corrected when that instant is already too close),
     * or pause + cue. No-op when the deck already matches within the drift threshold: applying the same state twice never re-seeks.
     */
    private fun applyAnchor(d: Deck, a: MixSyncAnchor, force: Boolean = false) {
        val st = engine.syncStatus(d)
        if (st.songId == null) return
        val t = now
        val threshold = driftThreshold()
        if (a.isPlaying) {
            val at = a.atSharedTime
            val localAt = at?.let { localTime(it) }
            if (at == null || localAt == null) {
                // No shared clock yet: start now from the anchor (the heartbeat corrects later).
                if (!st.isPlaying) engine.syncPlay(d, a.positionMs, t)
                return
            }
            if (st.isPlaying && !force) {
                val expected = a.positionMs + Math.round((t - localAt) * st.rate).toInt()
                if (abs(MixSyncDrift.offsetMs(st, expected)) <= threshold) return
            }
            // Never sooner than the minimum lead, never further out than the max (a start pulled in sounds where the deck would be by then).
            val start = MixSyncDrift.startInstant(localAt, t)
            val pos = a.positionMs + Math.round((start - localAt) * st.rate).toInt()
            if (!st.looping && st.durationMs > 0 && pos >= st.durationMs - 100) {
                engine.syncPause(d, st.durationMs) // the track already ended there
                return
            }
            engine.syncPlay(d, max(0, pos), start)
        } else {
            if (!st.isPlaying && abs(st.playheadMs - a.positionMs) <= threshold) return
            engine.syncPause(d, a.positionMs)
        }
    }

    // ---- drift

    private fun sendHeartbeats(t: Double) {
        val me = localId ?: return
        val shared = session.sharedNow() ?: return
        for (d in Deck.entries) {
            val owner = core.model.owner(d)
            val mine = owner == me || (owner == null && isHost)
            // A system-silenced or still-buffering deck is not the reference anyone should chase.
            if (!mine || d in held || d in deferredPlay) continue
            val sid = core.model.deck(d).track?.songId ?: continue
            if (localSong[d] != sid) continue
            if (t - (lastBeatAt[d] ?: Double.NEGATIVE_INFINITY) < MixSyncTunables.HEARTBEAT_MS) continue
            val st = engine.syncStatus(d)
            if (st.songId == null) continue
            lastBeatAt[d] = t
            val a = MixSyncAnchor(st.playheadMs, shared, st.isPlaying)
            core.noteLocalAnchor(d, a) // snapshots + repairs stay fresh
            core.sendBeat(MixSyncBeat(d.label, sid, a, core.model.epoch, clockUncertaintyMs))
        }
    }

    /**
     * A heartbeat from the deck's owner. Corrections need a clock measured on THIS host, a fresh beat, the offset past the
     * threshold on 2 consecutive beats, and the cooldown since the last fix (a correction's own settling is never chased).
     * Small drift is slid back with a <= 1 % rate nudge; large drift (or a play/pause mismatch) re-seeks.
     */
    private fun driftCheck(d: Deck, a: MixSyncAnchor, songId: String, theirUncertaintyMs: Double) {
        if (!core.isActive || d in held || core.model.deck(d).track?.songId != songId || localSong[d] != songId) return
        val at = a.atSharedTime ?: return
        if (session.offsetToCurrentHost() == null) return // a clock not measured on this host
        val shared = session.sharedNow() ?: return
        if (shared - at > MixSyncTunables.STALE_BEAT_MS) return
        val t = now
        val st = engine.syncStatus(d)
        if (st.songId == null) return
        var offset = 0
        val mismatch = a.isPlaying != st.isPlaying
        if (!mismatch) {
            if (!a.isPlaying) { driftStrikes[d] = 0; return }
            if (nudgeUntil[d] != null) return // a nudge is already sliding it back
            val expected = a.position(shared, st.rate)
            if (!st.looping && st.durationMs > 0 && expected >= st.durationMs - 250) return
            offset = MixSyncDrift.offsetMs(st, expected)
            if (abs(offset) <= driftThreshold(theirUncertaintyMs)) { driftStrikes[d] = 0; return }
        }
        val strikes = (driftStrikes[d] ?: 0) + 1
        driftStrikes[d] = strikes
        if (strikes < MixSyncTunables.DRIFT_STRIKES_NEEDED) return
        if (t - (lastDriftFixAt[d] ?: Double.NEGATIVE_INFINITY) < MixSyncTunables.DRIFT_COOLDOWN_MS) return
        driftStrikes[d] = 0
        lastDriftFixAt[d] = t
        driftFixCount[d] = (driftFixCount[d] ?: 0) + 1
        if (!mismatch && abs(offset) < MixSyncTunables.NUDGE_MAX_MS) {
            // Ahead => run 1 % slow (behind => fast) for exactly as long as it takes to close it.
            val factor = if (offset > 0) 1 - MixSyncTunables.NUDGE_RATE else 1 + MixSyncTunables.NUDGE_RATE
            nudgeUntil[d] = t + abs(offset) / MixSyncTunables.NUDGE_RATE
            nudgeCount[d] = (nudgeCount[d] ?: 0) + 1
            logSink("mix drift deck ${d.label}: $offset ms -> nudge x$factor")
            engine.syncNudgeRate(d, factor)
            return
        }
        logSink("mix drift deck ${d.label}: local=${st.playheadMs} playing=${st.isPlaying} off=$offset -> re-seek")
        applyAnchor(d, a, force = true)
    }

    // ---- readiness

    private fun readiness(d: Deck): MixSyncReady {
        val sid = core.model.deck(d).track?.songId ?: return MixSyncReady(d.label, null, MixSyncReady.Status.EMPTY)
        if (unavailableMap[d] != null || localSong[d] != sid) {
            return MixSyncReady(d.label, sid, if (unavailableMap[d] != null) MixSyncReady.Status.UNAVAILABLE else MixSyncReady.Status.LOADING)
        }
        return MixSyncReady(d.label, sid, if (engine.syncStatus(d).ready) MixSyncReady.Status.READY else MixSyncReady.Status.LOADING)
    }

    private fun reportReadiness(d: Deck) {
        if (!core.isActive || localId == null) return
        val r = readiness(d)
        if (reportedReady[d] == r) return
        reportedReady[d] = r
        core.sendReady(r)
    }

    private fun setUnavailable(d: Deck, title: String?) {
        if (unavailableMap[d] == title) return
        if (title == null) unavailableMap.remove(d) else unavailableMap[d] = title
    }

    companion object {
        /** `ceil` helper kept public for the UI's rounding of a threshold readout. */
        fun roundMs(x: Double): Int = x.roundToInt()
    }
}

/** The production [MixSyncDeckPort] over the real [MixEngine] (iOS `extension MixEngine: MixSyncEngine`). */
class MixEnginePort(private val engine: MixEngine) : MixSyncDeckPort {
    override var gestureTap: ((Gesture) -> Unit)?
        get() = engine.gestureTap
        set(v) { engine.gestureTap = v }

    override fun syncStatus(deck: Deck): MixSyncDeckStatus {
        val l = engine.loaded(deck)
        val w = engine.loopWindowMs(deck)
        return MixSyncDeckStatus(
            songId = l?.songId, isPlaying = engine.isPlaying(deck),
            playheadMs = Math.round(engine.audiblePlayhead(deck) * 1000).toInt(),
            durationMs = Math.round(engine.duration(deck) * 1000).toInt(), rate = engine.rate(deck),
            ready = l != null && !engine.streamHeld(deck), looping = w != null, loopStartMs = w?.first, loopEndMs = w?.second,
        )
    }

    /** SYNCHRONOUS load (the same path the Auto-DJ uses): an async commit would land OUTSIDE the remote guard and tap as a user load. */
    override fun syncLoad(item: MixLoadable, deck: Deck) = engine.applyingRemote { engine.loadNow(item, deck) }

    override fun syncEject(deck: Deck) {
        // Cue / PFL is per device: an eject the session asked for must not drop this DJ's cue.
        val cue = engine.cued(deck)
        val cueVol = engine.cueVolume(deck)
        engine.applyingRemote { engine.clearDeck(deck) }
        engine.setCued(cue, deck)
        engine.setCueVolume(cueVol, deck)
    }

    override fun syncPlay(deck: Deck, fromMs: Int, atLocalMs: Double) = engine.syncPlay(deck, fromMs, atLocalMs)

    override fun syncPause(deck: Deck, atMs: Int) = engine.applyingRemote {
        if (engine.isPlaying(deck)) engine.pause(deck)
        if (abs(engine.position(deck) * 1000 - atMs) > MixSyncTunables.DRIFT_THRESHOLD_MS) engine.seek(deck, atMs / 1000.0)
    }

    override fun syncApplyControl(e: MixSyncEvent) = engine.applyingRemote {
        if (e.kind == MixSyncKind.CROSSFADER) { e.value?.let { engine.setCrossfader(it) }; return@applyingRemote }
        val d = e.engineDeck ?: return@applyingRemote
        val slot = e.slot
        when (e.kind) {
            MixSyncKind.TEMPO, MixSyncKind.SYNC -> e.value?.let { engine.setRate(it, d) }
            "pitch" -> e.value?.let { engine.setPitch(it, d) }
            "volume" -> e.value?.let { engine.setVolume(it, d) }
            "eq" -> {
                val v = e.value
                val band = EQBand.entries.firstOrNull { it.label.equals(e.param, ignoreCase = true) }
                if (v != null && band != null) engine.setEqGain(band, v, d)
            }
            "effectToggle" -> {
                val on = e.flag ?: return@applyingRemote
                if (slot != null) engine.setSlot(slot, on, d) else Effect.fromRaw(e.param)?.let { engine.setEffect(it, on, d) }
            }
            "effectStrength" -> {
                val v = e.value ?: return@applyingRemote
                if (slot != null) engine.setSlotStrength(slot, v, d) else Effect.fromRaw(e.param)?.let { engine.setEffectStrength(it, v, d) }
            }
            "effectSlot" -> {
                val fx = Effect.fromRaw(e.param)
                if (slot != null && fx != null) engine.setSlotEffect(fx, slot, d)
            }
            "effectVariant" -> {
                val v = EffectVariant.fromRaw(e.param)
                if (slot != null && v != null) engine.setSlotVariant(v, slot, d)
            }
            "effectMod" -> {
                val i = slot ?: return@applyingRemote
                val parts = e.param?.split(":") ?: return@applyingRemote
                if (parts.size != 3) return@applyingRemote
                val src = ModSource.fromRaw(parts[0]) ?: return@applyingRemote
                val r = ModRate.fromRaw(parts[1]) ?: return@applyingRemote
                val shape = ModShape.fromRaw(parts[2]) ?: return@applyingRemote
                engine.setSlotMod(SlotMod(src, r, e.value ?: 0.5, shape, engine.slot(i, d)?.mod?.phase ?: 0.0), i, d)
            }
            "filterMode" -> {
                val hp = e.param == "highPass"
                val lp = e.param == "lowPass"
                val i = engine.slots(d).indexOfFirst { it.effect == Effect.FILTER }
                if ((hp || lp) && i >= 0) {
                    engine.setSlotVariant(if (hp) EffectVariant.HIGH_PASS else EffectVariant.LOW_PASS, i, d)
                }
            }
            "stemMode" -> e.flag?.let { engine.syncExtras?.setStemMode(d, it) }
            "stemMute" -> {
                val name = e.param
                val muted = e.flag
                if (name != null && muted != null && (name in engine.deckState(d).stemMuted) != muted) engine.syncExtras?.toggleStemMute(d, name)
            }
            "stemVolume" -> {
                val name = e.param
                val v = e.value
                if (name != null && v != null) engine.syncExtras?.setStemVolume(d, name, v)
            }
            MixSyncKind.LEAD -> if ((e.flag ?: false) != engine.isLead(d)) engine.setLead(d)
            MixSyncKind.RESET_DECK -> engine.resetDeck(d)
            MixSyncKind.LOOP, MixSyncKind.LOOP_UNITS ->
                engine.syncSetLoop(d, e.flag ?: (engine.loopWindowMs(d) != null), e.value, e.loopStartMs, e.loopEndMs)
            else -> Unit // a kind this build doesn't apply: ignored
        }
    }

    override fun syncSetControls(deck: Deck, controls: List<MixSyncEvent>) = engine.syncSetControls(deck, controls)

    override fun syncSetLoop(deck: Deck, on: Boolean, units: Double?, startMs: Int?, endMs: Int?) =
        engine.syncSetLoop(deck, on, units, startMs, endMs)

    override fun syncNudgeRate(deck: Deck, factor: Double) = engine.syncNudgeRate(deck, factor)

    override fun syncSeedEvents(deck: Deck): List<MixSyncEvent> {
        val out = ArrayList(engine.syncSeedEvents(deck)) // load + the WHOLE board
        if (out.isEmpty()) return out
        val st = syncStatus(deck)
        out += MixSyncEvent(
            if (st.isPlaying) MixSyncKind.PLAY else MixSyncKind.PAUSE, deck = deck.label,
            anchor = MixSyncAnchor(st.playheadMs, null, st.isPlaying),
        )
        return out
    }

    override val syncCrossfader: Double get() = engine.crossfader
    override fun setAutoDjBlocked(reason: String?) = engine.setAutoDjBlocked(reason)
    override fun syncSessionActive(on: Boolean) = engine.syncSessionActive(on)
}

/** [MixSyncClockPort] over the controller's shared clock. */
class ControllerClockPort(private val c: RemoteSessionController) : MixSyncClockPort {
    override fun bestRttMs(): Double? = c.clock.best?.rttMs
}

/**
 * Binds Mix Together to the Remote controller, behind [com.levi.pocketdj.ParityFlags.MIX_TOGETHER]: the hello advertises
 * `caps:["mix"]` (a device that can own a deck), every `mix.*` kind is routed to the core, the live mix counts as session
 * ACTIVITY for host election, and the 250 ms tick runs while a session is live. [build] constructs the (lazy) [MixSync] the
 * first time a session needs it; [ifBuilt] never constructs it.
 */
object MixTogetherInstaller {
    fun install(controller: RemoteSessionController, build: () -> MixSync, ifBuilt: () -> MixSync?) {
        if (!com.levi.pocketdj.ParityFlags.MIX_TOGETHER) return
        if (MixCapability.DECK_OWNER !in controller.localCaps) controller.localCaps = controller.localCaps + MixCapability.DECK_OWNER
        for (k in MixWireKind.all) controller.registerHandler(k) { env, from -> build().core.receive(env, from) }
        controller.registerActivityProbe { ifBuilt()?.isActive == true }
        controller.registerSessionObserver { live -> if (live) build().sessionChanged(true) else ifBuilt()?.sessionChanged(false) }
    }

    /** A session song -> a deck-loadable song on THIS device (mp3 only, L6): the same id when burned / streamable, else the catalog match. */
    fun resolver(
        loadables: (List<String>) -> List<MixLoadable>,
        resolve: (com.levi.pocketdj.remote.RemoteRow) -> com.levi.pocketdj.remote.RemoteResolution,
    ): (MixSyncEvent) -> MixLoadable? = fun(e: MixSyncEvent): MixLoadable? {
        val sid = e.songId ?: return null
        loadables(listOf(sid)).firstOrNull()?.let { return it }
        val row = com.levi.pocketdj.remote.RemoteRow(
            rid = "mix",
            row = com.levi.pocketdj.playback.durable.SessionRow(
                songId = sid, title = e.title ?: "", artist = e.artist ?: "", lengthMs = e.lengthMs?.toLong(), appleMusicId = e.appleMusicId,
            ),
        )
        return when (val r = resolve(row)) {
            is com.levi.pocketdj.remote.RemoteResolution.Catalog, is com.levi.pocketdj.remote.RemoteResolution.Matched ->
                r.item?.let { loadables(listOf(it.id)).firstOrNull() }
            // Apple Music playback is never mixable (no decks over a DRM stream).
            else -> null
        }
    }
}
