package com.levi.pocketdj.screens.settings.sections

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.reset.ResetReport
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsDivider
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsHost
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.padding

internal const val RESET_SECTION_ID = "reset"

/** What the user must type to arm a destructive confirm. Pure so it is unit-tested. */
object ResetConfirmation {
    const val RESET_WORD = "RESET"
    const val DELETE_WORD = "DELETE"
    fun armed(typed: String, word: String): Boolean = typed.trim().equals(word, ignoreCase = true)

    // iOS copy (SettingsView.resetSection / deleteAccountRow), adapted for this platform.
    const val RESET_TITLE = "Reset everything on this device?"
    const val RESET_MESSAGE =
        "Removes sources, search & import-server config, and cached covers. Your collections are " +
            "cleared too. This can’t be undone. Music you’ve already prepared stays in your cloud " +
            "library — this only resets this device."
    const val DELETE_TITLE = "Delete your account and all data?"
    const val DELETE_MESSAGE =
        "This permanently erases your profile, library, collections, favorites, listening history, " +
            "downloads, and studio content from this device, and removes your synced copies from the " +
            "cloud. It can’t be undone. Even if the cloud can’t be reached, everything on this device " +
            "is still erased."
}

/**
 * Settings > Reset: "Reset all app state" (device) and "Delete account" (cloud + device). Both are
 * destructive rows behind a typed-confirmation dialog; after either finishes the process restarts
 * so the app comes back into onboarding (the marker was written `pending` by the service).
 * Order 950: last.
 */
internal fun resetSection() = SettingsSection(RESET_SECTION_ID, 950) { host -> ResetPanel(host) }

private enum class Pending { None, Reset, Delete }

/**
 * Process-scoped run state: the wipe runs on the app scope, so its busy flag and failure report must live there
 * too (rotation / leaving Settings mid-run would otherwise lose the "Restart" dialog and re-enable the buttons).
 */
internal object ResetRunState {
    val busy = kotlinx.coroutines.flow.MutableStateFlow(false)
    val finished = kotlinx.coroutines.flow.MutableStateFlow<ResetReport?>(null)
}

@Composable
private fun ResetPanel(host: SettingsHost) {
    val context = LocalContext.current
    var pending by remember { mutableStateOf(Pending.None) }
    val busy by ResetRunState.busy.collectAsState()
    // Shown BEFORE the restart when a step failed, so the honest "N things were skipped" copy is actually seen.
    val finished by ResetRunState.finished.collectAsState()

    SettingsDivider()
    SettingsHeader("Reset")
    OutlinedButton(
        onClick = { pending = Pending.Reset },
        enabled = !busy,
        modifier = Modifier.fillMaxWidth(),
    ) { Text(if (busy) "Working…" else "Reset all app state", color = MaterialTheme.colorScheme.error) }
    SettingsCaption("Device-local only. Clears sources, config, cached data and collections, then restarts into setup.")
    OutlinedButton(
        onClick = { pending = Pending.Delete },
        enabled = !busy,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
    ) { Text("Delete account", color = MaterialTheme.colorScheme.error) }
    SettingsCaption("Removes your synced copies from the cloud AND everything on this device.")
    finished?.let { report ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Finished with ${report.failures.size} problem(s)") },
            text = {
                Text(
                    "These steps hit a problem and were skipped; the rest completed: " +
                        report.failures.joinToString { it.name } +
                        ". If the cloud step failed, your synced copies are still being erased in the background " +
                        "and will be retried the next time the app starts.",
                )
            },
            confirmButton = { TextButton(onClick = { relaunchApp(context) }) { Text("Restart") } },
        )
    }

    if (pending != Pending.None) {
        val isDelete = pending == Pending.Delete
        val word = if (isDelete) ResetConfirmation.DELETE_WORD else ResetConfirmation.RESET_WORD
        var typed by remember(pending) { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { pending = Pending.None },
            title = { Text(if (isDelete) ResetConfirmation.DELETE_TITLE else ResetConfirmation.RESET_TITLE) },
            text = {
                Column {
                    Text(if (isDelete) ResetConfirmation.DELETE_MESSAGE else ResetConfirmation.RESET_MESSAGE)
                    OutlinedTextField(
                        value = typed,
                        onValueChange = { typed = it },
                        singleLine = true,
                        label = { Text("Type $word to confirm") },
                        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = ResetConfirmation.armed(typed, word),
                    onClick = {
                        pending = Pending.None
                        ResetRunState.busy.value = true
                        // App scope: the wipe must outlive this composition (the section can leave composition mid-run).
                        host.graph.appScope.launch(Dispatchers.IO) {
                            val services = host.graph.servicesGraph
                            val report: ResetReport = if (isDelete) services.accountDeletion.deleteAccountAndAllData()
                            else services.appReset.resetEverything()
                            // Wait for the stores' async writers (queued deletes) instead of a fixed sleep.
                            services.drainWriters()
                            withContext(Dispatchers.Main) {
                                if (report.ok) relaunchApp(context) else ResetRunState.finished.value = report
                            }
                        }
                    },
                ) { Text(if (isDelete) "Delete everything" else "Reset everything", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { pending = Pending.None }) { Text("Cancel") } },
        )
    }
}

/**
 * Restart into the launcher activity (ProcessPhoenix pattern): start a fresh task from the foreground
 * app, then exit. Starting the activity while still foreground avoids the background-activity-launch
 * restriction and the inexact-alarm deferral. Call on the main thread.
 */
internal fun relaunchApp(context: Context) {
    val app = context.applicationContext
    val component = app.packageManager.getLaunchIntentForPackage(app.packageName)?.component ?: return
    context.startActivity(Intent.makeRestartActivityTask(component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    Runtime.getRuntime().exit(0)
}
