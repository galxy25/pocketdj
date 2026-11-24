package com.levi.pocketdj.remote

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.jukebox.JukeboxMatcher
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** What a remote row became on THIS device (iOS `RemoteSongResolver.Resolution`). */
sealed interface RemoteResolution {
    val item: QueueItem?

    data class Catalog(override val item: QueueItem) : RemoteResolution
    data class AppleMusic(override val item: QueueItem) : RemoteResolution
    data class Matched(override val item: QueueItem) : RemoteResolution
    data object Unavailable : RemoteResolution {
        override val item: QueueItem? get() = null
    }
}

/**
 * Maps a remote row onto something THIS device can play: the rights boundary of a Remote session (iOS
 * `RemoteSongResolver`). Rows carry only ids + title/artist (+ the Apple Music store id); each device plays from its
 * own library or its own Apple Music. Nothing here can put a rip URL, presigned link or token on the wire.
 *
 * Ladder:
 *  1. the row's songId is in this device's catalog -> that song
 *  2. the row's Apple Music id is a catalog song here -> that song
 *  3. the row has an Apple Music id and Apple Music is usable -> `am:<id>` (the user's own AM)
 *  4. normalized title + artist EXACT key in the catalog -> that song (O(1))
 *  5. the containment-tolerant fuzzy matcher -> EXPENSIVE (a catalog scan per miss): callers allow it only for the
 *     rows about to play (see [RemoteResolutionCache])
 *  6. otherwise -> unavailable on this device
 *
 * The lambdas are the seams (tests feed maps; production wires the live catalog via [forCatalog]).
 */
