package com.levi.pocketdj.studio.engine

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Identity of a finished take (the view files the StudioSample). */
data class MicTake(val id: String, val fileName: String, val durationMs: Int, val wasUserFolder: Boolean)

/** An input the user can pick (device id from AudioManager; label for the picker). */
data class MicInputOption(val deviceId: Int, val label: String, val isExternal: Boolean)

/** Pure seams of the recorder (iOS StudioMicRecorder nonisolated statics) - hermetically testable. */
object MicRecorderMath {
    /** Frozen-capture time before `captureStalled` warns (seconds). */
    const val STALL_WARN_SECONDS = 5.0

    /** Watchdog dt: wall time since the last tick clamped to [0, 0.5] s; 0 on the first tick. */
    fun clampedTickDt(now: Double, last: Double?): Double {
        if (last == null) return 0.0
        return min(0.5, max(0.0, now - last))
    }

    /** Reset to 0 when appended media advanced (>10 ms) or on first observation (previous < 0); else grow by dt. */
    fun nextStallAccum(accum: Double, dt: Double, appended: Double, previousAppended: Double): Double {
        if (previousAppended < 0) return 0.0
        return if (appended > previousAppended + 0.01) 0.0 else accum + dt
    }

    /** Mint an id + deterministic file name, skipping names [isTaken] claims; bounded to 100 attempts. */
    fun mintSampleFile(isTaken: (String) -> Boolean, mintId: () -> String = { StudioFactory.newSampleId() }): Pair<String, String> {
        var minted = "" to ""
        repeat(100) {
            val id = mintId()
            minted = id to StudioFolders.fileName(StudioFamily.SAMPLES, id)
            if (!isTaken(minted.second)) return minted
        }
        return minted
    }

    /**
     * The orphan-scan adoption decision: the embedded sample id iff [fileName] is a RAW capture the
     * document doesn't know and isn't the take being written right now (root-aware). Strict family
     * shape only; a render cache (`sample-<id>-r<rev>.m4a`) is derived data and never adopted.
     */
    fun adoptableSampleId(fileName: String, knownIds: Set<String>, activeTake: Pair<String, Boolean>?, rootIsUser: Boolean): String? {
        val id = StudioFolders.fileId(StudioFamily.SAMPLES, fileName) ?: return null
        if (fileName != StudioFolders.fileName(StudioFamily.SAMPLES, id)) return null
        if (id in knownIds) return null
        if (activeTake != null && activeTake.first == fileName && activeTake.second == rootIsUser) return null
        return id
    }

    /** Peak (0..1) of a PCM16 little-endian block. */
    fun peak16(bytes: ByteArray, length: Int): Float {
        var p = 0
        var i = 0
        while (i + 1 < length) {
            val v = abs(((bytes[i + 1].toInt() shl 8) or (bytes[i].toInt() and 0xFF)).toShort().toInt())
            if (v > p) p = v
            i += 2
        }
        return min(1f, p / 32768f)
    }

    /** Meter ballistics: instant attack, ~0.85 per block release. */
    fun smoothLevel(prev: Float, peak: Float): Float = if (peak >= prev) peak else prev * 0.85f
}

/**
 * Crash-safe take file: a mono PCM16 WAV written to the sample's `.m4a` file name (decoders sniff the
 * content, STU-1 convention). The RIFF header is re-patched every ~1 s so a process kill leaves a file
 * whose header is at most a second stale; [recoveredDurationMs] ignores the header and trusts the byte
 * length, so even a never-patched header recovers.
 */
class WavTakeWriter(file: File, val sampleRate: Int) {
    private val raf = RandomAccessFile(file, "rw").also { it.setLength(0); it.write(header(0)) }
    var dataBytes = 0L; private set
    private var lastPatchBytes = 0L
    val appendedSeconds: Double get() = dataBytes / 2.0 / sampleRate

    private fun header(data: Long): ByteArray {
        val bb = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("RIFF".toByteArray()).putInt((36 + data).toInt()).put("WAVE".toByteArray()).put("fmt ".toByteArray())
        bb.putInt(16).putShort(1).putShort(1).putInt(sampleRate).putInt(sampleRate * 2).putShort(2).putShort(16)
        bb.put("data".toByteArray()).putInt(data.toInt())
        return bb.array()
    }

