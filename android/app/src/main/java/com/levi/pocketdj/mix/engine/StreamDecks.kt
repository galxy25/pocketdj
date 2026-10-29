package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.FileByteSource
import com.levi.pocketdj.audio.core.Mp3Decoder
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.diag.DiagLog
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixMath
import com.levi.pocketdj.mix.stream.MixStreamLoader
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What the stream machine reads off one download (the slice of [MixStreamLoader.Stream] it needs). */
interface StreamHandle {
    val songId: String
    /** The source URL is known and the transfer is running / done. */
    val resolved: Boolean
    val bytesReceived: Long
    val expectedBytes: Long?
    val isComplete: Boolean
    val failed: Boolean
    /** A per-song cut: plays whole from 0:00. Otherwise [startMs] seeks into a shared album side. */
    val isCut: Boolean
    val startMs: Long?
    /** The file the bytes land in; the adopted burn file once the loader moved it. */
    val file: File?
}

/** The loader as the stream machine sees it (the real [MixStreamLoader], or a fake under test). */
interface StreamLoaderPort {
    fun canStream(songId: String, forAuto: Boolean = false): Boolean
    fun isRipped(songId: String): Boolean
    fun open(songId: String, title: String, artist: String, forAuto: Boolean = false): StreamHandle?
    fun stream(songId: String): StreamHandle?
}

/** Opens a growing-file decoder over a stream. null = the header is not readable yet (retry on the next event). */
interface StreamSourceFactory {
    fun open(h: StreamHandle): PcmSource?
    /** The download finished: the source's frontier is the whole file. */
    fun markComplete(src: PcmSource) {}
}

/** The Auto-DJ facts the stream machine needs (MIX-9 supplies them; absent = manual mixing). */
interface AutoStreamHooks {
    /** [deck] is the auto machine's live (on-air) deck. */
    fun isLiveDeck(deck: Deck): Boolean
    /** A crossfade / transition is in flight. */
    val isTransitioning: Boolean
    /** Skip to the next queued song with a [fadeSeconds] fade. */
    fun skipToNext(fadeSeconds: Double)
}

/** Pure streaming decisions (iOS `MixEngine` statics + the pump/tick conditions). */
object StreamRules {
    /** Seconds of runway needed past the playhead to start / to resume after an underrun. */
    const val START_RUNWAY = 2.0
    const val RESUME_RUNWAY = 4.0
    /** Seconds of downloaded runway that make a streaming deck "ready" for a transition. */
    const val AUTO_READY_RUNWAY = 15.0
    /** With this little left of the live song and nothing able to air, the live song is replayed. */
    const val AUTO_EXTEND_AT_SECONDS_LEFT = 0.5
    /** A live deck frozen on an underrun this long hands over to a ready song. */
    const val AUTO_STALL_SKIP_SECONDS = 8.0
    /** Provisional length of a streaming load that did not carry one. */
    const val FALLBACK_DURATION_MS = 180_000
    /** The tick holds a streaming deck once its playhead is this close to the frontier. */
    const val HOLD_EPSILON = 0.05

    fun runwayNeeded(playing: Boolean): Double = if (playing) RESUME_RUNWAY else START_RUNWAY

    /**
     * May a HELD deck start / resume? A complete stream always can; otherwise the frontier must be past
     * the playhead and cover the runway (capped at the window's end). Frames in file frames.
     */
    fun canResume(complete: Boolean, frontier: Long, posFrame: Long, fullEnd: Long, sampleRate: Int, playing: Boolean): Boolean {
        if (complete) return true
        val need = min(fullEnd, posFrame + (runwayNeeded(playing) * sampleRate).toLong())
        return frontier > posFrame && frontier >= need
    }

    /** Append chunk (seconds) by remaining runway: small while it is short, big once comfortable. */
    fun appendChunk(runwaySeconds: Double): Double = if (runwaySeconds < 10) 1.0 else 15.0

    /** Has the playhead caught a still-growing frontier (the tick holds the deck)? */
    fun shouldHold(frontierSec: Double, durationSec: Double, posSec: Double): Boolean =
        frontierSec < durationSec - HOLD_EPSILON && posSec >= frontierSec - HOLD_EPSILON

