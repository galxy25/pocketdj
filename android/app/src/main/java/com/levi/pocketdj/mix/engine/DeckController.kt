package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.model.Deck

/**
 * One deck's voice plumbing (the Android twin of iOS's per-deck player + file + frame window).
 * Owns the full-mix [Voice], its decoder runner, and the song's `[startFrame, endFrame)` window in
 * graph-rate file frames. Pure transport mechanics: no session events, no persistence, no state
 * flow (the engine owns those). Main thread only.
 */
class DeckController(
    val deck: Deck,
    private val graph: MixGraph,
    private val runner: VoiceRunner,
) {
    var voice: Voice? = null; private set
    private var pump: AutoCloseable? = null
    var startFrame = 0L; private set
    var endFrame = 0L; private set
    val sampleRate: Int get() = graph.sampleRate

    val isOpen: Boolean get() = voice != null
    val windowSeconds: Double get() = (endFrame - startFrame).toDouble() / sampleRate

    /** Install [v] over [w], replacing (and closing) the previous track. The voice starts paused. */
    fun open(v: Voice, w: LoadWindow.Frames) {
        val old = voice
        val oldPump = pump
        startFrame = w.startFrame
        endFrame = w.endFrame
        v.schedule(w.startFrame, w.endFrame, final = true)
        voice = v
        pump = runner.run(v)
        graph.setMain(deck, v)
        // Old voice is out of the graph now: stop its decoder before closing the source under it.
        old?.pause()
        runCatching { oldPump?.close() }
        runCatching { old?.close() }
    }

    /** Drop the track entirely (eject). */
    fun release() {
        val old = voice
        val oldPump = pump
        voice = null; pump = null
        startFrame = 0; endFrame = 0
        graph.setMain(deck, null)
        old?.pause()
        runCatching { oldPump?.close() }
        runCatching { old?.close() }
    }

    fun play() { voice?.play() }
    fun pause() { voice?.pause() }

    /** Reposition to [sec] source seconds into the window (clamped); transport state is untouched. */
    fun seekSeconds(sec: Double) {
        val v = voice ?: return
        v.seek(frameFor(sec))
    }

    fun frameFor(sec: Double): Long =
        (startFrame + Math.round(sec * sampleRate)).coerceIn(startFrame, endFrame)

    /** True playhead in source seconds from the voice's own frame counter; null unless it is rendering. */
    fun trueSeconds(): Double? {
        val v = voice ?: return null
        if (v.status != Voice.Status.PLAYING) return null
        return ((v.playerFrame - startFrame).toDouble() / sampleRate).coerceAtLeast(0.0)
    }

    val voiceStatus: Voice.Status? get() = voice?.status
    val isVoicePlaying: Boolean get() = voice?.isPlaying == true
}
