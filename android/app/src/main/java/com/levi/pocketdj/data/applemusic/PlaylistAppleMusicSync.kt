package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.SongDuplicateJudge
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** What the sync engine reads/writes of the collections + catalog (production: [CollectionsAmSyncHost]). */
interface AmSyncHost {
    val playlists: List<Playlist>
    val pockets: List<Pocket>
    fun songIdsForPlaylist(id: String): List<String>
    fun songIdsForPocket(id: String): List<String>
    fun song(id: String): IndexSong?
    fun duplicateIdentity(songId: String): SongDuplicateJudge.Identity?

    /** Catalog source playlists (the Apple Music mirrors are picked out by source name). */
    val sourcePlaylists: List<SourcePlaylist>

    /** Apple Music catalog id -> local song id (one pass over the live catalog). */
    fun songIdByAppleMusicId(): Map<String, String>

    fun linkPlaylist(playlistId: String, amPlaylistId: String)
    fun linkPocket(pocketId: String, amPlaylistId: String)
    fun createPlaylist(name: String, songIds: List<String>, source: SourcePlaylist?): Playlist
}

@Serializable
data class AmSyncStep(
    val id: Int,
    val label: String,
    val detail: String? = null,
    val state: State,
) {
    /** `interrupted` is what a persisted `running` becomes on relaunch (the stored jobId resumes it). */
    @Serializable
    enum class State {
        @SerialName("running") RUNNING,
        @SerialName("done") DONE,
        @SerialName("failed") FAILED,
        @SerialName("interrupted") INTERRUPTED,
    }
}

@Serializable
data class AmSyncReport(
    val dateMs: Double,
    val changes: List<Change> = emptyList(),
    val errors: List<String> = emptyList(),
    val summary: String = "",
) {
    @Serializable
    data class Change(
        /** "created" | "updated" | "reconciled" | "imported" | "skipped" | "not imported" */
        val kind: String,
        val name: String,
        val added: Int = 0,
        val removed: Int = 0,
        val detail: String? = null,
    )
}

/** The persisted current/most-recent run (iOS `RunSnapshot`). */
@Serializable
data class AmRunSnapshot(
    val startedMs: Double,
    val updatedMs: Double,
    val steps: List<AmSyncStep>,
    val completed: Boolean,
)

/** Live UI state of the sync (iOS @Observable properties). */
data class AmSyncUi(
    val isSyncing: Boolean = false,
    val steps: List<AmSyncStep> = emptyList(),
    val lastResult: String? = null,
    /** Newest-first, capped at [PlaylistAppleMusicSync.AUDIT_CAP], persisted. */
    val auditTrail: List<AmSyncReport> = emptyList(),
    val currentRunStartedMs: Double? = null,
    /** False while a run is live AND when the app died mid-run ("Interrupted sync"). */
    val currentRunCompleted: Boolean = true,
)

/** What a push WOULD send, plus what it deliberately would not. */
data class AmOutgoingResolution(
    val playlists: List<AmOutgoingPlaylist>,
    /** Set-to-push collections carrying nothing Apple Music can hold (never dropped silently). */
    val skipped: List<Skipped>,
) {
    data class Skipped(val name: String, val songCount: Int, val isPocket: Boolean)
}

@Serializable
data class AmCatalogLookup(val catalogId: String? = null, val checkedAtMs: Double)

/**
 * Bidirectional PocketDJ <-> Apple Music library-playlist sync via [AMPlaylistSyncClient]
 * (iOS `PlaylistAppleMusicSync`). PUSH = create + append, then RECONCILE (removals + reorders via
 * the transport's Web-API delete+append, fail-closed; see [PlaylistReconcilePlanner]). PULL imports remote playlists with no local
 * counterpart, only when [importNewPlaylistsEnabled] says so (nil/false = import nothing).
 */
