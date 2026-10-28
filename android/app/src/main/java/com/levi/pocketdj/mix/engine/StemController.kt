package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.ByteSource
import com.levi.pocketdj.audio.core.FileByteSource
import com.levi.pocketdj.audio.core.Mp3Decoder
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.diag.DiagLog
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.stream.MixStreamLoader
import com.levi.pocketdj.mix.store.DeckSnapshot
import com.levi.pocketdj.mix.store.MixEventKind
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** A deck's pending voice handover. nil = the deck sits on the voice its intent asks for. */
enum class StemHandover {
    /** Stems asked for; the full mix stays on air until they have runway. */
    TO_STEMS,
    /** Stems released; they stay on air until the full mix has runway. */
    TO_FULL_MIX,
}

/** How far a wired stem set reaches: [frontierSec] null = complete files; [endSec] = playable seconds from 0:00. */
data class StemReach(val frontierSec: Double?, val endSec: Double)

/** Pure zero-dead-air decisions (iOS `StemSync` / `MixEngine` statics). */
object StemRules {
    /** Seconds of runway a STILL-ARRIVING source needs past the playhead before a handover onto it. */
    const val HANDOVER_RUNWAY = 4.0
    /** The handover crossfade (LINEAR: the stems sum back to the full mix, equal-power would bump +3 dB). */
    const val HANDOVER_FADE = 0.06
    /** Partial stems hand back to the full mix this far before their frontier. */
    const val UNDERRUN_LEAD = 1.0
    /** Group starts are placed this far out so every voice is primed before its first sample is due. */
    const val START_LEAD = 0.06
    /** A stalled audible crossfade is abandoned after this long (the sink stopped under it). */
    const val FADE_STUCK_MS = 2000L

    /**
     * Does a source with [runway] seconds past the playhead qualify for a handover? A complete source
     * needs only to cover the playhead; a still-arriving one needs [HANDOVER_RUNWAY] - or whatever is
     * left of the song, near its end.
     */
    fun handoverReady(runway: Double, complete: Boolean, songLeft: Double): Boolean {
        if (!(runway > 0.05)) return false
        if (complete) return true
        return runway >= min(HANDOVER_RUNWAY, max(0.05, songLeft - 0.05))
    }

    /** Where a song ends when neither voice can grow: the longer of the two audios. */
    fun deadSourceEnd(mainEnd: Double, stemsWired: Boolean, stemsEnd: Double): Double =
        max(mainEnd, if (stemsWired) stemsEnd else 0.0)

    /** Per-stem balance in [BurnFileNames.STEM_NAMES] order: muted = 0, else the stem volume (default 1). */
    fun balance(muted: Set<String>, vol: Map<String, Double>): FloatArray =
        FloatArray(BurnFileNames.STEM_NAMES.size) { i ->
            val n = BurnFileNames.STEM_NAMES[i]
            if (n in muted) 0f else (vol[n] ?: 1.0).coerceIn(0.0, 1.0).toFloat()
        }

    /** What partial stems on air should do as they near their frontier. */
    sealed class Underrun {
        /** Nothing to do yet. */
        object None : Underrun()
        /** Hand back to the full mix; [reengage] keeps the stem intent pending (their stream is alive). */
        data class CutToFullMix(val reengage: Boolean) : Underrun()
        /** Neither voice has audio here but one can still grow: hold; [toStems] = the stems' pump resumes it. */
        data class Hold(val toStems: Boolean) : Underrun()
        /** Neither voice can grow: the song ends where its audio does. */
        object EndSong : Underrun()
    }

    fun stemUnderrun(
        pos: Double, stemEnd: Double, songEnd: Double,
        mainReady: Boolean, stemStreamAlive: Boolean, handoverToFullMix: Boolean,
        mainCanGrow: Boolean,
    ): Underrun {
        if (!(stemEnd < songEnd - 0.05 && pos >= stemEnd - UNDERRUN_LEAD)) return Underrun.None
        val wantStems = stemStreamAlive && !handoverToFullMix
        if (mainReady) return Underrun.CutToFullMix(reengage = wantStems)
        if (pos < stemEnd - 0.05) return Underrun.None   // the stems still have audio - play it out
        if (!mainCanGrow && !stemStreamAlive) return Underrun.EndSong
        return Underrun.Hold(toStems = stemStreamAlive && (wantStems || !mainCanGrow))
    }

    sealed class MainUnderrun {
        object None : MainUnderrun()
        object CutToStems : MainUnderrun()
        object Hold : MainUnderrun()
        object EndSong : MainUnderrun()
    }

    /** A TRUNCATED full mix (its stream died) under the playhead: hand over to stems / hold / end. */
    fun mainUnderrun(
        pos: Double, mainEnd: Double, songEnd: Double,
        stemsReady: Boolean, stemsComing: Boolean,
    ): MainUnderrun {
        if (!(mainEnd < songEnd - 0.05 && pos >= mainEnd - UNDERRUN_LEAD)) return MainUnderrun.None
        if (stemsReady) return MainUnderrun.CutToStems
        if (pos < mainEnd - 0.05) return MainUnderrun.None
        return if (stemsComing) MainUnderrun.Hold else MainUnderrun.EndSong
    }
}

/**
 * Maps a stem part's own frames onto the MAIN voice's file-frame domain: stem voice frame
 * `shift + t` plays stem frame `t`. Stems start at the SONG's 0:00 while an analog album side's main
 * voice starts at the song's offset into the side; sharing one frame domain lets the graph's handover
 * (seek incoming to outgoing's exact frame, alignment check) work without knowing about offsets.
 * [shift] is in THIS source's frames.
 */
