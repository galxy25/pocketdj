package com.levi.pocketdj.screens.settings


import androidx.compose.ui.platform.testTag

import androidx.compose.foundation.layout.fillMaxWidth

import androidx.compose.material3.Text

import androidx.compose.material3.MaterialTheme

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.SettingsHost
import kotlinx.coroutines.CoroutineScope

/**
 * Settings host: renders the section registry (decision D3) in order, separated by
 * dividers. The blocks themselves live in the `sections` package; other areas contribute
 * sections from their sidecar graph and this file is never edited for them.
 */
@Composable
fun SettingsScreen(
    modifier: Modifier = Modifier,
    onOpenStorage: () -> Unit = {},
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val settings by graph.settings.settings.collectAsState(initial = null)

    // Plain State (no `by` delegate): a delegated local captured by the anonymous SettingsHost
    // below sent the Compose compiler's deep copy into a non-terminating loop.
    val advancedState = androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    val advanced = advancedState.value
    val host = remember(graph, scope, snackbar, onOpenStorage, settings, advanced) {
        object : SettingsHost {
            override val graph: AppGraph = graph
            override val settings: AppSettings? = settings
            override val snackbar: SnackbarHostState = snackbar
            override val scope: CoroutineScope = scope
            override fun openStorage() = onOpenStorage()
            override val showAdvanced: Boolean = advanced
        }
    }
    val sections = remember(graph) { SettingsSections.ordered(graph.features.settingsSections) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            // iOS-style grouped Settings: the registry is bucketed by order range into titled
            // cards; the Advanced group (debug, reset) stays folded until asked for.
            for ((group, members) in SettingsGroups.group(sections)) {
                SettingsGroupBlock(group, members, host, advanced) { advancedState.value = it }
            }
            Spacer(Modifier.height(24.dp))
        }
        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }
}

/** One titled group card; the Advanced group carries the "Show advanced" switch and folds. */
@Composable
private fun SettingsGroupBlock(
    group: SettingsGroup,
    members: List<com.levi.pocketdj.shell.SettingsSection>,
    host: SettingsHost,
    advanced: Boolean,
    onAdvanced: (Boolean) -> Unit,
) {
    val isAdvanced = group == SettingsGroup.ADVANCED
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 6.dp, start = 4.dp)
            .testTag("settings-group-${group.name.lowercase()}"),
    ) {
        Text(group.title.uppercase(), style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        if (isAdvanced) {
            Text("Show advanced", style = MaterialTheme.typography.bodyMedium)
            androidx.compose.material3.Switch(checked = advanced, onCheckedChange = onAdvanced,
                modifier = Modifier.padding(start = 8.dp).testTag("settings-advanced-toggle"))
        }
    }
    if (isAdvanced && !advanced) return
    androidx.compose.material3.Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            for (index in members.indices) {
                val section = members[index]
                if (index > 0) SettingsDivider()
                key(section.id) { section.content(this, host) }
            }
        }
    }
}

/** Settings groups (iOS Form sections), keyed by the registry's order ranges. */
enum class SettingsGroup(val title: String) {
    ACCOUNT("Account"),
    LIBRARY("Library & sources"),
    APPLE_MUSIC("Apple Music & sync"),
    PLAYBACK("Playback, Mix & Jukebox"),
    LISTENING("History & recommendations"),
    STORAGE("Storage"),
    ABOUT("About"),
    ADVANCED("Advanced"),
}

object SettingsGroups {
    /** Order range -> group. Sections keep their registry order inside a group. */
    fun of(order: Int): SettingsGroup = when {
        order < 100 -> SettingsGroup.ACCOUNT
        order < 400 -> SettingsGroup.LIBRARY
        order < 500 -> SettingsGroup.APPLE_MUSIC
        order < 600 -> SettingsGroup.PLAYBACK
        order < 700 -> SettingsGroup.LISTENING
        order < 800 -> SettingsGroup.STORAGE
        order < 900 -> SettingsGroup.ABOUT
        else -> SettingsGroup.ADVANCED
    }

    fun group(sections: List<com.levi.pocketdj.shell.SettingsSection>): List<Pair<SettingsGroup, List<com.levi.pocketdj.shell.SettingsSection>>> =
        sections.groupBy { of(it.order) }.toList().sortedBy { it.first.ordinal }
}