class PlaylistAppleMusicSync(
    private val client: AMPlaylistSyncClient,
    private val transport: PlaylistWriteBackTransport?,
    private val auditFile: File,
    private val runFile: File,
    private val catalogLookupsFile: File? = null,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    enum class Direction { BOTH, PUSH, PULL }

    /** Wired at app init to `amImportNewPlaylists`. null => FALSE (the safe default). */
    @Volatile var importNewPlaylistsEnabled: (suspend () -> Boolean)? = null

    private val _ui = MutableStateFlow(AmSyncUi())
    val ui: StateFlow<AmSyncUi> = _ui.asStateFlow()
    private val running = AtomicBoolean(false)
    private val lock = Any()

    @Volatile private var catalogLookups: Map<String, AmCatalogLookup> = emptyMap()

    init {
        _ui.value = _ui.value.copy(auditTrail = loadAudit())
        catalogLookupsFile?.let { f ->
            runCatching { json.decodeFromString(LOOKUPS_SER, f.readText()) }.getOrNull()?.let { catalogLookups = it }
        }
        // Hydrate the persisted current run: a snapshot that never completed means the process died
        // mid-sync - its running steps become interrupted; the stored jobId makes the next Sync RESUME.
        runCatching { json.decodeFromString(AmRunSnapshot.serializer(), runFile.readText()) }.getOrNull()?.let { snap ->
            _ui.update {
                it.copy(
                    currentRunStartedMs = snap.startedMs,
                    currentRunCompleted = snap.completed,
                    steps = hydrateSteps(snap),
                )
            }
        }
    }

    val isAvailable: Boolean get() = true

    // MARK: Sync

    /**
     * AUTO-RESUME: if the last run never completed (hydrated with completed == false) silently pick
     * it back up - the client re-attaches to the stored server job and every half is idempotent.
     */
    suspend fun resumeIfInterrupted(host: AmSyncHost) {
        val s = _ui.value
        if (s.isSyncing || s.currentRunCompleted || s.currentRunStartedMs == null) return
        syncNow(host, Direction.BOTH)
    }

    suspend fun syncNow(host: AmSyncHost, direction: Direction = Direction.BOTH) {
        if (!running.compareAndSet(false, true)) return
        _ui.update {
            it.copy(
                isSyncing = true, lastResult = null, steps = emptyList(),
                currentRunStartedMs = nowMs(), currentRunCompleted = false,
            )
        }
        persistRun()
        val changes = mutableListOf<AmSyncReport.Change>()
        val errors = mutableListOf<String>()
        try {
            if (direction != Direction.PULL) pushHalf(host, changes, errors)
            if (direction == Direction.PUSH) {
                finish(changes, errors)
                return
            }
            pullHalf(host, changes)
            finish(changes, errors)
        } catch (e: CancellationException) {
            // run stays not-completed => "Interrupted sync", resumable; show it as such, not a spinner
            _ui.update { u -> u.copy(steps = u.steps.map { if (it.state == AmSyncStep.State.RUNNING) it.copy(state = AmSyncStep.State.INTERRUPTED) else it }) }
            throw e
        } catch (e: Exception) {
            val msg = e.message ?: e.toString()
            failStep(msg)
            errors += msg
            _ui.update { it.copy(lastResult = msg, currentRunCompleted = true) }
            persistRun()
            appendAudit(AmSyncReport(nowMs(), changes.toList(), errors.toList(), "Failed: $msg"))
        } finally {
            _ui.update { it.copy(isSyncing = false) }
            running.set(false)
        }
    }

    private fun finish(changes: List<AmSyncReport.Change>, errors: List<String>) {
        val summary = reportSummaryText(changes, errors)
        _ui.update { it.copy(lastResult = summary, currentRunCompleted = true) }
        persistRun()
        appendAudit(AmSyncReport(nowMs(), changes.toList(), errors.toList(), summary))
    }

    private suspend fun pushHalf(host: AmSyncHost, changes: MutableList<AmSyncReport.Change>, errors: MutableList<String>) {
        beginStep("Preparing playlists")
        // Resolve missing store ids ON DEVICE, scoped to the collections a dry run says would be dropped.
        val dryRun = resolveOutgoingDetailed(host)
        val resolvedIds = resolvedCatalogIds().toMutableMap()
        val needing = songsNeedingCatalogId(host, dryRun.skipped.map { normName(it.name) }.toSet())
        val pending = pendingLookups(needing, catalogLookups, nowMs())
        val tr = transport
        if (tr != null && tr.canWrite() && pending.isNotEmpty()) {
            beginStep("Matching songs to Apple Music")
            var matched = 0
            var looked = 0
            for ((songId, song) in pending.take(CATALOG_RESOLVE_CAP)) {
                looked++
                updateStep("Looking up “${song.title}”")
                val id = try { tr.resolveCatalogId(song) } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
                recordLookup(songId, id)
                if (id != null) { resolvedIds[songId] = id; matched++ }
                if (looked % CATALOG_SAVE_EVERY == 0) saveLookups()
            }
            saveLookups()
            val remaining = maxOf(0, pending.size - looked)
            finishStep("$matched of $looked matched" + if (remaining > 0) " · $remaining to go, continuing next sync" else "")
        }
        val resolution = resolveOutgoingDetailed(host, resolvedIds)
        val outgoing = resolution.playlists
        for (skip in resolution.skipped) {
            changes += AmSyncReport.Change(
                "skipped", skip.name, 0, 0,
                if (skip.songCount == 0) "empty" else "no Apple Music match for any of its ${skip.songCount} songs",
            )
        }
        val trackTotal = outgoing.sumOf { it.trackCatalogIds.size }
        finishStep("${outgoing.size} playlist${if (outgoing.size == 1) "" else "s"} · $trackTotal tracks")

        beginStep("Pushing to Apple Music")
        val pushed = client.push(outgoing) { p -> updateStep(p.display) }
        // STAMP THE DURABLE LINK onto EVERY local collection that folded into each entry.
        val byKey = HashMap<String, AmOutgoingPlaylist>()
        for (o in outgoing) byKey.putIfAbsent(normName(o.name), o)
        for (row in pushed.playlists) {
            val amId = row.id ?: continue
            val entry = byKey[normName(row.name)] ?: continue
            entry.localPlaylistIds.forEach { host.linkPlaylist(it, amId) }
            entry.localPocketIds.forEach { host.linkPocket(it, amId) }
        }
        val created = pushed.playlists.filter { it.created }
        val updated = pushed.playlists.filter { !it.created && it.added > 0 }
        for (row in pushed.playlists) {
            if (row.created || row.added > 0) {
                changes += AmSyncReport.Change(
                    if (row.created) "created" else "updated", row.name, row.added, 0,
                    row.total?.let { "${row.added} of $it tracks sent" },
                )
            }
        }
        for (f in pushed.errors) errors += "${f.name}: ${f.error}"
        finishStep(
            pushSummaryText(
                created.size, updated.size, updated.sumOf { it.added },
                pushed.playlists.size - created.size - updated.size, pushed.errors.size,
            ),
        )

        // 3. RECONCILE (removals + reorders; skips just-created playlists). Fail-closed: any throw
        // skips that playlist for this pass, an empty target never edits.
        val tr2 = transport
        if (tr2 != null && tr2.canWrite()) {
            beginStep("Reconciling removals & reorders")
            var reconciled = 0
            val justCreated = created.map { normName(it.name) }.toSet()
            // Never reconcile the same REMOTE playlist twice in one pass.
            val reconciledIds = HashSet<String>()
            for (pl in outgoing) {
                if (normName(pl.name) in justCreated) continue
                updateStep("Checking “${pl.name}”")
                // PREFER THE DURABLE LINK: reconcile rewrites contents, so a by-name guess after a rename
                // could overwrite the wrong list. Name only when there is no link yet.
                val amId = linkedAmPlaylistId(pl, host)
                    ?: try { tr2.resolvePlaylistId(pl.name, pl.trackCatalogIds) } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
                    ?: continue
                if (!reconciledIds.add(amId)) continue
                val res = try { tr2.reconcile(amId, pl.trackCatalogIds) } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
                if (res is PlaylistReconcileResult.Edited) {
                    reconciled++
                    changes += AmSyncReport.Change("reconciled", pl.name, res.added, res.removed, "now ${res.count} tracks in PocketDJ order")
                }
            }
            finishStep(if (reconciled == 0) "Nothing to fix" else "$reconciled playlist${if (reconciled == 1) "" else "s"} re-ordered/pruned")
        }
    }

    private suspend fun pullHalf(host: AmSyncHost, changes: MutableList<AmSyncReport.Change>) {
        beginStep("Reading Apple Music playlists")
        val remote = client.pull { p -> updateStep(p.display) }
        finishStep("${remote.size} playlist${if (remote.size == 1) "" else "s"} read")

        beginStep("Importing new playlists")
        val localByAm = host.songIdByAppleMusicId()
        val existing = existingCollectionNames(host)
        // Provenance stamp: an Apple Music mirror with the same normalized name => the import arrives LINKED.
        val mirrorByName = HashMap<String, SourcePlaylist>()
        for (sp in host.sourcePlaylists) {
            if (PlaylistWriteBack.isAppleMusicSource(sp.sourceName)) mirrorByName.putIfAbsent(normName(sp.playlist.name), sp)
        }
        var imported = 0
        val unmatched = newImports(remote, existing, linkedRemoteIds(host))
        val mayImport = importNewPlaylistsEnabled?.invoke() ?: false
        if (!mayImport && unmatched.isNotEmpty()) {
            changes += AmSyncReport.Change(
                "not imported", "${unmatched.size} Apple Music playlist${if (unmatched.size == 1) "" else "s"}", 0, 0,
                "left in Apple Music — turn on “Import new Apple Music playlists” to copy them here",
            )
        }
        for (r in if (mayImport) unmatched else emptyList()) {
            val seen = SongDuplicateJudge.Seen()
            val localIds = r.trackCatalogIds.mapNotNull { localByAm[it] }.filter { id ->
                val ident = host.duplicateIdentity(id) ?: return@filter true
                seen.insert(ident)
            }
            host.createPlaylist(r.name, localIds, mirrorByName[normName(r.name)])
            changes += AmSyncReport.Change(
                "imported", r.name, localIds.size, 0, "${localIds.size} of ${r.trackCatalogIds.size} tracks matched locally",
            )
            imported++
        }
        finishStep(if (imported == 0) "Nothing new" else "$imported imported")
    }

    // MARK: On-device catalog-id cache

    fun resolvedCatalogIds(): Map<String, String> = catalogLookups.mapNotNull { (k, v) -> v.catalogId?.let { k to it } }.toMap()

    private fun recordLookup(songId: String, catalogId: String?) {
        catalogLookups = catalogLookups + (songId to AmCatalogLookup(catalogId, nowMs()))
    }

    private fun saveLookups() {
        val f = catalogLookupsFile ?: return
        runCatching { atomicWrite(f, json.encodeToString(LOOKUPS_SER, catalogLookups)) }
    }

    // MARK: Step helpers (every mutation persists the run snapshot)

    private fun beginStep(label: String) {
        _ui.update { it.copy(steps = it.steps + AmSyncStep(it.steps.size, label, null, AmSyncStep.State.RUNNING)) }
        persistRun()
    }

    private fun mutateRunning(f: (AmSyncStep) -> AmSyncStep) {
        _ui.update { s ->
            val i = s.steps.indexOfLast { it.state == AmSyncStep.State.RUNNING }
            if (i < 0) s else s.copy(steps = s.steps.toMutableList().also { it[i] = f(it[i]) })
        }
        persistRun()
    }

    private fun updateStep(detail: String) = mutateRunning { it.copy(detail = detail) }
    private fun finishStep(detail: String? = null) =
        mutateRunning { it.copy(state = AmSyncStep.State.DONE, detail = detail ?: it.detail) }
    private fun failStep(detail: String) = mutateRunning { it.copy(state = AmSyncStep.State.FAILED, detail = detail) }

    // MARK: Persistence

    private fun persistRun() = synchronized(lock) {
        val s = _ui.value
        val started = s.currentRunStartedMs ?: return@synchronized
        runCatching {
            atomicWrite(runFile, json.encodeToString(AmRunSnapshot.serializer(), AmRunSnapshot(started, nowMs(), s.steps, s.currentRunCompleted)))
        }
    }

    private fun loadAudit(): List<AmSyncReport> =
        runCatching { json.decodeFromString(AUDIT_SER, auditFile.readText()) }.getOrNull() ?: emptyList()

    /**
     * READ-MERGE-WRITE, not overwrite: another instance (a second window, a sync finishing after
     * this panel was re-entered) may have appended reports since this one loaded.
     */
    internal fun appendAudit(report: AmSyncReport) = synchronized(lock) {
        val merged = mergeAudit(loadAudit(), report)
        _ui.update { it.copy(auditTrail = merged) }
        runCatching { atomicWrite(auditFile, json.encodeToString(AUDIT_SER, merged)) }
        Unit
    }

    companion object {
        const val AUDIT_CAP = 20
        const val CATALOG_RESOLVE_CAP = 200
        const val CATALOG_SAVE_EVERY = 25
        const val MISS_RETRY_AFTER_MS = 30.0 * 24 * 60 * 60 * 1000

        const val AUDIT_FILE = "pocketdj-am-sync-audit.json"
        const val RUN_FILE = "pocketdj-am-sync-current.json"
        const val LOOKUPS_FILE = "pocketdj-am-catalog-ids.json"

        private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; explicitNulls = false; encodeDefaults = true }
        private val AUDIT_SER = ListSerializer(AmSyncReport.serializer())
        private val LOOKUPS_SER = MapSerializer(String.serializer(), AmCatalogLookup.serializer())

        private fun atomicWrite(f: File, text: String) {
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(f)) { f.writeText(text); tmp.delete() }
        }

        /** A persisted `running` step of a run that never completed hydrates as `interrupted`. */
        fun hydrateSteps(snap: AmRunSnapshot): List<AmSyncStep> = snap.steps.map {
            if (!snap.completed && it.state == AmSyncStep.State.RUNNING) it.copy(state = AmSyncStep.State.INTERRUPTED) else it
        }

        /** Newest first, de-duplicated by dateMs, capped at [AUDIT_CAP]. */
        fun mergeAudit(existing: List<AmSyncReport>, report: AmSyncReport): List<AmSyncReport> {
            val seen = HashSet<Double>()
            return (listOf(report) + existing).filter { seen.add(it.dateMs) }
                .sortedByDescending { it.dateMs }
                .take(AUDIT_CAP)
        }

        /**
         * The SAME name normalization the server's push dedup uses (index.mjs normName): trim,
         * lowercase, collapse internal whitespace. Client and server MUST agree.
         */
        fun normName(s: String): String =
            s.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

        /**
         * PURE: every collection whose songs resolve to Apple Music catalog ids, as an outgoing
         * payload - PLAYLISTS plus every POCKET that CAME FROM an Apple Music playlist. Hand-made
         * pockets stay local. Collections whose names NORMALIZE EQUAL merge into ONE entry (ordered
         * union); ids are de-duplicated in order, and a NAME+ARTIST gate stops the same recording
         * pushing twice. `allowsPush == false` collections never push.
         */
        fun resolveOutgoingDetailed(host: AmSyncHost, resolvedCatalogIds: Map<String, String> = emptyMap()): AmOutgoingResolution {
            class Acc(val name: String) {
                val ids = ArrayList<String>()
                val meta = ArrayList<AmOutgoingPlaylist.TrackMeta>()
                val playlistIds = ArrayList<String>()
                val pocketIds = ArrayList<String>()
                val seenIds = HashSet<String>()
                val seenIdent = SongDuplicateJudge.Seen()
            }
            val byKey = LinkedHashMap<String, Acc>()
            val skipped = mutableListOf<AmOutgoingResolution.Skipped>()
            fun fold(name: String, songIds: List<String>, localId: String, isPocket: Boolean) {
                val acc = byKey.getOrPut(normName(name)) { Acc(name) }
                for (songId in songIds) {
                    val song = host.song(songId) ?: continue
                    val catalogId = song.appleMusicId ?: resolvedCatalogIds[songId] ?: continue
                    if (!acc.seenIds.add(catalogId)) continue
                    val ident = host.duplicateIdentity(songId) ?: continue
                    if (!acc.seenIdent.insert(ident)) continue
                    acc.ids += catalogId
                    acc.meta += AmOutgoingPlaylist.TrackMeta(catalogId, song.name, song.artist)
                }
                if (isPocket) acc.pocketIds += localId else acc.playlistIds += localId
                if (acc.ids.isEmpty() && songIds.isNotEmpty()) skipped += AmOutgoingResolution.Skipped(name, songIds.size, isPocket)
            }
            for (pl in host.playlists.filter { it.amSyncDir.allowsPush }) {
                fold(pl.name, host.songIdsForPlaylist(pl.id), pl.id, false)
            }
            for (p in host.pockets) {
                if (p.hasSource && PlaylistWriteBack.isAppleMusicSource(p.sourceName) && p.amSyncDir.allowsPush) {
                    fold(p.name, host.songIdsForPocket(p.id), p.id, true)
                }
            }
            val sendable = byKey.values.filter { it.ids.isNotEmpty() }.map {
                AmOutgoingPlaylist(
                    name = it.name, trackCatalogIds = it.ids.toList(), trackMeta = it.meta.toList(),
                    localPlaylistIds = it.playlistIds.toList(), localPocketIds = it.pocketIds.toList(),
                )
            }
            val sendableNames = sendable.map { normName(it.name) }.toSet()
            return AmOutgoingResolution(sendable, skipped.filter { normName(it.name) !in sendableNames })
        }

        /** The Apple Music playlist id an outgoing entry is already bound to (first linked local wins); null => resolve by name. */
        fun linkedAmPlaylistId(entry: AmOutgoingPlaylist, host: AmSyncHost): String? {
            for (id in entry.localPlaylistIds) host.playlists.firstOrNull { it.id == id }?.amPlaylistId?.takeIf { it.isNotEmpty() }?.let { return it }
            for (id in entry.localPocketIds) host.pockets.firstOrNull { it.id == id }?.amPlaylistId?.takeIf { it.isNotEmpty() }?.let { return it }
            return null
        }

        fun resolveOutgoing(host: AmSyncHost): List<AmOutgoingPlaylist> = resolveOutgoingDetailed(host).playlists

        /** Songs in PUSHABLE collections named in [onlyCollectionsNamed] (normalized) that carry no store id. */
        fun songsNeedingCatalogId(host: AmSyncHost, onlyCollectionsNamed: Set<String>): List<Pair<String, WriteBackSong>> {
            if (onlyCollectionsNamed.isEmpty()) return emptyList()
            val seen = HashSet<String>()
            val out = mutableListOf<Pair<String, WriteBackSong>>()
            fun consider(ids: List<String>) {
                for (id in ids) {
                    val s = host.song(id) ?: continue
                    if (s.appleMusicId != null || !seen.add(id)) continue
                    val title = s.name.trim()
                    val artist = s.artist.trim()
                    if (title.isEmpty() || artist.isEmpty()) continue
                    out += id to WriteBackSong(appleMusicId = "", title = title, artist = artist, album = null, durationMs = s.length?.toInt())
                }
            }
            for (pl in host.playlists) if (pl.amSyncDir.allowsPush && normName(pl.name) in onlyCollectionsNamed) consider(host.songIdsForPlaylist(pl.id))
            for (p in host.pockets) {
                if (p.hasSource && PlaylistWriteBack.isAppleMusicSource(p.sourceName) && p.amSyncDir.allowsPush &&
                    normName(p.name) in onlyCollectionsNamed
                ) consider(host.songIdsForPocket(p.id))
            }
            return out
        }

        /** Which of [needing] still deserves a lookup: never asked, or a miss older than 30 days. */
        fun pendingLookups(
            needing: List<Pair<String, WriteBackSong>>,
            known: Map<String, AmCatalogLookup>,
            nowMs: Double,
        ): List<Pair<String, WriteBackSong>> = needing.filter { (id, _) ->
            val seen = known[id] ?: return@filter true
            if (seen.catalogId != null) false else nowMs - seen.checkedAtMs > MISS_RETRY_AFTER_MS
        }

        /** Normalized names of every local playlist AND pocket the pull-import dedupes against. */
        fun existingCollectionNames(host: AmSyncHost): Set<String> =
            host.playlists.map { normName(it.name) }.toSet() + host.pockets.map { normName(it.name) }

        /** Every Apple Music playlist id a local collection is already bound to (link or provenance). */
        fun linkedRemoteIds(host: AmSyncHost): Set<String> {
            val out = HashSet<String>()
            for (pl in host.playlists) {
                pl.amPlaylistId?.takeIf { it.isNotEmpty() }?.let(out::add)
                pl.sourcePlaylistId?.takeIf { it.isNotEmpty() }?.let(out::add)
            }
            for (p in host.pockets) {
                p.amPlaylistId?.takeIf { it.isNotEmpty() }?.let(out::add)
                p.sourcePlaylistId?.takeIf { it.isNotEmpty() }?.let(out::add)
            }
            return out
        }

        /**
         * PURE: which pulled remotes to import. Skips remotes bound by id, skips any whose
         * normalized name exists locally (playlist OR pocket), and collapses same-named remotes to
         * the FULLEST one (first wins ties), preserving first-seen order.
         */
        fun newImports(
            remote: List<AmRemotePlaylist>,
            existingNames: Set<String>,
            linkedRemoteIds: Set<String> = emptySet(),
        ): List<AmRemotePlaylist> {
            val best = LinkedHashMap<String, AmRemotePlaylist>()
            for (r in remote) {
                val key = normName(r.name)
                if (r.id in linkedRemoteIds) continue
                if (key in existingNames) continue
                val cur = best[key]
                if (cur == null || r.trackCatalogIds.size > cur.trackCatalogIds.size) best[key] = r
            }
            return best.values.toList()
        }

        fun pushSummaryText(created: Int, updated: Int, addedTracks: Int, unchanged: Int, failed: Int): String {
            val parts = mutableListOf<String>()
            if (created > 0) parts += "created $created"
            if (updated > 0) parts += "updated $updated (+$addedTracks song${if (addedTracks == 1) "" else "s"})"
            if (unchanged > 0) parts += "$unchanged already in sync"
            if (failed > 0) parts += "$failed failed"
            return if (parts.isEmpty()) "Nothing to push" else parts.joinToString(" · ")
        }

        fun reportSummaryText(changes: List<AmSyncReport.Change>, errors: List<String>): String {
            val parts = mutableListOf<String>()
            val created = changes.count { it.kind == "created" }
            val updated = changes.count { it.kind == "updated" }
            val reconciled = changes.count { it.kind == "reconciled" }
            val imported = changes.count { it.kind == "imported" }
            if (created > 0) parts += "$created created"
            if (updated > 0) parts += "$updated updated"
            if (reconciled > 0) parts += "$reconciled reconciled"
            if (imported > 0) parts += "$imported imported"
            if (parts.isEmpty()) parts += "Everything in sync"
            if (errors.isNotEmpty()) parts += "${errors.size} error${if (errors.size == 1) "" else "s"}"
            return parts.joinToString(" · ")
        }
    }
}