class ShiftedSource(private val src: PcmSource, private val shift: Long) : PcmSource {
    override val sampleRate: Int get() = src.sampleRate
    override val channels: Int get() = src.channels
    override val totalFrames: Long get() = src.totalFrames.let { if (it < 0) it else it + shift }
    override val isComplete: Boolean get() = src.isComplete
    override val availableFrames: Long get() = src.availableFrames + shift
    override fun seek(frame: Long) = src.seek(max(0L, frame - shift))
    override fun read(dst: FloatArray, frames: Int): Int = src.read(dst, frames)
    override fun close() = src.close()
}

/** Four opened stem parts, in [BurnFileNames.STEM_NAMES] order. */
class StemParts(
    val sources: List<PcmSource>,
    /** Whole files (not a growing stream). */
    val complete: Boolean,
    val release: AutoCloseable? = null,
)

/** A song's four stems streaming together. */
interface StemStream {
    val songId: String
    val failed: Boolean
    val complete: Boolean
    /** Growing sources once EVERY part has decodable audio; the same instances on repeat calls; null until then. */
    fun parts(): List<PcmSource>?
    /** Stop pulling bytes (the transfer ends unless another owner holds the set). */
    fun cancel()
}

/** Where a deck finds its stems: on disk, as a stream, or fetched whole. */
interface StemProvider {
    /** All four stems on disk, opened; null when not (fully) burned. */
    fun local(songId: String): StemParts?
    /**
     * Do [local]'s slow work (open + measure four mp3s) AHEAD of time. Blocking: callers run it off the
     * main thread; a later [local] on main then returns the warmed parts instantly. Default: nothing to warm.
     */
    fun prewarm(songId: String) {}
    fun canStream(songId: String): Boolean
    fun openStream(songId: String, owner: String): StemStream?
    /** Fetch the stems whole (no streaming available); true when all four are now on disk. */
    suspend fun fetchWhole(songId: String): Boolean
}

/** What the full-mix voice looks like to the stem machine (MIX-10 streaming fills the real thing). */
interface MainVoiceStatus {
    /** Where the full mix's schedulable audio ends (song seconds). */
    fun endSeconds(deck: Deck): Double
    /** All there: not still downloading and not cut short by a dead stream. */
    fun complete(deck: Deck): Boolean
    /** The full mix's stream DIED mid-song; [endSeconds] is its last frame for good. */
    fun truncated(deck: Deck): Boolean
    /** Its stream is alive and can still deliver more. */
    fun canGrow(deck: Deck): Boolean
}

/** A fully on-disk full mix: ends with the window, can never be truncated. */
class CompleteFileMain(private val core: EngineCore) : MainVoiceStatus {
    override fun endSeconds(deck: Deck) = core.duration(deck)
    override fun complete(deck: Deck) = true
    override fun truncated(deck: Deck) = false
    override fun canGrow(deck: Deck) = false
}

/**
 * Per-deck stem decks with the zero-dead-air HANDOVER (port of iOS `MixEngine` stems + `StemSync`).
 *
 * CARDINAL RULE: the on-air deck never goes silent because of an ENGINE transition. Switching a deck
 * between its full mix and its stems is a handover, not a stop/start: the outgoing voice keeps playing
 * until the incoming one is wired AND has runway past the playhead, then the two cross over
 * sample-aligned under a 60 ms LINEAR fade ([com.levi.pocketdj.mix.graph.MixGraph.crossfadeTo]). Stems
 * not on disk stream (or are fetched) while the full mix plays on, and the intent
 * ([handovers]) is the deck's "Loading stems..." state; a failed fetch, a toggle back, a track change
 * or an eject drops it. Every intent change bumps a generation; an async completion that finds its
 * generation stale touches nothing.
 *
 * Main thread only. Voice-level mechanics (the group, shifted sources, loops) live on
 * [DeckController]; the gain state machine lives in the graph's `Handover`.
 */
