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
    // Local edits go through ONE serialized lane (parallelism 1, FIFO) so a stale prefix can never be
    // persisted after a newer one. While any local write is in flight the field is the source of truth;
    // only a change that did NOT come from us (a cloud pull) is adopted back into the field.
    val writeLane = remember { Dispatchers.IO.limitedParallelism(1) }
    val inFlight = remember { java.util.concurrent.atomic.AtomicInteger(0) }
    val profileState by services.profile.state.collectAsState()
    LaunchedEffect(profileState.name) {
        val live = services.profile.state.value.name
        if (inFlight.get() == 0 && live.isNotEmpty() && live != name) name = live
    }
    val syncStatus by services.cloudSync.status.collectAsState()
    val syncOn by graph.settings.flow(SyncSettings.CLOUD_SYNC_ENABLED).collectAsState(initial = true)

    SettingsHeader("Profile")
    OutlinedTextField(
        value = name,
        onValueChange = {
            name = it
            inFlight.incrementAndGet()
            host.scope.launch(writeLane) {
                try {
                    services.profile.setName(ShellSettings.normalizeProfileName(it))
                } finally {
                    inFlight.decrementAndGet()
                }
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
        // No sync account on this device: the switch cannot be ON (it read ON next to
        // "Account unavailable"). The stored preference is kept for when an account appears.
        Switch(
            checked = SyncUi.switchOn(syncOn, syncStatus.accountAvailable),
            enabled = SyncUi.switchEnabled(syncStatus.accountAvailable),
            onCheckedChange = { v -> host.scope.launch { graph.settings.set(SyncSettings.CLOUD_SYNC_ENABLED, v) } },
        )
    }
    if (SyncUi.switchEnabled(syncStatus.accountAvailable)) OutlinedButton(
        enabled = syncOn && !syncStatus.syncing,
        onClick = { host.scope.launch(Dispatchers.IO) { services.cloudSync.syncNow() } },
    ) { Text(if (syncStatus.syncing) "Syncing\u2026" else "Sync now") }
    if (services.isDebuggable()) {
        var inMemory by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { inMemory = graph.settings.get(SyncSettings.DEBUG_IN_MEMORY_DB) }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        ) {
            Text("Debug: in-memory sync backend", modifier = Modifier.weight(1f))
            Switch(
                checked = inMemory,
                onCheckedChange = { v ->
                    inMemory = v
                    host.scope.launch {
                        graph.settings.set(SyncSettings.DEBUG_IN_MEMORY_DB, v)
                        services.setDebugInMemoryDb(v)
                    }
                },
            )
        }
    }
    SettingsCaption(SyncUi.caption(syncStatus.accountAvailable, syncStatus.lastError, syncStatus.lastSummary))
}

/** Pure copy/state rules for the sync row (JVM-tested). */
internal object SyncUi {
    fun switchEnabled(accountAvailable: Boolean?): Boolean = accountAvailable != false
    fun switchOn(pref: Boolean, accountAvailable: Boolean?): Boolean = pref && accountAvailable != false
    const val NO_ACCOUNT = "Sync isn\u2019t set up on this device yet, so your profile and play data stay on this device."
    fun caption(accountAvailable: Boolean?, lastError: String?, lastSummary: String?): String = when {
        accountAvailable == false -> NO_ACCOUNT
        lastError != null -> "Sync failed: $lastError"
        lastSummary != null -> lastSummary
        else -> "Your profile and play data follow you across your devices."
    }
}
