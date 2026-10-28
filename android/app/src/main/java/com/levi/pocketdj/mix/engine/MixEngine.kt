package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.graph.ParamsComposer
import com.levi.pocketdj.mix.graph.SlotParams
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FilterMode
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MeterSource
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixMath
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.audio.dsp.MixDeckLevels
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixDeckSnapshot
import com.levi.pocketdj.mix.store.DeckSnapshot
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionRecorder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

/**
 * The Mix engine facade (iOS `MixEngine`): two decks over a [MixGraph], MAIN-THREAD ONLY, app
 * scoped (constructed once in the app graph; it is NEVER torn down when the Mix tab is left).
 *
 * Observable surface: [ui] (a [MixUiState] StateFlow). Hot values stay out of it: [positions]
 * (polled by the seek slider), [levels] (VU) and [truePlayhead] (beat pulse).
 *
 * Invariants carried over from iOS:
 *  - [setPlaying] is the single transport funnel: `.play`/`.pause` are recorded and a song is
 *    marked played ONLY on a real transition.
 *  - Boost (volume above unity) rides the trim and is written ONLY by volume changes; the
 *    crossfader path ([applyCrossfader]) never re-derives it and never records.
 *  - A restore is PARKED at launch, materialized on the Mix tab with the recorder detached, decks
 *    cued and silent; a real load drops a parked restore.
 *  - The tick clamps dt to 0.5 s and retires a deck reaching its end outside a running auto mix.
 *
 * Sub-controllers (loop / stems / streaming / Auto-DJ / mod tick) plug in through [EngineCore] and
 * the hook members below; this class owns no knowledge of them.
 */
