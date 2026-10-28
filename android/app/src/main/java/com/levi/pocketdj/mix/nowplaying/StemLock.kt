package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.durable.SessionStemLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * STEM LOCK - "keep my stems across tracks" for a Now Playing playback SESSION (iOS `StemLock.swift`).
 *
 * Off (default): the Now Playing mix controls are ephemeral and reset on every track change. On: the
 * stem state of the playing track (stems on/off, muted parts, per-part gains) CARRIES to every
 * following track. The carry is captured from USER stem actions only, so a track that cannot do stems
 * (no stems / not a local file / a failed stream) never overwrites it: it plays the full mix under an
 * "unavailable" indicator and the lock stays for the tracks after it. A locked track ALWAYS starts on
 * the full mix (zero dead air) and hands over to the carried set once the ENABLED parts are on disk.
 *
 * SESSION scope: persisted in the durable session JSON (`stemLock` object, iOS shape), restored with
 * it, CLEARED by a new session and by stop / end of set. Skips, repeats, queue edits and restore keep it.
 */
object StemLock {
    /** Download priority of the stem parts (Levi: vocals, drums, other, bass). Muted parts go last. */
    val partPriority: List<String> = listOf("vocals", "drums", "other", "bass")

    /** One `stemlock` line on the Now Playing trace lane (song ids only, never titles). */
    fun log(message: String) { NPLog.lane(NPLog.NP, "stemlock $message") }

    /** What the Now Playing surfaces show for the lock on the CURRENT track. */
    enum class Indicator {
        /** The lock is off. */
        OFF,
        /** Locked, carrying "stems off" (or nothing playing yet): plain full mix. */
        IDLE,
        /** Locked with stems: the full mix plays while the carried stems buffer. */
        LOADING,
        /** Locked with stems, and the carried stems are on air. */
        ACTIVE,
        /** Locked with stems, but THIS track cannot do stems: full mix, the lock carries on. */
        UNAVAILABLE,
    }
}

/** The persisted Stem Lock state of a session (iOS `StemLockState`; the carried stem set rides with it). */
data class StemLockState(
    val enabled: Boolean = false,
    /** Stems on for the carried set. */
    val stemsOn: Boolean = false,
    /** Muted parts (sorted - stable on disk). */
    val muted: List<String> = emptyList(),
    /** Per-part gains moved off 1.0. */
    val volumes: Map<String, Double> = emptyMap(),
) {
    /** The un-muted parts, in download priority - what a handover waits for. */
    val enabledParts: List<String> get() = StemLock.partPriority.filter { it !in muted }

    /** The muted parts, in download priority - fetched last. */
    val disabledParts: List<String> get() = StemLock.partPriority.filter { it in muted }

    /** Lock on AND carrying stems: the only state that changes playback or downloads. */
    val wantsStems: Boolean get() = enabled && stemsOn

    /** One-line summary for the diag lane (`stems=on parts=vocals,drums muted=bass,other`). */
    val logSummary: String
        get() {
            if (!stemsOn) return "stems=off"
            var s = "stems=on parts=${enabledParts.joinToString(",")}"
            if (muted.isNotEmpty()) s += " muted=${muted.joinToString(",")}"
            if (volumes.isNotEmpty()) {
                s += " gains=" + volumes.keys.sorted().joinToString(",") { "$it:${"%.2f".format(java.util.Locale.US, volumes[it] ?: 1.0)}" }
            }
            return s
        }

    /** The durable-session shape; null when the lock is off (iOS omits the key then). */
    fun toSession(): SessionStemLock? =
        if (!enabled) null else SessionStemLock(enabled = true, stemsOn = stemsOn, muted = muted.sorted(), volumes = volumes)

    companion object {
        fun fromSession(s: SessionStemLock?): StemLockState =
            if (s == null || !s.enabled) StemLockState()
            else StemLockState(
                enabled = true, stemsOn = s.stemsOn,
                muted = s.muted.filter { it in StemLock.partPriority }.distinct().sorted(),
                volumes = s.volumes.filterKeys { it in StemLock.partPriority }.mapValues { it.value.coerceIn(0.0, 1.0) },
            )
    }
}

