package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.graph.DeckParams
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.graph.ParamsComposer
import com.levi.pocketdj.mix.graph.SlotParams
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxRack
import com.levi.pocketdj.mix.model.MixRanges
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File

/**
 * PB-6's seam (Playback area) for the Now Playing DSP hand-off: ExoPlayer plays the track until the
 * user first touches a mix control, then the host swaps the audio into this engine AT the current
 * position (iOS `SetlistPlayer.engageMix`). One audio owner at a time; the engine is presented to the
 * ONE MediaSession through the SessionSwitchboard (see [NowPlayingDspSessionPlayer]).
 */
interface NowPlayingDspSeam {
    val isEngaged: Boolean
    /**
     * Take over [file]'s song window [[startMs], [startMs]+[lengthMs]) (lengthMs <= 0 = to the end of the file)
     * at [atSeconds] into the song. false = the file cannot be decoded (the host keeps ExoPlayer).
     */
    fun engage(file: File, startMs: Long, lengthMs: Long, atSeconds: Double, play: Boolean): Boolean
    /** Release the graph; returns the song position (seconds) the engine reached, null when not engaged. */
    fun disengage(): Double?
    val isPlaying: Boolean
    val currentTimeSec: Double
    val rate: Double
    /** The window played to its end (fires once per engage, on the main thread via [NowPlayingDspEngine.tick]). */
    var onReachedEnd: (() -> Unit)?
}

/** Stem files on this device and how to get the rest; seam so the engine is JVM-testable. */
interface DspStemSource {
    /** Parts of [songId] on disk (any subset of vocals/drums/bass/other). */
    fun localParts(songId: String): Map<String, File>
    /** The catalog has stems for [songId] (so a handover may wait for them). */
    fun obtainable(songId: String): Boolean
    /** Fetch the missing ENABLED [parts] (idempotent); true when they are now on disk. */
    suspend fun fetch(songId: String, parts: List<String>): Boolean
}

/**
 * F4 - a SINGLE-DECK first-party DSP engine that takes over the CURRENTLY PLAYING local track so the
 * Now Playing mix mini-panel can apply tempo / pitch / gain / effects / stems in real time (iOS
 * `NowPlayingDSP`). It REUSES the Mix graph (decision: no fork): a private [MixGraph] whose deck A carries
 * the track through the same Voice -> TimePitch -> FX -> EQ -> trim chain, the same 60 ms linear
 * [com.levi.pocketdj.mix.graph.Handover] to the four stem voices, rendered to its own [AudioSink].
 *
 * Control state is EPHEMERAL: the host calls [resetControls] on every track change unless Stem Lock
 * carries the stem set ([applyCarriedStemControls]). Main-thread API; [tick] (host heartbeat, ~4 Hz)
 * starts the primed voice, completes pending stem handovers and detects the end of the window.
 */
