package com.levi.pocketdj.data.burns

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.IOException
import java.util.UUID

/** [BurnTree] over a SAF tree URI via [DocumentsContract] (no androidx.documentfile dependency). */
class ContentResolverBurnTree(private val context: Context, private val treeUri: Uri) : BurnTree {
    private val cr: ContentResolver get() = context.contentResolver

    private val rootDocUri: Uri by lazy {
        DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
    }

    /** Persisted grant still present AND the root document still answers. */
    override fun isReachable(): Boolean = try {
        val granted = cr.persistedUriPermissions.any { it.uri == treeUri && it.isWritePermission }
        granted && cr.query(rootDocUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)
            ?.use { it.moveToFirst() } == true
    } catch (_: Exception) {
        false
    }

    private fun childUri(name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        cr.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(0))
            }
        }
        return null
    }

    override fun exists(name: String): Boolean = try { childUri(name) != null } catch (_: Exception) { false }

    override fun probeWrite(): Boolean = try {
        val name = ".pdj-burn-probe-${UUID.randomUUID()}"
        val doc = DocumentsContract.createDocument(cr, rootDocUri, "application/octet-stream", name)
        if (doc == null) false else {
            cr.openOutputStream(doc)?.use { it.write("ok".toByteArray()) }
            DocumentsContract.deleteDocument(cr, doc)
            true
        }
    } catch (_: Exception) {
        false
    }

    override fun copyIn(name: String, src: File) {
        try {
            childUri(name)?.let { DocumentsContract.deleteDocument(cr, it) }
            val mime = if (name.endsWith(".mp3")) "audio/mpeg" else "text/plain"
            val doc = DocumentsContract.createDocument(cr, rootDocUri, mime, name)
                ?: throw IOException("could not create $name in the burn folder")
            val out = cr.openOutputStream(doc, "wt") ?: throw IOException("could not open $name")
            out.use { o -> src.inputStream().use { it.copyTo(o) } }
        } catch (e: IOException) {
            throw e
        } catch (e: Exception) {
            throw IOException(e.message ?: "burn folder write failed", e)
        }
    }
}

/** SharedPreferences-backed chosen tree (read at enqueue / UI time only). */
class SharedPrefsBurnFolderPrefs(private val context: Context) : BurnFolderPrefs {
    private val prefs get() = context.getSharedPreferences("pdj-burn-folder", Context.MODE_PRIVATE)
    override fun treeUri(): String? = runCatching { prefs.getString("treeUri", null) }.getOrNull()
    override fun setTreeUri(uri: String?) {
        runCatching { prefs.edit().apply { if (uri == null) remove("treeUri") else putString("treeUri", uri) }.apply() }
    }
}
