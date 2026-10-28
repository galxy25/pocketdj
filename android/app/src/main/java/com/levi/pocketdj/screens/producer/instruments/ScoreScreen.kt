package com.levi.pocketdj.screens.producer.instruments

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.engine.SynthVoice
import com.levi.pocketdj.studio.engine.TakeRenderException
import com.levi.pocketdj.studio.midi.SmfWriter
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.score.ScorePdf
import com.levi.pocketdj.studio.score.ScoreQuantizer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Pure copy/naming helpers for the Score screen's exports. */
object ScoreExport {
    /** Export base name: the take's name with filesystem-hostile separators stripped; blank => "Instrumental". */
    fun baseName(take: StudioTake): String {
        val raw = take.name.ifEmpty { "Untitled instrumental" }
        val cleaned = raw.replace("/", "-").replace(":", "-").replace(Regex("[\\\\*?\"<>|]"), "-").trim()
        return cleaned.ifEmpty { "Instrumental" }
    }

    fun displayTitle(take: StudioTake) = take.name.ifEmpty { "Untitled instrumental" }

    /** Staff 1's section title: the take name alone for a single-staff take, numbered once overdub staffs exist. */
    fun primaryStaffTitle(take: StudioTake): String =
        if (take.extraStaffs.isNullOrEmpty()) displayTitle(take) else "${displayTitle(take)} · Staff 1 · ${take.instrument.displayName}"