/** The DSP's stem controls as the lock captures them (engaged track only). */
data class StemSnapshot(
    val stemsOn: Boolean = false,
    val muted: Set<String> = emptySet(),
    val volumes: Map<String, Double> = emptyMap(),
)

/**
 * The session-scoped lock: carry state, per-track "unavailable" marker and the pure indicator rule
 * (iOS `SetlistPlayer.stemLock*`). Main thread. [onChanged] fires after every state change so the
 * owner can persist the session (`SessionWriter`'s `stemLock` supplier reads [state]).
 */
class StemLockSession(private val onChanged: () -> Unit = {}) {
    private val _state = MutableStateFlow(StemLockState())
    val state: StateFlow<StemLockState> = _state.asStateFlow()
    val current: StemLockState get() = _state.value

    /** The song the lock could not apply stems to (cleared on every track start). */
    var unavailableSongId: String? = null; private set

    /** True while the lock itself drives the DSP (its writes must not re-capture as USER changes). */
    var applying = false

    /** Turn the lock on (capturing the CURRENT track's stem state, or stems off when [snapshot] is null) or off. */
    fun setLock(on: Boolean, snapshot: StemSnapshot?) {
        _state.value = if (on) capture(StemLockState(enabled = true), snapshot) else StemLockState()
        unavailableSongId = null
        onChanged()
    }

    /** A USER stem action on the engaged track. Returns true when the carry changed. */
    fun onUserStemChange(snapshot: StemSnapshot, currentSongId: String?, stemsOn: Boolean): Boolean {
        val st = current
        if (!st.enabled || applying) return false
        val next = capture(st, snapshot)
        if (next == st) return false
        _state.value = next
        if (next.stemsOn && currentSongId != null && unavailableSongId == currentSongId && stemsOn) unavailableSongId = null
        onChanged()
        return true
    }

    /** A new session / stop / end of set. */
    fun reset() {
        if (current.enabled) StemLock.log("lock cleared (session ended / new session)")
        _state.value = StemLockState()
        unavailableSongId = null
    }

    /** Restore the persisted lock with the session (no persist round-trip). */
    fun restore(persisted: SessionStemLock?) {
        _state.value = StemLockState.fromSession(persisted)
        unavailableSongId = null
    }

    fun markUnavailable(songId: String) { unavailableSongId = songId }

    /** A track is starting: the unavailable marker is per track. */
    fun trackStarted() { unavailableSongId = null }

    private fun capture(base: StemLockState, snap: StemSnapshot?): StemLockState =
        if (snap == null) base.copy(stemsOn = false, muted = emptyList(), volumes = emptyMap())
        else base.copy(
            stemsOn = snap.stemsOn,
            muted = snap.muted.filter { it in StemLock.partPriority }.sorted(),
            volumes = snap.volumes.filterKeys { it in StemLock.partPriority },
        )

    companion object {
        /**
         * The indicator rule (iOS `stemLockIndicator`). [engaged]: the DSP owns the track;
         * [stemsOnAir]: the stems are audible; [stemsLoading]: a handover to the stems is pending.
         */
        fun indicator(
            state: StemLockState, currentSongId: String?, heldForResume: Boolean, unavailableSongId: String?,
            engaged: Boolean, stemsOnAir: Boolean, stemsLoading: Boolean,
        ): StemLock.Indicator {
            if (!state.enabled) return StemLock.Indicator.OFF
            if (!state.stemsOn || currentSongId == null || heldForResume) return StemLock.Indicator.IDLE
            if (unavailableSongId == currentSongId) return StemLock.Indicator.UNAVAILABLE
            if (!engaged) return StemLock.Indicator.LOADING   // the track is still starting
            if (stemsOnAir) return StemLock.Indicator.ACTIVE
            return if (stemsLoading) StemLock.Indicator.LOADING else StemLock.Indicator.UNAVAILABLE
        }
    }
}
