package com.levi.pocketdj.studio.engine

/**
 * The sequencer's fast step clock (iOS `StudioPatternClock`). Deliberately a plain class with plain fields and
 * NOT observable state: the step highlight advances 8x/s at 120 BPM, and driving Compose recomposition from it
 * re-lays-out the surrounding controls (the proven dead-play/pause-button bug on iOS). The grid samples
 * [currentStep] inside a frame-clock loop that invalidates only a draw layer.
 *
 * The clock is FRAME based: [renderedFrames] is the scheduler's own frame cursor (frames since the pattern
 * started, i.e. the render clock, not wall time), minus [latencyFrames] of output buffering so the highlight
 * lands on what is audible. [currentStep] maps the elapsed slot through the SAME [PatternMath.mappedStep] the
 * scheduler uses, so the moving highlight always lands on the cell that is actually triggering.
 */
class PatternClock(
    private val renderedFrames: () -> Long,
    private val latencyFrames: () -> Long = { 0L },
    private val sampleRate: Double = 44_100.0,
) {
    @Volatile var bpm: Double = 120.0
    @Volatile var stepCount: Int = 16
    /** The playhead step playback began at (the cursor). */
    @Volatile var startStep: Int = 0
    @Volatile var loopEnabled: Boolean = false
    @Volatile var loopBars: Int = 2
    /** True only while the pattern is actually rendering. */
    @Volatile var running: Boolean = false

    /** The pattern step currently sounding, or null when stopped / still inside the output-latency pre-roll. */
    val currentStep: Int?
        get() {
            if (!running || bpm <= 0) return null
            val audible = renderedFrames() - latencyFrames()
            if (audible < 0) return null
            val stepF = PatternMath.stepFrames(bpm, sampleRate)
            val slot = (audible / stepF).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            return PatternMath.mappedStep(slot, startStep, loopEnabled, loopBars, stepCount)
        }

    /**
     * What the stop button parks the resting cursor at: the last PLAYED step, but NOT while the looper is on
     * (there [startStep] doubles as the loop-window anchor, so moving it would slide the chosen region forward
     * on every stop-replay). Read BEFORE stopping - stop clears the clock.
     */
    fun cursorToParkOnStop(): Int? = if (loopEnabled) null else currentStep
}
