package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * DJ Mode volume leveling (P2-DJ-11; port of iOS `SetlistPlayer.djLevelDb / applyDJLeveling / djAnalyze` and
 * `NowPlayingDSP.setLevel`). Every local song plays at -14 LUFS (clamped -12..+6 dB) with NEVER a step change:
 *
 *  - Only a STORED measurement re-applies gain ([onMeasured]); a cached / failed / cancelled outcome never does (re-applying
 *    would re-enter [levelDb] and could kick the analysis again - the old busy loop).
 *  - A result landing mid-play ramps over [LoudnessLeveling.RAMP_SECONDS] in [LevelRamper.STEP_SECONDS] steps; a track start
 *    lands at once (before audio); the incoming's gain lands over [LevelRamper.FADE_START_SECONDS] at fade start.
 *  - Unknown loudness = the quick hint clamped to +-4 dB, else 0 dB. A shared album side is measured per song SLICE.
 *  - Active only while DJ is on AND the Volume leveling toggle is on; DJ off / session end cancels running analyses and
 *    levels to 0 dB ([levelToZero]).
 *
 * The listener's volume sits on top (the engine adds this to the boost trim) and the master limiter catches positive-gain peaks.
 */
class DjLeveling(
    private val host: Host,
    private val loudness: LoudnessCache,
    private val analysis: AudioAnalysisCache,
    private val scope: CoroutineScope,
) {
    /** What the readout says about the playing song's leveling (never a "0 dB" that was never measured). */
    enum class Status(val label: String) {
        INACTIVE("inactive"), OFF("off"), MEASURING("measuring"), UNAVAILABLE("unavailable"), MEASURED("measured"), ESTIMATED("estimated"),
    }

    interface Host {
        /** DJ Mode is on AND allowed to act. */
        val djActive: Boolean
        /** Settings > Mixing "Volume leveling". */
        val volumeLeveling: Boolean
        val running: Boolean
        /** The DSP owns the playing row (a trim exists to move). */
        val dspEngaged: Boolean
        /** The playing row is a still-arriving file (not measurable until complete). */
        val dspStreaming: Boolean
        /** The leveling gain the live deck is heading to. */
        val levelTargetDb: Double
        fun currentItem(): com.levi.pocketdj.playback.sequencer.QueueItem?
        /** The row's complete local file + slice (cached: cheap), null = not local. */
        fun localSource(item: com.levi.pocketdj.playback.sequencer.QueueItem): DjConductor.LocalSource?
        fun setLevel(db: Double, ramp: Boolean)
        fun log(line: String)
    }

    private val _status = MutableStateFlow(Status.INACTIVE)
    /** The playing song's leveling status (the P2-DJ-12 readout binds this). */
    val status: StateFlow<Status> = _status
    private var lastLogged: String? = null

    /** The loudness key of [src] for [songId]: a song on a shared album side keys (and is measured as) its own slice. */
    fun keyFor(songId: String, src: DjConductor.LocalSource): LoudnessCache.Key? =
        LoudnessCache.key(songId, src.file, src.startMs.toInt(), src.lengthMs.takeIf { it > 0 }?.toInt())

    /**
     * The leveling gain for a local file: the stored measurement's, else the quick hint's (+-4 dB), else 0. The analysis is kicked
     * ONCE - never while one runs for the key, never again after it failed.
     */
    fun levelDb(songId: String, src: DjConductor.LocalSource): Double {
        val key = keyFor(songId, src) ?: return 0.0
        loudness.gainDb(key)?.let { return it }
        if (!loudness.isSettledOrRunning(key)) analyze(key, src)
        return AudioAnalysis.levelGain(null, analysis.quick(key)).value ?: 0.0
    }

    /** The readout status for a key (after [levelDb] kicked any analysis). */
    fun statusFor(key: LoudnessCache.Key?): Status {
        if (key == null) return Status.UNAVAILABLE
        if (loudness.gainDb(key) != null) return Status.MEASURED
        if (loudness.contains(key) || loudness.hasFailed(key)) return Status.UNAVAILABLE
        if (LoudnessLeveling.gainDb(analysis.quick(key)?.lufs) != null) return Status.ESTIMATED
        return Status.MEASURING
    }

    /** Apply the CURRENT row's leveling gain (DJ + Volume on), else 0 dB. [ramp]: glide there (an analysis landing mid-play). */
    fun applyCurrent(ramp: Boolean) {
        if (!host.running || !host.dspEngaged) return
        val cur = host.currentItem() ?: return
        val src = if (host.djActive && host.volumeLeveling) host.localSource(cur) else null
        if (src == null) {
            // The readout says WHY there is no trim.
            _status.value = if (host.djActive && !host.volumeLeveling) Status.OFF else Status.INACTIVE
            if (abs(host.levelTargetDb) > EPS) {
                host.setLevel(0.0, ramp)
                note("leveling off gain=0")
            }
            return
        }
        if (host.dspStreaming) {
            // Still arriving: its head's quick hint (about, +-4 dB) stands in until the file completes.
            val hint = (analysis.results(cur.id).second ?: analysis.results(cur.resolveId).second)
            val g = AudioAnalysis.levelGain(null, hint).value
            if (g != null) {
                _status.value = Status.ESTIMATED
                if (abs(g - host.levelTargetDb) > EPS) host.setLevel(g, ramp)
            } else _status.value = Status.MEASURING
            return
        }
        val db = levelDb(cur.id, src)
        val key = keyFor(cur.id, src)
        _status.value = statusFor(key)
        if (abs(db - host.levelTargetDb) <= EPS) return
        host.setLevel(db, ramp)
        val lufs = key?.let { loudness.lufs(it) ?: analysis.quick(it)?.lufs }
        note(
            String.format(
                Locale.US, "leveling song=%s lufs=%s gain=%+.1f dB%s", cur.id, lufs?.let { String.format(Locale.US, "%.1f", it) } ?: "-", db,
                if (_status.value == Status.ESTIMATED) " (estimated)" else if (ramp) " (ramped)" else "",
            ),
        )
    }

    /**
     * Measure [key] once (background). When THIS analysis stored a result and it belongs to the PLAYING row, its gain ramps in.
     */
    private fun analyze(key: LoudnessCache.Key, src: DjConductor.LocalSource) {
        val path = src.file.path
        scope.launch {
            val outcome = loudness.analyze(key, path)
            onOutcome(key, outcome)
        }
    }

    /** An analysis outcome for [key]: only a stored (Measured) result re-applies gain; failure only updates the status. */
    internal fun onOutcome(key: LoudnessCache.Key, outcome: LoudnessCache.Outcome) {
        val cur = host.currentItem()
        if (!host.running || cur == null || !cur.matches(key.songId) || !host.dspEngaged) return
        when (outcome) {
            is LoudnessCache.Outcome.Measured -> applyCurrent(ramp = true)
            LoudnessCache.Outcome.Failed -> if (host.djActive) _status.value = Status.UNAVAILABLE
            else -> Unit   // Cached / Cancelled / NotReady: re-applying could re-kick (the old busy loop)
        }
    }

    /** DJ off / session end / suspension: every running measurement stops and the trim returns to 0 dB. */
    fun levelToZero() {
        loudness.cancelAll()
        _status.value = Status.INACTIVE
        host.setLevel(0.0, false)
        note("leveling off gain=0")
    }

    /** Stop running measurements (DJ off) without touching the trim. */
    fun cancelAnalyses() = loudness.cancelAll()

    private fun note(line: String) {
        if (line == lastLogged) return
        lastLogged = line
        host.log(line)
    }

    companion object {
        /** Gain differences under this are not worth a move. */
        const val EPS = 0.01
    }
}

