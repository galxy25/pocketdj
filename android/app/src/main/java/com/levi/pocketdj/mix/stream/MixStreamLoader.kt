package com.levi.pocketdj.mix.stream

import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.diag.DiagLog
import java.io.File
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/** The slice of the rips plane the loader needs (JVM-testable; production wiring in MixGraph). */
interface MixStreamRips {
    /** A rip server is configured (presigns need one). Synchronous: read on every canStream. */
    fun hasServer(): Boolean
    fun entry(songId: String): RipManifestEntry?
    /** A 6 h presigned URL for the song's durable object, or null when the server can't mint one. */
    suspend fun presignedUrl(songId: String, ttlSeconds: Int): String?
    /** Public (no-auth) URL of an S3 key. */
    fun urlForKey(key: String): String
    /** Public URLs of the four stems, or null when the song isn't (fully) stemmed. */
    fun stemUrls(songId: String): Map<String, String>?
}

/** Where completed streams land: the burn store. */
interface StreamAdopter {
    /** Adopt a complete song file as a `.ready` burn; the adopted file or null. */
    fun adoptFile(songId: String, title: String, artist: String, from: File): File?
    /** Move four complete stem parts into the burn folder; part -> new file, or null. */
    fun adoptStems(songId: String, files: Map<String, File>): Map<String, File>?
    /** A queued/in-flight BACKGROUND burn of the same file would download it twice - stream takes over. */
    fun yieldBackgroundDownload(songId: String) {}
}

/** [StreamAdopter] over the real [BurnStore] (whose adoption fires `onAnyBurnFinalized`). */
class BurnStoreAdopter(
    private val burns: BurnStore,
    private val yieldBackground: (String) -> Unit = {},
) : StreamAdopter {
    override fun adoptFile(songId: String, title: String, artist: String, from: File) =
        burns.adoptStreamedFile(songId, title, artist, from)

    override fun adoptStems(songId: String, files: Map<String, File>) = burns.adoptStreamedStems(songId, files)
    override fun yieldBackgroundDownload(songId: String) = yieldBackground(songId)
}

/**
 * STREAMING MODE for the Mix decks (port of iOS `MixStreamLoader`): pull a song's durable mp3 from
 * the rip bucket into a local file BYTE BY BYTE so a deck can start playing it seconds after it is
 * asked for. The engine plays the growing file directly.
 *
 * A completed stream IS a download: when its bytes are the song's burn file (digital per-song mp3,
 * or an analog album side) it is ADOPTED into the burn store as a normal `.ready` burn (which fires
 * `onAnyBurnFinalized`). An analog per-song CUT stream is played but never adopted (the burn ledger
 * keys analog songs by the album side).
 *
 * Every stream runs to completion once started - capped at [maxConcurrent] live transfers (the
 * oldest stream no deck is playing is cancelled to make room; pinned ids are never cancelled). A
 * stream that fails after [maxRetries] Range-resumes is remembered for [failureCooldown];
 * [canStream] refuses it meanwhile, and refuses everything for [serverDownCooldown] after a
 * presign/HTTP failure and while the device has no network path.
 *
 * Threading: all state lives under one lock; transfer events arrive from the sink's coroutines in
 * strict response -> bytes -> finished order per transfer and are handled under that lock. Hooks
 * run on [callbackExecutor] (FIFO) - production passes the main executor.
 */
