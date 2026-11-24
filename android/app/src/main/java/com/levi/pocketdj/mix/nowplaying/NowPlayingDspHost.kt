package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.model.Effect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What the host needs from the app (production: PlaybackController + BurnStore + the switchboard). */
interface DspHostPorts {
    /** The playing row (null = nothing / Apple Music / a held restore). */
    val currentSongId: String?
    val currentTitle: String?
    val currentArtist: String?
    val currentArtworkUri: String?
    /** A restored session waiting for its first play. */
    val heldForResume: Boolean
    /** The Mix tab owns audio (iOS `mix.isRunning || mix.autoMixing`). */
    val mixSessionActive: Boolean
    /** Apple Music (no file) is the active backend. */
    val appleMusicActive: Boolean
    /** The burned/local file for [songId] (null = not mixable). */
    fun resolve(songId: String): ResolvedTrack?
    /** Window length for the row (the QUEUE row's clipped length), 0 = whole file. */
    fun windowLengthMs(songId: String): Long
    /** The song ExoPlayer has actually LOADED (the controller's current item), null = none/other. The Stem Lock carry waits for it. */
    val loadedSongId: String? get() = currentSongId
    /** Current ExoPlayer position within the song, ms (read at the moment of the swap). */
    suspend fun positionMs(): Long
    /** Is ExoPlayer currently producing audio? (engage plays only if so.) */
    val exoPlaying: Boolean
    /** The listener wants audio (iOS `!pausedByListener`): a just-loaded row may still be buffering, so [exoPlaying] is not enough. */
    val playWanted: Boolean get() = exoPlaying
    /** The natural end of the engaged window: advance the sequencer exactly like an ExoPlayer ENDED. */
    fun advanceAfterEnd(songId: String)
    /** The engine ended its window: reset session-side state (resign the MediaSession) BEFORE the sequencer advances/replays. */
    fun engineEnded() {}
    fun log(line: String) {}
    /**
     * P2-MM-8: the playing row streams from its presigned URL (no local file) and Mix Mode's buffer already covers the
     * playhead: the first control touch can move it onto the GROWING file. Cheap (a byte estimate); default off.
     */
    fun growingTouchReady(songId: String): Boolean = false
    /** P2-MM-8: do that hand-off now ([play] = the listener wants sound; false stays paused). False = refused, nothing touched. */
    suspend fun engageGrowingFromStream(songId: String, play: Boolean): Boolean = false
    /**
     * P2-MM-9: the row sounds on Apple Music and has a complete local copy: the first control touch can hand it off to
     * the DSP (AppleMusicHandOff). Cheap (a cached verdict); default off.
     */
    fun appleMusicHandOffReady(songId: String): Boolean = false
    /** P2-MM-9: do that hand-off now ([play] = the listener wants sound; false stays paused). False = refused, nothing touched. */
    suspend fun handOffFromAppleMusic(songId: String, play: Boolean): Boolean = false
}

/** Immutable snapshot for the panel (the engine is not observable by Compose). */
data class DspUiState(
    val available: Boolean = false,
    val engaged: Boolean = false,
    val rate: Double = 1.0,
    val pitch: Double = 0.0,
    val volume: Double = 1.0,
    val effectsOn: Set<Effect> = emptySet(),
    val effectStrength: Map<Effect, Double> = emptyMap(),
    val stemMode: Boolean = false,
    val stemHandover: StemHandover? = null,
    val stemsObtainable: Boolean = false,
    val muted: Set<String> = emptySet(),
    val volumes: Map<String, Double> = emptyMap(),
    val lock: StemLockState = StemLockState(),
    val indicator: StemLock.Indicator = StemLock.Indicator.OFF,
    val fxLock: FxLockState = FxLockState(),
    val fxIndicator: FxLock.Indicator = FxLock.Indicator.OFF,
    val tick: Int = 0,
)

/**
 * Glue between the app's playback (ExoPlayer via the sequencer) and the [NowPlayingDspEngine]: the
 * swap-on-touch hand-off, the Stem Lock carry on every track start, and the panel's state (iOS
 * `SetlistPlayer.engageMix` / `applyStemLockOnTrackStart` / `mixAvailable`). Main thread.
 */
