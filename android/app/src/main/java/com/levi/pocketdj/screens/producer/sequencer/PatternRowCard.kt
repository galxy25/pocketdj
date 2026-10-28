package com.levi.pocketdj.screens.producer.sequencer

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.MixerDeck
import com.levi.pocketdj.studio.engine.PatternClock
import com.levi.pocketdj.studio.engine.PatternMath
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.delay

private val CELL_HEIGHT = 34.dp
private val CELL_RADIUS = 6.dp
private val CELL_GAP = 4.dp
private val GROUP_GAP = 12.dp
private const val LINES_PER_CHUNK = 8

/** Spans offered by the long-press "Fit to steps" menu (0 = natural length). */
internal val SPAN_CHOICES = listOf(1, 2, 3, 4, 6, 8, 12, 16)

/** "Samples" / "Loops" target menu body shared by the add-row control and the row's retarget menu. */
@Composable
internal fun TargetMenuItems(store: StudioStore, currentId: String?, onPick: (String) -> Unit, tagPrefix: String) {
    val samples = store.samplesByName
    val loops = store.loopsByName
    if (samples.isNotEmpty()) {
        Text("Samples", Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        samples.forEach { s ->
            DropdownMenuItem(
                text = { Text((s.name.ifEmpty { "Untitled sample" }) + if (s.id == currentId) "  ✓" else "") },
                onClick = { onPick(s.id) }, modifier = Modifier.testTag("$tagPrefix-${s.id}"),
            )
        }
    }
    if (loops.isNotEmpty()) {
        Text("Loops", Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        loops.forEach { l ->
            DropdownMenuItem(
                text = { Text((l.name.ifEmpty { "Untitled loop" }) + if (l.id == currentId) "  ✓" else "") },
                onClick = { onPick(l.id) }, modifier = Modifier.testTag("$tagPrefix-${l.id}"),
            )
        }
    }
}

/**
 * One sequencer row (iOS PatternRowCard): header (collapse chevron, tap-to-solo title, retarget, gain chip, rename,
 * remove), the step grid and a collapsed-by-default per-row mixer deck. The grid wraps [PatternMath.stepsPerLine]
 * steps per line (8 on compact), groups steps in fours with wider gaps, and builds its lines progressively so a
 * 75-bar pattern is on screen and tappable immediately. The playing-step highlight is DRAWN from the frame-sampled
 * [tick] state (draw phase only) - the clock itself is never observable state, so cells never recompose at 8 Hz.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun PatternRowCard(
    graph: AppGraph,
    patternId: String,
    rowIndex: Int,
    row: StudioPatternRow,
    compact: Boolean,
    playingThis: Boolean,
    soloingThis: Boolean,
    collapsed: Boolean,
    barsPerLine: Int,
    cursorStep: Int,
    loopEnabled: Boolean,
    loopBars: Int,
    live: Boolean,
    clock: PatternClock,
    tick: State<Long>,
    onSolo: (Int) -> Unit,
    onToggleCollapse: () -> Unit,
    onRename: () -> Unit,
    onTouchStep: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val missing = !store.targetExists(row.targetId)
    val info = store.displayInfo(row.targetId)
    val title = row.label?.takeIf { it.isNotEmpty() } ?: info?.title?.takeIf { it.isNotEmpty() }
        ?: if (row.targetId.startsWith("lp_")) "Loop" else "Sample"
    var deckExpanded by remember(row.targetId) { mutableStateOf(false) }

    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp), tonalElevation = 2.dp) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // ---- header ----
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onToggleCollapse, Modifier.size(32.dp).testTag("seq-row-collapse-$rowIndex")) {
                    Icon(if (collapsed) Icons.Filled.ChevronRight else Icons.Filled.ExpandMore, if (collapsed) "Expand lane" else "Collapse lane")
                }
                Row(
                    Modifier.weight(1f).clickable(enabled = !missing) { onSolo(rowIndex) }.testTag("seq-row-solo-$rowIndex")
                        .semantics { contentDescription = if (soloingThis) "Stop preview" else "Preview this row" },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        when {
                            soloingThis -> Icons.Filled.StopCircle
                            row.targetId.startsWith("lp_") -> Icons.Filled.Repeat
                            else -> Icons.Filled.GraphicEq
                        },
                        null, Modifier.size(20.dp),
                        tint = if (soloingThis) MaterialTheme.colorScheme.tertiary else if (missing) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
                    )
                    Column(Modifier.padding(start = 8.dp)) {
                        Text(
                            title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall,
                            color = if (missing) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                            fontStyle = if (missing) androidx.compose.ui.text.font.FontStyle.Italic else androidx.compose.ui.text.font.FontStyle.Normal,
                        )
                        Text(
                            if (missing) "missing — playback and bounce skip this row" else info?.kindLabel.orEmpty(),
                            style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = if (missing) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                RetargetMenu(store, row.targetId, rowIndex) { store.setPatternRowTarget(patternId, rowIndex, it) }
                RowGainChip(rowIndex, row.gainDb) { db ->
                    // Persist (marks the bounce dirty) AND mirror into the live mixer when THIS pattern is loaded.
                    store.setPatternRowGain(patternId, rowIndex, db)
                    val eng = studio.patternEngine
                    if (eng.loadedPatternId.value == patternId) eng.setPatternRowGain(rowIndex, db)
                }
                IconButton(onClick = onRename, Modifier.size(32.dp).testTag("seq-row-rename-$rowIndex")) { Icon(Icons.Filled.Edit, "Rename lane", Modifier.size(18.dp)) }
                IconButton(onClick = { store.removePatternRow(patternId, rowIndex) }, Modifier.size(32.dp).testTag("seq-row-remove-$rowIndex")) { Icon(Icons.Filled.Close, "Remove row", Modifier.size(18.dp)) }
            }

            if (collapsed) {
                val hits = row.steps.count { it }
                Text("$hits hit${if (hits == 1) "" else "s"} · collapsed", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                StepGrid(
                    patternId, rowIndex, row, missing, compact, playingThis, barsPerLine, cursorStep, loopEnabled, loopBars, live,
                    graph, clock, tick, onTouchStep,
                )
                // ---- per-row mixer deck (sample rows only: loops carry their edits baked into the file) ----
                val s = store.sample(row.targetId)
                if (s != null) {
                    Row(
                        Modifier.fillMaxWidth().clickable { deckExpanded = !deckExpanded }.testTag("seq-row-deck-$rowIndex"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Tune, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("Mixer deck", Modifier.weight(1f).padding(start = 6.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Icon(if (deckExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (deckExpanded) {
                        MixerDeck(
                            edit = s.edit, showGain = false, showLooper = false, idPrefix = "seq-deck-$rowIndex",
                            onEdit = { e ->
                                val clamped = e.clamped()
                                // Bumps renderRevision -> the row re-bakes on the next Play; mark THIS pattern's bounce stale ONCE
                                // (mutatePattern saves synchronously and bounceDirty is idempotent).
                                store.updateSampleEdit(s.id, clamped)
                                if (store.pattern(patternId)?.bounceDirty == false) store.mutatePattern(patternId) { it }
                                val eng = studio.studioEngine
                                if (eng.loadedSampleId.value == s.id) eng.applyEdit(clamped)
                            },
                        )
                        Text("Shapes this sample — heard on the next Play.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun RetargetMenu(store: StudioStore, currentId: String, rowIndex: Int, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, Modifier.size(32.dp).testTag("seq-row-retarget-$rowIndex")) {
            Icon(Icons.Filled.SwapHoriz, "Change row target", Modifier.size(18.dp))
        }
        DropdownMenu(open, { open = false }) {
            TargetMenuItems(store, currentId, { open = false; onPick(it) }, "seq-row-retarget-$rowIndex")
        }
    }
}

/** Row-gain chip: tap opens a fixed-width slider popover (-24...+12 dB, 0.5 steps) that auto-dismisses after 3 s idle. */
@Composable
private fun RowGainChip(rowIndex: Int, gainDb: Double, onChange: (Double) -> Unit) {
    var open by remember { mutableStateOf(false) }
    var interaction by remember { mutableIntStateOf(0) }
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(7.dp)).clickable { open = true }
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(7.dp))
                .padding(horizontal = 8.dp, vertical = 5.dp).testTag("seq-row-gain-$rowIndex-open")
                .semantics { contentDescription = "Row gain" },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.VolumeUp, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(PatternMath.gainLabel(gainDb), Modifier.padding(start = 4.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(open, { open = false }) {
            // 3 s idle auto-dismiss; every slider change restarts the timer.
            LaunchedEffect(open, interaction) { delay(3_000); open = false }
            Row(Modifier.width(290.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Slider(
                    value = gainDb.toFloat(), onValueChange = { onChange(Math.round(it * 2.0) / 2.0); interaction++ },
                    valueRange = -24f..12f, steps = 71, modifier = Modifier.weight(1f).testTag("seq-row-gain-$rowIndex"),
                )
                Text(PatternMath.gainLabel(gainDb), Modifier.width(60.dp).padding(start = 8.dp), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun StepGrid(
    patternId: String, rowIndex: Int, row: StudioPatternRow, missing: Boolean, compact: Boolean, playingThis: Boolean,
    barsPerLine: Int, cursorStep: Int, loopEnabled: Boolean, loopBars: Int, live: Boolean,
    graph: AppGraph, clock: PatternClock, tick: State<Long>, onTouchStep: (Int) -> Unit,
) {
    val store = graph.studioGraph.studioStore
    val n = row.steps.size
    val perLine = PatternMath.stepsPerLine(compact, barsPerLine)
    val lines = PatternMath.lineCount(n, perLine)
    // PROGRESSIVE: only `shown` lines are built now; the rest stream in a chunk per frame.
    var shown by remember(rowIndex, perLine) { mutableIntStateOf(LINES_PER_CHUNK) }
    if (shown < lines) LaunchedEffect(shown) { delay(16); shown = minOf(shown + LINES_PER_CHUNK, lines) }
    val coverage = remember(row.steps, row.stepSpans) { PatternMath.spanCoverage(row.steps, row.stepSpans) }
    val window = if (loopEnabled) PatternMath.loopWindow(cursorStep, loopBars, maxOf(1, n)) else null
    val cursor = cursorStep.coerceIn(0, maxOf(0, n - 1))
    val onColor = MaterialTheme.colorScheme.primary
    val offColor = MaterialTheme.colorScheme.surfaceVariant
    val accent2 = MaterialTheme.colorScheme.tertiary
    val fg = MaterialTheme.colorScheme.onSurface
    val dim = MaterialTheme.colorScheme.outline
    val border = MaterialTheme.colorScheme.outlineVariant
    val preroll = remember(cursorStep, loopEnabled, loopBars, n) { PatternMath.mappedStep(0, cursorStep, loopEnabled, loopBars, maxOf(1, n)) }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (line in 0 until minOf(shown, lines)) {
            val lo = line * perLine
            val hi = minOf(lo + perLine, n)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(GROUP_GAP)) {
                // Fixed perLine cells per line (short tails padded) so every cell has the same width.
                val groups = PatternMath.beatGroups(lo, lo + perLine)
                for (g in groups) {
                    Row(Modifier.weight(g.count().toFloat()), horizontalArrangement = Arrangement.spacedBy(CELL_GAP)) {
                        for (col in g) {
                            if (col >= hi) { Spacer(Modifier.weight(1f).height(CELL_HEIGHT)); continue }
                            val on = row.steps[col]
                            val loops = on && row.loopSteps.getOrNull(col) == true
                            val span = if (on) row.stepSpans.getOrNull(col) ?: 0 else 0
                            val covered = !on && coverage.getOrNull(col) == true
                            val inLoop = window?.let { col >= it.start && col < it.start + it.len } ?: false
                            var menu by remember { mutableStateOf(false) }
                            val shape = RoundedCornerShape(CELL_RADIUS)
                            Box(
                                Modifier.weight(1f).height(CELL_HEIGHT).clip(shape)
                                    .background(
                                        when {
                                            on -> onColor.copy(alpha = if (missing) 0.35f else 1f)
                                            covered -> onColor.copy(alpha = 0.16f)
                                            else -> offColor
                                        },
                                    )
                                    .drawBehind {
                                        tick.value                                  // draw-phase subscription to the frame sampler
                                        val r = CornerRadius(CELL_RADIUS.toPx())
                                        if (inLoop) drawRoundRect(accent2.copy(alpha = 0.14f), cornerRadius = r)
                                        drawRoundRect(if (col % 4 == 0) dim.copy(alpha = 0.55f) else border, cornerRadius = r, style = Stroke(1.dp.toPx()))
                                        val current = if (playingThis) clock.currentStep ?: preroll else null
                                        if (col == current) drawRoundRect(accent2, cornerRadius = r, style = Stroke(2.dp.toPx()))
                                        else if (col == cursor && !playingThis) drawRoundRect(fg.copy(alpha = 0.9f), cornerRadius = r, size = Size(size.width, size.height), style = Stroke(2.dp.toPx()))
                                    }
                                    .combinedClickable(
                                        onClick = {
                                            store.setPatternStep(patternId, rowIndex, col, !on)
                                            if (live && playingThis) graph.studioGraph.patternEngine.updateLiveStep(rowIndex, col, !on)
                                            onTouchStep(col)
                                        },
                                        onLongClick = { if (on) menu = true },
                                    )
                                    .semantics { contentDescription = "Step ${col + 1}" + if (on) (if (loops) ", loop" else ", one-shot") + (if (span > 0) ", fit $span steps" else "") else "" }
                                    .testTag("seq-step-$rowIndex-$col"),
                            ) {
                                if (loops) Icon(Icons.Filled.Repeat, null, Modifier.align(Alignment.TopEnd).padding(2.dp).size(10.dp), tint = MaterialTheme.colorScheme.surface)
                                if (span > 0) Text("×$span", Modifier.align(Alignment.BottomStart).padding(2.dp), fontSize = 8.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.surface)
                                DropdownMenu(menu, { menu = false }) {
                                    DropdownMenuItem(
                                        text = { Text(if (loops) "One-shot (play once)" else "Loop until retriggered") },
                                        onClick = {
                                            menu = false
                                            store.setPatternStepLoop(patternId, rowIndex, col, !loops)
                                            if (live && playingThis) graph.studioGraph.patternEngine.updateLiveStepLoop(rowIndex, col, !loops)
                                        },
                                        modifier = Modifier.testTag("seq-step-loop-$rowIndex-$col"),
                                    )
                                    Text("Fit to steps", Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    (listOf(0) + SPAN_CHOICES).forEach { sp ->
                                        DropdownMenuItem(
                                            text = { Text((if (sp == 0) "Natural length" else if (sp == 1) "1 step" else "$sp steps") + if (sp == span) "  ✓" else "") },
                                            onClick = { menu = false; store.setPatternStepSpan(patternId, rowIndex, col, sp) },
                                            modifier = Modifier.testTag("seq-step-span-$rowIndex-$col-$sp"),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (shown < lines) {
            val remaining = lines - shown
            Text("$remaining more bar${if (remaining == 1) "" else "s"}…", Modifier.height(CELL_HEIGHT).testTag("seq-pending-bars-$rowIndex"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
