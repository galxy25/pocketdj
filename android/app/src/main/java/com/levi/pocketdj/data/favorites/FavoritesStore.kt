package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json

/**
 * Per-profile song FAVORITES — Android port of iOS `FavoritesStore` (doctrine 2026-07-20):
 *  1. PER PROFILE, never global (own document `pocketdj-favorites.json`).
 *  2. This store records intent and fires [onChanged]; whether intent leaves the device
 *     (Apple Music two-way sync) is the sync service's call (COL-11).
 *  3. Unfavorites are FIRST-CLASS: stored as `favorited=false` tombstones, never deleted.
 *
 * [onChanged] fires ONLY for user toggles ([set]/[toggle]) — never for remote/seed/import/
 * reload/remap — so exactly one heart/unheart activity row is written per tap.
 */
class FavoritesStore(
    private val file: File,
    private val json: Json = PdjJson.lenient,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
) : FavoritesAccess {

    /** Immutable snapshot for Compose. [revision] bumps on EVERY ♥-set mutation. */
    data class State(
        val favoriteIds: Set<String>,
        val seedVersion: Int,
        val revision: Int,
    )

    private val lock = Any()
    private val byId = LinkedHashMap<String, FavoriteEntry>()
    private var favoriteIdSet = HashSet<String>()
    private var seedVer = 0
    private var rev = 0
    private var saveVersion = 0L
    private var dirty = false

    private val _state = MutableStateFlow(State(emptySet(), 0, 0))
    val state: StateFlow<State> = _state.asStateFlow()

    /** User-originated change hook (the activity heart/unheart wiring). */
    @Volatile
    var onChanged: ((FavoriteEntry) -> Unit)? = null

    init {
        adopt(readDocument())
    }

    val revision: Int get() = synchronized(lock) { rev }
    val seedVersion: Int get() = synchronized(lock) { seedVer }
    val favoriteIds: Set<String> get() = _state.value.favoriteIds

    // ---- Reads -------------------------------------------------------------------------

    /** Reads the internal set under the lock, so it is never stale inside a coalesced block. */
    override fun isFavorite(songId: String): Boolean = synchronized(lock) { favoriteIdSet.contains(songId) }

    /** The explicit entry (favorite OR tombstone); null = never touched. */
    fun entry(songId: String): FavoriteEntry? = synchronized(lock) { byId[songId] }

    fun entries(): List<FavoriteEntry> = synchronized(lock) { byId.values.sortedBy { it.songId } }

    /** Mirrorable entries owed an outbound push (carry an AM id; never pushed or edited since). */
    val pendingPushes: List<FavoriteEntry>
        get() = synchronized(lock) {
            byId.values
                .filter { it.appleMusicId != null && (it.pushedAtMs ?: -1.0) < it.atMs }
                .sortedBy { it.atMs }
        }

    // ---- User writes -------------------------------------------------------------------

    override fun toggle(songId: String, appleMusicId: String?): Boolean {
        val (next, entry) = synchronized(lock) {
            val n = !favoriteIdSet.contains(songId)
            n to setLocked(songId, n, appleMusicId)
        }
        entry?.let { fire(it) }
        return next
    }

    /** Idempotent: a no-op write refreshes nothing and fires nothing. */
    fun set(songId: String, favorited: Boolean, appleMusicId: String?) {
        val entry = synchronized(lock) { setLocked(songId, favorited, appleMusicId) }
        entry?.let { fire(it) }
    }

    /**
     * Mutation under [lock]. Returns the entry owed an [onChanged] call, or null for a no-op
     * (or when inside a coalesced block, where the call is queued until the lock is released).
     */
    private fun setLocked(songId: String, favorited: Boolean, appleMusicId: String?): FavoriteEntry? {
        if (songId.isEmpty()) return null
        val existing = byId[songId]
        if (existing != null && existing.favorited == favorited &&
            existing.appleMusicId == (appleMusicId ?: existing.appleMusicId)
        ) {
            return null
        }
        // The AM id is a property of the SONG — keep a known one when the caller has none.
        val e = FavoriteEntry(songId, favorited, clock(), appleMusicId ?: existing?.appleMusicId, null)
        apply(e)
        save()
        if (saveDepth > 0) {
            // Never run the hook (activity.record takes another store's lock) under our lock.
            pendingFires.add(e)
            return null
        }
        return e
    }

    private val pendingFires = ArrayList<FavoriteEntry>()

    private fun fire(e: FavoriteEntry) {
        onChanged?.invoke(e)
    }

    /** Guarded on the toggle timestamp: a re-toggle while a push was in flight stays pending. */
    fun markPushed(songId: String, pushedAtMs: Double) {
        synchronized(lock) {
            val e = byId[songId] ?: return
            if (e.atMs > pushedAtMs) return
            apply(e.copy(pushedAtMs = pushedAtMs))
            save()
        }
    }

    // ---- Remote / seed / import writes (never fire onChanged) ----------------------------

    /** Adopt Apple Music's view. LOCAL EDITS WIN: a toggle newer than [observedAtMs] survives. */
    fun applyRemote(songId: String, favorited: Boolean, appleMusicId: String?, observedAtMs: Double): Boolean =
        synchronized(lock) {
            val existing = byId[songId]
            if (existing != null) {
                if (existing.atMs > observedAtMs) return false
                if (existing.favorited == favorited) {
                    if ((existing.pushedAtMs ?: -1.0) < existing.atMs) markPushed(songId, observedAtMs)
                    return false
                }
            }
            apply(
                FavoriteEntry(
                    songId, favorited, observedAtMs,
                    appleMusicId ?: existing?.appleMusicId, observedAtMs,
                ),
            )
            save()
            true
        }

    /**
     * Initial-state seed: fills only never-touched songs, once per [version]. Seeded rows are
     * marked pushed so they never generate outbound writes. Returns entries seeded.
     */
    fun applySeed(songIds: List<String>, appleMusicIds: Map<String, String> = emptyMap(), version: Int): Int =
        synchronized(lock) {
            if (version <= seedVer) return 0
            val now = clock()
            var seeded = 0
            for (id in songIds) {
                if (byId.containsKey(id)) continue
                apply(FavoriteEntry(id, true, now, appleMusicIds[id], now))
                seeded++
            }
            seedVer = version
            bump() // the seed generation moved even if nothing was seeded
            save()
            seeded
        }

    /** Re-read the file after a sync pulled a newer copy. No [onChanged]. */
    fun reloadFromDisk() {
        synchronized(lock) { adopt(readDocument()) }
    }

    /** Wipe every favorite and tombstone (destructive "clear all"). No [onChanged]. */
    fun clear() {
        synchronized(lock) {
            dirty = false
            adopt(FavoritesDocument())
            writer.delete(++saveVersion)
        }
    }

    // ---- Backup ------------------------------------------------------------------------

    /** The FULL document (favorites AND tombstones + seedVersion) — same bytes [reloadFromDisk] reads. */
    fun exportData(): String = synchronized(lock) { json.encodeToString(FavoritesDocument.serializer(), snapshotDoc()) }

    /** Merge a backup: per song the NEWER `atMs` wins. No [onChanged]. Returns entries adopted. */
    fun importMerging(data: String): Int {
        val doc = runCatching { json.decodeFromString(FavoritesDocument.serializer(), data) }.getOrNull() ?: return 0
        return synchronized(lock) {
            coalesced {
                var adopted = 0
                for (e in doc.entries) {
                    val existing = byId[e.songId]
                    if (existing != null && existing.atMs > e.atMs) continue
                    apply(e)
                    adopted++
                }
                seedVer = maxOf(seedVer, doc.seedVersion ?: 0)
                bump()
                save()
                adopted
            }
        }
    }

    /**
     * Rewrite song ids after a provisional (`amrec_`) entry is superseded by its indexed
     * replacement. A destination the user already touched explicitly wins.
     */
    fun remapSongIds(pairs: List<Pair<String, String>>) {
        if (pairs.isEmpty()) return
        synchronized(lock) {
            var changed = false
            for ((from, to) in pairs) {
                val e = byId.remove(from) ?: continue
                favoriteIdSet.remove(from)
                bump() // the ♥ set moved even when the destination already exists
                if (!byId.containsKey(to)) apply(e.copy(songId = to))
                changed = true
            }
            if (changed) save()
        }
    }

    // ---- Coalescing + persistence ------------------------------------------------------

    private var saveDepth = 0
    private var saveMissed = false

    /** Run [body], collapsing every save/publish it triggers into one trailing write. */
    fun <T> withCoalescedSaves(body: () -> T): T {
        val result = synchronized(lock) { coalesced(body) }
        // Queued user-toggle hooks fire AFTER the lock is released (no lock nesting).
        val toFire = synchronized(lock) {
            if (saveDepth == 0 && pendingFires.isNotEmpty()) pendingFires.toList().also { pendingFires.clear() } else emptyList()
        }
        toFire.forEach(::fire)
        return result
    }

    private fun <T> coalesced(body: () -> T): T {
        saveDepth++
        try {
            return body()
        } finally {
            saveDepth--
            if (saveDepth == 0 && saveMissed) {
                saveMissed = false
                save()
            }
            if (saveDepth == 0) publish()
        }
    }

    /** ON_STOP barrier: supersede queued writes, write the latest document inline. */
    fun flushNow() {
        synchronized(lock) {
            if (!dirty) return
            dirty = false
            // The queued background write already landed: nothing newer to write inline.
            if (writer.appliedVersion >= saveVersion) return
            val doc = snapshotDoc()
            writer.flushNow(++saveVersion) { json.encodeToString(FavoritesDocument.serializer(), doc) }
        }
    }

    private fun snapshotDoc() = FavoritesDocument(
        entries = byId.values.sortedBy { it.songId },
        seedVersion = seedVer.takeIf { it != 0 },
    )

    private fun save() {
        if (saveDepth > 0) {
            saveMissed = true
            return
        }
        dirty = true
        val doc = snapshotDoc()
        writer.write(++saveVersion) { json.encodeToString(FavoritesDocument.serializer(), doc) }
    }

    private fun bump() {
        rev++
        publish()
    }

    private fun publish() {
        if (saveDepth > 0) return
        _state.value = State(HashSet(favoriteIdSet), seedVer, rev)
    }

    private fun apply(e: FavoriteEntry) {
        byId[e.songId] = e
        if (e.favorited) favoriteIdSet.add(e.songId) else favoriteIdSet.remove(e.songId)
        bump()
    }

    private fun adopt(doc: FavoritesDocument) {
        byId.clear()
        for (e in doc.entries) byId[e.songId] = e
        favoriteIdSet = doc.entries.filter { it.favorited }.mapTo(HashSet()) { it.songId }
        seedVer = doc.seedVersion ?: 0
        bump()
    }

    private fun readDocument(): FavoritesDocument {
        if (!file.exists()) return FavoritesDocument()
        return runCatching { json.decodeFromString(FavoritesDocument.serializer(), file.readText()) }
            .getOrDefault(FavoritesDocument())
    }

    companion object {
        /** iOS parity file name. */
        const val FILE_NAME = "pocketdj-favorites.json"
    }
}

/**
 * Activity wiring: one heart/unheart row per USER toggle. Title/artist are snapshots from the
 * live catalog at record time ([lookup] returns title to artist, or null when the song is
 * unknown — the row then renders from the id alone). Install as `favorites.onChanged`.
 */
fun favoriteActivityRecorder(
    activity: com.levi.pocketdj.data.activity.CollectionActivityStore,
    lookup: (String) -> Pair<String?, String?>?,
): (FavoriteEntry) -> Unit = { entry ->
    val meta = lookup(entry.songId)
    activity.record(
        kind = if (entry.favorited) {
            com.levi.pocketdj.data.activity.ActivityKind.HEART
        } else {
            com.levi.pocketdj.data.activity.ActivityKind.UNHEART
        },
        itemId = entry.songId,
        itemTitle = meta?.first,
        itemArtist = meta?.second,
        atMs = entry.atMs,
    )
}
