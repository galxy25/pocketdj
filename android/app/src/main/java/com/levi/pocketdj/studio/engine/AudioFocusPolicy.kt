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
