package com.levi.pocketdj.audio.core

/** Fills [out] with [frames] interleaved stereo float frames (always writes all of them). */
fun interface BlockRenderer {
    fun render(out: FloatArray, frames: Int)
}

/**
 * The graph's only platform contact. A pull sink: once [start]ed it repeatedly asks the
 * [BlockRenderer] for blocks and advances [clock]. Everything above this (Mix graph, Studio,
 * Now Playing DSP) is platform-free and renders identically into [OfflineRenderer] under test.
 */
interface AudioSink {
    val sampleRate: Int
    val channels: Int get() = 2
    val clock: RenderClock

    /** Output underruns since [start] (device starvation, not Voice holds). */
    val underruns: Long

    /** True while blocks are actually flowing to the device. */
    val isRendering: Boolean

    /** Called when the output route changed and the sink recovered (or failed to). */
    var onRoutingChanged: ((rendering: Boolean) -> Unit)?

    fun start(renderer: BlockRenderer)
    fun stop()
    fun release()

    /** Approximate output latency in frames (0 when unknown). */
    fun latencyFrames(): Int
}