class StemController(
    private val core: EngineCore,
    private val provider: StemProvider,
    private val runner: VoiceRunner,
    private val scope: CoroutineScope,
    var main: MainVoiceStatus = CompleteFileMain(core),
) {
    private class Fade(val gen: Int, val toStems: Boolean, val startedMs: Long)

    private class DeckStems {
        var handover: StemHandover? = null
        var gen = 0
        var fetch: Job? = null
        var stream: StemStream? = null
        /** The raw (unshifted) sources behind the wired group. */
        var parts: List<PcmSource>? = null
        var frontierSec: Double? = null
        var endSec = 0.0
        var release: AutoCloseable? = null
        var deferred = false
        var held = false
        var fade: Fade? = null
        val wired: Boolean get() = parts != null
    }

    private val st = arrayOf(DeckStems(), DeckStems())
    private fun s(d: Deck) = st[d.ordinal]
    private val sr: Int get() = core.graph.sampleRate

    /** The loop controller (set at wiring); the stems follow a live loop and must hold its window. */
    var loops: LoopController? = null
    /** Where [prewarm] runs (off the main thread). */
    var prewarmContext: kotlin.coroutines.CoroutineContext = kotlinx.coroutines.Dispatchers.IO
    /** Holds owned by OTHER sources (MIX-10): a held deck is waiting for bytes. */
    var streamHeld: (Deck) -> Boolean = { false }
    /** A held/streaming deck un-holds because the stems carry it now (MIX-10 clears its hold). */
    var onUnhold: ((Deck) -> Unit)? = null
    /** The song got shorter than catalogued (no voice can grow): the auto end must be re-stamped. */
    var onDurationShortened: ((Deck) -> Unit)? = null

    private val _handovers = MutableStateFlow<Map<Deck, StemHandover>>(emptyMap())
    /** Pending handovers (drives the "Loading stems..." capsule + the Stems button spinner). */
    val handovers: StateFlow<Map<Deck, StemHandover>> = _handovers

    // ------------------------------------------------------------------ readers

    fun handover(deck: Deck): StemHandover? = s(deck).handover
    /** Stem mode is ON: on stems, or loading them (a pending handover onto them), and not on its way back. */
    fun modeOn(deck: Deck): Boolean = when (s(deck).handover) {
        StemHandover.TO_STEMS -> true
        StemHandover.TO_FULL_MIX -> false
        null -> core.deckState(deck).stemMode
    }
    /** Stem mode is ON and the four stems are wired (playback actually routes to stems). */
    fun active(deck: Deck): Boolean = core.deckState(deck).stemMode && s(deck).wired
    fun isMuted(name: String, deck: Deck) = name in core.deckState(deck).stemMuted
    fun volume(name: String, deck: Deck) = core.deckState(deck).stemVol[name] ?: 1.0
    fun reach(deck: Deck): StemReach? = s(deck).takeIf { it.wired }?.let { StemReach(it.frontierSec, it.endSec) }
    fun isHeld(deck: Deck): Boolean = s(deck).held
    fun intentGen(deck: Deck): Int = s(deck).gen
    fun isFetching(deck: Deck): Boolean = s(deck).fetch?.isActive == true
    fun isStreaming(deck: Deck): Boolean = s(deck).stream != null
    fun fadeInFlight(deck: Deck): Boolean = s(deck).fade != null

    private fun log(msg: String) {
        DiagLog.shared?.telemetry("mixstems", msg)
        core.diag("mixstems $msg")
    }

    private fun setHandover(deck: Deck, h: StemHandover?) {
        s(deck).handover = h
        _handovers.value = Deck.entries.mapNotNull { d -> s(d).handover?.let { d to it } }.toMap()
    }

    // ------------------------------------------------------------------ intent

    /** Ask for the deck's stems (on) or its full mix (off). Idempotent; a later call supersedes a pending one. */
    fun setStemMode(on: Boolean, deck: Deck) = applyStemIntent(on, deck, deferSourceUntilPlay = false)

    /**
     * Records INTENT; the audio follows under the zero-dead-air rule. Stems on disk with the deck paused
     * switch at once; on a playing deck the full mix crosses over; stems NOT on disk stream/fetch while the
     * full mix plays and are taken over once they have runway. [deferSourceUntilPlay] (restore): stems not
     * on disk are only streamed once the deck first plays.
     */
    fun applyStemIntent(on: Boolean, deck: Deck, deferSourceUntilPlay: Boolean) {
        val loaded = core.deckState(deck).loaded ?: return
        val d = s(deck)
        d.gen++                                  // every in-flight fetch for the old intent is stale
        d.fetch?.cancel(); d.fetch = null
        d.deferred = false
        if (on != modeOn(deck)) core.rec(MixEventKind.StemMode, deck, flag = on)   // the gesture, not the eventual handover
        if (on) {
            if (active(deck)) {
                if (d.handover != null) { setHandover(deck, null); core.persist() }   // already on stems: just stay
                return
            }
            setHandover(deck, StemHandover.TO_STEMS)
            log("deck ${deck.label} request ${loaded.songId}")
            if (!d.wired || (d.frontierSec != null && d.stream == null)) {
                if (deferSourceUntilPlay && !core.deckState(deck).isPlaying) {
                    if (!wireStems(deck)) d.deferred = true
                } else requestStemSource(deck)
            }
            advance(deck)
        } else {
            if (!active(deck)) dropPending(deck)   // never got onto stems: the full mix simply carries on
            else { setHandover(deck, StemHandover.TO_FULL_MIX); advance(deck) }
        }
        core.persist()
    }

    fun toggleStemMute(name: String, deck: Deck) {
        core.updateDeck(deck) {
            it.copy(stemMuted = if (name in it.stemMuted) it.stemMuted - name else it.stemMuted + name)
        }
        applyStemGains(deck)
        core.rec(MixEventKind.StemMute, deck, param = name, flag = isMuted(name, deck))
        core.persist()
    }

    fun setStemVolume(name: String, v: Double, deck: Deck) {
        core.updateDeck(deck) { it.copy(stemVol = it.stemVol + (name to v.coerceIn(0.0, 1.0))) }
        applyStemGains(deck)
        core.rec(MixEventKind.StemVolume, deck, param = name, value = volume(name, deck))
        core.persist(debounced = true)
    }

    private fun applyStemGains(deck: Deck) {
        val ds = core.deckState(deck)
        core.params.setStemBalance(deck, StemRules.balance(ds.stemMuted, ds.stemVol))
    }

    /** Durable-session restore: balance + mode (a deferred source waits for the first play). */
    fun restore(deck: Deck, ds: DeckSnapshot) {
        core.updateDeck(deck) { it.copy(stemMuted = ds.stemMuted.toSet(), stemVol = ds.stemVol) }
        applyStemGains(deck)
        if (ds.stemMode) applyStemIntent(true, deck, deferSourceUntilPlay = true)
    }

    /** Forget a deck's stem INTENT entirely (track change / eject): stale every in-flight fetch, unwire. */
    fun reset(deck: Deck) {
        val d = s(deck)
        d.gen++
        d.fetch?.cancel(); d.fetch = null
        setHandover(deck, null)
        d.deferred = false
        d.held = false
        unwire(deck)
    }

    // ------------------------------------------------------------------ finding the stems

    /** Wire stems for a `.toStems` request: disk -> wired now; streamable -> open the stream; else fetch whole. */
    private fun requestStemSource(deck: Deck) {
        val songId = core.deckState(deck).loaded?.songId ?: return
        val d = s(deck)
        if (wireStems(deck)) return
        if (provider.canStream(songId)) {
            provider.openStream(songId, owner(deck))?.let { stream ->
                d.stream = stream
                pumpStems(deck)
                return
            }
        }
        val gen = d.gen
        d.fetch = scope.launch {
            val ok = provider.fetchWhole(songId)
            // A completion for a superseded request (toggled off, new track, ejected) never claims the deck.
            if (d.gen != gen || core.deckState(deck).loaded?.songId != songId || d.handover != StemHandover.TO_STEMS) return@launch
            d.fetch = null
            if (ok && wireStems(deck)) advance(deck)
            else {
                log("deck ${deck.label} unavailable $songId - full mix stays")
                dropPending(deck)
                core.persist()
            }
        }
    }

    /**
     * A deck loaded this song: open + measure its on-disk stems on a background thread so the main-thread
     * [StemProvider.local] at toggle / restore time is instant (it walks four multi-MB mp3s otherwise).
     */
    fun prewarm(songId: String) {
        scope.launch(prewarmContext) { runCatching { provider.prewarm(songId) } }
    }

    private fun owner(deck: Deck) = "mix-${deck.label}"

    /** Open the deck track's four on-disk stems and wire them. False when not stem-burned locally. */
    private fun wireStems(deck: Deck): Boolean {
        val songId = core.deckState(deck).loaded?.songId ?: return false
        val parts = provider.local(songId) ?: return false
        if (!wire(deck, parts)) { runCatching { parts.release?.close() }; return false }
        releaseStemStream(deck)               // complete files on disk supersede a stem stream
        return true
    }

    /**
     * Build the four stem voices over [parts] (shifted into the main voice's frame domain), install the
     * group, and park it paused at the deck's playhead. Priming needs no handling here: the Android mp3
     * decoder applies the untagged-stem 576-sample priming itself, so a stem frame IS a song frame.
     */
    private fun wire(deck: Deck, parts: StemParts): Boolean {
        val c = core.controller(deck)
        if (!c.isOpen || parts.sources.size != BurnFileNames.STEM_NAMES.size) return false
        val d = s(deck)
        if (d.wired) unwire(deck)
        val voices = parts.sources.mapIndexed { i, src ->
            val shift = Math.round(c.startFrame.toDouble() * src.sampleRate / sr)
            Voice(ShiftedSource(src, shift), sr, name = "stem-${deck.label}-${BurnFileNames.STEM_NAMES[i]}")
        }
        c.installStems(VoiceGroup(voices))
        d.parts = parts.sources
        d.release = parts.release
        d.frontierSec = if (parts.complete) null else frontierOf(parts.sources)
        d.endSec = reachOf(parts.sources, parts.complete)
        val from = core.position(deck).let { if (d.frontierSec == null) min(it, maxStemSeconds(deck)) else it }
        scheduleStems(deck, from)
        applyStemGains(deck)
        return true
    }

    /** Tear down a deck's stem wiring: group out of the graph, stream cancelled, scope released. */
    private fun unwire(deck: Deck) {
        val d = s(deck)
        settleStemFade(deck)
        val wasWired = d.wired
        core.controller(deck).removeStems()
        d.parts = null
        d.frontierSec = null
        d.endSec = 0.0
        releaseStemStream(deck)
        runCatching { d.release?.close() }; d.release = null
        if (wasWired) core.graph.deck(deck).handover.settle(false)   // the full mix is the voice of record again
    }

    private fun releaseStemStream(deck: Deck) {
        val stream = s(deck).stream ?: return
        s(deck).stream = null
        if (!stream.complete) log("deck ${deck.label} cancel stem stream ${stream.songId}")
        stream.cancel()
    }

    /** Drop a `.toStems` request (failed, superseded, toggled off): unwire stems that never went on air. */
    private fun dropPending(deck: Deck) {
        val d = s(deck)
        setHandover(deck, null)
        d.fetch?.cancel(); d.fetch = null
        d.deferred = false
        if (!active(deck)) unwire(deck)
    }

    // ------------------------------------------------------------------ streaming

    /** The loader's stem fan-in: pump every deck waiting on / playing [songId]'s stem stream. */
    fun streamProgressed(songId: String) {
        for (d in Deck.entries) if (s(d).stream?.songId == songId) pumpStems(d)
    }

    /** The full mix's stream moved (MIX-10): a held deck / pending handover re-checks its runway. */
    fun onMainProgressed(deck: Deck) {
        if (s(deck).handover != null) advance(deck)
        releaseHoldIfRunway(deck)
    }

    private fun frontierOf(srcs: List<PcmSource>): Double =
        srcs.minOf { it.availableFrames.coerceAtLeast(0) }.toDouble() / srcs[0].sampleRate

    private fun reachOf(srcs: List<PcmSource>, complete: Boolean): Double {
        if (!complete) return frontierOf(srcs)
        val totals = srcs.map { if (it.totalFrames > 0) it.totalFrames else it.availableFrames }
        return totals.min().toDouble() / srcs[0].sampleRate
    }

    /**
     * Extend a deck's STREAMING stems to the new frontier: wire the four parts once each has a decodable
     * frame, raise all four voices' windows in lockstep (the same seconds on every part, so they stay
     * locked), and let a pending handover re-check its runway. A failed set: a pending request drops (the
     * full mix never stopped); stems already on air hand back to it.
     */
    fun pumpStems(deck: Deck) {
        val d = s(deck)
        val stream = d.stream ?: return
        if (stream.failed) {
            d.stream = null   // the leftover frontier keeps bounding what is scheduled
            core.diag("mixstems deck ${deck.label} stem stream failed ${stream.songId}")
            if (!active(deck)) dropPending(deck)
            else if (!main.truncated(deck)) { setHandover(deck, StemHandover.TO_FULL_MIX); advance(deck) }
            settleDeadSources(deck)
            return
        }
        if (!d.wired) {
            val ps = stream.parts() ?: return
            if (frontierOf(ps) <= 0.05) return
            if (!wire(deck, StemParts(ps, complete = false))) return
        }
        growWindow(deck, stream)
        if (stream.complete && d.stream === stream) finishStemStream(deck)
        releaseHoldIfRunway(deck)
        advance(deck)
    }

    private fun growWindow(deck: Deck, stream: StemStream) {
        val d = s(deck)
        val srcs = d.parts ?: return
        val g = core.controller(deck).stems ?: return
        val shift = core.controller(deck).startFrame
        val complete = stream.complete
        val endSec = reachOf(srcs, complete)
        d.frontierSec = if (complete) d.frontierSec else frontierOf(srcs)
        if (endSec > d.endSec || complete) d.endSec = max(d.endSec, endSec)
        val frame = min(shift + Math.round(endSec * sr), core.controller(deck).endFrame)
        for (v in g.voices) v.append(frame, final = complete)
    }

    /** The deck's stem stream completed: its stems are ordinary complete files now. */
    private fun finishStemStream(deck: Deck) {
        val d = s(deck)
        d.stream = null
        d.frontierSec = null
    }

    // ------------------------------------------------------------------ the handover decision

    /**
     * The single decision point: does the deck's pending handover have what it needs NOW? Called on every
     * event that can change the answer (the request, a pump, a fetch, a seek, the tick). Idempotent; never
     * stops a voice that has no successor with runway. ONE FADE AT A TIME: while a crossfade is in flight
     * this leaves the intent where it is (the landing re-runs it).
     */
    fun advance(deck: Deck) {
        val d = s(deck)
        val h = d.handover ?: return
        if (core.deckState(deck).loaded == null || d.fade != null) return
        val pos = core.position(deck)
        val dur = core.duration(deck)
        when (h) {
            StemHandover.TO_STEMS -> {
                if (!d.wired) return   // still streaming its first frames / fetching
                if (d.frontierSec == null && !core.deckState(deck).isPlaying) { cutToStems(deck); return }
                val ready = StemRules.handoverReady(
                    runway = (d.frontierSec ?: d.endSec) - pos, complete = d.frontierSec == null, songLeft = dur - pos,
                )
                if (!ready) {
                    // Complete stems that cannot cover the playhead never will: give up, the full mix plays on.
                    if (d.frontierSec == null && d.stream == null) dropPending(deck)
                    return
                }
                // A LOOPING deck follows onto its stems: they must hold the whole window.
                loops?.loopWindow(deck)?.let { if (!loops!!.schedulableOnStems(deck, it)) return }
                cutToStems(deck)
            }
            StemHandover.TO_FULL_MIX -> {
                if (!StemRules.handoverReady(main.endSeconds(deck) - pos, main.complete(deck), dur - pos)) return
                cutToFullMix(deck)
                // The user is done with these stems: stop downloading them (what arrived stays wired).
                releaseStemStream(deck)
            }
        }
    }

    /** The longest position at which a schedule still gets real audio: just inside the SHORTEST wired stem. */
    private fun maxStemSeconds(deck: Deck): Double = max(0.0, s(deck).endSec - 0.05)

    /** Position the (paused) stem group at [fromSec]. False when nothing is schedulable there. */
    private fun scheduleStems(deck: Deck, fromSec: Double): Boolean {
        val c = core.controller(deck)
        val g = c.stems ?: return false
        val d = s(deck)
        val shift = c.startFrame
        val endF = min(shift + Math.round(d.endSec * sr), c.endFrame)
        val from = c.frameFor(max(0.0, fromSec))
        if (from >= endF) return false
        for (v in g.voices) v.schedule(from, endF, final = d.frontierSec == null)
        return true
    }

    private fun commitStemMode(deck: Deck, on: Boolean) {
        core.updateDeck(deck) { it.copy(stemMode = on) }
        setHandover(deck, null)
        applyStemGains(deck)
        core.persist()
    }

    private fun mainAudible(deck: Deck): Boolean {
        val v = core.controller(deck).voice ?: return false
        return v.isPlaying && v.status == Voice.Status.PLAYING
    }

    private fun stemsAudible(deck: Deck): Boolean {
        val v = core.controller(deck).stems?.voices?.get(0) ?: return false
        return v.isPlaying && v.status == Voice.Status.PLAYING
    }

    /**
     * FULL MIX -> STEMS at the playhead. A deck audibly rendering its full mix crosses over (the graph
     * seeks the stems to the main voice's exact frame ~250 ms out and fades 60 ms, linear); a silent deck
     * (paused, cued, held) switches outright. Schedule BEFORE silencing anything: failing to schedule must
     * leave the deck on its full mix, never scheduled-but-unstarted.
     */
    private fun cutToStems(deck: Deck) {
        settleStemFade(deck)
        val c = core.controller(deck)
        val d = s(deck)
        if (c.stems == null) { dropPending(deck); return }
        val pos = core.position(deck)
        val loopW = loops?.loopWindow(deck)
        if (loopW != null && loops?.schedulableOnStems(deck, loopW) != true) return
        val audible = core.deckState(deck).isPlaying && core.isRendering && !streamHeld(deck) && mainAudible(deck)
        var from = pos
        if (!audible) {
            // Clamp just inside the shortest stem so an end-of-track playhead still lands on real audio.
            from = if (d.frontierSec == null) min(pos, maxStemSeconds(deck)) else pos
            if (!scheduleStems(deck, from)) { dropPending(deck); return }
        }
        loopW?.let { c.setLoopSeconds(it, includeStems = true) }   // a live loop follows the deck onto its stems
        val gen = core.graph.crossfadeTo(deck, toStems = true, forceOutright = !audible)
        if (!audible) {
            c.stems?.seekAll(c.frameFor(from))                     // the graph's stamp may be stale on an idle sink
            if (isHeldHere(deck)) { d.held = false; onUnhold?.invoke(deck) }
        } else d.fade = Fade(gen, true, core.nowMs())
        commitStemMode(deck, true)
        log("deck ${deck.label} -> stems @${fmt(pos)}s")
    }

    /** STEMS -> FULL MIX at the playhead: [cutToStems] mirrored. */
    private fun cutToFullMix(deck: Deck) {
        settleStemFade(deck)
        val c = core.controller(deck)
        val v = c.voice ?: run { dropPending(deck); return }
        val pos = core.position(deck)
        val audible = core.deckState(deck).isPlaying && core.isRendering && stemsAudible(deck)
        loops?.loopWindow(deck)?.let { c.setLoopSeconds(it, includeStems = false) }
        val gen = core.graph.crossfadeTo(deck, toStems = false, forceOutright = !audible)
        if (!audible) v.seek(c.frameFor(pos))
        else s(deck).fade = Fade(gen, false, core.nowMs())
        commitStemMode(deck, false)
        log("deck ${deck.label} -> full mix @${fmt(pos)}s")
    }

    private fun isHeldHere(deck: Deck) = s(deck).held || streamHeld(deck)

    /**
     * Land an in-flight crossfade NOW. Every path that stops, re-schedules or pauses a deck's voices calls
     * this first, so no transport action ever sees a half-faded deck. If the incoming side is not
     * rendering yet (still inside its start lead), landing would silence the deck: the fade is UNDONE
     * instead (the outgoing voice keeps the deck) and the intent is re-queued.
     */
    fun settleStemFade(deck: Deck) {
        val d = s(deck)
        val f = d.fade ?: return
        d.fade = null
        val c = core.controller(deck)
        val h = core.graph.deck(deck).handover
        val incomingPlaying = if (f.toStems) stemsAudible(deck) else mainAudible(deck)
        if (incomingPlaying) {
            h.settle(f.toStems)
            if (f.toStems) c.voice?.pause() else c.stems?.pauseAll()
        } else {
            h.settle(!f.toStems)
            if (f.toStems) c.stems?.pauseAll() else c.voice?.pause()
            core.updateDeck(deck) { it.copy(stemMode = !f.toStems) }
            setHandover(deck, if (f.toStems) StemHandover.TO_STEMS else StemHandover.TO_FULL_MIX)
        }
    }

    /** Land / abort bookkeeping for the audible crossfade in flight (tick). */
    private fun checkFade(deck: Deck) {
        val d = s(deck)
        val f = d.fade ?: return
        val h = core.graph.deck(deck).handover
        when {
            h.landedGen >= f.gen -> { d.fade = null; advance(deck) }
            h.abortedGen >= f.gen -> {
                // The incoming side was not where the outgoing one is: the graph kept the old side on air.
                d.fade = null
                core.updateDeck(deck) { it.copy(stemMode = !f.toStems) }
                setHandover(deck, if (f.toStems) StemHandover.TO_STEMS else StemHandover.TO_FULL_MIX)
                log("deck ${deck.label} handover aborted - retry")
            }
            core.nowMs() - f.startedMs > StemRules.FADE_STUCK_MS -> settleStemFade(deck)
        }
    }

    // ------------------------------------------------------------------ engine hooks

    /** Transport edge (engine hook). */
    fun onTransport(deck: Deck, playing: Boolean) {
        val d = s(deck)
        if (!playing) { settleStemFade(deck); return }
        if (d.deferred && core.deckState(deck).loaded != null) {
            d.deferred = false
            requestStemSource(deck)
            advance(deck)
        }
    }

    /** A seek landed (engine hook; a looped deck's loop handles it instead). */
    fun onSeeked(deck: Deck, sec: Double) {
        val d = s(deck)
        settleStemFade(deck)
        // STREAMING stems that do not reach the target yet: the seek lands on the full mix and the stems
        // re-engage once they have runway - a stem seek past the frontier would schedule nothing (dead air).
        val fr = d.frontierSec
        if (active(deck) && fr != null &&
            !StemRules.handoverReady(fr - sec, false, core.duration(deck) - sec)
        ) {
            val c = core.controller(deck)
            c.stems?.pauseAll()
            core.graph.deck(deck).handover.settle(false)
            if (core.deckState(deck).isPlaying) c.voice?.play()
            core.updateDeck(deck) { it.copy(stemMode = false) }
            setHandover(deck, if (d.stream != null && d.handover != StemHandover.TO_FULL_MIX) StemHandover.TO_STEMS else null)
        }
        advance(deck)
    }

    /** Per-tick checks for a playing deck (engine hook). */
    fun onTick(deck: Deck, pos: Double) {
        val d = s(deck)
        checkFade(deck)
        if (d.stream != null) pumpStems(deck)
        if (d.fade == null) {
            if (active(deck)) stemUnderrun(deck, pos) else mainUnderrun(deck, pos)
            if (d.handover != null) advance(deck)
        }
    }

    // ------------------------------------------------------------------ underruns

    /**
     * Partial stems on air are running out: hand back to the full mix while they still have audio to
     * crossfade out of, keeping the stem intent pending while their stream is alive so they re-engage with
     * runway. With no full-mix runway either, play the stems out to their frontier, then HOLD (Buffering...)
     * until a voice that can grow gets runway; with neither able to grow, the song ends there.
     */
    private fun stemUnderrun(deck: Deck, pos: Double) {
        val d = s(deck)
        if (d.frontierSec == null) return
        if (loops?.loopWindow(deck) != null) return   // a looping deck never underruns: its stems hold the window
        if (d.stream != null) pumpStems(deck)         // bytes that landed since may already cover it
        if (!active(deck) || d.fade != null) return
        val end = d.frontierSec ?: return
        val songEnd = core.duration(deck)
        val ready = StemRules.handoverReady(main.endSeconds(deck) - pos, main.complete(deck), songEnd - pos)
        when (val a = StemRules.stemUnderrun(
            pos, end, songEnd, ready, d.stream != null, d.handover == StemHandover.TO_FULL_MIX, main.canGrow(deck),
        )) {
            StemRules.Underrun.None -> {}
            is StemRules.Underrun.CutToFullMix -> {
                log("deck ${deck.label} stem underrun at ${fmt(pos)}s -> full mix")
                cutToFullMix(deck)
                if (a.reengage) setHandover(deck, StemHandover.TO_STEMS)   // the intent stands
            }
            is StemRules.Underrun.Hold -> {
                log("deck ${deck.label} stem underrun at ${fmt(pos)}s -> hold")
                if (a.toStems) setHandover(deck, StemHandover.TO_STEMS)
                core.setPosition(deck, min(pos, end))
                d.held = true
            }
            StemRules.Underrun.EndSong -> settleDeadSources(deck)
        }
    }

    /** The full mix carries the deck but its audio ENDS short of the song (its stream died). */
    private fun mainUnderrun(deck: Deck, pos: Double) {
        val d = s(deck)
        if (!main.truncated(deck) || active(deck) || d.fade != null || loops?.loopWindow(deck) != null) return
        val stemsReady = d.wired && StemRules.handoverReady(
            (d.frontierSec ?: d.endSec) - pos, d.frontierSec == null, core.duration(deck) - pos,
        )
        val coming = d.stream != null || d.fetch?.isActive == true
        when (StemRules.mainUnderrun(pos, main.endSeconds(deck), core.duration(deck), stemsReady, coming)) {
            StemRules.MainUnderrun.None -> {}
            StemRules.MainUnderrun.CutToStems -> {
                log("deck ${deck.label} full mix ends at ${fmt(main.endSeconds(deck))}s -> stems")
                cutToStems(deck)
            }
            StemRules.MainUnderrun.Hold -> {
                log("deck ${deck.label} full mix ran out at ${fmt(pos)}s -> hold for stems")
                setHandover(deck, StemHandover.TO_STEMS)   // the stems' pump (or fetch) resumes the deck
                core.setPosition(deck, min(pos, main.endSeconds(deck)))
                d.held = true
            }
            StemRules.MainUnderrun.EndSong -> settleDeadSources(deck)
        }
    }

    /** A hold clears once the voice that can carry the deck has runway again. */
    private fun releaseHoldIfRunway(deck: Deck) {
        val d = s(deck)
        if (!d.held) return
        val pos = core.position(deck)
        val dur = core.duration(deck)
        val stemsOk = d.wired && StemRules.handoverReady((d.frontierSec ?: d.endSec) - pos, d.frontierSec == null, dur - pos)
        val mainOk = StemRules.handoverReady(main.endSeconds(deck) - pos, main.complete(deck), dur - pos)
        if (stemsOk || mainOk) { d.held = false; onUnhold?.invoke(deck) }
    }

    /**
     * Neither voice can grow any more (the full mix's stream is dead and the stems are absent or a dead
     * stream's leftovers): the song now ENDS where the longer of the two audios runs out, so the tick plays
     * it out and the auto-mix moves on instead of running a playhead over silence to the catalog length.
     * No-op while either voice can still grow, or when the stems are complete.
     */
    fun settleDeadSources(deck: Deck) {
        val d = s(deck)
        if (!main.truncated(deck) || d.stream != null || d.fetch?.isActive == true) return
        if (d.wired && d.frontierSec == null) return
        val end = StemRules.deadSourceEnd(main.endSeconds(deck), d.wired, d.frontierSec ?: d.endSec)
        val wasHeld = d.held
        d.held = false
        if (end < core.duration(deck) - 0.05) {
            core.diag("mixstream deck ${deck.label} truncate at ${end.toInt()}s - no voice can grow")
            core.updateDeck(deck) { it.copy(durationSec = end) }
            if (core.position(deck) > end) core.setPosition(deck, end)
            onDurationShortened?.invoke(deck)
        }
        if (wasHeld) onUnhold?.invoke(deck)
        // Released from a hold with leftover stem audio ahead: they play the rest out.
        if (wasHeld && !active(deck) && d.wired && (d.frontierSec ?: d.endSec) - core.position(deck) > 0.05) cutToStems(deck)
    }

    private fun fmt(x: Double) = String.format(java.util.Locale.US, "%.1f", x)
}

