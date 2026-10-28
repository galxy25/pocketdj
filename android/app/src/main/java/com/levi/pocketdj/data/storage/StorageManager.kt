package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.EvictionPlan
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.util.concurrent.atomic.AtomicBoolean
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

/**
 * Song ids the prune must spare RIGHT NOW. A substituted clean/explicit row's burn is keyed by its
 * [QueueItem.resolveId] ("sng_x_clean"), not its base id, so BOTH are protected (iOS inserts
 * `queue[index].id` and `.resolveId`); deck-loaded ids are added as-is.
 */
fun protectedIds(current: QueueItem?, deckSongIds: List<String?> = emptyList()): Set<String> = buildSet {
    current?.let { add(it.id); add(it.resolveId) }
    deckSongIds.forEach { it?.let(::add) }
}

/** The slice of BurnStore the prune needs — a port so the ordering/gate logic is a pure JVM test. */
interface PruneBurns {
    fun items(): Collection<BurnItem>
    /** ONE listing per root: sweeps orphan aux first when over [capBytes], then plans. Deletes no burn. */
    fun plan(order: List<String>, capBytes: Long, capSongs: Int): EvictionPlan
    fun removeBurns(songIds: List<String>)
}

class BurnStorePruneAdapter(private val store: BurnStore) : PruneBurns {
    override fun items(): Collection<BurnItem> = store.items.value.values
    override fun plan(order: List<String>, capBytes: Long, capSongs: Int) =
        store.planEvictionSweepingOrphans(order, capBytes, capSongs)
    override fun removeBurns(songIds: List<String>) = store.removeBurns(songIds)
}

/**
 * The soft-cap PRUNE engine (iOS `StorageManager`). No cap set => never deletes. With a cap, at
 * most once per [StorageSettings.PRUNE_INTERVAL_MS], evicts burned media least-recently-played
 * first until the footprint fits. Removes downloaded media only — catalog/collections/settings
 * are untouched.
 *
 * Crash-loop discipline (the 35 GB -> 32 GB incident): the gate stamp is written FIRST, before
 * any planning or deletion, so a process death mid-prune never retries on the next launch; ONE
 * directory listing per root plans the whole pass (never a rescan per eviction); eviction runs
 * in chunks of [StorageSettings.EVICTION_CHUNK] yielding between them; the protected (deck-
 * loaded) set is re-read per chunk.
 */
class StorageManager(
    private val burns: PruneBurns,
    private val playStats: PlayStatsStore,
    private val settings: StorageSettingsPort,
    /** Song ids that must not be pruned RIGHT NOW (deck-loaded / now-playing). */
    var protectedSongIds: () -> Set<String> = { emptySet() },
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
    /** Disk work (listing, orphan deletes, burn removal) runs here, never on the caller (Main) dispatcher. */
    private val io: CoroutineContext = Dispatchers.IO,
) {
    data class PruneResult(
        val evicted: Int = 0,
        val freedBytes: Long = 0,
        /** Burned footprint AFTER the prune. */
        val usageBytes: Long = 0,
        /** 0 => no byte cap was in force. */
        val capBytes: Long = 0,
        val usageSongs: Int = 0,
        /** 0 => no songs cap was in force. */
        val capSongs: Int = 0,
    )

    @Volatile var lastResult: PruneResult? = null
        private set

    private val pruning = AtomicBoolean(false)
    val isPruning: Boolean get() = pruning.get()

    suspend fun activeCap(): ActiveCap? = resolveActiveCap(settings.capGB(), settings.capSongs())

    /** The once-per-20h gate: a cap must be SET and the last run old enough. */
    suspend fun pruneIfDue(): PruneResult? {
        if (activeCap() == null || isPruning) return null
        val last = settings.lastPruneAt()
        if (last != null && clock() - last < StorageSettings.PRUNE_INTERVAL_MS) return null
        return prune()
    }

    /** Plan once, evict in chunks yielding between them. Null when no cap is active or already running. */
    suspend fun prune(): PruneResult? {
        if (!pruning.compareAndSet(false, true)) return null
        try {
            val run = withContext(io) { begin() } ?: return null
            var start = 0
            val skipped = ArrayList<String>()
            val gone = ArrayList<String>()
            while (start < run.plan.evict.size) {
                val end = minOf(start + StorageSettings.EVICTION_CHUNK, run.plan.evict.size)
                // Re-read per chunk: a song loaded onto a deck mid-prune is spared.
                val protected = protectedSongIds()
                val (spare, go) = run.plan.evict.subList(start, end).partition { it in protected }
                skipped += spare
                withContext(io) { burns.removeBurns(go) }
                gone += go.filter { id -> burns.items().none { it.songId == id } }
                start = end
                yield()
            }
            return finish(run, skipped, gone)
        } finally {
            pruning.set(false)
        }
    }

    private class Run(val cap: ActiveCap, val plan: EvictionPlan, val itemsBefore: Map<String, BurnItem>)

    private suspend fun begin(): Run? {
        val cap = activeCap() ?: return null
        settings.stampPrune(clock()) // STAMP FIRST — before any listing or deletion
        val protected = protectedSongIds()
        val items = burns.items()
        // LRP: never-played (0) ahead of everything, oldest download breaking ties. A substituted
        // (clean/explicit) burn is keyed "sng_x_clean" while plays are recorded against the BASE id.
        val order = items.asSequence()
            .filter { it.state == BurnState.READY && it.songId !in protected }
            .map { it to (playStats.lastPlayedAt(SongVariant.baseId(it.songId)) ?: 0.0) }
            .sortedWith(compareBy<Pair<BurnItem, Double>> { it.second }.thenBy { it.first.downloadedAt })
            .map { it.first.songId }
            .toList()
        val plan = burns.plan(order, cap.bytes ?: Long.MAX_VALUE, cap.songs ?: Int.MAX_VALUE)
        log("prune start usage=${plan.usageBytes} cap=${cap.bytes ?: 0} capSongs=${cap.songs ?: 0} evict=${plan.evict.size} projected=${plan.projectedBytes}")
        return Run(cap, plan, items.associateBy { it.songId })
    }

    private fun finish(run: Run, skipped: List<String>, gone: List<String>): PruneResult {
        // Arithmetic, not a rescan: planned freed bytes less what the spared songs kept on disk
        // (their FULL planned footprint: sidecar, cut, stems, grid, shared-aware audio).
        val keptBack = skipped.sumOf { run.plan.freedById[it] ?: run.itemsBefore[it]?.bytes ?: 0L }
        val usage = run.plan.projectedBytes + keptBack
        // Pre-sweep footprint (iOS usageBefore) so swept orphan stems/grids count as freed.
        val usageBefore = run.plan.usageBytes + run.plan.sweptBytes
        val readyBefore = run.itemsBefore.values.count { it.state == BurnState.READY }
        val result = PruneResult(
            evicted = gone.size, // actually dropped from the ledger, not merely requested
            freedBytes = maxOf(0L, usageBefore - usage),
            usageBytes = usage,
            capBytes = run.cap.bytes ?: 0L,
            usageSongs = maxOf(0, readyBefore - gone.count { run.itemsBefore[it]?.state == BurnState.READY }),
            capSongs = run.cap.songs ?: 0,
        )
        log("prune done evicted=${result.evicted} freed=${result.freedBytes} usage=$usage")
        lastResult = result
        return result
    }
}
