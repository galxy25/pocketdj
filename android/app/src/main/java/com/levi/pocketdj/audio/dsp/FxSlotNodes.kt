package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.FXSlot
import com.levi.pocketdj.mix.model.FxParams

/**
 * One FX rack slot's pre-allocated node bundle, chained comp -> filter -> reverb -> mod in
 * series (iOS `SlotNodes`). EXACTLY ONE node is un-bypassed while the slot is live and none when
 * it is off; a mid-mix swap is just these bypass flips (no allocation, no graph change).
 *
 * [applySlot] is the only place bypass + reverb preset change; [writeSlotParams] is the pure
 * VALUE write the modulation tick calls at ~60 Hz (never touches bypass / presets).
 * `effectiveStrength` is the live (possibly modulated) value; the delay time is always derived
 * from the slot's BASE strength.
 */
class FxSlotNodes(private val sampleRate: Float = 44_100f) : DspNode {
    val comp = Compressor(sampleRate)
    val filter = Biquad(sampleRate)
    val reverb = Reverb(sampleRate)
    val mod = ModDelay(sampleRate)

    /** The reverb variant currently loaded (rebuild only when this changes). */
    var loadedReverbPreset: FxParams.ReverbPreset? = null; private set

    init { comp.bypass = true; filter.bypass = true; reverb.bypass = true; mod.bypass = true }

    /** The slot-level bypass is "all four bypassed"; setting true bypasses everything. */
    override var bypass: Boolean
        get() = comp.bypass && filter.bypass && reverb.bypass && mod.bypass
        set(v) { if (v) { comp.bypass = true; filter.bypass = true; reverb.bypass = true; mod.bypass = true } }

    /** Number of un-bypassed nodes (invariant: <= 1). */
    val activeNodeCount: Int
        get() = listOf(comp, filter, reverb, mod).count { !it.bypass }

    fun applySlot(slot: FXSlot, effectiveStrength: Double) {
        val live = slot.enabled
        val wasBypassed = mod.bypass
        setBypass(comp, !(live && slot.effect == Effect.COMPRESSOR))
        setBypass(filter, !(live && slot.effect == Effect.FILTER))
        setBypass(reverb, !(live && slot.effect == Effect.REVERB))
        setBypass(mod, !(live && slot.effect == Effect.FLANGER))
        if (!live) return
        if (slot.effect == Effect.REVERB) {
            val p = FxParams.reverbPreset(slot.variant)
            if (loadedReverbPreset != p) { reverb.loadPreset(p); loadedReverbPreset = p }
        }
        writeSlotParams(slot, effectiveStrength)
        if (slot.effect == Effect.FLANGER && wasBypassed) mod.snap()
    }

    /** Pure value writes for one live slot. */
    fun writeSlotParams(slot: FXSlot, strength: Double) {
        val v = slot.variant
        when (slot.effect) {
            Effect.REVERB -> reverb.setWetDryMix(strength.toFloat() * 100f)
            Effect.FILTER -> {
                val shape = when (FxParams.filterType(v)) {
                    FxParams.FilterShape.RESONANT_LOW_PASS -> Biquad.Type.LOW_PASS
                    FxParams.FilterShape.RESONANT_HIGH_PASS -> Biquad.Type.HIGH_PASS
                    FxParams.FilterShape.BAND_PASS -> Biquad.Type.BAND_PASS
                }
                val f = FxParams.filterFrequency(v, strength)
                // Same bandwidth semantics as iOS for every shape (0.5 oct for LP/HP = resonant).
                val q = Biquad.qFromBandwidth(FxParams.filterBandwidth(v, strength).toDouble(), f.toDouble(), sampleRate.toDouble()).toFloat()
                filter.set(shape, f, q)
            }
            Effect.FLANGER -> {
                mod.setDelayTime(FxParams.modDelayTime(v, slot.strength)) // BASE only
                mod.setFeedback(FxParams.modFeedback(v, strength))
                mod.setWetDryMix(FxParams.modWetDryMix(v, strength))
                mod.setLowPassCutoff(FxParams.modLowPassCutoff(v))
            }
            Effect.COMPRESSOR -> comp.set(
                FxParams.compThreshold(v, strength), FxParams.compHeadRoom(v),
                FxParams.compAttack(v), FxParams.compRelease(v), FxParams.compMakeup(v, strength),
            )
        }
    }

    /** A node leaving bypass starts from clean history (no stale tail bursts out). */
    private fun setBypass(n: DspNode, on: Boolean) {
        if (n.bypass && !on) n.reset()
        n.bypass = on
    }

    override fun process(buf: FloatArray, frames: Int) {
        comp.process(buf, frames)
        filter.process(buf, frames)
        reverb.process(buf, frames)
        mod.process(buf, frames)
    }

    override fun reset() { comp.reset(); filter.reset(); reverb.reset(); mod.reset() }
}
