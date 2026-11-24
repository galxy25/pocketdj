package com.levi.pocketdj.screens.history

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Icon
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketRunStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.history.wheel.PocketMomentCard
import com.levi.pocketdj.screens.history.wheel.PocketWheelHost
import com.levi.pocketdj.screens.history.wheel.rememberPocketWheelActions
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The Wheel | List segment of History > Pockets (iOS `PocketsTabView.Segment`). Pure; tested on the JVM. */
internal enum class PocketsSegment(val label: String) {
    WHEEL("Wheel"), LIST("List");

    companion object {
        const val PREF_KEY = "pdj.history.pockets.segment"
        /** Wheel is the default for a missing or unknown stored value. */
        fun parse(raw: String?): PocketsSegment = entries.firstOrNull { it.label == raw } ?: WHEEL
        /** The List segment is hidden once the user declined cloud pockets (answered AND off): it would only re-offer the opt-in. */
        fun showsList(pocketsOn: Boolean, answered: Boolean): Boolean = !(answered && !pocketsOn)
        /** What is shown: a hidden List always collapses to the wheel. */
        fun effective(stored: PocketsSegment, showsList: Boolean): PocketsSegment = if (showsList) stored else WHEEL
    }
}

/** Phones show the moment card as a bottom sheet; at >= 600 dp it is a side pane inside the wheel screen. */
internal const val CARD_SIDE_PANE_DP = 600

/** The "Pocket finished" summary (a finished run the user has not dismissed). */
internal object PocketFinishedText {
    fun headline(a: PocketRunStore.RunState): String {
        val n = a.playedThrough + a.skips
        val rate = if (n > 0) Math.round(a.skips * 100.0 / n) else 0L
        return "Pocket finished · ${a.playedThrough} played · $rate % skipped"
    }
}

/** History > Pockets: Wheel (default; needs only local history) | List (the cloud listening-pockets view). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PocketsTabScreen(onOpen: (key: String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val pocketsOn by graph.settings.flow(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ENABLED).collectAsState(initial = null)
    val answered by graph.settings.flow(com.levi.pocketdj.data.pockets.PocketsSettings.LISTENING_POCKETS_ANSWERED).collectAsState(initial = null)
    val prefs = remember { runCatching { context.getSharedPreferences("pdj", android.content.Context.MODE_PRIVATE) }.getOrNull() }
    var stored by rememberSaveable {
        mutableStateOf(PocketsSegment.parse(runCatching { prefs?.getString(PocketsSegment.PREF_KEY, null) }.getOrNull()))
    }
    if (pocketsOn == null || answered == null) return
    val showsList = PocketsSegment.showsList(pocketsOn == true, answered == true)
    val segment = PocketsSegment.effective(stored, showsList)

    Column(modifier.fillMaxSize()) {
        if (showsList) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("pockets-segment")) {
                PocketsSegment.entries.forEachIndexed { i, s ->
                    SegmentedButton(
                        selected = segment == s,
                        onClick = {
                            stored = s
                            runCatching { prefs?.edit()?.putString(PocketsSegment.PREF_KEY, s.label)?.apply() }
                        },
                        shape = SegmentedButtonDefaults.itemShape(i, PocketsSegment.entries.size),
                        modifier = Modifier.testTag("pockets-segment-${s.label.lowercase()}"),
                    ) { Text(s.label) }
                }
            }
        }
        when (segment) {
            PocketsSegment.LIST -> ListeningPocketsScreen(onOpen = onOpen, modifier = Modifier.fillMaxSize().testTag("history-pockets-list"))
            PocketsSegment.WHEEL -> WheelSegment(graph)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WheelSegment(graph: AppGraph) {
    val pg = graph.pocketsGraph
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedKey = selected?.let(PocketMomentKey::fromToken)
    val snapshot by pg.wheelCache.snapshot.collectAsState()
    val actions = rememberPocketWheelActions(pg, onPause = null)
    val active by pg.runStore.active.collectAsState()
    val scope = rememberCoroutineScope()
    val labelOf: (com.levi.pocketdj.data.pockets.ListeningContextTag) -> String? = remember(graph) {
        { tag -> runCatching { graph.collectionsGraph.listeningContextProvider.label(tag) }.getOrNull() }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val sidePane = maxWidth >= CARD_SIDE_PANE_DP.dp
        val moment = selectedKey?.let { k -> snapshot.moments.firstOrNull { it.key == k } }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            active?.takeIf { it.finished }?.let { run ->
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("pocket-finished-card"),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(PocketFinishedText.headline(run), fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleSmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                pg.runStore.dismissFinished()
                                scope.launch { runCatching { withContext(NonCancellable) { pg.wheelController.playBest() } } }
                            },
                            modifier = Modifier.testTag("pocket-finished-another"),
                        ) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null)
                            Text("another pocket")
                        }
                        TextButton(onClick = { pg.runStore.dismissFinished() }, modifier = Modifier.testTag("pocket-finished-dismiss")) { Text("Dismiss") }
                    }
                }
            }
            PocketWheelHost(
                graph = pg,
                selected = selectedKey,
                onSelect = { selected = it?.token },
                card = if (sidePane) { key ->
                    snapshot.moments.firstOrNull { it.key == key }?.let { m ->
                        PocketMomentCard(m, snapshot, pg.wheelCache.palette, actions, labelOf, onClose = { selected = null })
                    }
                } else { _ -> },
            )
        }
        if (!sidePane && moment != null) {
            ModalBottomSheet(onDismissRequest = { selected = null }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
                Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)) {
                    PocketMomentCard(moment, snapshot, pg.wheelCache.palette, actions, labelOf, onClose = { selected = null })
                }
            }
        }
    }
}
