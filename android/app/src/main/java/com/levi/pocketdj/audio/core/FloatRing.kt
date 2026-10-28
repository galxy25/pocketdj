package com.levi.pocketdj.audio.core

/**
 * Lock-free single-producer / single-consumer ring of floats (interleaved PCM). The producer
 * (decoder thread) calls [write]; the consumer (render thread) calls [read] / [skip] /
 * [clearConsumer]. Neither side allocates or blocks. Indices are monotonically increasing Longs;
 * a volatile store publishes the data written before it.
 */
class FloatRing(val capacity: Int) {
    init { require(capacity > 0) }

    private val buf = FloatArray(capacity)
    @Volatile private var head = 0L // total floats written (producer-owned)
    @Volatile private var tail = 0L // total floats consumed (consumer-owned)

    /** Floats ready to read. Exact from the consumer side; a lower bound from the producer's. */
    val readable: Int get() = (head - tail).toInt()

    /** Floats that can be written. Exact from the producer side; a lower bound from the consumer's. */
    val writable: Int get() = capacity - (head - tail).toInt()

    /** Producer: copy up to [n] floats from [src]; returns how many fit. */
    fun write(src: FloatArray, off: Int, n: Int): Int {
        val h = head
        val count = minOf(n, capacity - (h - tail).toInt())
        if (count <= 0) return 0
        val start = (h % capacity).toInt()
        val first = minOf(count, capacity - start)
        System.arraycopy(src, off, buf, start, first)
        if (count > first) System.arraycopy(src, off + first, buf, 0, count - first)
        head = h + count
        return count
    }

    /** Consumer: copy up to [n] floats into [dst]; returns how many were available. */
    fun read(dst: FloatArray, off: Int, n: Int): Int {
        val t = tail
        val count = minOf(n, (head - t).toInt())
        if (count <= 0) return 0
        val start = (t % capacity).toInt()
        val first = minOf(count, capacity - start)
        System.arraycopy(buf, start, dst, off, first)
        if (count > first) System.arraycopy(buf, 0, dst, off + first, count - first)
        tail = t + count
        return count
    }

    /** Consumer: drop up to [n] floats. */
    fun skip(n: Int): Int {
        val count = minOf(n, (head - tail).toInt())
        if (count > 0) tail += count
        return maxOf(count, 0)
    }

    /** Consumer: drop everything currently readable (only safe while the producer is quiescent). */
    fun clearConsumer() { tail = head }
}
