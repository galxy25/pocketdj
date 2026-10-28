package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.transfers.TransferRecord
import java.io.File
import java.io.IOException
import java.util.UUID

/** One physical burn root. */
data class BurnRoot(val dir: File, val isUserFolder: Boolean, val treeUri: String? = null)

/**
 * The single burn-root resolver (decision D5/D2). v1 = app-private `filesDir/burns`; a SAF
 * user-folder implementation slots in later (destination must be captured onto the transfer
 * record at enqueue time, never read live in a worker).
 */
interface BurnFolder {
    /** Every reachable root, app root first (iOS `forEachBurnRoot`). */
    fun roots(): List<BurnRoot>

    /** The ACTIVE write root, created if needed; null when unusable. */
    fun activeWritable(): BurnRoot?

    /**
     * The dir an item was actually written to: `wasAppStorage` null/true => app root; false =>
     * the user folder, or null while it is unreachable (the item is then skipped, never pruned).
     */
    fun dirFor(wasAppStorage: Boolean?): File? =
        roots().firstOrNull { it.isUserFolder == (wasAppStorage == false) }?.dir

    /**
     * Best-effort copy of [names] (files in [dir]) into the user's tree when [dir] is the user
     * staging root; no-op otherwise. Never throws (a mirror failure leaves the staged file playable).
     */
    fun mirrorFiles(dir: File, names: List<String>) {}

    /** True when the last [activeWritable] had to ignore a chosen user folder (surface a notice). */
    fun fellBack(): Boolean = false

    /** Sentinel write+delete; false on failure (folder unavailable). */
    fun probeWrite(root: BurnRoot): Boolean = try {
        val sentinel = File(root.dir, ".pdj-burn-probe-${UUID.randomUUID()}")
        sentinel.writeText("ok")
        sentinel.delete()
        true
    } catch (_: IOException) {
        false
    }
}

/** `filesDir/burns/`. */
class AppPrivateBurnFolder(private val dir: File) : BurnFolder {
    override fun roots(): List<BurnRoot> = listOf(BurnRoot(dir, isUserFolder = false))

    override fun activeWritable(): BurnRoot? {
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) return null
        return BurnRoot(dir, isUserFolder = false)
    }
}

/**
 * The SAF document-tree layer (a fake in JVM tests; [com.levi.pocketdj.data.burns.ContentResolverBurnTree]
 * on device). A tree is the user-browsable copy of burns: descriptive mp3 + txt in a folder the
 * user picked (incl. SD card).
 */
interface BurnTree {
    /** Permission still held and the tree still resolves. */
    fun isReachable(): Boolean

    /** Create + delete a sentinel; false on any failure. */
    fun probeWrite(): Boolean

    fun exists(name: String): Boolean

    /** Copy [src] into the tree as [name], replacing any existing child. Throws IOException. */
    fun copyIn(name: String, src: File)
}

/** User's chosen folder (persisted tree URI string), read ONLY at enqueue / UI time, never by a worker. */
interface BurnFolderPrefs {
    fun treeUri(): String?
    fun setTreeUri(uri: String?)
}

/**
 * Where a burn goes, decided ONCE at enqueue and stamped on the transfer record (iOS
 * capture-at-enqueue rule): the worker never re-reads settings.
 */
data class BurnDestination(val wasAppStorage: Boolean, val treeUri: String?)

/**
 * App-private root PLUS an optional SAF user folder. The user root's [BurnRoot.dir] is a local
 * staging dir the app plays from; the tree holds the user-browsable copy (SAF has no File path).
 *
 * READ-PATH resolution never touches the tree (no ContentResolver binder calls on hot paths):
 * the staging root is a local directory, so [roots]/[dirFor] list it whenever it exists, even if
 * the tree is revoked/ejected or the user went back to app storage. Tree reachability gates only
 * NEW writes ([activeWritable]) and the tree mirror ([mirrorFiles]).
 */
class SafBurnFolder(
    private val appDir: File,
    private val userStageDir: File,
    private val prefs: BurnFolderPrefs,
    private val openTree: (String) -> BurnTree?,
) : BurnFolder {
    private val app = AppPrivateBurnFolder(appDir)

    @Volatile private var fellBackFlag = false

    private fun reachableTree(): Pair<String, BurnTree>? {
        val uri = prefs.treeUri() ?: return null
        val tree = openTree(uri) ?: return null
        return if (tree.isReachable()) uri to tree else null
    }

    override fun roots(): List<BurnRoot> {
        val out = ArrayList<BurnRoot>()
        out += BurnRoot(appDir, isUserFolder = false)
        if (userStageDir.isDirectory) out += BurnRoot(userStageDir, isUserFolder = true, treeUri = prefs.treeUri())
        return out
    }

    override fun activeWritable(): BurnRoot? {
        val wanted = prefs.treeUri()
        val chosen = reachableTree()
        if (chosen != null && chosen.second.probeWrite()) {
            if (!userStageDir.isDirectory && !userStageDir.mkdirs() && !userStageDir.isDirectory) {
                fellBackFlag = true
                return app.activeWritable()
            }
            fellBackFlag = false
            return BurnRoot(userStageDir, isUserFolder = true, treeUri = chosen.first)
        }
        fellBackFlag = wanted != null
        return app.activeWritable()
    }

    override fun fellBack(): Boolean = fellBackFlag

    override fun mirrorFiles(dir: File, names: List<String>) {
        if (dir != userStageDir) return
        val tree = prefs.treeUri()?.let(openTree) ?: return
        for (n in names) {
            if (n.isEmpty()) continue
            val f = File(dir, n)
            if (!f.isFile) continue
            try { tree.copyIn(n, f) } catch (_: Exception) { return }
        }
    }

    override fun probeWrite(root: BurnRoot): Boolean {
        if (!root.isUserFolder) return super.probeWrite(root)
        val tree = root.treeUri?.let(openTree) ?: return false
        return tree.probeWrite() && super.probeWrite(root)
    }

    companion object {
        fun destinationOf(root: BurnRoot) = BurnDestination(wasAppStorage = !root.isUserFolder, treeUri = root.treeUri)
    }
}

/** A destination resolved for a worker from the RECORD alone. */
data class ResolvedDestination(
    val dir: File,
    val tree: BurnTree?,
    /** The record to finalize with (wasAppStorage flipped to true on fallback). */
    val record: TransferRecord,
    val fellBack: Boolean,
)

/** Worker-side destination resolution: record in, never settings. */
class BurnDestinationResolver(
    val appDir: File,
    private val userStageDir: File,
    private val openTree: (String) -> BurnTree?,
) {
    fun resolve(record: TransferRecord): ResolvedDestination {
        if (record.wasAppStorage) return ResolvedDestination(appDir, null, record, false)
        val tree = record.burnFolderTreeUri?.let(openTree)
        return if (tree != null && tree.isReachable() && tree.probeWrite()) {
            ResolvedDestination(userStageDir, tree, record, false)
        } else {
            ResolvedDestination(appDir, null, record.copy(wasAppStorage = true), true)
        }
    }
}
