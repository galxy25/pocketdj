package com.levi.pocketdj.screens.settings.sections

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal fun historySection() = SettingsSection(SettingsSections.HISTORY, 600) { host ->
    val context = LocalContext.current
    var confirmClearHistory by remember { mutableStateOf(false) }

    SettingsHeader("History")
    OutlinedButton(onClick = { confirmClearHistory = true }) {
        Text("Clear play history")
    }
    SettingsCaption(
        "Removes every recorded play from this device. Settings, sources, " +
            "and the install identity are kept.",
    )

    if (confirmClearHistory) {
        AlertDialog(
            onDismissRequest = { confirmClearHistory = false },
            title = { Text("Clear play history?") },
            text = {
                Text(
                    "Every recorded play is removed from this device. " +
                        "Settings and sources are kept. This can't be undone.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClearHistory = false
                        host.scope.launch {
                            // clear() does synchronous file IO — keep it off-main.
                            withContext(Dispatchers.Default) {
                                PlayHistoryStore.get(context).clear()
                            }
                            host.snackbar.showSnackbar("Play history cleared")
                        }
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearHistory = false }) { Text("Cancel") }
            },
        )
    }
}
