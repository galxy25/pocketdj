package com.levi.pocketdj.screens.history.wheel

import android.provider.Settings
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Luggage
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.levi.pocketdj.data.pockets.wheel.PocketMode
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketPaletteStore
import com.levi.pocketdj.data.pockets.wheel.PocketClock
import com.levi.pocketdj.data.pockets.wheel.PocketSwatch
import com.levi.pocketdj.data.pockets.wheel.PocketWheelSnapshot
import com.levi.pocketdj.di.PocketsGraph
import com.levi.pocketdj.ui.theme.PdjAccent
import com.levi.pocketdj.ui.theme.PdjBackground
import com.levi.pocketdj.ui.theme.PdjOnBackground
import com.levi.pocketdj.ui.theme.PdjOnSurfaceVariant
import com.levi.pocketdj.ui.theme.PdjOutline
import com.levi.pocketdj.ui.theme.PdjSurfaceContainerHigh
import com.levi.pocketdj.ui.theme.PdjSurfaceVariant
import kotlinx.coroutines.delay
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

// iOS Theme: bg / bgRaised / bgOverlay / border / fg / fgDim / accent / accent2 (gold).
private val Bg = PdjBackground
private val BgRaised = PdjSurfaceVariant
private val BgOverlay = PdjSurfaceContainerHigh
private val Border = PdjOutline
private val Fg = PdjOnBackground
private val FgDim = PdjOnSurfaceVariant
private val Accent = PdjAccent
private val Accent2 = Color(0xFFFFCE6E)

/** Two-pane breakpoint (design §10.5: side pane at 600 dp or wider). */
private val WIDE = 600.dp
private val MAX_SIDE = 520.dp
private const val LABEL_MARGIN_DP = 22f

/** The chip order of the design: All, then Car / Trip / Run / Walk / Mix / Browse / Home. */
internal val CHIP_MODES: List<PocketMode> =
    listOf(PocketMode.CAR_PLAY, PocketMode.TRIP, PocketMode.RUNNING, PocketMode.WALKING, PocketMode.MIX, PocketMode.BROWSE, PocketMode.COLLECTION)

internal fun chipLabel(m: PocketMode): String = when (m) {
    PocketMode.CAR_PLAY -> "Car"
    PocketMode.TRIP -> "Trip"
    PocketMode.RUNNING -> "Run"
    PocketMode.WALKING -> "Walk"
    PocketMode.MIX -> "Mix"
    PocketMode.BROWSE -> "Browse"
    PocketMode.COLLECTION -> "Home"
}

internal fun modeIcon(m: PocketMode): ImageVector = when (m) {
    PocketMode.CAR_PLAY -> Icons.Filled.DirectionsCar
    PocketMode.TRIP -> Icons.Filled.Luggage
    PocketMode.RUNNING -> Icons.AutoMirrored.Filled.DirectionsRun
    PocketMode.WALKING -> Icons.AutoMirrored.Filled.DirectionsWalk
    PocketMode.MIX -> Icons.Filled.Shuffle
    PocketMode.BROWSE -> Icons.Filled.Explore
    PocketMode.COLLECTION -> Icons.Filled.Home
}

/** Reduce motion: the system "Remove animations" / animator scale of 0. */
@Composable
internal fun rememberReduceMotion(): Boolean {
    val ctx = LocalContext.current
    return remember(ctx) {
        runCatching { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false)
    }
}

private fun Color.withRgba(c: PocketWheelPaint.Rgba) = Color(c.r.toFloat(), c.g.toFloat(), c.b.toFloat(), c.a.toFloat())

private fun swatchColor(s: PocketSwatch): Color {
    val (r, g, b) = s.rgb(dark = true)
    return Color(r.toFloat(), g.toFloat(), b.toFloat())
}

private fun todayDow(nowMs: Long): Int =
    PocketClock.local(nowMs.toDouble(), java.util.TimeZone.getDefault().getOffset(nowMs) / 60_000).dow

// ---------------------------------------------------------------------------------------------------------------
// Host: wires the screen to the app graph
// ---------------------------------------------------------------------------------------------------------------

