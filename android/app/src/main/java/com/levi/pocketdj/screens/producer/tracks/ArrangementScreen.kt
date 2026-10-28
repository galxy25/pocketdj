package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameMillis
import android.widget.Toast
import com.levi.pocketdj.studio.engine.MultitrackPlayer
import com.levi.pocketdj.studio.engine.PlayOutcome
import kotlinx.coroutines.launch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.screens.producer.common.WaveformMath
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.store.ArrangerMath
import com.levi.pocketdj.studio.store.TrimSession
import com.levi.pocketdj.studio.engine.ArrangerGridAnalyzer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Surface
import androidx.compose.ui.draw.alpha
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * An open arrangement: header (back / name / menu / + Track), a collapsible transport (cursor time, tempo,
 * zoom, follow), then the arranger: fixed track headers beside ONE horizontally-scrolling column (beat
 * ruler over the clip lanes) with a full-height seek cursor. [playheadMs] is the live position when a
 * multitrack player is running (the player lands in a later package); null shows the tap-set seek cursor.
 */
@Composable
fun ArrangementScreen(
    graph: AppGraph,
    actions: TracksActions,
    arrangementId: String,
    onBack: () -> Unit,
    playheadMs: Int? = null,
    modifier: Modifier = Modifier,
    player: MultitrackPlayer = remember(graph) { graph.studioGraph.multitrackPlayer },
) {
    val ctx = LocalContext.current
    val store = actions.store
    val doc by produceState(store.state.value, store) { store.state.collect { value = it } }
    val arr = doc.arrangements.firstOrNull { it.id == arrangementId } ?: return
    val prefs = remember { TracksPrefs(ctx) }
    val scope = rememberCoroutineScope()
    val compact = LocalConfiguration.current.screenWidthDp < 600
    val density = LocalDensity.current.density

    var pxPerSec by rememberSaveable(arrangementId) { mutableFloatStateOf(ArrangerMath.DEFAULT_PX_PER_SEC) }
    var follow by remember { mutableStateOf(true) }
    var centerNonce by remember { mutableIntStateOf(0) }
    var cursorMs by rememberSaveable(arrangementId) { mutableIntStateOf(0) }
    var viewportDp by remember { mutableFloatStateOf(0f) }
    var transportCollapsed by remember { mutableStateOf(prefs.transportCollapsed) }
    var pickerTrack by remember { mutableStateOf<String?>(null) }
    var editTrack by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var bpmDialog by remember { mutableStateOf(false) }
    var deleteTrack by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }

    // STU-13: bounce / record-to-master / scissor trim.
    val studio = graph.studioGraph
    val recordPrefs = remember { RecordModePrefs(ctx) }
    var quantized by remember { mutableStateOf(recordPrefs.quantized) }
    var recording by remember { mutableStateOf(false) }
    var bounceOpen by remember { mutableStateOf(false) }
    var busyMsg by remember { mutableStateOf<String?>(null) }
    var trim by remember(arrangementId) { mutableStateOf<TrimSession?>(null) }
    var trimRev by remember { mutableIntStateOf(0) }
    var peaksNonce by remember { mutableIntStateOf(0) }
    val trimming = trim != null

    // STU-12: live playback. The clock is NOT snapshot state; one frame loop samples it into `liveMs`
    // only while this arrangement is playing (so an idle screen never recomposes per frame).
    val playingId by player.playingArrangementId.collectAsState()
    val playing = playingId == arrangementId
    var liveMs by remember { mutableIntStateOf(0) }
    var fxOpen by remember { mutableStateOf(false) }
    val arrLatest by rememberUpdatedState(arr)
    LaunchedEffect(playing) {
        while (playing) {
            withFrameMillis { }
            liveMs = player.positionMs(arrLatest) ?: break
        }
    }
    // Live mix / master FX / loop edits reach the running player; bake-affecting edits re-prime (debounced).
    LaunchedEffect(arr) { if (playing) player.onArrangementChanged(arr) }
    DisposableEffect(arrangementId) {
        // Rotation / split-screen resize recreates the activity: playback must survive that, only a real exit stops it.
        onDispose {
            if (ctx.findActivity()?.isChangingConfigurations != true) {
                player.stop()
                player.recorder.discard() // a take that was never baked has no owner once the screen is gone
            }
        }
    }

    val cursor = ArrangerMath.effectiveCursorMs(playheadMs ?: (if (playing) liveMs else cursorMs), arr.lengthMs)
    val fit = ArrangerMath.fitPx(arr.lengthMs, viewportDp)
    val contentDp = ArrangerMath.timelineWidth(arr.lengthMs, pxPerSec)

    // Per-clip waveform peaks: clips are immutable, so compute once per id.
    val peaks = remember(arrangementId) { mutableStateMapOf<String, FloatArray>() }
    val clipSignature = arr.tracks.flatMap { t -> t.clips.map { it.id } }.joinToString(",")
    LaunchedEffect(clipSignature, peaksNonce) {
        for (t in arr.tracks) for (c in t.clips) {
            if (peaks.containsKey(c.id)) continue
            val f = store.clipFile(c.fileName) ?: continue
            val pcm = runCatching {
                graph.studioGraph.studioRender.decodeRangeBuffer(f.path, c.fileStartMs, if (c.durationMs > 0) c.durationMs else Int.MAX_VALUE / 4)
            }.getOrNull() ?: continue
            peaks[c.id] = withContext(Dispatchers.Default) { WaveformMath.peaks(pcm, 120) }
        }
    }

    // Beat Match needs a beat grid per clip: analyze any clip without one in the background (idempotent).
    LaunchedEffect(clipSignature) { studio.arrangerGridAnalyzer.ensureGrids(arrangementId) }

    fun toast(msg: String) = Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()

    /** Bake the finished master capture into a dated Recording artifact (survives leaving the screen). */
    fun bakeRecording() {
        val capture = player.consumeRecording()
        recording = false
        if (capture == null) return
        busyMsg = "Saving recording…"
        graph.appScope.launch {
            val art = withContext(NonCancellable + Dispatchers.IO) {
                studio.masterRecordingBaker.bakeArtifact(arrangementId, capture, studio.studioRoots.arrangementsDir(), store, ArrangerMath.artifactStamp())
            }
            busyMsg = null
            toast(if (art != null) "Recording saved" else "Nothing was recorded")
        }
    }

    // Playback reached its NATURAL end while recording -> bake. (A manual stop bakes explicitly; a seek/loop/re-prime
    // restart never bumps the nonce, so there is no truncated bake.)
    val recNonce by player.recordingFinishedNonce.collectAsState()
    LaunchedEffect(recNonce) { if (recNonce > 0 && recording) bakeRecording() }

    fun toggleRecord() {
        if (recording) { player.stop(); bakeRecording(); return }
        recording = true
        scope.launch {
            val outcome = player.playOutcome(arrLatest, ArrangerMath.effectiveCursorMs(cursorMs, arrLatest.lengthMs), record = true, quantized = quantized)
            if (outcome == PlayOutcome.NOTHING_TO_PLAY) toast("Nothing to record")
            if (outcome != PlayOutcome.STARTED && !player.isRecording) recording = false
        }
    }

    fun bounce(tracks: List<com.levi.pocketdj.studio.model.StudioTrack>) {
        bounceOpen = false
        if (tracks.isEmpty()) return
        player.stop(); if (recording) bakeRecording()
        busyMsg = "Bouncing…"
        val snapshot = arrLatest
        graph.appScope.launch {
            val art = withContext(NonCancellable) {
                studio.arrangerBouncer.bounceArtifact(snapshot, tracks, studio.studioRoots.arrangementsDir(), store, ArrangerMath.artifactStamp())
            }
            busyMsg = null
            toast(if (art != null) "Bounced ${ArrangerMath.mmss(art.durationMs / 1000.0)}" else "Couldn’t bounce that")
        }
    }

    fun exitTrim() { trim?.cancel(); trim = null; trimRev++ }
    fun enterTrim() {
        if (playing) player.stop()
        trim = TrimSession.begin(arrLatest, cursorMs); trimRev++
    }
    fun saveTrim() {
        val s = trim ?: return
        // Peaks are keyed by clip id and a head/tail-only cut keeps the id: drop + reload so waveforms redraw windowed.
        for (t in arrLatest.tracks) if (t.id in s.selected) t.clips.forEach { peaks.remove(it.id) }
        s.save(store, arrangementId)
        trim = null; trimRev++; peaksNonce++
    }

    Box(modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().testTag("arrangement-screen")) {
        // Header.
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.testTag("tracks-home-back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to arrangements") }
            Text(
                arr.name.ifEmpty { "Untitled" }, Modifier.weight(1f).padding(horizontal = 4.dp).clickableNoRipple { renaming = true },
                style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("tracks-arrangement-menu")) { Icon(Icons.Filled.MoreVert, "Arrangement actions") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename…") }, onClick = { menu = false; renaming = true })
                    DropdownMenuItem(text = { Text("Delete arrangement") }, onClick = { menu = false; deleting = true })
                }
            }
            Button(onClick = { store.addTrack(arrangementId) }, modifier = Modifier.testTag("tracks-add-track")) { Icon(Icons.Filled.Add, null); Text("Track") }
        }
        HorizontalDivider()

        if (arr.tracks.isEmpty()) {
            Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Build a multitrack", style = MaterialTheme.typography.titleMedium)
                Text("Add tracks, then place samples, sequences, loops and instrumentals onto their lanes.", Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(onClick = { store.addTrack(arrangementId) }, modifier = Modifier.testTag("tracks-empty-add-track")) { Text("Add a track") }
            }
        } else {
            TransportBar(
                playing = playing, loopEnabled = arr.loopEnabled, fxOpen = fxOpen, canPlay = arr.allClips.isNotEmpty() && !trimming,
                onPlay = { scope.launch { if (player.playOutcome(arr, cursorMs) == PlayOutcome.NOTHING_TO_PLAY) Toast.makeText(ctx, "Nothing to play", Toast.LENGTH_SHORT).show() } },
                onStop = { player.stop(); if (recording) bakeRecording() },
                onToggleLoop = {
                    if (!arr.loopEnabled && !LoopRegionMath.isUsable(arr.loopStartMs, arr.loopEndMs)) {
                        val (a, b) = LoopRegionMath.defaultRegion(arr.lengthMs, arr.bpm)
                        store.setArrangementLoop(arrangementId, enabled = true, startMs = a, endMs = b)
                    } else store.setArrangementLoop(arrangementId, enabled = !arr.loopEnabled)
                },
                onToggleFx = { fxOpen = !fxOpen },
            )
            if (fxOpen) MasterFxGrid(arr.masterFX, onChange = { store.setArrangementMasterFX(arrangementId, it) })
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                RecordControl(
                    recording, quantized, enabled = arr.allClips.isNotEmpty() && !trimming,
                    onToggle = { toggleRecord() }, onQuantizedChange = { quantized = it; recordPrefs.quantized = it },
                )
                TextButton(onClick = { bounceOpen = true }, enabled = arr.allClips.isNotEmpty() && !trimming, modifier = Modifier.testTag("tracks-bounce")) { Text("Bounce") }
                ScissorButton(trimming, enabled = arr.allClips.isNotEmpty(), onToggle = { if (trimming) exitTrim() else enterTrim() })
                val gridMsg = ArrangerGridAnalyzer.underConstructionMessage(arr)
                FilterChip(
                    selected = arr.beatMatchEnabled, onClick = { store.setArrangementBeatMatch(arrangementId, !arr.beatMatchEnabled) },
                    enabled = gridMsg == null || arr.beatMatchEnabled, label = { Text("Beat Match") },
                    modifier = Modifier.semantics { contentDescription = "Beat Match ${if (arr.beatMatchEnabled) "on" else "off"}" }.testTag("tracks-beat-match"),
                )
            }
            ArrangerGridAnalyzer.underConstructionMessage(arr)?.let {
                Text(it, Modifier.padding(horizontal = 16.dp).testTag("tracks-beat-grid-building"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            trim?.let { s -> TrimToolbar(arr, s, trimRev, onChanged = { trimRev++ }, onCancel = { exitTrim() }, onSave = { saveTrim() }) }
            Transport(
                arr, cursor, compact, transportCollapsed, follow, pxPerSec, fit,
                onToggleCollapse = { transportCollapsed = !transportCollapsed; prefs.transportCollapsed = transportCollapsed },
                onBpm = { bpmDialog = true },
                onZoom = { dir -> pxPerSec = ArrangerMath.stepZoom(dir, pxPerSec, fit) },
                onFollow = { follow = !follow; if (follow) centerNonce++ },
            )
            HorizontalDivider()
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    // Fixed headers, offset below the ruler so they line up with the lanes.
                    Column(verticalArrangement = Arrangement.spacedBy(LANE_GAP.dp)) {
                        Spacer(Modifier.height((RULER_HEIGHT - LANE_GAP).coerceAtLeast(0).dp))
                        arr.tracks.forEachIndexed { i, t ->
                            TrackHeader(
                                t, i,
                                modifier = Modifier.alpha(trimLaneAlpha(trimming, trim?.selected?.contains(t.id) == true)),
                                onEdit = { editTrack = t.id }, onAddClip = { if (!trimming) pickerTrack = t.id },
                                onDuplicate = { store.duplicateTrack(arrangementId, t.id) },
                                onDelete = { deleteTrack = t.id },
                                onMute = { store.setTrackMuted(arrangementId, t.id, it) },
                                onSolo = { store.setTrackSoloed(arrangementId, t.id, it) },
                                onGain = { store.setTrackGain(arrangementId, t.id, it) },
                            )
                        }
                    }
                    FollowTimeline(cursor, pxPerSec, contentDp, follow, centerNonce, { viewportDp = it }, Modifier.weight(1f)) {
                        Column(Modifier.padding(end = 24.dp)) {
                            BeatRuler(arr.bpm, pxPerSec, arr.lengthMs, contentDp, onSeek = { cursorMs = it; centerNonce++; if (playing) scope.launch { player.play(arrLatest, it) } })
                            Box {
                                Column(verticalArrangement = Arrangement.spacedBy(LANE_GAP.dp)) {
                                    arr.tracks.forEachIndexed { i, t ->
                                        @Suppress("UNUSED_VARIABLE") val rev = trimRev
                                        LaneStrip(
                                            trim?.let { s -> t.copy(clips = s.clipsFor(t.id)) } ?: t,
                                            i, pxPerSec, contentDp, peaks, arr.beatMatchEnabled, arr.bpm,
                                            modifier = Modifier.alpha(trimLaneAlpha(trimming, trim?.selected?.contains(t.id) == true)),
                                            onMoveClip = { cid, to -> store.moveClip(arrangementId, t.id, cid, to) },
                                            onRemoveClip = { cid -> peaks.remove(cid); store.removeClip(arrangementId, t.id, cid) },
                                        )
                                    }
                                }
                                BeatGrid(arr.bpm, pxPerSec, contentDp, Modifier.matchParentSize())
                                trim?.let { s -> TrimRegionLayer(s, trimRev, pxPerSec, arr.bpm, arr.lengthMs, onChanged = { trimRev++ }, modifier = Modifier.matchParentSize()) }
                            }
                        }
                        // Cursor overlay + a REAL layout anchor (spacer flow, not an offset) so a semantics
                        // test can read the cursor's true x after follow/zoom.
                        if (!trimming && arr.loopEnabled && LoopRegionMath.isUsable(arr.loopStartMs, arr.loopEndMs)) {
                            LoopRegionOverlay(
                                arr.loopStartMs, arr.loopEndMs, pxPerSec, arr.bpm, arr.lengthMs, arr.tracks.size,
                                onChange = { a, b -> store.setArrangementLoop(arrangementId, startMs = a, endMs = b) },
                            )
                        }
                        CursorOverlay(cursor, pxPerSec, arr.tracks.size)
                    }
                }
            }
        }
    }

        busyMsg?.let { msg ->
            Surface(Modifier.fillMaxSize().alpha(0.85f).clickable(enabled = true) { }, color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(); Text(msg, Modifier.padding(top = 12.dp).testTag("tracks-busy-message"))
                }
            }
        }
    }

    if (bounceOpen) BounceSheet(arr, onBounce = { bounce(it) }, onDismiss = { bounceOpen = false })
    pickerTrack?.let { tid ->
        ClipPickerSheet(doc, actions.stemSource?.songs().orEmpty(), onPick = { pick -> pickerTrack = null; actions.addClip(arrangementId, tid, pick) }, onDismiss = { pickerTrack = null })
    }
    editTrack?.let { tid -> TrackEditSheet(store, arrangementId, tid) { editTrack = null } }
    if (renaming) NameDialog("Rename arrangement", arr.name, "Rename", { renaming = false }) { store.renameArrangement(arrangementId, it); renaming = false }
    if (bpmDialog) BpmDialog(arr.bpm, { bpmDialog = false }) { store.setArrangementBpm(arrangementId, it); bpmDialog = false }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false }, title = { Text("Delete this arrangement?") }, text = { Text("Its tracks and clips are removed.") },
        confirmButton = { TextButton(onClick = { deleting = false; store.deleteArrangement(arrangementId); onBack() }, modifier = Modifier.testTag("tracks-delete-confirm")) { Text("Delete arrangement") } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } },
    )
    deleteTrack?.let { tid ->
        val t = arr.tracks.firstOrNull { it.id == tid }
        AlertDialog(
            onDismissRequest = { deleteTrack = null }, title = { Text("Delete track?") },
            text = { Text("“${t?.name ?: "Track"}” and its ${t?.clips?.size ?: 0} clip(s) are removed.") },
            confirmButton = { TextButton(onClick = { exitTrim(); t?.clips?.forEach { peaks.remove(it.id) }; store.deleteTrack(arrangementId, tid); deleteTrack = null }, modifier = Modifier.testTag("tracks-track-delete-confirm")) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { deleteTrack = null }) { Text("Cancel") } },
        )
    }
}

