package com.levi.pocketdj.data.transfers

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The WorkManager seam (a fake in unit tests). */
interface TransferWork {
    /** `enqueueUniqueWork(spec.uniqueName, KEEP, ...)`. */
    fun enqueue(spec: BurnWorkSpec)
    fun cancel(uniqueNames: Collection<String>)
    fun cancelAll()

    /** State per unique name; names with no work are absent. */
    suspend fun states(uniqueNames: Collection<String>): Map<String, WorkStateKind>
}

/** At most one publish per key per [intervalMs]; deltas accumulate in between (iOS 0.5 s doctrine). */
class BytesThrottle(private val intervalMs: Long = 500) {
    private val pending = HashMap<String, Long>()
    private val lastAt = HashMap<String, Long>()

    /** Returns the delta to publish now, or null while throttled. */
    @Synchronized
    fun add(key: String, delta: Long, nowMs: Long): Long? {
        val total = (pending[key] ?: 0L) + delta
        val last = lastAt[key]
        return if (last == null || nowMs - last >= intervalMs) {
            pending[key] = 0L
            lastAt[key] = nowMs
            total
        } else {
            pending[key] = total
            null
        }
    }

    @Synchronized fun forget(key: String) { pending.remove(key); lastAt.remove(key) }
    @Synchronized fun clear() { pending.clear(); lastAt.clear() }
}

/**
 * Background-transfer owner: port of iOS `TransferCoordinator` onto WorkManager.
 *
 * Invariants carried over:
 *  - the record is persisted (atomic file write) BEFORE the work is enqueued, so a death
 *    between the two is recoverable by [reconcileOnLaunch] / the ledger heal;
 *  - one in-flight transfer per song (upsert by songId);
 *  - an HTTP error body is never finalized as audio (worker side, see [BurnDownload]);
 *  - the bearer never rides to S3 / presigned / rips-base hosts ([BearerPolicy]);
 *  - progress counters are RUN-scoped ([beginRun] resets) and `cancel(songIds)` decrements
 *    `enqueued` so the overlay clears;
 *  - byte deltas publish at most once per 0.5 s per task.
 * Not main-thread bound: state sits behind a lock; hooks fire on the calling thread.
 */
