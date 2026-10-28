package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.pockets.ListeningContextTag
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/** Location permission as the store/UI sees it - platform-API-free so it compiles and tests everywhere. */
enum class ListeningLocationAuthorization {
    NOT_DETERMINED, DENIED, RESTRICTED, WHEN_IN_USE, ALWAYS,

    /** No location source on this platform/build. */
    UNSUPPORTED;

    val isGranted: Boolean get() = this == WHEN_IN_USE || this == ALWAYS
}

/**
 * Where visits + movement come from (LOC-2 supplies the Android implementation; tests inject a
 * fake, which is also how the permission-denied path is exercised without a real prompt).
 */
interface ListeningLocationSource {
    val authorization: ListeningLocationAuthorization

    /** Begin monitoring, delivering into [store]. */
    fun start(store: ListeningLocationStore)
    fun stop()

    /** Offer the foreground -> background ("Always") upgrade. */
    fun requestAlwaysUpgrade()
}

/**
 * The on-device location context engine (port of apple ListeningLocationStore.swift): owns a
 * persisted [ListeningPlaceEngine], implements [ListeningContextProviding] for the play-history ->
 * listening-pockets pipeline, and drives an injected [ListeningLocationSource].
 *
 * OPT-IN, default OFF. The document `pocketdj-listening-places.json` is written atomically
 * (tmp + rename), excluded from backup/device-transfer (res/xml rules), and NEVER synced -
 * coordinates never leave the device. Turning it off erases everything; plays already tagged keep
 * their opaque ids, which then read as "Earlier place".
 *
 * Thread-safe: every public member takes one lock (sources deliver from arbitrary threads). The
 * JSON document is encoded under the lock but written on [io], so the lock is never held across
 * disk IO.
 */
