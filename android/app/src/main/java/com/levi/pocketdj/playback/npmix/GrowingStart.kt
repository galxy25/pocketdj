package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.mix.stream.GrowingFileSchedule
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.StartAttempt
import com.levi.pocketdj.playback.sequencer.StartInterceptor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * MIX MODE PHASE 3b: the NP DSP plays the GROWING file (np-mix-mode §5 phase 3; iOS `SetlistPlayer.startOnGrowingFile`
 * / `growingStartEligible` / `engageGrowingFromStream` / `growingBufferingChanged` / `growingFallBack`).
 *
 * With Mix Mode buffering, a ripped cloud row that is not local STARTS in the NP DSP on its [com.levi.pocketdj.mix.stream
 * .MixStreamLoader] buffer stream: no presigned ExoPlayer download of the same bytes, and every Mix control is live from
 * the first second. The DSP never reads past the written frontier: a start / underrun / seek without runway HOLDS (the card
 * reads BUFFERING, the playhead frozen) and resumes with runway. Backstops:
 *  - a MID-SONG hold longer than [GrowingRules.HOLD_FALLBACK_MS] leaves the DSP: the row goes back on its plain stream at
 *    the same position, never truncated (a start hold gets [GrowingRules.START_HOLD_FALLBACK_MS], the start watchdog's
 *    own escalation + 2 s, because the sequencer's Exo-based watchdog stands down while the DSP owns audio);
 *  - a stream that dies before any audio falls back the same way.
 * A row already streaming from its presigned URL (Mix Mode turned on mid-song) moves onto the growing file on the FIRST
 * CONTROL TOUCH ([engageFromStream]) once the buffer covers the playhead.
 *
 * This file is two layers: [GrowingRules] / [HoldWatch] are PURE (the eligibility matrix, the touch decision, the hold
 * clock); [GrowingStart] is the StartInterceptor + ledger that drives them through the [Env] / [Dsp] seams, so the whole
 * thing is JVM-testable. Main-thread only, like the sequencer.
 */

/** A snapshot of the loader's buffer stream for one audio id (the loader's own object is mutable and thread-shared). */
data class StreamInfo(
    val audioId: String,
    /** Where the bytes are being written. */
    val file: File,
    /** The adopted burn file once the stream completed and moved (null = still [file]). */
    val finalFile: File? = null,
    val bytesReceived: Long = 0,
    val expectedBytes: Long? = null,
    val isComplete: Boolean = false,
    val failed: Boolean = false,
    /** Response headers arrived: [isCut] / [startMs] / [expectedBytes] are final. */
    val resolved: Boolean = true,
    /** The per-song analog cut (plays from 0:00; no window). */
    val isCut: Boolean = false,
    /** Analog album-side stream: the song's offset into the side. */
    val startMs: Long? = null,
)

object GrowingRules {
    /** Interceptor priority (album glide 100, DJ incoming 90, growing start 50: SequencerHooks). */
    const val PRIORITY = 50

    /** A restore-resume / start this deep that the buffer does not cover yet plays plain (never trade an instant start for a hold). */
    const val DEEP_RESUME_MS = 15_000L

    /** A mid-song hold this long falls back to the plain stream (Levi 2026-11-02: 5 s; the plain stream range-seeks at once). */
    const val HOLD_FALLBACK_MS = 5_000L

    /** A hold before the first audio: the start watchdog's escalation + 2 s (iOS `startStallEscalateSeconds + 2`). */
    const val START_HOLD_FALLBACK_MS = 22_000L

    /** The dead-air meter label of a start on the growing file (its own backend). */
    const val BACKEND = com.levi.pocketdj.playback.health.DeadAirMeter.BACKEND_GROWING

    /** Dead-air causes. */
    const val CAUSE_FALLBACK = "npmix-fallback"
    const val CAUSE_HANDOFF = "npmix-growing-handoff"
    const val HANDOFF_BACKEND = "handoff"

    /** Everything the eligibility matrix is a pure function of. */
    data class RowFacts(
        /** Mix Mode is ON and allowed to download right now (not held, not suspended, not device mode). */
        val buffering: Boolean = true,
        val mixTabActive: Boolean = false,
        val deviceMode: Boolean = false,
        /** The NP DSP can engage on this device. */
        val dspAvailable: Boolean = true,
        /** The row already has a local file (burned / buffered): it plays that, no stream needed. */
        val local: Boolean = false,
        /** Studio / profile-source rows never stream from the rip server. */
        val studioOrProfile: Boolean = false,
        /** An off-catalog Apple Music row (`amrec_<storeId>`): Apple Music only. */
        val catalogOnly: Boolean = false,
        /** The row has a rip-manifest entry and the loader can stream it. */
        val ripped: Boolean = true,
        /** The row starts on Apple Music first (phase 4 owns it; Android: the AM-sourced distinction). */
        val appleMusicFirst: Boolean = false,
        /** An ANALOG song with no per-song cut streams its whole album SIDE from byte 0. */
        val analogSide: Boolean = false,
        /** The song's offset into that side (0 = the side's top: a growing stream is as fast as the plain one). */
        val analogStartMs: Long = 0,
        /** The network policy lets Mix Mode download here (cellular "Off" = no). */
        val networkAllows: Boolean = true,
        /** This row's growing file failed / stalled this play: it plays the plain way now. */
        val refused: Boolean = false,
    )

    sealed interface Verdict {
        data object Growing : Verdict
        /** Plain start; [reason] is the log token. */
        data class Plain(val reason: String) : Verdict
    }

    /** THE ELIGIBILITY MATRIX. First failing rule wins (its token is logged). */
    fun eligible(f: RowFacts): Verdict {
        if (!f.buffering) return Verdict.Plain("mix-off")
        if (f.mixTabActive) return Verdict.Plain("mix-tab")
        if (f.deviceMode) return Verdict.Plain("device-mode")
        if (!f.dspAvailable) return Verdict.Plain("no-dsp")
        if (f.refused) return Verdict.Plain("refused")
        if (f.local) return Verdict.Plain("local")
        if (f.studioOrProfile) return Verdict.Plain("studio-or-profile")
        if (f.catalogOnly) return Verdict.Plain("catalog-only")
        if (!f.ripped) return Verdict.Plain("not-ripped")
        if (f.appleMusicFirst) return Verdict.Plain("apple-music-first")
        // A song minutes into a side would hold until the download got there; the plain stream range-seeks straight to it.
        if (f.analogSide && f.analogStartMs > 0) return Verdict.Plain("analog-side")
        if (!f.networkAllows) return Verdict.Plain("network-policy")
        return Verdict.Growing
    }

    /** Seconds of the file the stream's bytes cover (null = unknown). */
    fun covered(s: StreamInfo, fileDurationSeconds: Double?): Double? =
        GrowingFileSchedule.coveredFileSeconds(s.bytesReceived, s.expectedBytes, s.isComplete, fileDurationSeconds)

    /**
     * A start [resumeAtMs] into the song: up to [DEEP_RESUME_MS] always starts on the growing file (it holds a moment at
     * worst); deeper only when the buffer already covers it plus the start runway - else plain (the stream range-seeks).
     */
    fun resumeOk(resumeAtMs: Long?, coveredSeconds: Double?): Boolean {
        val ms = resumeAtMs ?: return true
        if (ms <= DEEP_RESUME_MS) return true
        return (coveredSeconds ?: 0.0) >= ms / 1000.0 + GrowingFileSchedule.START_RUNWAY
    }

    /**
     * Does the buffer cover the playhead of a row streaming from its presigned URL? [songRelSeconds] is the song-relative
     * playhead. A per-song CUT starts at the song's 0:00; a digital file / an analog side is offset by the side start.
     * A cheap byte estimate (no file open): the engine re-checks exactly at the touch.
     */
    fun touchCovers(s: StreamInfo?, songRelSeconds: Double, fileDurationSeconds: Double?): Boolean {
        if (s == null || s.failed || !s.resolved) return false
        val covered = covered(s, fileDurationSeconds) ?: return false
        val need = if (s.isCut) songRelSeconds else (s.startMs ?: 0L) / 1000.0 + songRelSeconds
        return covered >= need + GrowingFileSchedule.RESUME_RUNWAY
    }

    /** What the touch hand-off is decided from. */
    data class TouchFacts(
        val buffering: Boolean,
        val refused: Boolean,
        /** The row is streaming from its presigned URL right now (a file is the existing hand-off's business). */
        val onPlainStream: Boolean,
        val dspEngaged: Boolean,
        val interruptionOpen: Boolean,
        val startPending: Boolean,
        val stream: StreamInfo?,
        val songRelSeconds: Double,
        val fileDurationSeconds: Double?,
    )

    sealed interface TouchVerdict {
        data object Go : TouchVerdict
        data class Refuse(val reason: String) : TouchVerdict
    }

    /** The first-touch hand-off: never across an interruption, never mid-start, only when the buffer covers the playhead. */
    fun touch(f: TouchFacts): TouchVerdict {
        if (!f.buffering) return TouchVerdict.Refuse("mix-off")
        if (f.dspEngaged) return TouchVerdict.Refuse("engaged")
        if (f.refused) return TouchVerdict.Refuse("refused")
        if (!f.onPlainStream) return TouchVerdict.Refuse("not-on-stream")
        if (f.interruptionOpen) return TouchVerdict.Refuse("interruption")
        if (f.startPending) return TouchVerdict.Refuse("start-pending")
        val s = f.stream
        if (s == null || s.failed) return TouchVerdict.Refuse("no-stream")
        if (!touchCovers(s, f.songRelSeconds, f.fileDurationSeconds)) return TouchVerdict.Refuse("not-covered")
        return TouchVerdict.Go
    }
}

/**
 * The hold clock (iOS `growingBufferingChanged`'s sleep). Fed one sample per poll; answers the fallback reason when a
 * hold that the listener still wants sound for outlasted its budget. An open interruption never falls back (the hold is
 * the call's, not the stream's) and restarts the budget.
 */
class HoldWatch(
    private val holdBudgetMs: Long = GrowingRules.HOLD_FALLBACK_MS,
    private val startBudgetMs: Long = GrowingRules.START_HOLD_FALLBACK_MS,
) {
    private var since: Long? = null

    /** Null = keep waiting; non-null = fall back, with the log reason (`hold>5s`). */
    fun sample(nowMs: Long, holding: Boolean, awaitingFirstAudio: Boolean, interruptionOpen: Boolean): String? {
        if (!holding) { since = null; return null }
        val s = since ?: nowMs.also { since = it }
        if (interruptionOpen) { since = nowMs; return null }
        val budget = if (awaitingFirstAudio) startBudgetMs else holdBudgetMs
        return if (nowMs - s >= budget) "hold>${budget / 1000}s" else null
    }

    fun reset() { since = null }
}

/** The NP DSP as the growing start sees it (production: [com.levi.pocketdj.mix.nowplaying.NowPlayingDspEngine]). */
interface GrowingDsp {
    val engagedSongId: String?
    val isBuffering: Boolean
    val awaitingFirstAudio: Boolean
    val currentTimeSec: Double
}

/** Everything [GrowingStart] needs from the app; production wiring is in [NpMixWiring]. */
interface GrowingEnv {
    val dsp: GrowingDsp

    /** The coordinator's `buffering`: cheap, checked before anything touches the loader. */
    val buffering: Boolean

    /** The sequencer's play generation (the fence for every async step). */
    val generation: Long
    fun currentRow(): QueueItem?
    val interruptionOpen: Boolean
    val startPending: Boolean

    suspend fun rowFacts(item: QueueItem): GrowingRules.RowFacts
    /** Open - or join - the buffer lane's stream (null = it cannot stream now). */
    fun openStream(item: QueueItem): StreamInfo?
    /** The stream already running for [audioId] (never opens one). */
    fun stream(audioId: String): StreamInfo?
    /** Duration of the FILE the stream carries (the row's length; a presigned side's duration), for the byte-fraction estimate. */
    fun fileDurationSeconds(item: QueueItem, s: StreamInfo): Double?

    /** The touch decision's inputs for the playing row (null = nothing playing from a plain stream). */
    suspend fun touchFacts(item: QueueItem): GrowingRules.TouchFacts?
    /** [GrowingStart.touchReady] flipped: the panel re-publishes. */
    fun touchReadyChanged() {}

    /** The outgoing source (Apple Music / a stale Exo item) goes quiet before the DSP sounds. */
    suspend fun quietOutgoing()

    /** Open the DSP on [s] at [atSeconds], PAUSED, bind the row, stage the card metadata. False = refused (nothing touched). */
    fun engage(item: QueueItem, s: StreamInfo, atSeconds: Double): Boolean
    /** Play the engaged DSP (plays with runway, else HOLDS for bytes). */
    fun resume()
    fun disengage(): Double?
    /** Hand the engine the loader's progress for the engaged stream. */
    fun feed(s: StreamInfo)

    /** Announce the claimed start to the sequencer (History play, dead-air backend, `onTrackStarted`). False = superseded. */
    fun completeClaimedStart(gen: Long): Boolean
    fun noteFirstAudio(songId: String, source: String)

    /** The row goes back through the sequencer's start funnel at [atMs] (its growing path refused). */
    fun restartPlain(uid: String, atMs: Long): Boolean
    /** The presigned stream a touch hand-off left is resumed at [atMs] (ExoPlayer still holds it). False = could not. */
    suspend fun resumeLeftStream(songId: String, atMs: Long): Boolean

    fun meterBegan(cause: String)
    fun meterTrackStarting(backend: String)
    fun meterFirstAudio(backend: String)

    /** The row's local copy now exists: its stems come next. */
    fun replan()
    fun log(line: String)
}

/**
 * The growing-file start: a [StartInterceptor] (priority [GrowingRules.PRIORITY]) plus the ledger of the row the DSP is
 * playing from its growing file (iOS `growingUid` / `growingLeftStream` / `growingRefusedUid`).
 */
class GrowingStart(
    private val env: GrowingEnv,
    private val scope: CoroutineScope,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val pollMs: Long = 250,
    private val hold: HoldWatch = HoldWatch(),
) : StartInterceptor {
    override val priority: Int get() = GrowingRules.PRIORITY

    private data class Left(val uid: String, val atMs: Long)

    /** The row (uid) the DSP is playing from its growing file; null = not on one. */
    var growingUid: String? = null
        private set
    private var growingGen = -1L
    private var leftStream: Left? = null
    private var handOffMeterOpen = false
    private var handOffFirstAudio = false
    private var completeLogged = false

    /** A row whose growing file failed / stalled this play: it plays the plain way now. */
    var refusedUid: String? = null
        private set

    private var monitor: Job? = null

    var startCount = 0
        private set
    var handOffCount = 0
        private set
    var fallbackCount = 0
        private set

    /** The DSP owns the audio for the row on air right now (the supervisor never acts then). */
    val ownsAudio: Boolean get() = growingUid != null

    // ---- the start interceptor -----------------------------------------------------------------------------

    override suspend fun tryClaim(attempt: StartAttempt): Boolean {
        // Cheap and first: Mix Mode off must never even construct the loader.
        if (!env.buffering) return false
        val item = attempt.item
        // A start of a DIFFERENT row clears an old refusal (iOS: `if growingRefusedUid != it.uid { growingRefusedUid = nil }`).
        if (refusedUid != item.uid) refusedUid = null
        val facts = env.rowFacts(item).copy(refused = refusedUid == item.uid)
        when (val v = GrowingRules.eligible(facts)) {
            is GrowingRules.Verdict.Plain -> { env.log("growing skip row=${item.id} reason=${v.reason}"); return false }
            GrowingRules.Verdict.Growing -> Unit
        }
        val s = env.openStream(item)?.takeIf { !it.failed } ?: run {
            env.log("growing skip row=${item.id} reason=no-stream")
            return false
        }
        if (!GrowingRules.resumeOk(attempt.resumeAtMs, GrowingRules.covered(s, env.fileDurationSeconds(item, s)))) {
            // (The stream keeps downloading: the first touch moves the row onto it later.)
            env.log("growing skip row=${item.id} reason=deep-resume at=${attempt.resumeAtMs}ms not buffered that far")
            return false
        }
        env.quietOutgoing()
        if (env.generation != attempt.gen) return true // superseded while the outgoing source went quiet: the new start owns it
        val at = (attempt.resumeAtMs ?: 0L) / 1000.0
        if (!env.engage(item, s, at)) {
            env.log("growing skip row=${item.id} reason=dsp-refused")
            return false
        }
        beginGrowing(item.uid, attempt.gen)
        if (!env.completeClaimedStart(attempt.gen)) {
            // Superseded between the engage and the announcement: the newer start owns the audio now.
            env.disengage()
            endGrowing()
            return true
        }
        env.resume()
        startCount++
        env.log(
            "growing start row=${item.id} at=${(at * 1000).toLong()}ms bytes=${s.bytesReceived}/${s.expectedBytes ?: "?"} " +
                if (env.dsp.isBuffering) "holding" else "playing",
        )
        return true
    }

    // ---- touch hand-off ------------------------------------------------------------------------------------

    /**
     * The FIRST control touch on a row streaming from its presigned URL whose buffer covers the playhead: move it onto the
     * growing file at the same song position. Never across an interruption, never mid-start; [play] false (or paused)
     * stays paused - a hand-off never STARTS audio. The DSP refuses, touching nothing, when it cannot play there.
     */
    suspend fun engageFromStream(play: Boolean): Boolean {
        val item = env.currentRow() ?: return false
        val f = env.touchFacts(item) ?: return false
        val v = GrowingRules.touch(f.copy(refused = refusedUid == item.uid))
        if (v is GrowingRules.TouchVerdict.Refuse) {
            env.log("handoff row=${item.id} growing refused reason=${v.reason}")
            return false
        }
        val s = f.stream ?: return false
        val gen = env.generation
        val atSeconds = f.songRelSeconds
        if (!env.engage(item, s, atSeconds)) {
            env.log("handoff row=${item.id} growing refused reason=dsp-refused at=${(atSeconds * 1000).toLong()}ms")
            return false
        }
        if (env.generation != gen || env.currentRow()?.uid != item.uid) { env.disengage(); return false }
        beginGrowing(item.uid, gen)
        leftStream = Left(item.uid, (atSeconds * 1000).toLong())
        handOffCount++
        touchReadyCached = false
        if (play) {
            env.meterBegan(GrowingRules.CAUSE_HANDOFF)
            env.meterTrackStarting(GrowingRules.HANDOFF_BACKEND)
            handOffMeterOpen = true
            handOffFirstAudio = true
            env.resume()
        }
        env.log("handoff row=${item.id} stream -> DSP growing file at=${(atSeconds * 1000).toLong()}ms paused=${if (play) 0 else 1}")
        return true
    }

    @Volatile private var touchReadyCached = false
    private var refreshing = false

    /**
     * Cheap "would a touch hand off now?" for the panel's availability (a cached verdict: the exact check re-runs at the
     * touch). Refreshed by [scheduleTouchRefresh] on buffer progress and row changes.
     */
    fun touchReady(): Boolean = touchReadyCached && env.buffering

    fun scheduleTouchRefresh() {
        if (refreshing) return
        refreshing = true
        scope.launch {
            try {
                val ready = env.buffering && env.currentRow()?.let { item ->
                    env.touchFacts(item)?.let { GrowingRules.touch(it.copy(refused = refusedUid == item.uid)) == GrowingRules.TouchVerdict.Go }
                } == true
                if (ready != touchReadyCached) {
                    touchReadyCached = ready
                    if (ready) env.log("touch-ready row=${env.currentRow()?.id} - the buffer covers the playhead")
                    env.touchReadyChanged()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            } finally {
                refreshing = false
            }
        }
    }

    // ---- the DSP's events ----------------------------------------------------------------------------------

    /** The loader progressed for [audioId]: feed the engine when it is the growing row's stream. */
    fun onStreamProgress(audioId: String) {
        val uid = growingUid
        val row = env.currentRow()
        if (uid == null || row == null || row.uid != uid || row.resolveId != audioId) {
            // Not the growing row's stream: it may be the playing row's stream the touch hand-off could use.
            if (row != null && row.resolveId == audioId) scheduleTouchRefresh()
            return
        }
        val s = env.stream(audioId) ?: return
        env.feed(s)
        if (s.isComplete && !completeLogged) {
            completeLogged = true
            env.log("growing row=${row.id} complete")
            env.replan() // the current row is local now: its stems come next
        }
    }

    /** The engine's first sound for the engaged row. */
    fun onDspAudioStarted() {
        val uid = growingUid ?: return
        val row = env.currentRow()?.takeIf { it.uid == uid } ?: return
        if (handOffMeterOpen) { handOffMeterOpen = false; env.meterFirstAudio(GrowingRules.HANDOFF_BACKEND) }
        env.noteFirstAudio(row.id, if (handOffFirstAudio) "dsp-stream-handoff" else "dsp-stream")
        handOffFirstAudio = false
    }

    /** The engine's stream died before any audio: the row plays its plain way. */
    fun onStreamFailed(atSeconds: Double) {
        val uid = growingUid ?: return
        fallBack(uid, growingGen, atSeconds, "stream failed", engineAlreadyReleased = true)
    }

    /** One poll of the hold clock (the monitor calls it; tests drive it directly). */
    fun tick() {
        val uid = growingUid ?: return
        if (env.generation != growingGen || env.currentRow()?.uid != uid || env.dsp.engagedSongId == null) { endGrowing(); return }
        val reason = hold.sample(nowMs(), env.dsp.isBuffering, env.dsp.awaitingFirstAudio, env.interruptionOpen) ?: return
        fallBack(uid, growingGen, env.dsp.currentTimeSec, reason, engineAlreadyReleased = false)
    }

    // ---- lifecycle -----------------------------------------------------------------------------------------

    /** The current row changed: nothing of the old row may fall back or retry. */
    fun rowChanged(currentUid: String?) {
        touchReadyCached = false
        if (currentUid != null) scheduleTouchRefresh()
        if (growingUid != null && growingUid != currentUid) endGrowing()
        if (leftStream != null && leftStream?.uid != currentUid) leftStream = null
        if (refusedUid != null && refusedUid != currentUid) refusedUid = null
    }

    fun sessionEnded() {
        endGrowing()
        refusedUid = null
    }

    private fun beginGrowing(uid: String, gen: Long) {
        growingUid = uid
        growingGen = gen
        leftStream = null
        handOffMeterOpen = false
        handOffFirstAudio = false
        completeLogged = false
        hold.reset()
        monitor?.cancel()
        monitor = scope.launch {
            try {
                while (isActive && growingUid == uid) {
                    delay(pollMs)
                    tick()
                }
            } catch (e: CancellationException) {
                throw e
            }
        }
    }

    private fun endGrowing() {
        monitor?.cancel(); monitor = null
        growingUid = null
        leftStream = null
        handOffMeterOpen = false
        handOffFirstAudio = false
        hold.reset()
    }

    /**
     * The growing file cannot carry the row (a hold ran too long, or its stream died before any audio): leave the DSP and
     * put the row on its PLAIN stream at the same song position - the presigned stream a touch hand-off left, else a fresh
     * resolve (refused for the growing path this play). Fenced on the row and the play generation; never claims an advance.
     */
    private fun fallBack(uid: String, gen: Long, atSeconds: Double, reason: String, engineAlreadyReleased: Boolean) {
        val row = env.currentRow()
        if (growingUid != uid || gen != growingGen || env.generation != gen || row?.uid != uid) {
            env.log("growing fallback ignored (stale) reason=$reason")
            return
        }
        val atMs = Math.round(atSeconds * 1000).coerceAtLeast(0L)
        val left = leftStream?.takeIf { it.uid == uid }
        refusedUid = uid
        fallbackCount++
        endGrowing()
        if (!engineAlreadyReleased) env.disengage()
        env.log("growing fallback reason=$reason row=${row.id} at=${atMs}ms -> plain stream${if (left != null) " (the one it left)" else ""}")
        env.meterBegan(GrowingRules.CAUSE_FALLBACK)
        if (left != null) {
            scope.launch {
                val ok = try { env.resumeLeftStream(row.id, atMs) } catch (e: CancellationException) { throw e } catch (_: Exception) { false }
                if (!ok && env.currentRow()?.uid == uid) env.restartPlain(uid, atMs)
            }
        } else {
            env.restartPlain(uid, atMs)
        }
    }
}
