package com.levi.pocketdj.mix.service

import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/** The engine surface the focus machine drives (all main thread). */
interface FocusTransport {
    /** A deck has play intent (the mix is audibly running). */
    val isRunning: Boolean
    /** The mix should be heard: a deck has play intent, or a live un-paused Auto-DJ is between decks. */
    val mixWantsAudio: Boolean get() = isRunning
    /** A running deck still has audio left (iOS `position < duration - 0.25`): only then does a park latch. */
    val deckAudible: Boolean get() = isRunning
    /** The Mix is still the switchboard owner right now (a regain must not steal the session back). */
    val isOwner: Boolean get() = true
    /** Lock-screen style pause: suspends a running Auto-DJ and freezes its clocks. */
    fun remotePause()
    /** Resume exactly what the last pause silenced. */
    fun remotePlay()
    /** Hard stop: both decks (ends a running Auto-DJ). */
    fun pauseBoth()
}

/** The platform focus calls, so the state machine is JVM-testable. */
interface FocusSystem {
    /** Request AUDIOFOCUS_GAIN. True when granted. */
    fun request(): Boolean
    fun abandon()
}

/**
 * Audio-focus policy for the Mix (iOS registerInterruptionHandling):
 *  - GAIN is requested when a deck starts;
 *  - a TRANSIENT loss while running pauses (remotePause) and latches [interruptionParked]; the regain
 *    resumes ONLY what was parked. A deck the user hand-started during the park clears the latch
 *    (the user took over: nothing is double-resumed and that deck simply keeps playing);
 *  - a permanent LOSS pauses both decks and gives the focus up;
 *  - ducking is left to the system; becoming-noisy (headphones unplugged) pauses.
 */
class MixFocusMachine(
    private val system: FocusSystem,
    private val transport: FocusTransport,
    private val log: (String) -> Unit = { MixDiag.log(it) },
) {
    var interruptionParked = false; private set
    var held = false; private set

    /** A deck started sounding. */
    fun onAudioStarted() {
        if (interruptionParked) {
            interruptionParked = false
            log("focus: hand-start during park - latch cleared")
        }
        if (!held) {
            held = system.request()
            log("focus: request gain granted=$held")
            if (!held) {
                // Denied (a call holds focus): never play over it. No regain will be delivered for a
                // failed request, so this is a plain pause; the user's next play retries the request.
                log("focus: denied - remotePause")
                transport.remotePause()
            }
        }
    }

    /** Another owner took the session (pauseForHandoff): the park is moot. */
    fun onHandoff() {
        if (interruptionParked) {
            interruptionParked = false
            log("focus: handoff - latch cleared")
        }
    }

    fun onFocusChange(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (transport.mixWantsAudio) {
                    // Latch only when a deck is audible (iOS P0-4): an Auto-DJ gap pauses its clocks but
                    // leaves nothing for the regain to resume.
                    if (transport.deckAudible) interruptionParked = true
                    log("focus: transient loss - ${if (interruptionParked) "parked" else "paused (nothing audible to latch)"}")
                    transport.remotePause()
                } else log("focus: transient loss - idle")
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                interruptionParked = false
                held = false
                log("focus: loss - pauseBoth")
                transport.pauseBoth()
                system.abandon()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                held = true
                if (interruptionParked) {
                    interruptionParked = false
                    if (!transport.isOwner) {
                        log("focus: regain - not-owner, latch dropped")
                    } else if (transport.isRunning) {
                        log("focus: regain - a deck is already playing, nothing to resume")
                    } else {
                        log("focus: regain - resuming parked")
                        transport.remotePlay()
                    }
                }
            }
            else -> Unit // CAN_DUCK: the system ducks for us
        }
    }

    fun onBecomingNoisy() {
        if (transport.mixWantsAudio) {
            log("focus: becoming noisy - remotePause")
            transport.remotePause()
        }
    }

    /** The transport went fully idle (user pause): release the focus unless a park is waiting for the regain. */
    fun onTransportIdle() {
        if (!transport.mixWantsAudio && !interruptionParked && held) {
            held = false
            system.abandon()
            log("focus: idle - abandoned")
        }
    }
}

/** [AudioManager]-backed [FocusSystem]. Callbacks are delivered on the main looper. */
class AndroidFocusSystem(
    private val audio: AudioManager,
    private val onChange: (Int) -> Unit,
) : FocusSystem {
    private val request: AudioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
        )
        .setOnAudioFocusChangeListener({ onChange(it) }, Handler(Looper.getMainLooper()))
        .build()

    override fun request(): Boolean = audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    override fun abandon() { audio.abandonAudioFocusRequest(request) }
}
