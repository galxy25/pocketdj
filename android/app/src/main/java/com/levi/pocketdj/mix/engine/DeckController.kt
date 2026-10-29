package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
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
    /** The deck's four stem voices (MIX-8), in the MAIN voice's file-frame domain (see ShiftedSource). */
    var stems: VoiceGroup? = null; private set
    private var stemPumps: List<AutoCloseable> = emptyList()
    private var pump: AutoCloseable? = null
    var startFrame = 0L; private set
    var endFrame = 0L; private set
    val sampleRate: Int get() = graph.sampleRate

    val isOpen: Boolean get() = voice != null
    val windowSeconds: Double get() = (endFrame - startFrame).toDouble() / sampleRate

    /** Install [v] over [w], replacing (and closing) the previous track. The voice starts paused. */
    fun open(v: Voice, w: LoadWindow.Frames, final: Boolean = true) {
        val old = voice
        val oldPump = pump
        startFrame = w.startFrame
        endFrame = w.endFrame
        v.schedule(w.startFrame, w.endFrame, final = final)
        voice = v
        pump = runner.run(v)
        graph.setMain(deck, v)
        // Old voice is out of the graph now: stop its decoder before closing the source under it.
        old?.pause()
        runCatching { oldPump?.close() }
        runCatching { old?.close() }
    }

    /**
     * Raise a GROWING window's end to [frame] (MIX-10 streaming): only ever raises, [final] marks the true
     * end of the file. The voice keeps decoding past what it had; a playhead that caught the old end
     * resumes by itself.
     */
    fun growTo(frame: Long, final: Boolean = false) {
        val v = voice ?: return
        if (frame > endFrame) endFrame = frame
        v.append(frame, final)
    }

    /** Install the deck's stem group (replacing any previous one) and start its decoder threads. */
    fun installStems(group: VoiceGroup) {
        removeStems()
        stems = group
        stemPumps = group.voices.map { runner.run(it) }
        graph.setStems(deck, group)
    }

    /** Tear the stem group down: out of the graph, decoders joined, sources closed. */
    fun removeStems() {
        val g = stems ?: return
        val ps = stemPumps
        stems = null; stemPumps = emptyList()
        graph.setStems(deck, null)
        g.pauseAll()
        for (p in ps) runCatching { p.close() }
        runCatching { g.closeAll() }
    }

    /** The deck's transport currently belongs to the stems (the graph's handover intent). */
    val onStems: Boolean get() = stems != null && graph.isOnStems(deck)

    /**
     * Apply (or clear) a loop window, in source seconds, to the full-mix voice and, when
     * [includeStems], to the four stems (same absolute frames: stems live in the main voice's domain).
     */
    fun setLoopSeconds(w: Pair<Double, Double>?, includeStems: Boolean) {
        val f0 = w?.let { frameFor(it.first) } ?: -1L
        val f1 = w?.let { frameFor(it.second) } ?: -1L
        if (w != null && f1 <= f0) return
        voice?.setLoop(f0, f1)
        if (includeStems) stems?.voices?.forEach { it.setLoop(f0, f1) }
    }

    /** Drop the track entirely (eject). */
    fun release() {
        removeStems()
        val old = voice
        val oldPump = pump
        voice = null; pump = null
        startFrame = 0; endFrame = 0
        graph.setMain(deck, null)
        old?.pause()
        runCatching { oldPump?.close() }
        runCatching { old?.close() }
    }

    fun play() {
        val g = stems
        if (g != null && graph.isOnStems(deck)) {
            // The four stems start on ONE input-clock frame; an already-running group is left alone
            // (re-arming a start would mute it for the lead).
            if (!g.voices[0].isPlaying) g.startAt(graph.deck(deck).inputFrameAfter(START_LEAD))
        } else voice?.play()
    }

    fun pause() { voice?.pause(); stems?.pauseAll() }

    /** Reposition to [sec] source seconds into the window (clamped); transport state is untouched. */
    fun seekSeconds(sec: Double) {
        val v = voice ?: return
        val f = frameFor(sec)
        v.seek(f)
        if (onStems) stems?.seekAll(f)
    }

    fun frameFor(sec: Double): Long =
        (startFrame + Math.round(sec * sampleRate)).coerceIn(startFrame, endFrame)

    /**
     * True playhead in source seconds from the voice's own frame counter MINUS the stretcher's delay (what
     * is audible now; the FX/EQ run after the stretcher); null unless it is rendering.
     */
    fun trueSeconds(): Double? {
        val v = (if (onStems) stems?.voices?.get(0) else voice) ?: return null
        if (!v.isPlaying || v.status != Voice.Status.PLAYING) return null
        return ((v.playerFrame - startFrame).toDouble() / sampleRate - graph.audibleLagSeconds(deck)).coerceAtLeast(0.0)
    }

    val voiceStatus: Voice.Status? get() = voice?.status
    val isVoicePlaying: Boolean get() = (if (onStems) stems?.voices?.get(0) else voice)?.isPlaying == true

    companion object { const val START_LEAD = 0.06 }
}
