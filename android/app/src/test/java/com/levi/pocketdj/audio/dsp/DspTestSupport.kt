package com.levi.pocketdj.audio.dsp

import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt

internal const val SR = 44_100f

/** Interleaved stereo sine, same on both channels. */
internal fun sine(freq: Float, frames: Int, amp: Float = 1f, startFrame: Int = 0): FloatArray {
    val a = FloatArray(frames * 2)
    for (i in 0 until frames) {
        val v = (amp * sin(2.0 * PI * freq * (i + startFrame) / SR)).toFloat()
        a[2 * i] = v; a[2 * i + 1] = v
    }
    return a
}

internal fun constant(value: Float, frames: Int): FloatArray = FloatArray(frames * 2) { value }

/** RMS of the left channel over frames [from, to). */
internal fun rmsL(a: FloatArray, from: Int, to: Int): Double {
    var s = 0.0
    for (i in from until to) s += a[2 * i].toDouble() * a[2 * i]
    return sqrt(s / (to - from))
}

internal fun db(x: Double) = 20 * log10(x)

/** Process in blocks of [block] frames. */
internal fun DspNode.run(a: FloatArray, block: Int = 512) {
    val frames = a.size / 2
    val tmp = FloatArray(block * 2)
    var off = 0
    while (off < frames) {
        val n = minOf(block, frames - off)
        System.arraycopy(a, off * 2, tmp, 0, n * 2)
        process(tmp, n)
        System.arraycopy(tmp, 0, a, off * 2, n * 2)
        off += n
    }
}

/** Steady-state gain (dB) of [node] on a sine at [freq]. */
internal fun gainDbAt(node: DspNode, freq: Float): Double {
    val x = sine(freq, 22_050)
    val y = x.copyOf()
    node.reset()
    node.run(y)
    return db(rmsL(y, 11_025, 22_050) / rmsL(x, 11_025, 22_050))
}
