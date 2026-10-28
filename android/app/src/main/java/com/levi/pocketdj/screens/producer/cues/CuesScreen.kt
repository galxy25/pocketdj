package com.levi.pocketdj.screens.producer.cues

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.mix.CueSlotColors
import com.levi.pocketdj.screens.mix.MixWaveform
import com.levi.pocketdj.studio.cues.CueSeek
import com.levi.pocketdj.studio.model.StudioCue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Producer > Cues: up to 8 cue points per indexed track. Pick a track (burned first), see its waveform with the
 * cue markers + a live playhead, tap a filled slot to PLAY FROM that cue or an empty slot to SET one at the
 * playhead; long-press a filled slot for rename / nudge / set-to-playhead / delete. The store enforces the cap.
 * A song whose rip is still in flight resolves to live HLS (unseekable): its filled slots are dimmed with a
 * "still ripping" hint rather than silently playing from 0:00.
 */
@Composable
fun CuesScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val store = graph.studioGraph.studioStore
    val catalog by graph.catalogRepository.state.collectAsState()
    val doc by store.state.collectAsState()
    val burns = graph.servicesGraph.burnStore
    var query by remember { mutableStateOf("") }
    var selectedId by remember { mutableStateOf<String?>(null) }
    val songs = catalog.catalog?.songsById?.values.orEmpty()
    val cuedIds = remember(doc.cues) { doc.cues.map { it.songId }.toSet() }

    Column(modifier.fillMaxSize().padding(12.dp).testTag("cues-screen"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(
            query, { query = it }, singleLine = true, label = { Text("Search artist or title") },
            modifier = Modifier.fillMaxWidth().testTag("cue-search"),
        )
        val song = selectedId?.let { catalog.catalog?.songsById?.get(it) }
        when {
            query.isNotBlank() || (song == null && songs.isNotEmpty() && cuedIds.isNotEmpty()) -> {
                val results = remember(query, songs, cuedIds, doc.cues.size) {
                    CueSeek.search(songs, query, { burns.hasLocalFile(it) }, cuedIds)
                }
                if (results.isEmpty()) Text("No tracks match.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                else LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(results, key = { it.id }) { s ->
                        TrackRow(s, doc.cues.count { it.songId == s.id }, burns.hasLocalFile(s.id)) { selectedId = s.id; query = "" }
                    }
                }
            }
            song != null -> SelectedPane(graph, song, Modifier.weight(1f))
            else -> Text(
                "Search for a track above, then tap an empty slot to drop a cue at the playhead (or at 0:00 when nothing is playing) — " +
                    "up to 8 per track. Tap a filled slot to play from that exact spot. Long-press a cue to rename, nudge, or delete it.",
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("cue-empty"),
            )
        }
    }
}

@Composable
private fun TrackRow(song: IndexSong, cueCount: Int, burned: Boolean, onPick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip8().background(MaterialTheme.colorScheme.surfaceVariant).clickable(onClick = onPick)
            .padding(horizontal = 8.dp, vertical = 8.dp).testTag("cue-track-row-${song.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(song.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(song.artist, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (cueCount > 0) Text("⚑ $cueCount", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary, modifier = Modifier.padding(end = 6.dp))
        if (burned) Text("●", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(end = 2.dp))
    }
}

