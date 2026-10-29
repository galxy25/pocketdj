package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.data.settings.SourceConfig
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

internal fun dataSourcesSection() = SettingsSection(SettingsSections.DATA_SOURCES, 100) { host ->
    val graph = host.graph
    SettingsHeader("Data sources")
    val current = host.settings
    if (current == null) {
        CircularProgressIndicator(Modifier.padding(8.dp))
    } else {
        current.sources.forEach { source ->
            SourceRow(
                source = source,
                showUrl = host.showAdvanced,
                onToggle = { enabled ->
                    host.scope.launch {
                        // Transform inside the DataStore edit — a stale composition
                        // snapshot must not undo a quick preceding toggle.
                        graph.settings.updateSources { sources ->
                            sources.map {
                                if (it.id == source.id) it.copy(enabled = enabled) else it
                            }
                        }
                        graph.catalogRepository.refresh()
                    }
                },
            )
        }
        // One-tap preset loaders, hidden once present (match name OR url).
        val presets = listOf(AppSettings.appleMusicSource(), AppSettings.digitalSource())
        presets.forEach { preset ->
            val present = current.sources.any { it.name == preset.name || it.url == preset.url }
            if (!present) {
                TextButton(
                    onClick = {
                        host.scope.launch {
                            graph.settings.updateSources { sources ->
                                if (sources.any { it.name == preset.name || it.url == preset.url }) {
                                    sources
                                } else {
                                    sources + preset
                                }
                            }
                            graph.catalogRepository.refresh()
                        }
                    },
                ) {
                    Text("Add “${preset.name}”")
                }
            }
        }
    }
}

internal fun importServerSection() = SettingsSection(SettingsSections.IMPORT_SERVER, 300) { host ->
    val graph = host.graph
    // Editable copies, seeded once from the first settings emission.
    var ripUrl by remember { mutableStateOf("") }
    var ripToken by remember { mutableStateOf("") }
    val loaded = host.settings != null
    LaunchedEffect(loaded) {
        host.settings?.let {
            ripUrl = it.ripServerUrl
            ripToken = it.ripToken
        }
    }
    var healthResult by remember { mutableStateOf<String?>(null) }
    var testingHealth by remember { mutableStateOf(false) }

    SettingsHeader("Import server")
    SettingsCaption(
        "Blank by default — paste your rip server's URL (e.g. a Tailscale " +
            "Funnel address). Songs without a public rip stay browsable " +
            "metadata until a server is configured.",
    )
    OutlinedTextField(
        value = ripUrl,
        onValueChange = { ripUrl = it },
        label = { Text("Server URL") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = ripToken,
        onValueChange = { ripToken = it },
        label = { Text("Access token (optional)") },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Button(
            onClick = {
                host.scope.launch {
                    graph.settings.setRipServer(ripUrl, ripToken)
                    host.snackbar.showSnackbar("Import server saved")
                }
            },
        ) {
            Text("Save")
        }
        Spacer(Modifier.width(12.dp))
        OutlinedButton(
            enabled = ripUrl.isNotBlank() && !testingHealth,
            onClick = {
                host.scope.launch {
                    testingHealth = true
                    healthResult = null
                    try {
                        // Probe the TYPED values without committing them — only Save
                        // persists (a failed test must not flip every unripped song to
                        // rip-on-demand ▶).
                        val health = graph.ripServerClient.health(ripUrl, ripToken)
                        healthResult = if (health.ok) {
                            buildString {
                                append("Connected")
                                health.catalog?.songs?.let { append(" — $it songs") }
                                health.version?.let { append(" · v$it") }
                                if (health.hls == true) append(" · HLS")
                            }
                        } else {
                            "Server responded but reported not-OK"
                        }
                    } catch (error: RipServerClient.RipServerException) {
                        healthResult = error.message
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        healthResult = error.message ?: "Unreachable"
                    } finally {
                        testingHealth = false
                    }
                }
            },
        ) {
            Text(if (testingHealth) "Testing…" else "Test connection")
        }
    }
    healthResult?.let { SettingsCaption(it) }
}

internal fun jukeboxBrokerSection() = SettingsSection(SettingsSections.JUKEBOX_BROKER, 500) { host ->
    val graph = host.graph
    var jukeboxUrl by remember { mutableStateOf("") }
    var jukeboxToken by remember { mutableStateOf("") }
    val loaded = host.settings != null
    LaunchedEffect(loaded) {
        host.settings?.let {
            jukeboxUrl = it.jukeboxServerUrl
            jukeboxToken = it.jukeboxToken
        }
    }

    SettingsHeader("Jukebox broker")
    SettingsCaption("The request-line broker Jukebox Hero connects to. Blank = off.")
    OutlinedTextField(
        value = jukeboxUrl,
        onValueChange = { jukeboxUrl = it },
        label = { Text("Broker URL") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = jukeboxToken,
        onValueChange = { jukeboxToken = it },
        label = { Text("Broker token (optional)") },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.fillMaxWidth(),
    )
    Spacer(Modifier.height(8.dp))
    Button(
        onClick = {
            host.scope.launch {
                graph.settings.setJukeboxServer(jukeboxUrl, jukeboxToken)
                host.snackbar.showSnackbar("Jukebox broker saved")
            }
        },
    ) {
        Text("Save")
    }
    // NOTE: the "Search online" toggle was removed — Browse has no online mode on Android
    // yet; the settings key (`onlineSearchEnabled`) survives for when it ships.
}

@Composable
private fun SourceRow(source: SourceConfig, showUrl: Boolean, onToggle: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(source.name, style = MaterialTheme.typography.bodyMedium)
            // The raw index URL is an endpoint detail: shown only with Settings ▸ Show advanced.
            if (showUrl) Text(
                source.url,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Switch(checked = source.enabled, onCheckedChange = onToggle)
    }
}
