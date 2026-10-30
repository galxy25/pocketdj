package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.store.MixSessionEvent
import kotlinx.coroutines.delay

/** Pure replay-clock math (port of the iOS detail view's index/clock logic) so it is JVM-testable. */
object ReplayClock {
    val SPEEDS = listOf(0.5, 1.0, 2.0, 4.0)

    /**
     * The event the playhead is "on" at [replayMs] over a tMs-sorted list: the FIRST event at an
     * exact-time hit (so a same-instant cluster highlights its head), else the last event strictly
     * before; null before the first / for an empty list.
     */
    fun currentIndex(tMs: List<Int>, replayMs: Double): Int? {
        if (tMs.isEmpty()) return null
        val t = replayMs.toInt()
        var lo = 0
        var hi = tMs.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (tMs[mid] < t) lo = mid + 1 else hi = mid
        }
        if (lo < tMs.size && tMs[lo] == t) return lo
        return if (lo > 0) lo - 1 else null
    }

    /** Wall-clock advance: replayMs + dt * speed, clamped to [durationMs]. */
    fun advance(replayMs: Double, dtMs: Double, speed: Double, durationMs: Int): Double =
        minOf(replayMs + dtMs * speed, durationMs.toDouble())

    fun isFinished(replayMs: Double, durationMs: Int) = replayMs >= durationMs.toDouble()

    /** Pressing play at the end restarts from the top. */
    fun startPosition(replayMs: Double, durationMs: Int): Double = if (isFinished(replayMs, durationMs)) 0.0 else replayMs

    /** Auto-scroll fights the user while scrubbing and is pointless while paused. */
    fun shouldAutoScroll(playing: Boolean, scrubbing: Boolean) = playing && !scrubbing

    fun speedLabel(speed: Double): String =
        if (speed == speed.toLong().toDouble()) "${speed.toLong()}×" else "$speed×"
}

/** Pure layout/tap rules for the timeline (iOS `MixSessionsView` wrappedTimeline + handleTap). */
object ReplayLayout {
    /** Width (dp) at which the timeline switches from one card per row to the wrapped grid. */
    const val WRAP_MIN_DP = 600

    /** Cards per wrapped row: 1 below [WRAP_MIN_DP] (vertical list), 3 on tablets, 5 on very wide panes. */
    fun perRow(widthDp: Int): Int = when {
        widthDp < WRAP_MIN_DP -> 1
        widthDp < 900 -> 3
        else -> 5
    }

    fun isWrapped(widthDp: Int) = perRow(widthDp) > 1

    fun <T> rows(items: List<T>, perRow: Int): List<List<T>> = items.chunked(maxOf(1, perRow))

    /** A tapped card: a LOAD with a resolvable song opens its metadata; everything else jumps the playhead. */
    sealed class Tap {
        data class Metadata(val songId: String) : Tap()
        data class Jump(val tMs: Int) : Tap()
    }

    fun tap(event: MixSessionEvent, songInCatalog: (String) -> Boolean): Tap {
        val id = event.songId
        return if (event.kind == com.levi.pocketdj.mix.store.MixEventKind.Load && id != null && songInCatalog(id)) Tap.Metadata(id)
        else Tap.Jump(event.tMs)
    }
}

@Composable
private fun tintColor(t: EventTint): Color = when (t) {
    EventTint.ACCENT -> MaterialTheme.colorScheme.primary
    EventTint.ACCENT2 -> MaterialTheme.colorScheme.tertiary
    EventTint.GREEN -> Color(0xFF4CD964)
    EventTint.DIM -> MaterialTheme.colorScheme.onSurfaceVariant
    EventTint.RED -> Color(0xFFFF5A5F)
    EventTint.YELLOW -> Color(0xFFFFD60A)
    EventTint.PURPLE -> Color(0xFFBF5AF2)
}

