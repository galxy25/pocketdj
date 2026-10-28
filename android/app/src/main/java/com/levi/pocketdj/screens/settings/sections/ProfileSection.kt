package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.unit.dp
import androidx.compose.ui.Alignment
import com.levi.pocketdj.data.sync.SyncSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.levi.pocketdj.data.settings.ShellSettings
import com.levi.pocketdj.onboarding.OnboardingPrefs
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.launch

internal const val PROFILE_SECTION_ID = "profile"

/**
 * Settings > Profile: "Your PocketDJ name" (edits the synced [com.levi.pocketdj.data.sync.ProfileStore],
 * which mirrors into the PROFILE_NAME pref, collections and the jukebox DJ line) plus cross-device
 * sync status / "Sync now". Order 50: first.
 */
internal fun profileSection() = SettingsSection(PROFILE_SECTION_ID, 50) { host ->
    val graph = host.graph
    val services = graph.servicesGraph
    var name by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            services.profile.migrateIfNeeded(graph.settings.get(OnboardingPrefs.PROFILE_NAME))
        }
        name = services.profile.name.ifEmpty { graph.settings.get(OnboardingPrefs.PROFILE_NAME) }
    }
    // A cloud pull changes the profile name underneath us: follow it.
    val profileState by services.profile.state.collectAsState()
    LaunchedEffect(profileState.name) { if (profileState.name.isNotEmpty()) name = profileState.name }
    val syncStatus by services.cloudSync.status.collectAsState()
    val syncOn by graph.settings.flow(SyncSettings.CLOUD_SYNC_ENABLED).collectAsState(initial = true)

    SettingsHeader("Profile")
    OutlinedTextField(
        value = name,
        onValueChange = {
            name = it
            host.scope.launch(Dispatchers.IO) {
                services.profile.setName(ShellSettings.normalizeProfileName(it))
            }
        },
        label = { Text("Your PocketDJ name") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    SettingsCaption(
        "Your PocketDJ name shows as the artist on your samples, loops, sequences, and " +
            "instrumentals (leave blank for \u201cStudio\u201d).",
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
    ) {
        Text("Sync across devices", modifier = Modifier.weight(1f))
        Switch(
            checked = syncOn,
            onCheckedChange = { v -> host.scope.launch { graph.settings.set(SyncSettings.CLOUD_SYNC_ENABLED, v) } },
        )
    }
    OutlinedButton(
        enabled = syncOn && !syncStatus.syncing,
        onClick = { host.scope.launch(Dispatchers.IO) { services.cloudSync.syncNow() } },
    ) { Text(if (syncStatus.syncing) "Syncing\u2026" else "Sync now") }
    SettingsCaption(
        syncStatus.lastError?.let { "Sync failed: $it" }
            ?: syncStatus.lastSummary
            ?: if (syncStatus.accountAvailable == false) "Sync isn\u2019t set up on this device yet."
            else "Your profile and play data follow you across your devices.",
    )
}