class RemoteSongResolver(
    /** songId -> a playable item from this device's catalog. */
    val catalogItem: (String) -> QueueItem?,
    /** Apple Music store id -> a catalog item carrying that id. */
    val catalogItemForAppleMusicId: (String) -> QueueItem? = { null },
    /** Normalized title + artist -> a catalog item (an O(1) exact-key lookup); args are RAW, the seam normalizes. */
    val matchTitleArtist: (String, String) -> QueueItem? = { _, _ -> null },
    /** The containment-tolerant matcher (a catalog scan per call). null = none (tests). */
    val fuzzyTitleArtist: ((String, String) -> QueueItem?)? = null,
    /** Can this device stream Apple Music at all (a usable backend + a signed-in account)? */
    val appleMusicAvailable: () -> Boolean = { false },
    /** The Apple Music store id the local catalog knows for a songId (stamped onto OUTBOUND rows). */
    val appleMusicIdForSong: (String) -> String? = { null },
    /** Tried after everything else misses (the showcase's catalog-less fake speaker). null in production. */
    val lastResort: ((RemoteRow) -> QueueItem?)? = null,
    /** A session is starting: warm whatever the lookups need (build the catalog index off the main thread). */
    val prepare: () -> Unit = {},
) {
    /** Every rung, the fuzzy matcher included. */
    fun resolve(row: RemoteRow): RemoteResolution = resolve(row, allowFuzzy = true) ?: RemoteResolution.Unavailable

    /**
     * `allowFuzzy = false` stops before the expensive fuzzy matcher: a row the cheap rungs miss returns null
     * (UNDECIDED: neither playable nor reported unavailable yet).
     */
    fun resolve(row: RemoteRow, allowFuzzy: Boolean): RemoteResolution? {
        val r = row.row
        fun stamped(base: QueueItem): QueueItem {
            val own = base.id == r.songId
            return QueueItem(
                id = base.id, title = base.title, artist = base.artist,
                lengthMs = base.lengthMs ?: r.lengthMs, repeatCount = r.repeatCount,
                variant = if (own) r.variant?.takeIf { v -> SongVariant.entries.any { it.raw == v } } else null,
                editionLocked = own && (r.editionLocked ?: false),
            )
        }
        catalogItem(r.songId)?.let { return RemoteResolution.Catalog(stamped(it)) }
        // A row that is ALREADY an Apple-Music-only id (`am:<storeID>`, e.g. a jukebox request) counts too.
        val amId = r.appleMusicId ?: storeId(r.songId)
        if (!amId.isNullOrEmpty()) {
            catalogItemForAppleMusicId(amId)?.let { return RemoteResolution.Catalog(stamped(it)) }
            if (appleMusicAvailable()) {
                return RemoteResolution.AppleMusic(
                    QueueItem(id = namespacedSongId(amId), title = r.title, artist = r.artist, lengthMs = r.lengthMs),
                )
            }
        }
        matchTitleArtist(r.title, r.artist)?.let { return RemoteResolution.Matched(stamped(it)) }
        val fuzzy = fuzzyTitleArtist
        if (fuzzy != null) {
            if (!allowFuzzy) return null
            fuzzy(r.title, r.artist)?.let { return RemoteResolution.Matched(stamped(it)) }
        }
        lastResort?.invoke(row)?.let { return RemoteResolution.Matched(it) }
        return RemoteResolution.Unavailable
    }

    /**
     * An OUTBOUND row for [item]: ids + title/artist/length only, stamped with the Apple Music store id the local
     * catalog knows (or the id inside an `am:` song id). Never a URL or token: [SessionRow] has no such field.
     */
    fun outboundRow(item: QueueItem): SessionRow = SessionRow(
        songId = item.id,
        title = item.title,
        artist = item.artist ?: "",
        lengthMs = item.lengthMs,
        repeatCount = item.repeatCount,
        variant = item.variant,
        editionLocked = if (item.editionLocked) true else null,
        appleMusicId = storeId(item.id) ?: appleMusicIdForSong(item.id)?.takeIf { it.isNotBlank() },
    )

    companion object {
        const val AM_PREFIX = "am"

        fun namespacedSongId(storeId: String): String = "$AM_PREFIX:$storeId"

        /** `am:<storeID>` -> storeID (null for any other id shape, incl. `am:album:...`). */
        fun storeId(namespaced: String): String? {
            val prefix = "$AM_PREFIX:"
            if (!namespaced.startsWith(prefix)) return null
            val rest = namespaced.substring(prefix.length)
            return if (rest.isEmpty() || rest.contains(':')) null else rest
        }

        private fun item(s: IndexSong) = QueueItem(id = s.id, title = s.name, artist = s.artist, lengthMs = s.length)

        /**
         * The production resolver over the live catalog. The Apple-Music-id and title|artist indexes are built once
         * per catalog [revision] ([RemoteCatalogIndex]); the fuzzy rung is [JukeboxMatcher.match].
         */
        fun forCatalog(
            songs: () -> List<IndexSong>,
            revision: () -> Int,
            appleMusicAvailable: () -> Boolean,
        ): RemoteSongResolver {
            val index = RemoteCatalogIndex(songs, revision)
            return RemoteSongResolver(
                catalogItem = { id -> index.songById(id)?.let(::item) },
                catalogItemForAppleMusicId = { am -> index.byAppleMusicId()[am]?.let(index::songById)?.let(::item) },
                matchTitleArtist = { t, a -> index.byTitleArtist()[RemoteCatalogIndex.key(t, a)]?.let(index::songById)?.let(::item) },
                fuzzyTitleArtist = { t, a -> index.fuzzy(t, a)?.let(::item) },
                appleMusicAvailable = appleMusicAvailable,
                appleMusicIdForSong = { id -> index.songById(id)?.appleMusicId },
                prepare = { index.prepare() },
            )
        }
    }
}

/**
 * Lookup tables over the catalog, rebuilt only when the catalog [revision] moves (a 100k-song scan per miss would
 * stall a speaker). The exact key uses the jukebox matcher's normalizer. Misses of the fuzzy rung are memoized per
 * build. Not thread-safe by itself: [prepare] may be called off the main thread, reads on the resolve thread; the
 * swap is a single volatile write of an immutable [Tables].
 */
