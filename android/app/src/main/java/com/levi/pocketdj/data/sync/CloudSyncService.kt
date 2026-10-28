package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable

/**
 * Cross-device sync of the user's SESSION DATA - whole-document, last-writer-wins, over a
 * [CloudDocDatabase]. VERBATIM port of iOS `CloudSyncService` (the doctrine is hard-won; only the
 * backend differs).
 *
 * Doctrine:
 *  - PULL applies only when the cloud copy is strictly newer than the local file (mtime vs the
 *    writer's recorded mtime, +[SKEW_MS] slack). Before overwriting, the local file is backed up
 *    to `<name>.pre-cloud`.
 *  - After a pull the owning store's [Entry.reload] re-decodes from disk. Restore-later stores
 *    have no reload: their files are pulled BEFORE they are read (`syncAtLaunch` is awaited first,
 *    bounded by a deadline so launch never hangs on the network).
 *  - PUSH sends any file whose mtime advanced past the last push - launch, foreground (throttled),
 *    the active tick, backgrounding, and Settings "Sync now". Pushes are gated by [pushAllowed]
 *    (onboarding): pulls are deliberately NOT gated.
 *  - Media files never sync; documents referencing device-local media are excluded by design.
 *
 * Passes are not dispatcher-bound: run them from an IO scope ([scope]). File and database work is
 * plain blocking/suspending code.
 */
