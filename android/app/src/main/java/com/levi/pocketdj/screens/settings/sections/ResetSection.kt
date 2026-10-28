package com.levi.pocketdj.screens.settings.sections

import android.app.AlarmManager
import android.app.PendingIntent
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
import kotlinx.coroutines.delay
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

@Composable
private fun ResetPanel(host: SettingsHost) {
    val context = LocalContext.current
    var pending by remember { mutableStateOf(Pending.None) }
    var busy by remember { mutableStateOf(false) }
    var failures by remember { mutableStateOf(0) }

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
    if (failures > 0) SettingsCaption("$failures step(s) hit a problem and were skipped; the rest completed.")

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
                        busy = true
                        // App scope: the wipe must outlive this composition (the section can leave composition mid-run).
                        host.graph.appScope.launch(Dispatchers.IO) {
                            val services = host.graph.servicesGraph
                            val report: ResetReport = if (isDelete) services.accountDeletion.deleteAccountAndAllData()
                            else services.appReset.resetEverything()
                            failures = report.failures.size
                            delay(400)
                            relaunchApp(context)
                        }
                    },
                ) { Text(if (isDelete) "Delete everything" else "Reset everything", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { pending = Pending.None }) { Text("Cancel") } },
        )
    }
}

/** Restart the process into the launcher activity (alarm-scheduled so the new process starts after this one dies). */
internal fun relaunchApp(context: Context) {
    val app = context.applicationContext
    val launch = app.packageManager.getLaunchIntentForPackage(app.packageName) ?: return
    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
    val pi = PendingIntent.getActivity(app, 7013, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
    (app.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        .set(AlarmManager.RTC, System.currentTimeMillis() + 300, pi)
    android.os.Process.killProcess(android.os.Process.myPid())
}
