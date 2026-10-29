package com.levi.pocketdj.studio.audio

import com.levi.pocketdj.audio.core.OboeBackend
import com.levi.pocketdj.studio.dsp.MasterFx
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFx
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams

/**
 * JNI surface of libpdjdsp (cpp/pdjdsp). Every call is a control/offline call; the Oboe data callback
 * is pure C++ and never calls back into the JVM. When the library is absent (JVM unit tests, a missing
 * ABI) [available] is false and callers use the Kotlin mirrors / [ResampleStretcher].
 */
object NativeDsp {
    val available: Boolean by lazy {
        try { System.loadLibrary("pdjdsp"); true } catch (_: Throwable) { false }
    }

    // TrackFx
    external fun nativeTrackFxNew(sr: Double, channels: Int): Long
    external fun nativeTrackFxFree(h: Long)
    external fun nativeTrackFxUpdate(h: Long, lo: Double, mid: Double, hi: Double, rev: Double, dly: Double, cho: Double, bpm: Double)
    external fun nativeTrackFxReset(h: Long)
    external fun nativeTrackFxProcess(h: Long, interleaved: FloatArray, frames: Int)
    // MasterFx
    external fun nativeMasterFxNew(sr: Double, channels: Int): Long
    external fun nativeMasterFxFree(h: Long)
    external fun nativeMasterFxUpdate(h: Long, params: DoubleArray)
    external fun nativeMasterFxProcess(h: Long, interleaved: FloatArray, frames: Int, framePos: Double)
    // Mixer
    external fun nativeMixAdd(dst: FloatArray, src: FloatArray, n: Int, gain: Float)
    external fun nativeHardClamp(buf: FloatArray, n: Int, limit: Float)
    // SF2
    external fun nativeSf2New(): Long
    external fun nativeSf2Free(h: Long)
    external fun nativeSf2Load(h: Long, path: String, sr: Int): Boolean
    external fun nativeSf2SetPreset(h: Long, bank: Int, program: Int): Boolean
    external fun nativeSf2NoteOn(h: Long, key: Int, vel: Float)
    external fun nativeSf2NoteOff(h: Long, key: Int)
    external fun nativeSf2AllOff(h: Long)
    external fun nativeSf2Render(h: Long, out: FloatArray, frames: Int, mix: Boolean)
    external fun nativeSf2PresetCount(h: Long): Int
    // Stretch (offline)
    external fun nativeStretchExact(input: FloatArray, inFrames: Int, out: FloatArray, outFrames: Int, sr: Int, semitones: Double): Boolean
    // Real-time stretch (decks; render thread)
    external fun nativeRtNew(sr: Int, maxIn: Int, maxOut: Int): Long
    external fun nativeRtFree(h: Long)
    external fun nativeRtInputLatency(h: Long): Int
    external fun nativeRtOutputLatency(h: Long): Int
    external fun nativeRtSetPitch(h: Long, semitones: Double)
    external fun nativeRtReset(h: Long)
    external fun nativeRtProcess(h: Long, input: FloatArray, inFrames: Int, out: FloatArray, outFrames: Int)
    // Oboe
    external fun nativeOboeNew(sr: Int, ringFrames: Int): Long
    external fun nativeOboeFree(h: Long)
    external fun nativeOboeOpen(h: Long): Boolean
    external fun nativeOboeClose(h: Long)
    external fun nativeOboeWrite(h: Long, buf: FloatArray, frames: Int): Int
    external fun nativeOboeFreeFrames(h: Long): Int
    external fun nativeOboeBuffered(h: Long): Int
    external fun nativeOboeConsumed(h: Long): Long
    external fun nativeOboeUnderruns(h: Long): Long
    external fun nativeOboeDisconnected(h: Long): Boolean
    external fun nativeOboeLatency(h: Long): Int

    /** Native kernel when the library loaded, else the Kotlin mirror. */
    fun trackFx(sampleRate: Double = 44_100.0): TrackFx =
        if (available) NativeTrackFx(sampleRate) else TrackFxKernel(sampleRate, 2)

    fun masterFx(sampleRate: Double = 44_100.0): MasterFx =
        if (available) NativeMasterFx(sampleRate) else MasterFxKernel(sampleRate, 2)

    fun oboeBackend(sampleRate: Int, ringFrames: Int): OboeBackend = NativeOboeBackend(sampleRate, ringFrames)
}

internal fun interleave(planar: Array<FloatArray>, frames: Int, out: FloatArray) {
    val l = planar[0]; val r = planar.getOrElse(1) { planar[0] }
    for (i in 0 until frames) { out[2 * i] = l[i]; out[2 * i + 1] = r[i] }
}

