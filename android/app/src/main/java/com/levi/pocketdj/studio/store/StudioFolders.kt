package com.levi.pocketdj.studio.store

import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

/**
 * The five Studio artifact FAMILIES (iOS `StudioFamily`). [rawValue] doubles as the app-managed
 * subdirectory name (`filesDir/studio/<rawValue>/`) — never rename a case.
 */
enum class StudioFamily(
    val rawValue: String,
    /** Samples/loops/sequences/takes are user-relocatable (SAF tree); instruments never are. */
    val supportsUserFolder: Boolean,
    /** Deterministic file-name prefix (`sample-`, `loop-`, ...). */
    val filePrefix: String,
    /** The family's one file extension. Loops are `wav` on Android (LPCM; no CAF writer). */
    val fileExtension: String,
    /** The id namespace embedded in file names; null for instruments (bank slug). */
    val idPrefix: String?,
) {
    SAMPLES("samples", true, "sample-", "m4a", "smp_"),
    LOOPS("loops", true, "loop-", "wav", "lp_"),
    SEQUENCES("sequences", true, "pattern-", "m4a", "ptn_"),
    TAKES("takes", true, "take-", "m4a", "tk_"),
    INSTRUMENTS("instruments", false, "instrument-", "sf2", null),
}

/** A resolved artifact: a [file] when app-private/JVM, always a [uri] string for the player. */
data class StudioFileRef(val file: File?, val uri: String)

/** A directory listing/query FAILED (provider offline, permission revoked): "can't check", never "empty". */
class StudioDirUnavailableException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

/**
 * One physical folder holding a family's artifacts — the app-private dir or a user-picked SAF
 * tree. The seam that keeps reconcile/usage/delete logic JVM-testable and SAF-agnostic.
 */
interface StudioDir {
    /** Stable identity (path / uri) used to visit each root once. */
    val key: String
    fun exists(name: String): Boolean
    /** File names in the folder. THROWS [StudioDirUnavailableException] when the listing itself failed. */
    fun list(): List<String>
    fun length(name: String): Long
    fun delete(name: String): Boolean
    fun isWritable(): Boolean
    /** null when [name] is not present. */
    fun resolve(name: String): StudioFileRef?
    /** Open (create/truncate) [name] for writing; null when impossible. */
    fun openOutput(name: String): OutputStream?
}

/** Where each family's artifacts live right now. */
interface StudioRoots {
    /** App-managed root (always reachable; created on demand). */
    fun appDir(family: StudioFamily): StudioDir

    /**
     * The user-picked root, or null when none is configured OR it is unreachable right now
     * (SAF permission revoked, drive unplugged). null means "can't check" — callers must NEVER
     * treat it as "file is gone".
     */
    fun userDir(family: StudioFamily): StudioDir?

    /**
     * True when the user HAS picked a folder for [family] (even if it is unreachable right now). Lets a writer tell
     * "no folder chosen" (silent app-storage) from "chosen but revoked" (fall back AND tell the user).
     */
    fun userFolderConfigured(family: StudioFamily): Boolean = userDir(family) != null

    /** Arranger clip/bounce audio: app-private, not a family, never user-relocatable. */
    fun arrangementsDir(): File
}

/** [StudioDir] over a plain directory (app-private storage; also the JVM test double). */
class FileStudioDir(val dir: File) : StudioDir {
    override val key: String get() = dir.absolutePath

    private fun file(name: String): File? =
        if (name.isEmpty() || name.contains('/') || name == "." || name == "..") null else File(dir, name)

    override fun exists(name: String) = file(name)?.isFile == true
    override fun list(): List<String> = dir.list()?.toList() ?: emptyList()
    override fun length(name: String) = file(name)?.takeIf { it.isFile }?.length() ?: 0L
    override fun delete(name: String) = file(name)?.delete() == true
    override fun isWritable() = dir.isDirectory && dir.canWrite()
    override fun resolve(name: String): StudioFileRef? =
        file(name)?.takeIf { it.isFile }?.let { StudioFileRef(it, it.toURI().toString()) }

