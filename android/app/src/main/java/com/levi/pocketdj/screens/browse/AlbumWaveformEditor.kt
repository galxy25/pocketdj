package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.diag.DiagLog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

private val HANDLE_BAND = 22.dp
private val WAVE_HEIGHT = 96.dp
private val TITLE_BAND = 18.dp

/**
 * The WHOLE vinyl side as one waveform on the album page (iOS `AlbumWaveformEditor`): every song's region tinted by
 * its Camelot key, a live 4 Hz playhead, tap / horizontal drag = play from there, boundary handles with a nudge bar,
 * double-tap a region = rename. Self-hides when any song's start is unknown.
 *
 * A VERTICAL pan that starts on the waveform is never consumed (the page's LazyColumn scrolls) and neither scrubs nor
 * plays. Boundary edits and renames are saved as deltas in the synced edits document and re-applied live.
 */
@Composable
internal fun AlbumWaveformEditor(
    album: IndexAlbum,
    songsById: Map<String, IndexSong>,
    manifest: Map<String, RipManifestEntry>,
    /** Start the album at track [index], [atMs] into that track (the album page owns how a play launches). */
    playFrom: (index: Int, atMs: Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val layout by graph.catalogRepository.segmentOverrides.collectAsState()
    val sequencer = graph.playbackGraph.sequencer
    val editsStore = graph.collectionsGraph.editsStore

    val trackList = album.trackList
    // effective start = manifest/edited start (what playback seeks to), else the override, else the detected segment.
    val starts = AlbumBoundaryEdits.starts(trackList, album.audioTracks) { id ->
        graph.ripsRepository.effectiveStartMs(id) ?: layout.startMs[SongVariant.baseId(id)]
    } ?: return

    // Live playhead at 4 Hz from the loaded run item.
    var fileState by remember { mutableStateOf(sequencer.albumFileState()) }
    LaunchedEffect(Unit) {
        while (true) {
            fileState = sequencer.albumFileState()
            delay(250)
        }
    }
    val bases = remember(trackList) { trackList.toSet() }
    val isLoaded = fileState?.let { SongVariant.baseId(it.mediaId) in bases } == true
    val playhead: Long? = if (isLoaded) fileState?.fileMs else null

    val total = maxOf(1L, AlbumBoundaryEdits.totalMs(starts, if (isLoaded) fileState?.durationMs else null, album.audioDurationSec, album.audioTracks))
    val fileKey = trackList.firstNotNullOfOrNull { id -> manifest[id]?.takeIf { it.startMs != null }?.key }
    val waveformUrl = trackList.firstNotNullOfOrNull { id -> manifest[id]?.waveform?.let { Endpoints.ripAudioUrl(it) } }
    val rawSegments = graph.catalogRepository.rawAlbum(album.id)?.audioTracks ?: album.audioTracks
    val editable = AlbumBoundaryEdits.editable(rawSegments?.size ?: 0, trackList.size)

    fun endOf(i: Int, s: List<Long>) =
        AlbumBoundaryEdits.endMs(i, trackList, s, total, layout.endMs, layout.detectedEndMs, fileKey ?: album.id)
    val storedSideEnd = endOf(starts.size - 1, starts)

    fun title(i: Int): String = songsById[trackList.getOrNull(i)]?.name ?: "Track ${i + 1}"
    fun keyColor(i: Int): Color {
        val seg = album.audioTracks?.getOrNull(i)
        return Camelot.color(songsById[trackList.getOrNull(i)]?.camelot ?: seg?.camelot)
    }

    var dragging by remember { mutableStateOf<Pair<Int, Long>?>(null) }
    var pending by remember { mutableStateOf<Pair<Int, Long>?>(null) }
    var scrubMs by remember { mutableStateOf<Long?>(null) }
    var selected by remember { mutableStateOf<Int?>(null) }
    var renaming by remember { mutableStateOf<Int?>(null) }
    var imageOk by remember(waveformUrl) { mutableStateOf(false) }
    // A saved move shows in place until the re-applied catalog catches up.
    LaunchedEffect(starts, storedSideEnd) { pending = null }
    val shown = dragging ?: pending

    val effStarts = starts.mapIndexed { i, s -> if (shown?.first == i) shown.second else s }
    val sideEnd = if (shown?.first == starts.size) shown.second else storedSideEnd

    fun save(i: Int, ms: Long) {
        if (!editable) return
        val raw = rawSegments ?: return
        val edit = AlbumBoundaryEdits.saveBoundary(editsStore.albumEdit(album.id), raw, i, ms) ?: return
        pending = i to ms
        scope.launch { editsStore.setAlbumEditIo(album.id, edit) }
        DiagLog.shared?.telemetry("action", "album boundary edit album=${album.id} index=$i ms=$ms")
    }

    fun play(atFileMs: Long) {
        if (isLoaded && sequencer.seekAlbumFile(atFileMs)) return
        val i = AlbumBoundaryEdits.indexAt(atFileMs, starts)
        if (i >= trackList.size) return
        val into = maxOf(0L, atFileMs - starts[i])
        if (into > 0) sequencer.cueNextStart(trackList[i], into)
        playFrom(i, into)
    }

    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Album Waveform", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(
                AlbumBoundaryEdits.readout(dragging, scrubMs, starts.size, total) { ms -> title(AlbumBoundaryEdits.indexAt(ms, starts)) },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.testTag("album-waveform-readout"),
            )
        }

        BoxWithConstraints(Modifier.fillMaxWidth().height(HANDLE_BAND + WAVE_HEIGHT + TITLE_BAND).clipToBounds().testTag("album-waveform")) {
            val wPx = with(density) { maxWidth.toPx() }.coerceAtLeast(1f)
            val bandPx = with(density) { HANDLE_BAND.toPx() }
            fun x(ms: Long) = ms.coerceIn(0L, total).toFloat() / total * wPx
            val ends = effStarts.indices.map { i ->
                when {
                    i == effStarts.lastIndex -> sideEnd
                    shown?.first == i + 1 -> effStarts[i + 1] // a moved start ends the previous song
                    else -> minOf(endOf(i, starts), effStarts[i + 1])
                }
            }

            // The waveform image fills the whole side; a placeholder shows until it lands.
            Box(Modifier.offset(y = HANDLE_BAND).fillMaxWidth().height(WAVE_HEIGHT).background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))) {
                if (waveformUrl != null) {
                    AsyncImage(
                        model = waveformUrl,
                        contentDescription = null,
                        contentScale = ContentScale.FillBounds,
                        onSuccess = { imageOk = true },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                if (!imageOk) {
                    Text(
                        if (fileKey == null) "Waveform appears after the album's first play" else "Loading waveform…",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
            }

            val fg = MaterialTheme.colorScheme.onSurface
            val accent = MaterialTheme.colorScheme.primary
            val dim = MaterialTheme.colorScheme.onSurfaceVariant
            Canvas(Modifier.fillMaxSize()) {
                val waveH = WAVE_HEIGHT.toPx()
                val top = HANDLE_BAND.toPx()
                effStarts.forEachIndexed { i, s ->
                    val rx = x(s)
                    val rw = maxOf(1f, x(ends[i]) - rx)
                    val c = keyColor(i)
                    drawRect(c.copy(alpha = 0.26f), Offset(rx, top), Size(rw, waveH))
                    drawRect(c, Offset(rx, top), Size(rw, 3.dp.toPx()))
                }
                for (i in 0..effStarts.size) {
                    val m = if (i < effStarts.size) effStarts[i] else sideEnd
                    val sel = selected == i
                    val px = x(m)
                    val lineW = (if (sel) 2.dp else 1.dp).toPx()
                    drawRect(if (sel) accent else fg.copy(alpha = 0.55f), Offset(px - lineW / 2, top), Size(lineW, waveH))
                    if (editable) drawCircle(if (sel) accent else dim, 6.dp.toPx(), Offset(px, top - 8.dp.toPx()))
                }
                (scrubMs ?: playhead)?.let { p ->
                    drawRect(fg, Offset(x(p) - 1.dp.toPx(), top), Size(2.dp.toPx(), waveH))
                }
            }
            effStarts.forEachIndexed { i, s ->
                val rw = maxOf(1f, x(ends[i]) - x(s))
                Text(
                    title(i),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    fontSize = 10.sp,
                    modifier = Modifier
                        .offset { IntOffset((x(s) + 3.dp.toPx()).roundToInt(), (bandPx + WAVE_HEIGHT.toPx() + 2.dp.toPx()).roundToInt()) }
                        .width(with(density) { maxOf(0f, rw - 6.dp.toPx()).toDp() }),
                )
            }

            // Gestures. Latest-state holders so the pointer block (keyed on Unit) never goes stale.
            val onTap by rememberUpdatedState<(Offset) -> Unit> { p ->
                if (p.y < bandPx) {
                    selected = if (editable) AlbumBoundaryEdits.nearestHandle(p.x, effStarts, sideEnd, total, wPx) else null
                } else {
                    selected = null
                    play(AlbumBoundaryEdits.msAt(p.x, wPx, total))
                }
            }
            val onDouble by rememberUpdatedState<(Offset) -> Unit> { p ->
                if (p.y >= bandPx) renaming = AlbumBoundaryEdits.indexAt(AlbumBoundaryEdits.msAt(p.x, wPx, total), starts)
            }
            val onDragBegin by rememberUpdatedState<(Offset, Offset) -> Unit> { down, now ->
                val h = if (down.y < bandPx && editable) AlbumBoundaryEdits.nearestHandle(down.x, effStarts, sideEnd, total, wPx) else null
                if (h != null) dragging = h to AlbumBoundaryEdits.clamp(h, AlbumBoundaryEdits.msAt(now.x, wPx, total), effStarts, sideEnd, total)
                else scrubMs = AlbumBoundaryEdits.msAt(now.x, wPx, total)
            }
            val onDragMove by rememberUpdatedState<(Offset) -> Unit> { now ->
                val d = dragging
                if (d != null) dragging = d.first to AlbumBoundaryEdits.clamp(d.first, AlbumBoundaryEdits.msAt(now.x, wPx, total), effStarts, sideEnd, total)
                else scrubMs = AlbumBoundaryEdits.msAt(now.x, wPx, total)
            }
            val onDragEnd by rememberUpdatedState<(Offset) -> Unit> { now ->
                val d = dragging
                if (d != null) {
                    dragging = null
                    selected = d.first
                    save(d.first, d.second)
                } else {
                    scrubMs = null
                    play(AlbumBoundaryEdits.msAt(now.x, wPx, total))
                }
            }

            Box(
                Modifier.fillMaxSize().pointerInput(Unit) {
                    val slop = viewConfiguration.touchSlop
                    val doubleTapMs = viewConfiguration.doubleTapTimeoutMillis
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        var dragStarted = false
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch: PointerInputChange = ev.changes.firstOrNull { it.id == down.id } ?: return@awaitEachGesture
                            if (ch.changedToUp()) {
                                if (dragStarted) {
                                    ch.consume()
                                    onDragEnd(ch.position)
                                    return@awaitEachGesture
                                }
                                // Handle band: act at once (no rename there). Waveform area: wait for a second tap
                                // (double-tap = rename), else the single tap acts.
                                if (down.position.y < bandPx) {
                                    onTap(down.position)
                                    return@awaitEachGesture
                                }
                                val second = withTimeoutOrNull(doubleTapMs) { awaitFirstDown(requireUnconsumed = false) }
                                if (second == null) {
                                    onTap(down.position)
                                } else {
                                    val up = waitForUpOrCancellation()
                                    if (up != null && (up.position - down.position).getDistance() <= slop * 4) {
                                        up.consume()
                                        onDouble(down.position)
                                    } else {
                                        onTap(down.position)
                                    }
                                }
                                return@awaitEachGesture
                            }
                            if (!dragStarted) {
                                // Someone else (the page scroll) took the gesture.
                                if (ch.isConsumed) return@awaitEachGesture
                                val d = ch.position - down.position
                                if (d.getDistance() >= slop) {
                                    // Decide BEFORE consuming: a vertical pan belongs to the LazyColumn.
                                    if (AlbumBoundaryEdits.isVerticalPan(d.x, d.y)) return@awaitEachGesture
                                    dragStarted = true
                                    onDragBegin(down.position, ch.position)
                                    ch.consume()
                                }
                            } else {
                                ch.consume()
                                onDragMove(ch.position)
                            }
                        }
                    }
                },
            )
        }

        val sel = selected
        if (sel != null && editable) {
            val isEnd = sel == starts.size
            val current = if (isEnd) storedSideEnd else starts[sel]
            Column(Modifier.testTag("album-wave-nudge")) {
                Text(
                    AlbumBoundaryEdits.nudgeLabelFor(isEnd, title(sel), current),
                    style = MaterialTheme.typography.labelMedium,
                    maxLines = 1,
                )
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    for (d in listOf(-1000, -100, 100, 1000)) {
                        OutlinedButton(onClick = {
                            save(sel, AlbumBoundaryEdits.clamp(sel, current + d, starts, storedSideEnd, total))
                        }) { Text(AlbumBoundaryEdits.nudgeLabel(d)) }
                    }
                    playhead?.let { p ->
                        OutlinedButton(onClick = {
                            save(sel, AlbumBoundaryEdits.clamp(sel, p, starts, storedSideEnd, total))
                        }) { Text("Set to playhead") }
                    }
                    TextButton(onClick = { selected = null }) { Text("✕") }
                }
            }
        }
        Text(
            AlbumBoundaryEdits.hint(editable),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    renaming?.let { idx ->
        val songId = trackList.getOrNull(idx)
        var text by remember(idx) { mutableStateOf(songsById[songId]?.name.orEmpty()) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename track") },
            text = { OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true, label = { Text("Title") }) },
            confirmButton = {
                TextButton(onClick = {
                    renaming = null
                    if (songId != null) {
                        val rawName = graph.catalogRepository.rawSong(songId)?.name ?: songsById[songId]?.name.orEmpty()
                        val edit = AlbumBoundaryEdits.renamed(editsStore.songEdit(songId), rawName, text)
                        if (edit != null) scope.launch { editsStore.setSongEditIo(songId, edit) }
                    }
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } },
        )
    }
}
