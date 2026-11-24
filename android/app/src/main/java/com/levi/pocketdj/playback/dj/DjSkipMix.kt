package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.nowplaying.DjPhase
import com.levi.pocketdj.mix.nowplaying.DjTransitionSpec

/** What a DJ skip decided (iOS `djSkipMix`'s Bool, plus whether the press was already reported to the skip tracker). */
enum class DjSkipResult {
    /** The skip mix took it (or ignored a repeated press): nothing else to do. */
    HANDLED,

    /** Not mixable: the caller's immediate advance (it reports the advance-away itself). */
    FALLBACK,

    /** Not mixable, but the press was already reported to the skip tracker: the immediate advance must not report it again. */
    FALLBACK_AWAY_NOTED,
}

/** What the sequencer calls into (set by `DjModeWiring`; null = DJ Mode never bound = every skip is today's immediate advance). */
interface DjSkipHooks {
    fun skip(fast: Boolean): DjSkipResult

    /** Every start / advance / previous / run end supersedes a pending skip mix. */
    fun clearPending()
}

/**
 * DJ MODE's SKIP MIX (iOS `SetlistPlayer.djSkipMix` / `djAdvanceAtFadeStart`'s skip half; docs/architecture/android-parity2.md
 * 6.4): ⏭ with DJ Mode on mixes into the next row like the Mix tab's Skip, over Settings > Mixing "Skip fade" (15 s default), or
 * the 5 s sweep when `fast` (lock screen / headset / Auto / widget). Anything DJ cannot mix is the caller's immediate advance.
 *
 *  - **idle** (no transition): a transition starts NOW - no pre-roll, a skip-fade crossfade cut to the runway (>= 1 s with
 *    0.5 s to spare), glide / FX as at a song's end;
 *  - **pre-roll**: drop the pre-roll and fade now; PAUSED in the pre-roll the transition is abandoned and the immediate advance
 *    skips; a skip already pending for the run's incoming is the same skip (ignored);
 *  - **fade**: ignored - EXCEPT a second press (any, in-app tap or remote) inside a skip's OWN crossfade, which finishes it
 *    over the 5 s sweep (the android "second tap upgrades" rule; no double-tap detector delays a tap);
 *  - **post-roll**: the glide ends (the listener wins) and the skip mixes out of the new song.
 *
 * The pending skip is keyed on the run's incoming song; it is [consumeAtFadeStart]ed by the advance and cleared by every
 * start / advance / previous / run end (and by a cut). Pure state over [Port]: main thread.
 */
class DjSkipMix(private val p: Port) {
    interface Port {
        /** DJ Mode is on AND allowed to act, the session runs un-held, the current row is on the DSP. */
        val canMix: Boolean
        val currentId: String?
        val phase: DjPhase
        val isPlaying: Boolean
        val incomingSongId: String?
        val secondsLeft: Double
        val outRate: Double?
        val skipFadeSeconds: Double

        /** The conductor's transition out of the playing row with a skip fade (the shared decline list in skip mode); null = declined. */
        fun makeTransition(skipFade: Double): DjTransitionSpec?

        /** Start [spec] now; null = it began, else the engine's decline reason. */
        fun beginTransition(spec: DjTransitionSpec): String?
        fun skipDuringPreRoll(fadeSeconds: Double)
        fun abandonForSkip()
        fun endPostRollForSkip()

        /** Shorten the running crossfade to [fadeSeconds]; false when it is not longer than that. */
        fun shortenFade(fadeSeconds: Double): Boolean

        /** The skip tracker's PRESS: the listen ends here (the advance itself lands at the fade start, which is synchronous). */
        fun noteAdvanceAway()
        fun declined(from: String, reason: String)
        fun log(line: String)
    }

    /** What the fade start learns about a pending skip. */
    data class Taken(val skipPending: Boolean, val isSkip: Boolean) {
        companion object { val None = Taken(skipPending = false, isSkip = false) }
    }

