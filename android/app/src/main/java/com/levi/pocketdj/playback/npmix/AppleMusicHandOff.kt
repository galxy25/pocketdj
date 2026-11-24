package com.levi.pocketdj.playback.npmix

import kotlinx.coroutines.CancellationException

/**
 * MIX MODE PHASE 4: the Apple Music -> local TOUCH HAND-OFF (iOS `SetlistPlayer.handOffFromAppleMusic` /
 * `appleMusicHandOffReady` / `appleMusicLocalCopy` / `amHandOffTargetId`; design android-parity2 §4.4).
 *
 * Apple Music audio is DRM'd inside the SDK, so it can never go through the DSP. A row that started on Apple Music
 * but has a complete local copy moves onto that copy the FIRST time the listener touches a Mix control:
 *  1. read the Apple Music position (+ [AppleMusicHandOffRules.LEAD_MS_DEFAULT]);
 *  2. engage the DSP on the local copy at that position, PAUSED (a refusal touches nothing: Apple Music plays on);
 *  3. stop Apple Music;
 *  4. start the DSP (the engage already claimed the session) - only when the listener wants sound.
 *
 * It is NEVER automatic: nothing here is driven by a timer or a progress event; [handOff] is only called from the
 * panel's control touch. The last [AppleMusicHandOffRules.TAIL_GUARD_MS] of a song is never handed off (the song is
 * about to end; the swap would only cost a gap). The swap is one dead-air transition, cause
 * [AppleMusicHandOffRules.CAUSE].
 *
 * Two layers like [GrowingStart]: [AppleMusicHandOffRules] is PURE; [AppleMusicHandOff] drives it through [AppleMusicHandOffEnv].
 * Main-thread only, like the sequencer.
 */
object AppleMusicHandOffRules {
    /** Never hand off within this much of the song's end (iOS tail guard, 3 s). */
    const val TAIL_GUARD_MS = 3_000L

    /** Where in the song the DSP starts relative to the Apple Music position (iOS `amHandoffLeadMsDefault`). */
    const val LEAD_MS_DEFAULT = 0L

    /** The dead-air meter cause / backend label of the swap. */
    const val CAUSE = "npmix-am-handoff"
    const val BACKEND = "handoff"

    /** Everything the verdict is a pure function of. */
    data class Facts(
        /** Mix Mode is ON and allowed to take over audio right now. */
        val buffering: Boolean,
        /** Apple Music is the backend sounding the row right now. */
        val appleMusicActive: Boolean,
        val dspEngaged: Boolean,
        val mixTabActive: Boolean,
        val deviceMode: Boolean = false,
        /** The row has a COMPLETE local copy the DSP can open. */
        val localCopyComplete: Boolean,
        val interruptionOpen: Boolean = false,
        /** Apple Music is audibly playing (iOS `am.isPlaying`): a MusicKit-owned interruption flag does not hold the hand-off. */
        val appleMusicPlaying: Boolean = false,
        /** The listener paused on purpose (iOS pausedByListener): also exempts the interruption flag. */
        val pauseIntentional: Boolean = false,
        val startPending: Boolean = false,
        /** A hand-off of this row already failed this play. */
        val refused: Boolean = false,
        /** The row's length; null = unknown (the tail guard cannot apply). */
        val lengthMs: Long? = null,
        /** The Apple Music position; null = it could not be read. */
        val positionMs: Long? = null,
    )

    sealed interface Verdict {
        data object Go : Verdict
        data class Refuse(val reason: String) : Verdict
    }