    /** STRICT readiness of a streaming deck (iOS deckReadyToAir): finished, or [AUTO_READY_RUNWAY] downloaded past the playhead. */
    fun readyToAir(held: Boolean, complete: Boolean, frontierSec: Double?, posSec: Double, durationSec: Double): Boolean {
        if (held) return false
        if (complete) return true
        val f = frontierSec ?: return false
        return f - posSec >= min(AUTO_READY_RUNWAY, max(0.0, durationSec - posSec) - 0.1)
    }
}

/**
 * Streaming decks (port of iOS `MixEngine` "Streaming mode"): a deck asked for a ripped-but-not-burned
 * song loads it STREAMING. The track takes the deck at once (the auto machine's load check never waits),
 * with the catalog length as a provisional duration and the playhead HELD; [pumpStream] attaches the
 * growing file once its header is readable, starts / resumes a held deck when it has runway, raises the
 * voice's window to the byte frontier, and finally marks the file complete (the same decoder simply
 * runs on into the adopted burn: no re-open, so no seam).
 *
 * The voice's window end IS the schedulable frontier (iOS `endFrames`): a voice that runs dry on a
 * non-final window reports UNDERRUN rather than ending, and the tick HOLDS the playhead at the frontier
 * (`holdStream`). Held seconds never advance the playhead or the auto end clock (the engine tick skips a
 * held deck and tells the Auto-DJ). Stem streaming itself lives in [StemController]; this class feeds it
 * the full mix's reach through [MainVoiceStatus] and the main-progress / unhold seams.
 *
 * Main thread only. Install with [install].
 */