/**
 * The horizontally-scrolling timeline viewport. Follow: centres the cursor (only past the first
 * half-screenful) whenever cursor / zoom / follow / [centerNonce] change. Split out so the scroll wiring
 * (dp to px, viewport measurement) can be driven by a Compose UI test.
 */
@Composable
internal fun FollowTimeline(
    cursorMs: Int, pxPerSec: Float, contentDp: Float, follow: Boolean, centerNonce: Int,
    onViewportDp: (Float) -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit,
) {
    val density = LocalDensity.current.density
    val hScroll = rememberScrollState()
    var viewportDp by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(cursorMs, pxPerSec, follow, centerNonce, viewportDp, contentDp) {
        if (!follow || viewportDp <= 0f) return@LaunchedEffect
        val target = ArrangerMath.followScrollTarget(cursorMs, pxPerSec, viewportDp, contentDp)
        hScroll.animateScrollTo((target * density).toInt())
    }
    Box(modifier.onSizeChanged { viewportDp = it.width / density; onViewportDp(viewportDp) }.horizontalScroll(hScroll).testTag("tracks-timeline")) { content() }
}

@Composable
internal fun CursorOverlay(cursorMs: Int, pxPerSec: Float, laneCount: Int) {
    val x = cursorMs / 1000f * pxPerSec
    val height = (RULER_HEIGHT + laneCount * LANE_HEIGHT + (laneCount - 1).coerceAtLeast(0) * LANE_GAP).dp
    Row(Modifier.height(height)) {
        Spacer(Modifier.width(x.dp))
        Box(
            Modifier.width(2.dp).height(height).background(MaterialTheme.colorScheme.tertiary)
                .semantics { contentDescription = "Cursor ${ArrangerMath.mmss(cursorMs / 1000.0)}" }.testTag("tracks-cursor-anchor"),
        ) {
            Text(
                ArrangerMath.mmss(cursorMs / 1000.0), Modifier.padding(start = 3.dp).background(MaterialTheme.colorScheme.tertiary),
                fontSize = 8.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onTertiary, maxLines = 1, softWrap = false,
            )
        }
    }
}

