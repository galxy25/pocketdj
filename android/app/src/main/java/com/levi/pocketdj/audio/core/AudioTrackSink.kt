package com.levi.pocketdj.audio.core

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import java.util.concurrent.atomic.AtomicBoolean

/** The slice of [AudioTrack] the sink needs, so the recovery logic is JVM-testable. */
interface TrackHandle {
    val underrunCount: Int
    val bufferSizeInFrames: Int
    fun play()
    /** Blocking write of [count] interleaved floats; negative = dead object / route vanished. */
    fun write(buf: FloatArray, count: Int): Int
    fun stop()
    fun release()
}

/** Reports output-route changes (sink devices only, never the initial snapshot). */
interface RouteWatcher {
    fun register(onChange: () -> Unit)
    fun unregister()
}

/**
 * The device sink: ONE float-PCM [AudioTrack] in low-latency mode fed by a dedicated
 * urgent-audio render thread. Position truth is [clock] (frames handed to the track).
 *
 * Route changes (headphones, Bluetooth, USB, CarPlay/Auto) recreate the track on the render
 * thread between blocks — the graph above keeps its fixed [sampleRate] (the platform mixer
 * resamples) — then re-report via [onRoutingChanged]. A failed (re)create leaves [isRendering]
 * false and the render thread keeps retrying with backoff (a Bluetooth handoff can fail for a few
 * hundred ms), re-reporting once it recovers; [start] on a running sink is a no-op. A throwing
 * renderer drops [isRendering] to false (recorded via [AudioDiag]) instead of lying.
 */
class AudioTrackSink(
    override val sampleRate: Int,
    private val blockFrames: Int,
    private val trackFactory: () -> TrackHandle,
    private val routes: RouteWatcher,
    private val retryInitialMs: Long = 50,
    private val retryMaxMs: Long = 1000,
) : AudioSink {
    constructor(audioManager: AudioManager, sampleRate: Int = 44_100, blockFrames: Int = 512) :
        this(sampleRate, blockFrames, { RealTrack.build(sampleRate, blockFrames) }, AndroidRouteWatcher(audioManager))

    override val clock = RenderClock(sampleRate)
    override var onRoutingChanged: ((Boolean) -> Unit)? = null

    @Volatile private var track: TrackHandle? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var rendering = false
    @Volatile private var underrunBase = 0L
    private val needsRecreate = AtomicBoolean(false)

    override val isRendering: Boolean get() = rendering
    override val underruns: Long get() = underrunBase + (track?.underrunCount ?: 0)

    @Synchronized override fun start(renderer: BlockRenderer) {
        if (running) return // a lost track is retried by the render loop itself
        val t = runCatching { trackFactory().also { it.play() } }.getOrNull()
        if (t == null) { rendering = false; return } // owner's watchdog retries start()
        track = t
        running = true
        rendering = true
        routes.register { needsRecreate.set(true) }
        thread = Thread({ loop(renderer) }, "pdj-audio-render").also { it.priority = Thread.MAX_PRIORITY; it.start() }
    }

    private fun loop(renderer: BlockRenderer) {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) }
        val buf = FloatArray(blockFrames * 2)
        var retryMs = retryInitialMs
        var nextRetryAt = 0L
        while (running) {
            if (needsRecreate.getAndSet(false)) { recreate(report = true); retryMs = retryInitialMs; nextRetryAt = System.nanoTime() + retryMs * 1_000_000 }
            val t = track
            if (t == null) {
                rendering = false
                if (System.nanoTime() >= nextRetryAt) {
                    val ok = recreate(report = false)
                    if (ok) { onRoutingChanged?.invoke(true); retryMs = retryInitialMs }
                    else { retryMs = minOf(retryMs * 2, retryMaxMs); nextRetryAt = System.nanoTime() + retryMs * 1_000_000 }
                }
                try { Thread.sleep(minOf(20L, retryInitialMs)) } catch (_: InterruptedException) { }
                continue
            }
            try {
                renderer.render(buf, blockFrames)
                val w = t.write(buf, buf.size)
                if (w < 0) { needsRecreate.set(true); continue } // dead object: the route vanished under us
                rendering = true
                clock.advance(blockFrames)
            } catch (e: Throwable) {
                rendering = false
                AudioDiag.stop("AudioTrackSink", "render-exception", e.toString())
                try { Thread.sleep(50) } catch (_: InterruptedException) { }
            }
        }
    }

    /** Rebuild the track; [report] fires [onRoutingChanged] with the outcome. */
    private fun recreate(report: Boolean): Boolean {
        val old = track
        if (old != null) {
            underrunBase += old.underrunCount
            runCatching { old.stop() }; runCatching { old.release() }
        }
        val fresh = runCatching { trackFactory().also { it.play() } }.getOrNull()
        track = fresh
        rendering = fresh != null
        if (report) onRoutingChanged?.invoke(rendering)
        return fresh != null
    }

    @Synchronized override fun stop() {
        running = false
        thread?.let { runCatching { it.join(500) } }
        thread = null
        routes.unregister()
        runCatching { track?.stop() }; runCatching { track?.release() }
        track = null
        rendering = false
    }

    override fun release() = stop()

    override fun latencyFrames(): Int = track?.bufferSizeInFrames ?: 0

    private class RealTrack(private val t: AudioTrack) : TrackHandle {
        override val underrunCount: Int get() = t.underrunCount
        override val bufferSizeInFrames: Int get() = t.bufferSizeInFrames
        override fun play() = t.play()
        override fun write(buf: FloatArray, count: Int) = t.write(buf, 0, count, AudioTrack.WRITE_BLOCKING)
        override fun stop() = t.stop()
        override fun release() = t.release()

        companion object {
            fun build(sampleRate: Int, blockFrames: Int): TrackHandle {
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
                return RealTrack(t)
            }
        }
    }

    /**
     * Only OUTPUT (sink) devices count, and only changes AFTER registration: the platform replays
     * every connected device right after register, and mics/USB peripherals are not routes.
     */
    private class AndroidRouteWatcher(private val am: AudioManager) : RouteWatcher {
        private var callback: android.media.AudioDeviceCallback? = null
        private val known = HashSet<Int>()

        override fun register(onChange: () -> Unit) {
            synchronized(known) {
                known.clear()
                runCatching { am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).forEach { known += it.id } }
            }
            val cb = object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                    val fresh = synchronized(known) { addedDevices.orEmpty().filter { it.isSink }.count { known.add(it.id) } }
                    if (fresh > 0) onChange()
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                    val gone = synchronized(known) { removedDevices.orEmpty().filter { it.isSink }.count { known.remove(it.id) } }
                    if (gone > 0) onChange()
                }
            }
            callback = cb
            am.registerAudioDeviceCallback(cb, null)
        }

        override fun unregister() {
            callback?.let { runCatching { am.unregisterAudioDeviceCallback(it) } }
            callback = null
        }
    }
}
