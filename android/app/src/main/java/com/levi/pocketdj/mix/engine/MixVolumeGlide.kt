package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.playback.dj.LoudnessCache
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** What the deck's leveling readout says (iOS `NowPlayingDSP.LevelingStatus`, the cases Mix uses). */
enum class LevelingStatus { INACTIVE, MEASURING, UNAVAILABLE, MEASURED }

/** One deck's leveling as heard: its status and the trim right now (dB; ramps over [LoudnessLeveling.RAMP_SECONDS]). */
data class LevelSide(val status: LevelingStatus = LevelingStatus.INACTIVE, val trimDb: Double = 0.0) {
    /** The words under Vol: "+2.1 dB" / "−3.4 dB" / "0.0 dB" / "measuring…" / "unavailable" / "—". */
    val words: String get() = VolumeGlideRules.words(this)
}

/** Both decks' [LevelSide]; the Mix deck shows its own under Vol while it is not [LevelingStatus.INACTIVE]. */
data class DeckLeveling(val a: LevelSide = LevelSide(), val b: LevelSide = LevelSide()) {
    operator fun get(deck: Deck): LevelSide = if (deck == Deck.A) a else b
    fun with(deck: Deck, side: LevelSide): DeckLeveling = if (deck == Deck.A) copy(a = side) else copy(b = side)
}

/** The file (and slice of it) a deck's song is playing from. */
data class LevelSource(val file: File, val startMs: Int?, val lengthMs: Int?)

/** Pure Volume Glide decisions (iOS `MixEngine` leveling statics + `DJLevelingReadoutRow.words`). */
object VolumeGlideRules {
    /** Ramp step (iOS 20 ms) and how many steps move the readout (every 3rd, ~16 Hz). */
    const val RAMP_STEP_MS = 20L
    const val READOUT_EVERY = 3
    /** A change this small is applied at once (no ramp worth running). */
    const val RAMP_EPSILON_DB = 0.01

    fun clamp(db: Double): Double =
        if (!db.isFinite()) 0.0 else db.coerceIn(LoudnessLeveling.MIN_GAIN_DB, LoudnessLeveling.MAX_GAIN_DB)

    fun rampSteps(totalSeconds: Double): Int = max(1, (totalSeconds / (RAMP_STEP_MS / 1000.0)).roundToInt())

    /** Linear interpolation of step [i] of [steps] from [from] to [to]. */
    fun stepValue(from: Double, to: Double, i: Int, steps: Int): Double = from + (to - from) * i / steps

    /** Ramp only a SOUNDING deck (playing and the crossfader lets it through) with a real change and a ramp to run. */
    fun shouldRamp(audible: Boolean, from: Double, to: Double, rampSeconds: Double): Boolean =
        audible && abs(to - from) > RAMP_EPSILON_DB && rampSeconds > 0

    fun words(side: LevelSide): String = when (side.status) {
        LevelingStatus.MEASURED -> {
            val v = side.trimDb
            if (abs(v) < 0.05) "0.0 dB" else String.format(Locale.US, "%s%.1f dB", if (v > 0) "+" else "−", abs(v))
        }
        LevelingStatus.MEASURING -> "measuring…"
        LevelingStatus.UNAVAILABLE -> "unavailable"
        LevelingStatus.INACTIVE -> "—"
    }
}

/** What Volume Glide needs from the engine. Main-thread only. */
interface VolumeGlideHost {
    /** Hand mixes are never leveled: only while the Auto-DJ is mixing. */
    val autoMixing: Boolean
    fun loadedSongId(deck: Deck): String?
    /** The deck's file when a measurement can run; null while still streaming (or when there is no file). */
    fun levelSource(deck: Deck): LevelSource?
    /** A growing-file deck waiting for its full file. */
    fun isStreaming(deck: Deck): Boolean
    /** Playing and the crossfader lets it through. */
    fun isAudible(deck: Deck): Boolean
    /** Put [db] on the deck's TRIM (the fader is untouched). */
    fun writeTrim(deck: Deck, db: Double)
    fun log(line: String)
}