@Composable
private fun Transport(
    arr: StudioArrangement, cursorMs: Int, compact: Boolean, collapsed: Boolean, follow: Boolean, pxPerSec: Float, fit: Float,
    onToggleCollapse: () -> Unit, onBpm: () -> Unit, onZoom: (Int) -> Unit, onFollow: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                "${ArrangerMath.mmss(cursorMs / 1000.0)} / ${ArrangerMath.mmss(arr.lengthMs / 1000.0)}",
                style = MaterialTheme.typography.labelLarge, modifier = Modifier.testTag("tracks-time"),
            )
            if (compact) {
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onToggleCollapse, modifier = Modifier.testTag("tracks-transport-collapse").semantics { contentDescription = if (collapsed) "Transport collapsed" else "Transport expanded" }) {
                    Icon(if (collapsed) Icons.Filled.Tune else Icons.Filled.ExpandLess, "Toggle transport")
                }
            } else {
                BpmButton(arr, onBpm); Spacer(Modifier.weight(1f)); ZoomControls(follow, pxPerSec, fit, onZoom, onFollow)
            }
        }
        if (compact && !collapsed) {
            Row(verticalAlignment = Alignment.CenterVertically) { BpmButton(arr, onBpm); Spacer(Modifier.weight(1f)); ZoomControls(follow, pxPerSec, fit, onZoom, onFollow) }
        }
    }
}