    fun append(bytes: ByteArray, length: Int) {
        raf.seek(44 + dataBytes)
        raf.write(bytes, 0, length)
        dataBytes += length
        if (dataBytes - lastPatchBytes >= sampleRate * 2L) patch()
    }

    private fun patch() {
        raf.seek(0); raf.write(header(dataBytes)); lastPatchBytes = dataBytes
    }

    fun close() { patch(); raf.close() }

    companion object {
        /** Duration from the BYTE LENGTH of a mono PCM16 WAV (header sizes untrusted); null if not a usable WAV. */
        fun recoveredDurationMs(file: File): Int? {
            if (!file.isFile || file.length() <= 44) return null
            val head = ByteArray(44)
            file.inputStream().use { if (it.read(head) < 44) return null }
            if (String(head, 0, 4) != "RIFF" || String(head, 8, 4) != "WAVE") return null
            val rate = ByteBuffer.wrap(head).order(ByteOrder.LITTLE_ENDIAN).getInt(24)
            val ch = ByteBuffer.wrap(head).order(ByteOrder.LITTLE_ENDIAN).getShort(22).toInt()
            if (rate <= 0 || ch <= 0) return null
            val frames = (file.length() - 44) / (2L * ch)
            return (frames * 1000 / rate).toInt().takeIf { it > 0 }
        }

        /** Rewrite a recovered file's header sizes from the byte length so strict decoders open it. */
        fun repairHeader(file: File) {
            RandomAccessFile(file, "rw").use { raf ->
                val data = max(0L, raf.length() - 44)
                raf.seek(4); raf.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt((36 + data).toInt()).array())
                raf.seek(40); raf.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(data.toInt()).array())
            }
        }
    }
}

/**
 * App-scoped mic recorder (port of StudioMicRecorder). `AudioRecord` 44.1 kHz mono PCM16 on its own
 * thread -> [WavTakeWriter]. Begin/end of [AudioFocusPolicy.micCaptureActive] brackets monitoring so no
 * playback path starts under a live capture. Orphan recovery files a take interrupted by a crash.
 */