/** Production [AmSyncHost] over the live collections store + catalog snapshot. */
class CollectionsAmSyncHost(
    private val store: com.levi.pocketdj.data.collections.CollectionsStore,
    private val catalog: () -> com.levi.pocketdj.data.catalog.MergedCatalog?,
) : AmSyncHost {
    override val playlists get() = store.playlists
    override val pockets get() = store.pockets
    override fun songIdsForPlaylist(id: String) = store.songIdsForPlaylist(id)
    override fun songIdsForPocket(id: String) = store.songIdsForPocket(id)
    override fun song(id: String): IndexSong? = catalog()?.songsById?.get(id)
    override fun duplicateIdentity(songId: String) = store.duplicateIdentity(songId)
    override val sourcePlaylists: List<SourcePlaylist> get() = catalog()?.playlists.orEmpty()
    override fun songIdByAppleMusicId(): Map<String, String> {
        val out = HashMap<String, String>()
        catalog()?.songsById?.forEach { (id, s) -> s.appleMusicId?.let { out[it] = id } }
        return out
    }
    override fun linkPlaylist(playlistId: String, amPlaylistId: String) = store.linkToAppleMusic(playlistId, amPlaylistId)
    override fun linkPocket(pocketId: String, amPlaylistId: String) = store.linkPocketToAppleMusic(pocketId, amPlaylistId)
    override fun createPlaylist(name: String, songIds: List<String>, source: SourcePlaylist?) =
        store.createPlaylist(name, songIds, source)
}

