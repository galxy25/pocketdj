package com.levi.pocketdj.mix.recording

import com.levi.pocketdj.mix.store.MixRecording
import com.levi.pocketdj.mix.store.MixSessionStore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** The slice of the session store the recorder files takes onto (a port for JVM tests). */
interface RecordingSessions {
    val currentId: String
    fun recordings(sessionId: String): List<MixRecording>
    /** Attach a take; null when the session no longer exists. */
    fun addRecording(sessionId: String, fileName: String, startedAt: Double, durationMs: Int): String?
    /** Re-file a take, reviving a deleted session. */
    fun recoverRecording(sessionId: String, name: String, fileName: String, startedAt: Double, durationMs: Int)
}

fun MixSessionStore.asRecordingSessions() = object : RecordingSessions {
    override val currentId get() = this@asRecordingSessions.currentId
    override fun recordings(sessionId: String) = this@asRecordingSessions.recordings(sessionId)
    override fun addRecording(sessionId: String, fileName: String, startedAt: Double, durationMs: Int) =
        this@asRecordingSessions.addRecording(sessionId, fileName, startedAt, durationMs, false)
    override fun recoverRecording(sessionId: String, name: String, fileName: String, startedAt: Double, durationMs: Int) =
        this@asRecordingSessions.recoverRecording(sessionId, name, fileName, startedAt, durationMs, false)
}

/** An in-flight take: session + file captured at START so a Reset mid-capture still files it right. */
data class ActiveTake(val sessionId: String, val fileName: String, val file: File)

/**
 * App-scoped coordinator for mix AUDIO recording (iOS MixRecorder). Start/stop only gate the
 * persistent [tap]; no graph node is ever added or removed. All entry points are main-thread.
 */
class MixRecorder(
    private val root: File,
    private val tap: RecordingTapSink,
    private val sessions: RecordingSessions,
    /** True while any deck plays (the mix is audible): the stall watchdog only fires then. */
    private val mixAudible: () -> Boolean,
    private val makeWriter: (File) -> TakeWriter,
    private val nowMs: () -> Long = System::currentTimeMillis,
    /** Hops a writer-thread callback onto the main thread. */
    private val postMain: (() -> Unit) -> Unit = { it() },
    private val durationOf: (File) -> Int = { AdtsScan.scan(it).durationMs },
) {
    private val _isRecording = MutableStateFlow(false)
    val isRecordingFlow: StateFlow<Boolean> = _isRecording.asStateFlow()
    val isRecording: Boolean get() = _isRecording.value

    private val _captureStalled = MutableStateFlow(false)
    val captureStalledFlow: StateFlow<Boolean> = _captureStalled.asStateFlow()
    val captureStalled: Boolean get() = _captureStalled.value

    /** Set when the writer died and the take was auto-stopped; the UI shows it once and calls [consumeWriterFailure]. */
    private val _writerFailureMessage = MutableStateFlow<String?>(null)
    val writerFailureMessage: StateFlow<String?> = _writerFailureMessage.asStateFlow()
    fun consumeWriterFailure() { _writerFailureMessage.value = null }

    var startedAtMs: Long = 0; private set

    private var writer: TakeWriter? = null
    private var take: ActiveTake? = null
    private var watchdog: Job? = null
    private var stagnantSince: Long? = null
    private var lastAppended = -1.0

    /** The in-flight take; storage delete-all skips it and the orphan scan never adopts it. */
    val activeTake: ActiveTake? get() = if (isRecording) take else null

    fun toggle() { if (isRecording) stop() else start() }

    /** Begin capturing into the CURRENT session's folder. False if already recording or the file can't open. */
    fun start(scope: CoroutineScope? = null): Boolean {
        if (isRecording) return false
        val sessionId = sessions.currentId
        val folder = SessionFolders.sessionFolder(root, sessionId) ?: return false
        val onDisk = folder.list()?.toSet().orEmpty()
        val name = SessionFolders.nextTakeName(sessions.recordings(sessionId).size, onDisk)
        val file = File(folder, name)
        val w = makeWriter(file)
        w.onWriterFailure = { postMain { writerDidFail() } }
        tap.clear()
        try { w.start() } catch (_: Throwable) { return false }
        tap.setCapturing(true)
        writer = w
        take = ActiveTake(sessionId, name, file)
        startedAtMs = nowMs()
        _captureStalled.value = false
        stagnantSince = null; lastAppended = -1.0
        _isRecording.value = true
        scope?.let { startWatchdog(it) }
        return true
    }

    /** Stop capture and file the take onto the session current at START. No-op if not recording. */
    fun stop() {
        if (!isRecording) return
        val t = take ?: return
        val w = writer
        tap.setCapturing(false)
        // Content clock read AFTER the final drain: media actually appended, not wall time.
        w?.stop()
        val contentMs = ((w?.appendedSeconds ?: 0.0) * 1000).toInt()
        writer = null
        _isRecording.value = false
        _captureStalled.value = false
        watchdog?.cancel(); watchdog = null
        val wallMs = maxOf(0L, nowMs() - startedAtMs).toInt()
        val durationMs = if (contentMs > 0) contentMs else wallMs
        if (sessions.addRecording(t.sessionId, t.fileName, startedAtMs.toDouble(), durationMs) == null) {
            sessions.recoverRecording(t.sessionId, RECOVERED_NAME, t.fileName, startedAtMs.toDouble(), durationMs)
        }
    }

    private fun writerDidFail() {
        if (!isRecording) return
        _writerFailureMessage.value = FAILURE_MESSAGE
        stop()
    }

    /** One watchdog evaluation (the loop calls this every 2 s; tests call it with a fake clock). */
    fun checkStall(now: Long = nowMs()) {
        if (!isRecording) return
        val appended = writer?.appendedSeconds ?: 0.0
        if (appended > lastAppended + 0.01 || !mixAudible()) {
            stagnantSince = null
            _captureStalled.value = false
        } else {
            val since = stagnantSince
            if (since == null) stagnantSince = now
            else if (now - since >= STALL_MS) _captureStalled.value = true
        }
        lastAppended = appended
    }

    private fun startWatchdog(scope: CoroutineScope) {
        watchdog?.cancel()
        watchdog = scope.launch {
            while (isActive && isRecording) { delay(WATCHDOG_MS); checkStall() }
        }
    }

    fun beginWatchdog(scope: CoroutineScope) { if (isRecording && watchdog == null) startWatchdog(scope) }

    /**
     * Re-file any take on disk no session references (a kill mid-take leaves a playable ADTS file but no
     * metadata). Idempotent (filed files are known afterwards), never adopts [activeTake], skips files
     * with no whole frame (dead 0:00 rows). A deleted session is revived. Returns the number filed.
     */
    fun recoverOrphans(): Int {
        var filed = 0
        for ((sessionId, file) in SessionFolders.allTakes(root)) {
            if (file.name in sessions.recordings(sessionId).map { it.fileName }) continue
            val live = activeTake
            if (live != null && live.sessionId == sessionId && live.fileName == file.name) continue
            val dur = durationOf(file)
            if (dur <= 0) continue
            sessions.recoverRecording(sessionId, RECOVERED_NAME, file.name, file.lastModified().toDouble(), dur)
            filed++
        }
        return filed
    }

    companion object {
        const val RECOVERED_NAME = "Recovered recording"
        const val STALL_MS = 5_000L
        const val WATCHDOG_MS = 2_000L
        const val FAILURE_MESSAGE = "Recording stopped: the take couldn't keep writing (low disk space " +
            "or the session folder became unavailable). The audio captured so far was saved."
    }
}
