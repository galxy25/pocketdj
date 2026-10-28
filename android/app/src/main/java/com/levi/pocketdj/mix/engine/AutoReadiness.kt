package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import java.util.Locale

/** What a streaming deck looks like to the readiness rules (null stream = a plain on-disk deck). */
data class StreamView(val isComplete: Boolean, val frontierSeconds: Double?)

/**
 * Outside facts the Auto-DJ needs that live in other packages (streaming = MIX-10, burns = BurnStore).
 * Defaults describe "everything is on disk, nothing streams".
 */
interface AutoSeams {
    /** The deck's growing-file stream, else null. */
    fun stream(deck: Deck): StreamView? = null
    /** [songId]'s audio is fully on this device: a load of it airs at once. */
    fun songOnDevice(songId: String): Boolean
    /** A load of [songId] failed only because the stream gate is closed RIGHT NOW (defer, never drop). */
    fun transientlyUnloadable(songId: String): Boolean = false
}

/**
 * Production seams over the burn store + stream loader (wired in MixGraph; iOS `songOnDevice` /
 * `transientlyUnloadable`). `stream(deck)` stays null until MIX-10's StreamDecks supplies views.
 */
internal class LoaderAutoSeams(
    private val burned: (String) -> Boolean,
    private val finishedStream: (String) -> Boolean,
    private val ripped: (String) -> Boolean,
    private val canStream: (String) -> Boolean,
) : AutoSeams {
    /** On device = burned file, or a finished, non-failed stream. */
    override fun songOnDevice(songId: String) = burned(songId) || finishedStream(songId)
    /** Ripped, not burned, and the stream gate refuses right now: defer, never drop. */
    override fun transientlyUnloadable(songId: String) =
        ripped(songId) && !burned(songId) && !canStream(songId)
}

internal class EngineAutoSeams(private val engine: MixEngine) : AutoSeams {
    override fun songOnDevice(songId: String): Boolean = engine.songOnDisk(songId)
}

/**
 * Zero dead air at the SONG BOUNDARY (iOS "auto machine readiness"). Field (CarPlay on cellular,
 * 2026-10-12): the machine fired transitions on the wall clock alone, so it crossfaded INTO a standby
 * still Buffering, a Skip landed on a not-yet-downloaded song, and a closed stream gate DROPPED every
 * ripped-but-not-burned song. The rules:
 *  - a transition only begins into a deck that can AIR (strict [ready], lenient [canAir] at the
 *    last moment); a not-ready standby is replaced by a READY upcoming song (promote) and deferred,
 *    never dropped;
 *  - nothing ready at the end of the live song => the live song is EXTENDED (replayed);
 *  - a crossfade whose incoming deck is holding is FROZEN (the outgoing stays on air);
 *  - a Skip during such a frozen fade re-targets past the held song;
 *  - a live deck stalled on an underrun hands over to a ready song after [STALL_SKIP_SECONDS];
 *  - a ripped song the stream gate refuses right now is DEFERRED, not dropped.
 * Every decision logs one `mixadvance` line.
 */
object AutoReadiness {
    /** Seconds of downloaded runway past the playhead that make a streaming deck "ready". */
    const val READY_RUNWAY = 15.0
    /** With this little left of the live song and NOTHING able to air, the live song is replayed. */
    const val EXTEND_AT_SECONDS_LEFT = 0.5
    /** A live deck frozen on an underrun this long hands over to a ready song. */
    const val STALL_SKIP_SECONDS = 8.0

    /**
     * STRICT readiness: the deck holds a track that will play through - an on-disk file, a finished
     * stream, or a stream with [READY_RUNWAY] downloaded past its playhead.
     */
    fun ready(
        loaded: Boolean, hasAudio: Boolean, stream: StreamView?, held: Boolean,
        position: Double, duration: Double,
    ): Boolean {
        if (!loaded) return false
        if (stream == null) return hasAudio
        if (held) return false
        if (stream.isComplete) return true
        val frontier = stream.frontierSeconds ?: return false
        return frontier - position >= minOf(READY_RUNWAY, maxOf(0.0, duration - position) - 0.1)
    }