private fun iconVector(i: EventIcon): ImageVector = when (i) {
    EventIcon.LOAD -> Icons.Filled.Download
    EventIcon.PLAY -> Icons.Filled.PlayArrow
    EventIcon.PAUSE -> Icons.Filled.Pause
    EventIcon.SEEK -> Icons.Filled.SwapHoriz
    EventIcon.TEMPO -> Icons.Filled.Speed
    EventIcon.PITCH -> Icons.Filled.MusicNote
    EventIcon.VOLUME -> Icons.AutoMirrored.Filled.VolumeUp
    EventIcon.CROSSFADER -> Icons.Filled.CompareArrows
    EventIcon.COMPRESSOR -> Icons.Filled.GraphicEq
    EventIcon.REVERB -> Icons.Filled.SettingsInputAntenna
    EventIcon.FLANGER -> Icons.Filled.Air
    EventIcon.FILTER -> Icons.Filled.FilterList
    EventIcon.FX_GENERIC -> Icons.Filled.Tune
    EventIcon.VARIANT -> Icons.Filled.Tune
    EventIcon.MOD -> Icons.Filled.Waves
    EventIcon.EQ -> Icons.Filled.Equalizer
    EventIcon.FILTER_HP -> Icons.Filled.VerticalAlignTop
    EventIcon.FILTER_LP -> Icons.Filled.VerticalAlignBottom
    EventIcon.STEMS -> Icons.Filled.GridView
    EventIcon.STEM_MUTED -> Icons.AutoMirrored.Filled.VolumeOff
    EventIcon.STEM_UNMUTED -> Icons.AutoMirrored.Filled.VolumeUp
    EventIcon.STEM_VOLUME -> Icons.Filled.GraphicEq
    EventIcon.LEAD -> Icons.Filled.Star
    EventIcon.SYNC -> Icons.Filled.Sync
    EventIcon.RESET -> Icons.Filled.RestartAlt
    EventIcon.AUTO_PAUSE -> Icons.Filled.PauseCircle
    EventIcon.AUTO_RESUME -> Icons.Filled.PlayCircle
    EventIcon.UNKNOWN -> Icons.Filled.QuestionMark
}

