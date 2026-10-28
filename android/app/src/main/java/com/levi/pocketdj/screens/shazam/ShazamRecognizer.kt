package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** State machine behind the "?♪?" button (iOS ShazamPhase). */
sealed interface ShazamPhase {
    data object Idle : ShazamPhase
    /** Mic open, capturing audio. */
    data object Listening : ShazamPhase
    /** Signature generated, querying the Shazam catalog. */
    data object Recognizing : ShazamPhase
    data class Matched(val match: ShazamMatch) : ShazamPhase
    data object NoMatch : ShazamPhase
    /** Microphone permission denied. */
    data object Denied : ShazamPhase
    data class Failed(val message: String) : ShazamPhase

    val isActive: Boolean get() = this is Listening || this is Recognizing
}

/** What the capture + signature + query pipeline reports (no ShazamKit types leak out). */
sealed interface RecognitionResult {
    data class Hit(val info: ShazamHitInfo) : RecognitionResult
    data object NoMatch : RecognitionResult
    data class Error(val message: String) : RecognitionResult
}

/**
 * The native pipeline: AudioRecord capture -> ShazamKit StreamingSession -> match. [recognize]
 * suspends until a terminal result; cancelling the coroutine must release the mic.
 */
fun interface RecognitionBackend {
    suspend fun recognize(): RecognitionResult
}

/** Asked once per tap; the UI layer owns the runtime-permission prompt. */
fun interface MicPermission {
    suspend fun ensureGranted(): Boolean
}

/** What a button tap should do next. */
enum class ShazamTap { STARTED, CANCELLED, OPEN_SETTINGS, BLOCKED }

/**
 * Owns one recognition at a time (iOS ShazamRecognizer). Second tap while active cancels;
 * a denied state sends the user to app settings; gated while a mix recording is active (the
 * mic capture would fight the recorder for the audio source).
 */
class ShazamRecognizer(
    private val scope: CoroutineScope,
    private val backend: RecognitionBackend,
    private val permission: MicPermission,
    private val songs: () -> Collection<IndexSong>,
    /** True while a mix recording is active (MixRecorder.isRecording). */
    private val blocked: () -> Boolean = { false },
    /** Cosmetic Listening -> Recognizing delay. */
    private val recognizingAfterMs: Long = 600,
) {
    private val _phase = MutableStateFlow<ShazamPhase>(ShazamPhase.Idle)
    val phase: StateFlow<ShazamPhase> = _phase.asStateFlow()

    private var job: Job? = null

    fun tap(): ShazamTap = when {
        _phase.value.isActive -> { stop(); ShazamTap.CANCELLED }
        _phase.value is ShazamPhase.Denied -> ShazamTap.OPEN_SETTINGS
        blocked() -> ShazamTap.BLOCKED
        else -> { start(); ShazamTap.STARTED }
    }

    fun start() {
        if (_phase.value.isActive) { stop(); return }
        if (blocked()) return
        _phase.value = ShazamPhase.Listening
        job = scope.launch { run() }
    }

    /** Cancel an in-flight listen; terminal phases are left alone. */
    fun stop() {
        job?.cancel()
        job = null
        if (_phase.value.isActive) _phase.value = ShazamPhase.Idle
    }

    /** Dismiss a result and return to Idle. */
    fun reset() {
        stop()
        _phase.value = ShazamPhase.Idle
    }

    /** The permission was denied again after settings: allow a fresh attempt. */
    fun clearDenied() { if (_phase.value is ShazamPhase.Denied) _phase.value = ShazamPhase.Idle }

    private suspend fun run() {
        try {
            if (!permission.ensureGranted()) { _phase.value = ShazamPhase.Denied; return }
            // Superseded by stop() while the prompt was up.
            if (_phase.value !is ShazamPhase.Listening) return
            val cosmetic = scope.launch {
                delay(recognizingAfterMs)
                if (_phase.value is ShazamPhase.Listening) _phase.value = ShazamPhase.Recognizing
            }
            val result = try { backend.recognize() } finally { cosmetic.cancel() }
            if (!_phase.value.isActive) return // cancelled meanwhile
            _phase.value = when (result) {
                is RecognitionResult.Hit -> ShazamPhase.Matched(ShazamCatalogMatch.resolve(result.info, songs().toList()))
                RecognitionResult.NoMatch -> ShazamPhase.NoMatch
                is RecognitionResult.Error -> ShazamPhase.Failed(result.message)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            if (_phase.value.isActive) _phase.value = ShazamPhase.Failed(t.message ?: "Recognition failed")
        }
    }
}

/**
 * Default backend. The vendored ShazamKit-for-Android AAR (`app/libs/shazamkit-android.aar`) is
 * distributed through Apple's developer portal and is not in the repo, so until it is dropped in
 * this reports the build as unsupported. The AudioRecord + StreamingSession adapter replaces it.
 */
object UnavailableRecognitionBackend : RecognitionBackend {
    override suspend fun recognize(): RecognitionResult =
        RecognitionResult.Error("Song recognition isn’t available in this build.")
}
