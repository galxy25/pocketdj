package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.health.PlaybackRunway
import com.levi.pocketdj.playback.health.RunwayLock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * SWAP-ON-LAND (np-mix-mode §1.4 / §4.2; iOS `SetlistPlayer.handOffCurrentToLocal` / `revertFailedHandOff` /
 * `retryOwedHandOff`).
 *
 * The playing row is on the presigned ExoPlayer stream of a rip and the identical bytes just became a local
 * file. The engine is reloaded onto the local file AT THE SAME SONG POSITION; ExoPlayer keeps playWhenReady
 * the whole time (a reload + seek is one atomic replace-at-position, so the top of the file never sounds).
 *
 * Invariants (all pure in [decide] / [HandOffLedger], so JVM-testable):
 *  - A hand-off NEVER starts audio: refused when the listener paused, the engine no longer intends to play, or
 *    focus is lost / transient (an interruption is open).
 *  - A refusal that a later event can cure ("owed": paused, interruption, start window open, Mix tab live) is
 *    retried on first audio / user PLAY / Mix tab idle.
 *  - A failed local file reverts ONCE to the stream at the same position ([HandOffLedger.onFailed]); a second
 *    failure advances as ever.
 *  - A [PlaybackRunway] is held across the reload until first audio (cap [RUNWAY_CAP_MS]).
 *  - Own-stamp match = URL + song (two songs on one analog side share one file).
 */
object SwapOnLand {
    /** The hand-off never cuts into the last moments of a song (it would race the natural end). */
    const val MIN_REMAINING_MS = 3_000L

    /** How long a hand-off runway is held at most (first audio normally ends it in < 1 s). */
    const val RUNWAY_CAP_MS = 10_000L

    /** The local file the playing row would move onto (the SAME bytes the stream carries). */
    data class Target(
        val url: String,
        /** Song window inside a shared analog side file; null = whole file / a per-song cut. */
        val startMs: Long?,
        val endMs: Long?,
        /** The storage id the file belongs to; must equal the id the stream resolved under. */
        val resolveId: String,
    )

    /** The row the engine is playing right now, as the engine reports it. */
    data class Playing(
        val songId: String,
        val url: String,
        val clipStartMs: Long?,
        val clipEndMs: Long?,
        /** Engine position. Media3 reports positions RELATIVE to a clip, so on Android this is song-relative. */
        val positionMs: Long,
        val durationMs: Long?,
        val isFile: Boolean,
        val live: Boolean,
        val hasLoadedItem: Boolean,
        val trackEnded: Boolean,
        /** True on Media3 (clipped item): [positionMs] is already song-relative. False = file-absolute (iOS shape). */
        val positionIsClipRelative: Boolean = true,
    )

    /** Everything [decide] is a pure function of. */
    data class Facts(
        val mixEnabled: Boolean,
        val running: Boolean,
        val held: Boolean,
        val dspEngaged: Boolean,
        /** A Mix-tab session owns the audio (`DspHostPorts.mixSessionActive`). */
        val mixTabActive: Boolean,
        val pausedByCascade: Boolean,
        val appleMusicActive: Boolean,
        /** The sequencer start window is open (no first audio of the row heard yet). */
        val startPending: Boolean,
        val rowUid: String,
        val rowId: String,
        val rowResolveId: String,
        val rowLengthMs: Long?,
        val generation: Long,
        val playing: Playing?,
        val target: Target?,
        /** An audio-focus loss / transient loss / call is open. */
        val interruptionOpen: Boolean,
        val listenerPaused: Boolean,
        /** The listener wants sound (iOS `listenerIntentPlaying`). */
        val intentPlaying: Boolean,
        /** The engine is currently producing / buffering toward audio (playWhenReady). */
        val enginePlayWhenReady: Boolean = true,
    )

    sealed interface Decision {
        /** Do nothing. [owe] = a later event can cure it: remember the row and retry. */
        data class Refuse(val reason: String, val owe: Boolean = false) : Decision

        data class Go(
            val atMs: Long,
            val localSeekMs: Long,
            val target: Target,
            val stream: StreamRef,
            val lengthMs: Long?,
        ) : Decision
    }

    /** What the engine was playing before the swap (the revert target). */
    data class StreamRef(val url: String, val clipStartMs: Long?, val clipEndMs: Long?)