class RemoteCatalogIndex(
    private val songs: () -> List<IndexSong>,
    private val revision: () -> Int,
    /** Runs a rebuild off the caller's thread (tests pass an inline runner). */
    private val async: (Runnable) -> Unit = { r -> Thread(r, "remote-catalog-index").apply { isDaemon = true }.start() },
) {
    class Tables(
        val byId: Map<String, IndexSong>,
        val byAppleMusicId: Map<String, String>,
        val byTitleArtist: Map<String, String>,
        val songs: List<IndexSong>,
    ) {
        /** Fuzzy-rung memo, scoped to THIS build so a stale result can never leak into newer tables. */
        internal val fuzzyMemo = HashMap<String, String?>()
    }

    private class Built(val tables: Tables, val rev: Int)

    @Volatile private var built: Built? = null
    private val buildLock = Any()
    private val rebuilding = AtomicBoolean(false)
    private val buildCount = AtomicInteger(0)

    /** Number of builds so far (tests). */
    val builds: Int get() = buildCount.get()

    /** Rebuild if the catalog moved since the tables were built. */
    fun prepare() { refresh() }

    private fun buildNow(rev: Int): Built {
        val b = Built(build(songs()), rev)
        buildCount.incrementAndGet()
        built = b
        return b
    }

    /**
     * Current tables. First ever call builds synchronously (single-flight); afterwards a moved revision keeps
     * answering from the old tables while one background build (single-flight) swaps in the new ones.
     */
    private fun refresh(): Tables {
        val rev = revision()
        val cur = built
        if (cur != null) {
            if (cur.rev != rev && rebuilding.compareAndSet(false, true)) {
                async(Runnable {
                    try {
                        synchronized(buildLock) { if (built?.rev != rev) buildNow(rev) }
                    } finally {
                        rebuilding.set(false)
                    }
                })
            }
            return cur.tables
        }
        synchronized(buildLock) {
            built?.let { return it.tables }
            return buildNow(rev).tables
        }
    }

    fun songById(id: String): IndexSong? = refresh().byId[id]
    fun byAppleMusicId(): Map<String, String> = refresh().byAppleMusicId
    fun byTitleArtist(): Map<String, String> = refresh().byTitleArtist

    fun fuzzy(title: String, artist: String): IndexSong? {
        val t = refresh()
        val k = key(title, artist)
        synchronized(t.fuzzyMemo) {
            if (t.fuzzyMemo.containsKey(k)) return t.fuzzyMemo[k]?.let { t.byId[it] }
        }
        val hit = JukeboxMatcher.match(title, artist, t.songs)
        synchronized(t.fuzzyMemo) { t.fuzzyMemo[k] = hit?.id }
        return hit
    }

    companion object {
        fun key(title: String, artist: String): String =
            JukeboxMatcher.normalize(title) + "\u001F" + JukeboxMatcher.normalize(artist)

        /** The pure table build; the first song wins a duplicate key. */
        fun build(songs: List<IndexSong>): Tables {
            val byId = HashMap<String, IndexSong>(songs.size * 2)
            val am = HashMap<String, String>()
            val ta = HashMap<String, String>()
            for (s in songs) {
                byId.putIfAbsent(s.id, s)
                s.appleMusicId?.takeIf { it.isNotEmpty() }?.let { am.putIfAbsent(it, s.id) }
                ta.putIfAbsent(key(s.name, s.artist), s.id)
            }
            return Tables(byId, am, ta, songs)
        }
    }
}

/**
 * Per-session resolution state for the rows of a shared queue: cheap rungs for every row, the expensive fuzzy rung
 * only for the current row and the next [FUZZY_AHEAD] ([RemoteSongResolver] ladder). A row the cheap rungs miss
 * outside that window stays UNDECIDED (null, retried as it nears the current row); a decided one is cached by rid.
 * A cached resolution ALWAYS hands out a FRESH queue-item uid ([queueItem]): the uid is per queue INSTANCE.
 */
class RemoteResolutionCache(private val resolver: RemoteSongResolver) {
    private val decided = HashMap<String, RemoteResolution>()

    /** rids of rows resolved as unavailable on this device. */
    val unavailableRids: Set<String> get() = decided.filterValues { it is RemoteResolution.Unavailable }.keys

    /** Forget everything (a new session / a catalog change / a host change). */
    fun clear() = decided.clear()

    /** Keep only the rows still in the live window (the cache stays bounded as the set advances). */
    fun retainOnly(live: Set<String>) { decided.keys.retainAll(live) }

    /**
     * Resolve [rows] given the position of the current row inside them. Rows before [currentIndex] (already played)
     * get the cheap rungs only. Returns one entry per row, null = undecided.
     */
    fun resolve(rows: List<RemoteRow>, currentIndex: Int): List<RemoteResolution?> =
        rows.mapIndexed { i, row ->
            decided[row.rid]?.let { return@mapIndexed it }
            val fuzzy = i >= currentIndex && i <= currentIndex + FUZZY_AHEAD
            resolver.resolve(row, allowFuzzy = fuzzy)?.also { decided[row.rid] = it }
        }

    /** A fresh queue instance of [resolution]'s item (null when unavailable). Never reuses a uid. */
    fun queueItem(resolution: RemoteResolution): QueueItem? = resolution.item?.freshInstance()

    companion object {
        /** The fuzzy rung runs for the current row and this many after it. */
        const val FUZZY_AHEAD = 3
    }
}
