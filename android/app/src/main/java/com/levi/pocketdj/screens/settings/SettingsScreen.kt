package com.levi.pocketdj.screens.settings

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
 * dividers. The blocks themselves live in `sections/*.kt`; other areas contribute
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

    val host = remember(graph, scope, snackbar, onOpenStorage, settings) {
        object : SettingsHost {
            override val graph: AppGraph = graph
            override val settings: AppSettings? = settings
            override val snackbar: SnackbarHostState = snackbar
            override val scope: CoroutineScope = scope
            override fun openStorage() = onOpenStorage()
        }
    }
    val sections = remember(graph) { SettingsSections.ordered(graph.features.settingsSections) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            sections.forEachIndexed { index, section ->
                if (index > 0) SectionDivider()
                key(section.id) { section.content(this, host) }
            }
            Spacer(Modifier.height(24.dp))
        }
        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }
}
