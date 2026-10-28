package com.levi.pocketdj.diag

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Schedules the debounce flush; the returned lambda cancels it. */
fun interface DiagScheduler {
    fun schedule(delayMs: Long, block: () -> Unit): () -> Unit

    companion object {
        fun system(): DiagScheduler {
            val ex: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
                Thread(r, "diag-flush").apply { isDaemon = true }
            }
            return DiagScheduler { delay, block ->
                val f: ScheduledFuture<*> = ex.schedule({ runCatching(block) }, delay, TimeUnit.MILLISECONDS)
                ({ f.cancel(false); Unit })
            }
        }
    }
}

/**
 * Remote diagnostics (port of iOS `DiagLog`). Buffers secret-free event lines and uploads the
 * session log to a private S3 prefix. Parts of 500 lines (`-p2`, `-p3`…), each rewritten in
 * full on every flush; flush 15 s after the first new line (3 s in telemetry mode), at once
 * for `error`, and at 25 pending lines. Uploads are serialized and only the newest body per
 * key is sent. Keyless lines are buffered (bounded) and upload when a key arrives.
 */
class DiagLog(
    enabled: Boolean,
    private val credentialStore: DiagCredentialStore,
    private val settings: DiagSettings,
    private val uploader: DiagUploader,
    private val scope: CoroutineScope,
    private val scheduler: DiagScheduler,
    private val clock: () -> Long,
    private val keyBase: String,
    /** Why uploads are off when [enabled] is false (Settings readout). */
    private val offReason: String = "release build (uploads disabled by design)",
    private val launchLine: String? = null,
    private val endpointsLine: String? = null,
) {
    private val lock = Any()
    @Volatile private var enabled: Boolean = enabled
    private var credentials: DiagCredentialStore.Credentials? = if (enabled) credentialStore.load() else null

    private val lines = ArrayList<String>()
    private var dirty = 0
    private var totalLines = 0
    private var part = 1
    private var keylessOverflowMarked = false
    private var cancelFlush: (() -> Unit)? = null

    private val pending = LinkedHashMap<String, ByteArray>()
    private var pumping = false
    private var pumpJob: Job? = null

    /** Optional capture mirror (Settings ▸ Debug); fed even when uploads are disabled. */
    @Volatile var capture: CaptureSessions? = null

    private val _status = MutableStateFlow(settings.loadStatus(enabled, credentials != null).copy(offReason = offReason))
    val uploadStatus: StateFlow<UploadStatus> = _status

    var telemetryEnabled: Boolean = false
        set(v) {
            val old = field
            field = v
            if (enabled && v != old) log("telemetry", if (v) "mode ON" else "mode OFF")
        }

    private val objectKey: String get() = if (part == 1) "$keyBase.log" else "$keyBase-p$part.log"

    init {
        if (enabled) {
            launchLine?.let { log("launch", it) }
            endpointsLine?.let { log("endpoints", it) }
            log("diag", "status ${statusLine()}")
        }
    }

    fun isEnabled(): Boolean = enabled

    /** Settings ▸ Debug "Remote diagnostics" toggle (inside a diag-channel build). */
    fun setEnabled(on: Boolean) {
        synchronized(lock) {
            if (enabled == on) return
            enabled = on
            credentials = if (on) credentialStore.load() else null
            _status.value = _status.value.copy(channelEnabled = on, keyPresent = credentials != null)
        }
        if (on) {
            log("diag", "remote diagnostics ON")
            launchLine?.let { log("launch", it) }
            endpointsLine?.let { log("endpoints", it) }
            log("diag", "status ${statusLine()}")
        } else cancelFlushLocked()
    }

    private fun cancelFlushLocked() = synchronized(lock) { cancelFlush?.invoke(); cancelFlush = null }

    private fun statusLine(): String {
        val s = _status.value
        val ok = s.lastSuccessAt?.let { iso(it) } ?: "never"
        val err = s.lastError?.let { "$it@${s.lastErrorAt?.let(::iso) ?: "?"}" } ?: "none"
        return "key=${if (s.keyPresent) "present" else "MISSING"} last-ok=$ok last-err=$err"
    }

    /** Re-read the key after import/removal. Gaining a key uploads everything buffered so far. */
    fun reloadCredentials() {
        if (!enabled) return
        val gained: Boolean
        val lost: Boolean
        synchronized(lock) {
            val had = credentials != null
            credentials = credentialStore.load()
            _status.value = _status.value.copy(keyPresent = credentials != null)
            gained = !had && credentials != null
            lost = had && credentials == null
        }
        if (gained) {
            log("diag", "key configured; late start — uploading ${synchronized(lock) { lines.size }} buffered line(s)")
            flushNow()
        } else if (lost) {
            log("diag", "key REMOVED — uploads stopped")
        }
    }

    /** Append one event line. `error` flushes immediately. NEVER pass secrets. */
    fun log(category: String, message: String) {
        val line = "${iso(clock())} [$category] $message"
        capture?.append(line)
        if (!enabled) return
        var flushImmediately = false
        var seal = false
        synchronized(lock) {
            if (totalLines >= SESSION_LINE_LIMIT) return
            val ts = iso(clock())
            if (credentials == null) {
                if (lines.size < PART_LINE_LIMIT - 1) {
                    totalLines++
                    lines.add(line)
                    dirty++
                } else if (!keylessOverflowMarked) {
                    keylessOverflowMarked = true
                    lines.add("$ts [diag] keyless buffer full — later lines dropped until a key arrives")
                    dirty++
                }
                return
            }
            totalLines++
            if (totalLines == SESSION_LINE_LIMIT) {
                lines.add("$ts [telemetry] session line cap reached — logging muted")
                dirty++
                flushImmediately = true
            } else {
                lines.add(line)
                dirty++
                if (lines.size >= PART_LINE_LIMIT) seal = true
                else if (category == "error" || dirty >= DIRTY_FLUSH) flushImmediately = true
                else if (cancelFlush == null) {
                    val delay = if (telemetryEnabled) TELEMETRY_DEBOUNCE_MS else DEBOUNCE_MS
                    cancelFlush = scheduler.schedule(delay) { flushNow() }
                }
            }
        }
        if (seal) seal() else if (flushImmediately) flushNow()
    }

    /** Rich-telemetry line; no-op unless the owner's Remote telemetry toggle is on. */
    fun telemetry(category: String, message: String) {
        if (!telemetryEnabled) return
        log(category, message)
    }

    /** Backgrounding would strand tail lines — push them out now. */
    fun flushOnBackground() {
        if (!enabled || synchronized(lock) { credentials == null }) return
        flushNow()
    }

    /** Flush and wait (bounded) for queued uploads — the ON_STOP funnel. */
    suspend fun flushAndWait(timeoutMs: Long = 5_000) {
        flushOnBackground()
        withTimeoutOrNull(timeoutMs) { awaitUploads() }
    }

    suspend fun awaitUploads() {
        while (true) {
            val j = synchronized(lock) { pumpJob } ?: return
            j.join()
            if (synchronized(lock) { !pumping && pending.isEmpty() }) return
        }
    }

    private fun flushNow() {
        val key: String
        val body: ByteArray
        synchronized(lock) {
            cancelFlush?.invoke(); cancelFlush = null
            if (dirty == 0 || credentials == null) return
            dirty = 0
            key = objectKey
            body = (lines.joinToString("\n") + "\n").toByteArray()
        }
        enqueue(key, body)
    }

    private fun seal() {
        val key: String
        val body: ByteArray
        synchronized(lock) {
            cancelFlush?.invoke(); cancelFlush = null
            key = objectKey
            body = (lines.joinToString("\n") + "\n").toByteArray()
            part++
            lines.clear()
            lines.add("${iso(clock())} [rotate] continues in part $part")
            dirty = 1
        }
        enqueue(key, body)
    }

    private fun enqueue(key: String, body: ByteArray) {
        synchronized(lock) {
            pending[key] = body // newest wins; position of an already-queued key is kept
            if (pumping) return
            pumping = true
            pumpJob = scope.launch { pump() }
        }
    }

    private suspend fun pump() {
        while (true) {
            val key: String
            val body: ByteArray
            val creds: DiagCredentialStore.Credentials
            synchronized(lock) {
                val e = pending.entries.firstOrNull()
                if (e == null) { pumping = false; return }
                key = e.key; body = e.value
                pending.remove(key)
                creds = credentials ?: run { pending.clear(); pumping = false; return }
            }
            val outcome = try {
                uploader.put(key, body, creds)
            } catch (e: kotlinx.coroutines.CancellationException) {
                synchronized(lock) { pumping = false }
                throw e
            } catch (e: Exception) {
                UploadOutcome.Transport(e.javaClass.simpleName)
            }
            record(outcome)
        }
    }

    /** Fold one PUT outcome into the persisted status; log only ok⇄failing TRANSITIONS. */
    private fun record(outcome: UploadOutcome) {
        val now = clock()
        var toLog: String? = null
        synchronized(lock) {
            val s = _status.value
            val wasFailing = s.failing
            val firstResult = s.lastSuccessAt == null && s.lastErrorAt == null
            val err = outcome.errorText
            if (err != null) {
                settings.saveError(err, now)
                _status.value = s.copy(lastError = err, lastErrorAt = now)
                if (!wasFailing || firstResult) toLog = "upload FAILED $err"
            } else {
                settings.saveSuccess(now)
                _status.value = s.copy(lastSuccessAt = now)
                if (wasFailing) toLog = "upload recovered (was ${s.lastError ?: "?"})"
            }
        }
        toLog?.let { log("diag", it) }
    }

    companion object {
        /** Process singleton set by the services graph; null in JVM tests. */
        @Volatile var shared: DiagLog? = null

        const val PART_LINE_LIMIT = 500
        const val SESSION_LINE_LIMIT = 40_000
        const val DIRTY_FLUSH = 25
        const val DEBOUNCE_MS = 15_000L
        const val TELEMETRY_DEBOUNCE_MS = 3_000L

        private val ISO: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
        private val STAMP: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss'Z'").withZone(ZoneOffset.UTC)

        fun iso(ms: Long): String = ISO.format(Instant.ofEpochMilli(ms))

        /** `diag/android-<installId8>/<launch stamp>-b<versionCode>` (+ `[-pN].log`). */
        fun keyBase(installId: String, launchMs: Long, versionCode: Int): String =
            "diag/android-${installId.take(8)}/${STAMP.format(Instant.ofEpochMilli(launchMs))}-b$versionCode"
    }
}