class StreamDecks(
    private val engine: MixEngine,
    private val loader: StreamLoaderPort?,
    private val sources: StreamSourceFactory,
    private val stems: StemController? = null,
    /** The song's audio is fully on this device (a burn / studio / profile file). */
    private val hasLocalFile: (String) -> Boolean = { false },
) : MainVoiceStatus {

    private class DeckStream(val handle: StreamHandle) {
        var holding = true
        var windowMs: Int? = null
        var fullEnd = 0L
        var bps: Double? = null
        var source: PcmSource? = null
        var attached = false
        var heldSinceMs: Long? = null
    }

    private val ds = arrayOfNulls<DeckStream>(2)
    private val truncated = BooleanArray(2)
    private fun s(d: Deck) = ds[d.ordinal]

    /** Auto-DJ facts (MIX-9). */
    var autoHooks: AutoStreamHooks? = null

    private val _buffering = MutableStateFlow<Set<Deck>>(emptySet())
    private val _streaming = MutableStateFlow<Set<Deck>>(emptySet())
    /** Decks waiting for downloaded audio (drives the "Buffering..." indicator). */
    val buffering: StateFlow<Set<Deck>> = _buffering
    /** Decks still playing a file that has not finished downloading (the waveform re-reads on completion). */
    val streaming: StateFlow<Set<Deck>> = _streaming

    // ------------------------------------------------------------------ queries

    fun canStream(songId: String): Boolean = loader?.canStream(songId) == true
    fun isStreaming(deck: Deck): Boolean = s(deck) != null
    /** Full-mix hold, or the stems' own Hold: both are "Buffering...". */
    fun isBuffering(deck: Deck): Boolean = s(deck)?.holding == true || stems?.isHeld(deck) == true
    /** The full mix's playhead is frozen waiting for bytes. */
    fun isHeld(deck: Deck): Boolean = s(deck)?.holding == true
    /** Song ids the decks play from live streams (the loader never evicts these). */
    val streamingSongIds: Set<String> get() = pinned
    @Volatile private var pinned: Set<String> = emptySet()   // snapshot: the loader reads it from its IO thread
    /** Since when (engine clock) a PLAYING deck's hold has lasted; null when not held or not playing. */
    fun heldSinceMs(deck: Deck): Long? =
        s(deck)?.takeIf { it.holding && engine.deckState(deck).isPlaying }?.heldSinceMs

    /** The schedulable frontier (seconds into the song window) of a streaming deck, null otherwise. */
    fun frontierSeconds(deck: Deck): Double? {
        s(deck) ?: return null
        val c = engine.controller(deck)
        if (!c.isOpen) return null
        return (c.endFrame - c.startFrame).toDouble() / c.sampleRate
    }

    private fun stemsActive(deck: Deck) = stems?.active(deck) == true

    // ------------------------------------------------------------------ MainVoiceStatus (for the stem machine)

    override fun endSeconds(deck: Deck): Double {
        val c = engine.controller(deck)
        return if (c.isOpen) (c.endFrame - c.startFrame).toDouble() / c.sampleRate else 0.0
    }
    override fun complete(deck: Deck): Boolean = s(deck) == null && !truncated[deck.ordinal]
    override fun truncated(deck: Deck): Boolean = truncated[deck.ordinal]
    override fun canGrow(deck: Deck): Boolean = s(deck) != null

    // ------------------------------------------------------------------ readiness (Auto-DJ, MIX-9)

    /** STRICT: the deck holds a track that will play through (on-disk file, finished stream, or [StreamRules.AUTO_READY_RUNWAY] ahead). */
    fun deckReadyToAir(deck: Deck): Boolean {
        if (engine.deckState(deck).loaded == null) return false
        val d = s(deck) ?: return engine.controller(deck).isOpen || stemsActive(deck)
        return StreamRules.readyToAir(
            held = d.holding, complete = d.handle.isComplete, frontierSec = frontierSeconds(deck),
            posSec = engine.position(deck), durationSec = engine.duration(deck),
        )
    }

    /** LENIENT: the deck would make sound right now (not holding for bytes). */
    fun deckCanAir(deck: Deck): Boolean {
        if (engine.deckState(deck).loaded == null) return false
        val d = s(deck) ?: return engine.controller(deck).isOpen || stemsActive(deck)
        return !d.holding
    }

    /** Is [songId]'s audio fully on this device (a burn, or a finished stream) - a load of it airs at once. */
    fun songOnDevice(songId: String): Boolean {
        if (hasLocalFile(songId)) return true
        val st = loader?.stream(songId)
        return st != null && st.isComplete && !st.failed
    }

    /** A load of [songId] failed only because the stream gate is closed RIGHT NOW: defer it, don't drop it. */
    fun transientlyUnloadable(songId: String): Boolean {
        val l = loader ?: return false
        return l.isRipped(songId) && !hasLocalFile(songId) && !l.canStream(songId, forAuto = true)
    }

    // ------------------------------------------------------------------ wiring

    /** Hook every engine / stem / loader seam. Existing hooks are chained, never replaced. */
    fun install() {
        engine.streamLoad = { item, deck -> loadStreaming(item, deck) }
        engine.streamHeldProvider = { isHeld(it) }
        val prevTick = engine.onDeckTick
        engine.onDeckTick = { d, p -> onTick(d, p); prevTick?.invoke(d, p) }
        val prevSeek = engine.onSeeked
        engine.onSeeked = { d, sec -> prevSeek?.invoke(d, sec); onSeeked(d, sec) }
        val prevTransport = engine.onTransport
        engine.onTransport = { d, playing -> prevTransport?.invoke(d, playing); onTransport(d, playing) }
        val prevReset = engine.onStemsReset
        engine.onStemsReset = { d -> prevReset?.invoke(d); clearStream(d) }
        stems?.let { sc ->
            sc.main = this
            val prevHold = sc.onHold
            sc.onHold = { d -> prevHold?.invoke(d); publish() }
            val prevUnhold = sc.onUnhold
            sc.onUnhold = { d -> prevUnhold?.invoke(d); onStemsUnhold(d) }
        }
    }

    private fun log(msg: String) {
        DiagLog.shared?.telemetry("mixstream", msg)
        engine.diag("mixstream $msg")
    }

    private fun logError(msg: String) {
        DiagLog.shared?.log("error", "mixstream $msg")
        engine.diag("mixstream ERROR $msg")
    }

    private fun setHolding(deck: Deck, on: Boolean) {
        val d = s(deck) ?: return
        if (d.holding == on) return
        d.holding = on
        // The stall clock measures held-WHILE-PLAYING time only (iOS streamHeldSince).
        d.heldSinceMs = if (on && engine.deckState(deck).isPlaying) engine.nowMs() else null
        publish()
    }

    private fun publish() {
        val b = Deck.entries.filter { isBuffering(it) }.toSet()
        val st = Deck.entries.filter { s(it) != null }.toSet()
        pinned = Deck.entries.mapNotNull { s(it)?.handle?.songId }.toSet()
        if (b != _buffering.value) {
            _buffering.value = b
            // A hold freezes the playhead and a resume restarts it: the system card's rate follows AT ONCE.
            engine.onNowPlayingChanged?.invoke()
        }
        if (st != _streaming.value) _streaming.value = st
    }

    /** Re-publish the Buffering set (the stems' own hold changes outside this class). */
    fun refreshBuffering() = publish()

    // ------------------------------------------------------------------ load

    /**
     * Load [item] onto [deck] as a STREAM. The track takes the deck synchronously with the catalog length as
     * its provisional duration and the playhead HELD until [pumpStream] has enough bytes. False (deck
     * untouched) when the stream gate is closed.
     */
    fun loadStreaming(item: MixLoadable, deck: Deck): Boolean {
        val l = loader ?: return false
        val forAuto = engine.streamingForAuto
        if (!l.canStream(item.songId, forAuto = forAuto)) return false
        val handle = l.open(item.songId, item.title, item.artist, forAuto = forAuto) ?: return false
        engine.beginStreamLoad(deck)     // forgets the prior voice / stem intent (-> clearStream)
        val d = DeckStream(handle)
        d.windowMs = item.lengthMs
        ds[deck.ordinal] = d
        truncated[deck.ordinal] = false
        publish()
        val meta = LoadedTrack(
            songId = item.songId, title = item.title, artist = item.artist, bpm = item.bpm,
            camelot = item.camelot, key = item.key, albumId = item.albumId,
        )
        engine.commitStreamLoad(deck, meta, (item.lengthMs ?: StreamRules.FALLBACK_DURATION_MS) / 1000.0)
        log("deck ${deck.label} load ${item.songId}")
        pumpStream(deck)
        return true
    }

    /** The loader's progress fan-in: pump every deck streaming [songId]. */
    fun streamProgressed(songId: String) {
        for (d in Deck.entries) if (s(d)?.handle?.songId == songId) pumpStream(d)
        publish()
    }

    // ------------------------------------------------------------------ the pump

    /**
     * Extend a streaming deck's playable audio to the new byte frontier: attach the file on the first usable
     * bytes, start / resume a HELD playhead once it has runway, raise the window while running, and hand the
     * deck to the finished file on completion.
     */
    fun pumpStream(deck: Deck) {
        val d = s(deck) ?: return
        val h = d.handle
        if (h.failed) { handleStreamFailure(deck); return }
        if (!h.resolved || !(h.bytesReceived > 0 || h.isComplete)) return
        val c = engine.controller(deck)
        if (!d.attached && !attach(deck, d)) return
        val sr = c.sampleRate
        val start = c.startFrame
        val fullEnd = d.fullEnd
        val complete = h.isComplete
        val frontier = if (complete) fullEnd
        else min(
            min(fullEnd, MixMath.streamPlayableFrames(h.bytesReceived, d.bps, sr.toDouble(), start)),
            // never past what the decoder can actually produce (ID3 / art bytes, VBR intros)
            d.source?.let { start + max(0L, it.availableFrames) } ?: fullEnd,
        )

        if (d.holding) {
            val pos = engine.position(deck)
            val posFrame = start + (pos * sr).toLong()
            val playing = engine.deckState(deck).isPlaying
            if (!StreamRules.canResume(complete, frontier, posFrame, fullEnd, sr, playing)) return
            c.growTo(frontier, final = complete && frontier >= fullEnd)
            setHolding(deck, false)
            if (!stemsActive(deck)) {
                c.seekSeconds(pos)     // reschedule from the held position; a loop on the voice survives the seek
                if (playing && engine.startEngineIfNeeded()) c.play()
            }
            restampAutoEnd(deck)       // the held seconds pushed this deck's end back
            log("deck ${deck.label} ${if (pos > 0.1) "resume" else "start"} ${h.songId} runway=${fmt((frontier - posFrame).toDouble() / sr)}s")
            engine.refreshTransport()
        } else if (frontier > c.endFrame) {
            // Small appends while the runway is short, big ones once it is comfortable.
            val playFrame = start + ((engine.truePlayhead(deck) ?: engine.position(deck)) * sr).toLong()
            val runway = (c.endFrame - playFrame).toDouble() / sr
            val chunk = StreamRules.appendChunk(runway)
            if (!(complete || (frontier - c.endFrame).toDouble() / sr >= chunk)) return
            c.growTo(frontier, final = complete && frontier >= fullEnd)
        }
        if (complete && c.endFrame == fullEnd && !d.holding) finishStream(deck, d)
        stems?.onMainProgressed(deck)   // the full mix's runway grew: a pending handover / stem hold re-checks
    }

    /**
     * First attach: open the growing file once its header (and full-length claim) is readable, install the
     * voice over an EMPTY window at the song's start, and learn the byte rate. False = not yet (or failed).
     */
    private fun attach(deck: Deck, d: DeckStream): Boolean {
        val h = d.handle
        val c = engine.controller(deck)
        val src = sources.open(h)
        if (src == null) {
            if (h.isComplete) handleStreamFailure(deck)   // a finished file that will not open can never play
            return false
        }
        val sr = c.sampleRate
        val voice = Voice(src, sr, name = "deck${deck.label}")
        val startMs = if (h.isCut) null else h.startMs?.toInt()
        val windowMs = if (h.isCut) null else d.windowMs
        val w = LoadWindow.compute(voice.totalFrames, sr, startMs, windowMs)
        if (w == null) {
            runCatching { voice.close() }
            // A complete file with nothing in the window can never play; a partial one just has no frames yet.
            if (h.isComplete) handleStreamFailure(deck)
            return false
        }
        c.open(voice, LoadWindow.Frames(w.startFrame, w.startFrame), final = false)
        d.source = src
        d.attached = true
        d.fullEnd = w.endFrame
        d.bps = MixMath.streamBytesPerSecond(voice.totalFrames, sr.toDouble(), h.expectedBytes)
        engine.updateDeck(deck) { it.copy(startMs = startMs, durationSec = w.count.toDouble() / sr) }
        if (engine.position(deck) > engine.duration(deck)) engine.setPosition(deck, engine.duration(deck))
        return true
    }

    /** The download finished and the whole window is scheduled: the deck is an ordinary file deck now. */
    private fun finishStream(deck: Deck, d: DeckStream) {
        val c = engine.controller(deck)
        d.source?.let { sources.markComplete(it) }
        c.growTo(d.fullEnd, final = true)
        log("deck ${deck.label} complete ${d.handle.songId}")
        clearStream(deck)
    }

    /**
     * The stream died for good. Before any audio: the load failed - drop the track (a live auto deck that
     * never sounded skips ahead). Mid-song: the bytes we have ARE the song - its window ends at the
     * frontier, the deck plays out, the auto end is re-stamped. Under stems: keep whatever full mix arrived,
     * marked TRUNCATED.
     */
    private fun handleStreamFailure(deck: Deck) {
        val d = s(deck) ?: return
        val songId = d.handle.songId
        val c = engine.controller(deck)
        if (stemsActive(deck)) {
            logError("deck ${deck.label} $songId failed - stems carry the deck")
            // the main voice ENDS at its frontier (never underruns forever if the full mix returns)
            if (c.isOpen) c.growTo(c.endFrame, final = true)
            d.source?.let { sources.markComplete(it) }
            clearStream(deck)
            truncated[deck.ordinal] = true
            stems?.mainStreamDied(deck)
            engine.refreshTransport()
            return
        }
        if (!c.isOpen || c.endFrame == c.startFrame) {
            val wasLive = autoHooks?.isLiveDeck(deck) == true && (engine.deckState(deck).isPlaying || d.holding)
            logError("deck ${deck.label} drop $songId - stream failed before audio")
            engine.reportDeckEnded(deck, MixTrackEndReason.STOPPED)   // a dead stream is not the listener skipping it
            engine.ejectDeckCore(deck)
            engine.persist()
            if (wasLive && autoHooks?.isTransitioning != true) autoHooks?.skipToNext(0.5)
            return
        }
        val sr = c.sampleRate
        val end = c.endFrame
        val dur = (end - c.startFrame).toDouble() / sr
        logError("deck ${deck.label} truncate $songId at ${dur.toInt()}s")
        c.growTo(end, final = true)     // the voice now ENDS at the frontier instead of underrunning
        d.source?.let { sources.markComplete(it) }   // drain every byte that arrived
        engine.updateDeck(deck) { it.copy(durationSec = dur) }
        if (d.holding) {
            setHolding(deck, false)
            engine.setPosition(deck, min(engine.position(deck), dur))
        }
        restampAutoEnd(deck)
        clearStream(deck)
    }

    /**
     * Forget a deck's stream bookkeeping (the stream itself keeps downloading - the collection run needs the
     * file either way).
     */
    fun clearStream(deck: Deck) {
        ds[deck.ordinal] = null
        truncated[deck.ordinal] = false   // (a stems-carried failure re-marks it after clearing)
        publish()
    }

    /** Hold a playing streaming deck whose playhead caught the byte frontier (the tick calls this). */
    private fun holdStream(deck: Deck) {
        val d = s(deck) ?: return
        if (d.holding) return
        engine.controller(deck).pause()
        setHolding(deck, true)
        log("deck ${deck.label} underrun at ${fmt(engine.position(deck))}s")
    }

    /** Re-stamp an auto deck's wall-clock end from its live position (held seconds don't count). */
    private fun restampAutoEnd(deck: Deck) {
        if (engine.autoMixing) engine.autoDj?.onSeek(deck)
    }

    // ------------------------------------------------------------------ engine hooks

    /** Per-tick, per-playing-deck, after the playhead advanced. */
    internal fun onTick(deck: Deck, pos: Double) {
        if (s(deck) == null || stemsActive(deck)) return
        val frontier = frontierSeconds(deck) ?: return
        if (StreamRules.shouldHold(frontier, engine.duration(deck), pos)) {
            // The playhead caught the downloaded frontier: hold it there (the pump resumes with runway).
            engine.setPosition(deck, min(pos, frontier))
            holdStream(deck)
            stems?.advance(deck)   // stems waiting with runway carry the deck instead
        }
    }

    /** A seek landed. */
    internal fun onSeeked(deck: Deck, sec: Double) {
        val d = s(deck) ?: return
        if (stemsActive(deck)) return
        val frontier = frontierSeconds(deck) ?: 0.0
        if (d.holding || sec >= frontier - StreamRules.HOLD_EPSILON) {
            // STREAMING past the downloaded frontier: HOLD at the target; the pump resumes the deck there
            // once the bytes arrive (immediately, if they already have).
            engine.controller(deck).pause()
            setHolding(deck, true)
            engine.setPosition(deck, sec)
            pumpStream(deck)
        }
    }

    /** A deck started playing: a held stream may already have the runway a PLAYING deck needs. */
    internal fun onTransport(deck: Deck, playing: Boolean) {
        val d = s(deck) ?: return
        if (!playing) { d.heldSinceMs = null; return }
        if (d.holding) {
            if (d.heldSinceMs == null) d.heldSinceMs = engine.nowMs()   // the stall clock starts at the PLAY
            pumpStream(deck)
        }
    }

    /** The stems took the deck over: their audio is playable, so the full mix's hold clears. */
    private fun onStemsUnhold(deck: Deck) {
        val d = s(deck)
        if (d?.holding == true) {
            setHolding(deck, false)
            restampAutoEnd(deck)
        } else publish()
    }

    private fun fmt(x: Double) = String.format(java.util.Locale.US, "%.1f", x)
}

