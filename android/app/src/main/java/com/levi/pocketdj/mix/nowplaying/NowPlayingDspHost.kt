package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.engine.ResolvedTrack
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.model.Effect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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
    /** Window length for the row (clipped analog duration), 0 = whole file. */
    fun windowLengthMs(songId: String): Long
    /** Current ExoPlayer position within the song, ms (read at the moment of the swap). */
    suspend fun positionMs(): Long
    /** Is ExoPlayer currently producing audio? (engage plays only if so.) */
    val exoPlaying: Boolean
    /** The natural end of the engaged window: advance the sequencer exactly like an ExoPlayer ENDED. */
    fun advanceAfterEnd(songId: String)
    fun log(line: String) {}
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
) {
    private val _ui = MutableStateFlow(DspUiState())
    val ui: StateFlow<DspUiState> = _ui.asStateFlow()
    private var version = 0
    /** Song the engine's hand-off is currently armed for (guards async work). */
    private var lastTrackSongId: String? = null

    init {
        engine.onChanged = { publish() }
        engine.onUserStemChange = { stemControlsChangedByUser() }
        engine.onStemsOnAir = { id -> StemLock.log("handover song=$id full mix -> stems @${"%.2f".format(java.util.Locale.US, engine.currentTimeSec)}s") ; publish() }
        engine.onReachedEnd = {
            val id = engine.engagedSongId
            if (id != null) ports.advanceAfterEnd(id)
        }
    }

    /**
     * iOS `mixAvailable`: the panel shows ONLY for a local/mixable file while no Mix session runs - hidden,
     * never greyed. Cheap enough for composition (resolver is a map lookup).
     */
    fun available(): Boolean {
        val id = ports.currentSongId ?: return false
        if (ports.mixSessionActive || ports.appleMusicActive || ports.heldForResume) return false
        return engine.isEngaged && engine.engagedSongId == id || ports.resolve(id) != null
    }

    /** Idempotent: the FIRST control touch hands the playing track off ExoPlayer into the DSP graph. */
    suspend fun engage(): Boolean {
        val id = ports.currentSongId ?: return false
        if (engine.isEngaged && engine.engagedSongId == id) return true
        if (!available()) return false
        val t = ports.resolve(id) ?: return false
        val pos = ports.positionMs() / 1000.0
        val play = ports.exoPlaying
        val ok = engine.engage(t.file, if (t.isCut) 0L else (t.startMs ?: 0).toLong(), ports.windowLengthMs(id), pos, play)
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
        if (engine.isEngaged && engine.engagedSongId != songId) engine.disengage()
        engine.resetControls()
        lock.trackStarted()
        applyLockOnTrackStart(songId)
        publish()
        replan()
    }

    /** iOS `applyStemLockOnTrackStart`: a locked track starts on the FULL MIX and hands over once the enabled parts are on disk. */
    private suspend fun applyLockOnTrackStart(songId: String?) {
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
            if (!engage()) {
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
    fun sessionEnded() { lock.reset(); lastTrackSongId = null; publish(); replan() }

    fun indicator(): StemLock.Indicator = StemLockSession.indicator(
        lock.current, ports.currentSongId, ports.heldForResume, lock.unavailableSongId,
        engaged = engine.isEngaged && engine.engagedSongId == ports.currentSongId,
        stemsOnAir = engine.stemsOnAir, stemsLoading = engine.stemsLoading,
    )

    /** Host heartbeat (~4 Hz): engine tick + panel state refresh while engaged. */
    fun heartbeat() { engine.tick(); if (engine.isEngaged) publish() }

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
            lock = lock.current, indicator = indicator(), tick = ++version,
        )
    }

    private fun stemsObtainable(id: String): Boolean = engine.stemsAvailableFor(id)
}
