package com.levi.pocketdj.audio.core

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The device sink: ONE float-PCM [AudioTrack] in low-latency mode fed by a dedicated
 * urgent-audio render thread. Position truth is [clock] (frames handed to the track).
 *
 * Route changes (headphones, Bluetooth, USB, CarPlay/Auto) recreate the track on the render
 * thread between blocks — the graph above keeps its fixed [sampleRate] (the platform mixer
 * resamples) — then re-report via [onRoutingChanged]. A failed (re)create leaves
 * [isRendering] false so the owner's watchdog can retry with [start] again.
 */
class AudioTrackSink(
    private val audioManager: AudioManager,
    override val sampleRate: Int = 44_100,
    private val blockFrames: Int = 512,
) : AudioSink {
    override val clock = RenderClock(sampleRate)
    override var onRoutingChanged: ((Boolean) -> Unit)? = null

    @Volatile private var track: AudioTrack? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var rendering = false
    @Volatile private var underrunBase = 0L
    private val needsRecreate = AtomicBoolean(false)
    private var routeListener: AudioDeviceCallbackShim? = null

    override val isRendering: Boolean get() = rendering
    override val underruns: Long get() = underrunBase + (track?.underrunCount ?: 0)

    private fun buildTrack(): AudioTrack {
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val min = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(fmt)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(min, blockFrames * 2 * 4 * 2))
            .build()
        // two bursts of headroom: low latency without crackle on slow devices
        runCatching { t.bufferSizeInFrames = maxOf(blockFrames * 2, t.bufferSizeInFrames.coerceAtMost(blockFrames * 4)) }
        return t
    }

    @Synchronized override fun start(renderer: BlockRenderer) {
        if (running) return
        val t = runCatching { buildTrack() }.getOrNull()
        if (t == null) { rendering = false; return }
        track = t
        t.play()
        running = true
        rendering = true
        val shim = AudioDeviceCallbackShim { needsRecreate.set(true) }
        audioManager.registerAudioDeviceCallback(shim.callback, null)
        routeListener = shim
        thread = Thread({ loop(renderer) }, "pdj-audio-render").also { it.priority = Thread.MAX_PRIORITY; it.start() }
    }

    private fun loop(renderer: BlockRenderer) {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) }
        val buf = FloatArray(blockFrames * 2)
        while (running) {
            if (needsRecreate.getAndSet(false)) recreate()
            val t = track
            if (t == null) { rendering = false; try { Thread.sleep(50) } catch (_: InterruptedException) { }; continue }
            renderer.render(buf, blockFrames)
            val w = t.write(buf, 0, buf.size, AudioTrack.WRITE_BLOCKING)
            if (w < 0) { // dead object / invalid: the route vanished under us
                needsRecreate.set(true)
                continue
            }
            clock.advance(blockFrames)
        }
    }

    private fun recreate() {
        val old = track
        underrunBase += old?.underrunCount ?: 0
        runCatching { old?.stop() }; runCatching { old?.release() }
        val fresh = runCatching { buildTrack().also { it.play() } }.getOrNull()
        track = fresh
        rendering = fresh != null
        onRoutingChanged?.invoke(rendering)
        if (fresh == null) needsRecreate.set(false) // owner restarts via start()
    }

    @Synchronized override fun stop() {
        running = false
        thread?.let { runCatching { it.join(500) } }
        thread = null
        routeListener?.let { audioManager.unregisterAudioDeviceCallback(it.callback) }
        routeListener = null
        runCatching { track?.stop() }; runCatching { track?.release() }
        underrunBase += 0
        track = null
        rendering = false
    }

    override fun release() = stop()

    override fun latencyFrames(): Int = track?.bufferSizeInFrames ?: 0

    /** Thin wrapper so the listener type stays out of the public surface. */
    private class AudioDeviceCallbackShim(val onChange: () -> Unit) {
        val callback = object : android.media.AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = onChange()
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = onChange()
        }
    }
}