class NowPlayingDspHost(
    val engine: NowPlayingDspEngine,
    val lock: StemLockSession,
    private val ports: DspHostPorts,
    /** Re-plan the prefetch lane (production wires `StemLockPrefetcher.plan`); called on lock/track/queue changes. */
    private val replan: () -> Unit = {},
    /** The session-scoped FX Lock carry (P2-FX-1); production shares it with the session writer. */
    val fxLock: FxLockSession = FxLockSession(),
) {
    private val _ui = MutableStateFlow(DspUiState())
    val ui: StateFlow<DspUiState> = _ui.asStateFlow()
    private var version = 0
    /** Song the engine's hand-off is currently armed for (guards async work). */
    private var lastTrackSongId: String? = null
    /** One engage at a time: concurrent slider events must not tear down/rebuild the graph. */
    private val engageLock = Mutex()
    /** A track started whose Stem Lock carry waits for ExoPlayer to finish loading the row. */
    private var carryPending: String? = null

    init {
        engine.onChanged = { publish() }
        engine.onUserStemChange = { stemControlsChangedByUser() }
        engine.onUserEffectChange = { effectsChangedByUser() }
        engine.onStemsOnAir = { id -> StemLock.log("handover song=$id full mix -> stems @${"%.2f".format(java.util.Locale.US, engine.currentTimeSec)}s") ; publish() }
        engine.onReachedEnd = {
            val id = engine.engagedSongId
            if (id != null) {
                // Leave the graph FIRST so a repeat/advance is driven by ExoPlayer (iOS handleDSPEnded).
                engine.disengage()
                engine.resetControls()
                stampFxIfIdle()
                ports.engineEnded()
                publish()
                ports.advanceAfterEnd(id)
            }
        }
    }

    /**
     * iOS `mixAvailable`: the panel shows ONLY for a local/mixable file while no Mix session runs - hidden,
     * never greyed. Cheap enough for composition (resolver is a map lookup).
     */
    fun available(): Boolean {
        val id = ports.currentSongId ?: return false
        if (ports.mixSessionActive || ports.heldForResume) return false
        // P2-MM-9: an Apple Music row is mixable only once it can hand off to its local copy (hidden, never greyed, otherwise).
        if (ports.appleMusicActive) return ports.appleMusicHandOffReady(id)
        return engine.isEngaged && engine.engagedSongId == id || ports.resolve(id) != null || ports.growingTouchReady(id)
    }

    /** P2-MM-9: the row has a complete local copy the DSP can open (the Apple Music hand-off's target). */
    fun hasLocalCopy(songId: String): Boolean = ports.resolve(songId) != null

    /**
     * P2-MM-9: open the DSP on [songId]'s local copy at [atSeconds], PAUSED (the Apple Music hand-off's step 2; the engage
     * claims the session). False = refused (no copy / undecodable): nothing was touched.
     */
    suspend fun engageLocalPaused(songId: String, atSeconds: Double): Boolean = engageLock.withLock {
        if (ports.currentSongId != songId || ports.mixSessionActive || ports.heldForResume) return@withLock false
        if (isEngagedFor(songId)) return@withLock true
        val t = ports.resolve(songId) ?: return@withLock false
        val ok = engine.engage(t.file, if (t.isCut) 0L else (t.startMs ?: 0).toLong(), ports.windowLengthMs(songId), atSeconds, false)
        if (!ok) { ports.log("npdsp am-handoff engage REFUSED song=$songId"); publish(); return@withLock false }
        engine.bindSong(songId)
        publish()
        true
    }

    /** Idempotent and serialized: the FIRST control touch hands the playing track off ExoPlayer into the DSP graph. */
    suspend fun engage(): Boolean = engageLock.withLock { engageLocked(null, null) }

    private suspend fun engageLocked(atSeconds: Double?, play: Boolean?): Boolean {
        val id = ports.currentSongId ?: return false
        if (engine.isEngaged && engine.engagedSongId == id) return true
        if (!available()) return false
        if (ports.appleMusicActive) {
            if (atSeconds != null) return false
            val ok = ports.handOffFromAppleMusic(id, play ?: ports.playWanted)
            publish()
            return ok
        }
        val t = ports.resolve(id)
        if (t == null) {
            // P2-MM-8: no local file, but Mix Mode's buffer covers the playhead - the touch moves the row onto the growing file.
            if (atSeconds != null || !ports.growingTouchReady(id)) return false
            val ok = ports.engageGrowingFromStream(id, play ?: ports.playWanted)
            publish()
            return ok
        }
        val pos = atSeconds ?: (ports.positionMs() / 1000.0)
        val go = play ?: ports.exoPlaying
        val ok = engine.engage(t.file, if (t.isCut) 0L else (t.startMs ?: 0).toLong(), ports.windowLengthMs(id), pos, go)
        if (!ok) { lock.markUnavailable(id); ports.log("npdsp engage REFUSED song=$id"); publish(); return false }
        engine.bindSong(id)
        // controls touched before the swap (carried stems) are re-applied by the caller
        publish()
        return true
    }

    /** The panel's control wrappers: engage first, then apply. */
    suspend fun withEngaged(block: (NowPlayingDspEngine) -> Unit) { if (engage()) block(engine) }

    /** A new track started playing (or the queue's current row changed). */
    suspend fun onTrackStarted(songId: String?) {
        if (songId == lastTrackSongId && engine.engagedSongId == songId) return
        lastTrackSongId = songId
        carryPending = null
        if (engine.isEngaged && engine.engagedSongId != songId) engine.disengage()
        engine.resetControls()
        stampFxIfIdle()   // the carry IS the control state while idle: the panel shows it, the next engage ramps it in
        lock.trackStarted()
        publish()
        replan()
        // The carry engages only once ExoPlayer has LOADED this row (a load yields/pauses the DSP owner and
        // the controller still holds the previous row until then): pending until [carryIfReady] sees it.
        if (songId != null && (lock.current.enabled || fxLock.current.enabled)) carryPending = songId
        carryIfReady()
    }

    /** Heartbeat/collector hook: apply the pending Stem Lock carry once the new row is loaded. */
    suspend fun carryIfReady() {
        val id = carryPending ?: return
        if (ports.currentSongId != id) { carryPending = null; return }
        if (isEngagedFor(id)) { carryPending = null; return } // P2-MM-8: a growing start engaged the row itself (stems follow its completion; the engage ramped the effects in)
        if (ports.loadedSongId != id) return
        carryPending = null
        engageLock.withLock { applyLocksOnTrackStart(id) }
        publish()
    }

    /** The DSP owns [songId] right now (swap-on-land never reloads ExoPlayer under an engaged DSP). */
    fun isEngagedFor(songId: String): Boolean = engine.isEngaged && engine.engagedSongId == songId

    /**
     * SWAP-ON-LAND under a Stem Lock carrying stems (P2-MM-5): the playing row's local file just landed, so the DSP
     * engages on it directly at [atMs] (song-relative, playing) instead of an ExoPlayer reload. False = not applicable
     * (no lock / stems off / a different row) or the DSP refused: the caller falls back to the plain reload.
     */
    suspend fun engageForHandOff(songId: String, atMs: Long): Boolean = engageLock.withLock {
        val st = lock.current
        if (ports.currentSongId != songId || ports.heldForResume || ports.mixSessionActive) return@withLock false
        if (!(st.enabled && st.wantsStems && st.stemsOn) && !fxLock.current.wantsFX) return@withLock false
        if (isEngagedFor(songId)) return@withLock true
        applyLocksOnTrackStart(songId, atMs / 1000.0)
        publish()
        isEngagedFor(songId)
    }

    /** iOS `applyLocksOnTrackStart`: the Stem Lock first, the FX Lock last (both ride the same engage). */
    private suspend fun applyLocksOnTrackStart(songId: String?, atSeconds: Double = 0.0) {
        applyLockOnTrackStart(songId, atSeconds)
        applyFxLockOnTrackStart(songId, atSeconds)
    }

    /**
     * iOS `applyFXLockOnTrackStart`: locked with an effect ON, a mixable row is handed to the DSP at once so the
     * carried effects ramp in from its first second. A row the DSP cannot own plays dry (WAITING); a live Mix tab
     * leaves the lock DORMANT; a file the DSP cannot open stays on ExoPlayer.
     */
    private suspend fun applyFxLockOnTrackStart(songId: String?, atSeconds: Double) {
        val st = fxLock.current
        if (!st.enabled || songId == null || ports.heldForResume) return
        if (!st.wantsFX) { FxLock.log("carry song=$songId fx=none -> dry"); return }
        if (isEngagedFor(songId)) { FxLock.log("carry song=$songId ${st.logSummary} -> on the DSP (engaged at start)"); return }
        if (ports.mixSessionActive) { FxLock.log("carry song=$songId ${st.logSummary} -> DORMANT (Mix tab live) - dry, lock kept"); return }
        if (ports.appleMusicActive || ports.resolve(songId) == null) {
            val why = if (ports.appleMusicActive) "Apple Music" else "not a local file"
            FxLock.log("carry song=$songId ${st.logSummary} -> WAITING ($why) - dry, lock kept")
            return
        }
        fxLock.applying = true
        try {
            if (!engageLocked(atSeconds, ports.playWanted)) {
                FxLock.log("carry song=$songId ${st.logSummary} -> WAITING (DSP refused the file) - dry, lock kept")
                return
            }
            // The engage ramped the stamped effects in; if anything moved the control state in between, the carry wins.
            if (engine.effectSettings() != st.knownEffects) engine.applyCarriedEffects(st.effects)
            FxLock.log("carry song=$songId ${st.logSummary} -> engaged at start (ramp ${(engine.fxRampSeconds * 1000).toInt()}ms)")
        } finally { fxLock.applying = false }
    }

    /** The DSP is idle (between engagements): its control state IS the carry. */
    private fun stampFxIfIdle() {
        if (!fxLock.current.enabled || engine.isEngaged) return
        fxLock.applying = true
        try { engine.applyCarriedEffects(fxLock.current.effects) } finally { fxLock.applying = false }
    }

    /** A held restore delivered the lock: show/stamp its effects on the idle DSP. */
    fun restoreFxStamp() { stampFxIfIdle(); publish(); replan() }

    private fun effectsChangedByUser() {
        val wanted = fxLock.current.wantsFX
        val changed = fxLock.onUserEffectChange(engine.effectSettings())
        if (changed) {
            FxLock.log("carry updated mid-track song=${engine.engagedSongId ?: "-"} ${fxLock.current.logSummary}")
            // Only an effect switching the lock between "carries something" and "nothing" changes the lane.
            if (fxLock.current.wantsFX != wanted) replan()
        }
        publish()
    }

    /** The FX lock capsule: ON captures the current effects as the carry; OFF forgets them. No-op without a running track. */
    fun setFxLock(on: Boolean) {
        if (ports.currentSongId == null) return
        fxLock.setLock(on, if (on) engine.effectSettings() else emptyMap())
        // Off with the DSP idle: a stamped carry nobody hears yet must not leak into the next engage.
        if (!on && !engine.isEngaged) engine.resetControls()
        FxLock.log("lock ${if (on) "ON" else "OFF"} song=${ports.currentSongId ?: "-"}${if (on) " carry " + fxLock.current.logSummary else ""}")
        publish(); replan()
    }

    fun fxIndicator(): FxLock.Indicator = FxLockSession.indicator(
        fxLock.current, ports.currentSongId, ports.heldForResume,
        engaged = engine.isEngaged && engine.engagedSongId == ports.currentSongId, mixSessionActive = ports.mixSessionActive,
    )

    /** iOS `applyStemLockOnTrackStart`: a locked track starts on the FULL MIX and hands over once the enabled parts are on disk. */
    private suspend fun applyLockOnTrackStart(songId: String?, atSeconds: Double = 0.0) {
        val st = lock.current
        if (!st.enabled || songId == null || ports.heldForResume) return
        if (!st.stemsOn) { StemLock.log("carry song=$songId stems=off -> full mix"); return }
        val t = ports.resolve(songId)
        if (t == null || ports.mixSessionActive) {
            lock.markUnavailable(songId)
            StemLock.log("carry song=$songId ${st.logSummary} -> UNAVAILABLE (not a local file) - full mix, lock kept")
            return
        }
        lock.applying = true
        try {
            // iOS applyStemLockOnTrackStart: engaged at 0 (the row just loaded), playing unless the listener paused.
            if (!engageLocked(atSeconds, ports.playWanted)) {
                lock.markUnavailable(songId)
                StemLock.log("carry song=$songId -> UNAVAILABLE (DSP refused the file) - full mix, lock kept")
                return
            }
            engine.applyCarriedStemControls(st.muted.toSet(), st.volumes)
            if (!engine.requestStemModeForLock(true)) {
                lock.markUnavailable(songId)
                StemLock.log("carry song=$songId ${st.logSummary} -> UNAVAILABLE (no stems) - full mix, lock kept")
            } else StemLock.log("carry song=$songId ${st.logSummary} -> full mix first, stems loading")
        } finally { lock.applying = false }
    }

    private fun stemControlsChangedByUser() {
        val changed = lock.onUserStemChange(engine.stemSnapshot(), engine.engagedSongId, engine.stemMode)
        if (changed) { StemLock.log("carry updated mid-track song=${engine.engagedSongId ?: "-"} ${lock.current.logSummary}"); replan() }
        publish()
    }

    /** The lock button (🔒): ON captures the current track's stem state. No-op without a running track. */
    fun setStemLock(on: Boolean) {
        if (ports.currentSongId == null) return
        lock.setLock(on, if (on && engine.isEngaged) engine.stemSnapshot() else null)
        StemLock.log("lock ${if (on) "ON" else "OFF"} song=${ports.currentSongId ?: "-"}${if (on) " carry " + lock.current.logSummary else ""}")
        publish(); replan()
    }

    /** A new session / stop: unlocked, nothing carried, nothing downloading for it. */
    fun sessionEnded() {
        val hadFx = fxLock.current.enabled
        lock.reset(); fxLock.reset(); lastTrackSongId = null
        if (hadFx && !engine.isEngaged) engine.resetControls()   // an idle DSP drops a stamped carry
        publish(); replan()
    }

    fun indicator(): StemLock.Indicator = StemLockSession.indicator(
        lock.current, ports.currentSongId, ports.heldForResume, lock.unavailableSongId,
        engaged = engine.isEngaged && engine.engagedSongId == ports.currentSongId,
        stemsOnAir = engine.stemsOnAir, stemsLoading = engine.stemsLoading,
    )

    /** Host heartbeat (~4 Hz): engine tick + panel state refresh while engaged. */
    fun heartbeat() { engine.tick(); if (engine.isEngaged) publish() }

    /** Re-publish the panel state (the Mix session flag or the current row changed under the host). */
    fun refresh() = publish()

    private fun publish() {
        val id = ports.currentSongId
        _ui.value = DspUiState(
            available = available(), engaged = engine.isEngaged,
            rate = engine.rate, pitch = engine.pitch, volume = engine.volume,
            effectsOn = Effect.entries.filter { engine.isEnabled(it) }.toSet(),
            effectStrength = Effect.entries.associateWith { engine.strength(it) },
            stemMode = engine.stemMode, stemHandover = engine.stemHandover,
            stemsObtainable = id != null && (engine.isEngaged || ports.resolve(id) != null) && stemsObtainable(id),
            muted = engine.mutedStems, volumes = engine.stemVolumes,
            lock = lock.current, indicator = indicator(), fxLock = fxLock.current, fxIndicator = fxIndicator(), tick = ++version,
        )
    }

    private fun stemsObtainable(id: String): Boolean = engine.stemsAvailableFor(id)
}
