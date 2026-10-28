package com.levi.pocketdj.screens.producer.tracks

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

/** Persisted record mode: false = Clean (canonical-rate, pitch-correct), true = Quantized (lo-fi relabel). */
class RecordModePrefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("pocketdj-tracks-ui", Context.MODE_PRIVATE)
    var quantized: Boolean
        get() = runCatching { sp.getBoolean(KEY, false) }.getOrDefault(false)
        set(v) { runCatching { sp.edit().putBoolean(KEY, v).apply() } }
    private companion object { const val KEY = "pdj.tracks.quantizedRecording" }
}

/** Menu copy shared by the UI and its test. */
object RecordModeText {
    const val CLEAN = "Clean"
    const val QUANTIZED = "Quantized (lo-fi)"
    fun label(quantized: Boolean) = if (quantized) QUANTIZED else CLEAN
}

/**
 * Record-to-master: a record/stop toggle (starts playback WITH the master tap from the cursor; tapping it
 * while recording stops and bakes) plus a caret menu to pick Clean or Quantized (lo-fi).
 */
@Composable
fun RecordControl(
    recording: Boolean, quantized: Boolean, enabled: Boolean,
    onToggle: () -> Unit, onQuantizedChange: (Boolean) -> Unit, modifier: Modifier = Modifier,
) {
    var menu by remember { mutableStateOf(false) }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        FilledIconToggleButton(
            checked = recording, onCheckedChange = { onToggle() }, enabled = enabled || recording,
            modifier = Modifier.semantics { contentDescription = if (recording) "Stop recording" else "Record master (${RecordModeText.label(quantized)})" }.testTag("tracks-record"),
        ) {
            Icon(if (recording) Icons.Filled.Stop else Icons.Filled.FiberManualRecord, null, tint = if (recording) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.error)
        }
        Box {
            IconButton(onClick = { menu = true }, enabled = !recording, modifier = Modifier.semantics { contentDescription = "Record mode" }.testTag("tracks-record-mode")) {
                Icon(Icons.Filled.ArrowDropDown, null)
            }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(
                    text = { Text((if (!quantized) "✓ " else "    ") + RecordModeText.CLEAN) },
                    onClick = { menu = false; onQuantizedChange(false) }, modifier = Modifier.testTag("tracks-record-mode-clean"),
                )
                DropdownMenuItem(
                    text = { Text((if (quantized) "✓ " else "    ") + RecordModeText.QUANTIZED) },
                    onClick = { menu = false; onQuantizedChange(true) }, modifier = Modifier.testTag("tracks-record-mode-quantized"),
                )
            }
        }
    }
}