/**
 * Outcome of reconciling an app-created Apple Music playlist to an exact ordered track list
 * (iOS `PlaylistReconcileResult`; the destructive remove + reorder half of the hybrid sync).
 */
sealed interface PlaylistReconcileResult {
    /** Contents now equal the ordered target; added/removed are the net MEMBERSHIP delta (reorders alone are 0/0). */
    data class Edited(val count: Int, val added: Int, val removed: Int) : PlaylistReconcileResult
    data object AlreadyInSync : PlaylistReconcileResult
    /** Apple refused the edit (or the live rows can't be judged safely) - nothing was touched. */
    data object NotEditable : PlaylistReconcileResult
    /** Empty target: refuse to wipe the playlist (the "empty != deletion" guard). */
    data object SkippedEmpty : PlaylistReconcileResult
    data object Unsupported : PlaylistReconcileResult
}

/**
 * PURE diff of a live library playlist against the target order. The Web API has no replace-all, so a
 * reconcile is DELETE(rows) + POST(append): the minimal delete set keeps the longest prefix already
 * correct, so a removal-only change never rewrites a track it did not have to.
 */
object PlaylistReconcilePlanner {
    sealed interface Plan {
        data object AlreadyInSync : Plan
        /** Live rows lack an id we can reason about (e.g. an uploaded file): fail closed. */
        data object Unsafe : Plan
        data class Edit(
            val deleteLibraryIds: List<String>,
            val appendCatalogIds: List<String>,
            val added: Int,
            val removed: Int,
        ) : Plan
    }

