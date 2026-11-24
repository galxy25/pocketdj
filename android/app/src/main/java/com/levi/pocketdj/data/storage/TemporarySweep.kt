package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.TemporaryHold
import com.levi.pocketdj.data.edition.SongVariant
import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** The outcome of one temporary sweep (iOS `StorageManager.SweepResult`). */
data class SweepResult(
    /** Holds fully removed (songs). */
    val removed: Int = 0,
    /** Ledger-credited bytes deleted. */
    val freedBytes: Long = 0,
    /** Eligible holds spared because something is using them. */
    val skippedProtected: Int = 0,
    /** Holds kept in part (unreachable folder). */
    val kept: Int = 0,
    /** Holds left afterwards. */
    val remaining: Int = 0,
)

/** What one `BurnStore.removeTemporaryAssets` call did (iOS `TemporaryRemoval`). */
data class TemporaryRemoval(val songs: Int = 0, val bytes: Long = 0, val kept: Int = 0)

/** The pure rules of the temporary-asset expiry sweep (iOS `StorageManager.planSweep` & co.). */
object TemporarySweep {
    /** Holds removed per turn - the same chunk the soft-cap prune uses. */
    const val CHUNK = StorageSettings.EVICTION_CHUNK

    /** While-foreground cadence of the expiry sweep (the gate for launch/foreground/tick/job). */
    const val INTERVAL_MS = 60L * 60 * 1000

    /** Picked-folder identity tolerance: a file's mtime within +-2 s of the recorded one is still ours. */
    const val IDENTITY_TOLERANCE_MS = 2_000.0

    /**
     * [ids] plus each id's BASE: a hold keyed by an edition variant ("sng_x_clean") is spared when the
     * base row is playing and vice versa - over-protecting only ever keeps a file a little longer.
     */
    fun bases(ids: Set<String>): Set<String> = ids.mapTo(HashSet()) { SongVariant.baseId(it) }

    fun isProtected(id: String, protected: Set<String>, bases: Set<String>): Boolean =
        id in protected || SongVariant.baseId(id) in bases

    /** Soonest expiry first, song id breaking ties (deterministic). */
    val expiryOrder: Comparator<TemporaryHold> = compareBy<TemporaryHold>({ it.expiresAtMs }, { it.songId })

    class Plan(val delete: List<String>, val skippedProtected: Int)

    /**
     * PURE PLAN (no disk I/O - the ledger's credited bytes only): the holds to delete, in order -
     * every EXPIRED unprotected hold (soonest expiry first; [ignoreExpiry] = "Clear now": all of
     * them), then, while the remaining temporary footprint is still over [capBytes], the
     * soonest-expiring unprotected holds that have not expired yet. An expired-but-protected hold is
     * counted and left for the next sweep.
     */
    fun planSweep(
        holds: Collection<TemporaryHold>, now: Double, capBytes: Long, protected: Set<String>,
        ignoreExpiry: Boolean = false,
    ): Plan {
        val bases = bases(protected)
        val ordered = holds.sortedWith(expiryOrder)
        val delete = ArrayList<String>()
        var skipped = 0
        var footprint = holds.sumOf { it.bytes }
        val rest = ArrayList<TemporaryHold>()
        for (h in ordered) {
            if (!(ignoreExpiry || h.expiresAtMs <= now)) { rest.add(h); continue }
            if (isProtected(h.songId, protected, bases)) { skipped++; continue }
            delete.add(h.songId)
            footprint -= h.bytes
        }
        for (h in rest) {
            if (footprint <= capBytes) break
            if (isProtected(h.songId, protected, bases)) continue
            delete.add(h.songId)
            footprint -= h.bytes
        }
        return Plan(delete, skipped)
    }

    /**
     * Soft-cap prune order head (iOS `beginPrune`): the unprotected, still-ready temporary holds
     * (audio held), soonest expiry first. The caller appends the least-recently-played pinned burns.
     */
    fun softCapTemporaryFirst(
        holds: Collection<TemporaryHold>, readyIds: Set<String>, protected: Set<String>,
    ): List<String> {
        val bases = bases(protected)
        return holds.asSequence()
            .filter { it.audio && it.songId in readyIds && !isProtected(it.songId, protected, bases) }
            .sortedWith(expiryOrder)
            .map { it.songId }
            .toList()
    }

    /**
     * Picked-folder identity (iOS `userFolderFileIsOurs`): may the sweep delete [name]? A hold with no
     * identity map predates it (path rules only -> true); a name never recorded is not provably ours;
     * an unreadable mtime ([currentMtimeMs] null) is left to the other checks; otherwise the file
     * must be unchanged since the buffer lane wrote it.
     */
    fun fileIsOurs(hold: TemporaryHold, name: String, currentMtimeMs: Double?): Boolean {
        val files = hold.userFolderFiles ?: return true
        val recorded = files[name] ?: return false
        val now = currentMtimeMs ?: return true
        return abs(now - recorded) <= IDENTITY_TOLERANCE_MS
    }

    /**
     * The hold left after a removal pass: audio cleared when [audioDone], stem parts narrowed to
     * [keptParts]. Null when nothing is left (the hold is forgotten, its identity map with it).
     */
    fun afterRemoval(h: TemporaryHold, audioDone: Boolean, keptParts: List<String>): TemporaryHold? {
        val kept = keptParts.toSet()
        val u = h.copy(
            audio = if (audioDone) false else h.audio,
            audioBytes = if (audioDone) null else h.audioBytes,
            stemParts = keptParts,
            stemBytes = h.stemBytes?.filterKeys { it in kept }?.takeIf { it.isNotEmpty() },
            stemPartsInUserFolder = h.stemPartsInUserFolder?.filter { it in kept }?.takeIf { it.isNotEmpty() },
        )
        return if (u.isEmpty) null else u
    }
}

/**
 * Repeats [action] every [intervalMs] while started (the "hourly while in the foreground" tick).
 * [start] is idempotent; [stop] (backgrounding) cancels the pending wait.
 */
class SweepTicker(
    private val scope: CoroutineScope,
    private val intervalMs: Long,
    private val action: suspend () -> Unit,
) {
    private var job: Job? = null

    @Synchronized fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            while (isActive) {
                delay(intervalMs)
                runCatching { action() }
            }
        }
    }

    @Synchronized fun stop() {
        job?.cancel()
        job = null
    }

    val isRunning: Boolean @Synchronized get() = job?.isActive == true
}