class ListeningLocationStore(
    private val file: File,
    private val now: () -> Long = System::currentTimeMillis,
    /** Test seam: false => every lookup is unavailable and nothing is ever ingested. */
    platformSupported: Boolean = true,
    private val makeSource: () -> ListeningLocationSource? = { null },
    /** Disk writes run here, in submission order (default: one daemon thread) so no caller thread - incl. main - does IO. Tests inject a direct executor. */
    private val io: Executor = defaultIo,
) : ListeningContextProviding {

    private val lock = Any()
    private var source: ListeningLocationSource? = null

    private var enabled = false
    private var auth: ListeningLocationAuthorization =
        if (platformSupported) ListeningLocationAuthorization.NOT_DETERMINED else ListeningLocationAuthorization.UNSUPPORTED
    private var requestedAlways = false
    private var engineState = ListeningPlaceEngine()
    private val _revision = MutableStateFlow(0)

    override val isSupported: Boolean = platformSupported
    val isEnabled: Boolean get() = synchronized(lock) { enabled }
    val authorization: ListeningLocationAuthorization get() = synchronized(lock) { auth }
    val didRequestAlways: Boolean get() = synchronized(lock) { requestedAlways }
    val revision: Int get() = _revision.value
    val revisionFlow: StateFlow<Int> = _revision.asStateFlow()

    /**
     * Read-only deep SNAPSHOT for the UI/tests (copied under the lock, so callers may iterate it on
     * any thread while the source keeps ingesting). Mutating it does not affect the store.
     */
    val engine: ListeningPlaceEngine get() = synchronized(lock) { ListeningPlaceEngine.fromJson(engineState.toJson()) }

    override val isActive: Boolean get() = synchronized(lock) { activeLocked() }
    private fun activeLocked() = isSupported && enabled && auth.isGranted

    init {
        val doc = runCatching { PdjJson.lenient.parseToJsonElement(file.readText()) as? JsonObject }.getOrNull()
        if (doc != null) {
            enabled = ((doc["isEnabled"] as? JsonPrimitive)?.booleanOrNull ?: false) && platformSupported
            requestedAlways = (doc["didRequestAlways"] as? JsonPrimitive)?.booleanOrNull ?: false
            engineState = ListeningPlaceEngine.fromJson(doc["engine"] as? JsonObject)
        }
    }

    // MARK: - Lifecycle

    /** Call once at app start. Creating the source HERE (not lazily from a view) keeps a background delivery live. */
    fun startIfEnabled() = synchronized(lock) {
        if (!isSupported || !enabled) return@synchronized
        engineState.prune(now())
        save()
        startSourceLocked()
    }

    /** On: start tracking now, ask for permission, start the source. Off: stop + erase. */
    fun setEnabled(on: Boolean) = synchronized(lock) {
        if (!isSupported) return@synchronized
        if (on) {
            if (enabled) { startSourceLocked(); return@synchronized }
            enabled = true
            if (engineState.trackingStartedAtMs == null) engineState.trackingStartedAtMs = now()
            bumpLocked()
            startSourceLocked()
        } else {
            source?.stop()
            source = null
            enabled = false
            auth = ListeningLocationAuthorization.NOT_DETERMINED
            requestedAlways = false
            // Disabled == nothing on disk at all (not even an "off" doc with empty state): reset
            // in memory and delete, never save.
            engineState = ListeningPlaceEngine()
            _revision.value = _revision.value + 1
            deleteFiles()
        }
    }

    /** Wipe every place, trip and visit. While still enabled, tracking restarts from now (earlier times read unavailable). */
    fun eraseAll() = synchronized(lock) { eraseAllLocked() }

    private fun eraseAllLocked() {
        engineState = ListeningPlaceEngine()
        if (enabled) engineState.trackingStartedAtMs = now()
        if (enabled) bumpLocked() else { _revision.value = _revision.value + 1; deleteFiles() }
    }

    /** Settings' "Allow Always" button. */
    fun requestAlwaysUpgrade() = synchronized(lock) {
        val s = source
        if (!isSupported || !enabled || s == null) return@synchronized
        requestedAlways = true
        bumpLocked()
        s.requestAlwaysUpgrade()
    }

    private fun startSourceLocked() {
        if (source == null) source = makeSource()
        val s = source ?: return
        auth = s.authorization
        s.start(this)
    }

    // MARK: - Source callbacks

    fun sourceAuthorizationDidChange(status: ListeningLocationAuthorization) = synchronized(lock) {
        if (!isSupported || status == auth) return@synchronized
        val wasGranted = auth.isGranted
        auth = status
        // Tracking effectively begins at the grant: if nothing was observed yet, times between
        // "enabled" and "granted" stay unavailable instead of settling to "nowhere".
        if (enabled && status.isGranted && !wasGranted && engineState.timeline.isEmpty()) {
            engineState.trackingStartedAtMs = now()
        }
        bumpLocked()
    }

    fun ingestVisit(visit: LocationVisitSample) = synchronized(lock) {
        if (!isSupported || !enabled) return@synchronized
        engineState.ingest(visit, now())
        bumpLocked()
    }

    fun noteMovement(fix: LocationFixSample) = synchronized(lock) {
        if (!isSupported || !enabled) return@synchronized
        engineState.noteMovement(fix, now())
        bumpLocked()
    }

    // MARK: - ListeningContextProviding

    override fun context(atMs: Double): ListeningContextLookup = synchronized(lock) {
        if (!activeLocked()) return ListeningContextLookup.Unavailable
        engineState.lookup(atMs.toLong(), now())
    }

    override fun currentContextGuess(): ListeningContextTag? = synchronized(lock) {
        if (!activeLocked()) return null
        engineState.currentGuess(now())
    }

    override fun placeLabels(): List<ListeningPlaceLabel> = synchronized(lock) {
        if (!isSupported || !enabled) return emptyList()
        engineState.rankedPlaces(now())
    }

    override fun tripLabels(): List<ListeningTripLabel> = synchronized(lock) {
        if (!isSupported || !enabled) return emptyList()
        engineState.trips(now())
    }

    override fun label(tag: ListeningContextTag): String? = synchronized(lock) {
        if (!isSupported || !enabled) return null
        engineState.label(tag, now())
    }

    // MARK: - Persistence

    private fun bumpLocked() {
        _revision.value = _revision.value + 1
        save()
    }

    private fun deleteFiles() {
        io.execute {
            runCatching { file.delete() }
            runCatching { File(file.parentFile, file.name + ".tmp").delete() }
        }
    }

    private fun save() {
        val doc = JsonObject(
            linkedMapOf(
                "schemaVersion" to JsonPrimitive(SCHEMA_VERSION),
                "isEnabled" to JsonPrimitive(enabled),
                "didRequestAlways" to JsonPrimitive(requestedAlways),
                "engine" to engineState.toJson(),
            ),
        )
        val text = PdjJson.lenient.encodeToString(JsonObject.serializer(), doc)
        io.execute {
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(text)
                if (!tmp.renameTo(file)) { file.writeText(tmp.readText()); tmp.delete() }
            }
        }
    }

    companion object {
        const val SCHEMA_VERSION = 1
        const val FILE_NAME = "pocketdj-listening-places.json"
        private val defaultIo: Executor by lazy {
            Executors.newSingleThreadExecutor { r -> Thread(r, "pdj-places-io").apply { isDaemon = true } }
        }
    }
}