/**
 * The wheel bound to the app graph: follows the moment cache, keeps the best match fresh (on appear + every minute),
 * and carries the selected cell. [card] renders the moment card for the selected cell (P2-POC-10); null shows a hint.
 */
@Composable
fun PocketWheelHost(
    graph: PocketsGraph,
    modifier: Modifier = Modifier,
    onPause: (() -> Unit)? = null,
    selected: PocketMomentKey? = null,
    onSelect: ((PocketMomentKey?) -> Unit)? = null,
    card: (@Composable (PocketMomentKey) -> Unit)? = null,
) {
    val snapshot by graph.wheelCache.snapshot.collectAsState()
    var local by remember { mutableStateOf<PocketMomentKey?>(null) }
    LaunchedEffect(graph) {
        while (true) {
            runCatching { graph.wheelController.refresh() }
            delay(60_000)
        }
    }
    // A snapshot rebuild re-keys the best match too.
    LaunchedEffect(snapshot) { runCatching { graph.wheelController.refresh() } }
    val actions = rememberPocketWheelActions(graph, onPause)
    PocketWheelScreen(
        snapshot = snapshot,
        palette = graph.wheelCache.palette,
        actions = actions,
        selected = if (onSelect != null) selected else local,
        onSelect = onSelect ?: { local = it },
        modifier = modifier,
        card = card,
    )
}

// ---------------------------------------------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------------------------------------------

/**
 * History > Pockets > Wheel (iOS `PocketWheelScreen`). The clock face: midnight at 12 o'clock, clockwise; Monday the
 * innermost ring, Sunday the outermost; the focused weekday's ring is 1.8x thicker. Colour = the cell's dominant
 * SOURCE collection (stable synced palette). Tap or scrub to inspect; the centre play button plays the pocket that
 * best matches now. Non-scrolling: the host scrolls (History / Debug).
 */
@Composable
fun PocketWheelScreen(
    snapshot: PocketWheelSnapshot,
    palette: PocketPaletteStore,
    actions: PocketWheelActions,
    selected: PocketMomentKey?,
    onSelect: (PocketMomentKey?) -> Unit,
    modifier: Modifier = Modifier,
    card: (@Composable (PocketMomentKey) -> Unit)? = null,
    nowMs: () -> Long = { System.currentTimeMillis() },
) {
    var modeFilter by remember { mutableStateOf<PocketMode?>(null) }
    var focusedDow by remember { mutableStateOf(todayDow(nowMs())) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    val index = remember(snapshot) { snapshot.index() }

    BoxWithConstraints(modifier.fillMaxWidth().testTag("pocket-wheel-screen")) {
        val avail = maxWidth
        val wide = avail >= WIDE
        if (snapshot.isEmpty) {
            EmptyState(actions)
            return@BoxWithConstraints
        }
        val wheelColumn: @Composable (Dp) -> Unit = { side ->
            Column(Modifier.width(side), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ModeChips(modeFilter) { modeFilter = it }
                PocketWheelCanvas(
                    snapshot = snapshot, index = index, palette = palette, actions = actions,
                    side = side, focusedDow = focusedDow, modeFilter = modeFilter,
                    selected = selected, onSelect = onSelect, highlighted = highlighted, nowMs = nowMs,
                )
                WeekdayRow(focusedDow) { focusedDow = it }
            }
        }
        val detail: @Composable () -> Unit = {
            Caption(actions)
            Legend(snapshot, palette, highlighted) { highlighted = it }
            if (selected != null && index[selected] != null) {
                if (card != null) card(selected) else DefaultCardHint(index.getValue(selected), snapshot)
            } else {
                Text("Tap or drag across the wheel to see a pocket.", color = FgDim, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp).testTag("pocket-wheel-hint"), textAlign = TextAlign.Center)
            }
        }
        if (wide) {
            Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.Top) {
                wheelColumn(minOf(MAX_SIDE, avail * 0.55f))
                Column(Modifier.widthIn(max = 380.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) { detail() }
            }
        } else {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Radius (width - 32) / 2: the canvas takes the width minus the 16 dp gutters.
                wheelColumn(minOf(MAX_SIDE, avail - 32.dp))
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) { detail() }
            }
        }
    }
}

