package com.levi.pocketdj.screens.history

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.pockets.ListeningPocket
import com.levi.pocketdj.data.pockets.ListeningPocketPattern
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.games.PocketsOptInView
import kotlinx.coroutines.launch

/** What the Pockets tab shows (pure; iOS `ListeningPocketsView.body`/`content`). */
internal sealed interface PocketsTabMode {
    /** Engine on, pockets never answered: the disclosure + Not now / Turn on. */
    data object OptIn : PocketsTabMode
    data class Empty(val detail: String?) : PocketsTabMode
    data class Content(val patterns: List<ListeningPocketPattern>, val recent: List<ListeningPocket>, val stale: Boolean) : PocketsTabMode
}

internal object PocketsTabGate {
    const val UNAVAILABLE = "Pockets aren't available yet."
    const val EMPTY = "No pockets yet. Play three or more songs in a row without skipping."

    /**
     * The tab shows while the pockets gate is open (rec engine AND pockets ON) OR, once, as the opt-in
     * offer: engine on and the question never answered. "Not now" answers it and the tab goes away.
     */
    fun tabVisible(recEngine: Boolean, pocketsOn: Boolean, answered: Boolean): Boolean =
        (recEngine && pocketsOn) || (recEngine && !answered)

    fun gateOpen(recEngine: Boolean, pocketsOn: Boolean): Boolean = recEngine && pocketsOn

    /** Recent = individual pockets, newest first. */
    fun recent(results: ListeningPocketsResults?): List<ListeningPocket> =
        (results?.pockets ?: emptyList()).sortedByDescending { it.startMs }

    fun mode(gateOpen: Boolean, results: ListeningPocketsResults?, serviceAvailable: Boolean): PocketsTabMode {
        if (!gateOpen) return PocketsTabMode.OptIn
        val patterns = results?.patterns ?: emptyList()
        val recent = recent(results)
        if (patterns.isEmpty() && recent.isEmpty()) {
            return PocketsTabMode.Empty(if (serviceAvailable) null else UNAVAILABLE)
        }
        return PocketsTabMode.Content(patterns, recent, results?.stale == true)
    }

    /** Detail subject keys survive rotation/navigation as plain strings. */
    fun patternKey(id: String) = "pattern:$id"
    fun pocketKey(id: String) = "pocket:$id"
}

/** Builds the labeler for [results] from the live collections (names stay local). */
internal fun pocketLabelerFor(graph: AppGraph, results: ListeningPocketsResults?): ListeningPocketLabeler {
    val catalog = graph.catalogRepository.state.value.catalog
    val names = ListeningPocketLabeler.collectionNames(
        results,
        pockets = graph.collections.pockets.map { it.id to it.name },
        playlists = graph.collections.playlists.map { it.id to it.name },
        sources = catalog?.playlists.orEmpty().map { it.playlist.id to it.playlist.name },
    )
    return ListeningPocketLabeler(results, com.levi.pocketdj.data.location.NoopListeningContextProvider, names)
}

/** History ▸ Pockets. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ListeningPocketsScreen(onOpen: (key: String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val service = graph.collectionsGraph.listeningPockets
    val recOn by graph.browseGraph.recEnabled.collectAsState()
    val pocketsOn by graph.settings.flow(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED)
        .collectAsState(initial = false)
    val results by service.results.collectAsState()
    val refreshing by service.isRefreshing.collectAsState()
    val scope = rememberCoroutineScope()
    val gateOpen = PocketsTabGate.gateOpen(recOn, pocketsOn)

    LaunchedEffect(gateOpen) { if (gateOpen) service.refreshIfStale() }

    val mode = PocketsTabGate.mode(gateOpen, results, service.serviceAvailable)
    when (mode) {
        PocketsTabMode.OptIn -> PocketsOptInView(
            graph.gamesGraph.pocketsOptIn,
            modifier.testTag("pockets-optin-host"),
            title = "Find your listening pockets?",
            lead = "A pocket is a stretch where you played three or more songs in a row without skipping. " +
                "PocketDJ can find yours and show what they have in common.",
        )
        is PocketsTabMode -> PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { service.refreshNow() } },
            modifier = modifier.fillMaxSize(),
        ) {
            when (mode) {
                is PocketsTabMode.Empty -> Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp).testTag("pockets-empty"),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(Icons.Filled.Layers, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(PocketsTabGate.EMPTY, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    mode.detail?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                is PocketsTabMode.Content -> PocketsList(mode, pocketLabelerFor(graph, results), onOpen)
                PocketsTabMode.OptIn -> Unit
            }
        }
    }
}

@Composable
private fun PocketsList(mode: PocketsTabMode.Content, labeler: ListeningPocketLabeler, onOpen: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize().testTag("pockets-list")) {
        item(key = "hdr") {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Text("Your pockets", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                if (mode.stale) {
                    Text("Updating with your latest listening…", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("pockets-stale"))
                }
            }
        }
        if (mode.patterns.isNotEmpty()) {
            item(key = "h-rec") { SectionHeader("Recurring") }
            items(mode.patterns, key = { "p-" + it.id }) { p ->
                PatternCard(p, labeler, Modifier.clickable { onOpen(PocketsTabGate.patternKey(p.id)) }.testTag("pattern-row-${p.id}"))
                HorizontalDivider()
            }
        }
        if (mode.recent.isNotEmpty()) {
            item(key = "h-recent") { SectionHeader("Recent") }
            items(mode.recent, key = { "r-" + it.id }) { p ->
                PocketRow(p, labeler, Modifier.clickable { onOpen(PocketsTabGate.pocketKey(p.id)) }.testTag("pocket-row-${p.id}"))
                HorizontalDivider()
            }
        }
    }
}

@Composable
internal fun SectionHeader(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Chips(chips: List<String>) {
    if (chips.isEmpty()) return
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        chips.forEach { c ->
            Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)) {
                Text(c, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp))
            }
        }
    }
}

@Composable
private fun PatternCard(p: ListeningPocketPattern, labeler: ListeningPocketLabeler, modifier: Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(p.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Chips(labeler.chips(p.features, p.numeric))
        val parts = mutableListOf("${p.occurrences} ${if (p.occurrences == 1) "time" else "times"}")
        ListeningPocketLabeler.lastText(p.lastMs)?.let { parts += it }
        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun PocketRow(p: ListeningPocket, labeler: ListeningPocketLabeler, modifier: Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(p.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(ListeningPocketLabeler.whenText(p.startMs, p.tzOffsetMin), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        var counts = "${p.memberCount} ${if (p.memberCount == 1) "song" else "songs"}"
        if (p.skippedCount > 0) counts += " · ${p.skippedCount} skipped"
        Text(counts, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Chips(labeler.chips(p.features, p.numeric))
    }
}
