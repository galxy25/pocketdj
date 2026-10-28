package com.levi.pocketdj.audio.core

/**
 * N voices that must start on ONE render frame and then STAY locked (the four stems: host-time
 * starts comb-filter, and so does one stem holding while the others run).
 *
 * [startTogether] refuses (returns -1) unless [allReady]; [read] holds the WHOLE group (silence,
 * nothing consumed) whenever any member would underrun, so position never drifts between stems.
 */
class VoiceGroup(val voices: List<Voice>) {
    /** True when every voice has at least [minFrames] decoded (safe to schedule together). */
    fun allReady(minFrames: Int): Boolean = voices.all { it.bufferedFrames >= minFrames }

    /** Set by [read]: the last block was held for the whole group. */
    @Volatile var holding = false; private set
    @Volatile var holdCount = 0L; private set

    /**
     * Start all voices at one render frame [leadSeconds] after the sink clock; returns that frame,
     * or -1 (nothing started) when some voice has fewer than [minFrames] buffered.
     */
    fun startTogether(clock: RenderClock, leadSeconds: Double = DEFAULT_LEAD, minFrames: Int = 1): Long {
        if (!allReady(minFrames)) return -1
        val frame = clock.frameAfter(leadSeconds)
        startAt(frame)
        return frame
    }

    fun startAt(frame: Long) { for (v in voices) v.play(frame) }

    /**
     * Render one block per voice into [outs] (same order as [voices]). If any voice cannot fill the
     * block, every voice outputs silence and none advances. Returns true when the block played.
     */
    fun read(outs: List<FloatArray>, frames: Int, blockStart: Long): Boolean {
        // indexed loops: no iterator allocation per block on ART
        var ok = true
        for (i in voices.indices) if (!voices[i].canFill(frames, blockStart)) { ok = false; break }
        if (ok) { for (i in voices.indices) voices[i].read(outs[i], frames, blockStart) }
        else { for (i in voices.indices) voices[i].hold(outs[i], frames); holdCount++ }
        holding = !ok
        return ok
    }

    fun pauseAll() { for (v in voices) v.pause() }
    fun seekAll(frame: Long) { for (v in voices) v.seek(frame) }
    fun closeAll() { for (v in voices) v.close() }

    companion object { const val DEFAULT_LEAD = 0.06 }
}
