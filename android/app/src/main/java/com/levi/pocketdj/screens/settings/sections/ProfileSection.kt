package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.sync.ProfileSyncProblem
import com.levi.pocketdj.onboarding.LinkProbeResult
import com.levi.pocketdj.shell.SettingsHost
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
    val syncOn by graph.settings.flow(SyncSettings.CLOUD_SYNC_ENABLED).collectAsState(initial = SyncSettings.CLOUD_SYNC_ENABLED.default)

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
            "instrumentals (leave blank for \u201cPocket DJ\u201d).",
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
    val unauthorized by services.s3Database.unauthorized.collectAsState()
    val problem = remember(unauthorized, profileState.id) { services.profileSyncProblem(unauthorized) }
    // Hoisted: a successful relink clears the flag (the block disappears) but its outcome + Restore must stay.
    var relinked by remember { mutableStateOf<LinkProbeResult?>(null) }
    if (problem == ProfileSyncProblem.DELETED) ProfileDeletedBlock(host) { relinked = it }
    relinked?.let { r ->
        var restoring by remember { mutableStateOf(false) }
        var note by remember(r) { mutableStateOf(SyncUi.relinkMessage(r)) }
        Text(note, style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("profile-relink-message"))
        if (r is LinkProbeResult.Existing) OutlinedButton(
            enabled = !restoring,
            onClick = {
                restoring = true
                host.scope.launch {
                    val ok = withContext(Dispatchers.IO) { services.linkProbe.restore() }
                    restoring = false
                    if (ok) relinked = null else note = "Couldn’t restore right now. Try Sync now."
                    if (ok) host.snackbar.showSnackbar("Restored.")
                }
            },
            modifier = Modifier.testTag("profile-relink-restore"),
        ) { Text("Restore my stuff") }
    }
    SettingsCaption(SyncUi.caption(syncStatus.accountAvailable, syncStatus.lastError, syncStatus.lastSummary, problem))
}

/**
 * Q120: the dedicated "This profile was deleted on another device" state (a 401 on this device's identity after
 * the other device ran Delete account). Nothing syncs meanwhile. Start fresh = a new profile on this device
 * (local data kept); Relink = enter a code from a device that still has a profile.
 */
@Composable
private fun ColumnScope.ProfileDeletedBlock(host: SettingsHost, onLinked: (LinkProbeResult) -> Unit) {
    val services = host.graph.servicesGraph
    var relinking by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    Text(
        SyncUi.PROFILE_DELETED_TITLE,
        color = MaterialTheme.colorScheme.error,
        modifier = Modifier.padding(top = 8.dp).testTag("profile-deleted"),
    )
    SettingsCaption(SyncUi.PROFILE_DELETED_DETAIL)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(
            enabled = !busy,
            onClick = {
                busy = true
                host.scope.launch {
                    withContext(Dispatchers.IO) { services.profileRecovery.startFresh() }
                    busy = false
                    host.snackbar.showSnackbar(SyncUi.STARTED_FRESH)
                }
            },
            modifier = Modifier.testTag("profile-start-fresh"),
        ) { Text("Start fresh") }
        OutlinedButton(
            enabled = !busy,
            onClick = { relinking = !relinking; message = null },
            modifier = Modifier.testTag("profile-relink"),
        ) { Text("Relink") }
    }
    if (relinking) {
        OutlinedTextField(
            value = code,
            onValueChange = { code = it; message = null },
            label = { Text("Code from your other device") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("profile-relink-code"),
        )
        Button(
            enabled = !busy && code.isNotBlank(),
            onClick = {
                busy = true
                host.scope.launch {
                    // The same link flow as Settings > Link a device (adopts the other device's identity).
                    val r = withContext(Dispatchers.IO) { services.linkProbe.link(code) }
                    busy = false
                    if (r is LinkProbeResult.Unavailable) message = r.reason else onLinked(r)
                }
            },
            modifier = Modifier.testTag("profile-relink-submit"),
        ) { Text("Link") }
    }
    message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
}

/** Pure copy/state rules for the sync row (JVM-tested). */
internal object SyncUi {
    fun switchEnabled(accountAvailable: Boolean?): Boolean = accountAvailable != false
    fun switchOn(pref: Boolean, accountAvailable: Boolean?): Boolean = pref && accountAvailable != false
    const val NO_ACCOUNT = "Sync isn\u2019t set up on this device yet, so your profile and play data stay on this device."
    const val PROFILE_DELETED_TITLE = "This profile was deleted on another device"
    const val PROFILE_DELETED_DETAIL =
        "Nothing syncs from this device until you choose. Start fresh keeps everything on this device under a new " +
            "profile; Relink joins a profile you still have on another device (enter its code)."
    const val PROFILE_DELETED_CAPTION = "Sync is paused: this profile no longer exists. Your data stays on this device."
    const val STARTED_FRESH = "Started a fresh profile on this device"

    fun caption(
        accountAvailable: Boolean?,
        lastError: String?,
        lastSummary: String?,
        problem: ProfileSyncProblem? = null,
    ): String = when {
        problem == ProfileSyncProblem.DELETED -> PROFILE_DELETED_CAPTION
        accountAvailable == false -> NO_ACCOUNT
        lastError != null -> "Sync failed: $lastError"
        lastSummary != null -> lastSummary
        else -> "Your profile and play data follow you across your devices."
    }

    /** Relink outcome copy (the same link flow as Settings > Link a device). */
    fun relinkMessage(r: LinkProbeResult): String = when (r) {
        is LinkProbeResult.Existing ->
            "Linked" + (r.name.takeIf { it.isNotEmpty() }?.let { " to $it" } ?: "") + ". Restore your stuff to this device?"
        LinkProbeResult.Fresh -> "Linked. Nothing to restore yet; this device will sync from now on."
        is LinkProbeResult.Unavailable -> r.reason
    }
}