// ---------------------------------------------------------------------------------------------
// Production adapters

/** [StreamHandle] over a live [MixStreamLoader.Stream]. */
class LoaderStreamHandle(private val s: MixStreamLoader.Stream) : StreamHandle {
    override val songId: String get() = s.songId
    override val resolved: Boolean get() = s.resolved
    override val bytesReceived: Long get() = s.bytesReceived
    override val expectedBytes: Long? get() = s.expectedBytes
    override val isComplete: Boolean get() = s.isComplete
    override val failed: Boolean get() = s.failed
    override val isCut: Boolean get() = s.isCut
    override val startMs: Long? get() = s.startMs
    override val file: File? get() = s.finalFile ?: s.file
}

/** [StreamLoaderPort] over the real loader. */
class MixStreamLoaderPort(private val loader: MixStreamLoader) : StreamLoaderPort {
    override fun canStream(songId: String, forAuto: Boolean) = loader.canStream(songId, forAuto)
    override fun isRipped(songId: String) = loader.isRipped(songId)
    override fun open(songId: String, title: String, artist: String, forAuto: Boolean) =
        loader.open(songId, title, artist, forAuto)?.let(::LoaderStreamHandle)
    override fun stream(songId: String) = loader.stream(songId)?.let(::LoaderStreamHandle)
}

/** The MediaCodec mp3 decoder over a growing file (device-verified). A moved file keeps its length via [MonotonicByteSource]. */
class Mp3StreamSourceFactory : StreamSourceFactory {
    override fun open(h: StreamHandle): PcmSource? {
        val f = h.file ?: return null
        val dec = runCatching {
            Mp3Decoder(MonotonicByteSource(FileByteSource(f)), complete = h.isComplete, expectedBytes = h.expectedBytes)
        }.getOrNull()
            ?: return null
        // The header (and its full-length claim) must be readable now; a headerless partial retries later.
        if (dec.totalFrames <= 0) { runCatching { dec.close() }; return null }
        return dec
    }

    override fun markComplete(src: PcmSource) { (src as? Mp3Decoder)?.markComplete() }
}