private fun Modifier.clip8() = this.clip(RoundedCornerShape(8.dp))

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SelectedPane(graph: AppGraph, song: IndexSong, modifier: Modifier) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val burns = graph.servicesGraph.burnStore
    val player = graph.playbackController
    val rips = graph.ripsRepository
    val manifest by rips.manifest.collectAsState()
    val doc by store.state.collectAsState()
    val np by player.nowPlaying.collectAsState()
    val preparing by player.preparingSongId.collectAsState()
    val scope = rememberCoroutineScope()

    val entry = manifest[song.id]
    val isBurned = burns.hasLocalFile(song.id)
    val cues = remember(doc.cues, song.id) { store.cues(song.id) }
    val durMs = (song.length?.takeIf { it > 0 } ?: entry?.durationMs?.takeIf { it > 0 } ?: 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    val amReady by produceState(false, song.id) { value = song.appleMusicId != null && player.canSeekAppleMusic() }
    val availability = CueSeek.availability(isBurned, entry != null, song.appleMusicId != null, amReady)
    val seekable = availability == CueSeek.Availability.PLAYABLE
    var notice by remember(song.id) { mutableStateOf<String?>(null) }

    // Playhead (song-relative: ExoPlayer positions are clip-relative; AM reports song-relative).
    val isThis = np?.songId == song.id
    var playhead by remember(song.id) { mutableIntStateOf(0) }
    LaunchedEffect(song.id, isThis) {
        while (isThis) { playhead = runCatching { player.currentPositionMs() }.getOrDefault(0L).coerceIn(0L, durMs.toLong()).toInt(); delay(250) }
    }
    val playheadOrNull = if (isThis) playhead else null

    // Waveform ladder.
    val album = song.albumId?.let { graph.catalogRepository.state.value.catalog?.albumsById?.get(it) }
    val png = entry?.waveform?.let { "${Endpoints.RIPS_BASE.trimEnd('/')}/${it.removePrefix("/")}" }
    val shared = entry != null && (entry.startMs != null || entry.source == "analog")
    val peaks by produceState<FloatArray?>(null, song.id, isBurned) {
        value = if (isBurned && (shared || png == null)) runCatching { MixWaveform.peaksForSong(song.id, song.length?.toInt(), burns) }.getOrNull() else null
    }
    val wave: CueWave = when {
        peaks != null -> CueWave.Peaks(peaks!!)
        shared && png != null -> {
            val crop = CueSeek.analogCrop(
                entry?.startMs, entry?.durationMs,
                manifest.values.filter { it.key == entry?.key }.mapNotNull { e -> val s = e.startMs; val d = e.durationMs; if (s != null && d != null) s + d else null },
                album?.audioDurationSec,
            )
            if (crop != null) CueWave.CroppedPng(png, crop) else CueWave.Peaks(FloatArray(0))
        }
        !shared && png != null -> CueWave.Png(png)
        else -> CueWave.Peaks(FloatArray(0))
    }

    fun startAt(atMs: Int) {
        notice = null
        if (atMs > 0 && !seekable) { notice = "Can’t jump into this track yet — it’s still ripping. Playing from the top."; scope.launch { player.play(song.id, playContext = null) }; return }
        scope.launch {
            val plan = CueSeek.plan(entry?.startMs, entry?.durationMs ?: song.length, atMs)
            val out = player.play(song.id, queueAlbumContext = false, startMs = plan.clipRelativeMs)
            if (out is com.levi.pocketdj.playback.PlayOutcome.Preparing) notice = "Ripping this track first — it will be playable shortly."
        }
    }

    var renameSlot by remember { mutableStateOf<Int?>(null) }
    var renameText by remember { mutableStateOf("") }
    var scrub by remember(song.id) { mutableStateOf<Float?>(null) }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(song.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(song.artist, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (isBurned) Text("On device", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(end = 8.dp))
            Text(CueSeek.stamp(durMs).substringBeforeLast('.'), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelMedium)
        }
        CueTimeline(wave, durMs, cues, playheadOrNull, Modifier.testTag("cue-timeline"), onTap = { ms -> if (seekable || ms == 0) startAt(ms) else scrub = ms.toFloat() / durMs })

        // Transport: play/pause + scrub.
        Row(verticalAlignment = Alignment.CenterVertically) {
            val playing = isThis && np?.isPlaying == true
            IconButton({
                scope.launch { if (playing) player.pause() else if (isThis) player.resume() else startAt(0) }
            }, Modifier.testTag("cue-transport-play")) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play")
            }
            Slider(
                value = scrub ?: CueSeek.fraction(playheadOrNull ?: 0, durMs),
                onValueChange = { scrub = it },
                onValueChangeFinished = {
                    val f = scrub; scrub = null
                    if (f != null && seekable) {
                        val ms = CueSeek.positionAt(f, durMs)
                        if (isThis) scope.launch { player.seekTo(ms.toLong()) } else startAt(ms)
                    }
                },
                enabled = seekable, modifier = Modifier.weight(1f).testTag("cue-transport-scrub"),
            )
        }
        if (!seekable) Text(
            "Still ripping — cue playback unlocks when this track’s rip completes (or after you burn it).",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary, modifier = Modifier.testTag("cue-seek-hint"),
        )
        notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary, modifier = Modifier.testTag("cue-notice")) }
        if (preparing == song.id) Text("Preparing…", style = MaterialTheme.typography.bodySmall)

        // 8-slot grid (4 x 2).
        for (rowSlots in (0 until StudioCue.MAX_SLOTS).chunked(4)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                for (slot in rowSlots) {
                    val cue = cues.firstOrNull { it.slot == slot }
                    SlotCell(
                        slot, cue, seekable, Modifier.weight(1f),
                        onTap = {
                            if (cue != null) { if (seekable) startAt(cue.positionMs) else notice = "Can’t jump to this cue yet — the track is still ripping." }
                            else store.setCue(song.id, slot, playheadOrNull ?: 0)
                        },
                        onRename = { renameSlot = slot; renameText = cue?.name ?: "" },
                        onNudge = { store.nudgeCue(song.id, slot, it) },
                        onSetToPlayhead = playheadOrNull?.let { p -> { store.setCue(song.id, slot, p); Unit } },
                        onDelete = { store.removeCue(song.id, slot) },
                    )
                }
            }
        }
        Text(
            "Play & scrub to find a spot, then tap an empty slot to drop a cue at the playhead · long-press a cue for rename / nudge / delete.",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    renameSlot?.let { slot ->
        AlertDialog(
            onDismissRequest = { renameSlot = null },
            title = { Text("Rename Cue") },
            text = {
                Column {
                    OutlinedTextField(renameText, { renameText = it }, singleLine = true, modifier = Modifier.testTag("cue-rename-field"))
                    Text("A blank name goes back to the slot number.", style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = { TextButton({ store.renameCue(song.id, slot, renameText); renameSlot = null }, Modifier.testTag("cue-rename-save")) { Text("Save") } },
            dismissButton = { TextButton({ renameSlot = null }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SlotCell(
    slot: Int,
    cue: StudioCue?,
    seekable: Boolean,
    modifier: Modifier,
    onTap: () -> Unit,
    onRename: () -> Unit,
    onNudge: (Int) -> Unit,
    onSetToPlayhead: (() -> Unit)?,
    onDelete: () -> Unit,
) {
    val color = Color(CueSlotColors.argb(slot))
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(8.dp)
    Box(modifier) {
        if (cue != null) {
            // Dimmed (not disabled) when unseekable: a disabled control would also swallow the long-press menu.
            Column(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).background(color.copy(alpha = if (seekable) 0.22f else 0.1f), shape).border(1.5.dp, color.copy(alpha = if (seekable) 1f else 0.45f), shape)
                    .combinedClickable(onClick = onTap, onLongClick = { menu = true })
                    .padding(4.dp).testTag("cue-slot-$slot"),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            ) {
                Text(cue.name ?: "Cue ${slot + 1}", style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(CueSeek.stamp(cue.positionMs), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem({ Text("Rename") }, { menu = false; onRename() }, Modifier.testTag("cue-rename-$slot"))
                DropdownMenuItem({ Text("Nudge −${CueSeek.NUDGE_MS} ms") }, { onNudge(-CueSeek.NUDGE_MS) }, Modifier.testTag("cue-nudge-back-$slot"))
                DropdownMenuItem({ Text("Nudge +${CueSeek.NUDGE_MS} ms") }, { onNudge(CueSeek.NUDGE_MS) }, Modifier.testTag("cue-nudge-fwd-$slot"))
                DropdownMenuItem({ Text("Set to playhead") }, { menu = false; onSetToPlayhead?.invoke() }, Modifier.testTag("cue-set-playhead-$slot"), enabled = onSetToPlayhead != null)
                DropdownMenuItem({ Text("Delete") }, { menu = false; onDelete() }, Modifier.testTag("cue-delete-$slot"))
            }
        } else {
            Column(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).border(1.dp, MaterialTheme.colorScheme.outline, shape).clickable(onClick = onTap).padding(4.dp).testTag("cue-slot-$slot"),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            ) {
                Text("+", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Set", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
