package com.levi.pocketdj.data.games.inthepocket

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What the dictation controller needs from a speech engine - the seam the unit tests fake. */
interface FeedbackSpeechEngine {
    /** This device/locale can dictate ON DEVICE (no prompt is shown to find out). */
    val isAvailable: Boolean

    /** Ask for the microphone permission (prompts only the first time). */
    suspend fun requestAuthorization(): FeedbackDictationAuthorization

    /**
     * Start listening. [onTranscript] receives the WHOLE transcript so far (not a delta), any number of
     * times; [onFinish] fires once when recognition ends (null = cleanly).
     */
    fun start(onTranscript: (String) -> Unit, onFinish: (String?) -> Unit)

    fun stop()
}

enum class FeedbackDictationAuthorization { AUTHORIZED, DENIED, UNAVAILABLE }

/**
 * The feedback field's mic button (port of FeedbackDictationController): tap -> live transcript
 * APPENDED to whatever was typed; tap again -> stop. Permission denied / no on-device recognizer =>
 * the mic is hidden or disabled with a one-line explanation and the field stays a plain text field.
 */
class FeedbackDictationController(private val engine: FeedbackSpeechEngine?) {

    sealed class State {
        data object Idle : State()
        data object Requesting : State()
        data object Listening : State()
        /** Mic permission is off - the explanation line shows; typing still works. */
        data object Denied : State()
        data object Unavailable : State()
        data class Failed(val message: String) : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /** Hidden when false: the device can't dictate on-device. NEVER falls back to a cloud recognizer. */
    val isAvailable: Boolean get() = engine?.isAvailable ?: false
    val isListening: Boolean get() = _state.value == State.Listening

    val explanation: String? get() = explanationFor(_state.value)

    private var base = ""
    private var sink: ((String) -> Unit)? = null

    /** Mic button. [current] is the field's text now; [update] writes the field. */
    suspend fun toggle(current: String, update: (String) -> Unit) {
        if (_state.value == State.Listening) { stop(); return }
        val engine = engine
        if (engine == null || !engine.isAvailable) { _state.value = State.Unavailable; return }
        _state.value = State.Requesting
        when (engine.requestAuthorization()) {
            FeedbackDictationAuthorization.DENIED -> { _state.value = State.Denied; return }
            FeedbackDictationAuthorization.UNAVAILABLE -> { _state.value = State.Unavailable; return }
            FeedbackDictationAuthorization.AUTHORIZED -> Unit
        }
        // The user may have navigated away (stop()) while the permission sheet was up.
        if (_state.value != State.Requesting) return
        base = current
        sink = update
        try {
            engine.start(
                onTranscript = { text ->
                    if (_state.value == State.Listening) sink?.invoke(join(base, text))
                },
                onFinish = { error ->
                    if (error != null && _state.value == State.Listening) _state.value = State.Failed(error)
                    else if (_state.value == State.Listening) _state.value = State.Idle
                    sink = null
                },
            )
            _state.value = State.Listening
        } catch (e: Exception) {
            _state.value = State.Failed("Couldn't start dictation.")
        }
    }

    fun stop() {
        val s = _state.value
        if (s != State.Listening && s != State.Requesting) return
        _state.value = State.Idle
        engine?.stop()
        sink = null
    }

    companion object {
        const val DENIED_TEXT =
            "Dictation needs microphone access - turn it on for PocketDJ in Settings. You can still type."
        const val UNAVAILABLE_TEXT = "Dictation isn't available on this device. You can still type."

        fun explanationFor(s: State): String? = when (s) {
            State.Denied -> DENIED_TEXT
            State.Unavailable -> UNAVAILABLE_TEXT
            is State.Failed -> s.message
            else -> null
        }

        /** Typed text + a space + the transcript (no double spaces, nothing added for an empty side). */
        fun join(typed: String, spoken: String): String {
            val t = typed.trim { it == ' ' || it == '\t' }
            val s = spoken.trim { it == ' ' || it == '\t' }
            if (t.isEmpty()) return s
            if (s.isEmpty()) return typed
            val sep = if (t.endsWith("\n")) "" else " "
            return t + sep + s
        }
    }
}

/**
 * `SpeechRecognizer.createOnDeviceSpeechRecognizer` ONLY: a device without an on-device model reports
 * unavailable (no mic) instead of falling back to the cloud recognizer, so the spoken audio never
 * leaves the phone. Main-thread only. [requestPermission] is the screen's RECORD_AUDIO launcher.
 */
class SystemFeedbackSpeechEngine(
    private val context: Context,
    private val requestPermission: suspend () -> Boolean,
) : FeedbackSpeechEngine {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var finished = true

    override val isAvailable: Boolean
        get() = runCatching { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }.getOrDefault(false)

    override suspend fun requestAuthorization(): FeedbackDictationAuthorization {
        if (!isAvailable) return FeedbackDictationAuthorization.UNAVAILABLE
        return if (requestPermission()) FeedbackDictationAuthorization.AUTHORIZED
        else FeedbackDictationAuthorization.DENIED
    }

    override fun start(onTranscript: (String) -> Unit, onFinish: (String?) -> Unit) {
        stop()
        val rec = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        recognizer = rec
        finished = false
        var heard = false
        fun end(error: String?) {
            if (finished) return
            finished = true
            teardown()
            onFinish(error)
        }
        rec.setRecognitionListener(object : RecognitionListener {
            override fun onPartialResults(partialResults: Bundle?) {
                first(partialResults)?.let { heard = true; onTranscript(it) }
            }
            override fun onResults(results: Bundle?) {
                first(results)?.let { heard = true; onTranscript(it) }
                end(null)
            }
            override fun onError(error: Int) {
                // A stop/no-speech timeout is not a failure when something was heard.
                end(if (heard || error == SpeechRecognizer.ERROR_NO_MATCH ||
                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) null else "Dictation stopped - try again.")
            }
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
            private fun first(b: Bundle?): String? =
                b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        rec.startListening(intent)
    }

    override fun stop() {
        if (finished) return
        finished = true
        teardown()
    }

    private fun teardown() {
        val rec = recognizer
        recognizer = null
        if (rec != null) main.post { runCatching { rec.cancel(); rec.destroy() } }
    }
}
