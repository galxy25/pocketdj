package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.AutoRepeatMode
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.store.AutoRow
import com.levi.pocketdj.mix.store.AutoSnapshot
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.TrackRef
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import kotlin.random.Random

/** The Auto-DJ's observable surface for the Mix banner / queue UIs. */
data class AutoUiState(
    val mixing: Boolean = false,
    val paused: Boolean = false,
    val transitioning: Boolean = false,
    val status: String? = null,
    val livePos: Int = 0,
    val queueSize: Int = 0,
    val liveDeck: Deck = Deck.A,
    val repeat: AutoRepeatMode = AutoRepeatMode.OFF,
    val fxGlide: Boolean = false,
    val mixGlide: Boolean = false,
    val sourceLabel: String? = null,
    /** Auto/Manual toggle (engine is the source of truth; the Mix screen mirrors it). */
    val enabled: Boolean = false,
)

/**
 * The Auto-DJ machine (iOS `MixEngine` auto section). Plugs into [MixEngine] through
 * [AutoDjHooks]; MAIN THREAD ONLY. Time is the engine's injectable wall clock ([MixEngine.nowMs]),
 * so the whole machine is JVM-testable with fake voices.
 *
 * A transition runs, in order: PRE-ROLL (glide only) -> CROSSFADE (the volume sweep) -> POST-ROLL
 * (glide only); with no glide feature on only the crossfade phase is ever entered.
 *
 * Invariants carried over from iOS (see the status file for the full list):
 *  - the cursor ([livePos]/[nextToLoad]) only moves in [finishAutoCrossfade] (and resume/drop paths);
 *  - nothing is ever dropped for a CLOSED STREAM GATE (deferred), only for a permanently
 *    unloadable song;
 *  - held (buffering) seconds don't advance the live deck's end clock;
 *  - a remote pause FREEZES every armed clock; remote play shifts them by the frozen interval.
 */
