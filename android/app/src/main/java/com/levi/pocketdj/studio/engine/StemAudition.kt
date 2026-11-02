package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.demux.StemPlayer
import java.io.File

/** The carve sheet's full-mix audition (StudioEngine's sample preview of the song window; seconds are song-relative). */
interface MixAudition {
    val isPlaying: Boolean
    fun play()
    fun pause()
    fun seek(sec: Double)
    fun playheadSec(): Double
}

/** [MixAudition] over the shared [StudioEngine] sample preview. */
class EngineMixAudition(private val engine: StudioEngine) : MixAudition {
    override val isPlaying: Boolean get() = engine.isPlayingSample.value
    override fun play() { engine.playSample() }
    override fun pause() = engine.pauseSample()
    override fun seek(sec: Double) = engine.seekSample(sec)
    override fun playheadSec(): Double = engine.samplePlayheadSeconds()
}

/**
 * Q118 (iOS `StudioNewSampleFromTrackView` audition routing): what you HEAR in the stem-carve sheet is what gets
 * carved. Full-mix mode auditions the song through [mix]; stem mode auditions the four stems through a synced
 * [stems] player whose mutes follow the chips live. Exactly one of the two ever sounds: switching modes carries the
 * position and play state across. Stems are song-relative, as is the full-mix preview window, so seconds map 1:1.
 */
class StemAudition(private val mix: MixAudition, private val stems: StemPlayer) {
    /** True while the stem player is loaded and is the routed (audible) engine. */
    var auditioningStems: Boolean = false
        private set

    val isPlaying: Boolean get() = if (auditioningStems) stems.isPlaying else mix.isPlaying

    fun playheadSec(): Double = if (auditioningStems) stems.currentTimeSec else mix.playheadSec()

    fun toggle() {
        if (auditioningStems) { if (ensureLoaded()) stems.togglePlayPause() }
        else if (mix.isPlaying) mix.pause() else mix.play()
    }

    fun seek(sec: Double) { if (auditioningStems) { if (ensureLoaded()) stems.seek(sec) } else mix.seek(sec) }

    private var loadedId: String? = null
    private var loadedFiles: Map<String, File> = emptyMap()
    private var lastEnabled: Set<String> = emptySet()

    /** The app stops the stem player when it backgrounds; the routed stem mode reloads it on the next transport. */
    private fun ensureLoaded(): Boolean {
        if (stems.durationSec > 0) return true
        val id = loadedId ?: return false
        if (!stems.load(id, loadedFiles)) return false
        applyMutes(lastEnabled)
        return true
    }

    /**
     * Route the audition to the stems: load all four [files], converge the mutes onto [enabled], then continue from
     * the full mix's position (playing if it was). False (audition stays on the full mix, which resumes) when the
     * set is incomplete or the stems can't be opened.
     */
    fun enterStems(songId: String, files: Map<String, File>, enabled: Set<String>): Boolean {
        if (auditioningStems) { applyMutes(enabled); return true }
        val pos = mix.playheadSec()
        val wasPlaying = mix.isPlaying
        if (wasPlaying) mix.pause()
        val set = LinkedHashMap<String, File>()
        for (n in StemCarve.STEMS) set[n] = files[n] ?: run { if (wasPlaying) mix.play(); return false }
        if (!stems.load("$songId#cut-stems", set)) { stems.stop(); if (wasPlaying) mix.play(); return false }
        auditioningStems = true
        loadedId = "$songId#cut-stems"; loadedFiles = set
        applyMutes(enabled)
        stems.seek(pos)
        if (wasPlaying) stems.togglePlayPause()
        return true
    }

    /** Back to the full mix at the stems' position (playing if they were); the stem decoders are released. */
    fun exitStems() {
        if (!auditioningStems) return
        val pos = stems.currentTimeSec
        val wasPlaying = stems.isPlaying
        stems.stop()
        auditioningStems = false; loadedId = null
        mix.seek(pos)
        if (wasPlaying) mix.play()
    }

    /** Live chip mutes: a stem is audible exactly when its chip is on. */
    fun applyMutes(enabled: Set<String>) {
        lastEnabled = enabled
        if (!auditioningStems) return
        for (n in StemCarve.STEMS) if (stems.isAudible(n) != (n in enabled)) stems.toggleMute(n)
    }

    /** New selection / carve / dismiss: silence and release the stem player (the full-mix preview is the caller's). */
    fun release() {
        stems.stop()
        auditioningStems = false; loadedId = null
    }

    companion object {
        /** The sheet caption under the chips in stem mode. */
        fun caption(auditioningStems: Boolean): String =
            if (auditioningStems) "The audition plays exactly this mix — what you hear is what gets cut."
            else "The preview plays the full mix; the sample is cut from only the stems selected below."
    }
}
