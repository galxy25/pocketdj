package com.levi.pocketdj.screens.producer.sequencer

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AllInclusive
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.studio.StudioSettings
import com.levi.pocketdj.studio.engine.PatternMath
import com.levi.pocketdj.studio.model.StudioPattern
import kotlinx.coroutines.launch

/**
 * One pattern's editor (iOS SequencerEditor): back / name / rename / refresh / infinity / play / overflow (Bounce), BPM
 * and Length steppers, the Live-edits toggle + the "when do edits apply" banner, lane collapse + bars-per-line zoom,
 * the row cards (lazy), add-row, and the bounce status line. Reads the pattern FROM THE STORE every render - the
 * store document is the single truth, every mutation goes through StudioStore so `bounceDirty` can't be bypassed.
 */
@Composable
fun PatternEditor(graph: AppGraph, patternId: String, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val sg = graph.studioGraph
    val store = sg.studioStore
    val doc by store.state.collectAsState()
    val pattern = doc.patterns.firstOrNull { it.id == patternId }
    // App-scoped (Main) so an in-flight prepare survives activity recreation (rotation/fold/resize); cancelled on real exit.
    val scope = remember(graph) { kotlinx.coroutines.CoroutineScope(graph.appScope.coroutineContext + kotlinx.coroutines.Dispatchers.Main.immediate) }
    val controller = remember(graph) { SequencerController(graph, scope) }
    val activity = androidx.compose.ui.platform.LocalContext.current as? android.app.Activity
    val engine = sg.patternEngine
    val loadedId by engine.loadedPatternId.collectAsState()
    val playing by engine.isPlaying.collectAsState()
    val soloed by engine.soloedRow.collectAsState()
    val isPlayingThis = playing && loadedId == patternId && soloed == null

    // Live-vs-static playback (session-wide, no schema); compact = the 16-step line is too narrow to hit reliably.
    var live by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { live = runCatching { graph.settings.get(StudioSettings.SEQUENCER_LIVE) }.getOrDefault(false) }
    val compact = LocalConfiguration.current.screenWidthDp < 600

    var collapsedRows by rememberSaveable { mutableStateOf(setOf<Int>()) }
    var barsPerLine by rememberSaveable { mutableIntStateOf(1) }
    // SEQ5 playhead + looper: transient performance controls (per editor session).
    var startStep by rememberSaveable { mutableIntStateOf(0) }
    var loopEnabled by rememberSaveable { mutableStateOf(false) }
    var loopBars by rememberSaveable { mutableIntStateOf(2) }
    var renaming by remember { mutableStateOf(false) }
    var renamingRow by remember { mutableStateOf<Int?>(null) }

    // Frame sampler: the clock is NOT observable state; the grid reads this tick in its DRAW phase only.
    val tick = remember { mutableLongStateOf(0L) }
    LaunchedEffect(playing) {
        if (!playing) return@LaunchedEffect
        while (true) { androidx.compose.runtime.withFrameNanos { tick.longValue = it }; kotlinx.coroutines.delay(16) }
    }

    // Leaving the editor stops the pattern, gated on OWNERSHIP (the engine is app-scoped and plays one pattern globally).
    DisposableEffect(patternId) {
        onDispose {
            val changing = activity?.isChangingConfigurations == true
            if (SequencerLifecycle.shouldCancelPrepareOnDispose(changing)) controller.cancelPrepare()
            if (SequencerLifecycle.shouldStopOnDispose(changing, engine.loadedPatternId.value == patternId, engine.isPlaying.value)) engine.stopPattern()
        }
    }

    if (pattern == null) {
        Column(modifier.fillMaxSize().padding(24.dp)) {
            TextButton(onClick = onBack) { Text("Back to patterns") }
            Text("This pattern was deleted.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    fun togglePlay() {
        if (isPlayingThis) {
            // Park the cursor at the last PLAYED pad (resume-from-here feel), but NOT while the looper is on.
            engine.clock.cursorToParkOnStop()?.let { startStep = it }
            engine.stopPattern()
        } else controller.startPlayback(pattern, startStep, loopEnabled, loopBars)
    }

    Box(modifier.fillMaxSize()) {
        LazyColumn(
            Modifier.widthIn(max = 900.dp).fillMaxSize().align(Alignment.TopCenter).testTag("pattern-editor"),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { HeaderBar(pattern, onBack, controller, isPlayingThis, loopEnabled, loopBars,
                onRename = { renaming = true }, onPlay = ::togglePlay,
                onRefresh = { startStep = 0; if (isPlayingThis) engine.setPatternStartStep(0) },
                onLoopToggle = { loopEnabled = !loopEnabled; if (isPlayingThis) engine.setPatternLoop(loopEnabled, loopBars) },
                onLoopBars = { loopBars = it; if (isPlayingThis) engine.setPatternLoop(loopEnabled, it) },
            ) }
            item { BpmRow(pattern) { store.setPatternBpm(patternId, it.toDouble()) } }
            item { LengthRow(pattern) { store.setPatternStepCount(patternId, PatternMath.stepCountForBars(it)) } }
            item {
                LiveRow(live, isPlayingThis) { v ->
                    live = v
                    scope.launch { runCatching { graph.settings.set(StudioSettings.SEQUENCER_LIVE, v) } }
                }
            }
            if (pattern.rows.size > 1 || pattern.stepCount > 16) item {
                LanesControlRow(pattern, collapsedRows, { collapsedRows = it }, barsPerLine, { barsPerLine = it })
            }
            if (!pattern.hasSoundingSteps) item {
                Text(
                    "⚠ Toggle steps below to enable Play and Bounce — an empty pattern is never played or bounced.",
                    Modifier.fillMaxWidth().testTag("seq-empty-notice"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary,
                )
            }
            controller.notice?.let { n -> item { Text(n, Modifier.testTag("seq-notice"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
            itemsIndexed(pattern.rows, key = { i, r -> "$i-${r.targetId}" }) { i, row ->
                PatternRowCard(
                    graph, patternId, i, row, compact, isPlayingThis, playing && loadedId == patternId && soloed == i,
                    i in collapsedRows, barsPerLine, startStep, loopEnabled, loopBars, live, engine.clock, tick,
                    onSolo = { controller.toggleSolo(patternId, it, startStep, loopEnabled, loopBars) },
                    onToggleCollapse = { collapsedRows = if (i in collapsedRows) collapsedRows - i else collapsedRows + i },
                    onRename = { renamingRow = i },
                    onTouchStep = { startStep = it.coerceIn(0, maxOf(0, pattern.stepCount - 1)) },
                )
            }
            item { AddRowControl(graph, pattern) }
            item { BounceStatus(pattern) }
        }
    }

    if (renaming) NameDialog("Rename pattern", pattern.name, "Save", { renaming = false }) { store.renamePattern(patternId, it); renaming = false }
    renamingRow?.let { i ->
        LaneNameDialog(pattern.rows.getOrNull(i)?.label.orEmpty(), { renamingRow = null }) {
            store.setPatternRowLabel(patternId, i, it); renamingRow = null
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HeaderBar(
    pattern: StudioPattern, onBack: () -> Unit, controller: SequencerController, isPlayingThis: Boolean, loopEnabled: Boolean, loopBars: Int,
    onRename: () -> Unit, onPlay: () -> Unit, onRefresh: () -> Unit, onLoopToggle: () -> Unit, onLoopBars: (Int) -> Unit,
) {
    var overflow by remember { mutableStateOf(false) }
    var loopMenu by remember { mutableStateOf(false) }
    // Two rows: the name gets the full width (the transport icons used to truncate it to "Seed Pa…").
    androidx.compose.foundation.layout.Column {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        IconButton(onClick = onBack, Modifier.size(36.dp).testTag("seq-back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to patterns") }
        Text(pattern.name.ifEmpty { "Untitled pattern" }, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
        IconButton(onClick = onRename, Modifier.size(36.dp).testTag("seq-rename-${pattern.id}")) { Icon(Icons.Filled.Edit, "Rename pattern", Modifier.size(18.dp)) }
    }
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.End),
    ) {
        IconButton(onClick = onRefresh, Modifier.size(36.dp).testTag("seq-refresh")) { Icon(Icons.Filled.Replay, "Reset playhead to start") }
        Box {
            // Tap cycles a loopBars-bar window anchored at the playhead; long-press picks the bar count (default 2).
            Row(
                Modifier.combinedClickable(onClick = onLoopToggle, onLongClick = { loopMenu = true }).padding(horizontal = 6.dp, vertical = 6.dp).testTag("seq-loop")
                    .semantics { contentDescription = if (loopEnabled) "Looper on, $loopBars bars" else "Looper off" },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.AllInclusive, null, tint = if (loopEnabled) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
                if (loopEnabled) Text("$loopBars", Modifier.padding(start = 3.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
            }
            DropdownMenu(loopMenu, { loopMenu = false }) {
                listOf(1, 2, 4, 8, 16).forEach { n ->
                    DropdownMenuItem(
                        text = { Text("$n bar${if (n == 1) "" else "s"}" + if (n == loopBars) "  ✓" else "") },
                        onClick = { loopMenu = false; onLoopBars(n) }, modifier = Modifier.testTag("seq-loop-bars-$n"),
                    )
                }
            }
        }
        FilledTonalButton(
            onClick = onPlay, enabled = !controller.preparing && pattern.hasSoundingSteps,
            modifier = Modifier.testTag("seq-play"),
        ) {
            if (controller.preparing) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            else Icon(if (isPlayingThis) Icons.Filled.Stop else Icons.Filled.PlayArrow, null, Modifier.size(18.dp))
            Text(if (isPlayingThis) "Stop" else "Play", Modifier.padding(start = 6.dp))
        }
        Box {
            if (controller.bouncing) CircularProgressIndicator(Modifier.padding(8.dp).size(20.dp), strokeWidth = 2.dp)
            else IconButton(onClick = { overflow = true }, Modifier.testTag("seq-overflow")) { Icon(Icons.Filled.MoreVert, "More actions") }
            DropdownMenu(overflow, { overflow = false }) {
                DropdownMenuItem(
                    text = { Text("Bounce for offline") }, enabled = !controller.bouncing && pattern.hasSoundingSteps,
                    onClick = { overflow = false; controller.bounce(pattern) }, modifier = Modifier.testTag("seq-bounce"),
                )
            }
        }
    }}
}

@Composable
private fun BpmRow(pattern: StudioPattern, onBpm: (Int) -> Unit) {
    val bpm = Math.round(pattern.bpm).toInt()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("BPM", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("$bpm", Modifier.widthIn(min = 44.dp).testTag("seq-bpm-value"), style = MaterialTheme.typography.titleLarge)
        Stepper(onMinus = { onBpm((bpm - 1).coerceIn(60, 200)) }, onPlus = { onBpm((bpm + 1).coerceIn(60, 200)) }, tag = "seq-bpm", canMinus = bpm > 60, canPlus = bpm < 200)
    }
}

@Composable
private fun LengthRow(pattern: StudioPattern, onBars: (Int) -> Unit) {
    val bars = PatternMath.barsOf(pattern.stepCount)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Length", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(PatternMath.lengthLabel(pattern.stepCount), Modifier.testTag("seq-length-label"), style = MaterialTheme.typography.bodyMedium)
        Stepper(onMinus = { onBars((bars - 1).coerceAtLeast(1)) }, onPlus = { onBars((bars + 1).coerceAtMost(PatternMath.MAX_BARS)) }, tag = "seq-length-stepper", canMinus = bars > 1, canPlus = bars < PatternMath.MAX_BARS)
    }
}

@Composable
private fun Stepper(onMinus: () -> Unit, onPlus: () -> Unit, tag: String, canMinus: Boolean, canPlus: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        FilledTonalButton(onClick = onMinus, enabled = canMinus, modifier = Modifier.size(width = 44.dp, height = 36.dp).testTag("$tag-minus"), contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
            Icon(Icons.Filled.Remove, "Decrease")
        }
        Box(Modifier.size(6.dp))
        FilledTonalButton(onClick = onPlus, enabled = canPlus, modifier = Modifier.size(width = 44.dp, height = 36.dp).testTag("$tag-plus"), contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
            Icon(Icons.Filled.Add, "Increase")
        }
    }
}

/** Live/Static toggle + the mode-appropriate "when do edits apply" banner (shown while this pattern plays). */
@Composable
private fun LiveRow(live: Boolean, playingThis: Boolean, onLive: (Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FilterChip(selected = live, onClick = { onLive(!live) }, label = { Text("Live edits") }, modifier = Modifier.testTag("seq-live-toggle"))
        }
        if (playingThis) {
            Text(
                if (live) "Live — step & loop edits are heard within a step (BPM and span edits still on next Play)."
                else "Step and BPM edits apply the next time you press Play.",
                Modifier.testTag("seq-edit-banner"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun LanesControlRow(
    pattern: StudioPattern, collapsed: Set<Int>, onCollapsed: (Set<Int>) -> Unit, barsPerLine: Int, onZoom: (Int) -> Unit,
) {
    val allCollapsed = pattern.rows.isNotEmpty() && collapsed.size >= pattern.rows.size
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(
            onClick = { onCollapsed(if (allCollapsed) emptySet() else pattern.rows.indices.toSet()) },
            modifier = Modifier.testTag("seq-collapse-all"),
        ) { Text(if (allCollapsed) "Expand all" else "Collapse all") }
        Box(Modifier.weight(1f))
        Text("Zoom", Modifier.padding(end = 8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        val choices = listOf(1 to "1 bar", 2 to "2", 4 to "4", 8 to "8")
        SingleChoiceSegmentedButtonRow(Modifier.widthIn(max = 220.dp).testTag("seq-zoom")) {
            choices.forEachIndexed { i, (n, label) ->
                SegmentedButton(
                    selected = barsPerLine == n, onClick = { onZoom(n) }, shape = SegmentedButtonDefaults.itemShape(i, choices.size),
                    icon = {}, label = { Text(label, maxLines = 1) }, modifier = Modifier.testTag("seq-zoom-$n"),
                )
            }
        }
    }
}

@Composable
private fun AddRowControl(graph: AppGraph, pattern: StudioPattern) {
    val store = graph.studioGraph.studioStore
    val full = pattern.rows.size >= PatternMath.MAX_PATTERN_ROWS
    val noTargets = store.samplesByName.isEmpty() && store.loopsByName.isEmpty()
    var open by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box {
            TextButton(onClick = { open = true }, enabled = !full && !noTargets, modifier = Modifier.testTag("seq-add-row")) {
                Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Text("Add row", Modifier.padding(start = 6.dp))
            }
            DropdownMenu(open, { open = false }) {
                TargetMenuItems(store, null, { open = false; store.addPatternRow(pattern.id, it) }, "seq-add-row")
            }
        }
        if (full) Text("Patterns hold up to ${PatternMath.MAX_PATTERN_ROWS} rows.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        else if (noTargets) Text("Record a sample or slice a loop first — rows trigger your samples and loops.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BounceStatus(pattern: StudioPattern) {
    if (pattern.fileName != null && !pattern.bounceDirty)
        Text("✓ Bounced — plays offline in collections", Modifier.testTag("seq-bounce-status"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    else if (pattern.fileName != null)
        Text("Bounce out of date — the pattern changed since it was bounced", Modifier.testTag("seq-bounce-status"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Lane rename: unlike the folder NameDialog a BLANK name is valid - it restores the sample's own name. */
@Composable
private fun LaneNameDialog(initial: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename lane") },
        text = {
            Column {
                androidx.compose.material3.OutlinedTextField(text, { text = it }, singleLine = true, modifier = Modifier.testTag("seq-row-rename-field"))
                Text("A custom lane name — leave blank to restore the sample’s name.", Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(text.trim()) }, modifier = Modifier.testTag("seq-row-rename-confirm")) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