    override fun openOutput(name: String): OutputStream? {
        val f = file(name) ?: return null
        return try {
            dir.mkdirs()
            FileOutputStream(f)
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * [StudioRoots] with app roots under `<appBase>/<family>/` and user roots supplied by
 * [userDirProvider] (SAF on device, a File or null in tests).
 */
class DefaultStudioRoots(
    private val appBase: File,
    private val userConfigured: ((StudioFamily) -> Boolean)? = null,
    private val userDirProvider: (StudioFamily) -> StudioDir? = { null },
) : StudioRoots {
    override fun userFolderConfigured(family: StudioFamily): Boolean =
        family.supportsUserFolder && (userConfigured?.invoke(family) ?: (userDirProvider(family) != null))

    override fun appDir(family: StudioFamily): StudioDir {
        val d = File(appBase, family.rawValue)
        d.mkdirs()
        return FileStudioDir(d)
    }

    override fun userDir(family: StudioFamily): StudioDir? =
        if (family.supportsUserFolder) userDirProvider(family) else null

    override fun arrangementsDir(): File = File(appBase, "arrangements").also { it.mkdirs() }
}

/**
 * Deterministic names + STRICT parse + root-visiting helpers (iOS `StudioFolders`). Files live
 * FLAT in the family folder; user folders are shared with the user's OWN files, so names are only
 * ever recognised through [fileId] — never a loose prefix match.
 */
object StudioFolders {

    /** `<prefix><id>.<ext>` — the ONE minting point. */
    fun fileName(family: StudioFamily, id: String): String = family.filePrefix + id + "." + family.fileExtension

    /** Render-cache name for a sample: the raw name plus a `-r<revision>` stamp (freshness is literal). */
    fun renderedSampleFileName(id: String, revision: Int): String = "sample-$id-r$revision.m4a"

    /** Rendered-audio cache name for an instrumental. */
    fun renderedTakeFileName(id: String, revision: Int): String = "take-$id-r$revision.m4a"

    /**
     * STRICT parser: the id embedded in a family artifact's file name, or null when [name] is not
     * EXACTLY this family's deterministic shape (so `sample-of-my-mix.m4a` never parses).
     */
    fun fileId(family: StudioFamily, name: String): String? {
        val suffix = "." + family.fileExtension
        if (!name.startsWith(family.filePrefix) || !name.endsWith(suffix) || name.contains('/')) return null
        if (name.length < family.filePrefix.length + suffix.length) return null
        var core = name.substring(family.filePrefix.length, name.length - suffix.length)
        val idPrefix = family.idPrefix ?: return core.ifEmpty { null }
        if (family == StudioFamily.SAMPLES || family == StudioFamily.TAKES) {
            val r = core.lastIndexOf("-r")
            if (r >= 0 && r + 2 < core.length && core.substring(r + 2).all { it in '0'..'9' }) {
                core = core.substring(0, r)   // strip the render-cache revision stamp
            }
        }
        if (!core.startsWith(idPrefix) || core.length <= idPrefix.length) return null
        return core
    }

    /** A persisted file name is a bare name; a path separator means a corrupt/hostile document. */
    fun isBareName(name: String): Boolean = name.isNotEmpty() && !name.contains('/')

    /**
     * Resolve an artifact for READING/PLAYBACK against the root it was actually WRITTEN to
     * ([wasUserFolder]). null when the file is gone OR the user root that held it is unreachable.
     */
    fun fileRef(roots: StudioRoots, family: StudioFamily, fileName: String, wasUserFolder: Boolean): StudioFileRef? {
        if (!isBareName(fileName)) return null
        val dir = if (wasUserFolder) roots.userDir(family) ?: return null else roots.appDir(family)
        return dir.resolve(fileName)
    }

    /** True when the user root for [family] can be checked right now. */
    fun userRootReachable(roots: StudioRoots, family: StudioFamily): Boolean =
        family.supportsUserFolder && roots.userDir(family) != null

    /**
     * The family's ACTIVE folder for a WRITE: the user root when configured, reachable and
     * writable, else the app root. The writer stamps `isUserFolder` onto the record
     * (`wasUserFolder`) so the file forever resolves against the root it was written to.
     */
    fun writeFolder(roots: StudioRoots, family: StudioFamily): Pair<StudioDir, Boolean> {
        val user = roots.userDir(family)
        if (user != null && user.isWritable()) return user to true
        return roots.appDir(family) to false
    }

    /** Visit each possible root once: the app dir, then the user dir (when reachable). */
    fun forEachRoot(roots: StudioRoots, family: StudioFamily, body: (StudioDir, Boolean) -> Unit) {
        val visited = HashSet<String>()
        val app = roots.appDir(family)
        if (visited.add(app.key)) body(app, false)
        val user = roots.userDir(family) ?: return
        if (visited.add(user.key)) body(user, true)
    }

    /**
     * Total on-disk bytes of one family's artifacts across both roots. Counts ONLY strictly-shaped
     * names; in the USER root the parsed id must also be document-known when [knownIds] is given
     * (a user's coincidentally-shaped file is never counted; the app root is app-private).
     */
    fun usageBytes(roots: StudioRoots, family: StudioFamily, knownIds: Set<String>? = null): Long {
        var total = 0L
        forEachRoot(roots, family) { dir, isUser ->
            val names = try { dir.list() } catch (_: Exception) { return@forEachRoot }   // can't list -> count nothing
            for (n in names) {
                val id = fileId(family, n) ?: continue
                if (isUser && knownIds != null && id !in knownIds) continue
                total += dir.length(n)
            }
        }
        return total
    }
}