class MixEngine(
    override val graph: MixGraph = MixGraph(),
    private val sinkFactory: () -> AudioSink,
    private val resolver: MixTrackResolver,
    private val opener: MixSourceOpener,
    private val runner: VoiceRunner,
    tickDriver: TickDriver,
    private val clockMs: () -> Long = System::currentTimeMillis,
    private val nanoClock: () -> Long = System::nanoTime,
    deckStore: MixDeckSessionStore? = null,
    private val diagSink: (String) -> Unit = {},
) : EngineCore {

    // ------------------------------------------------------------------------------ state

    private val _ui = MutableStateFlow(MixUiState())
    val ui: StateFlow<MixUiState> = _ui.asStateFlow()
    val positions = DeckPositions()

    override val params = ParamsComposer(graph)
    private val controllers = arrayOf(
        DeckController(Deck.A, graph, runner), DeckController(Deck.B, graph, runner),
    )
    private val tick = MixTick(this, tickDriver)
    val hooks = MixRecordingHooks()

    /** The durable mix-deck session store; null = persistence is a no-op. */
    var sessionStore: MixDeckSessionStore? = deckStore

    /** The session-log sink (the app's MixSessionStore). */
    var recorder: MixSessionRecorder?
        get() = hooks.recorder
        set(v) { hooks.recorder = v }
    var onSongPlayed
        get() = hooks.onSongPlayed
        set(v) { hooks.onSongPlayed = v }
    var onDeckTrackEnded
        get() = hooks.onDeckTrackEnded
        set(v) { hooks.onDeckTrackEnded = v }

    // ---- extension seams for the sub-controllers / system integration packages
    var autoDj: AutoDjHooks? = null
    /** A deck is waiting for stream bytes (MIX-10): its playhead freezes and its voice is not started. */
    var streamHeldProvider: ((Deck) -> Boolean)? = null
    /** MIX-8's own stem Hold/Buffering flag, OR-ed into [streamHeld] independently so MIX-10 may freely (re)assign [streamHeldProvider]. */
    var stemHeldProvider: ((Deck) -> Boolean)? = null
    /** The deck's stem INTENT (on stems or loading them): the durable snapshot saves this, not the committed flag (iOS stemModeOn). */
    var stemModeOnProvider: ((Deck) -> Boolean)? = null
    /** The deck's active loop window in source seconds (MIX-8), else null. */
    var loopWindowProvider: ((Deck) -> Pair<Double, Double>?)? = null
    /** A rewind/reset/load invalidated the deck's loop (MIX-8 drops its resolved window). */
    var onLoopInvalidated: ((Deck) -> Unit)? = null
    /** A seek landed on [Deck] at the given source second (MIX-8: a looped deck's loop follows it). */
    var onSeeked: ((Deck, Double) -> Unit)? = null
    /** Per-tick, per-playing-deck, after the playhead advanced (MIX-8: stem underrun / handover checks). */
    var onDeckTick: ((Deck, Double) -> Unit)? = null
    /** A deck's transport really changed (play true / pause false) (MIX-8: deferred stem source, fade settle). */
    var onTransport: ((Deck, Boolean) -> Unit)? = null
    /** A track finished loading onto a deck (MIX-8: beat-grid hydrate). */
    var onDeckLoaded: ((Deck, LoadedTrack) -> Unit)? = null
    /** MIX-17: the LIVE (modulated) strength for a slot; null = the stored strength. */
    var slotStrengthProvider: ((Deck, Int, FXSlot) -> Double)? = null
    /** MIX-17: a rack/transport change that may start or stop the mod tick; `modChanged` = a slot's SlotMod was set. */
    var onSlotsChanged: ((Deck, Boolean) -> Unit)? = null
    /** A load/eject dropped the deck's stem intent (MIX-8). */
    var onStemsReset: ((Deck) -> Unit)? = null
    /** Not-on-disk loads: MIX-10 may open a growing-file stream instead. True = handled. */
    var streamLoad: ((MixLoadable, Deck) -> Boolean)? = null
    /** Restore extras for a deck (stem mode + loop need the MIX-8 controllers). */
    var onRestoreDeckExtras: ((Deck, DeckSnapshot) -> Unit)? = null
    /** A Mix deck started sounding (the audio-owner arbiter claims the system card). */
    var onAudioStarted: (() -> Unit)? = null
    /** The now-playing subject / transport changed (system card refresh). */
    var onNowPlayingChanged: (() -> Unit)? = null
    /** Whether a set list is live; a launch-time restore never builds a mix behind one. */
    var setlistIsLive: (() -> Boolean)? = null
    /** MIX-11: the output route changed and the sink rebuilt (true = rendering). Fires on the RENDER thread; the owner posts to main. */
    @Volatile var onSinkRouting: ((Boolean) -> Unit)? = null
    /** MIX-11: the 1 Hz liveness beat (main thread) while anything plays: session card refresh + silent-playing check. */
    var onHeartbeat: (() -> Unit)? = null
    /** Keep the sink alive even if nothing plays (an open recording tap). */
    var keepEngineAlive: () -> Boolean = { false }

    private var sink: AudioSink? = null
    private var built = false

    private var pendingRestore: MixDeckSnapshot? = null
    /** True once the launch restore was parked/attempted or a real load took over; before that an empty engine must not clear the store. */
    private var restoreSettled = false
    private val loadSeq = IntArray(2)
    /**
     * Off-main load seam: runs `work` (resolve + open + window; disk IO) off the main thread and then
     * `commit` on main. Null = synchronous (tests, restore).
     */
    var loadOffload: ((work: () -> PreparedLoad?, commit: (PreparedLoad?) -> Unit) -> Unit)? = null
    private var materializeWanted = false
    override var isRestoringMixSession = false; private set
    var hasSoundedThisProcess = false; private set
    private val deckExhaustedFromRestore = HashSet<Deck>()
    private var masterPausedDecks: Set<Deck> = emptySet()
    private var suppressStickyUpdates = false
    private var lastNowPlayingDeck: Deck? = null

    /** Monotonic count of deck-touching calls (load/play/playBoth). */
    var deckGestureGeneration = 0; private set
    /** Armed by an exhausted auto mix; any manual deck activity disarms it (MIX-7 pickup guard). */
    var autoEndedExhausted = false

    // ------------------------------------------------------------------------------ core impl

    private fun st(d: Deck): DeckState = _ui.value.deck(d)
    override fun deckState(deck: Deck): DeckState = st(deck)
    override fun updateDeck(deck: Deck, f: (DeckState) -> DeckState) {
        _ui.value = _ui.value.let { it.withDeck(deck, f(it.deck(deck))) }
    }
    private fun updateUi(f: (MixUiState) -> MixUiState) { _ui.value = f(_ui.value) }

    override fun controller(deck: Deck): DeckController = controllers[deck.ordinal]
    override fun position(deck: Deck): Double = positions.get(deck)
    override fun duration(deck: Deck): Double = st(deck).durationSec
    override fun setPosition(deck: Deck, sec: Double) {
        positions.set(deck, sec)
        hooks.noteHighWater(deck, sec)
    }
    override fun nowMs(): Long = clockMs()
    override fun diag(line: String) = diagSink(line)

    override val isRendering: Boolean get() = sink?.isRendering == true
    override val autoMixing: Boolean get() = autoDj?.isMixing == true
    private val autoPaused: Boolean get() = autoDj?.isPaused == true
    override val mixWantsAudio: Boolean
        get() = st(Deck.A).isPlaying || st(Deck.B).isPlaying || (autoMixing && !autoPaused)

    val isRunning: Boolean get() = _ui.value.isRunning
    val crossfader: Double get() = _ui.value.crossfader
    val leadDeck: Deck? get() = _ui.value.leadDeck
    val cueOnRight: Boolean get() = _ui.value.cueOnRight
    val isTicking: Boolean get() = tick.isTicking

    fun loaded(d: Deck): LoadedTrack? = st(d).loaded
    fun isPlaying(d: Deck): Boolean = st(d).isPlaying
    fun volume(d: Deck): Double = st(d).volume
    fun rate(d: Deck): Double = st(d).rate
    fun pitch(d: Deck): Double = st(d).pitch
    fun eqGain(band: EQBand, deck: Deck): Double = st(deck).eqGain(band)
    fun slots(deck: Deck) = st(deck).slots
    fun slot(i: Int, deck: Deck) = st(deck).slots.getOrNull(i)
    fun isEnabled(effect: Effect, deck: Deck) = st(deck).isEnabled(effect)
    fun strength(effect: Effect, deck: Deck) = st(deck).strength(effect)
    fun cued(deck: Deck) = st(deck).cued
    fun cueVolume(deck: Deck) = st(deck).cueVol
    val anyCued: Boolean get() = _ui.value.anyCued
    fun isLead(deck: Deck) = leadDeck == deck
    fun streamHeld(deck: Deck): Boolean =
        streamHeldProvider?.invoke(deck) == true || stemHeldProvider?.invoke(deck) == true
    fun loopWindow(deck: Deck): Pair<Double, Double>? = loopWindowProvider?.invoke(deck)
    fun deckExhaustedFromRestore(deck: Deck) = deck in deckExhaustedFromRestore

    /** The VU holder for a deck (poll; never triggers recomposition). */
    fun levels(deck: Deck): MixDeckLevels = graph.levelsOf(deck)
    fun meterSource(deck: Deck): MeterSource = _ui.value.meterSource(deck)
    fun setMeterSource(source: MeterSource, deck: Deck) = updateUi {
        if (deck == Deck.A) it.copy(meterSourceA = source) else it.copy(meterSourceB = source)
    }

    /** Seconds since the render thread last ran a block ([audible] = last block with signal); -1 = never. */
    internal fun tapAgeSeconds(audible: Boolean): Double {
        val stamp = if (audible) graph.pulse.lastAudibleAt else graph.pulse.lastRenderAt
        return if (stamp == 0L) -1.0 else (nanoClock() - stamp) / 1e9
    }

    // ------------------------------------------------------------------------------ recording

    override fun rec(kind: MixEventKind, deck: Deck?, param: String?, value: Double?, flag: Boolean?, slot: Int?) {
        hooks.emit(kind, deck, deck?.let { st(it).loaded }, deck?.let { position(it) }, param, value, flag, slot)
    }

    // ------------------------------------------------------------------------------ lifecycle

    /**
     * Build the output side. Idempotent. [startNow] false = INERT (a restore materializes without
     * touching the audio system); the first real transport starts the sink.
     */
    fun ensureEngine(startNow: Boolean = true) {
        built = true
        if (startNow) startEngineIfNeeded()
    }

    fun prepare() = ensureEngine(startNow = false)

    /** Start the sink if it is not pulling blocks. Reports failure instead of swallowing it. */
    fun startEngineIfNeeded(): Boolean {
        if (!built) return false
        val s = sink ?: sinkFactory().also { sk -> sink = sk; sk.onRoutingChanged = { ok -> onSinkRouting?.invoke(ok) } }
        if (!s.isRendering) graph.attach(s)
        return s.isRendering
    }

    /** Tick watchdog entry: the sink died under a live mix; bring it back and re-kick intent-playing decks. */
    internal fun watchdogRecover() {
        autoDj?.parkEngineStall()   // the machine's clocks must not burn a runway while the sink is down
        val ok = startEngineIfNeeded()
        diag("watchdog restart sink ok=$ok")
        if (!ok) return
        autoDj?.unparkEngineStall()
        for (d in Deck.entries) if (st(d).isPlaying && !streamHeld(d)) controller(d).play()
    }

    /** The arbiter displaced the Mix: park the sink when nothing wants audio (a silent sink must not hold output). */
    fun pauseEngineIfIdle() {
        if (!mixWantsAudio && !keepEngineAlive()) sink?.stop()
    }

    /** Test/teardown seam: stop the tick and release the decks. The app never calls this on tab leave. */
    fun shutdown() {
        tick.stop()
        for (d in Deck.entries) controller(d).release()
        sink?.stop()
    }

    // ------------------------------------------------------------------------------ loading

    /** Load a catalog song onto [deck] through the resolver (cut preferred, analog window bounded). */
    fun load(item: MixLoadable, deck: Deck) {
        deckGestureGeneration++
        // A manual load disarms an exhausted-ended auto pickup: a landing download must never
        // eject these decks mid-performance.
        autoEndedExhausted = false
        val off = loadOffload
        if (off == null || isRestoringMixSession) {
            commitPrepared(item, deck, prepare(item, deck))
            return
        }
        restoreSettled = true
        val gen = ++loadSeq[deck.ordinal]
        off({ prepare(item, deck) }) { p ->
            if (gen != loadSeq[deck.ordinal]) { p?.discard(); return@off }   // a newer load superseded this resolve
            commitPrepared(item, deck, p)
        }
    }

    /**
     * SYNCHRONOUS load for the Auto-DJ machine (MIX-9): it checks the deck's track straight after the
     * call (iOS `loadAuto`), so it must not ride [loadOffload]. Supersedes any in-flight async load.
     */
    internal fun loadNow(item: MixLoadable, deck: Deck) {
        deckGestureGeneration++
        autoEndedExhausted = false
        loadSeq[deck.ordinal]++
        commitPrepared(item, deck, prepare(item, deck))
    }

    /** MIX-9: the audio of [songId] is fully on this device (a load of it airs at once). */
    internal fun songOnDisk(songId: String): Boolean = resolver.exists(songId)

    /** MIX-9: the Auto-DJ started sounding (iOS `hasSoundedThisProcess`). */
    internal fun noteSounded() { if (!isRestoringMixSession) hasSoundedThisProcess = true }

    /** MIX-9: forget the lock-screen pause memory (a new mix's start). */
    internal fun clearMasterPaused() { masterPausedDecks = emptySet() }

    /** MIX-9: a master pause is remembered for the lock-screen play. */
    internal val hasMasterPaused: Boolean get() = masterPausedDecks.isNotEmpty()

    /** A resolved + opened load, ready to install. [notOnDisk] = the resolver had no file. */
    class PreparedLoad(
        val notOnDisk: Boolean,
        val voice: Voice? = null,
        val window: LoadWindow.Frames? = null,
        val startMs: Int? = null,
        val meta: LoadedTrack? = null,
    ) {
        fun discard() { runCatching { voice?.close() } }
    }

    /** Disk-touching half of a load (resolver, sidecars, decoder open, frame walk). Safe off-main. */
    private fun prepare(item: MixLoadable, deck: Deck): PreparedLoad? {
        val r = resolver.resolve(item.songId) ?: return PreparedLoad(notOnDisk = true)
        // A per-song CUT plays whole from 0:00; an analog shared-album fallback seeks to startMs AND
        // is bounded to lengthMs so it stops at the song boundary instead of bleeding into the next.
        val startMs = if (r.isCut) null else r.startMs
        val windowMs = if (r.isCut) null else item.lengthMs
        val src = runCatching { opener.open(r.file) }.getOrNull()
        if (src == null) { diag("load refused: open failed ${r.file.name}"); return null }
        val voice = Voice(src, graph.sampleRate, name = "deck${deck.label}")
        val w = LoadWindow.compute(voice.totalFrames, graph.sampleRate, startMs, windowMs)
        if (w == null) { runCatching { voice.close() }; diag("load refused: unreadable window ${r.file.name}"); return null }
        val meta = LoadedTrack(
            songId = item.songId, title = item.title, artist = item.artist, bpm = item.bpm,
            camelot = item.camelot, key = item.key, albumId = item.albumId,
            gridBpm = r.gridBpm, firstDownbeatMs = r.firstDownbeatMs, steady = r.steady,
            beatsMs = r.beatsMs, downbeatsMs = r.downbeatsMs,
        )
        return PreparedLoad(false, voice, w, startMs, meta)
    }

    private fun commitPrepared(item: MixLoadable, deck: Deck, p: PreparedLoad?) {
        if (!isRestoringMixSession) { pendingRestore = null; restoreSettled = true }
        if (p == null) return
        if (p.notOnDisk) {
            streamLoad?.invoke(item, deck)   // not on disk: playable while it downloads (MIX-10)
            return
        }
        loadSeq[deck.ordinal]++
        ensureEngine(startNow = !isRestoringMixSession)
        install(deck, p.voice!!, p.window!!, p.meta!!, p.startMs)
    }

    /**
     * MIX-10 streaming load, first half: the deck forgets its previous track's voice / stem intent so the
     * stream machine can take it. A parked restore is superseded exactly like a real load.
     */
    internal fun beginStreamLoad(deck: Deck) {
        if (!isRestoringMixSession) { pendingRestore = null; restoreSettled = true }
        loadSeq[deck.ordinal]++
        ensureEngine(startNow = !isRestoringMixSession)
        masterPausedDecks = masterPausedDecks - deck
        onStemsReset?.invoke(deck)
        controller(deck).release()
    }

    /** MIX-10 streaming load, second half: the track takes the deck with a provisional [durationSeconds]. */
    internal fun commitStreamLoad(deck: Deck, meta: LoadedTrack, durationSeconds: Double) =
        commitLoad(deck, meta, null, durationSeconds)

    /** Internal load seam (shared with tests): open [file] and load it as [meta]. False = deck untouched. */
    fun loadFile(file: java.io.File, startMs: Int?, lengthMs: Int?, meta: LoadedTrack, deck: Deck): Boolean {
        if (!isRestoringMixSession) { pendingRestore = null; restoreSettled = true }
        val src = runCatching { opener.open(file) }.getOrNull() ?: return false   // unreadable / corrupt
        return loadSource(src, startMs, lengthMs, meta, deck)
    }

    /**
     * Schedule exactly `[startMs, startMs+lengthMs)` of [source] (or the whole file) on [deck].
     * An over-length startMs / empty file keeps the current track. A successful load resets
     * rate/pitch/lead/stems/loop and records ONE `.load` with bpm/camelot.
     */
    fun loadSource(source: PcmSource, startMs: Int?, lengthMs: Int?, meta: LoadedTrack, deck: Deck): Boolean {
        // A REAL load supersedes a parked (not-yet-materialized) restore.
        if (!isRestoringMixSession) { pendingRestore = null; restoreSettled = true }
        loadSeq[deck.ordinal]++
        ensureEngine(startNow = !isRestoringMixSession)
        val voice = Voice(source, graph.sampleRate, name = "deck${deck.label}")
        val w = LoadWindow.compute(voice.totalFrames, graph.sampleRate, startMs, lengthMs)
        if (w == null) { runCatching { voice.close() }; return false }
        install(deck, voice, w, meta, startMs)
        return true
    }

    private fun install(deck: Deck, voice: Voice, w: LoadWindow.Frames, meta: LoadedTrack, startMs: Int?) {
        masterPausedDecks = masterPausedDecks - deck   // a NEW track was never silenced by the pause
        onStemsReset?.invoke(deck)                     // BEFORE the swap: landing a fade stops the player
        controller(deck).open(voice, w)
        commitLoad(deck, meta, startMs, w.count.toDouble() / graph.sampleRate)
    }

    /** The shared tail of every deck load. */
    private fun commitLoad(deck: Deck, meta: LoadedTrack, startMs: Int?, durationSeconds: Double) {
        // A track that played on this deck is being loaded over: its listen ends here.
        reportDeckEnded(deck, MixTrackEndReason.REPLACED)
        resetLoadCycle(deck)
        if (leadDeck == deck) updateUi { it.copy(leadDeck = null) }   // load resets this deck's lead role
        updateDeck(deck) {
            it.copy(
                loaded = meta, startMs = startMs, durationSec = durationSeconds, isPlaying = false,
                rate = 1.0, pitch = 0.0, stemMode = false, stemMuted = emptySet(), stemVol = emptyMap(),
                loopOn = false,
            )
        }
        onLoopInvalidated?.invoke(deck)
        onDeckLoaded?.invoke(deck, meta)
        // Loading stopped this deck OUTSIDE setPlaying: keep the sticky card subject honest.
        stickyFromPlaying()
        setPosition(deck, 0.0)
        params.setTempoPitch(deck, 1.0, 0.0)
        // One .load carrying bpm/camelot; tempo/pitch reset to default are implied by it.
        hooks.emitLoad(deck, meta)
        onNowPlayingChanged?.invoke()
        persist()   // a deck load is a structural change: the mix survives a kill
    }

    // ------------------------------------------------------------------------------ transport

    override fun setPlaying(deck: Deck, playing: Boolean) {
        val was = st(deck).isPlaying
        updateDeck(deck) { it.copy(isPlaying = playing) }
        if (playing == was) return
        onTransport?.invoke(deck, playing)
        onSlotsChanged?.invoke(deck, false)
        if (playing) {
            if (!isRestoringMixSession) onAudioStarted?.invoke()
            rec(MixEventKind.Play, deck)
            hooks.notePlay(deck, st(deck).loaded?.songId)
        } else {
            rec(MixEventKind.Pause, deck)
        }
        // Sticky card subject: the last UNAMBIGUOUS (exactly one deck playing) subject survives
        // pauses/blends; suppressed during batch transport where intermediate states are artifacts.
        if (!suppressStickyUpdates) stickyFromPlaying()
        onNowPlayingChanged?.invoke()
        // Land the freshest playheads on a play/pause transition.
        persistPositions()
    }

    private fun stickyFromPlaying() {
        val aOn = st(Deck.A).isPlaying; val bOn = st(Deck.B).isPlaying
        if (aOn != bOn) lastNowPlayingDeck = if (aOn) Deck.A else Deck.B
    }

    internal fun refreshTransport() {
        val running = st(Deck.A).isPlaying || st(Deck.B).isPlaying
        if (running != _ui.value.isRunning) updateUi { it.copy(isRunning = running) }
    }

    fun play(deck: Deck) {
        if (st(deck).loaded == null) return   // never run an empty deck's playhead
        deckGestureGeneration++
        autoEndedExhausted = false
        masterPausedDecks = emptySet()
        if (!isRestoringMixSession) hasSoundedThisProcess = true
        deckExhaustedFromRestore.remove(deck)   // an explicit start plays the re-cued track from 0:00
        ensureEngine()
        // Even when the sink cannot run right now the deck is still marked playing: that is the
        // INTENT the tick watchdog restores. A HELD stream deck keeps only the intent.
        if (!streamHeld(deck)) controller(deck).play()
        setPlaying(deck, true)
        refreshTransport()
        tick.startIfNeeded()
    }

    fun pause(deck: Deck) {
        // A manual pause during a RUNNING Auto-DJ ends it - but not while auto is PAUSED.
        if (autoMixing && !autoPaused) autoDj?.endAutoLoop()
        silence(deck)
    }

    /** Stop a deck's voice WITHOUT ending an auto mix (the auto machine's own retire step). */
    fun silence(deck: Deck) {
        controller(deck).pause()
        setPlaying(deck, false)
        refreshTransport()
    }

    fun togglePlay(deck: Deck) = if (st(deck).isPlaying) pause(deck) else play(deck)

    fun playBoth() {
        deckGestureGeneration++
        autoEndedExhausted = false
        masterPausedDecks = emptySet()
        if (!isRestoringMixSession) hasSoundedThisProcess = true
        autoDj?.onMasterPlay()
        ensureEngine()
        suppressStickyUpdates = true
        try {
            for (d in Deck.entries) if (st(d).loaded != null) {
                if (!streamHeld(d)) controller(d).play()
                setPlaying(d, true)
            }
        } finally { suppressStickyUpdates = false }
        refreshTransport()
        tick.startIfNeeded()
    }

    fun pauseBoth() {
        masterPausedDecks = Deck.entries.filter { st(it).isPlaying }.toSet()   // what the lock-screen play resumes
        if (autoMixing && !autoPaused) autoDj?.endAutoLoop()   // a manual master Pause ends a RUNNING Auto-DJ
        suppressStickyUpdates = true
        try { for (d in Deck.entries) { controller(d).pause(); setPlaying(d, false) } }
        finally { suppressStickyUpdates = false }
        refreshTransport()
    }

    fun toggleAll() = if (isRunning) pauseBoth() else playBoth()

    /**
     * LOCK-SCREEN play only: resume exactly what the last master pause silenced, falling back to
     * the card's now-playing deck. Only a deck with audio LEFT (and not a restore's re-cued
     * finished deck) is resumable.
     */
    fun resumeMasterPaused() {
        fun resumable(d: Deck) = st(d).loaded != null && position(d) < duration(d) - 0.5 && d !in deckExhaustedFromRestore
        val remembered = masterPausedDecks.filter(::resumable)
        masterPausedDecks = emptySet()
        if (remembered.isEmpty()) {
            val d = nowPlayingDeck
            if (d == null || !resumable(d)) {
                if (autoMixing && autoPaused) autoDj?.resumeAuto()   // advance instead of starting silence
                return
            }
            play(d)
            return
        }
        suppressStickyUpdates = true
        try { for (d in Deck.entries) if (d in remembered) play(d) } finally { suppressStickyUpdates = false }
        stickyFromPlaying()
    }

    /** Rewind to 0:00, keeping the transport state. */
    fun restart(deck: Deck) {
        val was = st(deck).isPlaying
        onLoopInvalidated?.invoke(deck)   // rewinding past a window would leave a stale loop half-armed
        val c = controller(deck)
        if (!c.isOpen && !streamHeld(deck)) return   // a stream still waiting for its first bytes has no voice yet
        c.seekSeconds(0.0)
        setPosition(deck, 0.0)
        if (streamHeld(deck)) onSeeked?.invoke(deck, 0.0)   // held: the stream pump re-checks runway at 0:00
        if (was) {
            startEngineIfNeeded()
            if (!streamHeld(deck)) c.play()
            setPlaying(deck, true)   // already playing: no spurious event
        }
        refreshTransport()
        tick.startIfNeeded()
    }

    /**
     * Full deck RESET: every per-deck parameter back to default (tempo, pitch, volume, all FX off at
     * strength 0.5, EQ flat) then rewind. KEEPS the loaded track, the rack LAYOUT, the lead role and
     * the cue send. ONE semantic `.resetDeck` event.
     */
    fun resetDeck(deck: Deck) {
        updateDeck(deck) { s ->
            s.copy(
                rate = 1.0, pitch = 0.0, volume = 1.0,
                slots = s.slots.map { it.setEnabled(false).setStrength(0.5) },
                eqLow = 0.0, eqMid = 0.0, eqHigh = 0.0, stemMuted = emptySet(), stemVol = emptyMap(),
            )
        }
        pushAllParams(deck)
        restart(deck)
        rec(MixEventKind.ResetDeck, deck)
        persist()
    }

    /** The "zero state": a reset that also EJECTS the track (and drops lead + cue). ONE `.resetDeck`. */
    fun clearDeck(deck: Deck) {
        ejectDeckCore(deck)
        rec(MixEventKind.ResetDeck, deck)
        persist()   // both decks empty (no auto) => the session is cleared
    }

    internal fun ejectDeckCore(deck: Deck) {
        reportDeckEnded(deck, MixTrackEndReason.REPLACED)   // the listen ends here
        resetLoadCycle(deck)
        setPlaying(deck, false)                            // emits .pause BEFORE we forget the track
        onStemsReset?.invoke(deck)
        onLoopInvalidated?.invoke(deck)
        controller(deck).release()
        if (leadDeck == deck) updateUi { it.copy(leadDeck = null) }
        updateDeck(deck) { DeckState() }                    // empty track, every parameter default, cue off
        positions.set(deck, 0.0)
        pushAllParams(deck)
        stickyFromPlaying()
        onNowPlayingChanged?.invoke()
        refreshTransport()
    }

    /** End the WHOLE mix: stop any Auto-DJ and eject both decks (Settings reset rides this). */
    fun ejectAll() {
        pendingRestore = null
        autoDj?.endAutoLoop()
        clearDeck(Deck.A)
        clearDeck(Deck.B)
    }

    /** Seek to an absolute SOURCE position, bounded to the song's window. */
    override fun seek(deck: Deck, sec: Double) {
        val clamped = sec.coerceIn(0.0, duration(deck))
        val c = controller(deck)
        if (!c.isOpen && !streamHeld(deck)) return   // (a held stream has no voice before its first bytes)
        c.seekSeconds(clamped)
        setPosition(deck, clamped)
        onSeeked?.invoke(deck, clamped)
        refreshTransport()
        tick.startIfNeeded()
        autoDj?.onSeek(deck)          // auto mix: re-time the crossfade to the NEW position
        rec(MixEventKind.Seek, deck, value = clamped)
        onNowPlayingChanged?.invoke()
        persist(debounced = true)     // scrub surface: one write per burst
    }

    // ------------------------------------------------------------------------------ params

    /**
     * The rack as the render thread sees it: each slot's stored strength, replaced by the LIVE
     * (possibly modulated) value when [slotStrengthProvider] is wired (MIX-17). The Auto-DJ glide
     * and every engine write go through here, so the glide moves the BASE while the LFO wobbles
     * around it.
     */
    private fun slotParams(deck: Deck, s: DeckState): List<SlotParams?> {
        val p = slotStrengthProvider
        return s.slots.mapIndexed { i, x -> SlotParams(x, p?.invoke(deck, i, x) ?: x.strength) }
    }

    /** The current live rack snapshot for [deck] (GlideMachine, ModController). */
    fun slotParamList(deck: Deck): List<SlotParams?> = slotParams(deck, st(deck))

    /** Land the deck's nodes on the stored strengths / current live values (mod snap-back). */
    fun reapplySlots(deck: Deck) = applySlot(deck)

    /** Push a deck's whole state onto the graph snapshot (after a reset / eject / restore). */
    private fun pushAllParams(deck: Deck) {
        val s = st(deck)
        params.setVolume(deck, s.volume)
        params.setCued(deck, s.cued)
        params.setCueVolume(deck, s.cueVol)
        params.setEq(deck, s.eqLow, s.eqMid, s.eqHigh)
        params.setTempoPitch(deck, s.rate, s.pitch)
        params.setSlots(deck, slotParams(deck, s))
    }

    private fun applySlot(deck: Deck) = params.setSlots(deck, slotParams(deck, st(deck)))

    fun setRate(rate: Double, deck: Deck) {
        updateDeck(deck) { it.copy(rate = rate.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)) }
        params.setTempoPitch(deck, st(deck).rate, st(deck).pitch)
        rec(MixEventKind.Tempo, deck, value = st(deck).rate)
        persist(debounced = true)
    }

    fun setPitch(semitones: Double, deck: Deck) {
        updateDeck(deck) { it.copy(pitch = semitones.coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive)) }
        params.setTempoPitch(deck, st(deck).rate, st(deck).pitch)
        rec(MixEventKind.Pitch, deck, value = st(deck).pitch)
        persist(debounced = true)
    }

    fun setEqGain(band: EQBand, db: Double, deck: Deck) {
        updateDeck(deck) { it.withEq(band, db.coerceIn(MixRanges.eq.start, MixRanges.eq.endInclusive)) }
        val s = st(deck)
        params.setEq(deck, s.eqLow, s.eqMid, s.eqHigh)
        rec(MixEventKind.Eq, deck, param = band.label.lowercase(Locale.ROOT), value = s.eqGain(band))
        persist(debounced = true)
    }

    fun filterMode(deck: Deck): FilterMode {
        val i = st(deck).firstSlot(Effect.FILTER) ?: return FilterMode.LOW_PASS
        return if (st(deck).slots[i].variant == EffectVariant.HIGH_PASS) FilterMode.HIGH_PASS else FilterMode.LOW_PASS
    }

    fun setFilterMode(mode: FilterMode, deck: Deck) {
        val i = st(deck).firstSlot(Effect.FILTER) ?: return
        val v = if (mode == FilterMode.HIGH_PASS) EffectVariant.HIGH_PASS else EffectVariant.LOW_PASS
        updateDeck(deck) { it.withSlot(i) { s -> s.setVariant(v) } }
        applySlot(deck)
        rec(MixEventKind.FilterMode, deck, param = mode.raw)
        persist()
    }

    /** Volume 0...2: 0...1 attenuates on the fader, 1...2 boosts to +6 dB on the trim. */
    fun setVolume(volume: Double, deck: Deck) {
        updateDeck(deck) { it.copy(volume = volume.coerceIn(MixRanges.volume.start, MixRanges.volume.endInclusive)) }
        params.setVolume(deck, st(deck).volume)   // the only writer of the trim (boost)
        rec(MixEventKind.Volume, deck, value = st(deck).volume)
        persist(debounced = true)
    }

    fun setCrossfader(value: Double) {
        applyCrossfader(value)
        rec(MixEventKind.Crossfader, null, value = crossfader)
        persist(debounced = true)
    }

    /**
     * Non-recording crossfade apply: the auto-DJ internals use THIS so machine moves are not logged
     * as user `.crossfader` gestures (an Auto on->off on an idle session stays empty). Touches only
     * the main gain: the trim/boost is never re-derived on this path.
     */
    fun applyCrossfader(value: Double) {
        val v = value.coerceIn(0.0, 1.0)
        updateUi { it.copy(crossfader = v) }
        params.setCrossfader(v.toFloat())
    }

    // ---- cue / PFL (transient monitoring state: not recorded, not persisted)

    fun setCued(on: Boolean, deck: Deck) {
        updateDeck(deck) { it.copy(cued = on) }
        params.setCued(deck, on)
    }

    fun toggleCue(deck: Deck) = setCued(!st(deck).cued, deck)

    fun setCueVolume(value: Double, deck: Deck) {
        updateDeck(deck) { it.copy(cueVol = value.coerceIn(0.0, 1.0)) }
        params.setCueVolume(deck, st(deck).cueVol)
    }

    fun setCueOnRight(right: Boolean) {
        updateUi { it.copy(cueOnRight = right) }
        params.setCueOnRight(right)
    }

    // ---- lead / sync

    /** Designate (or clear) the Lead deck. Tapping the current lead clears it. */
    fun setLead(deck: Deck) {
        updateUi { it.copy(leadDeck = if (it.leadDeck == deck) null else deck) }
        rec(MixEventKind.Lead, deck, flag = isLead(deck))
        persist()
    }

    /** The BPM to beat-match on: the MEASURED grid BPM when available, else the catalog BPM. */
    internal fun matchBpm(deck: Deck): Double? {
        val l = st(deck).loaded
        l?.gridBpm?.takeIf { it > 0 }?.let { return it }
        return l?.bpm?.takeIf { it > 0 }
    }

    fun canSync(deck: Deck): Boolean {
        val lead = leadDeck ?: return false
        return lead != deck && matchBpm(lead) != null && matchBpm(deck) != null
    }

    /**
     * Match the follower's effective BPM to the Lead (octave-folded), then best-effort phase-align
     * the downbeats. No-op without a Lead, for the lead itself, or with an unknown BPM.
     * Records `.tempo` (+ the phase-align `.seek`) and a `.sync` marker.
     */
    fun syncToLead(follower: Deck) {
        val lead = leadDeck ?: return
        if (lead == follower) return
        val leadBpm = matchBpm(lead) ?: return
        val folBpm = matchBpm(follower) ?: return
        setRate(MixMath.syncRate(leadBpm, st(lead).rate, folBpm), follower)
        phaseAlign(follower, lead)
        rec(MixEventKind.Sync, follower, value = st(follower).rate)
    }

    private fun phaseAlign(f: Deck, l: Deck) {
        if (!st(f).isPlaying || !st(l).isPlaying) return
        val leadBpm = matchBpm(l) ?: return
        val folBpm = matchBpm(f) ?: return
        val leadBeat = 60.0 / leadBpm
        val folBeat = 60.0 / folBpm
        // Phase relative to each song's measured first downbeat (0 when the grid is absent).
        val leadDb = (st(l).loaded?.firstDownbeatMs ?: 0) / 1000.0
        val folDb = (st(f).loaded?.firstDownbeatMs ?: 0) / 1000.0
        val leadPhase = ((position(l) - leadDb) / leadBeat) % 1.0
        val folPhase = ((position(f) - folDb) / folBeat) % 1.0
        var delta = leadPhase - folPhase
        if (delta > 0.5) delta -= 1 else if (delta < -0.5) delta += 1
        seek(f, maxOf(0.0, position(f) + delta * folBeat))
    }

    // ---- FX rack

    fun setEffect(effect: Effect, enabled: Boolean, deck: Deck) {
        updateDeck(deck) { it.withEnabled(effect, enabled) }
        applySlot(deck)
        rec(MixEventKind.EffectToggle, deck, param = effect.raw, flag = enabled)
        persist()
    }

    fun setEffectStrength(effect: Effect, strength: Double, deck: Deck) {
        updateDeck(deck) { it.withStrength(effect, strength) }
        applySlot(deck)
        rec(MixEventKind.EffectStrength, deck, param = effect.raw, value = st(deck).strength(effect))
        persist(debounced = true)
    }

    fun setSlot(i: Int, enabled: Boolean, deck: Deck) {
        val s = st(deck).slots.getOrNull(i) ?: return
        if (s.enabled == enabled) return
        updateDeck(deck) { it.withSlot(i) { x -> x.setEnabled(enabled) } }
        applySlot(deck)
        rec(MixEventKind.EffectToggle, deck, param = s.effect.raw, flag = enabled, slot = i)
        onSlotsChanged?.invoke(deck, false)
        persist()
    }

    fun setSlotStrength(i: Int, strength: Double, deck: Deck) {
        if (st(deck).slots.getOrNull(i) == null) return
        updateDeck(deck) { it.withSlot(i) { x -> x.setStrength(strength) } }
        applySlot(deck)
        val s = st(deck).slots[i]
        rec(MixEventKind.EffectStrength, deck, param = s.effect.raw, value = s.strength, slot = i)
        persist(debounced = true)
    }

    /** Swap a slot's effect family: variant resets to the family default; on/off + strength are kept. */
    fun setSlotEffect(effect: Effect, slot: Int, deck: Deck) {
        val s = st(deck).slots.getOrNull(slot) ?: return
        if (s.effect == effect) return
        updateDeck(deck) { it.withSlot(slot) { x -> x.setEffect(effect) } }
        applySlot(deck)
        rec(MixEventKind.EffectSlot, deck, param = effect.raw, slot = slot)
        onSlotsChanged?.invoke(deck, false)
        persist()
    }

    fun setSlotMod(mod: SlotMod, slot: Int, deck: Deck) {
        val s = st(deck).slots.getOrNull(slot) ?: return
        if (s.mod == mod.normalized()) return
        updateDeck(deck) { it.withSlot(slot) { x -> x.setMod(mod) } }
        applySlot(deck)
        rec(
            MixEventKind.EffectMod, deck, param = "${mod.source.raw}:${mod.rate.raw}:${mod.shape.raw}",
            value = mod.depth, slot = slot,
        )
        onSlotsChanged?.invoke(deck, true)
        persist()
    }

    fun setSlotVariant(variant: EffectVariant, slot: Int, deck: Deck) {
        val s = st(deck).slots.getOrNull(slot) ?: return
        if (s.variant == variant || variant.effect != s.effect) return
        updateDeck(deck) { it.withSlot(slot) { x -> x.setVariant(variant) } }
        applySlot(deck)
        rec(MixEventKind.EffectVariant, deck, param = variant.raw, slot = slot)
        persist()
    }

    // ------------------------------------------------------------------------------ now playing

    /** Exactly one deck playing -> it; else the sticky last subject; else A, then B. */
    val nowPlayingDeck: Deck?
        get() = NowPlayingRule.pick(
            st(Deck.A).loaded != null, st(Deck.B).loaded != null,
            st(Deck.A).isPlaying, st(Deck.B).isPlaying, lastNowPlayingDeck,
        )

    val nowPlaying: LoadedTrack? get() = nowPlayingDeck?.let { st(it).loaded }

    /**
     * The TRUE audio playhead in source seconds from the deck voice's own frame counter (the beat
     * pulse reads this at 60 fps). It honors seek and loop folding. null while the voice is not
     * rendering (just loaded / paused / ended): callers fall back to [position].
     */
    fun truePlayhead(deck: Deck): Double? = controller(deck).trueSeconds()

    // ------------------------------------------------------------------------------ outcomes

    internal fun reportDeckEnded(deck: Deck, reason: MixTrackEndReason) {
        hooks.reportEnded(deck, st(deck).loaded?.songId, position(deck), duration(deck), reason)
    }

    internal fun resetLoadCycle(deck: Deck) {
        deckExhaustedFromRestore.remove(deck)   // a fresh load is never the restore's finished track
        hooks.resetLoadCycle(deck)
    }

    /** Report that a deck's track stopped being the music (skip / natural end), for the Auto-DJ. */
    fun reportTrackEnded(deck: Deck, reason: MixTrackEndReason) = reportDeckEnded(deck, reason)

    // ------------------------------------------------------------------------------ persistence

    override fun persist(debounced: Boolean) {
        val store = sessionStore ?: return
        // A restore is not a write, and a parked snapshot IS the on-disk state: neither may be
        // clobbered or cleared by an idle-engine write.
        if (isRestoringMixSession || pendingRestore != null) return
        val snap = mixDeckSnapshot()
        // Before the launch restore is parked/attempted an empty engine's setter must not wipe the saved mix.
        if (snap == null) { if (restoreSettled) store.clear(); return }
        if (debounced) store.saveDebounced(snap) else store.save(snap)
    }

    /** The live state as a snapshot; null when there is nothing to restore. */
    fun mixDeckSnapshot(): MixDeckSnapshot? = MixPersistence.snapshot(
        deckSnapshot(Deck.A), deckSnapshot(Deck.B), crossfader, leadDeck?.label,
        autoDj?.snapshot(), isRunning, nowMs(),
    )

    private fun deckSnapshot(d: Deck): DeckSnapshot? =
        MixPersistence.deckSnapshot(
            st(d), (position(d) * 1000).toInt().coerceAtLeast(0),
            stemModeOnProvider?.invoke(d) ?: st(d).stemMode,
        )

    /** The decks' playheads -> the store's throttled position channel (immediate on a run/pause transition). */
    internal fun persistPositions() {
        if (isRestoringMixSession || pendingRestore != null || !restoreSettled) return
        val store = sessionStore ?: return
        val playing = st(Deck.A).isPlaying || st(Deck.B).isPlaying
        val a = (position(Deck.A) * 1000).toInt().coerceAtLeast(0)
        val b = (position(Deck.B) * 1000).toInt().coerceAtLeast(0)
        // iOS P1-9 taint: a silent run (decoder stalled, sink rendering zeros) must not persist
        // advancing playheads, or a never-audible restore creeps to end-of-file across launches.
        val now = nowMs()
        if (!playing) runningSinceMs = 0L else if (runningSinceMs == 0L) runningSinceMs = now
        val audibleAge = tapAgeSeconds(true)
        val tainted = playing && now - runningSinceMs > SILENT_TAINT_MS && (audibleAge < 0 || audibleAge > SILENT_TAINT_MS / 1000.0)
        if (tainted) {
            store.updatePosition(trustedA, trustedB, true)
        } else {
            trustedA = a; trustedB = b
            store.updatePosition(a, b, playing)
        }
    }

    private var runningSinceMs = 0L
    private var trustedA = 0
    private var trustedB = 0

    // ---- restore

    /** True while a launch-read snapshot is parked and not yet materialized. */
    val hasParkedRestore: Boolean get() = pendingRestore != null

    val parkedRestoreSummary: MixPersistence.ParkedSummary?
        get() = pendingRestore?.let(MixPersistence::parkedSummary)

    /**
     * Relaunch entry: read the persisted snapshot and PARK it (no audio, no sink, no card). Skipped
     * when the engine is already in use. If the Mix tab already asked to materialize, do it now
     * unless a set list is live.
     */
    fun restorePersistedMixIfIdle() {
        val store = sessionStore ?: return
        if (isRunning || autoMixing || st(Deck.A).loaded != null || st(Deck.B).loaded != null) { restoreSettled = true; return }
        restoreSettled = true
        val snap = store.load() ?: return
        pendingRestore = snap
        diag("mix RESTORE parked decks=${if (snap.deckA != null) "A" else ""}${if (snap.deckB != null) "B" else ""} auto=${snap.auto?.queue?.size ?: 0}")
        if (!materializeWanted) return
        if (setlistIsLive?.invoke() == true) { diag("materialize skipped setlistLive=1"); return }
        materializeNow("launchTask")
    }

    /** Mix-surface entry: actually re-load the parked snapshot onto the decks. Idempotent. */
    fun materializePendingRestoreIfNeeded(trigger: String = "mixTab") {
        materializeWanted = true
        // Nothing parks the launch restore for us: park from the store on first ask. That park is the launch
        // read, so IT applies the live-set-list guard (and materializes when no set list is live).
        if (pendingRestore == null && !restoreSettled) { restorePersistedMixIfIdle(); return }
        // Final review recheck (iOS materializePendingRestoreIfNeeded): a LATER Mix-surface request always
        // finishes the job. Only the launch read defers to a live set list; a held run (durable, can last
        // across launches) must not hide the parked mix from the Mix tab forever.
        materializeNow(trigger)
    }

    /**
     * Rebuild the mix from the parked snapshot: decks re-loaded and CUED at their saved playheads,
     * mixer state re-applied, Auto-DJ queue rebuilt SUSPENDED. Nothing plays, the recorder is
     * detached (a restore is not a user gesture), and nothing claims the audio owner. A vanished
     * file leaves that deck empty.
     */
    private fun materializeNow(trigger: String) {
        val snap = pendingRestore ?: return
        pendingRestore = null
        if (isRunning || autoMixing || st(Deck.A).loaded != null || st(Deck.B).loaded != null) return
        isRestoringMixSession = true
        val savedRecorder = hooks.recorder
        hooks.recorder = null
        try {
            ensureEngine(startNow = false)   // INERT: no sink start
            snap.deckA?.let { restoreDeck(Deck.A, it) }
            snap.deckB?.let { restoreDeck(Deck.B, it) }
            applyCrossfader(snap.crossfader)
            val lead = snap.leadDeck?.let(Deck::fromLabel)
            if (lead != null && st(lead).loaded != null) updateUi { it.copy(leadDeck = lead) }   // after loads
            snap.auto?.let { autoDj?.restoreSuspended(it) }
            diag("materialize trigger=$trigger xfader=${String.format(Locale.US, "%.2f", snap.crossfader)} lead=${snap.leadDeck ?: "-"}")
        } finally {
            hooks.recorder = savedRecorder
            isRestoringMixSession = false
            // NO persist here: a restore is not a write.
        }
    }

    private fun restoreDeck(deck: Deck, ds: DeckSnapshot) {
        val t = ds.track
        load(MixLoadable(t.songId, t.title, t.artist, t.bpm, t.camelot, t.key, t.albumId, t.lengthMs), deck)
        if (st(deck).loaded?.songId != t.songId) return   // file vanished -> deck empty
        setVolume(ds.volume, deck)
        setRate(ds.rate, deck)
        setPitch(ds.pitch, deck)
        // Whole rack in ONE state write (lossless slots, or the pre-rack flat fields migrated).
        updateDeck(deck) { it.copy(slots = MixPersistence.restoredSlots(ds)) }
        applySlot(deck)
        setEqGain(EQBand.LOW, ds.eqLow ?: 0.0, deck)
        setEqGain(EQBand.MID, ds.eqMid ?: 0.0, deck)
        setEqGain(EQBand.HIGH, ds.eqHigh ?: 0.0, deck)
        // A deck persisted AT its end has nothing left to schedule: re-cue to 0:00, mark exhausted.
        val lenMs = t.lengthMs ?: duration(deck).takeIf { it > 0 }?.let { (it * 1000).toInt() }
        if (MixPersistence.atEnd(ds.positionMs, lenMs)) deckExhaustedFromRestore.add(deck)
        else if (ds.positionMs > 0) seek(deck, ds.positionMs / 1000.0)   // cue, not play
        onRestoreDeckExtras?.invoke(deck, ds)   // stem mode + loop (MIX-8) arm after the seek
        diag("restore: deck ${deck.label} pos=${ds.positionMs} len=${lenMs ?: "-"} recued=${if (deck in deckExhaustedFromRestore) 1 else 0}")
    }

    private companion object { const val SILENT_TAINT_MS = 3000L }
}