    /** THE DECISION. First failing rule wins (its token is logged). */
    fun verdict(f: Facts): Verdict {
        if (!f.buffering) return Verdict.Refuse("mix-off")
        if (!f.appleMusicActive) return Verdict.Refuse("not-on-apple-music")
        if (f.dspEngaged) return Verdict.Refuse("engaged")
        if (f.mixTabActive) return Verdict.Refuse("mix-tab")
        if (f.refused) return Verdict.Refuse("refused")
        if (!f.localCopyComplete) return Verdict.Refuse("no-local-copy")
        // iOS interruptionHolds: a real interruption holds the swap, but not while Apple Music sounds or the pause is the listener's.
        if (f.interruptionOpen && !f.appleMusicPlaying && !f.pauseIntentional) return Verdict.Refuse("interruption")
        if (f.startPending) return Verdict.Refuse("start-pending")
        if (inTail(f.positionMs, f.lengthMs)) return Verdict.Refuse("tail-guard")
        return Verdict.Go
    }

    /** The playhead is inside the last [TAIL_GUARD_MS] of a song of known length. */
    fun inTail(positionMs: Long?, lengthMs: Long?): Boolean {
        if (positionMs == null || lengthMs == null || lengthMs <= 0) return false
        return lengthMs - positionMs < TAIL_GUARD_MS
    }

    /** The song-relative position the DSP starts at: the Apple Music position plus the lead, kept inside the song. */
    fun targetMs(positionMs: Long, lengthMs: Long?, leadMs: Long = LEAD_MS_DEFAULT): Long {
        val t = (positionMs + leadMs).coerceAtLeast(0L)
        return if (lengthMs != null && lengthMs > 0) t.coerceAtMost(lengthMs - 1) else t
    }
}

/** Everything [AppleMusicHandOff] needs from the app; production wiring is in [NpMixWiring]. */
interface AppleMusicHandOffEnv {
    /** The coordinator's `buffering`: cheap, checked before anything else. */
    val buffering: Boolean
    /** The sequencer's play generation (the fence for every async step). */
    val generation: Long
    /** The playing row's uid (null = nothing playing). */
    fun currentRowUid(): String?
    fun currentRowId(): String?

    /** The inputs of the verdict for the playing row, WITHOUT the position (null = no Apple Music row playing). */
    suspend fun facts(): AppleMusicHandOffRules.Facts?
    /** The Apple Music engine's song-relative position, ms (null = unreadable). */
    suspend fun appleMusicPositionMs(): Long?

    /** Open the DSP on the row's local copy at [atSeconds], PAUSED (claims the session). False = refused, nothing touched. */
    suspend fun engagePaused(atSeconds: Double): Boolean
    /** Stop the Apple Music engine; the controller is the DSP's (the sequencer's own player) afterwards. */
    suspend fun stopAppleMusic()
    /** Start the engaged DSP. */
    fun resume()
    /** Release the DSP (a superseded hand-off). */
    fun disengage()
    /** The panel re-publishes. */
    fun readyChanged() {}

    fun meterBegan(cause: String)
    fun meterTrackStarting(backend: String)
    fun meterFirstAudio(backend: String)
    /** The hand-off's open dead-air transition ends without sound (a failed Apple Music stop). */
    fun meterAbandoned(reason: String) {}
    fun log(line: String)
}

