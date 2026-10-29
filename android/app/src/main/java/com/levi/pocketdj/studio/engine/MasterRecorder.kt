package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioDiag
import com.levi.pocketdj.audio.core.AacEncoder
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.PcmChunkWriter
import com.levi.pocketdj.audio.core.StreamingResampler
import com.levi.pocketdj.audio.core.WavWriter
import com.levi.pocketdj.studio.audio.AndroidStudioCodec
import com.levi.pocketdj.studio.audio.BufferedM4aWriter
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue

/** A finished master capture: a float32 WAV at [sampleRate], plus the mode it was recorded in. */
class MasterCapture(val file: File, val sampleRate: Int, val quantized: Boolean)

/**
 * Record-to-master (iOS `MultitrackPlayer` record tap). The player taps the canonical master AFTER the peak
 * limiter ("exactly what you hear", master FX + master gain + limiter included) and this class streams it to a
 * float32 WAV off the render thread. State machine:
 *
 *  - [begin] (every play with record=true, INCLUDING a seek/loop/re-prime restart) first deletes any leftover
 *    partial from the previous pass, then opens a fresh file: a restart keeps recording but never leaks or
 *    concatenates a stale partial; a non-record begin also drops a leftover.
 *  - [end] finalizes the file. [finishedNonce] is bumped ONLY when the stop is [naturalEnd] (playback reached its
 *    end by itself): that is the view's single signal to bake. A manual stop or a restart does NOT bump it, so a
 *    transient stop() inside a play() restart can never trigger a truncated bake (and the nonce is not an
 *    `isPlaying` flip, which flickers on every restart).
 *  - [consume] hands the finished capture to the baker exactly once.
 *
 * Capture rate: Clean mode tags the capture at the sink's rate and the bake resamples to canonical (no pitch
 * change); Quantized (lo-fi) relabels the frames as canonical WITHOUT resampling (the retro downpitch of a
 * 48 kHz capture played at 44.1). On a sink already running at the canonical rate the two are identical.
 */
class MasterRecorder(
    private val tempDir: () -> File = { File(System.getProperty("java.io.tmpdir") ?: ".") },
    private val newName: () -> String = { "tracks-master-${UUID.randomUUID()}.wav" },
    private val log: (String) -> Unit = { msg -> runCatching { AudioDiag.emit("studio.master-rec $msg") } },
) {
    private val _nonce = MutableStateFlow(0)
    /** Bumped only when a recording ends because playback reached its natural end. */
    val finishedNonce: StateFlow<Int> = _nonce

    private val lock = Any()
    @Volatile private var session: Session? = null
    private var leftover: MasterCapture? = null

    val isRecording: Boolean get() = synchronized(lock) { session != null }
    private val _active = MutableStateFlow(false)
    /** Observable "a capture is running" (survives a configuration change; the view derives its Record state from it). */
    val active: StateFlow<Boolean> = _active

    private class Block(val data: FloatArray, val n: Int)

    private class Session(val file: File, val rate: Int, val quantized: Boolean) {
        val queue = LinkedBlockingQueue<Block>()
        val pool = java.util.concurrent.ConcurrentLinkedQueue<FloatArray>()
        val writer = WavWriter.Streaming(file, rate, 2, WavWriter.Format.FLOAT32)
        @Volatile var dropped = 0L
        val thread = Thread({
            try {
                while (true) {
                    val blk = queue.take()
                    if (blk.n == 0) break
                    writer.append(blk.data, 0, blk.n)
                    pool.offer(blk.data)
                }
            } catch (_: InterruptedException) {
            } finally { runCatching { writer.close() } }
        }, "pdj-master-rec").also { it.isDaemon = true; it.start() }
    }

    /** Start a capture at [captureRate]. Always discards a leftover partial first. False when the file can't be opened. */
    fun begin(record: Boolean, captureRate: Int, quantized: Boolean): Boolean = synchronized(lock) {
        session?.let { finish(it); runCatching { it.file.delete() } }
        session = null
        _active.value = false
        leftover?.let { runCatching { it.file.delete() } }
        leftover = null
        if (!record) return true
        return try {
            val dir = tempDir().also { it.mkdirs() }
            session = Session(File(dir, newName()), captureRate, quantized)
            _active.value = true
            log("begin rate=$captureRate quantized=$quantized")
            true
        } catch (t: Throwable) { log("begin failed: $t"); false }
    }

    /** Render-thread tap: copy [frames] interleaved stereo frames out of [buf] to the writer queue. */
    fun tap(buf: FloatArray, frames: Int) {
        val s = session ?: return
        if (frames <= 0) return
        val n = frames * 2
        val blk = s.pool.poll()?.takeIf { it.size >= n } ?: FloatArray(maxOf(n, 8192))
        System.arraycopy(buf, 0, blk, 0, n)
        s.queue.offer(Block(blk, n))
    }

    /** Finalize the capture. A [naturalEnd] stop bumps [finishedNonce] (only if a capture was active). */
    fun end(naturalEnd: Boolean) = synchronized(lock) {
        val s = session ?: return@synchronized
        session = null
        _active.value = false
        finish(s)
        leftover = MasterCapture(s.file, s.rate, s.quantized)
        log("end natural=$naturalEnd bytes=${s.writer.dataBytes}")
        if (naturalEnd) _nonce.value = _nonce.value + 1
    }

    /** The finished capture (once). Call after the player stopped. */
    fun consume(): MasterCapture? = synchronized(lock) { leftover.also { leftover = null } }

    /** Drop everything (screen disposal). */
    fun discard() = synchronized(lock) {
        session?.let { finish(it); runCatching { it.file.delete() } }
        session = null
        _active.value = false
        leftover?.let { runCatching { it.file.delete() } }
        leftover = null
    }

    private fun finish(s: Session) {
        s.queue.offer(Block(FloatArray(0), 0))
        runCatching { s.thread.join(5_000) }
    }
}