@Composable
private fun EmptyState(actions: PocketWheelActions) {
    Column(
        Modifier.fillMaxWidth().padding(32.dp).testTag("pocket-wheel-empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.Circle, contentDescription = null, tint = FgDim, modifier = Modifier.size(64.dp))
        Text("Play for a week to paint your wheel.", color = Fg, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(
            "Each ring is a day and each slice an hour. As you listen, PocketDJ colours them by the playlist or pocket the music came from.",
            color = FgDim, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
        )
        actions.playBest?.let { play ->
            Button(onClick = play, modifier = Modifier.testTag("pocket-wheel-empty-play")) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null); Spacer(Modifier.width(6.dp)); Text("Play something for now")
            }
        }
    }
}

@Composable
private fun ModeChips(selected: PocketMode?, onChange: (PocketMode?) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Chip("All", Icons.Filled.Apps, selected == null, "all") { onChange(null) }
        for (m in CHIP_MODES) Chip(chipLabel(m), modeIcon(m), selected == m, m.token) { onChange(if (selected == m) null else m) }
    }
}

@Composable
private fun Chip(label: String, icon: ImageVector, on: Boolean, id: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .heightIn(min = 36.dp)
            .clip(shape)
            .background(if (on) Accent.copy(alpha = 0.25f) else BgRaised, shape)
            .border(1.dp, if (on) Accent else Border, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .semantics { role = Role.Button; selected = on }
            .testTag("pocket-wheel-mode-$id"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, contentDescription = null, tint = if (on) Fg else FgDim, modifier = Modifier.size(16.dp))
        Text(label, color = if (on) Fg else FgDim, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun WeekdayRow(focused: Int, onFocus: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().widthIn(max = MAX_SIDE), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        for (d in 1..7) {
            val on = d == focused
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 40.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (on) BgOverlay else Color.Transparent)
                    .clickable { onFocus(d) }
                    .semantics { contentDescription = "Focus ${PocketMomentKey.weekdayNames[d - 1]}"; role = Role.Button; selected = on }
                    .testTag("pocket-wheel-day-$d"),
                contentAlignment = Alignment.Center,
            ) {
                Text(PocketMomentKey.weekdayAbbrev[d - 1], color = if (on) Fg else FgDim, fontSize = 11.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal)
            }
        }
    }
}

@Composable
private fun Caption(actions: PocketWheelActions) {
    val best = actions.bestMatch ?: return
    Column(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}.testTag("pocket-wheel-caption"),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(best.caption, color = Fg, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium)
        Text(best.detail, color = FgDim, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun Legend(snapshot: PocketWheelSnapshot, palette: PocketPaletteStore, highlighted: String?, onHighlight: (String?) -> Unit) {
    val ids = snapshot.dominanceOrder
    if (ids.isEmpty()) return
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).testTag("pocket-wheel-legend"), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for (id in ids) {
            val on = highlighted == id
            val shape = RoundedCornerShape(50)
            Row(
                Modifier
                    .heightIn(min = 36.dp)
                    .clip(shape)
                    .background(if (on) BgOverlay else BgRaised, shape)
                    .border(1.dp, if (on) Fg else Border, shape)
                    .clickable { onHighlight(if (on) null else id) }
                    .padding(horizontal = 10.dp, vertical = 5.dp)
                    .semantics { role = Role.Button; selected = on }
                    .testTag("pocket-legend-$id"),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(Modifier.size(10.dp).background(swatchColor(palette.swatch(id)), CircleShape))
                Text(snapshot.collectionNames[id] ?: "Collection", color = Fg, fontSize = 12.sp)
                Text("${Math.round((snapshot.weekShare[id] ?: 0.0) * 100)} %", color = FgDim, fontSize = 11.sp)
            }
        }
    }
}

