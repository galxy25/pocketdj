package com.levi.pocketdj.data.transfers

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.levi.pocketdj.data.burns.BurnDestinationResolver
import com.levi.pocketdj.data.burns.BurnReconciler
import com.levi.pocketdj.data.burns.BurnTree
import com.levi.pocketdj.data.burns.isOutOfSpace
import com.levi.pocketdj.di.AppGraph
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Result of one download attempt. */
sealed interface DownloadOutcome {
    data class Done(val bytes: Long) : DownloadOutcome
    /** Terminal: the record fails and the row shows [message]. NEVER leaves an audio file behind. */
    data class Failed(val message: String, val httpCode: Int? = null) : DownloadOutcome
    /** Transient transport failure: WorkManager backoff retries. */
    data class Retry(val message: String) : DownloadOutcome

    companion object {
        /** Shared analog album already on disk: no download, just the per-song sidecar. */
        fun finishShared(record: TransferRecord, dir: File): DownloadOutcome = try {
            val audio = File(dir, record.audioFileName)
            writeSidecar(record, dir)
            Done(audio.length())
        } catch (e: IOException) {
            if (isOutOfSpace(e)) Failed("out of space") else Retry(e.message ?: "I/O error")
        }

        private fun writeSidecar(record: TransferRecord, dir: File) {
            if (record.sidecarFileName.isEmpty()) return
            val dest = File(dir, record.sidecarFileName)
            val sp = File(dir, record.sidecarFileName + ".part")
            try {
                sp.writeBytes(record.sidecarText.toByteArray())
                Files.move(sp.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING)
            } finally {
                if (sp.exists()) sp.delete()
            }
        }

        /**
         * Pure-ish core (the iOS `didFinishDownloadingTo`): turn an HTTP [response] into files in
         * [dir]. A non-2xx response is NEVER finalized as audio (S3's 400 XML was 536 bytes);
         * a 2xx that is itself a tiny error document is rejected too. Audio goes `.part` ->
         * atomic rename; analog shared album files are never clobbered; the sidecar is written
         * from the record's pre-rendered text.
         */
        fun from(
            response: Response,
            record: TransferRecord,
            dir: File,
            onBytes: (Long) -> Unit = {},
            isCancelled: () -> Boolean = { false },
        ): DownloadOutcome = response.use { resp ->
            if (!resp.isSuccessful) return Failed("download failed (HTTP ${resp.code})", resp.code)
            try {
                dir.mkdirs()
                val audio = File(dir, record.audioFileName)
                val analogShared = record.source == "analog" && audio.isFile && audio.length() > 0
                val bytes: Long
                if (analogShared) {
                    bytes = audio.length()
                } else {
                    val body = resp.body ?: return Failed("empty response body")
                    // Unique per worker: siblings sharing one analog album file must not truncate each other.
                    val part = File(dir, record.audioFileName + "." + (record.workId ?: UUID.randomUUID().toString()) + ".part")
                    try {
                        part.outputStream().use { out ->
                            val buf = ByteArray(64 * 1024)
                            body.byteStream().use { input ->
                                while (true) {
                                    if (isCancelled()) throw IOException("canceled")
                                    val n = input.read(buf)
                                    if (n < 0) break
                                    out.write(buf, 0, n)
                                    onBytes(n.toLong())
                                }
                            }
                        }
                        if (BurnReconciler.isPoisoned(part)) return Failed("server returned an error document")
                        // A sibling may have landed the shared analog album meanwhile: first move wins.
                        if (record.source == "analog" && audio.isFile && audio.length() > 0) part.delete()
                        else Files.move(part.toPath(), audio.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    } finally {
                        if (part.exists()) part.delete()
                    }
                    bytes = audio.length()
                }
                writeSidecar(record, dir)
                Done(bytes)
            } catch (e: IOException) {
                if (isOutOfSpace(e)) Failed("out of space") else Retry(e.message ?: "I/O error")
            }
        }
    }
}

/** The worker body, free of Android so it runs on the JVM (MockWebServer + fake coordinator seam). */
class BurnDownloadRunner(
    private val coordinator: TransferCoordinator,
    private val http: OkHttpClient,
    private val destDir: (TransferRecord) -> File?,
    private val maxAttempts: Int = 5,
    /** Fresh presigned URL for a record (the stored one may have expired while work was deferred). */
    private val refreshUrl: (suspend (TransferRecord) -> String?)? = null,
    /** SVC-14: when set, the destination comes from the RECORD (captured at enqueue), never settings. */
    private val resolver: BurnDestinationResolver? = null,
) {
    enum class Result { SUCCESS, RETRY }

    private companion object {
        /** Serializes workers that share one analog album file (per dest path). */
        val albumLocks = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.sync.Mutex>()
    }

    suspend fun run(songId: String, url: String, attachBearer: Boolean, runAttemptCount: Int): Result {
        // No record => cancelled (Stop) or already settled: nothing safe to do.
        val stored = coordinator.record(songId) ?: return Result.SUCCESS
        val resolved = resolver?.resolve(stored)
        // Finalize with the resolved record: an unavailable tree flips wasAppStorage to true.
        val record = resolved?.record ?: stored
        val dir = resolved?.dir ?: destDir(stored)
        if (dir == null) {
            coordinator.onFailed(record, "no writable burn folder")
            return Result.SUCCESS
        }
        val isAnalog = record.source == "analog"
        val lock = if (isAnalog) albumLocks.getOrPut(File(dir, record.audioFileName).path) { kotlinx.coroutines.sync.Mutex() } else null
        val outcome = if (lock != null) lock.withLock { fetch(record, dir, url, attachBearer) } else fetch(record, dir, url, attachBearer)
        // The record may have been cancelled mid-flight; don't resurrect the item.
        if (coordinator.record(songId) == null) {
            // Cancelled after the body finished: don't leak files with no ledger row.
            if (outcome is DownloadOutcome.Done) {
                if (record.source != "analog") File(dir, record.audioFileName).delete()
                if (record.sidecarFileName.isNotEmpty()) File(dir, record.sidecarFileName).delete()
            }
            return Result.SUCCESS
        }
        return when (outcome) {
            is DownloadOutcome.Done -> {
                val tree = resolved?.tree
                if (tree == null) {
                    coordinator.onFinished(record, outcome.bytes)
                } else {
                    // A failed tree copy keeps the staged files and wasAppStorage=false: they are local,
                    // playable and (for analog) shared with finished siblings; the mirror can be redone.
                    withContext(Dispatchers.IO) { mirrorToTree(record, dir, tree) }
                    coordinator.onFinished(record, outcome.bytes)
                }
                Result.SUCCESS
            }
            is DownloadOutcome.Failed -> { coordinator.onFailed(record, outcome.message); Result.SUCCESS }
            is DownloadOutcome.Retry ->
                if (runAttemptCount + 1 >= maxAttempts) {
                    coordinator.onFailed(record, outcome.message); Result.SUCCESS
                } else Result.RETRY
        }
    }

    /** Copy the staged audio (+ sidecar) into the user's tree; false => caller falls back to app storage. */
    private fun mirrorToTree(record: TransferRecord, stage: File, tree: BurnTree): Boolean = try {
        val audio = File(stage, record.audioFileName)
        // Analog album mp3 is shared by sibling songs: never re-copy it over an existing one.
        if (!(record.source == "analog" && tree.exists(record.audioFileName))) tree.copyIn(record.audioFileName, audio)
        if (record.sidecarFileName.isNotEmpty()) tree.copyIn(record.sidecarFileName, File(stage, record.sidecarFileName))
        true
    } catch (_: IOException) {
        false
    }

    private suspend fun fetch(record: TransferRecord, dir: File, url: String, attachBearer: Boolean): DownloadOutcome {
        val songId = record.songId
        if (record.source == "analog") {
            val audio = File(dir, record.audioFileName)
            if (audio.isFile && audio.length() > 0) return withContext(Dispatchers.IO) { DownloadOutcome.finishShared(record, dir) }
        }
        val first = attempt(record, dir, url, attachBearer)
        if (first is DownloadOutcome.Failed && first.httpCode == 403 && refreshUrl != null) {
            val fresh = runCatching { refreshUrl?.invoke(record) }.getOrNull()
            if (fresh != null && fresh != url) return attempt(record, dir, fresh, false)
        }
        return first
    }

    private suspend fun attempt(record: TransferRecord, dir: File, url: String, attachBearer: Boolean): DownloadOutcome {
        val songId = record.songId
        val req = Request.Builder().url(url).apply {
            if (attachBearer) {
                val token = coordinator.tokenProvider()
                if (token.isNotEmpty()) header("Authorization", "Bearer $token")
            }
        }.build()
        val job = currentCoroutineContext().job
        return coroutineScope {
            val call = http.newCall(req)
            // Cancelling the worker (Stop) must abort the blocking socket read.
            val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                try { awaitCancellation() } finally { call.cancel() }
            }
            try {
                withContext(Dispatchers.IO) {
                    val resp = try {
                        call.execute()
                    } catch (e: IOException) {
                        if (job.isCancelled) throw CancellationException("canceled")
                        return@withContext DownloadOutcome.Retry(e.message ?: "network error")
                    }
                    DownloadOutcome.from(resp, record, dir, { coordinator.reportBytes(songId, it) }, { job.isCancelled })
                }
            } finally {
                watcher.cancel()
            }
        }
    }
}