/** Reads back the float32 WAVs [MasterRecorder] writes (the capture never goes through a platform decoder). */
object MasterWav {
    /** Frames per chunk when reading a capture back: the largest array a bake holds (about 0.1 s at 44.1 kHz). */
    const val CHUNK_FRAMES = 4096

    class Header(val sampleRate: Int, val frames: Long, val dataOffset: Long = 44)

    /** Validated header of a capture (null when not a stereo float32 WAV). A crash-truncated file trusts its length. */
    fun header(file: File): Header? = runCatching {
        RandomAccessFile(file, "r").use { raf ->
            if (raf.length() < 44) return null
            val head = ByteArray(44); raf.readFully(head)
            val info = WavWriter.parse(head) ?: return null
            if (info.format != WavWriter.Format.FLOAT32.tag || info.bits != 32 || info.channels != 2) return null
            val avail = raf.length() - 44
            // The header is patched on close; a crash leaves dataBytes 0 — trust the file length then.
            val bytes = (if (info.dataBytes in 1..avail) info.dataBytes else avail) / 8 * 8
            Header(info.sampleRate, bytes / 8)
        }
    }.getOrNull()

    /**
     * Streams the capture to [sink] in blocks of at most [chunkFrames] interleaved stereo frames (the array is
     * REUSED between calls). Returns the header, or null for an unreadable capture (sink never called).
     */
    fun readChunks(file: File, chunkFrames: Int = CHUNK_FRAMES, sink: (FloatArray, Int) -> Unit): Header? {
        val h = header(file) ?: return null
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(h.dataOffset)
            val bytes = ByteArray(chunkFrames * 8)
            val out = FloatArray(chunkFrames * 2)
            var left = h.frames
            while (left > 0) {
                val n = minOf(left, chunkFrames.toLong()).toInt()
                raf.readFully(bytes, 0, n * 8)
                ByteBuffer.wrap(bytes, 0, n * 8).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(out, 0, n * 2)
                sink(out, n)
                left -= n
            }
        }
        return h
    }

    /** Whole capture in memory (tests / short captures; the bake streams via [readChunks]). */
    fun read(file: File): PcmBuffer? = runCatching {
        val h = header(file) ?: return null
        val out = FloatArray((h.frames * 2).toInt()); var at = 0
        readChunks(file) { b, n -> System.arraycopy(b, 0, out, at, n * 2); at += n * 2 }
        PcmBuffer(h.sampleRate, 2, out)
    }.getOrNull()
}

/** Bakes a [MasterCapture] into a dated `live-recording-<stamp>.m4a` Recording artifact. */
const val LOFI_HARDWARE_RATE = 48_000

