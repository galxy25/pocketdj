package com.levi.pocketdj.screens.settings.sections

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.pockets.PocketsSettings
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.data.recs.RecommendationService
import com.levi.pocketdj.data.recs.RecsSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Pure copy for Settings > Recommendations (iOS `SettingsView.recommendationsSection`). */
object RecommendationsSettingsCopy {
    const val ID = "recommendations"
    const val ORDER = 660

    const val FOOTER =
        "When on, your listening history, favorites, collection updates, Gem Collector results, and — unless you " +
            "turn it off above — your lifetime play counts (including the counts imported from Apple Music) are sent " +
            "to PocketDJ to compute suggestions. When off, nothing leaves your device."

    const val DELETE_MESSAGE =
        "Removes the uploaded listening history, favorites, collection data, and listening pockets from " +
            "PocketDJ's servers. Your on-device history is untouched. If the engine stays on, fresh data is " +
            "uploaded again from now on."

    const val POCKETS_TITLE = "Find my listening pockets"

    /** iOS: the consent caption shows while pockets are off. */
    fun showConsent(pocketsOn: Boolean) = !pocketsOn

    /** iOS: a pockets sync error shows only while pockets are on. */
    fun pocketsError(err: String?, pocketsOn: Boolean): String? = if (pocketsOn) err else null

    /** What the pockets block renders; the composable consumes this so tests can pin the wiring. */
    data class PocketsRows(val toggle: Boolean, val consent: Boolean, val error: String?)

    /** [pocketsOn] null = DataStore has not emitted yet (no consent flash, no error). */
    fun pocketsRows(recOn: Boolean, pocketsOn: Boolean?, err: String?): PocketsRows =
        if (!recOn) PocketsRows(false, false, null)
        else PocketsRows(true, pocketsOn == false && showConsent(false), pocketsError(err, pocketsOn == true))

    /** Flipping the switch is an answer (Q91a): ANSWERED=true first, then ENABLED, so History never re-offers. */
    suspend fun applyPocketsToggle(on: Boolean, set: suspend (PrefKey<Boolean>, Boolean) -> Unit) {
        set(PocketsSettings.LISTENING_POCKETS_ANSWERED, true)
        set(PocketsSettings.LISTENING_POCKETS_ENABLED, on)
    }

    /** "Never" or a relative time like "5 minutes ago". */
    fun lastSentLabel(atMs: Long?, nowMs: Long = System.currentTimeMillis()): String =
        if (atMs == null) "Never"
        else DateUtils.getRelativeTimeSpanString(atMs, nowMs, DateUtils.MINUTE_IN_MILLIS).toString()
}

internal fun recommendationsSection() = SettingsSection(
    RecommendationsSettingsCopy.ID, RecommendationsSettingsCopy.ORDER,
) { host ->
    val graph = host.graph
    val enabled by graph.settings.flow(RecsSettings.REC_ENGINE_ENABLED).collectAsState(initial = false)
    val shareCounts by graph.settings.flow(RecsSettings.SHARE_LIFETIME_PLAY_COUNTS).collectAsState(initial = true)
    val service by produceState<RecommendationService?>(null) {
        value = withContext(Dispatchers.IO) { graph.browseGraph.recService }
    }
    var confirmDelete by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    // Serializes pockets writes so the last tap always wins (privacy-sensitive opt-in).
    val pocketsWriteLock = remember { kotlinx.coroutines.sync.Mutex() }

    SettingsHeader("Recommendations")
    SwitchRow("Use PocketDJ Recommendation Engine", enabled, "rec-engine-toggle") { on ->
        // The mirror + enabledDidChange ride the settings flow collector (BrowseGraph.startRecs).
        host.scope.launch { withContext(Dispatchers.IO) { graph.settings.set(RecsSettings.REC_ENGINE_ENABLED, on) } }
    }
    if (enabled) {
        SwitchRow("Include lifetime play counts", shareCounts, "rec-share-playcounts-toggle") { on ->
            host.scope.launch { withContext(Dispatchers.IO) { graph.settings.set(RecsSettings.SHARE_LIFETIME_PLAY_COUNTS, on) } }
        }
        val pocketsOn by graph.settings.flow(PocketsSettings.LISTENING_POCKETS_ENABLED).collectAsState<Boolean, Boolean?>(initial = null)
        SwitchRow(RecommendationsSettingsCopy.POCKETS_TITLE, pocketsOn == true, "pockets-toggle") { on ->
            // enabledDidChange rides the settings flow collector (CollectionsGraph pockets wiring).
            host.scope.launch {
                pocketsWriteLock.withLock {
                    withContext(Dispatchers.IO) {
                        RecommendationsSettingsCopy.applyPocketsToggle(on) { k, v -> graph.settings.set(k, v) }
                    }
                }
            }
        }
        if (RecommendationsSettingsCopy.pocketsRows(enabled, pocketsOn, null).consent) {
            Text(PocketsSettings.CONSENT_TEXT, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val pocketsSvc by produceState<com.levi.pocketdj.data.pockets.ListeningPocketsService?>(null) {
            value = withContext(Dispatchers.IO) { runCatching { graph.collectionsGraph.listeningPockets }.getOrNull() }
        }
        // syncError is a plain volatile field, so poll it while pockets are on.
        val pocketsErr by produceState<String?>(null, pocketsSvc, pocketsOn) {
            if (pocketsOn != true) { value = null; return@produceState }
            while (true) {
                value = RecommendationsSettingsCopy.pocketsRows(true, pocketsOn, pocketsSvc?.syncError).error
                kotlinx.coroutines.delay(1000)
            }
        }
        pocketsErr?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("pockets-sync-error"))
        }
        val last by (service?.lastSyncedAtMs ?: kotlinx.coroutines.flow.MutableStateFlow<Long?>(null)).collectAsState()
        val err by (service?.syncError ?: kotlinx.coroutines.flow.MutableStateFlow<String?>(null)).collectAsState()
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Last sent")
            Text(
                RecommendationsSettingsCopy.lastSentLabel(last),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("rec-last-sent"),
            )
        }
        err?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        TextButton(
            onClick = { service?.let { s -> busy = true; host.scope.launch { s.flushNowAsync().join(); busy = false } } },
            enabled = service != null && !busy,
            modifier = Modifier.testTag("rec-send-now"),
        ) { Text("Send now") }
        TextButton(
            onClick = { confirmDelete = true },
            enabled = service != null,
            modifier = Modifier.testTag("rec-delete-cloud"),
        ) { Text("Delete cloud data", color = MaterialTheme.colorScheme.error) }
    }
    SettingsCaption(RecommendationsSettingsCopy.FOOTER)

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete your recommendation data from PocketDJ's servers?") },
            text = { Text(RecommendationsSettingsCopy.DELETE_MESSAGE) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDelete = false
                        service?.deleteCloudDataAsync()
                    },
                    modifier = Modifier.testTag("rec-delete-cloud-confirm"),
                ) { Text("Delete cloud data", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@androidx.compose.runtime.Composable
private fun SwitchRow(title: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(title, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, modifier = Modifier.testTag(tag))
    }
}
