package com.levi.pocketdj.audio.dsp

/**
 * Always-active 3-band DJ-mixer EQ: low shelf 320 Hz, mid peak 1 kHz (BW 1 oct), high shelf
 * 3.2 kHz, each +/-12 dB. Mirrors iOS `configureEQ3`. A band at exactly 0 dB is skipped, so a
 * flat EQ is bit-transparent.
 */
class Eq3(sampleRate: Float = 44_100f) : DspNode {
    override var bypass: Boolean = false

    private val low = Biquad(sampleRate).also { it.set(Biquad.Type.LOW_SHELF, 320f, 1f, 0f) }
    private val mid = Biquad(sampleRate).also {
        it.set(Biquad.Type.PEAK, 1_000f, 1f, 0f); it.setBandwidthOctaves(1f)
    }
    private val high = Biquad(sampleRate).also { it.set(Biquad.Type.HIGH_SHELF, 3_200f, 1f, 0f) }

    var lowDb = 0f; private set
    var midDb = 0f; private set
    var highDb = 0f; private set

    fun setLowDb(db: Float) {
        val old = lowDb
        lowDb = db.coerceIn(-MAX_DB, MAX_DB)
        if (old == 0f && lowDb != 0f) low.reset() // skipped band: drop stale history
        low.setGainDb(lowDb)
    }
    fun setMidDb(db: Float) {
        val old = midDb
        midDb = db.coerceIn(-MAX_DB, MAX_DB)
        if (old == 0f && midDb != 0f) mid.reset() // skipped band: drop stale history
        mid.setGainDb(midDb)
    }
    fun setHighDb(db: Float) {
        val old = highDb
        highDb = db.coerceIn(-MAX_DB, MAX_DB)
        if (old == 0f && highDb != 0f) high.reset() // skipped band: drop stale history
        high.setGainDb(highDb)
    }

    override fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        if (lowDb != 0f) low.process(buf, frames)
        if (midDb != 0f) mid.process(buf, frames)
        if (highDb != 0f) high.process(buf, frames)
    }

    override fun reset() { low.reset(); mid.reset(); high.reset() }

    companion object { const val MAX_DB = 12f }
}