    /** Song-relative position of the playing stream: Media3 clip-relative positions pass through. */
    fun songRelMs(p: Playing): Long {
        val raw = if (p.positionIsClipRelative) p.positionMs else p.positionMs - (p.clipStartMs ?: 0L)
        return raw.coerceAtLeast(0L)
    }

    /**
     * The seek the engine must do on [target] for song position [songRelMs]: a clipped item (Media3) seeks
     * song-relative; a file-absolute engine re-bases onto the target's own `startMs` (a side -> cut move maps
     * through the song's own 0:00, a side -> side move through the new window start).
     */
    fun localSeekMs(songRelMs: Long, target: Target, positionIsClipRelative: Boolean = true): Long =
        if (positionIsClipRelative) songRelMs else songRelMs + (target.startMs ?: 0L)

    /** THE DECISION. The order mirrors iOS: session-wide guards, what is playing, then the paused/near-end checks. */
    fun decide(f: Facts): Decision {
        if (!f.mixEnabled) return Decision.Refuse("mix-off")
        if (!f.running) return Decision.Refuse("not-running")
        if (f.held) return Decision.Refuse("held")
        if (f.dspEngaged) return Decision.Refuse("engaged")
        if (f.mixTabActive) return Decision.Refuse("mix-tab", owe = true)
        if (f.pausedByCascade) return Decision.Refuse("cascade")
        if (f.appleMusicActive) return Decision.Refuse("apple-music")
        val p = f.playing ?: return Decision.Refuse("no-engine-item")
        if (p.live) return Decision.Refuse("live")
        if (p.songId != f.rowId && p.songId != f.rowResolveId) return Decision.Refuse("not-current")
        if (p.isFile) return Decision.Refuse("already-local")
        if (!p.hasLoadedItem) return Decision.Refuse("not-loaded")
        if (p.trackEnded) return Decision.Refuse("track-ended")
        // An interruption (call, Assistant, another app took focus): a reload would start our audio over it.
        if (f.interruptionOpen) return Decision.Refuse("focus", owe = true)
        // The start window is still open (no first audio yet): the stream's clock means nothing yet.
        if (f.startPending) return Decision.Refuse("start-pending", owe = true)
        val t = f.target ?: return Decision.Refuse("no-local-file")
        // SAME BYTES only: the file of the id the stream resolved under, never another edition's.
        if (t.resolveId != f.rowResolveId) return Decision.Refuse("other-edition")
        // PAUSED = anything but "the listener wants sound": a listener pause, a route loss, a cascade halt.
        if (f.listenerPaused || !f.intentPlaying || !f.enginePlayWhenReady) return Decision.Refuse("paused", owe = true)
        val at = songRelMs(p)
        val len = f.rowLengthMs ?: if (p.positionIsClipRelative) p.durationMs
        else (p.clipEndMs ?: p.durationMs)?.let { end -> end - (p.clipStartMs ?: 0L) }
        if (len != null && at > len - MIN_REMAINING_MS) return Decision.Refuse("near-end")
        return Decision.Go(
            atMs = at,
            localSeekMs = localSeekMs(at, t, p.positionIsClipRelative),
            target = t,
            stream = StreamRef(p.url, p.clipStartMs, p.clipEndMs),
            lengthMs = len,
        )
    }

    // ---- ledger: owed / fallback / own stamp -----------------------------------------------------------

    /** The last hand-off of the CURRENT row: the local file it moved onto and the stream it left. */
    data class Fallback(val uid: String, val songId: String, val localUrl: String, val stream: StreamRef, val atMs: Long)

    /** The URL + song our own in-place re-stamp put on the engine (two songs of one side share a file: BOTH must match). */
    data class OwnStamp(val url: String, val songId: String)

    sealed interface FailVerdict {
        /** Put the row back on [stream] at [atMs] (ONCE). */
        data class Revert(val stream: StreamRef, val atMs: Long) : FailVerdict

        /** Not ours (or already reverted once): the sequencer handles the failure as ever (advance). */
        data object Advance : FailVerdict
    }

    class HandOffLedger {
        var fallback: Fallback? = null
            private set
        var ownStamp: OwnStamp? = null
            private set

        /** The row (uid) a refused / deferred hand-off is owed to. A track change voids it. */
        var owedUid: String? = null
            private set
        var handOffCount: Int = 0
            private set
        var revertCount: Int = 0
            private set

