package com.levi.pocketdj.studio.engine

import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide audio coexistence policy (port of AudioSessionPolicy.swift + the Android AudioFocus
 * half). While the studio mic recorder is capturing, NO playback path may change the audio mode /
 * route or start sounding: the iOS rule "never re-arm .playback under a live input tap" becomes
 * "refuse to start playback while [micCaptureActive]". Deliberately a Boolean, not a count: exactly one
 * mic recorder exists, so begin/end pairs never nest.
 */
object AudioFocusPolicy {
    private val capture = AtomicBoolean(false)

    val micCaptureActive: Boolean get() = capture.get()

    /** Recorder calls this BEFORE touching the audio mode so a racing playback start sees it. */
    fun beginMicCapture() { capture.set(true) }

    /** Clear-first on stop so the recorder's own restore is never mistaken for a hostile re-arm. */
    fun endMicCapture() { capture.set(false) }

    /** Every Studio play path consults this; false => do not start / change route. */
    fun mayStartPlayback(): Boolean = !micCaptureActive

    /** Stable refusal reason ("mic-capture-active") when playback must not start, else null. */
    fun refusalReason(): String? = if (micCaptureActive) REASON_MIC_CAPTURE else null

    /**
     * The single gate every start path uses: returns true when [owner] may start; otherwise logs the refusal
     * reason through [StudioDiag] (so "refused" is never indistinguishable from "never called") and returns false.
     */
    fun gateStart(owner: String): Boolean {
        val r = refusalReason() ?: return true
        StudioDiag.play(owner, r, started = false)
        return false
    }

    const val REASON_MIC_CAPTURE = "mic-capture-active"

    /** Focus transitions that must park a Studio engine (iOS interruption park). */
    fun shouldPauseOnFocusChange(change: Int): Boolean = when (change) {
        AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> true
        else -> false
    }

    /**
     * Holder for one AudioFocus request (GAIN for playback engines, GAIN_TRANSIENT_EXCLUSIVE-like
     * capture uses GAIN_TRANSIENT). [onLoss] fires on loss so the engine can pause.
     */
    class FocusHandle(
        private val am: AudioManager,
        /** When set, a TRANSIENT loss calls this (park) instead of [onLoss], and AUDIOFOCUS_GAIN calls [onGain]. */
        private val onTransientLoss: (() -> Unit)? = null,
        private val onGain: (() -> Unit)? = null,
        private val onLoss: () -> Unit,
    ) {
        private var request: AudioFocusRequest? = null

        fun requestPlayback(): Boolean = request(AudioManager.AUDIOFOCUS_GAIN, AudioAttributes.USAGE_MEDIA, AudioAttributes.CONTENT_TYPE_MUSIC)

        fun requestCapture(): Boolean = request(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT, AudioAttributes.USAGE_MEDIA, AudioAttributes.CONTENT_TYPE_SPEECH)

        private fun request(gain: Int, usage: Int, content: Int): Boolean {
            abandon()
            val req = AudioFocusRequest.Builder(gain)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(usage).setContentType(content).build())
                .setOnAudioFocusChangeListener {
                    when {
                        it == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT && onTransientLoss != null -> onTransientLoss.invoke()
                        it == AudioManager.AUDIOFOCUS_GAIN -> onGain?.invoke()
                        shouldPauseOnFocusChange(it) -> onLoss()
                    }
                }
                .build()
            request = req
            return am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }

        fun abandon() {
            request?.let { am.abandonAudioFocusRequest(it) }
            request = null
        }
    }
}

/**
 * Reason-tagged Studio play/stop exits (acceptance: every engine stop/start logs a reason). Thin owner-prefixed
 * facade over [com.levi.pocketdj.audio.core.AudioDiag] so Studio and Mix/Now Playing share counters and the
 * `audio.play owner=... reason=...` line shape.
 */
object StudioDiag {
    fun owner(engine: String) = "studio.$engine"

    fun play(engine: String, reason: String, started: Boolean, detail: String? = null) =
        com.levi.pocketdj.audio.core.AudioDiag.play(owner(engine), reason, started, detail)

    fun stop(engine: String, reason: String, detail: String? = null) =
        com.levi.pocketdj.audio.core.AudioDiag.stop(owner(engine), reason, detail)
}

/**
 * Remembers WHICH engines an audio-focus interruption parked, so the matching gain resumes exactly those and
 * nothing the user had already stopped (iOS interruptionParked pairing). Thread-safe; ids are engine names.
 */
class InterruptionLedger {
    private val parked = LinkedHashSet<String>()

    /** Park [id] because it was audibly running. A second park of the same id is a no-op. Returns whether newly parked. */
    @Synchronized fun park(id: String): Boolean = parked.add(id)

    /** An explicit user stop/play of [id] supersedes any pending resume. */
    @Synchronized fun forget(id: String) { parked.remove(id) }

    /** Focus regained: the ids to resume (in park order), clearing the ledger. */
    @Synchronized fun drainForResume(): List<String> = parked.toList().also { parked.clear() }

    @Synchronized fun isParked(id: String): Boolean = id in parked
}
