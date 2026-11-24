package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.nowplaying.NetworkClass
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher
import com.levi.pocketdj.mix.nowplaying.NpMixMode
import com.levi.pocketdj.mix.engine.StemHandover

/** Which colour family the chip draws in (iOS: accent when the controls are live, dim otherwise). */
enum class NpMixChipTone { ACCENT, DIM }

/** The leading glyph (iOS `MixModeChipLabel`): filled dot, ring, download arrow, or alert. */
enum class NpMixChipGlyph { FILLED_DOT, RING, DOWNLOAD, ALERT, NONE }

/**
 * The Mix Mode status chip as pure data (JVM-tested): [NpMixMode.Indicator] -> iOS words / colour / progress /
 * TalkBack words. [text] is the iOS `chipText` verbatim; [progress] is the byte fraction of a Buffering / Holding
 * chip (null = unknown or not a progress chip).
 */
data class NpMixChipState(
    val text: String,
    val tone: NpMixChipTone,
    val glyph: NpMixChipGlyph,
    val progress: Float?,
    /** [NpMixMode.Indicator.a11yValue]: stable test / accessibility value. */
    val value: String,
    /** The chip's full words (text + the rule-A edition note), as TalkBack reads them. */
    val spoken: String,
) {
    companion object {
        /** null = no chip (Mix Mode off). */
        fun of(indicator: NpMixMode.Indicator, note: String? = null): NpMixChipState? {
            val text = indicator.chipText ?: return null
            val glyph = when (indicator) {
                NpMixMode.Indicator.Engaged, NpMixMode.Indicator.StemsLoading -> NpMixChipGlyph.FILLED_DOT
                NpMixMode.Indicator.Ready, NpMixMode.Indicator.ReadyFromAppleMusic -> NpMixChipGlyph.RING
                is NpMixMode.Indicator.Buffering, is NpMixMode.Indicator.Holding, NpMixMode.Indicator.Waiting -> NpMixChipGlyph.DOWNLOAD
                is NpMixMode.Indicator.Unavailable, NpMixMode.Indicator.Suspended,
                NpMixMode.Indicator.Ripping, is NpMixMode.Indicator.RippingEdition -> NpMixChipGlyph.ALERT
                NpMixMode.Indicator.Off -> NpMixChipGlyph.NONE
            }
            val progress = when (indicator) {
                is NpMixMode.Indicator.Buffering -> indicator.fraction
                is NpMixMode.Indicator.Holding -> indicator.fraction
                else -> null
            }?.toFloat()?.coerceIn(0f, 1f)
            return NpMixChipState(
                text = text,
                tone = if (indicator.controlsLive) NpMixChipTone.ACCENT else NpMixChipTone.DIM,
                glyph = glyph,
                progress = progress,
                value = indicator.a11yValue,
                spoken = listOfNotNull(text, note).joinToString(" · "),
            )
        }
    }
}

/** The MIX MODE status chip (`np-mix-mode-status`); renders nothing while Mix Mode is off. */
@Composable
fun NpMixModeChip(indicator: NpMixMode.Indicator, modifier: Modifier = Modifier, note: String? = null) {
    val s = NpMixChipState.of(indicator, note) ?: return
    val color = if (s.tone == NpMixChipTone.ACCENT) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier
            .testTag("np-mix-mode-status")
            .clearAndSetSemantics {
                contentDescription = "Mix Mode status"
                stateDescription = s.spoken
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        when (s.glyph) {
            NpMixChipGlyph.FILLED_DOT -> Surface(Modifier.size(6.dp), shape = CircleShape, color = color) {}
            NpMixChipGlyph.RING -> Surface(Modifier.size(6.dp), shape = CircleShape, color = Color.Transparent, border = BorderStroke(1.5.dp, color)) {}
            NpMixChipGlyph.DOWNLOAD -> Icon(Icons.Filled.KeyboardArrowDown, null, Modifier.size(12.dp), tint = color)
            NpMixChipGlyph.ALERT -> Icon(Icons.Filled.Info, null, Modifier.size(12.dp), tint = color)
            NpMixChipGlyph.NONE -> Unit
        }
        Text(
            if (note != null) "${s.text} · $note" else s.text,
            fontSize = 11.sp, color = color, textAlign = TextAlign.Center, maxLines = 2,
            modifier = Modifier.weight(1f, fill = false),
        )
        s.progress?.let {
            LinearProgressIndicator(
                progress = { it }, gapSize = 0.dp, drawStopIndicator = {},
                modifier = Modifier.size(width = 28.dp, height = 3.dp).clip(CircleShape).testTag("np-mix-mode-progress"),
            )
        }
    }
}