// ---------------------------------------------------------------------------------------------
// Production adapters

/** A byte source whose length never shrinks: a stream's file may be MOVED into the burn folder under an open reader. */
class MonotonicByteSource(private val inner: ByteSource) : ByteSource {
    @Volatile private var seen = 0L
    override val length: Long get() = max(seen, inner.length).also { seen = it }
    override fun read(pos: Long, dst: ByteArray, off: Int, len: Int): Int = inner.read(pos, dst, off, len)
    override fun close() = inner.close()
}

/** [StemProvider] over the burn store (on-disk stems, whole fetch) and the stream loader (stem streaming). */
class BurnStemProvider(
    private val burns: BurnStore,
    private val loader: MixStreamLoader?,
    private val open: (File) -> PcmSource? = { f -> runCatching { Mp3Decoder(f) }.getOrNull() },
) : StemProvider {
    private val warm = LinkedHashMap<String, StemParts>()

    override fun local(songId: String): StemParts? =
        synchronized(warm) { warm.remove(songId) } ?: openLocal(songId)

    override fun prewarm(songId: String) {
        if (synchronized(warm) { songId in warm }) return
        val parts = openLocal(songId) ?: return
        val evicted = ArrayList<StemParts>()
        synchronized(warm) {
            warm.put(songId, parts)?.let { evicted += it }
            while (warm.size > MAX_WARM) { val k = warm.keys.first(); warm.remove(k)?.let { evicted += it } }
        }
        evicted.forEach { e -> e.sources.forEach { runCatching { it.close() } } }
    }

    private fun openLocal(songId: String): StemParts? {
        val files = burns.localStemFiles(songId) ?: return null
        val opened = ArrayList<PcmSource>()
        for (n in BurnFileNames.STEM_NAMES) {
            val src = files[n]?.let(open)
            if (src == null || src.totalFrames <= 0) {
                runCatching { src?.close() }
                opened.forEach { runCatching { it.close() } }
                return null
            }
            opened += src
        }
        return StemParts(opened, complete = true)
    }

    override fun canStream(songId: String) = loader?.canStreamStems(songId) == true

    private companion object { const val MAX_WARM = 2 }

    override fun openStream(songId: String, owner: String): StemStream? {
        val l = loader ?: return null
        val set = l.openStems(songId, owner) ?: return null
        return object : StemStream {
            override val songId = songId
            private var decoders: List<Mp3Decoder>? = null
            override val failed: Boolean get() = set.failed
            override val complete: Boolean get() = set.isComplete.also { done ->
                if (done) decoders?.forEach { it.markComplete() }
            }

            override fun parts(): List<PcmSource>? {
                decoders?.let { return it }
                val made = ArrayList<Mp3Decoder>()
                for (n in BurnFileNames.STEM_NAMES) {
                    val part = set.parts[n] ?: return null
                    val f = part.finalFile ?: part.file
                    val dec = runCatching { Mp3Decoder(MonotonicByteSource(FileByteSource(f)), complete = false) }.getOrNull()
                    if (dec == null || dec.availableFrames <= 0) {
                        runCatching { dec?.close() }
                        made.forEach { runCatching { it.close() } }
                        return null
                    }
                    made += dec
                }
                decoders = made
                return made
            }

            override fun cancel() = l.cancelStems(songId, owner)
        }
    }

    override suspend fun fetchWhole(songId: String): Boolean = burns.burnStems(songId) != null
}