    /** LENIENT readiness: the deck would make sound right now (not holding for bytes). */
    fun canAir(loaded: Boolean, hasAudio: Boolean, stream: StreamView?, held: Boolean): Boolean {
        if (!loaded) return false
        if (stream == null) return hasAudio
        return !held
    }

    internal fun fmt1(v: Double) = String.format(Locale.US, "%.1f", v)
}

/** The readiness decisions that mutate the machine (promote / extend / abandon), over one [AutoDj]. */
internal class AutoReadinessOps(private val dj: AutoDj) {
    private val e get() = dj.engine

    fun deckReadyToAir(deck: Deck): Boolean = AutoReadiness.ready(
        loaded = e.loaded(deck) != null, hasAudio = e.controller(deck).isOpen,
        stream = dj.seams.stream(deck), held = e.streamHeld(deck),
        position = e.position(deck), duration = e.duration(deck),
    )

    fun deckCanAir(deck: Deck): Boolean = AutoReadiness.canAir(
        loaded = e.loaded(deck) != null, hasAudio = e.controller(deck).isOpen,
        stream = dj.seams.stream(deck), held = e.streamHeld(deck),
    )

    /** Can the standby deck air the next song: strictly ready, after a promote, or leniently? */
    fun standbyCanAir(reason: String): Boolean {
        val standby = dj.liveDeck.other
        return deckReadyToAir(standby) || promoteReadyUpcoming(reason) || deckCanAir(standby)
    }

    /**
     * The standby can't air its song yet: find the first unplayed upcoming song that is fully ON
     * DEVICE, move it into the next slot and load it onto the standby. The not-ready song stays
     * queued right behind it (its download keeps running).
     */
    fun promoteReadyUpcoming(reason: String): Boolean {
        val deck = dj.liveDeck.other
        val p = dj.livePos + 1
        if (p >= dj.queue.size) return false
        val liveId = e.loaded(dj.liveDeck)?.songId
        val waiting = dj.queue[p].loadable.songId
        var j = p + 1
        while (j < dj.queue.size) {
            val sid = dj.queue[j].loadable.songId
            if (sid != liveId && e.recorder?.hasPlayed(sid) != true && dj.seams.songOnDevice(sid)) {
                if (dj.loadAuto(dj.queue[j], deck)) {
                    dj.moveItem(j, p)
                    dj.nextToLoad = maxOf(dj.nextToLoad, p + 1)
                    dj.advLog("promote $sid over not-ready $waiting ($reason)")
                    return true
                }
            }
            j++
        }
        return false
    }

    /** Nothing can air at the end of the live song: replay it (music beats silence). */
    fun extendLive(reason: String) {
        val live = dj.liveDeck
        dj.advLog("extend ${e.loaded(live)?.songId ?: "-"} - $reason")
        e.restart(live)
        if (!e.isPlaying(live)) e.play(live)
        val durMs = dj.deckDurationMs[live] ?: (e.duration(live) * 1000).toInt()
        dj.deckEndsAt[live] = e.nowMs() + (durMs / maxOf(0.05, e.rate(live))).toLong()
        dj.extending = true
    }

    /**
     * Back out of a crossfade whose incoming deck can't air (holding, or ejected by a dead stream):
     * the outgoing takes the fader back and stays live, the incoming is silenced (still loaded - it
     * keeps downloading). The cursor never moved.
     */
    fun abandonTransition(reason: String) {
        val from = dj.fadeFrom
        val to = from.other
        dj.advLog("abandon fade -> ${e.loaded(to)?.songId ?: "-"} - $reason")
        dj.glide.abort()
        dj.glide.clearPhases()
        dj.fadeStartedAt = null
        dj.fadeHeldSince = null
        dj.transitionRepeatOne = false
        dj.transitionWrap = false
        dj.pendingFadeRestore?.let { dj.fadeSeconds = it; dj.pendingFadeRestore = null }
        e.applyCrossfader(if (from == Deck.A) 0.0 else 1.0)
        dj.liveDeck = from
        if (e.loaded(to) != null) e.silence(to)
    }
}
