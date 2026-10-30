package com.levi.pocketdj.studio.engine

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Disk cache of stretched/windowed arranger clips as PCM16 page files (ANS-STU-5). One file per clip
 * window, named from a content key (source file + stamp + window + warp parameters), so a clip edit
 * changes the key and the stale page is simply never opened again ([invalidateSource] / [trim] delete it).
 *
 * File layout: 16-byte header ("PDJP", version, frames, reserved) then little-endian interleaved stereo int16.
 */
open class ClipPageStore(private val dir: File, private val maxBytes: Long = DEFAULT_MAX_BYTES) {

    /** Stable cache key for a clip window. [sourceStamp] must change when the source audio changes. */
    data class Key(val fileName: String, val sourceStamp: String, val fileStartMs: Int, val durationMs: Int,
                   val rate: Double, val pitchCents: Double, val baseRate: Int) {
        val prefix: String get() = prefixOf(fileName)
        val id: String get() = prefix + "-" + hex("$fileName|$sourceStamp|$fileStartMs|$durationMs|$rate|$pitchCents|$baseRate")
    }

    private fun file(key: Key) = File(dir, key.id + EXT)

    /** True when a complete page for [key] exists. */
    fun has(key: Key): Boolean = file(key).let { it.isFile && it.length() >= HEADER_BYTES && frames(it) >= 0 }

    private fun frames(f: File): Int = runCatching {
        f.inputStream().use { s ->
            val h = ByteArray(HEADER_BYTES); if (s.read(h) < HEADER_BYTES) return -1
            val bb = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
            if (bb.getInt(0) != MAGIC || bb.getInt(4) != VERSION) return -1
            val n = bb.getInt(8)
            if (f.length() != HEADER_BYTES + n.toLong() * 4) -1 else n
        }
    }.getOrDefault(-1)

    /** Write [frames] frames of interleaved [samples] (floats, clipped to [-1, 1]) atomically; returns the frame count. */
    fun write(key: Key, samples: FloatArray, frames: Int = samples.size / 2): Int =
        writeStream(key, frames) { out, at, n -> System.arraycopy(samples, at * 2, out, 0, n * 2) }

    /** Streaming write: [fill] receives (block, startFrame, frames) and fills the interleaved block. Heap stays O(block). */
    open fun writeStream(key: Key, frames: Int, blockFrames: Int = 16_384, fill: (FloatArray, Int, Int) -> Unit): Int {
        dir.mkdirs()
        val tmp = File(dir, ".tmp-${UUID.randomUUID()}")
        try {
            FileOutputStream(tmp).use { os ->
                val head = ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
                head.putInt(MAGIC).putInt(VERSION).putInt(frames)
                os.write(head.array())
                val fb = FloatArray(blockFrames * 2)
                val bb = ByteBuffer.allocate(blockFrames * 4).order(ByteOrder.LITTLE_ENDIAN)
                var at = 0
                while (at < frames) {
                    val n = minOf(blockFrames, frames - at)
                    fill(fb, at, n)
                    bb.clear()
                    for (i in 0 until n * 2) bb.putShort(quantize(fb[i]))
                    os.write(bb.array(), 0, n * 4)
                    at += n
                }
            }
            val dest = file(key)
            dest.delete()
            if (!tmp.renameTo(dest)) error("page rename failed")
        } catch (t: Throwable) { tmp.delete(); throw t }
        return frames
    }

    /** Map the cached page for [key], or null when absent/corrupt. */
    open fun open(key: Key): ClipReader? {
        val f = file(key)
        val n = if (f.isFile) frames(f) else -1
        if (n < 0) return null
        f.setLastModified(System.currentTimeMillis()) // LRU touch
        return runCatching { MappedPcm16ClipReader(f, n) }.getOrNull()
    }

    /** Delete every page derived from source [fileName] (clip file deleted / re-recorded). */
    fun invalidateSource(fileName: String) {
        val p = Key(fileName, "", 0, 0, 0.0, 0.0, 0).prefix + "-"
        dir.listFiles()?.filter { it.name.startsWith(p) }?.forEach { it.delete() }
    }

    /** Delete every page whose source file is not in [live] (clip deleted / re-recorded / abandoned warp fallback). */
    fun retainSources(live: Set<String>) {
        val keepPrefixes = live.map { prefixOf(it) + "-" }
        dir.listFiles()?.filter { f -> f.name.endsWith(EXT) && keepPrefixes.none { f.name.startsWith(it) } }?.forEach { it.delete() }
    }

    fun invalidate(key: Key) { file(key).delete() }

    fun clear() { dir.listFiles()?.forEach { it.delete() } }

    val sizeBytes: Long get() = dir.listFiles()?.sumOf { it.length() } ?: 0L

    /** LRU-evict pages (never those in [keep]) until the cache fits [maxBytes]. Returns the bytes freed. */
    open fun trim(keep: Set<Key> = emptySet()): Long {
        val protect = keep.map { it.id + EXT }.toSet()
        val files = dir.listFiles()?.toList() ?: return 0
        var total = files.sumOf { it.length() }
        var freed = 0L
        for (f in files.filter { it.name !in protect }.sortedBy { it.lastModified() }) {
            if (total <= maxBytes) break
            val len = f.length()
            if (f.delete()) { total -= len; freed += len }
        }
        return freed
    }

    companion object {
        const val HEADER_BYTES = 16
        private const val MAGIC = 0x50444A50 // "PJDP" little-endian tag, only needs to be stable
        private const val VERSION = 1
        const val EXT = ".pcm16"
        const val DEFAULT_MAX_BYTES = 2L * 1024 * 1024 * 1024

        /** Windows shorter than this stay on the heap (the in-memory path); ~20 s of canonical stereo. */
        const val SHORT_CLIP_FRAMES = 44_100 * 20

        fun quantize(x: Float): Short = (x.coerceIn(-1f, 1f) * 32768f).roundToInt().coerceIn(-32768, 32767).toShort()
        fun dequantize(s: Short): Float = s / 32768f

        /** Float samples snapped to the PCM16 grid (what a paged clip reads back); the reference for bit-exact comparisons. */
        fun snap(samples: FloatArray): FloatArray = FloatArray(samples.size) { dequantize(quantize(samples[it])) }

        fun prefixOf(fileName: String): String = hex(fileName).take(12)

        private fun hex(s: String): String =
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }.take(32)
    }
}
