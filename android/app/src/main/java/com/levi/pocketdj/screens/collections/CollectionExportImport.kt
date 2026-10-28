package com.levi.pocketdj.screens.collections

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.io.CollectionFile
import com.levi.pocketdj.data.collections.io.ImportKind
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.NavRequestBus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What an Export… menu entry produces: a file name (explicit tail) + a lazy byte producer + MIME. */
class ExportRequest(val fileName: String, val mime: String, val bytes: () -> ByteArray?)

/** Builders for the per-item Export requests (pure: the store does the encoding). */
object CollectionExportRequests {
    fun playlistZip(store: CollectionsStore, id: String, name: String) = ExportRequest(
        CollectionShare.exportFilename(CollectionShare.Kind.PLAYLIST, name), CollectionShare.ZIP_MIME,
    ) { store.exportPlaylistZip(id) }

    fun pocketZip(store: CollectionsStore, id: String, name: String) = ExportRequest(
        CollectionShare.exportFilename(CollectionShare.Kind.POCKET, name), CollectionShare.ZIP_MIME,
    ) { store.exportPocketZip(id) }

    fun playlistCsv(store: CollectionsStore, id: String, name: String) = ExportRequest(
        CollectionShare.exportFilename(CollectionShare.Kind.CSV, name), CollectionShare.CSV_MIME,
    ) { store.exportPlaylistCsv(id) }

    fun pocketCsv(store: CollectionsStore, id: String, name: String) = ExportRequest(
        CollectionShare.exportFilename(CollectionShare.Kind.CSV, name), CollectionShare.CSV_MIME,
    ) { store.exportPocketCsv(id) }

    fun setlistCsv(store: CollectionsStore, id: String, name: String) = ExportRequest(
        CollectionShare.exportFilename(CollectionShare.Kind.CSV, name), CollectionShare.CSV_MIME,
    ) { store.exportSetlistCsv(id) }
}

/**
 * Save-as launcher: `CreateDocument` with the request's FULL file name (explicit `.pdjcollection`), bytes
 * are produced and written off-main after the user picks a destination. Zip and CSV use separate
 * launchers because the MIME is fixed at registration.
 */
class CollectionExporter internal constructor(
    private val start: (ExportRequest) -> Unit,
) {
    fun export(request: ExportRequest) = start(request)
}

/**
 * Pure completion of an export once the picker returned a created document: write [bytes] or, when they are
 * gone (activity recreated while the picker was open) / unwritable, [delete] the empty document SAF already
 * created so no 0-byte file is left behind. Returns the snackbar message.
 */
internal fun completeExport(fileName: String, bytes: ByteArray?, write: (ByteArray) -> Boolean, delete: () -> Unit): String {
    if (bytes == null) {
        delete()
        return "Export was interrupted - please try again"
    }
    return if (write(bytes)) "Exported $fileName" else { delete(); "Couldn't write the file" }
}

private fun finishExport(context: Context, scope: CoroutineScope, fileName: String, bytes: ByteArray?, uri: Uri) {
    scope.launch {
        val msg = withContext(Dispatchers.IO) {
            completeExport(
                fileName, bytes,
                write = { CollectionShare.writeUri(context.contentResolver, uri, it) },
                delete = { runCatching { android.provider.DocumentsContract.deleteDocument(context.contentResolver, uri) } },
            )
        }
        NavRequestBus.postMessage(msg)
    }
}

@Composable
fun rememberCollectionExporter(): CollectionExporter {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // The file name survives activity recreation (rotation / process death while the picker is open); the
    // bytes do not, and finishExport then deletes the created document instead of leaving it empty.
    var pendingName by rememberSaveable { mutableStateOf<String?>(null) }
    val pendingBytes = remember { arrayOfNulls<ByteArray>(1) }
    val onPicked: (Uri?) -> Unit = { uri ->
        val name = pendingName
        val bytes = pendingBytes[0]
        pendingName = null; pendingBytes[0] = null
        if (uri != null) finishExport(context, scope, name ?: "export", bytes, uri)
    }
    val zip = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(CollectionShare.ZIP_MIME), onPicked)
    val csv = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(CollectionShare.CSV_MIME), onPicked)
    return remember(zip, csv) {
        CollectionExporter { req ->
            // Build the bytes BEFORE the picker so an unavailable item (catalog not loaded / row gone)
            // never creates an empty document.
            scope.launch {
                val bytes = withContext(Dispatchers.IO) { req.bytes() }
                if (bytes == null) {
                    NavRequestBus.postMessage("Nothing to export")
                } else {
                    pendingBytes[0] = bytes; pendingName = req.fileName
                    if (req.mime == CollectionShare.CSV_MIME) csv.launch(req.fileName) else zip.launch(req.fileName)
                }
            }
        }
    }
}

/**
 * Collections-toolbar Import: `OpenDocument` for any file (the picker hides custom extensions behind
 * generic MIMEs), routed by CONTENT in `importAny`; the result posts a snackbar with counts.
 */
@Composable
fun rememberCollectionImporter(): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val graph = remember { AppGraph.get(context) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val msg = withContext(Dispatchers.IO) {
                val bytes = CollectionShare.readUri(context.contentResolver, uri) ?: return@withContext "Couldn't open that file"
                runCatching {
                    if (CollectionFile.detectKind(bytes) == ImportKind.BACKUP) {
                        com.levi.pocketdj.screens.settings.sections.BackupCoordinator.restore(graph, bytes)
                    } else {
                        CollectionShare.summaryMessage(graph.collections.importAny(bytes))
                    }
                }.getOrElse { CollectionShare.failureMessage(it) }
            }
            NavRequestBus.postMessage(msg)
        }
    }
    return remember(launcher) { { launcher.launch(arrayOf("*/*")) } }
}