class TransferCoordinator(
    private val file: File,
    private val work: TransferWork,
    /** Live rip-server token (may be empty). Read at enqueue only to decide the attach flag. */
    val tokenProvider: suspend () -> String = { "" },
    private val ripsHost: () -> String? = { null },
    private val clock: () -> Long = System::currentTimeMillis,
    private val newWorkId: () -> String = { UUID.randomUUID().toString() },
) {
    private val json = PdjJson.lenient
    private val lock = Any()
    private var tasks: List<TransferRecord> = emptyList()
    private var enqueuedTotal = 0
    private var finishedTotal = 0
    private val throttle = BytesThrottle()
    /** Songs enqueued by THIS process: their WorkManager insert may still be in flight at launch reconcile. */
    private val enqueuedHere = HashSet<String>()

    private val _progress = MutableStateFlow(TransferProgress())
    /** UI binds ONLY to this mirror, never to worker internals. */
    val progress: StateFlow<TransferProgress> = _progress.asStateFlow()

    @Volatile var onBurnFinalized: ((TransferRecord, Long) -> Unit)? = null
    @Volatile var onBurnFailed: ((TransferRecord, String) -> Unit)? = null
    @Volatile var onProgress: ((enqueued: Int, finished: Int) -> Unit)? = null
    /** (songId, byte delta since last publish) */
    @Volatile var onBytes: ((String, Long) -> Unit)? = null

    init {
        if (file.isFile) {
            try {
                tasks = json.decodeFromString(TransferDoc.serializer(), file.readText()).tasks
            } catch (_: Exception) {
                runCatching { file.renameTo(File(file.parentFile, file.name + ".corrupt-" + clock())) }
            }
        }
    }

    val records: List<TransferRecord> get() = synchronized(lock) { tasks }

    fun record(songId: String): TransferRecord? = synchronized(lock) { tasks.firstOrNull { it.songId == songId } }

    fun counters(): TransferProgress = synchronized(lock) { TransferProgress(enqueuedTotal, finishedTotal) }

    private fun persistLocked() {
        val text = json.encodeToString(TransferDoc.serializer(), TransferDoc(tasks = tasks))
        file.parentFile?.mkdirs()
        val part = File(file.parentFile, file.name + ".part")
        try {
            part.writeText(text)
            Files.move(part.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } finally {
            if (part.exists()) part.delete()
        }
    }

    private fun publish() {
        val (e, f) = synchronized(lock) { enqueuedTotal to finishedTotal }
        _progress.value = TransferProgress(e, f)
        onProgress?.invoke(e, f)
    }

    /** Reset run-scoped counters at the START of a burn run (else a 2nd burn shows "4 of 5"). */
    fun beginRun() {
        synchronized(lock) { enqueuedTotal = 0; finishedTotal = 0 }
        publish()
    }

    /**
     * Persist [record] (BEFORE the work request exists), then enqueue unique work. [url] is the
     * durable (presigned) URL; it rides in the work input because the worker must survive death.
     */
    suspend fun enqueue(url: String, record: TransferRecord): String {
        val attach = BearerPolicy.shouldAttachBearer(url, tokenProvider(), ripsHost())
        val workId = newWorkId()
        val rec = record.copy(taskIdentifier = stableTaskId(record.songId), workId = workId)
        synchronized(lock) {
            tasks = tasks.filter { it.songId != rec.songId } + rec
            enqueuedTotal += 1
            enqueuedHere += rec.songId
            persistLocked()
        }
        publish()
        work.enqueue(BurnWorkSpec(burnUniqueName(rec.songId), workId, rec.songId, url, attach))
        return workId
    }

    /** Stop for [songIds]: cancel their work, drop their records, clear them from the overlay. */
    fun cancel(songIds: Collection<String>) {
        val ids = songIds.toSet()
        val dropped = synchronized(lock) {
            val gone = tasks.filter { it.songId in ids }
            tasks = tasks.filter { it.songId !in ids }
            gone.forEach { throttle.forget(it.songId) }
            enqueuedTotal = maxOf(0, enqueuedTotal - gone.size)
            persistLocked()
            gone
        }
        publish()
        work.cancel(dropped.map { burnUniqueName(it.songId) })
    }

    fun cancelAll() {
        synchronized(lock) {
            tasks = emptyList(); enqueuedTotal = 0; finishedTotal = 0
            throttle.clear()
            persistLocked()
        }
        publish()
        work.cancelAll()
    }

    /**
     * Cross-check records against WorkManager. A record whose unique work is absent or finished
     * is dropped (the move already happened in the worker, or the temp is gone; the ledger heal
     * resolves the item); live work is kept and keeps running. Idempotent. Returns dropped songIds.
     */
    suspend fun reconcileOnLaunch(): List<String> {
        val snapshot = synchronized(lock) { tasks.filter { it.songId !in enqueuedHere } }
        if (snapshot.isEmpty()) return emptyList()
        val states = work.states(snapshot.map { burnUniqueName(it.songId) })
        val dead = snapshot.filter { states[burnUniqueName(it.songId)]?.live != true }.map { it.songId }.toSet()
        if (dead.isEmpty()) return emptyList()
        synchronized(lock) {
            tasks = tasks.filter { it.songId !in dead }
            persistLocked()
        }
        return dead.toList()
    }

    // ---- worker callbacks ---------------------------------------------------------------------

    /** Throttled byte progress from a running worker. */
    fun reportBytes(songId: String, delta: Long, nowMs: Long = clock()) {
        val publishDelta = throttle.add(songId, delta, nowMs) ?: return
        onBytes?.invoke(songId, publishDelta)
    }

    /** Worker finished (file + sidecar in place): drop the record, bump progress, finalize the item. */
    fun onFinished(record: TransferRecord, bytes: Long) {
        synchronized(lock) {
            tasks = tasks.filter { it.songId != record.songId }
            finishedTotal += 1
            throttle.forget(record.songId)
            persistLocked()
        }
        publish()
        onBurnFinalized?.invoke(record, bytes)
    }

    /** Terminal failure: drop the record and let the row show an error. Settled counts as finished. */
    fun onFailed(record: TransferRecord, message: String) {
        synchronized(lock) {
            tasks = tasks.filter { it.songId != record.songId }
            finishedTotal += 1
            throttle.forget(record.songId)
            persistLocked()
        }
        publish()
        onBurnFailed?.invoke(record, message)
    }
}
