package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.RenderClock

/**
 * A scripted SoundFont: holds amplitude 0.5 while any key is down, releases exponentially after the last off,
 * and records (renderedFrame, note, on) so tests can assert frame-exact firing and the calling thread.
 */
class FakeSynth(val loadOk: Boolean = true) : SynthVoice {
    data class Hit(val frame: Long, val note: Int, val on: Boolean, val thread: String)
    val hits = java.util.Collections.synchronizedList(ArrayList<Hit>())
    @Volatile var closed = false
    @Volatile var loadedPath: String? = null
    @Volatile var program = -1
    @Volatile var loadThread: String? = null
    private var frame = 0L
    private val held = HashSet<Int>()
    private var amp = 0.0
    override fun load(path: String): Boolean { loadedPath = path; loadThread = Thread.currentThread().name; return loadOk }
    override fun setPreset(bank: Int, program: Int): Boolean { this.program = program; return true }
    @Synchronized override fun noteOn(key: Int, velocity: Int) { hits.add(Hit(frame, key, true, Thread.currentThread().name)); held.add(key); amp = 0.5 }
    @Synchronized override fun noteOff(key: Int) { hits.add(Hit(frame, key, false, Thread.currentThread().name)); held.remove(key) }
    @Synchronized override fun allOff() { held.clear() }
    @Synchronized override fun render(out: FloatArray, frames: Int, mix: Boolean) {
        for (i in 0 until frames) {
            if (held.isEmpty()) amp *= 0.9995
            val v = amp.toFloat()
            if (mix) { out[2 * i] += v; out[2 * i + 1] += v } else { out[2 * i] = v; out[2 * i + 1] = v }
        }
        frame += frames
    }
    override fun close() { closed = true }
}

class FakeSink(private val latency: Int = 0) : AudioSink {
    override val sampleRate = 44_100
    override val clock = RenderClock(44_100)
    override val underruns = 0L
    override var isRendering = false
    override var onRoutingChanged: ((Boolean) -> Unit)? = null
    var renderer: BlockRenderer? = null
    var starts = 0
    var stops = 0
    override fun start(renderer: BlockRenderer) { this.renderer = renderer; isRendering = true; starts++ }
    override fun stop() { isRendering = false; stops++ }
    override fun release() {}
    override fun latencyFrames() = latency
    fun pull(frames: Int): FloatArray = FloatArray(frames * 2).also { renderer!!.render(it, frames) }
}