class MicRecorder(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val audioManager: AudioManager?,
    private val clockMs: () -> Long = System::currentTimeMillis,
) {
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()
    private val _recording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _recording.asStateFlow()
    private val _stalled = MutableStateFlow(false)
    val captureStalled: StateFlow<Boolean> = _stalled.asStateFlow()
    private val _failure = MutableStateFlow<String?>(null)
    val writerFailureMessage: StateFlow<String?> = _failure.asStateFlow()
    private val _inputs = MutableStateFlow<List<MicInputOption>>(emptyList())
    val inputs: StateFlow<List<MicInputOption>> = _inputs.asStateFlow()
    @Volatile var selectedDeviceId: Int? = null; private set

    @Volatile private var record: AudioRecord? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var writer: WavTakeWriter? = null
    @Volatile private var stopFlag = false
    private var finalized: CompletableDeferred<Unit>? = null
    private var recId = ""; private var recFile = ""; private var recUser = false; private var startedAtMs = 0.0
    private var stallAccum = 0.0; private var lastAppended = -1.0; private var lastTick: Double? = null
    @Volatile private var scannedApp = false
    @Volatile private var scannedUser = false

    val activeTake: Pair<String, Boolean>? get() = if (_recording.value) recFile to recUser else null

    /** Open the meter without writing (the sheet's idle monitoring). False when AudioRecord could not start. */
    @Synchronized
    fun beginMonitoring(): Boolean {
        if (record != null) return true
        AudioFocusPolicy.beginMicCapture()
        refreshInputs()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) { AudioFocusPolicy.endMicCapture(); return false }
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
        } catch (_: Exception) { AudioFocusPolicy.endMicCapture(); return false }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); AudioFocusPolicy.endMicCapture(); return false }
        applyPreferred(rec)
        try { rec.startRecording() } catch (_: Exception) { rec.release(); AudioFocusPolicy.endMicCapture(); return false }
        record = rec
        stopFlag = false
        _level.value = 0f
        thread = Thread({ captureLoop(rec, min * 2) }, "pdj-mic").also { it.start() }
        return true
    }

    @Synchronized
    fun endMonitoring() {
        if (_recording.value) { finishTake()?.let { fileSample(it) } }
        val t = thread
        stopFlag = true
        record = null
        thread = null
        runCatching { t?.join(1500) }
        AudioFocusPolicy.endMicCapture()
        _level.value = 0f
    }

    fun refreshInputs() {
        val am = audioManager ?: return
        _inputs.value = am.getDevices(AudioManager.GET_DEVICES_INPUTS).filter { it.isSource }.map {
            MicInputOption(it.id, labelOf(it), it.type != AudioDeviceInfo.TYPE_BUILTIN_MIC)
        }
        if (selectedDeviceId != null && _inputs.value.none { it.deviceId == selectedDeviceId }) selectedDeviceId = null
    }

    fun selectInput(deviceId: Int?) {
        selectedDeviceId = deviceId
        record?.let { applyPreferred(it) }
    }

    private fun applyPreferred(rec: AudioRecord) {
        val id = selectedDeviceId ?: run { rec.preferredDevice = null; return }
        val dev = audioManager?.getDevices(AudioManager.GET_DEVICES_INPUTS)?.firstOrNull { it.id == id }
        rec.preferredDevice = dev
    }

    private fun labelOf(d: AudioDeviceInfo): String {
        val n = d.productName?.toString().orEmpty()
        return when (d.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in microphone"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> n.ifBlank { "Bluetooth" }
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> n.ifBlank { "USB audio" }
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Headset mic"
            else -> n.ifBlank { "Audio input" }
        }
    }

    /** Start a take. False if already recording or no writable root / writer. */
    @Synchronized
    fun start(): Boolean {
        if (_recording.value) return false
        if (!beginMonitoring()) return false
        // Mic takes are written to a real file in the app-managed root; copy-out to a SAF user root is a later step.
        val appDir = roots.appDir(StudioFamily.SAMPLES)
        val minted = MicRecorderMath.mintSampleFile({ appDir.exists(it) })
        val target = StudioFiles.appFile(roots, StudioFamily.SAMPLES, minted.second) ?: return false
        val wasUser = false
        target.parentFile?.mkdirs()
        val w = try { WavTakeWriter(target, RATE) } catch (_: Exception) { return false }
        recId = minted.first; recFile = minted.second; recUser = wasUser
        startedAtMs = clockMs().toDouble()
        stallAccum = 0.0; lastAppended = -1.0; lastTick = null
        _stalled.value = false; _failure.value = null
        finalized = CompletableDeferred()
        writer = w
        _recording.value = true
        return true
    }

    private fun captureLoop(rec: AudioRecord, bufBytes: Int) {
        val buf = ByteArray(bufBytes)
        var level = 0f
        var lastWatch = System.nanoTime()
        while (!stopFlag && record === rec) {
            val n = rec.read(buf, 0, buf.size)
            if (n <= 0) { if (n < 0) break else continue }
            level = MicRecorderMath.smoothLevel(level, MicRecorderMath.peak16(buf, n))
            _level.value = level
            val w = writer
            if (w != null && _recording.value) {
                try { w.append(buf, n) } catch (_: Exception) { onWriterFailed(); }
            }
            val now = System.nanoTime()
            if (now - lastWatch >= 250_000_000L) { lastWatch = now; watchdogTick(now / 1e9) }
        }
        runCatching { rec.stop() }
        runCatching { rec.release() }
        // Finalize the writer on this thread AFTER the last append: the file is complete when [finalized] fires.
        val w = writer
        if (w != null && !_recording.value) { runCatching { w.close() }; writer = null; finalized?.complete(Unit) }
        // A loop that ended on its own (writer failure / read error) must not leave a dead record behind.
        if (record === rec) { record = null; thread = null; AudioFocusPolicy.endMicCapture(); _level.value = 0f }
    }

    private fun watchdogTick(nowSec: Double) {
        val w = writer ?: return
        val dt = MicRecorderMath.clampedTickDt(nowSec, lastTick); lastTick = nowSec
        val appended = w.appendedSeconds
        stallAccum = MicRecorderMath.nextStallAccum(stallAccum, dt, appended, lastAppended)
        lastAppended = appended
        _stalled.value = stallAccum >= MicRecorderMath.STALL_WARN_SECONDS
    }

    private fun onWriterFailed() {
        if (!_recording.value) return
        _failure.value = "Recording stopped: the take couldn’t keep writing (low disk space or the samples folder became unavailable). The audio captured so far was saved."
        finishTake()?.let { fileSample(it) }
        stopFlag = true
    }

    private fun contentMs(w: WavTakeWriter?): Int {
        val content = ((w?.appendedSeconds ?: 0.0) * 1000).toInt()
        return if (content > 0) content else max(0, (clockMs() - startedAtMs).toInt())
    }

    /** Shared stop path: ends the take WITHOUT touching monitoring. Writer closes on the capture thread. */
    private fun finishTake(): MicTake? {
        if (!_recording.value) return null
        val w = writer
        val take = MicTake(recId, recFile, contentMs(w), recUser)
        _recording.value = false
        _stalled.value = false
        stallAccum = 0.0; lastAppended = -1.0
        // Capture loop sees recording=false and the loop is told to end: close the file there.
        stopFlag = true
        return take
    }

    /** Stop the take and end monitoring; the file may still be finalizing (use [stopAwaitingFinalize] to read it). */
    @Synchronized
    fun stop(): MicTake? {
        val take = finishTake() ?: return null
        endMonitoring()
        return take
    }

    /** Like [stop] but suspends until the writer is closed: safe to read (and delete) the take file. */
    suspend fun stopAwaitingFinalize(): MicTake? {
        val done: CompletableDeferred<Unit>?
        val take: MicTake?
        synchronized(this) {
            done = finalized
            take = finishTake()
            if (take != null) endMonitoring()
        }
        if (take == null) return null
        done?.await()
        return take
    }

    /** Orderly exit: file an in-flight take with the default name and flush the store synchronously. */
    fun finalizeForExit() {
        val had = _recording.value
        endMonitoring()
        if (had) store.flush()
    }

    private fun fileSample(t: MicTake) {
        store.addSample(
            StudioSample(
                id = t.id, name = DEFAULT_NAME, fileName = t.fileName, wasUserFolder = t.wasUserFolder,
                createdAt = startedAtMs, durationMs = t.durationMs, source = StudioSource.Mic,
            ),
        )
    }

    /**
     * File any RAW `sample-<smp_id>` capture on disk the document doesn't know (a take interrupted by a
     * kill). Idempotent; never the live take; readability-gated (a header-only file is not filed).
     */
    fun recoverOrphans(): Int {
        var filed = 0
        val known = store.samples.map { it.id }.toMutableSet()
        fun scan(dir: com.levi.pocketdj.studio.store.StudioDir, isUser: Boolean) {
            val names = try { dir.list() } catch (_: Exception) { return }
            for (name in names) {
                val id = MicRecorderMath.adoptableSampleId(name, known, activeTake, isUser) ?: continue
                val f = dir.resolve(name)?.file ?: continue
                val ms = WavTakeWriter.recoveredDurationMs(f) ?: continue
                runCatching { WavTakeWriter.repairHeader(f) }
                store.addSample(
                    StudioSample(id = id, name = "Recovered recording", fileName = name, wasUserFolder = isUser,
                        createdAt = f.lastModified().toDouble(), durationMs = ms, source = StudioSource.Mic),
                )
                known.add(id); filed++
            }
        }
        if (!scannedApp) { scannedApp = true; scan(roots.appDir(StudioFamily.SAMPLES), false) }
        if (!scannedUser) {
            val u = roots.userDir(StudioFamily.SAMPLES)
            if (u != null) { scannedUser = true; scan(u, true) }
        }
        return filed
    }

    companion object {
        const val RATE = 44_100
        const val DEFAULT_NAME = "Mic recording"
    }
}