class MasterRecordingBaker(
    /** Legacy whole-buffer encoder seam (tests / fakes); null = stream through [openM4a]. */
    private val writeM4a: ((PcmBuffer, File) -> Unit)? = null,
    private val openM4a: (File, Int) -> PcmChunkWriter = { f, rate -> AndroidStudioCodec.openM4a(f, rate) },
) {
    private fun open(file: File): PcmChunkWriter =
        writeM4a?.let { w -> BufferedM4aWriter(StudioAudio.CANONICAL_RATE, 2) { w(it, file) } } ?: openM4a(file, StudioAudio.CANONICAL_RATE)

    /**
     * Streams [capture] as canonical frames into [sink]: Quantized relabels the capture as canonical WITHOUT
     * resampling; Clean resamples to canonical (passthrough when the capture already is). Returns the canonical
     * frame count, or null for an empty/unreadable capture (sink untouched).
     */
    fun streamCanonical(capture: MasterCapture, sink: (FloatArray, Int) -> Unit): Long? {
        val h = MasterWav.header(capture.file) ?: return null
        if (h.frames <= 0) return null
        var total = 0L
        val count = { b: FloatArray, n: Int -> total += n; sink(b, n) }
        val resampler: StreamingResampler? = when {
            !capture.quantized -> StreamingResampler(h.sampleRate, StudioAudio.CANONICAL_RATE).takeIf { h.sampleRate != StudioAudio.CANONICAL_RATE }
            // Android taps the canonical mix, so there is no hardware-rate capture to relabel: emulate iOS's 48 kHz
            // hardware tap by resampling up to LOFI_HARDWARE_RATE first, then relabelling (the audible downpitch).
            h.sampleRate == StudioAudio.CANONICAL_RATE -> StreamingResampler(h.sampleRate, LOFI_HARDWARE_RATE)
            else -> null
        }
        MasterWav.readChunks(capture.file) { b, n -> if (resampler != null) resampler.process(b, n, count) else count(b, n) } ?: return null
        resampler?.finish(count)
        return total
    }

    /** Whole canonical PCM (tests / small captures). Null for an empty/unreadable capture. */
    fun toCanonical(capture: MasterCapture): PcmBuffer? {
        var acc = FloatArray(0); var len = 0
        streamCanonical(capture) { b, n ->
            if (acc.size < len + n * 2) acc = acc.copyOf(maxOf(acc.size * 2, len + n * 2))
            System.arraycopy(b, 0, acc, len, n * 2); len += n * 2
        } ?: return null
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, acc.copyOf(len))
    }

    /** Encode + file the artifact; the temp WAV is deleted either way. Null when nothing usable was captured. */
    fun bakeArtifact(
        arrangementId: String, capture: MasterCapture, dir: File, store: StudioStore, stamp: String,
        now: Double = System.currentTimeMillis().toDouble(),
    ): StudioArrangementArtifact? {
        var keepCapture = false
        try {
            // An unreadable non-empty capture is KEPT on disk, never silently deleted as "nothing recorded".
            if (MasterWav.header(capture.file)?.frames?.let { it > 0 } != true) {
                keepCapture = runCatching { capture.file.length() > 44 }.getOrDefault(false)
                return null
            }
            val fileName = "live-recording-$stamp.m4a"
            dir.mkdirs()
            val dest = File(dir, fileName)
            val tmp = File(dir, ".rec-${UUID.randomUUID()}-$fileName")
            var frames = 0L
            var writer: PcmChunkWriter? = null
            var encoderFailed = false
            try {
                val w = open(tmp)
                writer = w
                frames = streamCanonical(capture) { b, n -> try { w.write(b, n) } catch (e: Throwable) { encoderFailed = true; throw e } } ?: throw java.io.IOException("capture unreadable mid-bake")
                try { writer.close() } catch (e: Throwable) { encoderFailed = true; throw e }
                writer = null
                dest.delete()
                if (!tmp.renameTo(dest)) { encoderFailed = true; throw java.io.IOException("rename failed") }
            } catch (t: Throwable) {
                writer?.let { w -> runCatching { (w as? AacEncoder.Stream)?.abort() ?: w.close() } }
                // A READ failure keeps the raw capture (the user's only copy) for a re-bake; encoder faults don't.
                if (!encoderFailed) keepCapture = runCatching { capture.file.length() > 44 }.getOrDefault(false)
                if (t is kotlinx.coroutines.CancellationException) throw t
                return null
            } finally { tmp.delete() }
            val ms = Math.round(frames.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt()
            if (ms <= 0) { dest.delete(); return null }
            return store.addArrangementArtifact(
                StudioArrangementArtifact(StudioFactory.newArtifactId(), arrangementId, StudioArrangementArtifact.Kind.RECORDING, "live-recording-$stamp", fileName, ms, now),
            )
        } finally { if (!keepCapture) runCatching { capture.file.delete() } }
    }
}
