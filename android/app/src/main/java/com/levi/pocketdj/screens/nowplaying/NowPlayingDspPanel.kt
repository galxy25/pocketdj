package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.mix.engine.StemHandover
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.MixRanges
import com.levi.pocketdj.mix.nowplaying.DjDisplayTouch
import com.levi.pocketdj.mix.nowplaying.NowPlayingDspHost
import com.levi.pocketdj.mix.nowplaying.StemLock
import com.levi.pocketdj.screens.mix.MixBufferingBadge
import kotlinx.coroutines.launch
import java.util.Locale

/** Pure readouts for the panel (JVM-tested). */
object DspPanelText {
    fun tempo(rate: Double) = String.format(Locale.US, "%.2f×", rate)
    fun pitch(st: Double) = if (st == 0.0) "0 st" else String.format(Locale.US, "%+.1f st", st)
    fun gain(v: Double) = "${Math.round(v * 100)}%"
    fun pending(h: StemHandover?): String? = when (h) {
        StemHandover.TO_STEMS -> "Loading stems…"
        StemHandover.TO_FULL_MIX -> "Loading full mix…"
        null -> null
    }
}

/**
 * F4 - the collapsible Mix mini-panel docked on the Now Playing deck (installed into
 * [NowPlayingSeams.dspSlot]). Tempo / pitch / gain / effects / stems for the CURRENTLY PLAYING local track.
 * The HEADER (chevron, "Mix", status chip, Mix Mode switch) shows whenever a session runs; the controls show when
 * the row is mixable - or, with Mix Mode on, DISABLED while its local copy buffers - and a non-mixable row keeps
 * the "hide, don't grey" rule. Every control first calls [NowPlayingDspHost.engage]
 * (idempotent: the first touch swaps ExoPlayer -> DSP at the current position).
 */
