package com.levi.pocketdj.data.games

import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Durable log of game RUNS (one row per finished round/session): the Games tab scoreboard.
 * Port of iOS `GameScoreboardStore` (`pocketdj-game-scores.json`).
 *
 * DELETION NEEDS TOMBSTONES. The log is a grow-only union across devices ([reloadFromDisk]
 * unions the on-disk doc by run id), so a plain row drop is undone by the next peer pull. A
 * tombstone is a positive assertion ("this id is gone") that survives a union:
 *
 *     live  = (localRuns ∪ docRuns) ∖ ids(localTombs ∪ docTombs)
 *     saved = live, ids(localTombs ∪ docTombs)
 *
 * Both halves are id-keyed grow-only unions, so the merge is commutative, associative and
 * idempotent. The 500-run cap trim is a local DISPLAY bound and NEVER tombstones.
 *
 * Thread-safety: every mutation is serialized on [lock]; saves are small synchronous atomic
 * writes (tmp + rename), so call mutators off the main thread if the log is large.
 */
class GameScoreboardStore(
    private val file: File,
    private val newId: () -> String = ScoreboardCodec::newId,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    data class State(val runs: List<RunRecord>, val tombstones: List<Tombstone>, val revision: Int)

    private val lock = Any()
    private var runsList: List<RunRecord> = emptyList()
    private var tombList: List<Tombstone> = emptyList()
    private var deletedIds: Set<String> = emptySet()
    private var revisionCounter = 0

    var installId: String = ""
        private set

    private val _state = MutableStateFlow(State(emptyList(), emptyList(), 0))
    val state: StateFlow<State> = _state.asStateFlow()

    /** Oldest -> newest. */
    val runs: List<RunRecord> get() = _state.value.runs
    val tombstones: List<Tombstone> get() = _state.value.tombstones
    val revision: Int get() = _state.value.revision

    init {
        val doc = readDocument()
        installId = doc?.installId ?: newId()
        // Tombstones FIRST, then filter the runs through them: a racing peer document can carry
        // both a run and its tombstone, and launch must never show it.
        adopt(doc?.deleted.orEmpty())
        runsList = doc?.runs.orEmpty().filter { it.id !in deletedIds }
        publish()
    }

    /** Record a finished run (zero-score runs included). */
    fun record(
        game: GameKind,
        score: Int,
        settingsSummary: String?,
        detail: Map<String, String>? = null,
        atMs: Double = clock(),
    ): RunRecord = synchronized(lock) {
        val run = RunRecord(
            id = newId().uppercase(), game = game.token, score = score, at = atMs,
            settingsSummary = settingsSummary, detail = detail, originInstallId = installId,
        )
        var next = runsList + run
        // The cap trim NEVER tombstones (local display bound, not a user deletion).
        if (next.size > MAX_RUNS) next = next.subList(next.size - MAX_RUNS, next.size).toList()
        runsList = next
        revisionCounter++
        publish()
        save()
        run
    }

    fun bestScore(game: GameKind): Int? = runs.filter { it.game == game.token }.maxOfOrNull { it.score }

    /** The best run: highest score, newest wins a tie. */
    fun bestRun(game: GameKind): RunRecord? =
        runs.filter { it.game == game.token }.reduceOrNull { a, b -> if (b.score > a.score || (b.score == a.score && b.at >= a.at)) b else a }

    /** Newest first. */
    fun recentRuns(game: GameKind, limit: Int): List<RunRecord> =
        runs.filter { it.game == game.token }.takeLast(limit.coerceAtLeast(0)).reversed()

    /**
     * Rounds played, share of DECIDED rounds (pocket or broke; abandoned predicted nothing) that
     * stayed in the pocket, and streaks. Abandoned rounds neither extend nor break a streak.
     */
    fun inThePocketStats(): InThePocketStats {
        val rows = runs.filter { it.game == GameKind.InThePocket.token }.sortedBy { it.at }
        var pockets = 0
        var decided = 0
        var streak = 0
        var best = 0
        for (r in rows) {
            when (r.detail?.get("outcome")) {
                "pocket" -> { pockets++; decided++; streak++; best = maxOf(best, streak) }
                "broke" -> { decided++; streak = 0 }
                else -> Unit
            }
        }
        return InThePocketStats(
            rounds = rows.size, pockets = pockets,
            pocketRate = if (decided > 0) pockets.toDouble() / decided else null,
            bestStreak = best, currentStreak = streak,
        )
    }

    // MARK: - Deletion (tombstoned)

    /** Delete every run of ONE game. Returns how many rows went. */
    fun delete(game: GameKind, atMs: Double = clock()): Int = synchronized(lock) {
        deleteRuns(runsList.filter { it.game == game.token }, atMs)
    }

    /** Delete EVERY run of EVERY game. */
    fun deleteAll(atMs: Double = clock()): Int = synchronized(lock) { deleteRuns(runsList, atMs) }

    private fun deleteRuns(doomed: List<RunRecord>, atMs: Double): Int {
        if (doomed.isEmpty()) return 0
        val ids = doomed.map { it.id }.toSet()
        runsList = runsList.filter { it.id !in ids }
        adopt(tombList + doomed.map { Tombstone(it.id, atMs, installId) })
        revisionCounter++
        publish()
        save()
        return doomed.size
    }

    /** Returns how many ids are NEWLY suppressed. */
    private fun adopt(incoming: List<Tombstone>): Int {
        val merged = ScoreboardCodec.unionTombstones(incoming)
        val before = deletedIds
        tombList = merged
        deletedIds = merged.mapTo(HashSet()) { it.id }
        return (deletedIds - before).size
    }

    /**
     * UNION the on-disk document into the live log after a sync pull: id-keyed, idempotent,
     * conditional save. Returns true when the merged document was written back (the doc was
     * stale with respect to us). The stale test is ID-BASED: the load-bearing case (we deleted
     * everything, the doc still holds the runs) has no extra runs to count.
     */
    fun reloadFromDisk(): Boolean = synchronized(lock) {
        val doc = readDocument() ?: return false
        val docTombs = doc.deleted.orEmpty()
        val tombsAdded = adopt(tombList + docTombs)

        val byId = LinkedHashMap<String, RunRecord>()
        for (r in runsList) byId.putIfAbsent(r.id, r)
        var addedFromDisk = 0
        for (r in doc.runs) if (byId.putIfAbsent(r.id, r) == null) addedFromDisk++
        val before = runsList.size
        var merged = byId.values.filter { it.id !in deletedIds }.sortedBy { it.at }
        if (merged.size > MAX_RUNS) merged = merged.subList(merged.size - MAX_RUNS, merged.size).toList()
        runsList = merged
        val rowsDropped = maxOf(0, before + addedFromDisk - runsList.size)

        val docRunIds = doc.runs.mapTo(HashSet()) { it.id }
        val docTombIds = docTombs.mapTo(HashSet()) { it.id }
        val mustSave = runsList.any { it.id !in docRunIds } ||
            !docTombIds.containsAll(deletedIds) ||
            docRunIds.any { it in deletedIds }
        if (addedFromDisk > 0 || rowsDropped > 0 || tombsAdded > 0 || mustSave) {
            revisionCounter++
            publish()
        }
        if (!mustSave) return false
        save()
        true
    }

    /**
     * HARD WIPE: account deletion / "Reset everything" and the authoritative fixture seed. NOT
     * the user-facing delete (that tombstones); leaving tombstones behind after erasure would
     * be residual personal data.
     */
    fun clear() = synchronized(lock) {
        runsList = emptyList()
        tombList = emptyList()
        deletedIds = emptySet()
        revisionCounter++
        publish()
        save()
    }

    /**
     * Debug seed: 3 puzzle runs (5/9/7) + 1 Music with Friends run (4). [replaceExisting] clears
     * the log (and the saved doc) first; otherwise it is a no-op when runs already exist, so a
     * demo seed never eats a real player's history.
     */
    fun seedFixture(replaceExisting: Boolean = false, nowMs: Double = clock()) {
        synchronized(lock) {
            if (replaceExisting) {
                if (runsList.isNotEmpty() || tombList.isNotEmpty()) clear()
            } else if (runsList.isNotEmpty()) {
                return
            }
            val hour = 3_600_000.0
            record(GameKind.CollectorsPuzzle, 5, "2:00 · 1 target", atMs = nowMs - 30 * hour)
            record(GameKind.CollectorsPuzzle, 9, "2:00 · 2 targets", atMs = nowMs - 20 * hour)
            record(GameKind.CollectorsPuzzle, 7, "1:00 · 1 target", atMs = nowMs - 10 * hour)
            record(GameKind.MusicWithFriends, 4, "90s road-trip anthems", mapOf("sessionId" to "seedmwf1"), nowMs - 5 * hour)
        }
    }

    // MARK: - Persistence

    private fun publish() {
        _state.value = State(runsList, tombList, revisionCounter)
    }

    private fun readDocument(): ScoreboardDocument? {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null
        return ScoreboardCodec.decode(text)
    }

    private fun save() {
        // null (not []) when nothing is deleted so the key is omitted entirely.
        val doc = ScoreboardDocument(
            installId = installId, runs = runsList,
            deleted = tombList.ifEmpty { null },
        )
        val bytes = runCatching { ScoreboardCodec.encode(doc).toByteArray(Charsets.UTF_8) }.getOrNull() ?: return
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) {
                file.writeBytes(bytes)
                tmp.delete()
            }
        }
    }

    companion object {
        const val MAX_RUNS = 500

        /** 4x [MAX_RUNS], evicted OLDEST-FIRST (see iOS rationale: no local convergence signal). */
        const val MAX_TOMBSTONES = 2000
    }
}