/**
 * Builds the stem / loop / beat-grid controllers around a [MixEngine] and installs every hook the
 * engine exposes for them. One instance per engine.
 */
class MixDeckExtras(
    val engine: MixEngine,
    provider: StemProvider,
    runner: VoiceRunner,
    scope: CoroutineScope,
    localGrid: (String) -> com.levi.pocketdj.data.burns.BeatGridSidecar?,
    downloadGrid: suspend (String) -> com.levi.pocketdj.data.burns.BeatGridSidecar?,
) {
    val stems = StemController(engine, provider, runner, scope)
    val hydrator = BeatGridHydrator(engine, localGrid, downloadGrid, scope)
    val loops = LoopController(engine, stems, hydrator)

    init {
        stems.loops = loops
        hydrator.onHydrated = { loops.reresolve(it) }
        stems.onDurationShortened = { engine.autoDj?.onSeek(it) }
        // The stem hold has its OWN seam; the stream-hold seam stays MIX-10's to assign in any order.
        stems.streamHeld = { d -> engine.streamHeldProvider?.invoke(d) == true }
        engine.stemHeldProvider = stems::isHeld
        engine.stemModeOnProvider = stems::modeOn
        engine.loopWindowProvider = loops::loopWindow
        engine.onLoopInvalidated = { loops.clear(it) }
        engine.onStemsReset = { stems.reset(it); hydrator.cancel(it) }
        engine.onSeeked = { d, sec -> if (engine.deckState(d).loopOn) loops.onSeeked(d, sec) else stems.onSeeked(d, sec) }
        engine.onDeckTick = stems::onTick
        engine.onTransport = stems::onTransport
        engine.onDeckLoaded = { d, l -> stems.prewarm(l.songId); hydrator.hydrate(d, l.songId) }
        engine.onRestoreDeckExtras = { d, ds ->
            if (ds.stemMode) stems.prewarm(ds.track.songId)
            stems.restore(d, ds); loops.restore(d, ds)
        }
    }
}