@Composable
fun NowPlayingDspPanel(host: NowPlayingDspHost, modifier: Modifier = Modifier) {
    val ui by host.ui.collectAsState()
    var expanded by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun touch(block: (com.levi.pocketdj.mix.nowplaying.NowPlayingDspEngine) -> Unit) { scope.launch { host.withEngaged(block) } }

    val ctx = androidx.compose.ui.platform.LocalContext.current
    val app = remember { com.levi.pocketdj.di.AppGraph.get(ctx) }
    val coordinator = app.playbackGraph.npMix.coordinator
    val mixState by coordinator.state.collectAsState()
    val seq by app.playbackGraph.sequencer.state.collectAsState()
    val mixTabLive by NowPlayingSeams.mixSessionActiveFlow.collectAsState()
    val modeToken by remember { app.settings.flow(com.levi.pocketdj.playback.PlaybackPrefKeys.PLAYBACK_MODE) }
        .collectAsState(initial = com.levi.pocketdj.playback.PlaybackMode.CLOUD.token)
    val deviceMode = com.levi.pocketdj.playback.PlaybackMode.fromToken(modeToken) == com.levi.pocketdj.playback.PlaybackMode.DEVICE
    // The byte progress and the lane's state are not observable: re-read twice a second while Mix Mode is on.
    var tick by remember { mutableStateOf(0) }
    androidx.compose.runtime.LaunchedEffect(mixState.enabled) {
        while (mixState.enabled) { kotlinx.coroutines.delay(500); tick++ }
    }
    val indicator = remember(tick, mixState, seq, ui, mixTabLive, deviceMode) { NpMixIndicatorReader.read(app, deviceMode) }
    val strip = remember(tick, mixState, seq, ui, deviceMode) { NpMixBufferRows.read(app, deviceMode) }
    val djController = app.playbackGraph.djMode.controller
    val djState by djController.state.collectAsState()
    val djNote = if (com.levi.pocketdj.ParityFlags.DJ_MODE) {
        remember(tick, djState, seq, mixTabLive) { DjChipText.mixChipNote(djController.indicator(), null) }
    } else null
    // P2-DJ-12: while DJ automation runs the controls SHOW the heard values (read-only; a touch acts on what is shown).
    val display by host.engine.djDisplay.flow.collectAsState()
    val showsHeader = seq.isRunning
    val controlsVisible = ui.available || indicator is com.levi.pocketdj.mix.nowplaying.NpMixMode.Indicator.Buffering

    if (!showsHeader) {
        if (ui.lock.enabled) StemLockIndicator(ui.indicator, modifier.padding(horizontal = 12.dp, vertical = 4.dp))
        return
    }
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag("np-mix-panel"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                Modifier.clickable { expanded = !expanded }.testTag("np-mix-toggle"),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(if (expanded) "▾" else "▸", fontSize = 12.sp)
                Text("Mix", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                if (ui.engaged) Text("●", fontSize = 10.sp, color = MaterialTheme.colorScheme.primary, modifier = Modifier.semantics { contentDescription = "Engaged" })
                if (ui.lock.enabled) Icon(Icons.Filled.Lock, "Stem Lock on", Modifier.size(12.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { NpMixModeChip(indicator, note = djNote) }
            // DJ Mode sits LEFT of Mix Mode, the same capsule (np-dj-mode §7); hidden until ParityFlags.DJ_MODE.
            NpDjModeSwitch(
                on = djState.enabled, enabled = seq.isRunning,
                onToggle = { on -> djController.setDjMode(on); if (on) expanded = true },
                crossfade = if (display.active) display.crossfade.toFloat() else null,
            )
            NpMixModeSwitch(
                on = mixState.enabled, enabled = seq.isRunning,
                onToggle = { on -> coordinator.setMixMode(on); if (on) expanded = true },
            )
        }
        if (ui.lock.enabled) StemLockIndicator(ui.indicator)
        if (expanded && controlsVisible) Box(
            Modifier.then(if (ui.available) Modifier else Modifier.alpha(0.45f).blockTouches()),
        ) { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        run {
            // The sliders follow the display while a transition runs; a drag sets the listener's value from the shown one and
            // ends the glide (the engine's setRate / setPitch), so nothing jumps.
            val shownRate = display.shownRate(ui.rate)
            val shownPitch = display.shownPitch(ui.pitch)
            DspSlider("Tempo", DspPanelText.tempo(shownRate), shownRate, MixRanges.rate, "np-mix-tempo") { v -> touch { it.setRate(v) } }
            DspSlider("Pitch", DspPanelText.pitch(shownPitch), shownPitch, MixRanges.pitch, "np-mix-pitch") { v -> touch { it.setPitch(v) } }
            DspSlider("Gain", DspPanelText.gain(ui.volume), ui.volume, MixRanges.volume, "np-mix-gain") { v -> touch { it.setVolume(v) } }
            // DJ's automatic leveling trim: read-only, separate from the listener's Gain.
            DjLevelingReadoutRow(display.leveling)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Effects", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                FxLockCapsule(ui.fxLock.enabled, ui.fxIndicator, onToggle = { host.setFxLock(!ui.fxLock.enabled) })
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (e in Effect.entries) {
                    val shown = display.shownEffect(e, e in ui.effectsOn, ui.effectStrength[e] ?: 0.5)
                    FilterChip(
                        selected = shown.on,
                        // a tap flips the SHOWN state: tapping a swept effect turns it off
                        onClick = { touch { it.setEffect(e, DjDisplayTouch.tapTargetOn(shown)) } },
                        label = { Text(e.label, fontSize = 12.sp) },
                        modifier = Modifier.testTag("np-mix-fx-${e.raw}"),
                    )
                }
            }
            for (e in Effect.entries) {
                val shown = display.shownEffect(e, e in ui.effectsOn, ui.effectStrength[e] ?: 0.5)
                if (!shown.on) continue
                DspSlider("${e.label} amount", "${Math.round(shown.strength * 100)}%", shown.strength, 0.0..1.0, "np-mix-fx-${e.raw}-strength") { v ->
                    touch {
                        // a drag on a swept effect keeps it on: the listener's effect turns on first (that ends the glide)
                        if (DjDisplayTouch.strengthDragNeedsEnable(shown, it.isEnabled(e))) it.setEffect(e, true)
                        it.setEffectStrength(e, v)
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Stems", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                DspPanelText.pending(ui.stemHandover)?.let { MixBufferingBadge(text = it, tag = "np-mix-stems-pending") }
                Row(
                    Modifier.clickable { host.setStemLock(!ui.lock.enabled) }.testTag("np-stemlock-toggle"),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(
                        Icons.Filled.Lock, if (ui.lock.enabled) "Stem Lock on" else "Stem Lock off", Modifier.size(16.dp),
                        tint = if (ui.lock.enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(if (ui.lock.enabled) "Lock on" else "Lock", fontSize = 12.sp)
                }
                Switch(
                    checked = ui.stemMode, enabled = ui.stemsObtainable || ui.stemMode,
                    onCheckedChange = { on -> touch { it.setStemMode(on) } },
                    modifier = Modifier.testTag("np-mix-stems"),
                )
            }
            if (ui.stemMode) {
                for (name in BurnFileNames.STEM_NAMES) {
                    val muted = name in ui.muted
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = !muted, onClick = { touch { it.setStemMuted(name, !muted) } },
                            label = { Text(name.replaceFirstChar { it.uppercase() }, fontSize = 12.sp) },
                            modifier = Modifier.testTag("np-mix-stem-$name"),
                        )
                        Slider(
                            value = (ui.volumes[name] ?: 1.0).toFloat(), onValueChange = { v -> touch { it.setStemVolume(name, v.toDouble()) } },
                            valueRange = 0f..1f, enabled = !muted, modifier = Modifier.weight(1f).testTag("np-mix-stem-$name-vol"),
                        )
                    }
                }
            }
        }
        } }
        if (mixState.enabled) NpMixBufferStrip(strip)
    }
}

/** Swallows every touch on the controls (the Mix Mode panel shows them DISABLED while the track buffers). */
private fun Modifier.blockTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
    }
}

@Composable
private fun DspSlider(title: String, display: String, value: Double, range: ClosedFloatingPointRange<Double>, tag: String, onChange: (Double) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(title, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(display, fontSize = 11.sp)
        }
        Slider(
            value = value.toFloat().coerceIn(range.start.toFloat(), range.endInclusive.toFloat()),
            onValueChange = { onChange(it.toDouble()) },
            valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
            modifier = Modifier.testTag(tag).semantics { contentDescription = "$title $display" },
        )
    }
}
