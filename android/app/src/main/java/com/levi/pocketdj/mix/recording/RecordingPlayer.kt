package com.levi.pocketdj.mix.recording

import android.media.AudioAttributes
import android.media.MediaPlayer
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Plays one recorded take for the Sessions screen. Starting a take pauses the live mix first (the
 * single-audio-owner rule), via [pauseMix]. One take at a time; tapping the playing take stops it.
 */
class RecordingPlayer(private val pauseMix: () -> Unit) {
    private var mp: MediaPlayer? = null
    private val _playing = MutableStateFlow<String?>(null)
    /** Path of the take now playing, null when idle. */
    val playing: StateFlow<String?> = _playing.asStateFlow()

    fun toggle(file: File): Boolean {
        if (_playing.value == file.path) { stop(); return false }
        return play(file)
    }

    fun play(file: File): Boolean {
        stop()
        if (!file.isFile) return false
        pauseMix()
        return try {
            val p = MediaPlayer()
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            p.setDataSource(file.path)
            p.setOnCompletionListener { stop() }
            p.setOnErrorListener { _, _, _ -> stop(); true }
            p.prepare(); p.start()
            mp = p; _playing.value = file.path
            true
        } catch (_: Throwable) { stop(); false }
    }

    fun stop() {
        mp?.let { runCatching { it.stop() }; runCatching { it.release() } }
        mp = null
        _playing.value = null
    }
}