@Composable
private fun BpmButton(arr: StudioArrangement, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.testTag("tracks-bpm")) {
        Text("${arr.bpm.toInt()} BPM${if (arr.beatMatchEnabled) " ·BM" else ""}")
    }
}

@Composable
private fun ZoomControls(follow: Boolean, pxPerSec: Float, fit: Float, onZoom: (Int) -> Unit, onFollow: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { onZoom(-1) }, enabled = ArrangerMath.canZoomOut(pxPerSec, fit), modifier = Modifier.testTag("tracks-zoom-out")) { Icon(Icons.Filled.ZoomOut, "Zoom out") }
        IconButton(onClick = { onZoom(+1) }, enabled = ArrangerMath.canZoomIn(pxPerSec), modifier = Modifier.testTag("tracks-zoom-in")) { Icon(Icons.Filled.ZoomIn, "Zoom in") }
        FilledIconToggleButton(checked = follow, onCheckedChange = { onFollow() }, modifier = Modifier.size(36.dp).testTag("tracks-follow").semantics { contentDescription = "Follow cursor ${if (follow) "on" else "off"}" }) {
            Icon(Icons.Filled.MyLocation, null)
        }
    }
}

@Composable
private fun BpmDialog(bpm: Double, onDismiss: () -> Unit, onSet: (Double) -> Unit) {
    var text by remember { mutableStateOf(bpm.toInt().toString()) }
    val v = text.toDoubleOrNull()
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text("Tempo (BPM)") },
        text = {
            Column {
                OutlinedTextField(text, { text = it.filter { c -> c.isDigit() || c == '.' } }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.testTag("tracks-bpm-field"))
                Text("Sets the beat grid and drop snap. Must be 20–300.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(enabled = v != null && v in 20.0..300.0, onClick = { onSet(v!!) }, modifier = Modifier.testTag("tracks-bpm-set")) { Text("Set") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    this.then(Modifier.clickable(interactionSource = null, indication = null, onClick = onClick))

private tailrec fun android.content.Context.findActivity(): android.app.Activity? = when (this) {
    is android.app.Activity -> this
    is android.content.ContextWrapper -> baseContext.findActivity()
    else -> null
}
