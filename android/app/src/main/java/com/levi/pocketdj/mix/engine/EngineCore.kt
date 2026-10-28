package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.graph.ParamsComposer
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.store.AutoSnapshot
import com.levi.pocketdj.mix.store.MixEventKind
import java.io.File

/**
 * The narrow surface the engine's sub-controllers (loop MIX-8, stems MIX-8, streaming MIX-10,
 * Auto-DJ MIX-9, mod tick MIX-17) are written against. Everything runs on the MAIN thread.
 * [MixEngine] is the only implementation.
 */
interface EngineCore {
    val graph: MixGraph
    val params: ParamsComposer

    fun deckState(deck: Deck): DeckState
    /** Replace a deck's state (emits the [MixUiState] flow). */
    fun updateDeck(deck: Deck, f: (DeckState) -> DeckState)

    fun position(deck: Deck): Double
    fun setPosition(deck: Deck, sec: Double)
    fun duration(deck: Deck): Double
    fun controller(deck: Deck): DeckController

    /** Emit one session event for a deck (or global) action. No-op without a recorder / during a restore. */
    fun rec(
        kind: MixEventKind, deck: Deck? = null, param: String? = null,
        value: Double? = null, flag: Boolean? = null, slot: Int? = null,
    )

    /** Persist the whole mix (immediate, or trailing-edge debounced for slider surfaces). */
    fun persist(debounced: Boolean = false)

    /** The SINGLE transport funnel: records .play/.pause only on a real transition. */
    fun setPlaying(deck: Deck, playing: Boolean)
    fun seek(deck: Deck, sec: Double)

    /** True while the output sink is actually pulling blocks. */
    val isRendering: Boolean
    /** A deck has play intent, or a RUNNING (not suspended) Auto-DJ is between decks. */
    val mixWantsAudio: Boolean
    val autoMixing: Boolean
    val isRestoringMixSession: Boolean

    fun nowMs(): Long
    fun diag(line: String)
}

/** The Auto-DJ machine (MIX-9) as the engine sees it. Absent = manual mixing only. */
interface AutoDjHooks {
    /** An auto mix exists (running or suspended). */
    val isMixing: Boolean
    /** The transition machine is suspended (decks hand-mixed / lock-screen paused). */
    val isPaused: Boolean
    /** A manual master/deck pause during a RUNNING auto mix ends it. */
    fun endAutoLoop()
    /** A seek moved a deck: re-time its crossfade (iOS refreshAutoDeckEndIfLive). */
    fun onSeek(deck: Deck) {}
    /** Master play un-silences everything: unpark any remote-frozen fade clock. */
    fun onMasterPlay() {}
    /** Resume a suspended mix (lock-screen path). */
    fun resumeAuto() {}
    /** A deck is stream-held this tick: its auto end clock must not burn (held seconds aren't played). */
    fun onDeckHeld(deck: Deck, dtSeconds: Double) {}
    /** The sink died under a live mix: freeze the machine's wall clocks (iOS `engineStallAt`). */
    fun parkEngineStall() {}
    /** The sink is rendering again: shift every armed clock past the stall. */
    fun unparkEngineStall() {}
    /** Called from the 10 Hz tick while [isMixing] and the sink renders. */
    fun fire(nowMs: Long) {}
    /** Snapshot for persistence; null when no auto queue. */
    fun snapshot(): AutoSnapshot? = null
    /** Rebuild the machine SUSPENDED from a parked restore. */
    fun restoreSuspended(auto: AutoSnapshot) {}
}

/** Why a deck's loaded track stopped being the music. */
enum class MixTrackEndReason(val raw: String) { NATURAL("natural"), SKIP("skip"), REPLACED("replaced"), STOPPED("stopped") }

/** What the engine needs to play one song: the audio file + any window / grid metadata. */
data class ResolvedTrack(
    val file: File,
    /** A per-song cut plays whole from 0:00; otherwise [startMs] seeks into a shared album side. */
    val isCut: Boolean,
    val startMs: Int? = null,
    val gridBpm: Double? = null,
    val firstDownbeatMs: Int? = null,
    val steady: Boolean? = null,
    val beatsMs: List<Int>? = null,
    val downbeatsMs: List<Int>? = null,
)

/** Resolves a song id to a local file (BurnStore in production, a stub under test). */
fun interface MixTrackResolver {
    fun resolve(songId: String): ResolvedTrack?
}

/** Opens a file as a [PcmSource] (MediaCodec mp3 decoder in production). null = unreadable. */
fun interface MixSourceOpener {
    fun open(file: File): PcmSource?
}

/** Drives a voice's decoder (a [com.levi.pocketdj.audio.core.VoicePump] thread in production). */
fun interface VoiceRunner {
    fun run(voice: Voice): AutoCloseable
}

/** A cancellable repeating task: runs until the block returns false. */
interface TickDriver {
    fun start(intervalMs: Long, block: () -> Boolean): AutoCloseable
}

/** Frame-window math for a load, as a pure function. */
object LoadWindow {
    /** [startFrame, endFrame) of the playable slice, or null when nothing is schedulable. */
    data class Frames(val startFrame: Long, val endFrame: Long) {
        val count: Long get() = endFrame - startFrame
    }

    /**
     * iOS loadFile: start = clamp(startMs, 0, total); available = total - start; the window is
     * min(available, lengthMs) when bounded. Zero-length (over-length startMs / empty file) = null.
     */
    fun compute(totalFrames: Long, sampleRate: Int, startMs: Int?, lengthMs: Int?): Frames? {
        if (totalFrames <= 0) return null
        val start = ((startMs ?: 0) / 1000.0 * sampleRate).toLong().coerceIn(0L, totalFrames)
        val available = totalFrames - start
        val windowed = lengthMs?.let { (it / 1000.0 * sampleRate).toLong() }
        val count = windowed?.let { minOf(available, maxOf(0L, it)) } ?: available
        if (count <= 0) return null
        return Frames(start, start + count)
    }
}
