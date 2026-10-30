package com.levi.pocketdj.shell

import com.levi.pocketdj.assistant.MediaPlayActions
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.QueueOutcome
import java.util.concurrent.atomic.AtomicBoolean

/**
 * User-facing failures of an out-of-UI action, each with a speakable sentence (iOS
 * `PocketDJIntentError`; the strings are the iOS ones verbatim).
 */
sealed class ShellActionException(message: String) : Exception(message) {
    data object SetupIncomplete : ShellActionException("Finish setting up PocketDJ in the app first.")
    data object PlaylistNotFound : ShellActionException("I couldn't find that playlist in PocketDJ.")
    data object PocketNotFound : ShellActionException("I couldn't find that pocket in PocketDJ.")
    data object SongNotFound : ShellActionException("I couldn't find that song in your PocketDJ sources.")
    data object MixSourceNotFound :
        ShellActionException("I couldn't find that pocket, playlist, or set list in PocketDJ.")
    class EmptyCollection(val name: String) : ShellActionException("$name has no playable songs yet.")
    class NoBurnedSongs(val name: String) : ShellActionException(
        "$name has no burned songs on this device — auto-mix plays local files only. Burn it first.",
    )
    data object NoAutoMixRunning : ShellActionException("There's no auto-mix running.")
    data object AutoMixNotPaused : ShellActionException("The auto-mix isn't paused.")
    data object MixUnavailable : ShellActionException("Auto-Mix isn't available yet")

    /** The queue started nothing (every row unplayable on this device). */
    class NothingPlayable(val name: String) :
        ShellActionException("None of the songs in $name are playable on this device yet.")

    class PlaybackFailed(message: String) : ShellActionException(message)
}

/** Catalog lookups ShellActions needs (production: the merged catalog snapshot). */
interface ShellCatalog {
    fun song(id: String): IndexSong?
    fun album(id: String): IndexAlbum?
}

/** Starts the freshly-upserted Now Playing setlist (production: `PlaybackController.playSetlist`). */
fun interface ShellPlayer {
    suspend fun play(set: Setlist, context: PlayContext): QueueOutcome
}

/** The onboarding veto, as a question (production: `OnboardingStore.awaitLoaded()` then `!isComplete`). */
fun interface SetupGate {
    suspend fun isIncomplete(): Boolean
}

/** Make the catalog usable before an action acts (iOS `ensureReady`). */
interface ReadinessPort {
    /** Fire-and-forget rips-manifest refresh (called at most once per process by ShellActions). */
    fun kickManifestRefresh()

    /** Start the offline-first catalog load (idempotent, single-flight). */
    fun loadCatalog()

    /** Suspend until the catalog has seeded from the DISK CACHE; never waits for the network refresh. */
    suspend fun awaitCatalogSeeded()
}

/**
 * The one app-scoped façade for every out-of-UI surface (iOS `IntentServices`): Assistant,
 * launcher shortcuts, deep links, widgets, Android Auto. All operations live here (thin,
 * testable); intent handlers are adapters.
 *
 * Invariants (iOS R4 and friends):
 *  - Every MUTATING action first checks the onboarding veto and throws
 *    [ShellActionException.SetupIncomplete]: a cold Assistant launch must not write synced
 *    collection/session documents on a not-yet-set-up device.
 *  - [ensureReady] returns as soon as the catalog's disk cache is seeded; it never awaits the
 *    network refresh. The manifest refresh is kicked once per process.
 *  - Playback goes through the SAME reserved Now Playing setlist the detail screens use
 *    (`CollectionsStore.playNow*`), so history tags (playlist/pocket/album) and the origin
 *    collection match the in-app path.
 */
