package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.EvictionPlan
import com.levi.pocketdj.data.burns.TemporaryHold
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.util.concurrent.atomic.AtomicBoolean
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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

    /** Song id -> temporary (buffer-lane) hold. Empty by default: a port without a ledger has no temporary assets. */
    fun temporaryHolds(): Map<String, TemporaryHold> = emptyMap()

    /** Delete exactly what these songs' holds list (`BurnStore.removeTemporaryAssets`). */
    fun removeTemporaryAssets(songIds: List<String>): TemporaryRemoval = TemporaryRemoval()
}

class BurnStorePruneAdapter(private val store: BurnStore) : PruneBurns {
    override fun items(): Collection<BurnItem> = store.items.value.values
    override fun plan(order: List<String>, capBytes: Long, capSongs: Int) =
        store.planEvictionSweepingOrphans(order, capBytes, capSongs)
    // Storage-pressure eviction stays local-only: the user's browsable folder copy is kept.
    override fun removeBurns(songIds: List<String>) = store.removeBurns(songIds, mirrored = false)
    override fun temporaryHolds(): Map<String, TemporaryHold> = store.temporaryHolds.value
    override fun removeTemporaryAssets(songIds: List<String>) = store.removeTemporaryAssets(songIds)
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
    /** Runs the debounced cap sweep a landing hold schedules; null = [scheduleCapSweepIfNeeded] is inert. */
    private val scope: CoroutineScope? = null,
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
                withContext(io) { evict(go, protected) }
                gone += go.filter { id -> burns.items().none { it.songId == id } }
                start = end
                yield()
            }
            return finish(run, skipped, gone)
        } finally {
            pruning.set(false)
        }
    }

    /**
     * One eviction batch. A song that is still TEMPORARY (buffered audio) goes through the hold-scoped
     * primitive - only what its hold lists, so stems the user pinned for it survive - and every other
     * song through the ordinary `removeBurns`.
     */
    private fun evict(ids: List<String>, protected: Set<String>) {
        if (ids.isEmpty()) return
        val holds = burns.temporaryHolds()
        val bases = TemporarySweep.bases(protected)
        val temp = ids.filter { holds[it]?.audio == true && !TemporarySweep.isProtected(it, protected, bases) }
        if (temp.isNotEmpty()) burns.removeTemporaryAssets(temp)
        burns.removeBurns(ids.filter { holds[it]?.audio != true })
    }

    private class Run(val cap: ActiveCap, val plan: EvictionPlan, val itemsBefore: Map<String, BurnItem>)

    private suspend fun begin(): Run? {
        val cap = activeCap() ?: return null
        settings.stampPrune(clock()) // STAMP FIRST — before any listing or deletion
        val protected = protectedSongIds()
        val items = burns.items()
        // LRP: never-played (0) ahead of everything, oldest download breaking ties. A substituted
        // (clean/explicit) burn is keyed "sng_x_clean" while plays are recorded against the BASE id.
        // TEMPORARY (buffered) songs go first, soonest expiry first - they were never asked for - then the
        // pinned burns, least-recently-played first.
        val tempFirst = TemporarySweep.softCapTemporaryFirst(
            burns.temporaryHolds().values,
            items.asSequence().filter { it.state == BurnState.READY }.map { it.songId }.toSet(),
            protected,
        )
        val tempSet = tempFirst.toSet()
        val order = tempFirst + items.asSequence()
            .filter { it.state == BurnState.READY && it.songId !in protected && it.songId !in tempSet }
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

    // ---- temporary-asset expiry sweep (np-mix-mode phase 1) -----------------------------------

    @Volatile var lastSweep: SweepResult? = null
        private set

    /** A cap sweep scheduled by a hold landing, not yet run (debounce). */
    private val capSweepScheduled = AtomicBoolean(false)

    /**
     * The EXPIRY SWEEP: delete temporary (buffered) assets past their TTL - and, over the buffer cap
     * (or [capOverrideBytes]), the soonest-expiring ones - never anything protected, and never
     * anything without a hold. Not gated on the soft cap. Null when a prune/sweep is already running.
     *
     * Crash-loop discipline: the stamp is written FIRST, the plan is ONE pass over the ledger (no disk
     * scan), deletion runs in chunks of [TemporarySweep.CHUNK] with a yield between them, and the
     * protected set is RE-READ and each hold RE-VALIDATED per chunk (a pin, a deck load or a track
     * change mid-sweep is honoured). [ignoreExpiry] = "Clear now".
     */
    suspend fun sweepTemporary(
        now: Long = clock(),
        reason: String,
        ignoreExpiry: Boolean = false,
        capOverrideBytes: Long? = null,
    ): SweepResult? {
        if (!pruning.compareAndSet(false, true)) return null
        try {
            val holds = withContext(io) { burns.temporaryHolds() }
            if (holds.isEmpty()) return SweepResult().also { lastSweep = it }
            settings.stampTemporarySweep(now) // STAMP FIRST - before any planning or deletion
            val capBytes = capOverrideBytes?.coerceAtLeast(0L) ?: settings.bufferCapBytes()
            val plan = TemporarySweep.planSweep(holds.values, now.toDouble(), capBytes, protectedSongIds(), ignoreExpiry)
            log("temporary sweep start reason=$reason holds=${holds.size} footprint=${holds.values.sumOf { it.bytes }} cap=$capBytes n=${plan.delete.size} protected=${plan.skippedProtected}")
            var removed = 0; var freed = 0L; var kept = 0; var skipped = plan.skippedProtected
            var start = 0
            while (start < plan.delete.size) {
                val end = minOf(start + TemporarySweep.CHUNK, plan.delete.size)
                val protected = protectedSongIds() // re-read per chunk
                val bases = TemporarySweep.bases(protected)
                val live = burns.temporaryHolds()
                var footprint = live.values.sumOf { it.bytes }
                val chunk = plan.delete.subList(start, end).filter { id ->
                    val h = live[id] ?: return@filter false // pinned meanwhile
                    if (TemporarySweep.isProtected(id, protected, bases)) { skipped++; return@filter false }
                    // An expiry pick whose hold a fresh landing extended is spared; cap picks are re-checked.
                    if (!(ignoreExpiry || h.expiresAtMs <= now || footprint > capBytes)) return@filter false
                    footprint -= h.bytes
                    true
                }
                if (chunk.isNotEmpty()) {
                    val r = withContext(io) { burns.removeTemporaryAssets(chunk) }
                    removed += r.songs; freed += r.bytes; kept += r.kept
                }
                start = end
                yield()
            }
            val result = SweepResult(removed, freed, skipped, kept, remaining = burns.temporaryHolds().size)
            log("temporary sweep reason=$reason deleted=$removed freed=$freed kept=$kept protected=$skipped left=${result.remaining}")
            lastSweep = result
            return result
        } finally {
            pruning.set(false)
        }
    }

    /**
     * The gated sweep for launch / foreground / the hourly tick / the prune job: a no-op with no holds,
     * while a prune/sweep runs, or when the last sweep STARTED less than [minIntervalMs] ago.
     */
    suspend fun sweepTemporaryIfDue(reason: String, minIntervalMs: Long = TemporarySweep.INTERVAL_MS): SweepResult? {
        if (isPruning || withContext(io) { burns.temporaryHolds().isEmpty() }) return null
        val now = clock()
        val last = settings.lastTemporarySweepAt()
        if (last != null && now >= last && now - last < minIntervalMs) return null
        return sweepTemporary(now, reason)
    }

    /**
     * A hold just landed or Mix Mode went off: when the temporary footprint is over the buffer cap, run
     * ONE cap sweep on a later turn (debounced - a burst of stem parts schedules a single pass and the
     * landing call never waits on deletes).
     */
    fun scheduleCapSweepIfNeeded() {
        val sc = scope ?: return
        if (capSweepScheduled.get()) return
        if (burns.temporaryHolds().values.sumOf { it.bytes } <= 0L) return
        if (!capSweepScheduled.compareAndSet(false, true)) return
        sc.launch(io) {
            yield()
            capSweepScheduled.set(false)
            val over = burns.temporaryHolds().values.sumOf { it.bytes } > settings.bufferCapBytes()
            if (over && sweepTemporary(reason = "cap") == null) {
                // A prune/sweep was running and dropped this pass: retry once it finishes.
                delay(2_000)
                scheduleCapSweepIfNeeded()
            }
        }
    }

    /**
     * Disk guard (before every buffer step): sweep the soonest-expiring unprotected buffers down to
     * [targetFootprintBytes]. Null when a prune/sweep is already running.
     */
    suspend fun sweepForDiskGuard(targetFootprintBytes: Long): SweepResult? =
        sweepTemporary(reason = "diskguard", capOverrideBytes = targetFootprintBytes)
}