        fun owe(uid: String) { owedUid = uid }
        fun clearOwed() { owedUid = null }

        /** Consume the owed uid iff it is still the current row's. */
        fun takeOwed(currentUid: String?): String? {
            val u = owedUid ?: return null
            owedUid = null
            return u.takeIf { it == currentUid }
        }

        fun recordHandOff(uid: String, songId: String, local: Target, stream: StreamRef, atMs: Long) {
            fallback = Fallback(uid, songId, local.url, stream, atMs)
            ownStamp = OwnStamp(local.url, songId)
            handOffCount++
        }

        /** The engine's current item is OUR stamp: URL AND song both equal (a shared analog file alone is not enough). */
        fun isOwnStamp(url: String?, songId: String?): Boolean =
            ownStamp?.let { it.url == url && it.songId == songId } == true

        /** The row changed / the session ended: nothing of the old row may revert or retry. */
        fun rowChanged(currentUid: String?) {
            if (fallback?.uid != currentUid) fallback = null
            if (owedUid != currentUid) owedUid = null
            if (fallback == null) ownStamp = null
        }

        fun clear() { fallback = null; ownStamp = null; owedUid = null }

        /**
         * The engine failed on [failingUrl] for [songId] while [currentUid] is the playing row. A failing hand-off file
         * reverts once; every other failure (and the second one) is the sequencer's to advance.
         * [liveSongRelMs] = the local clock; when the file died before it ever loaded (clock 0) the hand-off position wins.
         */
        fun onFailed(currentUid: String?, songId: String, failingUrl: String?, liveSongRelMs: Long): FailVerdict {
            val fb = fallback ?: return FailVerdict.Advance
            if (fb.uid != currentUid || !isOwnStamp(failingUrl, songId) || fb.localUrl != failingUrl) return FailVerdict.Advance
            fallback = null
            ownStamp = OwnStamp(fb.stream.url, songId)
            revertCount++
            return FailVerdict.Revert(fb.stream, if (liveSongRelMs > 0) liveSongRelMs else fb.atMs)
        }
    }

    // ---- executor --------------------------------------------------------------------------------------

    /** What the executor reads and drives (production: PlaybackController + sequencer + DSP host). */
    interface Env {
        /** The facts right now (target resolved off-main); null = nothing to hand off (no session). */
        suspend fun facts(): Facts?

        /** Under a Stem Lock carrying stems the DSP takes the row directly (no ExoPlayer reload). */
        val lockCarriesStems: Boolean

        /** Engage the DSP on the local file at [atMs] (playing); false = refused (fall back to the reload). */
        suspend fun engageDsp(songId: String, atMs: Long): Boolean

        /** The row is local now: its stems come next. */
        fun replan()

        val runwayLock: RunwayLock?
        fun log(line: String)
    }

    /** The engine side of the swap. */
    interface Engine {
        /** Replace the current item with [url] and seek to [atMs] without ever pausing. False = the engine refused. */
        suspend fun reload(songId: String, url: String, clipStartMs: Long?, clipEndMs: Long?, atMs: Long): Boolean

        /** Suspends until the first audio after the last [reload], or [timeoutMs]; true = sound heard. */
        suspend fun awaitAudio(timeoutMs: Long): Boolean
    }