internal fun deinterleave(interleaved: FloatArray, frames: Int, planar: Array<FloatArray>) {
    for (i in 0 until frames) { planar[0][i] = interleaved[2 * i]; if (planar.size > 1) planar[1][i] = interleaved[2 * i + 1] }
}

/** Stereo native track kernel behind the planar [TrackFx] contract. */
class NativeTrackFx(sampleRate: Double) : TrackFx {
    @Volatile private var h = NativeDsp.nativeTrackFxNew(sampleRate, 2)
    private var scratch = FloatArray(0)
    private var p = TrackFxParams()
    override val active: Boolean get() = p.active
    override fun update(p: TrackFxParams) {
        this.p = p
        if (h != 0L) NativeDsp.nativeTrackFxUpdate(h, p.eqLowDb, p.eqMidDb, p.eqHighDb, p.reverb, p.delay, p.chorus, p.bpm)
    }
    override fun reset() { if (h != 0L) NativeDsp.nativeTrackFxReset(h) }
    override fun process(data: Array<FloatArray>, frames: Int) {
        if (h == 0L || !p.active || frames <= 0) return
        if (scratch.size < frames * 2) scratch = FloatArray(frames * 2)
        interleave(data, frames, scratch)
        NativeDsp.nativeTrackFxProcess(h, scratch, frames)
        deinterleave(scratch, frames, data)
    }
    override fun close() { if (h != 0L) { NativeDsp.nativeTrackFxFree(h); h = 0 } }
}

class NativeMasterFx(sampleRate: Double) : MasterFx {
    @Volatile private var h = NativeDsp.nativeMasterFxNew(sampleRate, 2)
    private var scratch = FloatArray(0)
    override fun update(p: MasterFxParams) { if (h != 0L) NativeDsp.nativeMasterFxUpdate(h, p.toNativeArray()) }
    override fun process(data: Array<FloatArray>, frames: Int, framePos: Double) {
        if (h == 0L || frames <= 0) return
        if (scratch.size < frames * 2) scratch = FloatArray(frames * 2)
        interleave(data, frames, scratch)
        NativeDsp.nativeMasterFxProcess(h, scratch, frames, framePos)
        deinterleave(scratch, frames, data)
    }
    override fun close() { if (h != 0L) { NativeDsp.nativeMasterFxFree(h); h = 0 } }
}

/** TinySoundFont synth: one preset, MIDI-thread-safe note calls (native spinlock). */
class Sf2Synth(private val sampleRate: Int = 44_100) {
    private var h = NativeDsp.nativeSf2New()
    fun load(path: String): Boolean = NativeDsp.nativeSf2Load(h, path, sampleRate)
    fun setPreset(bank: Int, program: Int): Boolean = NativeDsp.nativeSf2SetPreset(h, bank, program)
    fun noteOn(key: Int, velocity: Int) = NativeDsp.nativeSf2NoteOn(h, key.coerceIn(0, 127), (velocity.coerceIn(1, 127)) / 127f)
    fun noteOff(key: Int) = NativeDsp.nativeSf2NoteOff(h, key.coerceIn(0, 127))
    fun allOff() = NativeDsp.nativeSf2AllOff(h)
    /** Interleaved stereo; [mix] adds into [out] instead of overwriting. */
    fun render(out: FloatArray, frames: Int, mix: Boolean = false) = NativeDsp.nativeSf2Render(h, out, frames, mix)
    fun presetCount(): Int = NativeDsp.nativeSf2PresetCount(h)
    fun close() { if (h != 0L) { NativeDsp.nativeSf2Free(h); h = 0 } }
}

internal class NativeOboeBackend(sampleRate: Int, ringFrames: Int) : OboeBackend {
    private var h = NativeDsp.nativeOboeNew(sampleRate, ringFrames)
    override fun open() = NativeDsp.nativeOboeOpen(h)
    override fun close() = NativeDsp.nativeOboeClose(h)
    override fun release() { if (h != 0L) { NativeDsp.nativeOboeClose(h); NativeDsp.nativeOboeFree(h); h = 0 } }
    override fun write(buf: FloatArray, frames: Int) = NativeDsp.nativeOboeWrite(h, buf, frames)
    override fun freeFrames() = NativeDsp.nativeOboeFreeFrames(h)
    override fun bufferedFrames() = NativeDsp.nativeOboeBuffered(h)
    override fun underruns() = NativeDsp.nativeOboeUnderruns(h)
    override fun disconnected() = NativeDsp.nativeOboeDisconnected(h)
    override fun streamLatencyFrames() = NativeDsp.nativeOboeLatency(h)
}