/**
 * One deck's leveling trim, moved without ever stepping (port of `NowPlayingDSP.setLevel`): a ramp is [STEP_SECONDS]-sized
 * linear steps, driven by [scope]'s clock; a non-ramped set lands at once (a track start, before audio).
 */
class LevelRamper(
    private val scope: CoroutineScope,
    initial: Double = 0.0,
    private val apply: (Double) -> Unit,
) {
    @Volatile var applied: Double = initial; private set
    @Volatile var target: Double = initial; private set
    private var job: Job? = null
    val inFlight: Boolean get() = job?.isActive == true

    /** Set the gain (clamped -12..+6 dB). [ramp]: glide there over [seconds] (default 2 s); otherwise land at once. */
    fun set(db: Double, ramp: Boolean, seconds: Double? = null) {
        val t = db.coerceIn(LoudnessLeveling.MIN_GAIN_DB, LoudnessLeveling.MAX_GAIN_DB)
        target = t
        job?.cancel(); job = null
        val total = seconds ?: LoudnessLeveling.RAMP_SECONDS
        if (!ramp || abs(t - applied) <= 0.01 || total <= 0.0) {
            applied = t
            apply(t)
            return
        }
        val values = rampValues(applied, t, total)
        val stepMs = ((total / values.size) * 1000.0).toLong().coerceAtLeast(1)
        job = scope.launch {
            for (v in values) {
                delay(stepMs)
                applied = v
                apply(v)
            }
            job = null
        }
    }

    /** Stop any ramp where it is. */
    fun cancel() { job?.cancel(); job = null; target = applied }

    companion object {
        /** One ramp step (fine enough that an 18 dB correction never zippers). */
        const val STEP_SECONDS = 0.02
        /** The incoming's gain lands over this at the fade start (its fade gain is about 0 meanwhile). */
        const val FADE_START_SECONDS = 0.15

        /** The values a ramp visits, in order, ending exactly on [to]: `max(1, round(total / 20 ms))` linear steps. */
        fun rampValues(from: Double, to: Double, totalSeconds: Double, stepSeconds: Double = STEP_SECONDS): List<Double> {
            val steps = maxOf(1, (totalSeconds / stepSeconds).roundToInt())
            return List(steps) { i -> if (i == steps - 1) to else from + (to - from) * (i + 1) / steps }
        }
    }
}