/** Shown when the host supplies no moment card (Debug preview): the cell's title + counts. */
@Composable
private fun DefaultCardHint(m: PocketMoment, snapshot: PocketWheelSnapshot) {
    Column(
        Modifier.fillMaxWidth().background(BgRaised, RoundedCornerShape(12.dp)).padding(12.dp).testTag("pocket-wheel-selected"),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(m.key.longLabel, color = Fg, fontWeight = FontWeight.SemiBold)
        Text((snapshot.name(m.dominantCollectionId) ?: "Mixed") + " · ${m.directPlays} plays", color = FgDim, style = MaterialTheme.typography.bodySmall)
    }
}

// ---------------------------------------------------------------------------------------------------------------
// The canvas
// ---------------------------------------------------------------------------------------------------------------

private data class Scrub(val x: Float, val y: Float, val key: PocketMomentKey?, val dow: Int, val hour: Int)

/**
 * The Canvas + its gestures (tap / scrub with a callout) + the centre play button + the accessibility nodes. Draws
 * only from the remembered [WheelLayout].
 */
@Composable
private fun PocketWheelCanvas(
    snapshot: PocketWheelSnapshot,
    index: Map<PocketMomentKey, PocketMoment>,
    palette: PocketPaletteStore,
    actions: PocketWheelActions,
    side: Dp,
    focusedDow: Int,
    modeFilter: PocketMode?,
    selected: PocketMomentKey?,
    onSelect: (PocketMomentKey?) -> Unit,
    highlighted: String?,
    nowMs: () -> Long,
) {
    val density = LocalDensity.current
    val sidePx = with(density) { side.toPx() }
    val radiusPx = max(with(density) { 60.dp.toPx() }, sidePx / 2 - with(density) { LABEL_MARGIN_DP.dp.toPx() }).toDouble()
    val layout = remember(radiusPx, focusedDow, modeFilter, snapshot) { WheelLayout(radiusPx, focusedDow, modeFilter, snapshot.moments) }
    val center = WheelLayout.Pt(sidePx / 2.0, sidePx / 2.0)
    val measurer = rememberTextMeasurer()
    val haptic = LocalHapticFeedback.current
    var scrub by remember { mutableStateOf<Scrub?>(null) }
    var tick by remember { mutableLongStateOf(nowMs()) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); tick = nowMs() } }
    val painters = PocketMode.entries.associateWith { rememberVectorPainter(modeIcon(it)) }

    Box(Modifier.size(side)) {
        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(layout) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        down.consume()
                        var last = down.position
                        fun update(p: Offset) {
                            last = p
                            val h = layout.hit(WheelLayout.Pt(p.x.toDouble(), p.y.toDouble()), center)
                            if (h is WheelLayout.Hit.CellHit) {
                                val s = scrub
                                if (s == null || s.key != h.key || s.hour != h.hour || s.dow != h.dow) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                scrub = Scrub(p.x, p.y, h.key, h.dow, h.hour)
                            } else {
                                scrub = null
                            }
                        }
                        update(down.position)
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch = ev.changes.firstOrNull() ?: break
                            if (!ch.pressed) break
                            update(ch.position)
                            ch.consume()
                        }
                        scrub = null
                        val end = layout.hit(WheelLayout.Pt(last.x.toDouble(), last.y.toDouble()), center)
                        if (end is WheelLayout.Hit.CellHit && end.key != null) {
                            onSelect(end.key)
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        }
                    }
                }
                .testTag("pocket-wheel-canvas"),
        ) {
            drawWheel(layout, index, palette, highlighted, selected, tick, measurer, painters, center)
        }

        // One TalkBack node per weekday ring: hours step with custom actions, the default action opens the pocket.
        RingSemantics(layout, index, snapshot.collectionNames, onSelect, nowMs)

        val holeDp = with(density) { (layout.holeRadius * 1.7).toFloat().toDp() }
        Box(Modifier.align(Alignment.Center).size(holeDp)) {
            CenterButton(actions, palette)
        }

        scrub?.let { s ->
            val calloutW = 180.dp
            val x = (s.x - with(density) { calloutW.toPx() } / 2).coerceIn(0f, max(0f, sidePx - with(density) { calloutW.toPx() }))
            val y = max(0f, s.y - with(density) { 72.dp.toPx() })
            Popup(alignment = Alignment.TopStart, offset = IntOffset(x.toInt(), y.toInt()), properties = PopupProperties(focusable = false, clippingEnabled = false)) {
                Callout(s, index, snapshot, Modifier.width(calloutW))
            }
        }
    }
}

