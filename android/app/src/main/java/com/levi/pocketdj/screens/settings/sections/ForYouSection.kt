package com.levi.pocketdj.screens.settings.sections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
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
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.RecsOffCollection
import com.levi.pocketdj.data.collections.recommendationsEnabled
import com.levi.pocketdj.data.collections.recommendationsOffCollections
import com.levi.pocketdj.data.collections.setRecommendationsEnabled
import com.levi.pocketdj.data.recs.ForYouRefreshCadence
import com.levi.pocketdj.data.recs.ForYouRefreshSchedule
import com.levi.pocketdj.data.recs.ForYouScheduleSettings
import com.levi.pocketdj.data.recs.ForYouSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.screens.settings.SettingsHeader
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Pure copy + formatting for Settings ▸ For You (iOS `SettingsView.forYouSection`). */
object ForYouSettingsCopy {
    const val ID = "forYou"
    const val ORDER = 650

    fun cadenceFooter(c: ForYouRefreshCadence): String = when (c) {
        ForYouRefreshCadence.MANUAL -> "Right now it only refreshes when you ask it to."
        ForYouRefreshCadence.HOURLY -> "Right now it refreshes every hour, at the minute you choose below."
        ForYouRefreshCadence.DAILY -> "Right now it refreshes once a day."
        ForYouRefreshCadence.WEEKLY -> "Right now it refreshes once a week."
        ForYouRefreshCadence.MONTHLY -> "Right now it refreshes on the 1st of each month."
    }

    /** The sentence that only makes sense when switched-off rows are listed above it. */
    fun recsOffFooter(n: Int): String {
        if (n <= 0) return ""
        return "\n\nRecommendations are off for $n collection${if (n == 1) "" else "s"} — " +
            "${if (n == 1) "it gets" else "they get"} no tile in For You and nothing is ranked for " +
            "${if (n == 1) "it" else "them"}. Switch one back on here, or from that collection’s ⋯ menu."
    }

    fun footer(c: ForYouRefreshCadence, recsOffCount: Int): String =
        "History ▸ For You shows the last ranking it computed and holds it steady until it refreshes — " +
            "so a suggestion you were half-deciding on doesn’t move while you look at it. ${cadenceFooter(c)}\n\n" +
            "The schedule is checked when you open the tab or come back to the app, so a refresh you were away " +
            "for happens on your next visit rather than being skipped. “Refresh” in the tab’s menu " +
            "always recomputes immediately, whatever this is set to." + recsOffFooter(recsOffCount)

    fun timeLabel(c: ForYouRefreshCadence) = if (c == ForYouRefreshCadence.HOURLY) "At minute" else "At"

    fun minutesLabel(minutesOfDay: Int, cadence: ForYouRefreshCadence): String {
        val m = ForYouRefreshSchedule.clampMinutes(minutesOfDay)
        return if (cadence == ForYouRefreshCadence.HOURLY) ":%02d".format(m % 60) else "%02d:%02d".format(m / 60, m % 60)
    }

    /** "Next refresh" value; an em dash for MANUAL. */
    fun nextRefreshLabel(s: ForYouScheduleSettings, now: java.time.ZonedDateTime = java.time.ZonedDateTime.now()): String {
        val next = ForYouRefreshSchedule.nextFire(now, s.cadence, s.minutesOfDay, s.weekday) ?: return "—"
        return DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).format(next)
    }
}

internal fun forYouSection() = SettingsSection(ForYouSettingsCopy.ID, ForYouSettingsCopy.ORDER) { host ->
    val graph = host.graph
    val s by remember {
        combine(
            graph.settings.flow(ForYouSettings.CADENCE),
            graph.settings.flow(ForYouSettings.MINUTES),
            graph.settings.flow(ForYouSettings.WEEKDAY),
        ) { c, m, w -> ForYouSettings.normalize(c, m, w) }
    }.collectAsState(initial = ForYouScheduleSettings())
    val collections by produceState<CollectionsStore?>(null) { value = withContext(Dispatchers.IO) { graph.collections } }

    fun save(next: ForYouScheduleSettings) {
        host.scope.launch { withContext(Dispatchers.IO) { ForYouSettings.save(graph.settings, next) } }
    }

    SettingsHeader("For You")
    var cadenceMenu by remember { mutableStateOf(false) }
    Box {
        ValueRow("Refresh", s.cadence.label, "foryou-cadence") { cadenceMenu = true }
        DropdownMenu(expanded = cadenceMenu, onDismissRequest = { cadenceMenu = false }) {
            for (c in ForYouRefreshCadence.entries) {
                DropdownMenuItem(text = { Text(c.label) }, onClick = { cadenceMenu = false; save(s.copy(cadence = c)) })
            }
        }
    }
    if (s.cadence == ForYouRefreshCadence.WEEKLY) {
        var dayMenu by remember { mutableStateOf(false) }
        Box {
            ValueRow("On", ForYouRefreshSchedule.weekdayName(s.weekday), "foryou-weekday") { dayMenu = true }
            DropdownMenu(expanded = dayMenu, onDismissRequest = { dayMenu = false }) {
                for (day in ForYouRefreshSchedule.WEEKDAY_RANGE) {
                    DropdownMenuItem(
                        text = { Text(ForYouRefreshSchedule.weekdayName(day)) },
                        onClick = { dayMenu = false; save(s.copy(weekday = day)) },
                    )
                }
            }
        }
    }
    if (s.cadence != ForYouRefreshCadence.MANUAL) {
        var picking by remember { mutableStateOf(false) }
        ValueRow(ForYouSettingsCopy.timeLabel(s.cadence), ForYouSettingsCopy.minutesLabel(s.minutesOfDay, s.cadence), "foryou-time") { picking = true }
        ValueRow("Next refresh", ForYouSettingsCopy.nextRefreshLabel(s), "foryou-next-refresh", onClick = null)
        if (picking) TimeDialog(s.minutesOfDay, onDismiss = { picking = false }) { save(s.copy(minutesOfDay = it)); picking = false }
    }

    // THE WAY BACK: every switched-off collection, with the switch that re-enables it. Nothing
    // renders when nothing is off (the default).
    val rev = collections?.state?.collectAsState()?.value
    val off: List<RecsOffCollection> = remember(rev, collections) { collections?.recommendationsOffCollections().orEmpty() }
    for (item in off) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            Text(item.name, modifier = Modifier.weight(1f))
            // Bound to the REAL flag: off by construction, so the only reachable transition is on.
            Switch(
                checked = collections?.recommendationsEnabled(item.id) ?: false,
                onCheckedChange = { collections?.setRecommendationsEnabled(it, item.id) },
                modifier = Modifier.testTag("foryou-recs-off-${item.id}"),
            )
        }
    }
    SettingsCaption(ForYouSettingsCopy.footer(s.cadence, off.size))
}

@Composable
private fun ValueRow(label: String, value: String, tag: String, onClick: (() -> Unit)?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 10.dp).testTag(tag),
    ) {
        Text(label, modifier = Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeDialog(minutesOfDay: Int, onDismiss: () -> Unit, onPick: (Int) -> Unit) {
    val state = rememberTimePickerState(minutesOfDay / 60, minutesOfDay % 60, is24Hour = true)
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { TimePicker(state = state) },
        confirmButton = { TextButton(onClick = { onPick(state.hour * 60 + state.minute) }) { Text("OK") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
