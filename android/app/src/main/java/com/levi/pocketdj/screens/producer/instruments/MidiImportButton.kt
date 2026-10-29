package com.levi.pocketdj.screens.producer.instruments

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.midi.MidiImport
import com.levi.pocketdj.studio.midi.MidiImportException
import com.levi.pocketdj.studio.model.InstrumentKey
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure result copy for the import button (JVM-testable). */
object MidiImportCopy {
    const val GENERIC_FAILURE = "Couldn't import that MIDI file."
    fun success(takeName: String) = "Imported “$takeName”."
}

/**
 * "Import MIDI" -> `.mid` becomes a take on the current instrument (piano when none is loaded). Shared by the
 * Takes list and the main Instruments Play section (Score view placement skipped; iOS StudioInstrumentsView parity).
 * [onMessage] receives the success / failure line; [onNeedPacks] fires when the failing instrument has no bank.
 */
@Composable
fun MidiImportButton(
    graph: AppGraph,
    onMessage: (String) -> Unit,
    onNeedPacks: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String = "take-import-midi",
) {
    val studio = graph.studioGraph
    val engine = studio.instrumentEngine
    val packs = studio.instrumentPacks
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var importing by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        importing = true
        scope.launch {
            try {
                val key = engine.state.value.currentInstrument ?: InstrumentKey.PIANO
                val (bytes, fileName) = withContext(Dispatchers.IO) {
                    val b = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw MidiImportException(MidiImport.CANNOT_OPEN)
                    val n = ctx.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                    b to n
                }
                val t = MidiImport.importTake(bytes, fileName, key, "Imported MIDI", studio.takeFiler, packs.localBankFile(key))
                onMessage(MidiImportCopy.success(t.name))
            } catch (e: MidiImportException) {
                onMessage(e.message ?: MidiImportCopy.GENERIC_FAILURE)
                if (packs.localBankFile(engine.state.value.currentInstrument ?: InstrumentKey.PIANO) == null) onNeedPacks()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                onMessage(MidiImportCopy.GENERIC_FAILURE)
            } finally { importing = false }
        }
    }
    TextButton(
        onClick = { launcher.launch(arrayOf("audio/midi", "audio/x-midi", "audio/mid", "application/octet-stream")) },
        enabled = !importing, modifier = modifier.testTag(tag),
    ) { Text(if (importing) "Importing…" else "Import MIDI") }
}
