package com.levi.pocketdj.shell

import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.data.collections.io.CollectionFile
import com.levi.pocketdj.data.collections.io.ImportKind
import com.levi.pocketdj.data.collections.io.ImportSummary
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Claims `DeepLinkSeams.importCollection` (the dispatcher turns a tapped `.pdjcollection` /
 * `.pocketdj.zip` from Files / Drive / mail into `DeepLink.CollectionFile(uri)` once onboarding is done).
 * The bytes are read and imported OFF-main, then the result is posted as a snackbar message with counts.
 * Android-free: reading and importing are injected so the JVM suite drives it with fakes.
 */
class CollectionImportSeam(
    private val scope: CoroutineScope,
    private val read: (uri: String) -> ByteArray?,
    private val import: (ByteArray) -> ImportSummary,
    private val postMessage: (String) -> Unit = NavRequestBus::postMessage,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** Full-backup restore (collections + sources + favorites). iOS routes `.backup` here, never to `importAny`. */
    private val restoreBackup: ((ByteArray) -> String)? = null,
) {
    fun install(seams: DeepLinkSeams) {
        seams.importCollection = { uri -> open(uri) }
    }

    fun open(uri: String) {
        scope.launch {
            val message = withContext(io) { importNow(uri) }
            postMessage(message)
        }
    }

    /** Synchronous core (also the test entry): returns the user-facing message. */
    fun importNow(uri: String): String {
        val bytes = runCatching { read(uri) }.getOrNull() ?: return "Couldn't open that file"
        return runCatching {
            val restore = restoreBackup
            if (restore != null && CollectionFile.detectKind(bytes) == ImportKind.BACKUP) restore(bytes)
            else CollectionShare.summaryMessage(import(bytes))
        }
            .getOrElse { CollectionShare.failureMessage(it) }
    }
}