class AutoDj(
    internal val engine: MixEngine,
    seams: AutoSeams? = null,
    internal val shuffleRandom: Random = Random.Default,
    /** Seconds a held live deck waits before handing over to a ready song. */
    internal val stallSkipSeconds: Double = AutoReadiness.STALL_SKIP_SECONDS,
) : AutoDjHooks {

    var seams: AutoSeams = seams ?: EngineAutoSeams(engine)
    private var lastNoLoadableKey: String? = null

    val glide = GlideMachine(this)
    internal val readiness = AutoReadinessOps(this)

    // ------------------------------------------------------------------------------ state

    var enabled = false; private set
    private var mixing = false
    private var paused = false
    override val isMixing: Boolean get() = mixing
    override val isPaused: Boolean get() = paused

    internal val queue = ArrayList<AutoMixItem>()
    internal var livePos = 0
    internal var nextToLoad = 0
    internal var liveDeck = Deck.A
    internal var fadeFrom = Deck.A
    var leadSeconds = 15.0; private set
    internal var fadeSeconds = 3.0
    /** A one-off manual Skip's custom fade: the baseline to restore once the crossfade finishes. */
    internal var pendingFadeRestore: Double? = null
    var repeat = AutoRepeatMode.OFF; private set
    var sourceLabel: String? = null; private set
    /** The lock-screen slow-skip length (Settings > Mix "Skip fade"). */
    var skipFadeSeconds = 15.0; private set

    internal var fadeStartedAt: Long? = null
    internal val deckEndsAt = HashMap<Deck, Long>()
    internal val deckDurationMs = HashMap<Deck, Int>()
    internal var extending = false
    internal var fadeHeldSince: Long? = null
    private var awaitLogged: String? = null
    private var resumeEndDeck: Deck? = null
    private var resumeFromRestore = false
    internal var transitionRepeatOne = false
    internal var transitionWrap = false
    private var resumeAutoOnRemotePlay = false
    /** Non-null <=> the wall clock is frozen by a remote pause. */
    internal var remotePausedAt: Long? = null; private set
    /** Non-null <=> the sink is down under a live mix (clocks parked). */
    internal var engineStallAt: Long? = null; private set
    private val streamHeldSince = HashMap<Deck, Long>()

    /** Lock-screen next/previous enablement (MIX-11 wires this to the media session). */
    var onSkipCommandsEnabled: ((Boolean) -> Unit)? = null

    private val _ui = MutableStateFlow(AutoUiState())
    val ui: StateFlow<AutoUiState> = _ui.asStateFlow()
    val autoStatus: String? get() = _ui.value.status

    /** A transition (preroll, crossfade or postroll) is in progress. */
    val autoTransitioning: Boolean
        get() = glide.prerollStartedAt != null || fadeStartedAt != null || glide.postrollStartedAt != null

    val queueSize: Int get() = queue.size
    val queueSongIds: List<String> get() = queue.map { it.loadable.songId }
    val fxGlideEnabled: Boolean get() = glide.fxGlideEnabled
    val mixGlideEnabled: Boolean get() = glide.mixGlideEnabled
    val remoteFrozen: Boolean get() = remotePausedAt != null
    val engineStalled: Boolean get() = engineStallAt != null

    internal fun advLog(msg: String) = engine.diag("mixadvance $msg")
    private fun now() = engine.nowMs()
    private fun f1(v: Double) = String.format(Locale.US, "%.1f", v)

    // ------------------------------------------------------------------------------ toggles

    fun setAutoEnabled(on: Boolean) {
        enabled = on
        if (!on) endAutoLoop()
        refreshStatus()
    }

    fun setFXGlide(on: Boolean) { glide.fxGlideEnabled = on; refreshStatus() }
    fun setMixGlide(on: Boolean) { glide.mixGlideEnabled = on; refreshStatus() }
    fun setMixGlideSeconds(s: Double) = glide.setMixGlideSeconds(s)
    fun setSkipFadeSeconds(s: Double) { skipFadeSeconds = maxOf(1.0, s) }

    fun setAutoRepeat(mode: AutoRepeatMode) {
        if (repeat == mode) return
        repeat = mode
        engine.persist()   // survives a kill with the auto session
        refreshStatus()
    }

    /** off -> all -> one -> off. */
    fun cycleAutoRepeat() = setAutoRepeat(
        when (repeat) {
            AutoRepeatMode.OFF -> AutoRepeatMode.ALL
            AutoRepeatMode.ALL -> AutoRepeatMode.ONE
            AutoRepeatMode.ONE -> AutoRepeatMode.OFF
        },
    )

    // ------------------------------------------------------------------------------ start / stop

    fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String? = null) {
        if (items.isEmpty()) return
        engine.noteSounded()
        engine.ensureEngine()
        endAutoLoop()

        // Starting an Auto Mix takes over BOTH decks: fully EJECT them first (volume/boost, effects,
        // stems, loops AND the cue send; `resetDeck` deliberately keeps cue, an eject doesn't).
        engine.ejectDeckCore(Deck.A)
        engine.ejectDeckCore(Deck.B)
        engine.rec(MixEventKind.ResetDeck, Deck.A)    // honest timeline: the auto start wiped both decks
        engine.rec(MixEventKind.ResetDeck, Deck.B)
        engine.clearMasterPaused()
        engine.autoEndedExhausted = false

        enabled = true
        sourceLabel = label
        leadSeconds = maxOf(1.0, lead)
        fadeSeconds = maxOf(0.2, fade)
        pendingFadeRestore = null
        extending = false
        fadeHeldSince = null
        awaitLogged = null
        queue.clear()
        queue.addAll(if (shuffled) items.shuffled(shuffleRandom) else items)
        livePos = 0
        liveDeck = Deck.A
        paused = false
        resumeEndDeck = null
        resumeFromRestore = false
        transitionRepeatOne = false
        transitionWrap = false
        resumeAutoOnRemotePlay = false
        remotePausedAt = null
        fadeStartedAt = null
        deckEndsAt.clear()
        deckDurationMs.clear()
        streamHeldSince.clear()
        glide.reset(queue)

        engine.applyCrossfader(0.0)
        // A queue item whose file vanished must not claim a deck. SHUFFLED: the order is ours to
        // pick, so open on a song that is ON DEVICE when there is one (zero dead air).
        if (shuffled && !seams.songOnDevice(queue[0].loadable.songId)) {
            val j = queue.indexOfFirst { seams.songOnDevice(it.loadable.songId) }
            if (j >= 0) {
                advLog("start: open on on-device ${queue[j].loadable.songId} over streaming ${queue[0].loadable.songId}")
                moveItem(j, 0)
            }
        }
        if (!loadAutoSlot(0, Deck.A)) {
            queue.clear()
            refreshStatus()
            engine.persist()   // the eject above emptied both decks: land that state
            return
        }
        loadAutoSlot(1, Deck.B)
        nextToLoad = minOf(2, queue.size)
        prefetchUpcoming()

        deckEndsAt[Deck.A] = now() + (deckDurationMs[Deck.A] ?: FALLBACK_DURATION_MS).toLong()
        mixing = true
        onSkipCommandsEnabled?.invoke(true)   // lock-screen next/previous = fast/slow auto-mix skip
        engine.play(Deck.A)
        refreshStatus()
        engine.persist()   // the whole (post-shuffle) queue + cursor survives a kill
    }

    /** User Stop: ends the machine and pauses both decks. */
    fun stopAutoMix() {
        engine.autoEndedExhausted = false   // user-initiated by default; exhaust sites re-set it after
        // BOTH decks: stopped mid-crossfade the incoming deck has played too; unreported its later
        // eject/load would read as a few-percent `.replaced` (a skip).
        if (mixing) for (d in listOf(liveDeck, liveDeck.other)) engine.reportTrackEnded(d, MixTrackEndReason.STOPPED)
        endAutoLoop()
        engine.clearPrepared()
        engine.pauseBoth()
    }

    override fun endAutoLoop() {
        if (mixing) onSkipCommandsEnabled?.invoke(false)
        val wasMixing = mixing
        // Abort any in-flight glide so a Stop mid-transition never leaves an effect on / a deck pitched.
        glide.abort()
        fadeStartedAt = null
        glide.clearPhases()
        pendingFadeRestore = null
        extending = false
        fadeHeldSince = null
        awaitLogged = null
        paused = false
        resumeEndDeck = null
        resumeFromRestore = false
        transitionRepeatOne = false
        transitionWrap = false
        resumeAutoOnRemotePlay = false
        remotePausedAt = null
        engineStallAt = null     // a stale stall park must never shift the NEXT mix's fresh clocks
        mixing = false
        sourceLabel = null
        // Recenter ONLY after a real auto-mix, non-recording, so ending never injects a `.crossfader`.
        if (wasMixing) {
            engine.applyCrossfader(0.5)
            engine.persist()   // auto over: the decks (still loaded) persist without it
        }
        refreshStatus()
    }

    // ------------------------------------------------------------------------------ pause / resume

    /**
     * PAUSE the auto-DJ without stopping it: suspends the transition machine so the decks can be
     * taken over by hand. Playback keeps running; only the auto-advance is gated.
     */
    fun pauseAuto() {
        if (!mixing || paused) return
        paused = true
        resumeEndDeck = null        // a fresh pause clears any stale resume-handoff intent
        engine.rec(MixEventKind.AutoPause)
        refreshStatus()
        engine.persist()
    }

    /**
     * RESUME after a manual interlude: re-arm the machine against the CURRENT live playback.
     *  - ONE deck playing: arm its end from its real remaining time;
     *  - BOTH playing: the later-ending deck survives, hand off when the sooner one ends;
     *  - NEITHER: restart the live deck (its track, or the next unplayed) before arming.
     */
    override fun resumeAuto() {
        if (!mixing || !paused) return
        engine.noteSounded()
        var fromRestore = resumeFromRestore
        resumeFromRestore = false    // consume-once: only the FIRST resume after a restore
        unfreezeAutoClock()          // an in-app Resume after a lock-screen pause must unpark the wall clock
        checkpointEngineStall()      // fresh end stamps below must only be shifted by the stall that FOLLOWS
        paused = false
        resumeAutoOnRemotePlay = false
        prefetchUpcoming()           // a restored / resumed run's first transition must not pay the sync prepare
        engine.rec(MixEventKind.AutoResume)
        // Mid-transition the (possibly just-unfrozen) fade owns both decks: lifting the gate is all
        // that is needed. A blend re-arm would fire a second, immediate handoff.
        if (autoTransitioning) { refreshStatus(); engine.persist(); return }
        val t = now()
        val aOn = engine.isPlaying(Deck.A)
        val bOn = engine.isPlaying(Deck.B)

        if (aOn && bOn) {
            val remA = maxOf(0.0, engine.duration(Deck.A) - engine.position(Deck.A))
            val remB = maxOf(0.0, engine.duration(Deck.B) - engine.position(Deck.B))
            val survivor = if (remA >= remB) Deck.A else Deck.B   // ends LAST -> stays live
            liveDeck = survivor
            resumeEndDeck = survivor.other                        // ends FIRST -> handoff trigger
            deckEndsAt[survivor] = t + secToMs(if (survivor == Deck.A) remA else remB)
            refreshStatus(); engine.persist()
            return
        }

        var live = if (aOn) Deck.A else if (bOn) Deck.B else liveDeck
        if (!aOn && !bOn && engine.deckExhaustedFromRestore(live)) {
            // The restored live deck had already FINISHED its track: advance instead of replaying it.
            val standby = live.other
            if (engine.loaded(standby) != null && !engine.deckExhaustedFromRestore(standby)) {
                engine.diag("mix resumeAuto: live deck ${live.label} exhausted - advancing to cued ${standby.label}")
                live = standby
                fromRestore = false          // the old live deck becomes the free deck -> fresh preload
            } else {
                engine.diag("mix resumeAuto: live deck ${live.label} exhausted - loading next unplayed")
                loadNextUnplayed(live, standby)
            }
        }
        if (!aOn && !bOn) {                   // nothing playing: get the live deck going again
            if (engine.loaded(live) == null) loadNextUnplayed(live)
            if (engine.loaded(live) != null) engine.play(live)
        }
        liveDeck = live
        resumeEndDeck = null
        val standby = live.other
        val cued = engine.loaded(standby)
        val cuedIdx = if (fromRestore && cued != null && cued.songId != engine.loaded(live)?.songId)
            queue.indexOfFirst { it.loadable.songId == cued.songId }.takeIf { it >= 0 } else null
        if (cuedIdx != null) {
            // RESUMING A RESTORED MIX: the snapshot already cued the on-deck next - trust it over
            // the played-log scan (the log outlives relaunches, and re-deriving would consume one
            // upcoming song on EVERY relaunch).
            livePos = maxOf(0, cuedIdx - 1)
            nextToLoad = cuedIdx + 1
        } else {
            val k = loadNextUnplayed(standby, live)   // preload the on-deck next
            if (k != null) {
                livePos = maxOf(0, k - 1)
                nextToLoad = k + 1
            } else {
                livePos = maxOf(livePos, queue.size - 1)   // queue exhausted: ride the live deck out
            }
        }
        deckEndsAt[live] = t + secToMs(maxOf(0.0, engine.duration(live) - engine.position(live)))
        refreshStatus(); engine.persist()
    }

    /**
     * Two-deck RESUME handoff (idle tick when [resumeEndDeck] finishes): retire the just-ended
     * deck, load the next unplayed track onto it and glide the survivor over to it. Ends the mix
     * if nothing is left to play.
     */
    private fun beginResumeHandoff(t: Long, freed: Deck) {
        engine.silence(freed)   // the ended deck is done - retire it cleanly
        val k = loadNextUnplayed(freed, liveDeck)
        if (k == null) {
            // REPEAT ALL: everything is played/unloadable by the log's lights - wrap to the head.
            if (repeat == AutoRepeatMode.ALL && ensureWrapPreloaded()) {
                transitionWrap = true
                if (glide.anyGlide) glide.begin(t, 0.0) else beginAutoCrossfade(t)
                return
            }
            stopAutoMix()
            engine.autoEndedExhausted = true   // resume-handoff with nothing loadable = exhausted too
            return
        }
        livePos = maxOf(0, k - 1)
        nextToLoad = k + 1
        if (glide.anyGlide) glide.begin(t, 0.0) else beginAutoCrossfade(t)   // no preroll: the first track already ended
    }

    /**
     * Load the next unplayed queue item onto [deck], DROPPING entries whose audio vanished (a
     * deleted/pruned burn) rather than leaving the deck empty. Returns the loaded item's queue index,
     * or null when nothing unplayed can be loaded.
     */
    private fun loadNextUnplayed(deck: Deck, exclude: Deck? = null): Int? {
        val deferred = HashSet<String>()
        while (true) {
            val k = nextUnplayedQueueIndex(exclude, deferred) ?: return null
            if (loadAuto(queue[k], deck)) { prefetchUpcoming(); return k }
            if (seams.transientlyUnloadable(queue[k].loadable.songId)) {
                deferred.add(queue[k].loadable.songId)   // stream gate closed now - keep it
                continue
            }
            queue.removeAt(k)                            // unloadable: it can never play; drop it
            if (nextToLoad > k) nextToLoad -= 1
            if (livePos > k) livePos -= 1
        }
    }

    /** First queue index whose song hasn't started playing this session (null = all played). */
    private fun nextUnplayedQueueIndex(exclude: Deck? = null, skipping: Set<String> = emptySet()): Int? {
        val skip = exclude?.let { engine.loaded(it)?.songId }
        for ((i, item) in queue.withIndex()) {
            val sid = item.loadable.songId
            if (sid == skip || sid in skipping) continue
            if (engine.recorder?.hasPlayed(sid) == true) continue
            return i
        }
        return null
    }

    // ------------------------------------------------------------------------------ repeat preloads

    /** The item repeat-one replays: the live slot when it matches the on-air track, else rebuilt from the deck. */
    private fun repeatOneItem(): AutoMixItem? {
        if (livePos < queue.size && queue[livePos].loadable.songId == engine.loaded(liveDeck)?.songId) return queue[livePos]
        val l = engine.loaded(liveDeck) ?: return null
        return AutoMixItem(
            MixLoadable(l.songId, l.title, l.artist, l.bpm, l.camelot, l.key, l.albumId, null),
            deckDurationMs[liveDeck] ?: FALLBACK_DURATION_MS,
        )
    }

    /** Repeat-one preload: the standby deck re-queues the CURRENT item; touches neither cursor nor queue. */
    private fun ensureRepeatOnePreloaded(): Boolean {
        val item = repeatOneItem() ?: return false
        val deck = liveDeck.other
        if (engine.loaded(deck)?.songId == item.loadable.songId) {
            deckDurationMs[deck] = item.durationMs
            return true
        }
        return loadAuto(item, deck)
    }

    /** Repeat-all preload: the wrap target is queue[0]; unloadable heads are dropped with the cursor shifted down. */
    private fun ensureWrapPreloaded(): Boolean {
        val deck = liveDeck.other
        while (queue.isNotEmpty()) {
            val item = queue[0]
            if (engine.loaded(deck)?.songId == item.loadable.songId) {
                deckDurationMs[deck] = item.durationMs
                return true
            }
            if (loadAuto(item, deck)) return true
            queue.removeAt(0)
            if (livePos > 0) livePos -= 1
            if (nextToLoad > 0) nextToLoad -= 1
        }
        return false
    }

    // ------------------------------------------------------------------------------ the tick

    /** One auto-mix step (called from the engine's tick while mixing and the sink renders). */
    override fun fire(nowMs: Long) {
        if (!enabled || !mixing) return
        // REMOTE-FROZEN: the decks are silent and every armed timestamp is parked.
        // Hold bookkeeping runs on EVERY tick (even frozen / stalled): a paused deck is not holding,
        // so a lock-screen pause clears the stall clock (iOS updates it in the tick body).
        trackHolds(nowMs)
        if (remotePausedAt != null) return
        // Engine stalled: a transition must not fire into a dead engine.
        if (engineStallAt != null) return
        val t = nowMs
        val pre = glide.prerollStartedAt
        val fadeStart0 = fadeStartedAt
        val post = glide.postrollStartedAt
        if (pre != null) {                                               // PRE-ROLL (glide)
            val p = ((t - pre) / 1000.0 / maxOf(0.05, glide.glideInSecondsActive)).coerceIn(0.0, 1.0)
            glide.applyOutgoing(p)
            if (p >= 1) {
                glide.prerollStartedAt = null
                beginAutoCrossfade(t)       // start the incoming deck + the volume sweep
                glide.startCrossfade()      // snap outgoing to target, offset incoming, beat-sync
            }
        } else if (fadeStart0 != null) {                                 // CROSSFADE (volume sweep)
            fadeStep(t, fadeStart0)
            return
        } else if (post != null) {                                       // POST-ROLL (glide)
            val p = ((t - post) / 1000.0 / maxOf(0.05, glide.mixGlideSeconds)).coerceIn(0.0, 1.0)
            glide.applyIncoming(p)
            if (p >= 1) glide.finish()
        } else {                                                         // IDLE - maybe start a transition
            if (!idleStep(t)) return
        }
        refreshStatus()
    }

    /** The stall clock only runs for a deck that is PLAYING and HOLDING right now. */
    private fun trackHolds(t: Long) {
        for (d in Deck.entries) {
            val held = engine.isPlaying(d) && engine.streamHeld(d)
            val since = streamHeldSince[d]
            if (held && since == null) {
                streamHeldSince[d] = t
                advLog("deck ${d.label} holding ${engine.loaded(d)?.songId ?: "-"} at ${f1(engine.position(d))}s auto=1")
            } else if (!held && since != null) {
                streamHeldSince.remove(d)
                if (engine.isPlaying(d)) advLog("deck ${d.label} resumed after ${f1((t - since) / 1000.0)}s hold")
            }
        }
    }

    private fun fadeStep(t: Long, fadeStart0: Long) {
        var fadeStart = fadeStart0
        val from = fadeFrom
        val to = from.other
        // ZERO DEAD AIR: never sweep the fader onto a deck that isn't making sound.
        if (engine.loaded(to) == null) {
            // The incoming stream died before any audio: back out - the outgoing stays on air.
            readiness.abandonTransition("incoming deck emptied")
            refreshStatus()
            return
        }
        if (engine.streamHeld(to)) {
            // Incoming is Buffering: FREEZE the sweep (the outgoing keeps playing) until it has
            // runway. If the outgoing runs out first, replay it rather than go silent.
            if (fadeHeldSince == null) {
                fadeHeldSince = t
                advLog("fade frozen - ${engine.loaded(to)?.songId ?: "-"} buffering")
            }
            if (engine.duration(from) - engine.position(from) <= AutoReadiness.EXTEND_AT_SECONDS_LEFT) {
                readiness.abandonTransition("outgoing ran out while incoming buffering")
                readiness.extendLive("next still buffering")
            }
            refreshStatus()
            return
        }
        fadeHeldSince?.let { held ->
            fadeStart += (t - held)
            fadeStartedAt = fadeStart
            fadeHeldSince = null
            restampEnd(to)
            advLog("fade resumed - ${engine.loaded(to)?.songId ?: "-"} has audio")
        }
        val p = ((t - fadeStart) / 1000.0 / fadeSeconds).coerceIn(0.0, 1.0)
        engine.applyCrossfader(if (fadeFrom == Deck.A) p else 1 - p)
        if (p >= 1) finishAutoCrossfade()
        refreshStatus()
    }

    /** The idle lane. Returns false when the caller should skip the status refresh (an early return in iOS). */
    private fun idleStep(t: Long): Boolean {
        // RESUME with two decks blended: hold everything until the SOONEST-ending deck finishes.
        resumeEndDeck?.let { endDeck ->
            val ended = !engine.isPlaying(endDeck) || (engine.duration(endDeck) - engine.position(endDeck)) <= 0.05
            if (ended) {
                resumeEndDeck = null
                beginResumeHandoff(t, endDeck)
            }
            refreshStatus()
            return false
        }
        // PAUSED: the DJ is hand-mixing - never auto-advance (nor auto-stop at end-of-track).
        if (paused) return false
        // DEAD LIVE DECK: the on-air song was dropped under us (a stream that died before audio) - hand
        // over to the next loadable song, or end the mix; never sit "mixing" over two empty decks.
        if (engine.loaded(liveDeck) == null) {
            if (livePos + 1 < queue.size) {
                if (!ensureNextPreloaded()) return false      // only stream-gated songs left: retry next tick
                advLog("live deck empty - handing over to ${engine.loaded(liveDeck.other)?.songId ?: "-"}")
                extending = false
                awaitLogged = null
                beginImmediateTransition(1.0)
                refreshStatus()
                return false
            }
            advLog("live deck empty and queue exhausted - mix ends")
            stopAutoMix()
            engine.autoEndedExhausted = true
            return false
        }
        // LOOPING: an engaged loop is a hand-mix hold; releasing it re-times the transition.
        if (engine.deckState(liveDeck).loopOn) return false
        val endsAt = deckEndsAt[liveDeck] ?: return false
        val secondsLeft = (endsAt - t) / 1000.0

        // STALLED LIVE DECK: a stream underrun mid-song is dead air - after the stall window hand
        // over to a song that can air right now.
        val since = streamHeldSince[liveDeck]
        if (since != null && engine.isPlaying(liveDeck) && (t - since) / 1000.0 >= stallSkipSeconds &&
            livePos + 1 < queue.size && ensureNextPreloaded() && readiness.standbyCanAir("live stalled")
        ) {
            advLog("stall-skip ${engine.loaded(liveDeck)?.songId ?: "-"} held ${((t - since) / 1000).toInt()}s -> ${engine.loaded(liveDeck.other)?.songId ?: "-"}")
            engine.reportTrackEnded(liveDeck, MixTrackEndReason.STOPPED)
            extending = false
            beginImmediateTransition(1.0)
            refreshStatus()
            return false
        }
        if (secondsLeft <= leadSeconds && repeat == AutoRepeatMode.ONE && ensureRepeatOnePreloaded()) {
            // REPEAT ONE: the standby holds the SAME item and the finish freezes the cursor. A failed
            // re-preload falls through to the ordinary lanes so the mix degrades instead of stalling.
            transitionRepeatOne = true
            beginAdvanceTransition(t, secondsLeft)
        } else if (livePos + 1 < queue.size) {
            // `ensureNextPreloaded` (not just the count): a progressive append can arrive while the
            // LAST queued track is live, AFTER all preloading ran.
            //
            // READINESS: the window opens at the lead (or at once while EXTENDING), but the
            // transition only begins into a deck that can air - ready, promoted, or (at the very
            // end) one that at least has its first seconds. Nothing at all => extend the live song.
            if (secondsLeft <= leadSeconds || extending) {
                val standby = liveDeck.other
                val atEnd = secondsLeft <= AutoReadiness.EXTEND_AT_SECONDS_LEFT
                val hasNext = ensureNextPreloaded()
                if (hasNext && (readiness.deckReadyToAir(standby) || readiness.promoteReadyUpcoming("auto") ||
                        ((atEnd || extending) && readiness.deckCanAir(standby)))
                ) {
                    if (extending || awaitLogged != null) {
                        advLog("advance -> ${engine.loaded(standby)?.songId ?: "-"} after wait (left=${f1(secondsLeft)}s)")
                    }
                    val wasExtended = extending
                    extending = false
                    awaitLogged = null
                    beginAdvanceTransition(t, if (wasExtended) maxOf(secondsLeft, fadeSeconds) else secondsLeft)
                } else if (atEnd && (hasNext || livePos + 1 < queue.size)) {
                    readiness.extendLive(
                        if (hasNext) "next not ready (${engine.loaded(standby)?.songId ?: "-"})"
                        else "no loadable next (stream gate closed)",
                    )
                } else {
                    val waiting = engine.loaded(standby)?.songId ?: "-"
                    if (awaitLogged != waiting) {
                        awaitLogged = waiting
                        advLog("await next $waiting - buffering (left=${f1(secondsLeft)}s)")
                    }
                }
            }
        } else if (secondsLeft <= leadSeconds && repeat == AutoRepeatMode.ALL && queue.isNotEmpty() && ensureWrapPreloaded()) {
            // REPEAT ALL: the LAST track wraps into queue[0] instead of ending exhausted.
            transitionWrap = true
            beginAdvanceTransition(t, secondsLeft)
        } else if (secondsLeft <= 0) {
            stopAutoMix()
            engine.autoEndedExhausted = true   // natural end: a late-landing download may continue it
        }
        return true
    }

    /**
     * Begin the tick-driven advance into the already-preloaded standby deck: the fade cap +
     * glide-fitting tail shared by the normal, repeat-one and repeat-all lanes.
     */
    private fun beginAdvanceTransition(t: Long, secondsLeft: Double) {
        // Cap the fade to the runway left (a track slid to 2 s from its end crossfades over ~2 s).
        if (secondsLeft < fadeSeconds && pendingFadeRestore == null) {
            pendingFadeRestore = fadeSeconds
            fadeSeconds = maxOf(0.5, secondsLeft)
        }
        if (glide.anyGlide) {
            // Fit the preroll into what's left after the (possibly capped) fade + a margin. Mix Glide
            // bends the OUTGOING tempo up to +10%, so divide the runway by that headroom.
            val headroom = if (glide.mixGlideEnabled) 1.12 else 1.0
            val preroll = maxOf(0.0, minOf(glide.mixGlideSeconds, secondsLeft / headroom - fadeSeconds - 0.3))
            glide.begin(t, preroll)
        } else {
            beginAutoCrossfade(t)
        }
    }

    // ------------------------------------------------------------------------------ skip

    /**
     * Manual SKIP: immediately advance to the next queued track, crossfading over [fadeSeconds].
     * Ignored mid-fade (a double-advance would jump the fader) except a fade FROZEN on a buffering
     * incoming deck; on the LAST track it ends the mix. The custom fade is restored to the baseline
     * once the crossfade finishes.
     */
    fun skipToNext(fadeSeconds: Double) {
        if (!enabled || !mixing) return
        if (autoTransitioning) {
            // A Skip during a crossfade FROZEN on a buffering incoming deck must not be swallowed:
            // back out and skip PAST the held song. Any other in-flight transition still ignores it.
            val fs = fadeStartedAt
            val heldDeck = fadeFrom.other
            if (fs == null || glide.postrollStartedAt != null ||
                !(engine.loaded(heldDeck) == null || engine.streamHeld(heldDeck))
            ) {
                advLog("skip ignored - transition in flight")
                return
            }
            val heldId = engine.loaded(heldDeck)?.songId
            readiness.abandonTransition("skip while incoming buffering")
            // Defer the held song to the END of the queue (it keeps downloading; it never aired).
            val p = livePos + 1
            if (heldId != null && p < queue.size && queue[p].loadable.songId == heldId && queue.size > p + 1) {
                queue.add(queue.removeAt(p))
                advLog("skip: deferred buffering $heldId to the end")
                if (engine.loaded(heldDeck)?.songId == heldId) ejectForReplacement(heldDeck)
            }
        }
        // The listen ends at the moment of the SKIP, not when the crossfade finishes retiring it.
        engine.reportTrackEnded(liveDeck, MixTrackEndReason.SKIP)
        extending = false
        awaitLogged = null
        // An explicit skip OVERRIDES repeat-one; repeat-ALL turns the last-track skip into a wrap.
        var wrapping = false
        if (livePos + 1 < queue.size) {
            // Late-append safety: the incoming deck must actually hold the next queue item.
            if (!ensureNextPreloaded()) {
                if (livePos + 1 < queue.size) {
                    // Only stream-gated songs are left: keep the live song playing.
                    advLog("skip: nothing loadable now - live song keeps playing")
                    return
                }
                advLog("skip: queue exhausted - mix ends")
                stopAutoMix()
                engine.autoEndedExhausted = true
                return
            }
            // One press = one AUDIBLE next song: prefer a ready song over a buffering one.
            val ready = readiness.standbyCanAir("skip")
            advLog("skip -> ${engine.loaded(liveDeck.other)?.songId ?: "-"} ready=${if (ready) 1 else 0}")
        } else if (repeat == AutoRepeatMode.ALL && queue.isNotEmpty() && ensureWrapPreloaded()) {
            wrapping = true
        } else {                                                  // last track -> end
            advLog("skip on last track - mix ends")
            stopAutoMix()
            engine.autoEndedExhausted = true   // skip-exhausted twin of the natural end
            return
        }
        transitionWrap = wrapping
        beginImmediateTransition(fadeSeconds)
        refreshStatus()
    }

    /** Start a transition NOW (skip / stall hand-over): no preroll, a one-off fade the finish restores. */
    private fun beginImmediateTransition(fade: Double) {
        if (glide.anyGlide) {
            // A manual skip glides too, but with NO preroll.
            glide.begin(now(), 0.0, fade)
        } else {
            if (pendingFadeRestore == null) pendingFadeRestore = fadeSeconds
            fadeSeconds = maxOf(0.2, fade)
            beginAutoCrossfade(now())
        }
    }

    /** Empty a standby deck whose (never-aired) song was skipped past, so the next preload reloads it. */
    private fun ejectForReplacement(deck: Deck) {
        streamHeldSince.remove(deck)
        engine.reportTrackEnded(deck, MixTrackEndReason.STOPPED)
        engine.ejectDeckCore(deck)
    }

    // ------------------------------------------------------------------------------ crossfade

    internal fun beginAutoCrossfade(t: Long) {
        val to = liveDeck.other
        fadeFrom = liveDeck
        fadeStartedAt = t
        // The crossfade itself as a compact .glide node, for every transition (glide or plain, auto or Skip).
        glide.recGlide("crossfader", null, engine.crossfader, if (fadeFrom == Deck.A) 1.0 else 0.0, fadeSeconds)
        // The incoming deck may REPLAY its current load (repeat-one, a queue duplicate): a new play of
        // the slot, so open a fresh load cycle for it.
        if (engine.hooks.hasPlayedThisLoad(to)) {
            engine.reportTrackEnded(to, MixTrackEndReason.REPLACED)
            engine.resetLoadCycle(to)
        }
        engine.restart(to)
        engine.play(to)
        deckEndsAt[to] = t + (deckDurationMs[to] ?: FALLBACK_DURATION_MS).toLong()
    }

    internal fun finishAutoCrossfade() {
        val from = fadeFrom
        val to = from.other
        engine.reportTrackEnded(from, MixTrackEndReason.NATURAL)   // no-op when a skip already reported
        engine.applyCrossfader(if (from == Deck.A) 1.0 else 0.0)
        engine.silence(from)      // retire the outgoing deck WITHOUT ending the auto-mix we're inside
        liveDeck = to
        val repeatedOne = transitionRepeatOne
        if (transitionRepeatOne) {
            // Repeat-one: cursor FROZEN (no advance, nothing retired into autoPlayed).
        } else if (transitionWrap) {
            livePos = 0           // repeat-all wrap: the head is live again
            nextToLoad = 1
        } else {
            livePos += 1
        }
        transitionRepeatOne = false
        transitionWrap = false
        fadeStartedAt = null
        pendingFadeRestore?.let { fadeSeconds = it; pendingFadeRestore = null }
        // Glide: the OUTGOING deck is about to be reused - restore its forced effect + natural
        // tempo/pitch BEFORE the load (a load doesn't clear effects).
        glide.restoreOutgoing(from)
        // Preload the next LOADABLE queue item, advancing past entries whose file vanished.
        // Repeat-one skips this: the retired deck already holds the replayed track.
        if (!repeatedOne) {
            while (nextToLoad < queue.size) {
                val ok = loadAuto(queue[nextToLoad], from)
                nextToLoad += 1
                if (ok) break
            }
        }
        prefetchUpcoming()
        engine.onNowPlayingChanged?.invoke()   // the now-playing deck just switched: refresh the card
        glide.beginPostroll()
        engine.persist()                       // the cursor advanced: persist the new live pos
    }

    /**
     * Late-append safety net: verify the deck the mix is about to crossfade INTO actually holds
     * `queue[livePos + 1]`, loading it now if not. Unloadable entries are dropped; a ripped song the
     * stream gate refuses right now is DEFERRED behind it. False when nothing loadable remains.
     */
    internal fun ensureNextPreloaded(): Boolean {
        val deck = liveDeck.other
        val p = livePos + 1
        var j = p
        val deferred = ArrayList<String>()
        while (j < queue.size) {
            val next = queue[j]
            if (engine.loaded(deck)?.songId == next.loadable.songId) {
                // Already preloaded, or a queue DUPLICATE of what this deck still holds (the crossfade
                // re-schedules via restart). Re-stamp the duration in case the entry differs.
                deckDurationMs[deck] = next.durationMs
                moveItem(j, p)
                nextToLoad = maxOf(nextToLoad, p + 1)
                if (deferred.isNotEmpty()) advLog("defer $deferred - stream gate closed; next ${next.loadable.songId}")
                return true
            }
            if (loadAuto(next, deck)) {
                // The deck just committed to index livePos+1: later inserts must land after it.
                moveItem(j, p)
                nextToLoad = maxOf(nextToLoad, p + 1)
                if (deferred.isNotEmpty()) advLog("defer $deferred - stream gate closed; next ${next.loadable.songId}")
                return true
            }
            if (seams.transientlyUnloadable(next.loadable.songId)) {
                deferred.add(next.loadable.songId)
                j += 1
                continue
            }
            queue.removeAt(j)                     // permanently unloadable: drop it
            if (nextToLoad > j) nextToLoad -= 1
        }
        if (deferred.isNotEmpty()) {
            // Runs every tick while the gate stays closed: log once per distinct deferred set, not at 10 Hz.
            val key = deferred.joinToString(",")
            if (key != lastNoLoadableKey) {
                lastNoLoadableKey = key
                advLog("no loadable next - ${deferred.size} deferred (stream gate closed)")
            }
        } else lastNoLoadableKey = null
        return false
    }

    /** Load the first loadable item at/after slot [p] onto [deck], moving it INTO [p]. */
    private fun loadAutoSlot(p: Int, deck: Deck): Boolean {
        var j = p
        while (j < queue.size) {
            if (loadAuto(queue[j], deck)) {
                if (j != p) advLog("slot $p: deferred ${j - p} gated song(s) for ${queue[j].loadable.songId}")
                moveItem(j, p)
                return true
            }
            if (seams.transientlyUnloadable(queue[j].loadable.songId)) { j += 1; continue }
            queue.removeAt(j)
        }
        return false
    }

    /**
     * Load a queue item onto a deck. False - WITHOUT stamping the deck's duration - when the load
     * failed: a failed load must not arm a transition clock against a track that isn't there.
     */
    internal fun loadAuto(item: AutoMixItem, deck: Deck): Boolean {
        engine.autoLoading = true
        try { engine.loadNow(item.loadable, deck) } finally { engine.autoLoading = false }
        if (engine.loaded(deck)?.songId != item.loadable.songId) return false
        deckDurationMs[deck] = item.durationMs
        return true
    }

    /** Prepare the next 1-2 unloaded queue items OFF Main so their [loadAuto] skips disk (sync prepare only on a miss). */
    internal fun prefetchUpcoming() {
        var k = nextToLoad
        var n = 0
        // Entries for removed / reordered items must not squat the cap.
        engine.prunePrepared((nextToLoad until minOf(queue.size, nextToLoad + PREFETCH_AHEAD)).map { queue[it].loadable.songId }.toSet())
        while (k < queue.size && n < PREFETCH_AHEAD) {
            val item = queue[k]
            if (seams.songOnDevice(item.loadable.songId)) { engine.prefetchPrepared(item.loadable, Deck.A); n++ }
            k++
        }
    }

    /** Move queue item [j] to [p] (p <= j); the items between shift back one. */
    internal fun moveItem(j: Int, p: Int) {
        if (j == p || j !in queue.indices || p < 0 || p >= j) return
        queue.add(p, queue.removeAt(j))
    }

    // ------------------------------------------------------------------------------ engine hooks

    /** A seek moved a deck: re-time the live deck's crossfade from its NEW position. */
    override fun onSeek(deck: Deck) {
        if (!mixing || deck != liveDeck || autoTransitioning) return
        checkpointEngineStall()   // a mid-stall seek's fresh stamp gets only the stall that follows it
        restampEnd(deck)
    }

    /** Master play un-silences everything: unpark any remote-frozen fade clock. */
    override fun onMasterPlay() = unfreezeAutoClock()

    /** Held (buffering) seconds aren't played seconds: the live deck's end clock must not burn. */
    override fun onDeckHeld(deck: Deck, dtSeconds: Double) {
        if (!mixing) return
        deckEndsAt[deck]?.let { deckEndsAt[deck] = it + secToMs(dtSeconds) }
    }

    /** Re-stamp a deck's wall-clock end from its live position (tempo-aware; held seconds don't count). */
    fun restampEnd(deck: Deck) {
        if (!mixing) return
        val durMs = deckDurationMs[deck] ?: FALLBACK_DURATION_MS
        val remaining = maxOf(0.0, durMs / 1000.0 - engine.position(deck)) / maxOf(0.05, engine.rate(deck))
        deckEndsAt[deck] = now() + secToMs(remaining)
    }

    /** The deck's real length changed (a truncated stream): keep the auto bookkeeping honest. */
    fun setDeckDuration(deck: Deck) {
        if (mixing) deckDurationMs[deck] = (engine.duration(deck) * 1000).toInt()
        if (deckEndsAt[deck] != null) restampEnd(deck)   // iOS guard: a never-armed standby stays unarmed
    }

    // ------------------------------------------------------------------------------ remote (lock screen)

    /**
     * LOCK-SCREEN pause - unlike the in-app master pause (which ENDS a running Auto-DJ), this SUSPENDS
     * it: pauseAuto first, then FREEZE the wall clock, then silence the decks. IDEMPOTENT: Bluetooth
     * heads re-send discrete PAUSE; a duplicate must not clobber the pause memory or resume intent.
     */
    fun remotePause() {
        streamHeldSince.clear()   // silenced decks aren't holding; the pause must not bank hold time
        if (!(engine.isRunning || (remotePausedAt == null && !engine.hasMasterPaused))) {
            engine.diag("mix remotePause guard=dup")
            return
        }
        engine.diag("mix remotePause guard=pass running=${if (engine.isRunning) 1 else 0} auto=${if (mixing) 1 else 0}/${if (paused) 1 else 0}")
        val autoWasRunning = mixing && !paused
        if (autoWasRunning) {
            pauseAuto()                     // BEFORE pauseBoth: a running auto-loop would be ended by it
            resumeAutoOnRemotePlay = true   // set-only: never clobber an earlier pause's intent
        }
        if (mixing) {
            unparkEngineStall()             // fold an in-progress stall into the freeze (no double shift)
            remotePausedAt = now()          // freeze transition timers while the decks are silent
        }
        engine.pauseBoth()                  // records masterPausedDecks; paused=true keeps the loop
    }

    /**
     * LOCK-SCREEN play - shift every armed timestamp forward by the frozen interval, resume the
     * paused deck(s), then resume the Auto-DJ if the matching pause was what suspended it. An Auto-DJ
     * the user paused IN-APP stays paused.
     */
    fun remotePlay() {
        streamHeldSince.clear()   // hold time restarts fresh after the lock-screen pause
        unfreezeAutoClock()
        engine.resumeMasterPaused()
        if (resumeAutoOnRemotePlay && mixing && paused) resumeAuto()
        // A RESTORED suspended mix resumed from the lock screen must actually run the machine.
        if (resumeFromRestore && mixing && paused) resumeAuto()
        resumeAutoOnRemotePlay = false
    }

    /** LOCK-SCREEN next/previous: while suspended, "resume the mix on the next track". */
    fun remoteSkip(fadeSeconds: Double) {
        if (paused) {
            unfreezeAutoClock()
            engine.resumeMasterPaused()
            resumeAuto()                    // consumes resumeAutoOnRemotePlay; no-ops the re-arm mid-fade
        }
        skipToNext(fadeSeconds)
    }

    /** Shift every armed timestamp forward by the remote-frozen interval. No-op when not frozen. */
    internal fun unfreezeAutoClock() {
        val frozeAt = remotePausedAt ?: return
        remotePausedAt = null
        shiftClocks(now() - frozeAt)
    }

    private fun shiftClocks(delta: Long) {
        if (delta <= 0) return
        glide.shift(delta)
        fadeStartedAt = fadeStartedAt?.plus(delta)
        for ((d, t) in deckEndsAt.toList()) deckEndsAt[d] = t + delta
    }

    // ------------------------------------------------------------------------------ engine stall

    /** The sink died under a live mix: park the clocks. Not while remote-frozen (they are parked already). */
    override fun parkEngineStall() {
        if (!mixing || remotePausedAt != null || engineStallAt != null) return
        engineStallAt = now()
        engine.diag("mix recover: engine down - stall parked")
    }

    /** The sink is back: shift every armed clock past the stall so overdue transitions don't burst. */
    override fun unparkEngineStall() {
        val stalledAt = engineStallAt ?: return
        engineStallAt = null
        shiftClocks(now() - stalledAt)
    }

    /** Re-base an in-progress stall: shift armed clocks by the stall-so-far and park again from NOW. */
    internal fun checkpointEngineStall() {
        if (engineStallAt == null) return
        unparkEngineStall()
        engineStallAt = now()
    }

    // ------------------------------------------------------------------------------ status / persistence

    internal fun refreshStatus() {
        val transitioning = autoTransitioning
        val s = if (mixing) {
            val detail = if (paused) "paused — hand-mixing"
            else if (transitioning) "fading" else "Deck ${liveDeck.label}"
            "${minOf(livePos + 1, queue.size)} / ${queue.size} · $detail"
        } else null
        val next = AutoUiState(
            mixing, paused, transitioning, s, livePos, queue.size, liveDeck, repeat,
            glide.fxGlideEnabled, glide.mixGlideEnabled, sourceLabel, enabled,
        )
        if (next != _ui.value) _ui.value = next
    }

    override fun snapshot(): AutoSnapshot? {
        if (!mixing || queue.isEmpty()) return null
        return AutoSnapshot(
            queue = queue.map {
                val l = it.loadable
                AutoRow(TrackRef(l.songId, l.title, l.artist, l.bpm, l.camelot, l.key, l.albumId, l.lengthMs), it.durationMs, it.sourceLabel)
            },
            livePos = livePos, nextToLoad = nextToLoad, liveDeck = liveDeck.label, sourceLabel = sourceLabel,
            leadSeconds = leadSeconds, fadeSeconds = pendingFadeRestore ?: fadeSeconds,
            fxGlide = glide.fxGlideEnabled, mixGlide = glide.mixGlideEnabled,
            repeatMode = if (repeat == AutoRepeatMode.OFF) null else repeat.raw,
        )
    }

    /** Rebuild the machine SUSPENDED from a parked restore (never self-resumes). */
    override fun restoreSuspended(auto: AutoSnapshot) {
        if (auto.queue.isEmpty()) return
        queue.clear()
        queue.addAll(
            auto.queue.map {
                val t = it.track
                AutoMixItem(MixLoadable(t.songId, t.title, t.artist, t.bpm, t.camelot, t.key, t.albumId, t.lengthMs), it.durationMs, it.sourceLabel)
            },
        )
        repeat = AutoRepeatMode.fromRaw(auto.repeatMode) ?: AutoRepeatMode.OFF
        enabled = true
        sourceLabel = auto.sourceLabel
        leadSeconds = maxOf(1.0, auto.leadSeconds)
        fadeSeconds = maxOf(0.2, auto.fadeSeconds)
        glide.fxGlideEnabled = auto.fxGlide
        glide.mixGlideEnabled = auto.mixGlide
        livePos = auto.livePos.coerceIn(0, queue.size - 1)
        nextToLoad = auto.nextToLoad.coerceIn(0, queue.size)
        liveDeck = Deck.fromLabel(auto.liveDeck) ?: Deck.A
        // Fresh machine internals: no in-flight transition, no frozen clocks, no stale intents.
        fadeStartedAt = null
        glide.reset(queue)
        transitionRepeatOne = false; transitionWrap = false
        pendingFadeRestore = null
        resumeEndDeck = null
        resumeAutoOnRemotePlay = false
        remotePausedAt = null
        engineStallAt = null
        deckEndsAt.clear()                 // re-stamped by resumeAuto from live positions
        for (d in Deck.entries) if (engine.loaded(d) != null) deckDurationMs[d] = (engine.duration(d) * 1000).toInt()
        paused = true                      // SUSPENDED
        resumeFromRestore = true           // first resume: the restored cursor wins over the play-log
        mixing = true
        refreshStatus()
        prefetchUpcoming()
    }

    private fun secToMs(s: Double): Long = Math.round(s * 1000)

    companion object {
        const val PREFETCH_AHEAD = 2
        const val FALLBACK_DURATION_MS = 180_000
    }
}
