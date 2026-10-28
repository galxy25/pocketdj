package com.levi.pocketdj.audio.core

/**
 * N voices that must start on ONE render frame (the four stems: host-time starts comb-filter).
 * [startTogether] computes the frame once and hands the same value to every voice.
 */
class VoiceGroup(val voices: List<Voice>) {
    /** True when every voice has at least [minFrames] decoded (safe to schedule together). */
    fun allReady(minFrames: Int): Boolean = voices.all { it.bufferedFrames >= minFrames }

    /** Start all voices at one render frame [leadSeconds] after the sink clock; returns that frame. */
    fun startTogether(clock: RenderClock, leadSeconds: Double = DEFAULT_LEAD): Long {
        val frame = clock.frameAfter(leadSeconds)
        startAt(frame)
        return frame
    }

    fun startAt(frame: Long) { for (v in voices) v.play(frame) }

    fun pauseAll() { for (v in voices) v.pause() }
    fun seekAll(frame: Long) { for (v in voices) v.seek(frame) }
    fun closeAll() { for (v in voices) v.close() }

    companion object { const val DEFAULT_LEAD = 0.06 }
}