    /** A 4xx on the first DELETE (not auth / rate-limit) means "this playlist can't be edited here". */
    fun isRefusal(status: Int?): Boolean = status != null && status in 400..499 && status != 401 && status != 429

    fun plan(live: List<AmTrackRow>, target: List<String>): Plan {
        if (live.any { it.libraryId == null || it.catalogId == null }) return Plan.Unsafe
        val targetSet = target.toSet()
        // Judge each live row by its WHOLE id set (iOS catalogIds(of:)): an equivalent id of a target
        // song counts as that song, so a regional/reissue mapping is not a perpetual remove + re-add.
        val liveCat = live.map { r ->
            if (r.catalogId!! in targetSet) r.catalogId
            else r.equivalentIds.firstOrNull { it in targetSet } ?: r.catalogId
        }
        if (liveCat == target) return Plan.AlreadyInSync
        val liveSet = liveCat.toSet()
        val added = target.count { it !in liveSet }
        val removed = liveCat.count { it !in targetSet }
        val kept = live.indices.filter { liveCat[it] in targetSet }
        val keptCat = kept.map { liveCat[it] }
        var keepFrom: Int
        var deletes: List<AmTrackRow>
        // DELETE addresses the SONG (library id), not the entry: a deleted id that also sits in the kept
        // prefix would remove that copy too, so such a plan is not allowed.
        fun clashes(del: List<AmTrackRow>, keptRows: List<AmTrackRow>) =
            del.map { it.libraryId }.toSet().let { d -> keptRows.any { it.libraryId in d } }
        val removalOnly = keptCat.size <= target.size && target.subList(0, keptCat.size) == keptCat &&
            !clashes(live.filterIndexed { i, _ -> liveCat[i] !in targetSet }, kept.map { live[it] })
        if (removalOnly) {
            deletes = live.filterIndexed { i, _ -> liveCat[i] !in targetSet }
            keepFrom = keptCat.size
        } else {
            var p = 0
            while (p < liveCat.size && p < target.size && liveCat[p] == target[p]) p++
            while (true) {
                val d = live.drop(p).map { it.libraryId }.toSet()
                val firstClash = live.take(p).indexOfFirst { it.libraryId in d }
                if (firstClash < 0) break
                p = firstClash
            }
            deletes = live.drop(p)
            keepFrom = p
        }
        // Only re-add what THIS pass deleted. Anything else missing is the push's job: a just-pushed track
        // may not be visible in the (eventually consistent) read yet, and appending it here would duplicate it.
        val budget = HashMap<String, Int>()
        val delIdx = if (removalOnly) live.indices.filter { liveCat[it] !in targetSet } else (keepFrom until live.size).toList()
        if (!removalOnly) for (i in delIdx) budget.merge(liveCat[i], 1, Int::plus)
        val append = if (removalOnly) emptyList() else target.drop(keepFrom).filter { id ->
            val n = budget[id] ?: 0
            if (n > 0) { budget[id] = n - 1; true } else false
        }
        if (deletes.isEmpty() && append.isEmpty()) return Plan.AlreadyInSync
        return Plan.Edit(deletes.map { it.libraryId!! }.distinct(), append, added, removed)
    }
}
