package com.levi.pocketdj.screens.settings

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.BuildConfig
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.diag.DiagKeyImporter
import com.levi.pocketdj.diag.DiagServices
import com.levi.pocketdj.shell.SettingsHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Seam the playback area fills with the dead-air meter summary (placeholder until it ships). */
fun interface DeadAirSource {
    fun summary(): String?

    companion object {
        @Volatile var current: DeadAirSource? = null
    }
}

/** Body of Settings ▸ Debug: build identity, backend, upload status, key import, capture. */
@Composable
internal fun ColumnScope.DebugPanel(host: SettingsHost) {
    val diag = DiagServices.get(host.graph)
    val context = LocalContext.current
    val status by diag.log.uploadStatus.collectAsState()
    val capturing = androidx.compose.runtime.remember { mutableStateOf(diag.capture.active) }
    var sessions by remember { mutableStateOf(diag.capture.sessions()) }
    var keyText by remember { mutableStateOf("") }
    var pendingMismatch by remember { mutableStateOf<String?>(null) }
    var pendingText by remember { mutableStateOf<String?>(null) }
    var enabled by remember { mutableStateOf(diag.log.isEnabled()) }
    var telemetry by remember { mutableStateOf(diag.settings.telemetryEnabled) }
    var keyId by remember { mutableStateOf(diag.keyId()) }
    val now = System.currentTimeMillis()

    fun report(outcome: DiagKeyImporter.Outcome) {
        keyId = diag.keyId()
        when (outcome) {
            is DiagKeyImporter.Outcome.Imported -> {
                pendingMismatch = null; pendingText = null; keyText = ""
                host.scope.launch { host.snackbar.showSnackbar("Diag key imported (${outcome.keyId})") }
            }
            is DiagKeyImporter.Outcome.NeedsConfirmation -> {
                pendingMismatch = outcome.mismatch.warning
            }
            is DiagKeyImporter.Outcome.Invalid ->
                host.scope.launch { host.snackbar.showSnackbar("Key rejected: ${outcome.reason}") }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) host.scope.launch {
            val text = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.readText() }.getOrNull()
            }
            if (text == null) host.snackbar.showSnackbar("Couldn't read the file") else {
                pendingText = text
                report(diag.importer.importText(text))
            }
        }
    }

    SettingsHeader("Debug")
    AboutRow("Version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
    AboutRow("Git", BuildConfig.GIT_SHA)
    AboutRow("Build", if (BuildConfig.DEBUG) "debug" else "release")
    AboutRow("Backend", RemoteEndpoints.summary)
    AboutRow("Logs", RemoteEndpoints.diagBucket)

    SettingsDivider()
    SettingsHeader("Remote diagnostics")
    Text(status.summary(now), style = MaterialTheme.typography.bodyMedium)
    SettingsCaption("Key: ${keyId ?: "none"}")
    ToggleRow("Remote diagnostics", enabled) {
        enabled = it; diag.settings.diagEnabled = it; diag.log.setEnabled(it)
    }
    ToggleRow("Remote telemetry", telemetry) {
        telemetry = it; diag.settings.telemetryEnabled = it; diag.log.telemetryEnabled = it
    }
    SettingsCaption("Telemetry streams every action and screen (with titles) near-live. Owner opt-in; uploads need a key.")

    OutlinedTextField(
        value = keyText, onValueChange = { keyText = it },
        label = { Text("Paste .pdjdiagkey contents") },
        modifier = Modifier.fillMaxWidth(), minLines = 2, maxLines = 4,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(enabled = keyText.isNotBlank(), onClick = { pendingText = keyText; report(diag.importer.importText(keyText)) }) { Text("Import key") }
        OutlinedButton(onClick = { picker.launch(arrayOf("*/*")) }) { Text("From file…") }
        OutlinedButton(enabled = keyId != null, onClick = { diag.importer.remove(); keyId = diag.keyId() }) { Text("Remove diag key") }
    }
    pendingMismatch?.let { warn ->
        SettingsCaption(warn)
        Button(onClick = { pendingText?.let { report(diag.importer.importText(it, force = true)) } }) { Text("Import anyway") }
    }

    SettingsDivider()
    SettingsHeader("Capture")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = {
            if (capturing.value) { diag.capture.stop(); sessions = diag.capture.sessions() } else diag.capture.start()
            capturing.value = diag.capture.active
        }) { Text(if (capturing.value) "Capture off" else "Capture on") }
        Text(if (capturing.value) "Recording…" else "${sessions.size} saved session(s)", style = MaterialTheme.typography.bodySmall)
    }
    sessions.forEach { f ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(f.name, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; putExtra(Intent.EXTRA_TEXT, runCatching { f.readText() }.getOrDefault(""))
                }
                context.startActivity(Intent.createChooser(send, "Share capture").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }) { Text("Share") }
            OutlinedButton(onClick = { diag.capture.delete(f); sessions = diag.capture.sessions() }) { Text("Delete") }
        }
    }

    SettingsDivider()
    SettingsHeader("Dead air")
    SettingsCaption(DeadAirSource.current?.summary() ?: "Dead-air meter not available yet (ships with the playback area).")
}

@Composable
private fun ToggleRow(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onChange)
    }
}
