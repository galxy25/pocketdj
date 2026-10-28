package com.levi.pocketdj.data.store

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The program-wide atomic, off-main, VERSION-ORDERED JSON document writer (decision D6;
 * reused by MIX-1, PB-4, STU-1). Mirrors the iOS `CollectionsDocumentWriter` actor.
 *
 * Contract:
 *  - Callers hand it a monotonically increasing `version` per mutation plus a `render`
 *    lambda (encode runs ON THE WRITER'S EXECUTOR, not the caller's thread).
 *  - A write/delete whose version is <= the highest version already applied (or
 *    invalidated) is DROPPED, so a straggler queued behind a newer write can never put
 *    stale bytes on disk.
 *  - [flushNow] applies inline (caller thread) and raises the floor first, so queued
 *    stragglers are dropped; used on ON_STOP so a process kill cannot lose a queued write.
 *  - [invalidate] raises the floor without writing — the seam for a future pull that
 *    supersedes queued local writes.
 *
 * Disk writes are temp-file + rename, serialized by [applyLock].
 */
class VersionedJsonWriter(
    private val file: File,
    private val executor: Executor = DIRECT,
) {
    private val applyLock = Any()
    private var applied: Long = Long.MIN_VALUE

    /** Count of disk operations actually performed (test/diagnostic). */
    @Volatile
    var writeCount: Int = 0
        private set

    /** Highest version applied or invalidated. */
    val appliedVersion: Long get() = synchronized(applyLock) { applied }

    /** Queue a write; encodes via [render] on the executor. */
    fun write(version: Long, render: () -> String) {
        executor.execute { applyWrite(version, render) }
    }

    /** Queue a delete, version-ordered against writes. */
    fun delete(version: Long) {
        executor.execute { applyDelete(version) }
    }

    /** Drop every queued operation with version <= [through]. */
    fun invalidate(through: Long) {
        synchronized(applyLock) { if (through > applied) applied = through }
    }

    /** Barrier: invalidate stragglers THEN write inline on the caller's thread. */
    fun flushNow(version: Long, render: () -> String) {
        invalidateBelow(version)
        applyWrite(version, render)
    }

    /** Inline delete on the caller's thread; supersedes every queued op with a lower version. */
    fun deleteNow(version: Long) {
        invalidateBelow(version)
        applyDelete(version)
    }

    /** Block until everything queued before this call has executed. */
    fun awaitIdle() {
        val latch = CountDownLatch(1)
        executor.execute { latch.countDown() }
        latch.await()
    }

    private fun invalidateBelow(version: Long) {
        // Everything strictly older than the inline write is superseded by it.
        synchronized(applyLock) { if (version - 1 > applied) applied = version - 1 }
    }

    private fun applyWrite(version: Long, render: () -> String) {
        // A burst of N events must not cost N full encodes: skip the render when a newer write already landed.
        if (synchronized(applyLock) { version <= applied }) return
        val text = try {
            render()
        } catch (_: Exception) {
            return
        }
        synchronized(applyLock) {
            if (version <= applied) return
            applied = version
            try {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(text)
                if (!tmp.renameTo(file)) {
                    // Overwrite-copy in place: no delete() window a process kill could turn into total loss.
                    tmp.copyTo(file, overwrite = true)
                    tmp.delete()
                }
                writeCount++
            } catch (_: Exception) {
                // Best-effort; in-memory state stays authoritative.
            }
        }
    }

    private fun applyDelete(version: Long) {
        synchronized(applyLock) {
            if (version <= applied) return
            applied = version
            runCatching { file.delete() }
            writeCount++
        }
    }

    companion object {
        /** Runs on the caller's thread (default: deterministic for tests). */
        val DIRECT: Executor = Executor { it.run() }

        /** A single daemon thread — production wiring (strict FIFO, off-main). */
        fun backgroundExecutor(name: String = "pdj-json-writer"): ExecutorService =
            Executors.newSingleThreadExecutor { r -> Thread(r, name).apply { isDaemon = true } }
    }
}