/** Long-running foreground worker: one per song, `enqueueUniqueWork("burn:<songId>", KEEP)`. */
class BurnDownloadWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val tc = AppGraph.get(applicationContext).servicesGraph.transferRuntime().coordinator
        val n = TransferNotifications.build(applicationContext, tc.counters())
        return if (Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(TransferNotifications.NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else ForegroundInfo(TransferNotifications.NOTIFICATION_ID, n)
    }

    override suspend fun doWork(): Result {
        val songId = inputData.getString(KEY_SONG_ID) ?: return Result.success()
        val url = inputData.getString(KEY_URL) ?: return Result.success()
        val attach = inputData.getBoolean(KEY_ATTACH_BEARER, false)
        val rt = AppGraph.get(applicationContext).servicesGraph.transferRuntime()
        // A start from the background can be refused on API 31+; the download still proceeds.
        runCatching { setForeground(getForegroundInfo()) }
        val r = BurnDownloadRunner(rt.coordinator, rt.http, rt.destDir, refreshUrl = rt.refreshUrl, resolver = rt.resolver).run(songId, url, attach, runAttemptCount)
        return if (r == BurnDownloadRunner.Result.RETRY) Result.retry() else Result.success()
    }

    companion object {
        const val KEY_SONG_ID = "songId"
        const val KEY_URL = "url"
        const val KEY_ATTACH_BEARER = "attachBearer"

        fun inputData(spec: BurnWorkSpec): Data = workDataOf(
            KEY_SONG_ID to spec.songId, KEY_URL to spec.url, KEY_ATTACH_BEARER to spec.attachBearer,
        )
    }
}

