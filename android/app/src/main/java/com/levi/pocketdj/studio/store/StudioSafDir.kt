package com.levi.pocketdj.studio.store

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.OutputStream

/**
 * [StudioDir] over a user-picked Storage Access Framework tree (the Android analogue of an iOS
 * security-scoped bookmark folder). Device-only to verify (SAF permission persistence on real
 * external storage); the reconcile/usage/delete LOGIC that sits on top is JVM-tested via the
 * [StudioDir] seam.
 *
 * Reachability doctrine: [open] returns null unless the persisted tree permission is still held
 * AND the tree root still answers a query — the caller (via [StudioRoots.userDir]) then reads
 * "unreachable => skip, never prune".
 */
class SafStudioDir private constructor(
    private val context: Context,
    private val tree: Uri,
) : StudioDir {
    private val cr get() = context.contentResolver
    private val treeDocId: String = DocumentsContract.getTreeDocumentId(tree)

    override val key: String get() = tree.toString()

    private data class Entry(val docId: String, val name: String, val size: Long, val isDir: Boolean)

    @Volatile private var cache: Pair<Long, List<Entry>>? = null

    /** Short-lived listing cache so a pass (usage / reconcile) isn't O(N^2) provider queries. */
    private fun entries(): List<Entry> {
        val c = cache
        val nowMs = System.currentTimeMillis()
        if (c != null && nowMs - c.first < CACHE_MS) return c.second
        return queryEntries().also { cache = nowMs to it }
    }

    /** Lists the tree; THROWS [StudioDirUnavailableException] on any failure (never "empty"). */
    private fun queryEntries(): List<Entry> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeDocId)
        val out = ArrayList<Entry>()
        try {
            val cursor = cr.query(
                children,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null, null, null,
            ) ?: throw StudioDirUnavailableException("null cursor for $tree")
            cursor.use { c ->
                while (c.moveToNext()) {
                    out += Entry(
                        c.getString(0), c.getString(1) ?: "", if (c.isNull(2)) 0L else c.getLong(2),
                        c.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR,
                    )
                }
            }
        } catch (e: StudioDirUnavailableException) {
            throw e
        } catch (e: Exception) {
            throw StudioDirUnavailableException("listing failed for $tree", e)
        }
        return out
    }

    /** Point lookups degrade to "not found" on failure; reconcile never uses them (it uses [list]). */
    private fun find(name: String): Entry? {
        if (!StudioFolders.isBareName(name)) return null
        return try { entries().firstOrNull { !it.isDir && it.name == name } } catch (_: StudioDirUnavailableException) { null }
    }

    private fun docUri(e: Entry): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, e.docId)

    override fun exists(name: String) = find(name) != null
    override fun list(): List<String> = entries().filter { !it.isDir }.map { it.name }
    override fun length(name: String) = find(name)?.size ?: 0L
    override fun delete(name: String): Boolean {
        val e = find(name) ?: return false
        cache = null
        return try { DocumentsContract.deleteDocument(cr, docUri(e)) } catch (_: Exception) { false }
    }

    override fun isWritable(): Boolean =
        cr.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }

    override fun resolve(name: String): StudioFileRef? = find(name)?.let { StudioFileRef(null, docUri(it).toString()) }

    override fun openOutput(name: String): OutputStream? {
        if (!StudioFolders.isBareName(name)) return null
        return try {
            cache = null
            find(name)?.let { DocumentsContract.deleteDocument(cr, docUri(it)) }
            cache = null
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, treeDocId)
            val created = DocumentsContract.createDocument(cr, parent, mimeFor(name), name) ?: return null
            // The provider may de-dupe ("x (1).m4a") or fix the extension: a record whose fileName
            // matches nothing would be pruned later, so refuse a renamed result.
            if (displayName(created) != name) {
                try { DocumentsContract.deleteDocument(cr, created) } catch (_: Exception) {}
                return null
            }
            cr.openOutputStream(created, "wt")
        } catch (_: Exception) {
            null
        }
    }

    private fun displayName(doc: Uri): String? = try {
        cr.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (_: Exception) { null }

    private fun mimeFor(name: String) = when (name.substringAfterLast('.', "")) {
        "m4a" -> "audio/mp4"
        "wav" -> "audio/wav"
        "sf2" -> "application/octet-stream"
        else -> "application/octet-stream"
    }

    companion object {
        private const val CACHE_MS = 1500L

        /** null when the permission was revoked / the tree no longer answers — i.e. UNREACHABLE. */
        fun open(context: Context, treeUri: String?): SafStudioDir? {
            if (treeUri.isNullOrEmpty()) return null
            return try {
                val tree = Uri.parse(treeUri)
                val held = context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
                if (!held) return null
                val dir = SafStudioDir(context, tree)
                val root = DocumentsContract.buildDocumentUriUsingTree(tree, dir.treeDocId)
                val alive = context.contentResolver.query(
                    root, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null,
                )?.use { it.moveToFirst() } == true
                if (alive) dir else null
            } catch (_: Exception) {
                null
            }
        }
    }
}