@Composable
private fun Callout(s: Scrub, index: Map<PocketMomentKey, PocketMoment>, snapshot: PocketWheelSnapshot, modifier: Modifier) {
    val title = s.key?.shortLabel ?: "${PocketMomentKey.weekdayAbbrev[s.dow - 1]} ${PocketMomentKey.hourLabel(s.hour)}"
    val m = s.key?.let { index[it] }
    val sub = m?.let { (snapshot.name(it.dominantCollectionId) ?: "Mixed") + " · ${it.directPlays} plays" } ?: "Nothing yet"
    Column(
        modifier
            .background(BgOverlay, RoundedCornerShape(8.dp))
            .border(BorderStroke(1.dp, Border), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = "" }
            .testTag("pocket-wheel-callout"),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(title, color = Fg, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Text(sub, color = FgDim, fontSize = 11.sp)
    }
}

@Composable
private fun RingSemantics(
    layout: WheelLayout,
    index: Map<PocketMomentKey, PocketMoment>,
    names: Map<String, String>,
    onSelect: (PocketMomentKey?) -> Unit,
    nowMs: () -> Long,
) {
    val hours = remember {
        val h = PocketClock.local(nowMs().toDouble(), java.util.TimeZone.getDefault().getOffset(nowMs()) / 60_000).hour
        mutableStateListOf(h, h, h, h, h, h, h)
    }
    for (dow in 1..7) {
        val hour = hours[dow - 1]
        val recurring = WheelAccessibility.recurringHours(dow, layout, index)
        Box(
            Modifier
                .fillMaxSize()
                .semantics {
                    contentDescription = PocketMomentKey.weekdayNames[dow - 1] +
                        if (recurring.isEmpty()) ". Recurring pockets: none yet"
                        else ". Recurring pockets: " + recurring.joinToString(", ") { PocketMomentKey.hourLabel(it) }
                    stateDescription = WheelAccessibility.value(dow, hour, layout, index, names)
                    customActions = listOf(
                        CustomAccessibilityAction("Next hour") { hours[dow - 1] = WheelAccessibility.nextHour(hours[dow - 1], 1); true },
                        CustomAccessibilityAction("Previous hour") { hours[dow - 1] = WheelAccessibility.nextHour(hours[dow - 1], -1); true },
                    )
                    onClick(label = "Open this pocket") {
                        WheelAccessibility.busiestKey(dow, hours[dow - 1], layout, index)?.let { onSelect(it); true } ?: false
                    }
                }
                .testTag("pocket-wheel-ring-$dow"),
        )
    }
}

// -- drawing ----------------------------------------------------------------------------------------------------

private fun sector(c: WheelLayout.Pt, inner: Double, outer: Double, a0: Double, a1: Double): Path {
    val p = Path()
    val steps = max(2, ceil((a1 - a0) / (3 * Math.PI / 180)).toInt())
    for (i in 0..steps) {
        val a = a0 + (a1 - a0) * i / steps
        val pt = WheelLayout.point(outer, a, c)
        if (i == 0) p.moveTo(pt.x.toFloat(), pt.y.toFloat()) else p.lineTo(pt.x.toFloat(), pt.y.toFloat())
    }
    for (i in steps downTo 0) {
        val a = a0 + (a1 - a0) * i / steps
        val pt = WheelLayout.point(inner, a, c)
        p.lineTo(pt.x.toFloat(), pt.y.toFloat())
    }
    p.close()
    return p
}

private fun Offset(p: WheelLayout.Pt) = Offset(p.x.toFloat(), p.y.toFloat())

private fun DrawScope.drawWheel(
    layout: WheelLayout,
    index: Map<PocketMomentKey, PocketMoment>,
    palette: PocketPaletteStore,
    highlighted: String?,
    selected: PocketMomentKey?,
    nowMs: Long,
    measurer: TextMeasurer,
    painters: Map<PocketMode, Painter>,
    c: WheelLayout.Pt,
) {
    val dp = density
    // Ring tracks (empty cells read as the surface colour).
    for (ring in layout.rings) drawPath(sector(c, ring.inner, ring.outer, 0.0, 2 * Math.PI), BgRaised)
    // Cells.
    for (cell in layout.cells) {
        val ring = layout.ring(cell.dow) ?: continue
        for (s in cell.slivers) {
            val m = index[s.key] ?: continue
            val swatch = palette.swatch(m.dominantCollectionId)
            val dimmed = highlighted != null && m.dominantCollectionId != highlighted
            drawPath(sector(c, ring.inner, ring.outer, s.start, s.end), Color.Unspecified.withRgba(PocketWheelPaint.fill(m, swatch, dimmed)))
            if (swatch == PocketSwatch.Mixed || swatch.isHatched) {
                val mid = (s.start + s.end) / 2
                drawLine(
                    Bg.copy(alpha = 0.6f),
                    Offset(WheelLayout.point(ring.inner + 1, mid, c)), Offset(WheelLayout.point(ring.outer - 1, mid, c)), strokeWidth = 1f,
                )
            }
            if (ring.focused && ring.thickness >= 20 * dp && s.end - s.start >= WheelLayout.angleForHour(0.55) && layout.modeFilter == null) {
                val p = WheelLayout.point(ring.mid, (s.start + s.end) / 2, c)
                val sz = 10f * dp
                val painter = painters[s.key.mode]
                if (painter != null) {
                    translate(p.x.toFloat() - sz / 2, p.y.toFloat() - sz / 2) {
                        with(painter) { draw(Size(sz, sz), colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(Bg.copy(alpha = 0.85f))) }
                    }
                }
            }
        }
    }
    // Hairline separators between hours on every ring (keeps the clock legible).
    for (h in 0 until 24) {
        val a = WheelLayout.angleForHour(h.toDouble())
        drawLine(
            Bg, Offset(WheelLayout.point(layout.holeRadius, a, c)), Offset(WheelLayout.point(layout.radius, a, c)),
            strokeWidth = (if (h % 6 == 0) 1.5f else 0.75f) * dp,
        )
    }
    // Selection outline.
    if (selected != null) {
        val ring = layout.ring(selected.dow)
        val s = layout.cell(selected.dow, selected.hour)?.slivers?.firstOrNull { it.key == selected }
        if (ring != null && s != null) drawPath(sector(c, ring.inner, ring.outer, s.start, s.end), Fg, style = Stroke(width = 2f * dp))
    }
    // Hour labels (12a / 6a / 12p / 6p) outside the rim, dots elsewhere.
    val tickStyle = TextStyle(color = FgDim, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
    for (h in 0 until 24) {
        val p = WheelLayout.point(layout.radius + 11 * dp, WheelLayout.angleForHour(h.toDouble()), c)
        if (h % 6 == 0) {
            val t = measurer.measure(PocketWheelPaint.hourTick(h), tickStyle)
            drawText(t, topLeft = Offset(p.x.toFloat() - t.size.width / 2f, p.y.toFloat() - t.size.height / 2f))
        } else {
            drawCircle(FgDim.copy(alpha = 0.6f), radius = 1.2f * dp, center = Offset(p))
        }
    }
    // Weekday letters at each ring's 12 o'clock end.
    for (ring in layout.rings) {
        val p = WheelLayout.point(ring.mid, -0.06, c)
        val style = TextStyle(color = if (ring.focused) Fg else FgDim, fontSize = if (ring.focused) 10.sp else 8.sp, fontWeight = if (ring.focused) FontWeight.Bold else FontWeight.Normal)
        val t = measurer.measure(PocketMomentKey.weekdayShort[ring.dow - 1], style)
        drawText(t, topLeft = Offset(p.x.toFloat() - t.size.width, p.y.toFloat() - t.size.height / 2f))
    }
    // The "now" needle.
    val tz = java.util.TimeZone.getDefault().getOffset(nowMs) / 60_000
    val a = WheelLayout.angleForHour(PocketClock.local(nowMs.toDouble(), tz).fractionalHour)
    drawLine(
        Accent2, Offset(WheelLayout.point(layout.holeRadius, a, c)), Offset(WheelLayout.point(layout.radius + 4 * dp, a, c)), strokeWidth = 1.5f * dp,
    )
}

// -- the centre play button -------------------------------------------------------------------------------------

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CenterButton(actions: PocketWheelActions, palette: PocketPaletteStore) {
    val best = actions.bestMatch
    val ringColor = if (best == null) Border else swatchColor(palette.swatch(best.collectionId))
    val run = actions.runProgress
    var menu by remember { mutableStateOf(false) }
    val reduce = rememberReduceMotion()
    val frac by animateFloatAsState(
        targetValue = if (run != null) run.done.toFloat() / max(1, run.total) else 0f,
        animationSpec = if (reduce) snap() else tween(300), label = "pocket-run-progress",
    )
    val hasMenu = run != null || (actions.alternatives.isNotEmpty() && actions.playAlternative != null)
    val enabled = actions.playBest != null || run != null
    val label = when {
        run != null -> "Pause the pocket, ${run.done} of ${run.total} songs played"
        best == null -> "Play the pocket for now"
        else -> "Play the pocket for now: ${best.detail}, ${best.caption}"
    }
    Box(
        Modifier
            .fillMaxSize()
            .clip(CircleShape)
            .background(BgOverlay, CircleShape)
            .border(4.dp, ringColor, CircleShape)
            // Secondary click (mouse / ChromeOS) opens the same menu as long-press.
            .pointerInput(hasMenu) {
                if (!hasMenu) return@pointerInput
                awaitEachGesture {
                    val ev = awaitPointerEvent()
                    if (ev.type == PointerEventType.Press && ev.buttons.isSecondaryPressed) {
                        ev.changes.forEach { it.consume() }
                        menu = true
                    }
                }
            }
            .combinedClickable(
                enabled = enabled,
                onClick = { if (run != null && actions.pauseRun != null) actions.pauseRun.invoke() else actions.playBest?.invoke() },
                onLongClick = { if (hasMenu) menu = true },
            )
            .semantics { contentDescription = label; role = Role.Button }
            .testTag("pocket-wheel-play"),
        contentAlignment = Alignment.Center,
    ) {
        if (run != null) {
            Canvas(Modifier.fillMaxSize().padding(5.dp)) {
                drawArc(Accent2, startAngle = -90f, sweepAngle = 360f * frac, useCenter = false, style = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Pause, contentDescription = null, tint = Fg, modifier = Modifier.size(22.dp))
                Text("${run.done}/${run.total}", color = Fg, fontSize = 11.sp, modifier = Modifier.testTag("pocket-wheel-progress"))
            }
        } else {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = if (enabled) Fg else FgDim, modifier = Modifier.size(32.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, modifier = Modifier.testTag("pocket-wheel-menu")) {
            if (run != null) {
                actions.clearRun?.let { clear ->
                    DropdownMenuItem(text = { Text("Clear this pocket") }, onClick = { menu = false; clear() }, modifier = Modifier.testTag("pocket-wheel-clear"))
                }
                actions.playBest?.let { play ->
                    DropdownMenuItem(text = { Text("Start a new pocket for now") }, onClick = { menu = false; play() }, modifier = Modifier.testTag("pocket-wheel-new"))
                }
            }
            val alt = actions.playAlternative
            if (actions.alternatives.isNotEmpty() && alt != null) {
                DropdownMenuItem(text = { Text("Not this?", color = FgDim, fontSize = 12.sp) }, onClick = {}, enabled = false)
                for ((i, a) in actions.alternatives.withIndex()) {
                    DropdownMenuItem(
                        text = { Text("${a.caption} · ${a.detail}") },
                        onClick = { menu = false; alt(a) },
                        modifier = Modifier.testTag("pocket-wheel-alt-$i"),
                    )
                }
            }
        }
    }
}