    /**
     * The hand-off driver. Main-thread API; [attempt] suspends only across the facts read and the engine calls,
     * and re-checks the row identity + play generation around each so a skip / stop racing it wins.
     */
    class Runner(
        private val env: Env,
        private val engine: Engine,
        private val scope: CoroutineScope,
        val ledger: HandOffLedger = HandOffLedger(),
        private val runwayCapMs: Long = RUNWAY_CAP_MS,
        private val newRunway: (String, RunwayLock?, Long) -> PlaybackRunway = { n, l, cap -> PlaybackRunway(n, l, capMs = cap) },
    ) {
        private var runway: PlaybackRunway? = null
        private var runwayJob: Job? = null
        private var attempting = false

        /** TEST PROBE: a hand-off runway is held. */
        val runwayHeld: Boolean get() = runway != null

        private fun log(line: String) = env.log(line)

        /** Try to hand the playing row over to its local file. True = it did. */
        suspend fun attempt(reason: String): Boolean {
            if (attempting) return false
            attempting = true
            try {
                val f = env.facts() ?: return false
                val d = decide(f)
                if (d is Decision.Refuse) {
                    log("hand-off refused reason=${d.reason} row=${f.rowId} trigger=$reason")
                    if (d.owe) ledger.owe(f.rowUid) else if (f.mixEnabled && f.running) ledger.clearOwed()
                    return false
                }
                d as Decision.Go
                ledger.clearOwed()
                // The facts read suspended (the target is resolved off-main): the row, the play generation and the
                // listener's intent must still be the ones the decision was made on.
                val again = env.facts()
                if (again == null || again.rowUid != f.rowUid || again.generation != f.generation) {
                    log("hand-off refused reason=superseded row=${f.rowId} trigger=$reason")
                    return false
                }
                val d2 = decide(again)
                if (d2 is Decision.Refuse) {
                    log("hand-off refused reason=${d2.reason} row=${f.rowId} trigger=$reason")
                    if (d2.owe) ledger.owe(again.rowUid)
                    return false
                }
                d2 as Decision.Go
                // Under a Stem Lock carrying stems the DSP engages directly on the local file.
                if (env.lockCarriesStems && env.engageDsp(f.rowId, d2.atMs)) {
                    ledger.recordHandOff(f.rowUid, f.rowId, d2.target, d2.stream, d2.atMs)
                    log("hand-off row=${f.rowId} pos=${d2.atMs} dsp=1 reason=$reason")
                    env.replan()
                    return true
                }
                endRunway("superseded")
                beginRunway(f.rowId)
                val ok = try {
                    engine.reload(f.rowId, d2.target.url, d2.target.startMs, d2.target.endMs, d2.localSeekMs)
                } catch (e: CancellationException) {
                    endRunway("cancelled"); throw e
                } catch (_: Exception) { false }
                if (!ok) {
                    endRunway("refused")
                    log("hand-off refused reason=engine row=${f.rowId} trigger=$reason")
                    return false
                }
                ledger.recordHandOff(f.rowUid, f.rowId, d2.target, d2.stream, d2.atMs)
                log("hand-off row=${f.rowId} pos=${d2.atMs} start=${d2.target.startMs ?: 0} reason=$reason")
                env.replan()
                return true
            } finally {
                attempting = false
            }
        }

        /** A hand-off that was refused for a curable reason: retry now if it is still owed to the playing row. */
        suspend fun retryOwed(trigger: String, currentUid: String?) {
            if (ledger.takeOwed(currentUid) == null) return
            attempt(trigger)
        }

        /** The failing item: revert ONCE onto the stream. True = handled (the caller must NOT advance). */
        fun onFailed(currentUid: String?, songId: String, failingUrl: String?, liveSongRelMs: Long): Boolean {
            val v = ledger.onFailed(currentUid, songId, failingUrl, liveSongRelMs)
            if (v !is FailVerdict.Revert) return false
            log("hand-off row=$songId local file FAILED -> back on the stream at=${v.atMs}ms")
            endRunway("superseded")
            beginRunway(songId)
            scope.launch {
                val ok = try {
                    engine.reload(songId, v.stream.url, v.stream.clipStartMs, v.stream.clipEndMs, v.atMs)
                } catch (e: CancellationException) { throw e } catch (_: Exception) { false }
                if (!ok) endRunway("revert-refused")
            }
            return true
        }

        /** The current row changed or the session ended. */
        fun rowChanged(currentUid: String?) {
            ledger.rowChanged(currentUid)
            endRunway("row-changed")
        }

        fun sessionEnded() {
            ledger.clear()
            endRunway("session-ended")
        }

        private fun beginRunway(songId: String) {
            runway = newRunway("pocketdj-npmix-handoff-$songId", env.runwayLock, runwayCapMs)
            val mine = runway
            runwayJob = scope.launch {
                val heard = try { engine.awaitAudio(runwayCapMs) } catch (e: CancellationException) { throw e } catch (_: Exception) { false }
                if (runway === mine) endRunway(if (heard) "firstAudio" else "cap")
            }
        }

        private fun endRunway(reason: String) {
            runwayJob?.cancel(); runwayJob = null
            runway?.end(reason)
            runway = null
        }
    }

    /** `[npmix]` lane (song ids only, never titles). */
    fun laneLog(message: String) = NPLog.lane("npmix", message)
}