/** The touch hand-off ledger and cached availability for one session. */
class AppleMusicHandOff(
    private val env: AppleMusicHandOffEnv,
    private val leadMs: Long = AppleMusicHandOffRules.LEAD_MS_DEFAULT,
) {
    @Volatile private var readyCached = false
    private var refusedUid: String? = null
    private var meterOpen = false
    private var running = false

    /** How many hand-offs completed (test seam + diagnostics). */
    var handOffCount = 0
        private set

    /**
     * Cheap "would a touch hand off now?" for the panel's availability: a CACHED verdict (the exact check re-runs at the
     * touch). Refreshed by [refresh] on row changes and when a local copy lands.
     */
    fun ready(): Boolean = readyCached && env.buffering

    /** Recompute the cached verdict (never hands anything off). */
    suspend fun refresh() {
        val now = try {
            env.buffering && env.facts()?.let { AppleMusicHandOffRules.verdict(it.copy(refused = refusedUid == env.currentRowUid())) } == AppleMusicHandOffRules.Verdict.Go
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
        if (now != readyCached) {
            readyCached = now
            if (now) env.log("am-handoff ready row=${env.currentRowId()} - a local copy exists")
            env.readyChanged()
        }
    }

    /**
     * The FIRST control touch on a row sounding on Apple Music with a complete local copy. [play] false stays paused
     * (a hand-off never STARTS audio). True = the DSP holds the row now. Any refusal leaves Apple Music untouched.
     */
    suspend fun handOff(play: Boolean): Boolean {
        if (running) return false
        running = true
        try {
            val uid = env.currentRowUid() ?: return false
            val id = env.currentRowId()
            val gen = env.generation
            val pos = env.appleMusicPositionMs()
            val facts = env.facts()?.copy(refused = refusedUid == uid, positionMs = pos)
            if (facts == null) return false
            if (pos == null) {
                // Never guess 0: the swap would restart the song. Apple Music plays on.
                env.log("am-handoff row=$id refused reason=no-position")
                return false
            }
            // iOS keys on `wasPlaying = am.isPlaying`: the DSP only sounds if Apple Music was sounding.
            val sound = play && facts.appleMusicPlaying
            val v = AppleMusicHandOffRules.verdict(facts)
            if (v is AppleMusicHandOffRules.Verdict.Refuse) {
                env.log("am-handoff row=$id refused reason=${v.reason}")
                return false
            }
            val at = AppleMusicHandOffRules.targetMs(pos, facts.lengthMs, leadMs)
            if (!env.engagePaused(at / 1000.0)) {
                refusedUid = uid
                readyCached = false
                env.readyChanged()
                env.log("am-handoff row=$id refused reason=dsp-refused at=${at}ms (Apple Music plays on)")
                return false
            }
            if (env.generation != gen || env.currentRowUid() != uid) {
                // The row moved on while the DSP opened: the new row owns the audio.
                env.disengage()
                env.log("am-handoff row=$id superseded")
                return false
            }
            // ONE dead-air transition for the whole swap: opened before Apple Music goes quiet, closed at the DSP's first sound.
            if (sound) {
                env.meterBegan(AppleMusicHandOffRules.CAUSE)
                env.meterTrackStarting(AppleMusicHandOffRules.BACKEND)
                meterOpen = true
            }
            try {
                env.stopAppleMusic()
            } catch (e: CancellationException) {
                rollback(uid, id)
                throw e
            } catch (e: Exception) {
                rollback(uid, id)
                env.log("am-handoff row=$id refused reason=stop-failed (${e.message}); Apple Music plays on")
                return false
            }
            handOffCount++
            readyCached = false
            if (sound) env.resume()
            env.log("am-handoff row=$id apple-music -> DSP local copy at=${at}ms paused=${if (sound) 0 else 1}")
            env.readyChanged()
            return true
        } finally {
            running = false
        }
    }

    /** The stop failed after the DSP engaged paused: release it so Apple Music stays the only owner. */
    private fun rollback(uid: String, id: String?) {
        env.disengage()
        refusedUid = uid
        if (meterOpen) env.meterAbandoned("am-handoff-failed")
        meterOpen = false
        readyCached = false
        env.readyChanged()
    }

    /** The DSP's first sound: closes the hand-off's dead-air transition (once). */
    fun onDspAudioStarted() {
        if (!meterOpen) return
        meterOpen = false
        env.meterFirstAudio(AppleMusicHandOffRules.BACKEND)
    }

    /** The playing row changed: the cached verdict and any refusal belong to the old row. */
    fun rowChanged(currentUid: String?) {
        readyCached = false
        if (refusedUid != null && refusedUid != currentUid) refusedUid = null
        if (meterOpen && currentUid == null) meterOpen = false
    }

    fun sessionEnded() {
        readyCached = false
        refusedUid = null
        meterOpen = false
    }
}
