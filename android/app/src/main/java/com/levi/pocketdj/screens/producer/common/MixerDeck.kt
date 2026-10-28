package com.levi.pocketdj.screens.producer.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.StudioSampleEdit

/**
 * The reusable mixer deck (iOS StudioMixerDeck): tempo / pitch / gain + the compressor / reverb / delay /
 * filter rack and an optional live looper. Stateless: every control copies the edit, mutates one field and
 * hands the WHOLE edit back to [onEdit], the host's single choke-point (clamp - live-apply - persist).
 */
@Composable
fun MixerDeck(
    edit: StudioSampleEdit,
    onEdit: (StudioSampleEdit) -> Unit,
    modifier: Modifier = Modifier,
    showGain: Boolean = true,
    showLooper: Boolean = true,
    loopOn: Boolean = false,
    onLoop: (Boolean) -> Unit = {},
    idPrefix: String = "mixdeck",
) {
    fun pct(v: Double) = "${Math.round(v * 100)}%"
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        EditSlider("Tempo", 0.5..10.0, edit.rate, { "×%.2f".format(java.util.Locale.US, it) }, "$idPrefix-tempo", step = 0.05) { onEdit(edit.copy(rate = it)) }
        EditSlider("Pitch", -12.0..12.0, edit.pitchSemitones, { "%+.0f st".format(java.util.Locale.US, it) }, "$idPrefix-pitch", step = 1.0) { onEdit(edit.copy(pitchSemitones = it)) }
        if (showGain) {
            EditSlider("Gain", -60.0..12.0, edit.gainDb, { "%+.0f dB".format(java.util.Locale.US, it) }, "$idPrefix-gain", step = 1.0) { onEdit(edit.copy(gainDb = it)) }
        }
        HorizontalDivider()
        Text("FX", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        EditSlider("Compressor", 0.0..1.0, edit.compWet, ::pct, "$idPrefix-comp", step = 0.05) { onEdit(edit.copy(compWet = it)) }
        EditSlider("Reverb", 0.0..1.0, edit.reverbWet, ::pct, "$idPrefix-reverb", step = 0.05) { onEdit(edit.copy(reverbWet = it)) }
        EditSlider("Delay", 0.0..1.0, edit.delayWet, ::pct, "$idPrefix-delay", step = 0.05) { onEdit(edit.copy(delayWet = it)) }
        EditSlider("Filter", 0.0..1.0, edit.filterAmt, ::pct, "$idPrefix-filter", step = 0.05) { onEdit(edit.copy(filterAmt = it)) }
        if (showLooper) {
            HorizontalDivider()
            FilterChip(
                selected = loopOn,
                onClick = { onLoop(!loopOn) },
                label = { Text(if (loopOn) "Looping" else "Loop") },
                leadingIcon = { Icon(Icons.Filled.Repeat, contentDescription = null) },
                modifier = Modifier.testTag("$idPrefix-loop"),
            )
        }
    }
}