class MixStreamLoader(
    private val rips: MixStreamRips,
    private val adopter: StreamAdopter,
    private val directory: File,
    private val network: NetworkMonitor = SettableNetworkMonitor(true),
    http: OkHttpClient? = null,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val callbackExecutor: Executor = Executor { it.run() },
) {

    /** One song's in-flight (or finished) stream. Read by the engine on every progress event. */
    class Stream internal constructor(
        val songId: String,
        /** Where the bytes are written (cacheDir/mixstream); moves into the burn folder on adoption. */
        val file: File,
        val title: String,
        val artist: String,
        internal val startedAt: Long,
    ) {
        /** Response headers have arrived: [isCut]/[startMs]/[expectedBytes] are final. */
        @Volatile var resolved = false; internal set
        /** The bytes are the analog per-song cut (plays from 0:00; no window). */
        @Volatile var isCut = false; internal set
        /** Analog album-side stream: the song's offset into the side (null for digital / cut). */
        @Volatile var startMs: Long? = null; internal set
        @Volatile var bytesReceived = 0L; internal set
        /** Content-Length of the whole object (null when the server didn't send one). */
        @Volatile var expectedBytes: Long? = null; internal set
        @Volatile var isComplete = false; internal set
        @Volatile var failed = false; internal set
        /** The complete file's location: the adopted burn file, or [file] when not adopted. */
        @Volatile var finalFile: File? = null; internal set
        val adopted: Boolean get() = finalFile.let { it != null && it != file }
        internal var adoptable = false
        internal var taskId: Int? = null
        internal var retries = 0
        internal var sideFallback: (suspend () -> String?)? = null
    }

    /**
     * A song's 4 Demucs stems streaming TOGETHER. Each part is an ordinary [Stream] keyed
     * `stem:<songId>:<part>`. Never adopted mid-flight: once all four land they MOVE into the burn
     * folder as ordinary burned stems.
     */
    class StemSet internal constructor(val songId: String, val parts: Map<String, Stream>) {
        @Volatile var adopted = false; internal set
        @Volatile internal var adopting = false
        val isComplete: Boolean get() = parts.isNotEmpty() && parts.values.all { it.isComplete }
        val failed: Boolean get() = parts.values.any { it.failed }
    }

    // ---- hooks ----------------------------------------------------------------------------------

    /** Bytes landed / headers resolved / completed / failed for a SONG id. */
    @Volatile var onProgress: ((String) -> Unit)? = null
    /** Raw byte deltas (the collection downloader's throughput window). Song streams only. */
    @Volatile var onBytes: ((String, Long) -> Unit)? = null
    /** A stream finished with no file (after retries) or was evicted. The downloader re-queues it. */
    @Volatile var onFailed: ((String) -> Unit)? = null
    /** Song ids some deck is playing right now - never cancelled to make room. */
    @Volatile var pinnedIds: (() -> Set<String>)? = null
    /** A stem set's bytes landed / completed (and was adopted) / failed - the BASE song id. */
    @Volatile var onStemProgress: ((String) -> Unit)? = null

    private val stemListeners = java.util.concurrent.ConcurrentHashMap<String, (String) -> Unit>()

    /** Further stem-set listeners (Now Playing DSP). Returns a token for [removeStemListener]. */
    fun addStemListener(listener: (String) -> Unit): String {
        val id = UUID.randomUUID().toString()
        stemListeners[id] = listener
        return id
    }

    fun removeStemListener(id: String) { stemListeners.remove(id) }

    private fun stemProgressed(base: String) {
        val primary = onStemProgress
        val others = stemListeners.values.toList()
        callbackExecutor.execute {
            primary?.invoke(base)
            others.forEach { it(base) }
        }
    }

    private fun post(block: () -> Unit) = callbackExecutor.execute(block)

    // ---- state ----------------------------------------------------------------------------------

    private val lock = ReentrantLock()
    private val streamMap = LinkedHashMap<String, Stream>()
    private val stemSetMap = HashMap<String, StemSet>()
    private val stemOwners = HashMap<String, MutableSet<String>>()
    private val recentStemFailures = HashMap<String, Long>()
    private val recentFailures = HashMap<String, Long>()
    private var serverDownUntil: Long? = null
    private val byTask = HashMap<Int, String>()
    private val sources = HashMap<String, String>()
    private val taskIds = AtomicInteger()

    val streams: Map<String, Stream> get() = lock.withLock { LinkedHashMap(streamMap) }
    val stemSets: Map<String, StemSet> get() = lock.withLock { HashMap(stemSetMap) }
    val networkAvailable: Boolean get() = network.available

    private val sink: StreamSink

    init {
        // Partials from a previous launch are never resumed (a restored deck re-streams via the
        // normal load path) - sweep them so the cache can't grow across launches.
        // Only the files present NOW are swept, and off the calling thread (it is usually main);
        // anything this launch creates afterwards is never in the snapshot.
        val stale = directory.listFiles()?.toList().orEmpty()
        directory.mkdirs()
        if (stale.isNotEmpty()) scope.launch { stale.forEach { it.deleteRecursively() } }
        val client = (http ?: OkHttpClient()).newBuilder()
            .readTimeout(REQUEST_TIMEOUT_S, TimeUnit.SECONDS)
            .connectTimeout(REQUEST_TIMEOUT_S, TimeUnit.SECONDS)
            .cache(null)
            .build()
        // Substitute for iOS URLSessionTask.lowPriority on stem parts: a separate dispatcher with
        // a small cap, so the on-air deck's song streams are not starved by four stem transfers.
        val stemClient = client.newBuilder()
            .dispatcher(okhttp3.Dispatcher().apply { maxRequests = STEM_MAX_REQUESTS; maxRequestsPerHost = STEM_MAX_REQUESTS })
            .build()
        sink = StreamSink(client, scope, clock, lowPriorityClient = stemClient) { e -> lock.withLock { handle(e) } }
    }

    // ---- queries --------------------------------------------------------------------------------

    /**
     * Can [songId] start streaming right now? It must be ripped (in the manifest), there must be a
     * rip server to presign against, a network path, and it must not have failed within the
     * cooldown / the server be in its down-cooldown. A live non-failed stream always can.
     */
    fun canStream(songId: String): Boolean = lock.withLock {
        if (streamMap[songId]?.let { !it.failed } == true) return true
        if (!network.available || !rips.hasServer() || rips.entry(songId) == null) return false
        serverDownUntil?.let { if (clock() < it) return false }
        recentFailures[songId]?.let { if (clock() - it < failureCooldownMs) return false }
        true
    }

    /** In the rip manifest (streamable in principle)? */
    fun isRipped(songId: String): Boolean = rips.entry(songId) != null

    fun stream(songId: String): Stream? = lock.withLock { streamMap[songId] }

    /** A transfer for [songId] is live (started, not complete, not failed). */
    fun isStreaming(songId: String): Boolean = lock.withLock {
        streamMap[songId]?.let { !it.isComplete && !it.failed } ?: false
    }

    // ---- open -----------------------------------------------------------------------------------

    /**
     * Begin (or join) the stream for [songId]. Null when it can't stream. A finished stream whose
     * file still exists is returned as-is (the deck plays it like a burn).
     */
    fun open(songId: String, title: String, artist: String): Stream? = lock.withLock {
        streamMap[songId]?.let { s ->
            if (!s.failed) {
                val f = s.finalFile ?: s.file
                if (!s.isComplete || f.exists()) return s
            }
        }
        if (!canStream(songId)) return null
        val entry = rips.entry(songId) ?: return null
        makeRoom()
        val file = File(directory, "${safe(songId)}-${UUID.randomUUID().toString().take(8)}.mp3")
        directory.mkdirs()
        file.createNewFile()
        val s = Stream(songId, file, title, artist, clock())
        streamMap[songId] = s
        recentFailures.remove(songId)
        adopter.yieldBackgroundDownload(songId)
        val cutKey = entry.cutKey
        if (entry.source == "analog" && cutKey != null) {
            // Prefer the per-song cut - streaming a whole album side to reach one song is the
            // expensive path. The side stays as the fallback if the cut can't be fetched.
            s.isCut = true
            s.sideFallback = { presignWithRetry(songId) }
            start(s, rips.urlForKey(cutKey), 0)
        } else {
            s.adoptable = true
            s.startMs = if (entry.source == "analog") entry.startMs else null
            scope.launch {
                val url = presignWithRetry(songId)
                lock.withLock {
                    if (streamMap[songId] !== s) return@launch
                    if (url == null) {
                        tripServerDown("presign"); fail(s, "presign failed")
                    } else start(s, url, 0)
                }
            }
        }
        telemetry("open $songId cut=${if (s.isCut) 1 else 0}")
        s
    }

    private suspend fun presignWithRetry(songId: String): String? =
        runCatching { rips.presignedUrl(songId, PRESIGN_TTL_S) }.getOrNull()
            ?: runCatching { rips.presignedUrl(songId, PRESIGN_TTL_S) }.getOrNull()

    // ---- stems ----------------------------------------------------------------------------------

    /** Can [songId]'s stems start streaming? (Public objects - no rip server needed.) */
    fun canStreamStems(songId: String): Boolean = lock.withLock {
        if (stemSetMap[songId]?.let { !it.failed } == true) return true
        if (!network.available || rips.stemUrls(songId) == null) return false
        recentStemFailures[songId]?.let { if (clock() - it < failureCooldownMs) return false }
        true
    }

    fun stemSet(songId: String): StemSet? = lock.withLock { stemSetMap[songId] }

    /**
     * Begin (or join) streaming [songId]'s 4 stems, all at once. Null when it can't. [owner]
     * registers a claim; see [cancelStems].
     */
    fun openStems(songId: String, owner: String = MIX_STEM_OWNER): StemSet? = lock.withLock {
        stemSetMap[songId]?.let { set ->
            if (!set.failed) {
                val files = set.parts.values.map { it.finalFile ?: it.file }
                if (!set.isComplete || set.adopting || files.all { it.exists() }) {
                    stemOwners.getOrPut(songId) { mutableSetOf() }.add(owner)
                    return set
                }
            }
        }
        if (!canStreamStems(songId)) return null
        val remote = rips.stemUrls(songId) ?: return null
        val parts = LinkedHashMap<String, Stream>()
        val sources = ArrayList<Pair<Stream, String>>()
        directory.mkdirs()
        for (name in BurnFileNames.STEM_NAMES) {
            val url = remote[name] ?: return null
            // `.mp3` extension: the decoder is picked from it.
            val file = File(directory, "${safe(songId)}-stem-$name-${UUID.randomUUID().toString().take(8)}.mp3")
            file.createNewFile()
            val s = Stream(stemKey(songId, name), file, name, "", clock())
            parts[name] = s
            sources += s to url
        }
        val set = StemSet(songId, parts)
        stemSetMap[songId] = set
        stemOwners[songId] = mutableSetOf(owner)
        recentStemFailures.remove(songId)
        for ((s, url) in sources) {
            streamMap[s.songId] = s
            start(s, url, 0) // public object: no presign, no bearer
        }
        telemetry("stems open $songId")
        set
    }

    /**
     * Stop streaming [songId]'s stems for [owner]. The transfer stops only when no other owner
     * still holds the set; a completed set is kept (already adopted as burned stems); an
     * incomplete one's files are swept.
     */
    fun cancelStems(songId: String, owner: String = MIX_STEM_OWNER): Unit = lock.withLock {
        stemOwners[songId]?.remove(owner)
        val others = stemOwners[songId]
        if (others != null && others.isNotEmpty() && stemSetMap[songId]?.isComplete == false) {
            telemetry("stems release $songId by $owner - still held by ${others.sorted()}")
            return
        }
        stemOwners.remove(songId)
        val set = stemSetMap[songId] ?: return
        if (set.isComplete) return
        for (p in set.parts.values) {
            cancelTransfer(p)
            streamMap.remove(p.songId)
            sources.remove(p.songId)
            p.file.delete()
        }
        stemSetMap.remove(songId)
        telemetry("stems cancel $songId")
    }

    /** All four parts landed: MOVE them into the burn folder as ordinary burned stems. */
    private fun adoptStemsIfComplete(base: String) {
        val set = stemSetMap[base] ?: return
        if (!set.isComplete || set.adopted || set.adopting) return
        set.adopting = true
        val files = set.parts.mapValues { it.value.file }
        // The move can be a cross-filesystem copy of four files: never under the loader lock.
        scope.launch {
            val moved = runCatching { adopter.adoptStems(base, files) }.getOrNull()
            lock.withLock {
                set.adopting = false
                if (moved == null || stemSetMap[base] !== set) return@withLock
                for ((name, f) in moved) set.parts[name]?.finalFile = f
                set.adopted = true
                telemetry("stems done $base")
                stemProgressed(base)
            }
        }
    }

    /** Cancel streams (collection run cancelled). Deck-pinned songs are left alone. */
    fun cancel(songIds: List<String>) = lock.withLock {
        val pinned = pinnedIds?.invoke() ?: emptySet()
        for (id in songIds) {
            if (id in pinned) continue
            val s = streamMap[id] ?: continue
            if (s.isComplete || s.failed) continue
            cancelTransfer(s)
            streamMap.remove(id)
            s.file.delete()
        }
    }

    // ---- transfer plumbing ----------------------------------------------------------------------

    private fun start(s: Stream, url: String, offset: Long) {
        sources[s.songId] = url
        val id = taskIds.incrementAndGet()
        if (offset == 0L) s.file.writeBytes(ByteArray(0))
        byTask[id] = s.songId
        s.taskId = id
        sink.start(id, url, s.file, offset, lowPriority = stemSongId(s.songId) != null)
    }

    private fun cancelTransfer(s: Stream) {
        val id = s.taskId ?: return
        byTask.remove(id)
        s.taskId = null
        sink.cancel(id)
    }

    /** Keep at most [maxConcurrent] live song transfers: cancel the OLDEST one no deck is playing. */
    private fun makeRoom() {
        // Stem parts ride their own lane - never counted against, or evicted for, the song cap.
        val live = streamMap.values.filter { !it.isComplete && !it.failed && stemSongId(it.songId) == null }
        if (live.size < maxConcurrent) return
        val pinned = pinnedIds?.invoke() ?: emptySet()
        val victim = live.filter { it.songId !in pinned }.minByOrNull { it.startedAt } ?: return
        telemetry("evict ${victim.songId} (cap $maxConcurrent)")
        cancelTransfer(victim)
        streamMap.remove(victim.songId)
        victim.file.delete()
        post { onFailed?.invoke(victim.songId) } // back to the downloader lane - it still needs the file
    }

    private fun notify(key: String) {
        val base = stemSongId(key)
        if (base != null) stemProgressed(base) else post { onProgress?.invoke(key) }
    }

    private fun handle(event: StreamSink.Event) {
        when (event) {
            is StreamSink.Event.Response -> {
                val id = byTask[event.task] ?: return
                val s = streamMap[id] ?: return
                if (event.status !in 200..299) {
                    cancelTransfer(s)
                    val fallback = s.sideFallback
                    if (s.isCut && fallback != null) {
                        // The cut isn't fetchable (private-bucket policy / missing object): stream the
                        // album side instead and window the song out of it.
                        s.sideFallback = null
                        s.isCut = false
                        s.adoptable = true
                        s.startMs = rips.entry(id)?.startMs
                        telemetry("cut HTTP ${event.status} $id -> side fallback")
                        scope.launch {
                            val url = fallback()
                            lock.withLock {
                                if (streamMap[id] !== s) return@launch
                                if (url == null) {
                                    tripServerDown("presign"); fail(s, "side presign failed")
                                } else start(s, url, 0)
                            }
                        }
                    } else {
                        if (stemSongId(id) == null) tripServerDown("HTTP ${event.status}")
                        fail(s, "HTTP ${event.status}")
                    }
                    return
                }
                serverDownUntil = null
                // Asked for a Range, got the whole object: the sink restarted the file at 0.
                if (event.status == 200 && s.bytesReceived > 0) s.bytesReceived = 0
                s.expectedBytes = event.contentRangeTotal
                    ?: if (event.expected > 0) event.expected + (if (event.status == 206) s.bytesReceived else 0) else null
                s.resolved = true
                notify(id)
            }
            is StreamSink.Event.Bytes -> {
                val id = byTask[event.task] ?: return
                val s = streamMap[id] ?: return
                s.bytesReceived = event.total
                if (stemSongId(id) == null) {
                    val delta = event.delta
                    post { onBytes?.invoke(id, delta) }
                }
                notify(id)
            }
            is StreamSink.Event.Finished -> {
                val id = byTask[event.task] ?: return
                val s = streamMap[id] ?: return
                byTask.remove(event.task)
                s.taskId = null
                s.bytesReceived = event.total
                val error = event.error
                if (error != null) {
                    val url = sources[id]
                    if (s.retries < maxRetries && url != null) {
                        s.retries += 1
                        telemetry("resume $id at ${event.total} try=${s.retries} err=${error.javaClass.simpleName}")
                        start(s, url, event.total)
                    } else {
                        if (stemSongId(id) == null) tripServerDown("network")
                        fail(s, "network ${error.javaClass.simpleName}: ${error.message}")
                    }
                    return
                }
                val expected = s.expectedBytes
                if (expected != null && event.total < expected) {
                    fail(s, "short body ${event.total}/$expected")
                    return
                }
                complete(s)
            }
        }
    }

    private fun complete(s: Stream) {
        if (!s.adoptable) { finishComplete(s, null); return }
        // Adoption moves (possibly copies, across filesystems) the whole file: do it off the lock
        // and the main thread. The stream reads as still-streaming (all bytes landed, file in
        // place) until the move is done, so no reader sees a half-moved path.
        scope.launch {
            val moved = runCatching { adopter.adoptFile(s.songId, s.title, s.artist, s.file) }.getOrNull()
            lock.withLock { if (streamMap[s.songId] === s) finishComplete(s, moved) }
        }
    }

    private fun finishComplete(s: Stream, moved: File?) {
        s.isComplete = true
        // Adopted: the file now lives in the burn folder.
        s.finalFile = moved ?: s.file
        val secs = (clock() - s.startedAt) / 1000.0
        telemetry("done ${s.songId} bytes=${s.bytesReceived} secs=${"%.1f".format(secs)} adopted=${if (s.adopted) 1 else 0}")
        stemSongId(s.songId)?.let { adoptStemsIfComplete(it) }
        notify(s.songId)
    }

    private fun fail(s: Stream, why: String) {
        cancelTransfer(s)
        s.failed = true
        DiagLog.shared?.log("error", "mixstream FAIL ${s.songId}: $why bytes=${s.bytesReceived}")
        val base = stemSongId(s.songId)
        if (base != null) {
            // One dead part sinks the set (a deck needs all four): stop its siblings, cool the
            // song down, and tell the engine - the deck keeps (or returns to) the full mix.
            recentStemFailures[base] = clock()
            stemSetMap[base]?.let { set ->
                for (p in set.parts.values) if (p !== s && !p.isComplete) {
                    cancelTransfer(p)
                    streamMap.remove(p.songId)
                }
                stemSetMap.remove(base)
            }
            stemOwners.remove(base)
            streamMap.remove(s.songId)
            stemProgressed(base)
            return
        }
        recentFailures[s.songId] = clock()
        val id = s.songId
        post { onProgress?.invoke(id) }
        post { onFailed?.invoke(id) }
        // Drop the record so a later open (after the cooldown) starts clean.
        streamMap.remove(id)
    }

    /** The rip infrastructure isn't answering: stop admitting new streams for a while. */
    private fun tripServerDown(why: String) {
        serverDownUntil = clock() + serverDownCooldownMs
        DiagLog.shared?.log("warn", "mixstream server down ($why) - streaming paused ${serverDownCooldownMs / 1000}s")
    }

    private fun telemetry(msg: String) {
        runCatching { android.util.Log.d("PocketDJ.mixstream", msg) } // logcat mirror (stubbed android.util.Log on the JVM would throw)
        DiagLog.shared?.telemetry("mixstream", msg)
    }

    // ---- tunables (instance-level so tests need no global state) --------------------------------

    @Volatile var maxConcurrent = DEFAULT_MAX_CONCURRENT
    @Volatile var maxRetries = DEFAULT_MAX_RETRIES
    @Volatile var failureCooldownMs = DEFAULT_FAILURE_COOLDOWN_MS
    @Volatile var serverDownCooldownMs = DEFAULT_SERVER_DOWN_COOLDOWN_MS

    // ---- test seams -----------------------------------------------------------------------------

    /** Script a stream without a network. [finished] completes it (and adopts, when [adoptable]). */
    internal fun injectStreamForTesting(
        songId: String, file: File, bytes: Long, expected: Long?, startMs: Long? = null,
        isCut: Boolean = false, adoptable: Boolean = false, finished: Boolean = false,
    ): Stream = lock.withLock {
        val s = streamMap[songId] ?: Stream(songId, file, songId, "", clock())
        streamMap[songId] = s
        s.resolved = true
        s.bytesReceived = bytes
        s.expectedBytes = expected
        s.startMs = startMs
        s.isCut = isCut
        s.adoptable = adoptable
        if (finished) complete(s) else notify(songId)
        s
    }

    internal fun tripServerDownForTesting() = lock.withLock { tripServerDown("test") }

    internal fun failStreamForTesting(songId: String) = lock.withLock { streamMap[songId]?.let { fail(it, "test") } }

    companion object {
        const val DEFAULT_MAX_CONCURRENT = 3
        const val DEFAULT_MAX_RETRIES = 3
        const val DEFAULT_FAILURE_COOLDOWN_MS = 120_000L
        const val DEFAULT_SERVER_DOWN_COOLDOWN_MS = 60_000L
        const val REQUEST_TIMEOUT_S = 20L
        const val STEM_MAX_REQUESTS = 2
        const val PRESIGN_TTL_S = 21_600

        const val MIX_STEM_OWNER = "mix"
        const val NOW_PLAYING_STEM_OWNER = "nowplaying"
        const val STEM_KEY_PREFIX = "stem:"

        /** The `streams` key of one stem part. */
        fun stemKey(songId: String, part: String) = "$STEM_KEY_PREFIX$songId:$part"

        /** The base song id of a stem-part key; null for a song key. Pure. */
        fun stemSongId(key: String): String? {
            if (!key.startsWith(STEM_KEY_PREFIX)) return null
            val rest = key.substring(STEM_KEY_PREFIX.length)
            val colon = rest.lastIndexOf(':')
            if (colon < 0) return null // part names never hold a colon
            return rest.substring(0, colon)
        }

        internal fun safe(id: String): String = id.map { if (it.isLetterOrDigit() || it == '_') it else '_' }.joinToString("")
    }
}