    /** Copy [bytes]/[src] into the share cache and open the system share sheet through the app FileProvider. */
    suspend fun share(ctx: Context, name: String, ext: String, mime: String, bytes: ByteArray? = null, src: File? = null) {
        val uri = withContext(Dispatchers.IO) {
            val dir = File(ctx.cacheDir, "shared-scores").also { it.mkdirs() }
            val f = File(dir, "$name.$ext")
            if (bytes != null) f.writeBytes(bytes) else src!!.copyTo(f, overwrite = true)
            FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", f)
        }
        val send = Intent(Intent.ACTION_SEND).apply { type = mime; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        ctx.startActivity(Intent.createChooser(send, "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/**
 * The saved-take Score screen (iOS `StudioScoreView`): the editable notation of one take with Replay (cursor + played / current
 * highlighting, tap-to-seek), Edit / Done / Cancel (Cancel restores every staff's pre-edit stream; a derive-from-raw staff goes back to
 * editedEvents = nil via revert), and exports: PDF (vector), MIDI (RAW events), Audio (rendered m4a).
 */
@Composable
fun ScoreScreen(graph: AppGraph, takeId: String, onBack: () -> Unit, onNeedPacks: () -> Unit, modifier: Modifier = Modifier) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val engine = studio.instrumentEngine
    val packs = studio.instrumentPacks
    val doc by store.state.collectAsState()
    val es by engine.state.collectAsState()
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val take = remember(doc, takeId) { store.take(takeId) }

    var editing by remember { mutableStateOf(false) }
    var preEdit by remember { mutableStateOf<Map<String, List<StudioNoteEvent>?>>(emptyMap()) }
    var message by remember { mutableStateOf<String?>(null) }
    var parked by remember { mutableStateOf<Int?>(null) }
    var preparing by remember { mutableStateOf(false) }
    var exportingAudio by remember { mutableStateOf(false) }
    var replayingId by remember { mutableStateOf<String?>(null) }

    DisposableEffect(Unit) { onDispose { if (replayingId == takeId) engine.stopReplay() } }

    if (take == null) {
        Column(modifier.fillMaxSize().padding(16.dp)) {
            IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text("That take is gone.", Modifier.testTag("score-missing"))
        }
        return
    }
    val ours = es.isReplaying && replayingId == takeId

    suspend fun play(t: StudioTake, fromMs: Int) {
        val key = t.instrument
        val bank = packs.localBankFile(key)
        if (bank == null || packs.pack(key) == null) { message = "Download the ${key.displayName} pack to hear this take."; onNeedPacks(); return }
        preparing = true
        val extras = ArrayList<Pair<SynthVoice, List<StudioNoteEvent>>>()
        var handed = false
        try {
            if (engine.state.value.currentInstrument != key && !engine.loadInstrument(key, bank)) { message = "Couldn't load the ${key.displayName} sound bank."; return }
            for (s in t.extraStaffs.orEmpty()) {
                val b = packs.localBankFile(s.instrument) ?: continue
                val v = withContext(Dispatchers.Default) {
                    val nv = try { engine.createVoice() } catch (e: Exception) { null } catch (e: LinkageError) { null }
                    if (nv != null && !(runCatching { nv.load(b.path) && nv.setPreset(0, s.instrument.gmProgram) }.getOrDefault(false))) { runCatching { nv.close() }; null } else nv
                }
                if (v != null) extras.add(v to s.scoreEvents)
            }
            if (engine.replay(t.scoreEvents, fromMs, extras)) { handed = true; replayingId = t.id; message = null } else message = "Nothing to play in this take."
        } finally {
            if (!handed) extras.forEach { runCatching { it.first.close() } }
            preparing = false
        }
    }

    /** Where Replay resumes: the cursor (a tap-to-seek / left-off position), or the top once played through. */
    fun resumeMs(t: StudioTake): Int {
        val end = t.allScoreEvents.maxOfOrNull { it.offMs } ?: 0
        val p = engine.replayPositionMs() ?: parked ?: 0
        return if (p >= end) 0 else p.coerceAtLeast(0)
    }

    val clock: () -> Int? = { if (replayingId == takeId) engine.replayPositionMs() ?: parked else parked }
    val seek: (Int) -> Unit = { ms ->
        parked = ms
        if (ours) scope.launch { play(take, ms) }
    }

    Column(modifier.fillMaxSize().testTag("score-screen")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton({ if (ours) engine.stopReplay(); onBack() }, Modifier.testTag("score-back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to takes") }
            Text(ScoreExport.displayTitle(take), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = { if (ours) { parked = engine.replayPositionMs(); engine.stopReplay() } else { if (es.isReplaying) engine.stopReplay(); scope.launch { play(take, resumeMs(take)) } } },
                    enabled = take.allScoreEvents.isNotEmpty() && !preparing, modifier = Modifier.testTag("score-replay"),
                ) { Text(if (preparing) "Preparing…" else if (ours) "Stop" else "Replay") }
                if (!editing) {
                    OutlinedButton({
                        // Snapshot EVERY staff's edit state for Cancel ("" = the primary staff).
                        preEdit = buildMap { put("", take.editedEvents); take.extraStaffs.orEmpty().forEach { put(it.id, it.editedEvents) } }
                        if (ours) engine.stopReplay()
                        editing = true
                    }, modifier = Modifier.testTag("score-edit")) { Text("Edit") }
                } else {
                    OutlinedButton({ editing = false }, modifier = Modifier.testTag("score-done")) { Text("Done") }
                    OutlinedButton({
                        when (val a = CancelAction.forSnapshot(preEdit[""])) { is CancelAction.Set -> store.setTakeEvents(takeId, a.events); CancelAction.Revert -> store.revertTakeEdits(takeId) }
                        for (s in take.extraStaffs.orEmpty()) when (val a = CancelAction.forSnapshot(preEdit[s.id])) {
                            is CancelAction.Set -> store.setStaffEvents(takeId, s.id, a.events)
                            CancelAction.Revert -> store.revertStaffEdits(takeId, s.id)
                        }
                        editing = false
                    }, modifier = Modifier.testTag("score-cancel")) { Text("Cancel") }
                }
                OutlinedButton({
                    exportingAudio = true
                    scope.launch {
                        try {
                            val f = studio.takeFiler.ensureAudio(store.take(takeId) ?: take) { packs.localBankFile(it) }
                            if (f == null) message = "Couldn't render this instrumental's audio." else ScoreExport.share(ctx, ScoreExport.baseName(take), "m4a", "audio/mp4", src = f)
                        } catch (e: TakeRenderException.BankMissing) { message = "Download the ${e.instrument.displayName} pack to export this instrumental's audio."; onNeedPacks()
                        } catch (e: TakeRenderException.EmptyTake) { message = "This instrumental has no notes to render."
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e
                        } catch (e: Throwable) { message = "Couldn't render this instrumental's audio. Try again, or re-download the ${take.instrument.displayName} pack."
                        } finally { exportingAudio = false }
                    }
                }, enabled = !exportingAudio && take.allScoreEvents.isNotEmpty(), modifier = Modifier.testTag("score-export-audio")) { Text(if (exportingAudio) "Rendering…" else "Audio") }
                OutlinedButton({
                    val t = store.take(takeId) ?: take
                    scope.launch {
                        val bytes = withContext(Dispatchers.Default) { ScorePdf.makePdf(ScoreQuantizer.quantize(t.scoreEvents, t.bpm, t.instrument), ScoreExport.displayTitle(t), t.instrument) }
                        if (bytes.isEmpty()) message = "Couldn't build the PDF." else ScoreExport.share(ctx, ScoreExport.baseName(t), "pdf", "application/pdf", bytes = bytes)
                    }
                }, modifier = Modifier.testTag("score-export-pdf")) { Text("PDF") }
                OutlinedButton({
                    val t = store.take(takeId) ?: take
                    // RAW/effective events (spec 7): the PDF is the readable simplification, MIDI is the faithful stream a DAW ingests.
                    scope.launch { ScoreExport.share(ctx, ScoreExport.baseName(t), "mid", "audio/midi", bytes = SmfWriter.write(t.scoreEvents, t.bpm, t.instrument)) }
                }, modifier = Modifier.testTag("score-export-midi")) { Text("MIDI") }
            }
            message?.let { Text(it, Modifier.testTag("score-message"), color = MaterialTheme.colorScheme.onSurfaceVariant) }

            ScoreEditor(
                events = take.scoreEvents, bpm = take.bpm, instrument = take.instrument, title = ScoreExport.primaryStaffTitle(take), editing = editing,
                onEdit = { store.setTakeEvents(takeId, it) }, positionMs = clock, onSeek = seek, tagPrefix = "score",
            )
            // Overdub staffs 2..4: the SAME editor surface, one section per staff, all on the one score clock.
            take.extraStaffs.orEmpty().forEachIndexed { i, staff ->
                Text("Staff ${i + 2} · ${staff.instrument.displayName}", style = MaterialTheme.typography.titleSmall)
                ScoreEditor(
                    events = staff.scoreEvents, bpm = take.bpm, instrument = staff.instrument, title = "Staff ${i + 2} · ${staff.instrument.displayName}", editing = editing,
                    onEdit = { store.setStaffEvents(takeId, staff.id, it) }, positionMs = clock, onSeek = seek, tagPrefix = "score-staff-$i",
                )
            }
            Text("${take.instrument.displayName} · ${com.levi.pocketdj.screens.producer.common.StudioFmt.trim(take.bpm)} BPM", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