/**
 * Mix tab VOLUME GLIDE (iOS `MixEngine` "Volume Glide"; design §7.2): opt-in loudness leveling of every Auto-DJ
 * deck song to -14 LUFS on its TRIM (the Vol fader never moves), measured OFF-main by the shared [LoudnessCache].
 *
 *  - Auto-DJ only: with glide off, or no Auto-DJ running, every deck is back to 0 dB and shows nothing.
 *  - Known gain => set AT ONCE on a silent deck, ramped over [rampSeconds] on a sounding one.
 *  - Unknown => "measuring…" at 0 dB until the analysis lands; a streaming deck waits for its finished file.
 *  - Nothing measurable / failed => 0 dB, "unavailable".
 *  - A song swap, eject, glide off or the Auto-DJ ending clears the trim.
 *
 * Main-thread only; [driver] runs the 20 ms ramp steps, [scope] receives the analysis result on main.
 */
class MixVolumeGlide(
    private val host: VolumeGlideHost,
    private val cache: () -> LoudnessCache?,
    private val driver: TickDriver,
    private val scope: CoroutineScope,
    private val rampSeconds: Double = LoudnessLeveling.RAMP_SECONDS,
) {
    var enabled = false; private set

    private val _leveling = MutableStateFlow(DeckLeveling())
    val leveling: StateFlow<DeckLeveling> = _leveling.asStateFlow()

    private val level = DoubleArray(2)
    private val ramps = arrayOfNulls<AutoCloseable>(2)
    /** The key whose analysis this deck is already awaiting (a repeat refresh must not queue another). */
    private val awaiting = arrayOfNulls<LoudnessCache.Key>(2)
    /** A cancelled shared analysis is re-kicked once per load, never in a loop. */
    private val rekicked = BooleanArray(2)
    /** The last gain logged per deck: the MEASURED line fires only when the target changes. */
    private val loggedGain = DoubleArray(2) { Double.NaN }

    private fun logGain(deck: Deck, target: Double) {
        if (loggedGain[deck.ordinal] == target) return
        loggedGain[deck.ordinal] = target
        host.log("volume glide deck=${deck.label} gain=${String.format(Locale.US, "%.1f", target)}")
    }

    /** The trim Volume Glide holds on [deck] right now (dB). */
    fun levelDb(deck: Deck): Double = level[deck.ordinal]
    val rampsSettled: Boolean get() = ramps.all { it == null }

    fun setEnabled(on: Boolean) {
        if (enabled == on) return
        enabled = on
        host.log("volume glide ${if (on) "on" else "off"}")
        refresh()
    }

    /** Re-level both decks (glide flipped, the Auto-DJ started / ended). */
    fun refresh() { for (d in Deck.entries) levelDeck(d) }

    /** A NEW song took [deck]. */
    fun deckLoaded(deck: Deck) {
        // awaiting is kept: a same-key reload must not queue a second analysis (a different key still starts its own,
        // and the stale result is dropped by the key check in levelDeck).
        rekicked[deck.ordinal] = false
        levelDeck(deck)
    }

    /** A growing-file deck finished downloading (or died): measure its file now. */
    fun deckSettled(deck: Deck) = levelDeck(deck)

    /** [deck] was ejected: no song, no trim, no readout. */
    fun deckCleared(deck: Deck) {
        val i = deck.ordinal
        ramps[i]?.close(); ramps[i] = null
        awaiting[i] = null
        rekicked[i] = false
        loggedGain[i] = Double.NaN
        if (level[i] != 0.0) { level[i] = 0.0; host.writeTrim(deck, 0.0) }
        publish(deck, LevelSide())
    }

    /** Level [deck]'s song (see the class doc for the cases). */
    fun levelDeck(deck: Deck) {
        val songId = host.loadedSongId(deck)
        if (!enabled || !host.autoMixing || songId == null) {
            awaiting[deck.ordinal] = null
            loggedGain[deck.ordinal] = Double.NaN
            setDeckLevel(deck, 0.0, LevelingStatus.INACTIVE)
            return
        }
        val src = host.levelSource(deck)
        if (src == null) {
            // Still streaming: waits for its file. No file at all (a bare source): nothing to measure.
            val st = if (host.isStreaming(deck)) LevelingStatus.MEASURING else LevelingStatus.UNAVAILABLE
            setDeckLevel(deck, if (st == LevelingStatus.MEASURING) level[deck.ordinal] else 0.0, st)
            return
        }
        val cache = cache()
        val key = cache?.let { LoudnessCache.key(songId, src.file, src.startMs, src.lengthMs) }
        if (cache == null || key == null) { setDeckLevel(deck, 0.0, LevelingStatus.UNAVAILABLE); return }
        cache.gainDb(key)?.let { setDeckLevel(deck, it, LevelingStatus.MEASURED); return }
        if (cache.contains(key) || cache.hasFailed(key)) { setDeckLevel(deck, 0.0, LevelingStatus.UNAVAILABLE); return }
        // Unmeasured: 0 dB + "measuring…" until the full analysis lands, then ramp the gain in.
        setDeckLevel(deck, 0.0, LevelingStatus.MEASURING)
        if (awaiting[deck.ordinal] == key) return
        awaiting[deck.ordinal] = key
        scope.launch {
            val outcome = cache.analyze(key, src.file.path)
            // The deck moved on (another song / file / a new analysis): this result is stale.
            if (awaiting[deck.ordinal] != key) return@launch
            awaiting[deck.ordinal] = null
            if (host.loadedSongId(deck) != songId) return@launch
            when (outcome) {
                is LoudnessCache.Outcome.Measured, is LoudnessCache.Outcome.Cached, LoudnessCache.Outcome.Failed -> levelDeck(deck)
                LoudnessCache.Outcome.Cancelled -> {
                    // The SHARED cache was cancelled under us (Now Playing DJ Mode turning off): measure again, once.
                    if (enabled && host.autoMixing && !rekicked[deck.ordinal]) { rekicked[deck.ordinal] = true; levelDeck(deck) }
                }
                LoudnessCache.Outcome.NotReady -> {}   // the file is still growing: deckSettled() re-kicks
            }
        }
    }

    /**
     * Put [db] on the deck's trim: at once while the deck is silent, else over [rampSeconds] in 20 ms steps
     * (the readout follows every [VolumeGlideRules.READOUT_EVERY]rd step).
     */
    private fun setDeckLevel(deck: Deck, db: Double, status: LevelingStatus) {
        val i = deck.ordinal
        val target = VolumeGlideRules.clamp(db)
        val from = level[i]
        ramps[i]?.close(); ramps[i] = null
        if (!VolumeGlideRules.shouldRamp(host.isAudible(deck), from, target, rampSeconds)) {
            if (from != target) { level[i] = target; host.writeTrim(deck, target) }
            publish(deck, LevelSide(status, target))
            if (status == LevelingStatus.MEASURED) logGain(deck, target)
            return
        }
        publish(deck, LevelSide(status, from))
        val steps = VolumeGlideRules.rampSteps(rampSeconds)
        var n = 0
        ramps[i] = driver.start(VolumeGlideRules.RAMP_STEP_MS) {
            n++
            val v = VolumeGlideRules.stepValue(from, target, n, steps)
            level[i] = v
            host.writeTrim(deck, v)
            if (n % VolumeGlideRules.READOUT_EVERY == 0 || n >= steps) publish(deck, LevelSide(status, v))
            if (n >= steps) ramps[i] = null
            n < steps
        }
        if (status == LevelingStatus.MEASURED) logGain(deck, target)
    }

    private fun publish(deck: Deck, side: LevelSide) {
        if (_leveling.value[deck] != side) _leveling.value = _leveling.value.with(deck, side)
    }
}
