package com.levi.pocketdj.screens.collections

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.data.collections.CollectionsStore
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

private fun finishExport(context: Context, scope: CoroutineScope, request: ExportRequest, uri: Uri?) {
    if (uri == null) return
    scope.launch {
        val ok = withContext(Dispatchers.IO) {
            val data = request.bytes() ?: return@withContext null
            CollectionShare.writeUri(context.contentResolver, uri, data)
        }
        NavRequestBus.postMessage(
            when (ok) {
                null -> "Nothing to export"
                true -> "Exported ${request.fileName}"
                false -> "Couldn't write the file"
            },
        )
    }
}

@Composable
fun rememberCollectionExporter(): CollectionExporter {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pending = remember { arrayOfNulls<ExportRequest>(1) }
    val zip = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(CollectionShare.ZIP_MIME)) { uri ->
        pending[0]?.let { finishExport(context, scope, it, uri) }; pending[0] = null
    }
    val csv = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(CollectionShare.CSV_MIME)) { uri ->
        pending[0]?.let { finishExport(context, scope, it, uri) }; pending[0] = null
    }
    return remember(zip, csv) {
        CollectionExporter { req ->
            pending[0] = req
            if (req.mime == CollectionShare.CSV_MIME) csv.launch(req.fileName) else zip.launch(req.fileName)
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
                runCatching { CollectionShare.summaryMessage(graph.collections.importAny(bytes)) }
                    .getOrElse { CollectionShare.failureMessage(it) }
            }
            NavRequestBus.postMessage(msg)
        }
    }
    return remember(launcher) { { launcher.launch(arrayOf("*/*")) } }
}