class CloudSyncService(
    private val database: () -> CloudDocDatabase,
    private val enabled: () -> Boolean,
    private val stateFile: File,
    /** Scope that owns background passes (the launch pass survives its deadline here). */
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val deviceName: String = "Android",
    private val log: (String, String) -> Unit = { _, _ -> },
) {
    constructor(
        database: CloudDocDatabase,
        enabled: () -> Boolean,
        stateFile: File,
        scope: CoroutineScope,
        clock: () -> Long = System::currentTimeMillis,
        deviceName: String = "Android",
    ) : this({ database }, enabled, stateFile, scope, clock, deviceName)

    /** One registered document: the on-disk file + how to apply a fresh pull. */
    class Entry(
        val key: String,
        val file: File,
        /** Re-decode the (just-overwritten) file into the live store. null = file-only (restore-later stores).
         * The result reports a RE-SAVE: `true` = the reload merged and re-wrote the file (a superset of the
         * cloud copy that must go back up). Any other result means "no re-save" (mtime change still counts). */
        val reload: (() -> Any?)? = null,
        /**
         * OPTIONAL write seam for the pulled payload. When set, [applyPull] hands the bytes HERE
         * instead of writing [file] itself - for a store whose own writer runs off-thread on a
         * serial queue, so the pull is totally ordered against an in-flight snapshot. The closure
         * MUST write the payload to [file] synchronously (the watermark mtime is read immediately).
         */
        val applyPayload: ((ByteArray) -> Unit)? = null,
    )

    /** What the onboarding "restore" probe found in the cloud. */
    sealed interface ProfileProbe {
        /** Sync is disabled - the probe never touches the backend. */
        data object Disabled : ProfileProbe
        data object NoAccount : ProfileProbe

        /** Account up but the probe errored or timed out. NOT [Fresh]: a slow network must never read as "no profile". */
        data object Unknown : ProfileProbe
        data object Fresh : ProfileProbe
        data class Existing(val name: String) : ProfileProbe
    }

    /** Observable status for Settings > Profile. */
    data class Status(
        val syncing: Boolean = false,
        val lastSyncAtMs: Long? = null,
        val lastSummary: String? = null,
        val lastError: String? = null,
        /** Last observed account availability; null until a pass or probe ran. */
        val accountAvailable: Boolean? = null,
    )

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()

    /**
     * ONBOARDING PUSH GATE: while the zero-to-hero flow is unresolved NO push may run - a store file
     * materialized mid-onboarding must never LWW-overwrite a returning user's cloud data. null =
     * always allowed. Pulls are not gated.
     */
    @Volatile var pushAllowed: (() -> Boolean)? = null

    private val entries = java.util.concurrent.CopyOnWriteArrayList<Entry>()
    private val syncing = AtomicBoolean(false)

    /** key -> file mtime (epoch ms) at the last successful push/pull (the in-sync watermark). */
    private val pushedMtimeMs = java.util.concurrent.ConcurrentHashMap<String, Double>()

    @Volatile private var lastPassAt: Long = 0L

    @Serializable
    private data class StateFile(
        val pushedMtimeMs: Map<String, Double> = emptyMap(),
        val lastSyncAtMs: Double? = null,
    )

    init {
        runCatching {
            if (stateFile.exists()) {
                val st = PdjJson.lenient.decodeFromString(StateFile.serializer(), stateFile.readText())
                pushedMtimeMs.putAll(st.pushedMtimeMs)
                st.lastSyncAtMs?.let { _status.value = _status.value.copy(lastSyncAtMs = it.toLong()) }
            }
        }
    }

    fun register(
        key: String,
        file: File,
        reload: (() -> Any?)? = null,
        applyPayload: ((ByteArray) -> Unit)? = null,
    ) {
        entries += Entry(key, file, reload, applyPayload)
    }

    val registeredKeys: List<String> get() = entries.map { it.key }

    /** Test seam: the watermark for [key], or null when cleared/never set. */
    fun watermark(key: String): Double? = pushedMtimeMs[key]

    private val mayRun: Boolean get() = enabled() && entries.isNotEmpty()

    /**
     * The launch pass - awaited BEFORE the durable-session restores so a fresh device restores CLOUD
     * session files. Bounded by [deadlineMs]: if the backend is slow the pass keeps running in the
     * background and this returns, so launch never hangs on the network.
     */
    suspend fun syncAtLaunch(deadlineMs: Long = LAUNCH_DEADLINE_MS) {
        if (!mayRun) return
        val pass: Job = scope.launch { runPass(manual = false) }
        withTimeoutOrNull(deadlineMs) { pass.join() }
    }

    /** Foreground re-sync (throttled to [FOREGROUND_GAP_MS]). Returns the launched job, or null when throttled. */
    fun syncOnForeground(): Job? {
        if (clock() - lastPassAt <= FOREGROUND_GAP_MS) return null
        return scope.launch { runPass(manual = false) }
    }

    /**
     * WHILE-ACTIVE freshness tick - what makes a merged history actually arrive when the other
     * device never backgrounds. Cheap: a pass opens with ONE fetchMeta and does nothing further
     * unless a document differs. The caller gates on "app in foreground".
     */
    fun syncTick(): Job? {
        if (clock() - lastPassAt <= ACTIVE_TICK_GAP_MS) return null
        return scope.launch { runPass(manual = false) }
    }

    /** Settings > Profile "Sync now". */
    suspend fun syncNow() = runPass(manual = true)

    // MARK: Onboarding

    /**
     * Probe the cloud for an existing profile, bounded by [deadlineMs] (a probe must never hang the
     * first-run flow; timeout = [ProfileProbe.Unknown], never [ProfileProbe.Fresh]).
     */
    suspend fun probeCloudProfile(deadlineMs: Long = PROBE_DEADLINE_MS): ProfileProbe {
        if (!enabled()) return ProfileProbe.Disabled
        val db = database()
        val result = withTimeoutOrNull(deadlineMs) {
            try {
                if (!db.accountAvailable()) {
                    ProfileProbe.NoAccount
                } else {
                    val doc = db.fetch(PROFILE_KEY)
                    if (doc == null) {
                        ProfileProbe.Fresh
                    } else {
                        val name = runCatching {
                            PdjJson.lenient.decodeFromString(ProfileStore.Document.serializer(), String(doc.payload, Charsets.UTF_8)).name
                        }.getOrDefault("")
                        ProfileProbe.Existing(name)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                ProfileProbe.Unknown
            }
        } ?: ProfileProbe.Unknown
        when (result) {
            ProfileProbe.NoAccount -> _status.value = _status.value.copy(accountAvailable = false)
            ProfileProbe.Fresh, is ProfileProbe.Existing -> _status.value = _status.value.copy(accountAvailable = true)
            ProfileProbe.Disabled, ProfileProbe.Unknown -> Unit
        }
        return result
    }

    /**
     * "Restore my stuff": pull-FORCED, no deadline. Applies EVERY cloud doc regardless of local mtimes
     * (a freshly materialized local file is always junk relative to the cloud copy the user asked to
     * restore). `.pre-cloud` backups are still taken. Pushes: none. Returns the pulled keys; null =
     * the pass could not run (disabled / no account / already syncing / error).
     */
    suspend fun restoreForOnboarding(): List<String>? {
        if (!mayRun || !syncing.compareAndSet(false, true)) return null
        try {
            _status.value = _status.value.copy(syncing = true, lastError = null)
            lastPassAt = clock()
            val db = database()
            val available = db.accountAvailable()
            _status.value = _status.value.copy(accountAvailable = available)
            if (!available) {
                _status.value = _status.value.copy(lastSummary = "Account unavailable")
                return null
            }
            val pulled = mutableListOf<String>()
            return try {
                val meta = db.fetchMeta(entries.map { it.key })
                for (entry in entries) {
                    if (meta[entry.key] == null) continue
                    val doc = db.fetch(entry.key) ?: continue
                    applyPull(doc, entry)
                    pulled += entry.key
                }
                _status.value = _status.value.copy(
                    lastSyncAtMs = clock(),
                    lastSummary = if (pulled.isEmpty()) "Nothing to restore" else "Restored ${pulled.joinToString(", ")}",
                )
                saveState()
                pulled
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _status.value = _status.value.copy(lastError = e.message ?: e.toString())
                null
            }
        } finally {
            syncing.set(false)
            _status.value = _status.value.copy(syncing = false)
        }
    }

    /** Backgrounding: push-only, fire-and-forget (the OS gives seconds - pulls can wait). */
    fun pushOnBackground(): Job? {
        if (!mayRun) return null
        return scope.launch { pushDirty() }
    }

    // MARK: The pass

    private suspend fun runPass(manual: Boolean) {
        if (!mayRun || !syncing.compareAndSet(false, true)) return
        try {
            _status.value = _status.value.copy(syncing = true, lastError = null)
            lastPassAt = clock()
            val db = database()
            val available = db.accountAvailable()
            _status.value = _status.value.copy(accountAvailable = available)
            if (!available) {
                _status.value = _status.value.copy(lastSummary = "Account unavailable")
                return
            }
            val pulled = mutableListOf<String>()
            val pushed = mutableListOf<String>()
            try {
                val meta = db.fetchMeta(entries.map { it.key })
                for (entry in entries) {
                    if (!kotlin.coroutines.coroutineContext.isActive && !manual) break
                    val localMs = fileMtimeMs(entry.file)
                    val cloudMs = meta[entry.key]
                    if (cloudMs != null && cloudMs > (localMs ?: 0.0) + SKEW_MS) {
                        val doc = db.fetch(entry.key)
                        if (doc != null) {
                            applyPull(doc, entry)
                            pulled += entry.key
                        }
                    } else if (localMs != null &&
                        localMs > (cloudMs ?: 0.0) + SKEW_MS &&
                        localMs > (pushedMtimeMs[entry.key] ?: 0.0) + 1 &&
                        (pushAllowed?.invoke() ?: true)
                    ) {
                        push(db, entry, localMs)
                        pushed += entry.key
                    }
                }
                _status.value = _status.value.copy(lastSyncAtMs = clock(), lastSummary = summary(pulled, pushed))
                saveState()
                log("sync", "pass ok manual=$manual pulled=[${pulled.joinToString(",")}] pushed=[${pushed.joinToString(",")}]")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _status.value = _status.value.copy(lastError = e.message ?: e.toString())
                log("error", "sync pass failed: ${e.javaClass.simpleName} ${e.message}")
            }
        } finally {
            syncing.set(false)
            _status.value = _status.value.copy(syncing = false)
        }
    }

    /**
     * The backgrounding push. Never blind: ONE fetchMeta probe (modification times only) so a device
     * cannot publish a stale document over a strictly newer one from another device - the watermark
     * only says "what I last sent", never "what someone else has since sent". A probe FAILURE (offline
     * on the way to the background is the common case) falls back to the old blind push: losing a set
     * the user just played offline is worse than the narrow overwrite risk.
     */
    suspend fun pushDirty() {
        if (!(pushAllowed?.invoke() ?: true)) return
        val db = database()
        if (!db.accountAvailable()) return
        val candidates = entries.filter { entry ->
            val localMs = fileMtimeMs(entry.file) ?: return@filter false
            localMs > (pushedMtimeMs[entry.key] ?: 0.0) + 1
        }
        if (candidates.isEmpty()) return

        val cloud: Map<String, Double> = try {
            db.fetchMeta(candidates.map { it.key })
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            emptyMap()
        }

        var pushed = false
        for (entry in candidates) {
            val localMs = fileMtimeMs(entry.file) ?: continue
            // Absent from the probe = never uploaded = push. Only a strictly newer cloud copy skips.
            val cloudMs = cloud[entry.key]
            if (cloudMs != null && cloudMs > localMs + SKEW_MS) continue
            val ok = try {
                push(db, entry, localMs)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                false
            }
            if (ok) pushed = true
        }
        if (pushed) saveState()
    }

    private fun applyPull(doc: CloudDoc, entry: Entry) {
        // Data safety: the pre-pull local copy survives as <name>.pre-cloud.
        if (entry.file.exists()) {
            val backup = File(entry.file.parentFile, entry.file.name + ".pre-cloud")
            runCatching { backup.delete() }
            runCatching { entry.file.copyTo(backup, overwrite = true) }
        }
        val apply = entry.applyPayload
        if (apply != null) {
            apply(doc.payload)
        } else {
            entry.file.parentFile?.mkdirs()
            val tmp = File(entry.file.parentFile, entry.file.name + ".pull.tmp")
            tmp.writeBytes(doc.payload)
            if (!tmp.renameTo(entry.file)) {
                entry.file.delete()
                if (!tmp.renameTo(entry.file)) tmp.copyTo(entry.file, overwrite = true)
            }
        }
        // Watermark the mtime of the bytes we JUST PULLED, read BEFORE reload(). A reload that MERGES
        // (activity/history) re-saves a strictly newer superset; watermarking the post-reload mtime
        // would tell the next pass "already pushed" and the superset would never publish.
        val pulledMtime = fileMtimeMs(entry.file) ?: doc.modifiedAtMs
        val resaved = entry.reload?.invoke() == true
        val afterReload = fileMtimeMs(entry.file)
        // The reload's own re-save report is authoritative: File.lastModified() is millisecond-grained
        // and an inline merge-save can land in the same ms as the pull. The mtime compare is a backstop.
        if (resaved || (afterReload != null && afterReload != pulledMtime)) {
            // The reload MERGED and re-saved: the file is now a superset of the cloud copy and must go
            // back up. Clear the watermark outright (an mtime-based one can fail to clear the sub-ms
            // epsilon of a small merge-save); a cleared watermark does not depend on timing.
            pushedMtimeMs.remove(entry.key)
        } else {
            pushedMtimeMs[entry.key] = pulledMtime
        }
    }

    private suspend fun push(db: CloudDocDatabase, entry: Entry, mtimeMs: Double): Boolean {
        val payload = runCatching { entry.file.readBytes() }.getOrNull() ?: return false
        db.save(CloudDoc(entry.key, payload, mtimeMs, deviceName))
        pushedMtimeMs[entry.key] = mtimeMs
        return true
    }

    private fun fileMtimeMs(file: File): Double? =
        if (file.exists()) file.lastModified().toDouble() else null

    private fun saveState() {
        val st = StateFile(HashMap(pushedMtimeMs), _status.value.lastSyncAtMs?.toDouble())
        runCatching {
            stateFile.parentFile?.mkdirs()
            val tmp = File(stateFile.parentFile, stateFile.name + ".tmp")
            tmp.writeText(PdjJson.lenient.encodeToString(StateFile.serializer(), st))
            if (!tmp.renameTo(stateFile)) { stateFile.delete(); tmp.renameTo(stateFile) }
        }
    }

    /**
     * Full local reset ("Reset everything" / re-onboarding): drop the in-sync watermark, delete the
     * state file, and sweep every `<name>.pre-cloud` backup. Without this an erased document would be
     * resurrected - re-pushed off a stale watermark or restored from its backup. The synced docs
     * themselves are NOT removed here (the orchestrator clears them via each store); the cloud is untouched.
     */
    fun clearLocalSyncState() {
        pushedMtimeMs.clear()
        runCatching { stateFile.delete() }
        for (entry in entries) {
            runCatching { File(entry.file.parentFile, entry.file.name + ".pre-cloud").delete() }
        }
        lastPassAt = 0L
        _status.value = Status(accountAvailable = _status.value.accountAvailable)
    }

    companion object {
        const val PROFILE_KEY = "profile"

        /** Clock/mtime slack under which two copies count as "the same write". */
        const val SKEW_MS = 2_000.0

        /** Foreground re-syncs are throttled to this gap (launch/manual syncs ignore it). */
        const val FOREGROUND_GAP_MS = 5 * 60_000L

        /** While-active tick gap. */
        const val ACTIVE_TICK_GAP_MS = 20_000L

        const val LAUNCH_DEADLINE_MS = 8_000L
        const val PROBE_DEADLINE_MS = 10_000L

        fun summary(pulled: List<String>, pushed: List<String>): String {
            if (pulled.isEmpty() && pushed.isEmpty()) return "Everything in sync"
            val parts = mutableListOf<String>()
            if (pulled.isNotEmpty()) parts += "pulled ${pulled.joinToString(", ")}"
            if (pushed.isNotEmpty()) parts += "pushed ${pushed.joinToString(", ")}"
            return parts.joinToString(" · ").replaceFirstChar { it.uppercase() }
        }
    }
}