class NowPlayingDspEngine(
    private val sinkFactory: () -> AudioSink,
    private val opener: MixSourceOpener,
    private val runner: VoiceRunner,
    private val stemSource: DspStemSource,
    private val scope: CoroutineScope,
    private val sampleRate: Int = 44_100,
) : NowPlayingDspSeam {

    private val graph = MixGraph(sampleRate)
    private val composer = ParamsComposer(graph).also { it.setCrossfader(0f) }
    private val deck = Deck.A

    // ---- engaged-track state ----
    private var sink: AudioSink? = null
    private var main: Voice? = null
    private var mainRun: AutoCloseable? = null
    private var stemGroup: VoiceGroup? = null
    private var stemRuns: List<AutoCloseable> = emptyList()
    private var songId: String? = null
    private var windowStart = 0L
    private var windowEnd = Long.MAX_VALUE
    private var playWanted = false
    private var started = false
    private var endFired = false
    private var tickCount = 0
    /** Song-window frame the voice was last positioned at (the voice reports 0 until its first rendered block). */
    private var positionedAt = 0L

    override var onReachedEnd: (() -> Unit)? = null
    /** The first audio left the engine (host: claim the MediaSession / pause ExoPlayer here). */
    var onAudioStarted: (() -> Unit)? = null
    /** A USER stem control moved (Stem Lock captures the carry from this; carried applies do not fire it). */
    var onUserStemChange: (() -> Unit)? = null
    /** The stems went on air for [songId]. */
    var onStemsOnAir: ((songId: String) -> Unit)? = null
    /** Any observable state changed (UI recomposition trigger). */
    var onChanged: (() -> Unit)? = null

    // ---- controls (ephemeral) ----
    override var rate = 1.0; private set
    var pitch = 0.0; private set
    var volume = 1.0; private set
    private val slots = Array(Effect.entries.size) { FXSlot(Effect.entries[it]) }

    var stemMode = false; private set
    var stemHandover: StemHandover? = null; private set
    var mutedStems: Set<String> = emptySet(); private set
    var stemVolumes: Map<String, Double> = emptyMap(); private set
    /** Parts a handover waits for (default: all not muted; Stem Lock narrows nothing, it just mutes). */
    private var handoverGen = 0
    private var retries = 0
    private var lastAbortGen = 0

    override val isEngaged: Boolean get() = main != null
    val engagedSongId: String? get() = songId
    override val isPlaying: Boolean get() = isEngaged && playWanted
    /** Audio has actually started flowing since [engage]. */
    val hasStarted: Boolean get() = started

    override val currentTimeSec: Double
        get() {
            val v = (if (stemOnSide()) stemGroup?.voices?.getOrNull(0) else main) ?: main ?: return 0.0
            val frame = if (started) v.playerFrame else maxOf(v.playerFrame, positionedAt)
            return ((frame - windowStart).coerceAtLeast(0L)).toDouble() / sampleRate
        }

    val durationSec: Double
        get() {
            val m = main ?: return 0.0
            val end = if (windowEnd == Long.MAX_VALUE) m.totalFrames else windowEnd
            return (end - windowStart).coerceAtLeast(0L).toDouble() / sampleRate
        }

    /** Stems are audible (the handover landed on the stems). */
    val stemsOnAir: Boolean get() = isEngaged && stemGroup != null && graph.deck(deck).handover.let { it.intentStems && it.publishedStem >= 0.999f }
    /** A handover to the stems is pending or fading. */
    val stemsLoading: Boolean get() = stemHandover == StemHandover.TO_STEMS || (stemMode && !stemsOnAir)
    val stemsAvailable: Boolean get() = songId?.let { stemSource.obtainable(it) || stemSource.localParts(it).isNotEmpty() } == true

    /** The catalog/disk has stems for [id] (usable BEFORE the swap: the Stems toggle is enabled pre-engage). */
    fun stemsAvailableFor(id: String): Boolean = stemSource.obtainable(id) || stemSource.localParts(id).isNotEmpty()

    private fun stemOnSide(): Boolean = graph.deck(deck).handover.intentStems && stemGroup != null

    // ================================================================ seam

    override fun engage(file: File, startMs: Long, lengthMs: Long, atSeconds: Double, play: Boolean): Boolean {
        if (isEngaged) disengage()
        val src = runCatching { opener.open(file) }.getOrNull() ?: return false
        val v = Voice(src, sampleRate, name = "np-dsp")
        windowStart = Math.round(startMs / 1000.0 * sampleRate)
        windowEnd = if (lengthMs > 0) minOf(windowStart + Math.round(lengthMs / 1000.0 * sampleRate), v.totalFrames.takeIf { it > 0 } ?: Long.MAX_VALUE)
        else Long.MAX_VALUE
        val at = (windowStart + Math.round(atSeconds.coerceAtLeast(0.0) * sampleRate)).coerceAtMost(maxOf(windowStart, windowEnd - 1))
        v.schedule(at, windowEnd)
        positionedAt = at
        main = v
        mainRun = runner.run(v)
        graph.setMain(deck, v)
        // The chain's handover persists across engages: a previous track that ended on its stems left the
        // gains at main=0/stems=1. A new track STARTS on the full mix (lands at the next block).
        graph.deck(deck).handover.settle(false)
        publishParams()
        val s = sinkFactory()
        sink = s
        graph.attach(s)
        playWanted = play
        started = false
        endFired = false
        tickCount = 0
        if (play) v.play(-1)
        onChanged?.invoke()
        return true
    }

    /** Remember which song is engaged (stems are keyed on it). Call right after a successful [engage]. */
    fun bindSong(id: String) { songId = id; onChanged?.invoke() }

    override fun disengage(): Double? {
        if (!isEngaged) return null
        val pos = currentTimeSec
        handoverGen++            // stop() FIRES completions: a stale fetch must find its generation moved on
        stemHandover = null
        playWanted = false
        graph.setMain(deck, null)
        graph.setStems(deck, null)
        sink?.let { runCatching { it.stop() }; runCatching { it.release() } }
        sink = null
        mainRun?.let { runCatching { it.close() } }; mainRun = null
        main?.let { runCatching { it.close() } }; main = null
        stemRuns.forEach { runCatching { it.close() } }; stemRuns = emptyList()
        stemGroup?.let { runCatching { it.closeAll() } }; stemGroup = null
        graph.deck(deck).resetDsp()
        songId = null
        started = false
        onChanged?.invoke()
        return pos
    }

    // ================================================================ transport

    fun play() {
        val v = main ?: return
        playWanted = true
        graph.settleHandover(deck)
        if (stemOnSide()) stemGroup?.startAt(-1) else v.play(-1)
        onChanged?.invoke()
    }

    fun pause() {
        if (!isEngaged) return
        playWanted = false
        main?.pause(); stemGroup?.pauseAll()
        onChanged?.invoke()
    }

    fun togglePlay() { if (playWanted) pause() else play() }

    fun seekTo(seconds: Double) {
        val v = main ?: return
        val f = (windowStart + Math.round(seconds.coerceAtLeast(0.0) * sampleRate)).coerceAtMost(maxOf(windowStart, windowEnd - 1))
        graph.settleHandover(deck)
        positionedAt = f
        if (stemOnSide()) { stemGroup?.seekAll(f); if (playWanted) stemGroup?.startAt(-1) }
        else { v.seek(f); if (playWanted) v.play(-1) }
        endFired = false
    }

    // ================================================================ heartbeat

    /** Host heartbeat. Cheap; safe to call at any rate. */
    fun tick() {
        val v = main ?: return
        tickCount++
        if (!started && playWanted && v.status == Voice.Status.PLAYING) {
            started = true
            onAudioStarted?.invoke()
        }
        pollHandover()
        if (!endFired && playWanted && started) {
            val frame = v.playerFrame
            val ended = v.status == Voice.Status.ENDED ||
                (windowEnd != Long.MAX_VALUE && frame >= windowEnd - 1) ||
                (stemOnSide() && stemGroup?.voices?.getOrNull(0)?.let { s -> s.status == Voice.Status.ENDED || (windowEnd != Long.MAX_VALUE && s.playerFrame >= windowEnd - 1) } == true)
            if (ended) {
                endFired = true
                playWanted = false
                onReachedEnd?.invoke()
                onChanged?.invoke()
            }
        }
    }

    // ================================================================ controls

    fun setRate(r: Double) {
        rate = r.coerceIn(MixRanges.rate.start, MixRanges.rate.endInclusive)
        composer.setTempoPitch(deck, rate, pitch); onChanged?.invoke()
    }

    fun setPitch(semitones: Double) {
        pitch = semitones.coerceIn(MixRanges.pitch.start, MixRanges.pitch.endInclusive)
        composer.setTempoPitch(deck, rate, pitch); onChanged?.invoke()
    }

    fun setVolume(v: Double) {
        volume = v.coerceIn(MixRanges.volume.start, MixRanges.volume.endInclusive)
        composer.setVolume(deck, volume); onChanged?.invoke()
    }

    fun isEnabled(e: Effect): Boolean = slots[e.ordinal].enabled
    fun strength(e: Effect): Double = slots[e.ordinal].strength

    fun setEffect(e: Effect, enabled: Boolean) {
        slots[e.ordinal] = slots[e.ordinal].setEnabled(enabled)
        publishSlots(); onChanged?.invoke()
    }

    fun setEffectStrength(e: Effect, strength: Double) {
        slots[e.ordinal] = slots[e.ordinal].setStrength(strength)
        publishSlots(); onChanged?.invoke()
    }

    private fun publishSlots() {
        composer.setSlots(deck, slots.map { if (it.enabled) SlotParams(it, it.strength) else null })
    }

    private fun publishParams() {
        composer.setTempoPitch(deck, rate, pitch)
        composer.setVolume(deck, volume)
        publishSlots()
        publishBalance()
    }

    private fun publishBalance() {
        val b = FloatArray(DeckParams.STEMS) { i ->
            val name = BurnFileNames.STEM_NAMES[i]
            if (name in mutedStems) 0f else (stemVolumes[name] ?: 1.0).coerceIn(0.0, 1.0).toFloat()
        }
        composer.setStemBalance(deck, b)
    }

    fun setStemMuted(name: String, muted: Boolean) {
        if (name !in BurnFileNames.STEM_NAMES) return
        mutedStems = if (muted) mutedStems + name else mutedStems - name
        publishBalance(); onUserStemChange?.invoke(); onChanged?.invoke()
    }

    fun setStemVolume(name: String, v: Double) {
        if (name !in BurnFileNames.STEM_NAMES) return
        stemVolumes = stemVolumes + (name to v.coerceIn(0.0, 1.0))
        publishBalance(); onUserStemChange?.invoke(); onChanged?.invoke()
    }

    /** Stem Lock re-applies a carried set on the next track (NOT a user change). */
    fun applyCarriedStemControls(muted: Set<String>, volumes: Map<String, Double>) {
        mutedStems = muted.intersect(BurnFileNames.STEM_NAMES.toSet())
        stemVolumes = volumes.filterKeys { it in BurnFileNames.STEM_NAMES }.mapValues { it.value.coerceIn(0.0, 1.0) }
        publishBalance(); onChanged?.invoke()
    }

    /** Back to defaults (a track change); the graph is not touched when not engaged. */
    fun resetControls() {
        rate = 1.0; pitch = 0.0; volume = 1.0
        for (e in Effect.entries) slots[e.ordinal] = FXSlot(e)
        stemMode = false; stemHandover = null; handoverGen++
        mutedStems = emptySet(); stemVolumes = emptyMap()
        publishParams()
        onChanged?.invoke()
    }

    /** The user's stem snapshot for Stem Lock. */
    fun stemSnapshot(): StemSnapshot = StemSnapshot(stemMode, mutedStems, stemVolumes)

    // ================================================================ stems

    private fun requiredParts(): List<String> = BurnFileNames.STEM_NAMES.filter { it !in mutedStems }

    /** USER toggle. false = nothing to hand over to (not engaged). */
    fun setStemMode(on: Boolean): Boolean {
        val ok = changeStemMode(on)
        if (ok) onUserStemChange?.invoke()
        return ok
    }

    /** Stem Lock's own request (not a user change). */
    fun requestStemModeForLock(on: Boolean): Boolean = changeStemMode(on)

    private fun changeStemMode(on: Boolean): Boolean {
        val id = songId ?: return false
        if (!isEngaged) return false
        handoverGen++
        retries = 0
        val gen = handoverGen
        stemMode = on
        if (!on) {
            if (stemHandover == StemHandover.TO_STEMS) stemHandover = null
            if (stemOnSide() || graph.deck(deck).handover.inFlight) {
                stemHandover = StemHandover.TO_FULL_MIX
                graph.crossfadeTo(deck, false)
                // the main voice is resumed by crossfadeTo's seek/play; the landing clears the flag in pollHandover
            } else stemHandover = null
            onChanged?.invoke()
            return true
        }
        stemHandover = StemHandover.TO_STEMS
        onChanged?.invoke()
        if (!partsReady(id)) {
            val missing = requiredParts().filter { it !in stemSource.localParts(id) }
            if (stemSource.obtainable(id) && missing.isNotEmpty()) {
                scope.launch {
                    val ok = runCatching { stemSource.fetch(id, missing) }.getOrDefault(false)
                    if (gen != handoverGen) return@launch   // superseded: touch nothing
                    if (!ok) { stemMode = false; stemHandover = null; onChanged?.invoke() }
                    else pollHandover()
                }
            } else {
                // nothing to wait for: no stems at all for this song
                stemMode = false; stemHandover = null
                onChanged?.invoke()
                return false
            }
        } else pollHandover()
        return true
    }

    private fun partsReady(id: String): Boolean {
        val local = stemSource.localParts(id)
        val req = requiredParts()
        return req.isNotEmpty() && req.all { it in local } || (req.isEmpty() && local.isNotEmpty())
    }

    private fun buildGroup(id: String): VoiceGroup? {
        val local = stemSource.localParts(id)
        val m = main ?: return null
        val voices = ArrayList<Voice>()
        val runs = ArrayList<AutoCloseable>()
        for (name in BurnFileNames.STEM_NAMES) {
            val f = local[name]
            val src = f?.let { runCatching { opener.open(it) }.getOrNull() }
                ?: SyntheticPcmSource(sampleRate, 2, maxOf(1L, m.totalFrames)) { _, _ -> 0f }   // muted / not landed: silent filler
            val v = Voice(src, sampleRate, name = "np-stem-$name")
            v.schedule(windowStart, windowEnd)
            runs += runner.run(v)
            voices += v
        }
        stemRuns = runs
        return VoiceGroup(voices)
    }

    /** Complete a pending TO_STEMS once its parts landed and the stem voices have runway; clear a landed TO_FULL_MIX. */
    private fun pollHandover() {
        val id = songId ?: return
        val h = graph.deck(deck).handover
        when (stemHandover) {
            StemHandover.TO_STEMS -> {
                if (!partsReady(id)) return
                if (stemGroup == null) {
                    val g = buildGroup(id) ?: return
                    stemGroup = g
                    graph.setStems(deck, g)
                    return                       // let the stem decoders fill; the fade starts on a later poll
                }
                val g = stemGroup ?: return
                if (!g.allReady(RUNWAY_FRAMES)) return
                if (h.inFlight) return
                if (h.intentStems && h.landedToStems) { finishToStems(id); return }
                if (h.abortedGen != 0 && h.abortedGen == h.latestGen && h.abortedGen != lastAbortGen) {
                    lastAbortGen = h.abortedGen
                    if (++retries > MAX_RETRIES) { stemMode = false; stemHandover = null; onChanged?.invoke(); return }
                }
                graph.crossfadeTo(deck, true, forceOutright = !playWanted)
                if (!h.inFlight && h.intentStems) finishToStems(id)
            }
            StemHandover.TO_FULL_MIX -> {
                if (!h.inFlight && !h.intentStems) { stemHandover = null; onChanged?.invoke() }
            }
            null -> Unit
        }
    }

    private fun finishToStems(id: String) {
        stemHandover = null
        onChanged?.invoke()
        onStemsOnAir?.invoke(id)
    }

    companion object {
        const val RUNWAY_FRAMES = 2048
        const val MAX_RETRIES = 3
    }
}