/** What a worker needs from the graph; assembled by ServicesGraph.transferRuntime(). */
class TransferRuntime(
    val coordinator: TransferCoordinator,
    val http: OkHttpClient,
    val destDir: (TransferRecord) -> File?,
    val refreshUrl: (suspend (TransferRecord) -> String?)? = null,
    val resolver: BurnDestinationResolver? = null,
)

/** Real WorkManager-backed [TransferWork]. */
class WorkManagerTransferWork(context: Context) : TransferWork {
    private val wm = WorkManager.getInstance(context.applicationContext)

    override fun enqueue(spec: BurnWorkSpec) {
        val req = OneTimeWorkRequest.Builder(BurnDownloadWorker::class.java)
            .setId(UUID.fromString(spec.workId))
            .setInputData(BurnDownloadWorker.inputData(spec))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag("burn")
            .build()
        wm.enqueueUniqueWork(spec.uniqueName, ExistingWorkPolicy.KEEP, req)
    }

    override fun cancel(uniqueNames: Collection<String>) = uniqueNames.forEach { wm.cancelUniqueWork(it) }

    override fun cancelAll() { wm.cancelAllWorkByTag("burn") }

    override suspend fun states(uniqueNames: Collection<String>): Map<String, WorkStateKind> =
        withContext(Dispatchers.IO) {
            val out = HashMap<String, WorkStateKind>()
            for (name in uniqueNames) {
                val infos = wm.getWorkInfosForUniqueWork(name).get()
                // Prefer a live entry; else any terminal one.
                val best = infos.map { it.state.toKind() }.let { l -> l.firstOrNull { it.live } ?: l.lastOrNull() }
                if (best != null) out[name] = best
            }
            out
        }

    private fun WorkInfo.State.toKind() = when (this) {
        WorkInfo.State.ENQUEUED -> WorkStateKind.ENQUEUED
        WorkInfo.State.RUNNING -> WorkStateKind.RUNNING
        WorkInfo.State.BLOCKED -> WorkStateKind.BLOCKED
        WorkInfo.State.SUCCEEDED -> WorkStateKind.SUCCEEDED
        WorkInfo.State.FAILED -> WorkStateKind.FAILED
        WorkInfo.State.CANCELLED -> WorkStateKind.CANCELLED
    }
}
