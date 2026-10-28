package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.withFrameNanos
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.BeatMath
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import kotlin.math.floor
import kotlin.math.max

/**
 * Pulse intensity from the TRUE audio playhead (iOS `BeatPulseView.envelope`). Pure: the flash decays in
 * WALL-CLOCK time (`source seconds since the last beat / rate`) so it looks the same at any tempo while
 * the beat spacing follows the playing tempo. No peak/decay state exists, so it cannot get stuck.
 */
object BeatPulsePhase {
    const val DOWNBEAT_DECAY_S = 0.34
    const val BEAT_DECAY_S = 0.22

    data class Envelope(val intensity: Double, val down: Boolean) {
        companion object { val Silent = Envelope(0.0, false) }
    }

    data class Beat(val sec: Double, val down: Boolean)

    /**
     * The most recent beat at/just before [pos] (source seconds): the REAL per-beat grid when the track
     * has one (a drifting track pulses on its actual beats), else a constant grid from the measured BPM
     * and first-downbeat phase (every 4th beat a downbeat). null before the first beat / without a grid.
     */
    fun lastBeat(t: LoadedTrack, pos: Double): Beat? {
        val beats = t.beatsMs
        if (!beats.isNullOrEmpty()) {
            val hit = BeatMath.lastBeat(beats, t.downbeatsMs, pos * 1000) ?: return null
            return Beat(hit.beatMs / 1000.0, hit.isDownbeat)
        }
        val bpm = (t.gridBpm ?: 0.0).takeIf { it > 0 } ?: (t.bpm ?: 0.0)
        if (bpm <= 0) return null
        val downSec = (t.firstDownbeatMs ?: 0) / 1000.0
        val secPerBeat = 60.0 / bpm
        val idx = floor((pos - downSec) / secPerBeat)
        if (idx < 0) return null
        return Beat(downSec + idx * secPerBeat, idx.toLong() % 4 == 0L)
    }

    fun envelope(playing: Boolean, track: LoadedTrack?, pos: Double, rate: Double): Envelope {
        if (!playing || track == null) return Envelope.Silent
        val b = lastBeat(track, pos) ?: return Envelope.Silent
        val elapsedWall = max(0.0, pos - b.sec) / max(rate, 0.05)
        val decay = if (b.down) DOWNBEAT_DECAY_S else BEAT_DECAY_S
        val t = max(0.0, 1 - elapsedWall / decay)
        return Envelope(t * t, b.down)   // quadratic ease
    }
}

/**
 * A glowing ring over the deck that flashes on each beat (downbeats brighter). Driven per display
 * frame from the true playhead, only while the deck plays. NOT composed at all when the setting is off
 * (the caller gates on the setting), so it costs nothing then.
 */
@Composable
fun BeatPulse(engine: MixEngine, deck: Deck, modifier: Modifier = Modifier) {
    var frame by remember { mutableLongStateOf(0L) }
    val ui by engine.ui.collectAsState()
    val playing = ui.deck(deck).isPlaying
    // Frame loop only while the deck plays (iOS TimelineView paused: !isPlaying).
    LaunchedEffect(deck, engine, playing) {
        if (playing) while (true) {
            withFrameNanos { frame = it }
        }
    }
    @Suppress("UNUSED_EXPRESSION") frame
    val env = BeatPulsePhase.envelope(
        playing = engine.isPlaying(deck),
        track = engine.loaded(deck),
        pos = engine.truePlayhead(deck) ?: engine.position(deck),
        rate = engine.rate(deck),
    )
    val color: Color = if (env.down) DeckColors.accent else DeckColors.gold
    if (env.intensity <= 0.0) return
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier
            .fillMaxSize()
            .alpha(env.intensity.toFloat())
            .shadow((9 * env.intensity).dp, shape, ambientColor = color, spotColor = color)
            .border((1 + 3 * env.intensity).dp, color, shape),
    )
}