    /** The row id this skip mixes INTO (the run's incoming). Null = no skip pending. */
    var pending: String? = null; private set

    /** A skip's crossfade is running (set at the fade start, cleared when the transition ends): a fast press shortens it. */
    var mixing: Boolean = false; private set

    /** True while a skip mix is in flight (pending its fade start, or crossfading). */
    val inFlight: Boolean get() = pending != null || mixing

    fun skip(fast: Boolean): DjSkipResult {
        if (!p.canMix) return DjSkipResult.FALLBACK
        val cur = p.currentId ?: return DjSkipResult.FALLBACK
        val fade = if (fast) DjMode.FAST_SKIP_FADE_SECONDS else p.skipFadeSeconds
        when (p.phase) {
            DjPhase.FADING -> {
                if (mixing && p.shortenFade(DjMode.FAST_SKIP_FADE_SECONDS)) {
                    p.log("skip upgraded to fast - fade now ${fmt(DjMode.FAST_SKIP_FADE_SECONDS)}s song=$cur")
                    return DjSkipResult.HANDLED
                }
                p.log("skip ignored - fade in flight song=$cur")
                return DjSkipResult.HANDLED
            }
            DjPhase.PREROLL -> {
                // A skip's own mix is still landing: a second press is the same skip.
                if (pending != null) {
                    p.log("skip ignored - a skip mix is starting song=$cur")
                    return DjSkipResult.HANDLED
                }
                val incoming = p.incomingSongId
                // Paused: the fade could not start until play - drop the mix, the immediate advance skips now.
                if (!p.isPlaying || incoming == null) {
                    p.abandonForSkip()
                    return DjSkipResult.FALLBACK
                }
                p.noteAdvanceAway()
                // Keyed on the RUN's incoming (the queue may have changed under the pre-roll: the fade start then refuses
                // and the skip falls back to the immediate advance).
                pending = incoming
                // The fade start pins the outgoing at its glide tempo: plan on the runway it really has.
                val runway = p.secondsLeft / maxOf(1.0, p.outRate ?: 1.0)
                p.skipDuringPreRoll(minOf(fade, maxOf(1.0, runway - 0.5)))
                return DjSkipResult.HANDLED
            }
            DjPhase.POSTROLL -> p.endPostRollForSkip()
            DjPhase.IDLE -> Unit
        }
        val spec = p.makeTransition(fade) ?: return DjSkipResult.FALLBACK
        // The listen ends at the PRESS: the Android fade start advances synchronously inside beginTransition, so the tracker
        // must read the outgoing's position before it.
        p.noteAdvanceAway()
        pending = spec.incoming.songId
        val reason = p.beginTransition(spec)
        if (reason != null) {
            pending = null
            p.declined(cur, "skip: $reason")
            return DjSkipResult.FALLBACK_AWAY_NOTED
        }
        p.log("skip song=$cur -> ${spec.incoming.songId} mix fade=${fmt(spec.plan.fadeSeconds)}s${if (fast) " (fast)" else ""}")
        return DjSkipResult.HANDLED
    }

    /**
     * FADE START: the pending skip (if any) is taken. [Taken.isSkip] = this advance is the listener's skip (a USER transport);
     * [Taken.skipPending] with `!isSkip` = a skip was pending for ANOTHER row (the fade start refuses and the skip still advances).
     */
    fun consumeAtFadeStart(songId: String): Taken {
        val pend = pending
        pending = null
        if (pend == null) return Taken.None
        val isSkip = pend == songId
        mixing = isSkip
        return Taken(skipPending = true, isSkip = isSkip)
    }

    /** A start / advance / previous / run end / cut: no skip mix is pending any more. */
    fun clearPending() { pending = null }

    /** A transition ended (complete, cut or listener): no skip crossfade runs any more. */
    fun transitionEnded() { pending = null; mixing = false }

    private fun fmt(v: Double) = String.format(java.util.Locale.US, "%.1f", v)
}