class ShellActions(
    private val collections: CollectionsStore,
    private val catalog: ShellCatalog,
    private val player: ShellPlayer,
    private val setup: SetupGate,
    private val readiness: ReadinessPort,
    private val postRoute: (ShellRoute) -> Unit = NavRequestBus::post,
) : MediaPlayActions {
    /** Assigned by the Mix area; null ⇒ every Auto-Mix action says it isn't available. */
    @Volatile var mixFacade: MixFacade? = null

    /**
     * Assigned by the shell graph: insert rows into the RUNNING Now Playing queue (`next` = Play Next, else Play Last).
     * Returns false when no session is running. Additive seam for Discover's ripped-row long-press menu.
     */
    @Volatile var queueSink: ((List<com.levi.pocketdj.playback.sequencer.QueueItem>, Boolean) -> Boolean)? = null

    /** Play Next / Play Last for one song; false when nothing is running (the menu hides in that case). */
    fun enqueueSong(item: com.levi.pocketdj.playback.sequencer.QueueItem, next: Boolean): Boolean =
        queueSink?.invoke(listOf(item), next) ?: false

    private val kickedManifestRefresh = AtomicBoolean(false)

    private suspend fun veto() {
        if (setup.isIncomplete()) throw ShellActionException.SetupIncomplete
    }

    suspend fun ensureReady() {
        if (kickedManifestRefresh.compareAndSet(false, true)) readiness.kickManifestRefresh()
        readiness.loadCatalog()
        readiness.awaitCatalogSeeded()
    }

    // ---- play ----

    /** ▶/🔀 a playlist. Returns its display name (spoken by the Assistant). */
    override suspend fun playPlaylist(id: String, shuffle: Boolean): String {
        veto()
        ensureReady()
        val playlist = collections.playlist(id) ?: throw ShellActionException.PlaylistNotFound
        val set = collections.playNowPlaylist(id, shuffle)
        if (set == null || set.tracks.isEmpty()) {
            throw ShellActionException.EmptyCollection(collections.playlist(id)?.name ?: "that playlist")
        }
        start(set, playlist.name)
        return playlist.name
    }

    /** ▶/🔀 a pocket (DAG-resolved order). */
    override suspend fun playPocket(id: String, shuffle: Boolean): String {
        veto()
        ensureReady()
        val pocket = collections.pocket(id) ?: throw ShellActionException.PocketNotFound
        val set = collections.playNowPocket(id, shuffle)
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.EmptyCollection(pocket.name)
        start(set, pocket.name)
        return pocket.name
    }

    /** ▶ one catalog song as a one-track Now Playing set. Returns the title. */
    override suspend fun playSong(id: String): String {
        veto()
        ensureReady()
        val song = catalog.song(id) ?: throw ShellActionException.SongNotFound
        val set = collections.playNow(
            songIds = listOf(id),
            name = song.name,
            sourceToken = PlayContext.SOURCE_BROWSER,
        )
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.SongNotFound
        start(set, song.name)
        return song.name
    }

    /** ▶/🔀 an album (tracks in order, or shuffled). iOS reports an unknown album as song-not-found. */
    override suspend fun playAlbum(id: String, shuffle: Boolean): String {
        veto()
        ensureReady()
        val album = catalog.album(id) ?: throw ShellActionException.SongNotFound
        val set = collections.playNow(
            songIds = album.trackList,
            name = album.name,
            shuffle = shuffle,
            sourceToken = PlayContext.SOURCE_ALBUM,
            originId = album.id,
        )
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.EmptyCollection(album.name)
        start(set, album.name)
        return album.name
    }

    /**
     * ▶/🔀 an arbitrary id list (a source playlist, For You…). A fresh snapshot is built per call,
     * so replaying picks up the source's current songs. [source] is a `PlayContext.SOURCE_*` token.
     */
    suspend fun playSongIds(ids: List<String>, name: String, shuffle: Boolean = false, source: String): String {
        veto()
        ensureReady()
        val set = collections.playNow(songIds = ids, name = name, shuffle = shuffle, sourceToken = source)
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.EmptyCollection(name)
        start(set, name)
        return name
    }

    private suspend fun start(set: Setlist, name: String) {
        // The context the in-app Now Playing run carries: source token + reserved set id + set name.
        val context = collections.historyContext(NOW_PLAYING_SETLIST_ID)
        when (val outcome = player.play(set, context)) {
            is QueueOutcome.Started -> Unit
            is QueueOutcome.NothingPlayable -> throw ShellActionException.NothingPlayable(name)
            is QueueOutcome.Failed -> throw ShellActionException.PlaybackFailed(outcome.message)
        }
    }

    // ---- navigation ----

    /** Raise a navigation request (consumed by the shell). Not vetoed: onboarding gates the shell itself. */
    fun open(route: ShellRoute) = postRoute(route)

    /** "Search PocketDJ for …": land on Browse with [query] parked in its search field. */
    fun search(query: String) = postRoute(ShellRoute.BrowseSearch(query.trim()))

    // ---- Mix seams ----

    private fun mixOrThrow(): MixFacade = mixFacade ?: throw ShellActionException.MixUnavailable

    private fun checkSource(source: MixSource) {
        val ok = when (source) {
            is MixSource.Pocket -> collections.pocket(source.id) != null
            is MixSource.Playlist -> collections.playlist(source.id) != null
            is MixSource.Setlist -> collections.setlist(source.id) != null
        }
        if (!ok) throw ShellActionException.MixSourceNotFound
    }

    suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean = false): MixStartResult {
        veto()
        val mix = mixOrThrow()
        ensureReady()
        checkSource(source)
        return mix.startAutoMix(source, shuffle, allowPendingStart)
    }

    suspend fun startAutoMix(
        deckA: MixSource,
        deckB: MixSource,
        shuffle: Boolean,
        allowPendingStart: Boolean = false,
    ): MixStartResult {
        veto()
        val mix = mixOrThrow()
        ensureReady()
        checkSource(deckA)
        checkSource(deckB)
        return mix.startAutoMix(deckA, deckB, shuffle, allowPendingStart)
    }

    suspend fun pauseAutoMix() {
        veto()
        val mix = mixOrThrow()
        if (!mix.autoMixing) throw ShellActionException.NoAutoMixRunning
        mix.pauseAutoMix()
    }

    suspend fun resumeAutoMix() {
        veto()
        val mix = mixOrThrow()
        if (!mix.autoMixing) throw ShellActionException.NoAutoMixRunning
        if (!mix.autoPaused) throw ShellActionException.AutoMixNotPaused
        mix.resumeAutoMix()
    }
}
