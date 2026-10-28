package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
 * Hidden - never greyed - for a non-local row or while a Mix session runs; a lock-only status row remains so a
 * locked session can say why a track plays the full mix. Every control first calls [NowPlayingDspHost.engage]
 * (idempotent: the first touch swaps ExoPlayer -> DSP at the current position).
 */
@Composable
fun NowPlayingDspPanel(host: NowPlayingDspHost, modifier: Modifier = Modifier) {
    val ui by host.ui.collectAsState()
    var expanded by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun touch(block: (com.levi.pocketdj.mix.nowplaying.NowPlayingDspEngine) -> Unit) { scope.launch { host.withEngaged(block) } }

    if (!ui.available) {
        if (ui.lock.enabled) StemLockIndicator(ui.indicator, modifier.padding(horizontal = 12.dp, vertical = 4.dp))
        return
    }
    Column(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("np-mix-panel"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { expanded = !expanded }.testTag("np-mix-toggle"),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(if (expanded) "▾" else "▸", fontSize = 12.sp)
            Text("Mix", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            if (ui.engaged) Text("●", fontSize = 10.sp, color = MaterialTheme.colorScheme.primary, modifier = Modifier.semantics { contentDescription = "Engaged" })
            if (ui.lock.enabled) Icon(Icons.Filled.Lock, "Stem Lock on", Modifier.size(12.dp))
        }
        if (ui.lock.enabled) StemLockIndicator(ui.indicator)
        if (expanded) {
            DspSlider("Tempo", DspPanelText.tempo(ui.rate), ui.rate, MixRanges.rate, "np-mix-tempo") { v -> touch { it.setRate(v) } }
            DspSlider("Pitch", DspPanelText.pitch(ui.pitch), ui.pitch, MixRanges.pitch, "np-mix-pitch") { v -> touch { it.setPitch(v) } }
            DspSlider("Gain", DspPanelText.gain(ui.volume), ui.volume, MixRanges.volume, "np-mix-gain") { v -> touch { it.setVolume(v) } }
            Text("Effects", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (e in Effect.entries) {
                    FilterChip(
                        selected = e in ui.effectsOn,
                        onClick = { touch { it.setEffect(e, !it.isEnabled(e)) } },
                        label = { Text(e.label, fontSize = 12.sp) },
                        modifier = Modifier.testTag("np-mix-fx-${e.raw}"),
                    )
                }
            }
            for (e in Effect.entries.filter { it in ui.effectsOn }) {
                DspSlider("${e.label} amount", "${Math.round((ui.effectStrength[e] ?: 0.5) * 100)}%", ui.effectStrength[e] ?: 0.5, 0.0..1.0, "np-mix-fx-${e.raw}-strength") { v ->
                    touch { it.setEffectStrength(e, v) }
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