/** The MIX MODE capsule switch (`np-mix-mode`): session state, never engages the DSP by itself. */
@Composable
fun NpMixModeSwitch(on: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val accent = MaterialTheme.colorScheme.primary
    val tint = if (on) accent else MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        shape = CircleShape,
        color = if (on) accent.copy(alpha = 0.18f) else MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, if (on) accent else MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier
            .testTag("np-mix-mode")
            .semantics {
                contentDescription = "Mix Mode"
                stateDescription = if (on) "On" else "Off"
                role = Role.Switch
            }
            .clip(CircleShape)
            .clickable(enabled = enabled) { onToggle(!on) },
    ) {
        Text(
            "Mix Mode", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

/**
 * Production reader of the iOS `mixModeIndicator` inputs (the facts live in the playback / mix graphs). Cheap
 * in-memory lookups; the caller re-reads it twice a second while buffering (the byte progress isn't observable).
 */
object NpMixIndicatorReader {
    fun read(app: AppGraph, deviceMode: Boolean): NpMixMode.Indicator {
        val mix = app.playbackGraph.npMix
        val coordinator = mix.coordinator
        if (!coordinator.enabled) return NpMixMode.Indicator.Off
        val st = app.playbackGraph.sequencer.state.value
        val row = st.queue.getOrNull(st.index)
        if (!st.isRunning || row == null) return NpMixMode.Indicator.Off
        val mg = app.mixGraph
        val burns = app.servicesGraph.burnStore
        val loader = mg.mixStreamLoader
        val pf = mg.stemLockPrefetcher
        val engine = mg.npDspEngine
        val controller = app.playbackController
        val audioId = row.resolveId
        val net = NetworkClass.current(app.appContext.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager)
        val cfg = mix.settings()
        val stream = loader.stream(audioId)
        val engaged = engine.isEngaged && engine.engagedSongId == row.id
        val amActive = controller.isAppleMusicActive
        val local = burns.isReadyInLedger(audioId)
        val fraction = stream?.expectedBytes?.takeIf { it > 0 }?.let { (stream.bytesReceived.toDouble() / it).coerceIn(0.0, 1.0) }
        return NpMixMode.indicator(
            NpMixMode.IndicatorInput(
                enabled = true, running = true, held = st.isHeldForResume,
                mixTabLive = NowPlayingSeams.mixSessionActive,
                engaged = engaged,
                stemsLoading = mg.npDspHost.ui.value.stemHandover == StemHandover.TO_STEMS,
                mixable = mg.npDspHost.available(),
                onAppleMusic = amActive,
                live = controller.nowPlaying.value?.isLive == true,
                offline = net == NetworkClass.OFFLINE,
                ripped = loader.canStream(audioId) || local,
                deviceMode = deviceMode,
                bufferFraction = fraction,
                buffering = (!local || amActive) && pf.isPlannedSong(audioId),
                failed = pf.songFailedRecently(audioId),
                storageFull = pf.songBlockedRecently(audioId),
                cellularOff = NowPlayingPrefetcher.mixReach(net, cfg.cellular, cfg.bufferAhead) == null,
                dspHolding = engaged && engine.isBuffering,
                // Rip-server work from the lane is gated off on Android until Levi decides (P2-MM-9).
                ripping = false,
            ),
        )
    }
}

/**
 * "Mix Mode" with a check: the Now Playing record menu and the mini bar's long-press menu (`np-menu-mix-mode`).
 * Session state; disabled with no session.
 */
@Composable
fun NpMixModeMenuItem(app: AppGraph, onDone: () -> Unit) {
    val coordinator = app.playbackGraph.npMix.coordinator
    val on by coordinator.state.collectAsState()
    val seq by app.playbackGraph.sequencer.state.collectAsState()
    DropdownMenuItem(
        text = { Text("Mix Mode") },
        leadingIcon = { if (on.enabled) Icon(Icons.Filled.Check, contentDescription = "On") },
        enabled = seq.isRunning,
        onClick = { coordinator.setMixMode(!on.enabled); onDone() },
        modifier = Modifier.testTag("np-menu-mix-mode").semantics { stateDescription = if (on.enabled) "On" else "Off" },
    )
}