/** One color-coded action card: deck chip A/B, kind icon, sentence, m:ss.S stamp. */
@Composable
fun TimelineCard(event: MixSessionEvent, active: Boolean, onTap: () -> Unit, modifier: Modifier = Modifier) {
    val d = MixEventSentences.describe(event)
    val tint = tintColor(d.tint)
    val shape = RoundedCornerShape(8.dp)
    Surface(
        modifier = modifier.fillMaxWidth().clip(shape).clickable(onClick = onTap).testTag("mix-replay-event-${event.id}"),
        shape = shape,
        color = if (active) tint.copy(alpha = 0.18f) else MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(if (active) 1.5.dp else 1.dp, if (active) tint else MaterialTheme.colorScheme.outline),
    ) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val deck = event.deck
            if (deck != null) {
                Box(
                    Modifier.size(18.dp).clip(CircleShape)
                        .background(if (deck == "A") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary),
                    contentAlignment = Alignment.Center,
                ) { Text(deck, fontSize = 11.sp, color = MaterialTheme.colorScheme.background) }
            } else {
                Icon(Icons.Filled.Adjust, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(iconVector(d.icon), null, Modifier.size(18.dp), tint = tint)
            Column(Modifier.weight(1f)) {
                Text(d.text, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                Text(MixEventSentences.clock(event.tMs), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/**
 * Replay controls + vertical timeline for one session's [events] (a stable snapshot). Replay is
 * VISUAL: a wall-clock ~30 Hz clock at 0.5-4x moves the highlight; it never drives the decks.
 * Auto-scroll only while playing and not scrubbing; tapping a card jumps the playhead there.
 */
@Composable
fun MixReplayTimeline(
    events: List<MixSessionEvent>,
    modifier: Modifier = Modifier,
    /** Optional hook: return true if the tap was consumed (e.g. a load card opened the metadata sheet). */
    onOpenSong: ((String) -> Unit)? = null,
    songInCatalog: (String) -> Boolean = { false },
) {
    val durationMs = events.lastOrNull()?.tMs ?: 0
    var replayMs by rememberSaveable { mutableFloatStateOf(0f) }
    var playing by remember { mutableStateOf(false) }
    var speed by rememberSaveable { mutableStateOf(1.0) }
    var scrubbing by remember { mutableStateOf(false) }
    var speedMenu by remember { mutableStateOf(false) }
    val tMs = remember(events) { events.map { it.tMs } }
    val currentIndex = ReplayClock.currentIndex(tMs, replayMs.toDouble())
    val listState = rememberLazyListState()
    var wrapPerRow by remember { mutableIntStateOf(1) }

    LaunchedEffect(playing) {
        if (!playing) return@LaunchedEffect
        replayMs = ReplayClock.startPosition(replayMs.toDouble(), durationMs).toFloat()
        var last = System.nanoTime()
        while (playing) {
            delay(33)
            val now = System.nanoTime()
            val dtMs = (now - last) / 1_000_000.0
            last = now
            val next = ReplayClock.advance(replayMs.toDouble(), dtMs, speed, durationMs)
            replayMs = next.toFloat()
            if (ReplayClock.isFinished(next, durationMs)) playing = false
        }
    }
    LaunchedEffect(currentIndex) {
        val i = currentIndex ?: return@LaunchedEffect
        if (ReplayClock.shouldAutoScroll(playing, scrubbing)) {
            val info = listState.layoutInfo
            listState.animateScrollToItem((i / wrapPerRow - info.visibleItemsInfo.size / 2).coerceAtLeast(0))
        }
    }

    Column(modifier.fillMaxSize()) {
        Surface(
            Modifier.fillMaxWidth().padding(12.dp), shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { playing = !playing }, enabled = events.isNotEmpty(), modifier = Modifier.testTag("mix-replay-playpause")) {
                    Icon(if (playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle, if (playing) "Pause replay" else "Play replay", Modifier.size(32.dp))
                }
                Text(MixEventSentences.clock(replayMs.toInt()), style = MaterialTheme.typography.labelSmall)
                Slider(
                    value = replayMs.coerceIn(0f, maxOf(durationMs, 1).toFloat()),
                    onValueChange = { scrubbing = true; playing = false; replayMs = it },
                    onValueChangeFinished = { scrubbing = false },
                    valueRange = 0f..maxOf(durationMs, 1).toFloat(),
                    enabled = events.isNotEmpty(),
                    modifier = Modifier.weight(1f).padding(horizontal = 6.dp).testTag("mix-replay-scrub"),
                )
                Text(MixEventSentences.clock(durationMs), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Box {
                    TextButton(onClick = { speedMenu = true }, modifier = Modifier.testTag("mix-replay-speed")) { Text(ReplayClock.speedLabel(speed)) }
                    DropdownMenu(speedMenu, { speedMenu = false }) {
                        ReplayClock.SPEEDS.forEach { s ->
                            DropdownMenuItem(text = { Text(ReplayClock.speedLabel(s)) }, onClick = { speed = s; speedMenu = false })
                        }
                    }
                }
            }
        }
        if (events.isEmpty()) {
            Text("No actions recorded", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            val onTap: (MixSessionEvent) -> Unit = { e ->
                when (val t = ReplayLayout.tap(e, songInCatalog)) {
                    is ReplayLayout.Tap.Metadata -> onOpenSong?.invoke(t.songId) ?: run { replayMs = e.tMs.toFloat() }
                    is ReplayLayout.Tap.Jump -> replayMs = t.tMs.toFloat()
                }
            }
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val perRow = ReplayLayout.perRow(maxWidth.value.toInt())
                androidx.compose.runtime.SideEffect { wrapPerRow = perRow }
                if (perRow <= 1) {
                    LazyColumn(
                        Modifier.fillMaxSize().testTag("mix-replay-timeline"), state = listState,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        itemsIndexed(events, key = { _, e -> e.id }) { i, e ->
                            TimelineCard(e, active = i == currentIndex, onTap = { onTap(e) })
                        }
                    }
                } else {
                    val rows = remember(events, perRow) { ReplayLayout.rows(events, perRow) }
                    LazyColumn(
                        Modifier.fillMaxSize().testTag("mix-replay-timeline-wrapped"), state = listState,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        itemsIndexed(rows) { rowIdx, row ->
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
                                    row.forEachIndexed { i, e ->
                                        TimelineCard(e, active = rowIdx * perRow + i == currentIndex, onTap = { onTap(e) }, modifier = Modifier.weight(1f))
                                        if (i < row.size - 1) Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(12.dp).align(Alignment.CenterVertically), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    // Keep a short last row's cards the same width as full rows.
                                    repeat(perRow - row.size) { Box(Modifier.weight(1f)) }
                                }
                                if (rowIdx < rows.size - 1) Icon(Icons.AutoMirrored.Filled.Undo, null, Modifier.padding(start = 6.dp).size(14.dp), tint = MaterialTheme.colorScheme.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
