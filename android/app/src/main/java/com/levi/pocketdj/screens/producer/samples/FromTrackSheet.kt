package com.levi.pocketdj.screens.producer.samples

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.engine.StemCarve

/**
 * The "Stem source" block of the from-track carve sheet (iOS `stemSection`): a switch that carves a MIX of the
 * track's separated stems instead of the full track, plus one chip per stem (vocals/drums/bass/other). The last
 * enabled chip can't be switched off. Hidden when the track has no stems (downloaded or stemmed server-side).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StemSourceSection(
    available: Boolean,
    downloaded: Boolean,
    stemMode: Boolean,
    enabled: Set<String>,
    busy: Boolean,
    onStemMode: (Boolean) -> Unit,
    onToggle: (String) -> Unit,
) {
    if (!available) return
    Column(Modifier.fillMaxWidth().testTag("sample-stem-section"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text("Stem source", style = MaterialTheme.typography.bodyMedium)
                Text(
                    if (downloaded) "Carve a mix of this track’s stems." else "Carve a mix of this track’s stems (downloaded when you switch this on).",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Switch(checked = stemMode, onCheckedChange = onStemMode, enabled = !busy, modifier = Modifier.testTag("sample-stem-mode"))
        }
        if (stemMode) {
            Text("The preview plays the full mix; the sample is cut from only the stems selected below.",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("sample-stem-caption"))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (name in DISPLAY_ORDER) {
                    FilterChip(name in enabled, { onToggle(name) }, { Text(name.replaceFirstChar { it.uppercase() }) }, Modifier.testTag("sample-stem-$name"), enabled = !busy)
                }
            }
        }
    }
}

/** Chip order matches the iOS row (drums, bass, other, vocals); the carve itself always sums in [StemCarve.STEMS] order. */
private val DISPLAY_ORDER = listOf("drums", "bass", "other", "vocals")
