package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.Mp3StreamSourceFactory
import com.levi.pocketdj.mix.engine.StreamHandle
import com.levi.pocketdj.mix.engine.StreamSourceFactory
import com.levi.pocketdj.mix.stream.GrowingFileSchedule
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
    /** Opens the growing decoder for [engageStreaming] (a fake under test). */
    private val growing: StreamSourceFactory = Mp3StreamSourceFactory(),
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
    private var startedAtClock = 0L
    private var audioAnnounced = false
    private var voiceEndedAtClock = -1L
    private fun clockNow(): Long = graph.deck(deck).inputClock
    /** True once the render clock has advanced past [since] by the stretcher's output delay (deterministic offline). */
    private fun lagElapsed(since: Long): Boolean = clockNow() - since >= graph.deck(deck).latencyFrames
    private var tickCount = 0
    /** Song-window frame the voice was last positioned at (the voice reports 0 until its first rendered block). */
    private var positionedAt = 0L

    /** A growing-file song being played while it downloads (null for an ordinary file). */
    private var grow: Grow? = null

    /** The mutable [StreamHandle] [engageStreaming] / [streamProgressed] keep current. */
    private class GrowHandle(file: File, expected: Long?, override val startMs: Long?) : StreamHandle {
        override val songId: String = file.name
        override val resolved = true
        override var bytesReceived = 0L
        override var expectedBytes: Long? = expected
        override var isComplete = false
        override var failed = false
        override val isCut = false
        override var file: File? = file
    }

    private class Grow(val handle: GrowHandle, val sources: StreamSourceFactory, val lengthMs: Long) {
        /** Waiting for bytes: playhead frozen at [heldSec], play intent kept. */
        var holding = true
        var attached = false
        var headerless = false
        /** Bytes received at the last undecided sniff / implausible-length probe (-1 = none): re-probe only after real growth. */
        var sniffedAt = -1L
        var everStarted = false
        var fullEnd = 0L
        /** Voice window end = how far the voice has been allowed to schedule (never past the byte frontier). */
        var voiceEnd = 0L
        var bps: Double? = null
        var source: PcmSource? = null
        var heldSec = 0.0
    }

    override var onReachedEnd: (() -> Unit)? = null
    /** A growing file died BEFORE any audio attached: the host re-plays the row its plain way from [posSec]. */
    var onStreamFailed: ((posSec: Double) -> Unit)? = null
    /** The first audio left the engine (host: claim the MediaSession / pause ExoPlayer here). */
    var onAudioStarted: (() -> Unit)? = null
    /**
     * The graph is built and the sink attached but NOTHING sounds yet: the host claims the MediaSession here
     * (silently pausing ExoPlayer) so exactly one engine ever sounds during the swap, whether or not it plays.
     */
    var onEngaged: (() -> Unit)? = null
    /** The engine left the graph ([disengage], for any reason): the host resigns the session. */
    var onDisengaged: (() -> Unit)? = null
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

    override val isEngaged: Boolean get() = main != null || grow != null
    /** The engaged song is still downloading (its window is the byte frontier, not the file). */
    val isStreaming: Boolean get() = grow != null
    /** The DSP HOLDS at the frontier of a still-downloading song with the play intent kept (the session shows BUFFERING). */
    val isBuffering: Boolean get() = grow?.let { it.holding && playWanted } == true
    val engagedSongId: String? get() = songId
    override val isPlaying: Boolean get() = isEngaged && playWanted
    /** Audio has actually started flowing since [engage]. */
    val hasStarted: Boolean get() = started
    /** The engaged growing song has ever made sound this engagement (survives hold resumes, unlike [hasStarted]). */
    val producedAudio: Boolean get() = grow?.everStarted ?: started

    override val currentTimeSec: Double
        get() {
            grow?.let { if (it.holding || !it.attached) return it.heldSec }
            val v = (if (stemOnSide()) stemGroup?.voices?.getOrNull(0) else main) ?: main ?: return 0.0
            val frame = if (started) v.playerFrame else maxOf(v.playerFrame, positionedAt)
            val raw = ((frame - windowStart).coerceAtLeast(0L)).toDouble() / sampleRate
            return npAudibleSeconds(raw, if (started && playWanted) graph.audibleLagSeconds(deck) else 0.0)
        }

    internal fun graphLagSecondsForTest(): Double = graph.audibleLagSeconds(deck)
    internal fun graphLatencyFramesForTest(): Int = graph.deck(deck).latencyFrames

    val durationSec: Double
        get() {
            val m = main ?: return grow?.let { (if (it.lengthMs > 0) it.lengthMs else FALLBACK_DURATION_MS) / 1000.0 } ?: 0.0
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
        beginGraph(play)
        if (play) v.play(-1)
        onChanged?.invoke()
        return true
    }

    /** Shared tail of an engage: settle the handover, publish the controls, attach the sink, claim the session. */
    private fun beginGraph(play: Boolean) {
        // The chain's handover persists across engages: a previous track that ended on its stems left the
        // gains at main=0/stems=1. A new track STARTS on the full mix (lands at the next block).
        graph.deck(deck).handover.settle(false)
        publishParams()
        val s = sinkFactory()
        sink = s
        graph.attach(s)
        playWanted = play
        started = false
        audioAnnounced = false
        voiceEndedAtClock = -1L
        endFired = false
        tickCount = 0
        // Claim the session (ExoPlayer pauses silently) BEFORE the voice starts: no double audio.
        onEngaged?.invoke()
    }

    // ================================================================ growing file (engageStreaming)

    /**
     * Take over a STILL-DOWNLOADING file (the loader's buffer stream) at [atSeconds] into the song. The graph
     * engages at once; the file attaches when its header declares the full length, the playhead is HELD until
     * there is start runway, and nothing is ever scheduled past the byte frontier (iOS `engageStreaming`).
     * A hold freezes the playhead and keeps the play intent ([isBuffering]). Feed progress with [streamProgressed].
     * A headerless mp3 (no Xing/Info/VBRI) is never attached on a partial length estimate - held unattached
     * until complete. The window is [startMs] + [lengthMs] (0 = whole file) like [engage].
     */
    fun engageStreaming(
        file: File, expectedBytes: Long?, atSeconds: Double, play: Boolean,
        startMs: Long = 0, lengthMs: Long = 0, bytesReceived: Long = 0, complete: Boolean = false,
        sources: StreamSourceFactory = growing,
    ): Boolean {
        if (isEngaged) disengage()
        val h = GrowHandle(file, expectedBytes, startMs.takeIf { it > 0 })
        h.bytesReceived = bytesReceived; h.isComplete = complete
        val g = Grow(h, sources, lengthMs)
        g.heldSec = atSeconds.coerceAtLeast(0.0)
        grow = g
        windowStart = 0L
        windowEnd = Long.MAX_VALUE
        positionedAt = 0L
        beginGraph(play)
        pumpStream()          // attach now when the header is already there
        onChanged?.invoke()
        return true
    }

    /** The loader's progress for the engaged stream: bytes landed / complete / dead. [finalFile] = the adopted burn file. */
    fun streamProgressed(bytesReceived: Long, complete: Boolean = false, failed: Boolean = false, finalFile: File? = null) {
        val g = grow ?: return
        val h = g.handle
        h.bytesReceived = maxOf(h.bytesReceived, bytesReceived)
        h.isComplete = h.isComplete || complete
        h.failed = h.failed || failed
        if (finalFile != null) h.file = finalFile
        pumpStream()
    }

    private fun setHolding(g: Grow, on: Boolean) {
        if (g.holding == on) return
        g.holding = on
        onChanged?.invoke()
    }

    /** Extend the growing song to the new byte frontier: attach, resume a hold with runway, append, finish. */
    private fun pumpStream() {
        val g = grow ?: return
        val h = g.handle
        if (h.failed) { streamFailed(g); return }
        if (!(h.bytesReceived > 0 || h.isComplete)) return
        if (!g.attached && !attachStream(g)) return
        val v = main ?: return
        val sr = sampleRate.toDouble()
        val complete = h.isComplete
        val frontier = if (complete) g.fullEnd else minOf(
            GrowingFileSchedule.frontier(h.bytesReceived, false, g.bps, sr, windowStart, g.fullEnd),
            // never past what the decoder can actually produce (ID3 / art bytes, VBR intros)
            g.source?.let { maxOf(windowStart, it.availableFrames) } ?: g.fullEnd,
        )
        if (g.holding) {
            if (!playWanted) return                 // paused at the held spot: ▶ pumps again
            val posFrame = windowStart + Math.round(g.heldSec * sr)
            if (!GrowingFileSchedule.canStart(posFrame, frontier, g.fullEnd, complete,
                    GrowingFileSchedule.runwayNeeded(resuming = g.everStarted), sr)) return
            v.append(frontier, final = complete && frontier >= g.fullEnd)
            g.voiceEnd = maxOf(g.voiceEnd, frontier)
            setHolding(g, false)
            resumeVoiceAt(v, posFrame)
        } else if (frontier > g.voiceEnd &&
            GrowingFileSchedule.shouldAppend(g.voiceEnd, frontier, v.playerFrame, sr, complete)) {
            v.append(frontier, final = complete && frontier >= g.fullEnd)
            g.voiceEnd = frontier
        }
        if (complete && g.voiceEnd >= g.fullEnd && !g.holding) finishStream(g)
    }

    private fun resumeVoiceAt(v: Voice, posFrame: Long) {
        positionedAt = posFrame
        started = false
        v.seek(posFrame)
        if (playWanted) { graph.settleHandover(deck); v.play(-1) }
    }

    /** First attach: the header (and its full-length claim) is readable; install the voice over an EMPTY window. */
    private fun attachStream(g: Grow): Boolean {
        val h = g.handle
        // An undecided / implausible verdict is cached by bytes received: progress fires per chunk and each
        // probe is file IO (and possibly a decoder open), so re-probe only after SNIFF_REPROBE_BYTES of growth.
        if (!h.isComplete && g.sniffedAt >= 0 && h.bytesReceived - g.sniffedAt < SNIFF_REPROBE_BYTES) return false
        val claim = if (h.isComplete) GrowingFileSchedule.LengthClaim.Container else g.sources.lengthClaim(h)
        if (!h.isComplete && !GrowingFileSchedule.attachableWhilePartial(claim)) {
            g.sniffedAt = h.bytesReceived
            // Headerless (or undecided): the decoder's length is an estimate from the bytes present; attached,
            // the completed song would "end" where the partial did. Held unattached until complete.
            if (claim != GrowingFileSchedule.LengthClaim.Undetermined) g.headerless = true
            return false
        }
        val src = runCatching { g.sources.open(h) }.getOrNull()
        if (src == null) { if (h.isComplete) streamFailed(g); return false }
        val v = Voice(src, sampleRate, name = "np-dsp")
        val sr = sampleRate.toDouble()
        val bps = GrowingFileSchedule.bytesPerSecond(v.totalFrames, sr, h.expectedBytes, claim)
        if (bps == null && !h.isComplete) { runCatching { v.close() }; g.headerless = true; g.sniffedAt = h.bytesReceived; return false }
        val w = GrowingFileSchedule.window(
            v.totalFrames, sr, h.startMs?.toInt(), g.lengthMs.takeIf { it > 0 }?.toInt(),
        )
        if (w.second <= 0) { runCatching { v.close() }; if (h.isComplete) streamFailed(g); return false }
        windowStart = w.first
        windowEnd = w.first + w.second
        g.fullEnd = windowEnd
        g.voiceEnd = windowStart
        g.bps = bps
        g.source = src
        g.heldSec = g.heldSec.coerceAtMost(w.second.toDouble() / sr)
        v.schedule(windowStart, windowStart, final = false)
        main = v
        mainRun = runner.run(v)
        graph.setMain(deck, v)
        positionedAt = windowStart + Math.round(g.heldSec * sr)
        g.attached = true
        onChanged?.invoke()
        return true
    }

    /** The whole window is scheduled and the download is done: an ordinary file song from now on. */
    private fun finishStream(g: Grow) {
        g.source?.let { g.sources.markComplete(it) }
        grow = null
        onChanged?.invoke()
    }

    /** The download died. Before any audio: the host re-plays the row its plain way. Mid-song: the bytes we have ARE the song. */
    private fun streamFailed(g: Grow) {
        if (!g.attached || main == null || (!g.everStarted && g.voiceEnd <= windowStart)) {
            val at = g.heldSec
            disengage()
            onStreamFailed?.invoke(at)
            return
        }
        val v = main ?: return
        v.append(g.voiceEnd, final = true)       // the voice now ENDS at the frontier instead of underrunning
        windowEnd = g.voiceEnd
        g.source?.let { g.sources.markComplete(it) }   // drain every byte that arrived
        val dead = g
        grow = null
        if (dead.holding) {
            val sr = sampleRate.toDouble()
            val last = maxOf(windowStart, windowEnd - 1)
            resumeVoiceAt(v, minOf(windowStart + Math.round(dead.heldSec * sr), last))
        }
        onChanged?.invoke()
    }

    /** The playing voice caught the frontier of a growing song: freeze the playhead there, keep the play intent. */
    private fun holdStream(g: Grow, v: Voice) {
        val sr = sampleRate.toDouble()
        val endSec = (g.voiceEnd - windowStart).toDouble() / sr
        g.heldSec = minOf(currentTimeSec, endSec).coerceAtLeast(0.0)
        g.everStarted = true
        v.pause(); stemGroup?.pauseAll()
        setHolding(g, true)
    }

    private fun seekStreaming(g: Grow, seconds: Double) {
        val target = seconds.coerceIn(0.0, maxOf(0.0, durationSec - 0.05))
        endFired = false
        val v = main
        if (!g.attached || v == null) { g.heldSec = target; onChanged?.invoke(); return }
        val sr = sampleRate.toDouble()
        val f = windowStart + Math.round(target * sr)
        if (g.holding || (!g.handle.isComplete && f >= g.voiceEnd - Math.round(GrowingFileSchedule.UNDERRUN_LEAD * sr))) {
            // Past the downloaded frontier: HOLD at the target; the pump resumes there once the bytes arrive.
            g.everStarted = g.everStarted || started
            v.pause()
            g.heldSec = target
            positionedAt = f
            setHolding(g, true)
            pumpStream()
        } else {
            positionedAt = f
            v.seek(f)
            if (playWanted) v.play(-1)
        }
    }

    /** Remember which song is engaged (stems are keyed on it). Call right after a successful [engage]. */
    fun bindSong(id: String) { songId = id; onChanged?.invoke() }

    override fun disengage(): Double? {
        if (!isEngaged) return null
        val pos = currentTimeSec
        handoverGen++            // stop() FIRES completions: a stale fetch must find its generation moved on
        stemHandover = null
        playWanted = false
        grow?.let { g -> g.source?.let { s -> runCatching { g.sources.markComplete(s) } } }
        grow = null
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
        onDisengaged?.invoke()
        return pos
    }

    // ================================================================ transport

    fun play() {
        grow?.let { g ->
            if (g.holding || !g.attached) { playWanted = true; pumpStream(); onChanged?.invoke(); return }
        }
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
        grow?.let { seekStreaming(it, seconds); return }
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
        grow?.let { g ->
            if (g.holding && playWanted) pumpStream()      // bytes may have landed since the last event
            val gv = main
            if (grow === g && g.attached && !g.holding && playWanted && started && gv != null && stemGroup == null) {
                val sr = sampleRate.toDouble()
                val raw = (gv.playerFrame - windowStart).toDouble() / sr
                val end = (g.voiceEnd - windowStart).toDouble() / sr
                if (GrowingFileSchedule.underrun(raw, end, (g.fullEnd - windowStart).toDouble() / sr)) {
                    holdStream(g, gv)
                    pumpStream()                            // bytes that arrived since may already cover it
                }
            }
        }
        val v = main ?: return
        tickCount++
        if (!started && playWanted && v.status == Voice.Status.PLAYING) {
            started = true
            grow?.everStarted = true
            startedAtClock = clockNow()
        }
        // The stretcher delays the first audible sample: hand the session over when it actually sounds.
        if (started && !audioAnnounced &&
            lagElapsed(startedAtClock)) {
            audioAnnounced = true
            onAudioStarted?.invoke()
        }
        pollHandover()
        if (!endFired && playWanted && started) {
            val frame = v.playerFrame
            val voiceEnded = v.status == Voice.Status.ENDED ||
                (windowEnd != Long.MAX_VALUE && frame >= windowEnd - 1) ||
                (stemOnSide() && stemGroup?.voices?.getOrNull(0)?.let { s -> s.status == Voice.Status.ENDED || (windowEnd != Long.MAX_VALUE && s.playerFrame >= windowEnd - 1) } == true)
            if (!voiceEnded) voiceEndedAtClock = -1L
            else if (voiceEndedAtClock < 0L) voiceEndedAtClock = clockNow()
            // The tail is still inside the stretcher: let it drain before the host engages the next track.
            val ended = voiceEnded && voiceEndedAtClock >= 0L && lagElapsed(voiceEndedAtClock)
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
                if (grow != null) return         // stems hand over once the song has finished downloading
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
        /** Growth in received bytes before an undecided / implausible length probe is repeated. */
        const val SNIFF_REPROBE_BYTES = 16L * 1024
        const val MAX_RETRIES = 3
        /** Provisional length of a streaming engage that did not carry one (the Mix deck's value). */
        const val FALLBACK_DURATION_MS = 180_000L
    }
}

/** Audible playhead: the voice counter minus the stretcher delay, never negative (Now Playing DSP, ANS-MIX-2). */
internal fun npAudibleSeconds(rawSeconds: Double, lagSeconds: Double): Double = (rawSeconds - lagSeconds).coerceAtLeast(0.0)
