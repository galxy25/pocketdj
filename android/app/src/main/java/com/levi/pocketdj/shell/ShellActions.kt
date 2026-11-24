package com.levi.pocketdj.shell

import com.levi.pocketdj.auto.AutoSessionTracker
import com.levi.pocketdj.assistant.MediaPlayActions
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketWheelController
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.QueueOutcome
import com.levi.pocketdj.screens.collections.AddToActions
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * User-facing failures of an out-of-UI action, each with a speakable sentence (iOS
 * `PocketDJIntentError`; the strings are the iOS ones verbatim).
 */
sealed class ShellActionException(message: String) : Exception(message) {
    data object SetupIncomplete : ShellActionException("Finish setting up PocketDJ in the app first.")
    data object PlaylistNotFound : ShellActionException("I couldn't find that playlist in PocketDJ.")
    data object PocketNotFound : ShellActionException("I couldn't find that pocket in PocketDJ.")
    data object SetlistNotFound : ShellActionException("I couldn't find that set list in PocketDJ.")
    data object SongNotFound : ShellActionException("I couldn't find that song in your PocketDJ sources.")
    data object MixSourceNotFound :
        ShellActionException("I couldn't find that pocket, playlist, or set list in PocketDJ.")
    class EmptyCollection(val name: String) : ShellActionException("$name has no playable songs yet.")
    class NoBurnedSongs(val name: String) : ShellActionException(
        "$name has no burned songs on this device — auto-mix plays local files only. Burn it first.",
    )
    data object NoAutoMixRunning : ShellActionException("There's no auto-mix running.")
    data object AutoMixNotPaused : ShellActionException("The auto-mix isn't paused.")
    /** Mix Together owns the decks (`MixTogetherBlock.REASON`). */
    class MixTogetherActive(why: String) : ShellActionException(why)
    data object MixUnavailable : ShellActionException("Auto-Mix isn't available yet")
    data object MixModeUnavailable : ShellActionException("Mix Mode and stems aren't available yet")

    /** The queue started nothing (every row unplayable on this device). */
    class NothingPlayable(val name: String) :
        ShellActionException("None of the songs in $name are playable on this device yet.")

    class PlaybackFailed(message: String) : ShellActionException(message)

    /** The Pocket Wheel's run could not start (iOS `noPocketFits`; text is the run store's own failure line). */
    data object NoPocketFits : ShellActionException(
        com.levi.pocketdj.data.pockets.wheel.PocketRunStore.NOT_ENOUGH_SONGS,
    )

    /** "Add this song" with nothing loaded in Now Playing or the Mix. */
    data object NothingPlaying : ShellActionException("Nothing is playing in PocketDJ right now.")

    /** Stems by voice while the Mix tab is live (iOS `mixTabLive`). */
    data object MixTabLive : ShellActionException(
        "The Mix tab is playing. Stems by voice work on Now Playing — use the Mix tab's stem pads for its decks.",
    )

    /** The pocket / playlist an add names no longer exists (or is the reserved Now Playing set). */
    data object CollectionNotFound : ShellActionException("I couldn't find that pocket or playlist in PocketDJ.")
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
    /** The audible owner's song id ([AudibleOwner]); production wires the sequencer + Mix. Null = nothing loaded. */
    private val audibleSongId: () -> String? = { null },
    /** Title for a song not in the catalog (a studio / queue-only track); null = unknown. */
    private val fallbackSongTitle: (String) -> String? = { null },
) : MediaPlayActions {
    /** Assigned by the Mix area; null ⇒ every Auto-Mix action says it isn't available. */
    @Volatile var mixFacade: MixFacade? = null

    /** The Pocket Wheel (P2-POC-16). A provider so the lazily built wheel is only touched when an action needs it. */
    @Volatile var pocketWheel: (() -> PocketWheelController?)? = null

    /** Now Playing's mini-mix (P2-SURF-10); null ⇒ Mix Mode / stem voice actions say they aren't available. */
    @Volatile var nowPlayingVoice: NowPlayingVoiceActions? = null

    private val kickedManifestRefresh = AtomicBoolean(false)

    private suspend fun veto() {
        if (setup.isIncomplete()) throw ShellActionException.SetupIncomplete
    }

    /** An Auto-DJ start is refused while mixing together: say WHY (Assistant, `pocketdj://automix`, the Auto Mix tab). */
    private fun vetoDuringMixTogether() {
        com.levi.pocketdj.remote.MixTogetherBlock.reason?.let { throw ShellActionException.MixTogetherActive(it) }
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

    /**
     * ▶/🔀 a saved (frozen) set list: its song rows (text cues dropped) become the reserved Now Playing
     * set, with each row's frozen repeat count kept. Returns the set list's display name.
     */
    suspend fun playSetlist(id: String, shuffle: Boolean = false): String {
        veto()
        ensureReady()
        val saved = collections.setlist(id) ?: throw ShellActionException.SetlistNotFound
        val name = saved.name ?: "Set list"
        val rows = saved.tracks.filter { it.isText != true && it.songId.isNotEmpty() }
        val set: Setlist?
        if (saved.id == NOW_PLAYING_SETLIST_ID) {
            // Reserved set: replay in place; rebuilding it from itself would clobber the real origin.
            set = saved.copy(tracks = if (shuffle) rows.shuffled() else rows)
        } else {
            collections.playlist(saved.playlistId)?.let { collections.markPlaylistPlayed(it.id) }
            set = collections.playNowRows(
                rows = rows,
                name = name,
                shuffle = shuffle,
                sourceToken = PlayContext.SOURCE_SETLIST,
                originId = saved.id,
            )
        }
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.EmptyCollection(name)
        start(set, name)
        return name
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
    suspend fun playSongIds(ids: List<String>, name: String, shuffle: Boolean = false, source: String, originId: String? = null): String {
        veto()
        ensureReady()
        val set = collections.playNow(songIds = ids, name = name, shuffle = shuffle, sourceToken = source, originId = originId)
        if (set == null || set.tracks.isEmpty()) throw ShellActionException.EmptyCollection(name)
        start(set, name)
        return name
    }

    /**
     * The out-of-UI door into the Pocket Wheel's best match (iOS `IntentServices.playPocketForNow`): onboarding veto +
     * readiness like every other play door, then the same run the wheel's centre play button starts. Returns the
     * spoken caption ("<collection>, <caption>"). [car] counts the car as connected (an Android Auto session).
     */
    override suspend fun playPocketForNow(): String = playPocketForNow(car = AutoSessionTracker.isActive)

    suspend fun playPocketForNow(car: Boolean): String {
        veto()
        ensureReady()
        val wheel = pocketWheel?.invoke() ?: throw ShellActionException.EmptyCollection("your pocket")
        val r = wheel.refresh(carOverride = car)
        if (!wheel.play(r.profile)) throw ShellActionException.NoPocketFits
        return pocketSpokenCaption(wheel.collectionName(r.profile.dominantCollectionId.orEmpty()), r.profile.caption)
    }

    /** One wheel moment (Android Auto "Pockets right now"): same veto + readiness as every play door. */
    suspend fun playPocketMoment(key: PocketMomentKey) {
        veto()
        ensureReady()
        val wheel = pocketWheel?.invoke() ?: throw ShellActionException.EmptyCollection("your pocket")
        if (!wheel.playMoment(key)) throw ShellActionException.NoPocketFits
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

    // ---- add to a collection ----

    /** "This song" (iOS `currentSongId`): the audible owner's track, or null when nothing is loaded. */
    fun currentSongId(): String? = audibleSongId()

    /**
     * Add [songId] (null = the song playing now) to the collection [collectionId] names
     * (`pocket:<id>` / `playlist:<id>`). Pocket -> membership; playlist -> its FIRST chapter; a member is
     * never toggled off ("X is already in Y."); never the reserved Now Playing playlist. Goes through the
     * Add-to sheet's own [AddToActions], so Recent, History > Activity and Apple Music write-back all fire.
     */
    suspend fun addSongToCollection(songId: String?, collectionId: String): AddToCollectionResult {
        veto()
        ensureReady()
        val id = songId ?: currentSongId() ?: throw ShellActionException.NothingPlaying
        val title = catalog.song(id)?.name ?: fallbackSongTitle(id) ?: throw ShellActionException.SongNotFound
        return AddToCollectionAction(collections).add(id, title, collectionId)
    }

    // ---- Now Playing Mix Mode + stems by voice (iOS setNowPlayingMixMode / setStem) ----

    /** "Turn on Mix Mode" / "Turn off Mix Mode". Returns the sentence to say. */
    suspend fun setNowPlayingMixMode(on: Boolean): String {
        veto()
        ensureReady()
        val voice = nowPlayingVoice ?: throw ShellActionException.MixModeUnavailable
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { voice.setMixMode(on) } // DSP state is main-thread
    }

    /** "Mute the vocals" / "Unmute the drums". Returns the sentence to say. */
    suspend fun setStem(stem: StemPart, muted: Boolean): String {
        veto()
        ensureReady()
        val voice = nowPlayingVoice ?: throw ShellActionException.MixModeUnavailable
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { voice.setStem(stem, muted) }
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
        vetoDuringMixTogether()
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
        vetoDuringMixTogether()
        val mix = mixOrThrow()
        ensureReady()
        checkSource(deckA)
        checkSource(deckB)
        return mix.startAutoMix(deckA, deckB, shuffle, allowPendingStart)
    }

    /**
     * ZERO-DEAD-AIR escape hatch for a Mix that can't fetch audio (the import server rejected this device's token / no server -
     * the 2026-10-30 iPad stall, where Auto Mix took the audio session and then aired silence): hand the crates' UNION to Now
     * Playing, whose backends (Apple Music first) need no rip server. Returns the queued track count (0 => nothing resolvable;
     * the mix is left alone). ONE audio owner after the hand-off: the downloader is cancelled (so its start-on-landing arm can
     * never start Auto-DJ over Now Playing once the token heals) and the Mix is silenced (auto mix stopped, hand-played decks
     * paused) via [MixFacade.releaseForNowPlaying] AFTER Now Playing has started successfully.
     */
    suspend fun playMixCratesInNowPlaying(sources: List<MixSource>, names: List<String>, shuffle: Boolean = true): Int {
        veto()
        ensureReady()
        val ids = mixCrateUnion(sources, collections)
        if (ids.isEmpty()) return 0
        val name = if (names.isEmpty()) "Mix crates" else names.joinToString(" + ")
        val set = collections.playNow(songIds = ids, name = name, shuffle = shuffle, sourceToken = PlayContext.SOURCE_MIX)
        if (set == null || set.tracks.isEmpty()) return 0
        // Start Now Playing FIRST: if it throws or is vetoed the running Mix is left alone (no dead air). Only a
        // successful start releases the Mix, so there is still exactly one audio owner afterwards.
        start(set, name)
        mixFacade?.releaseForNowPlaying()
        return set.tracks.size
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

/** The crates' playable-id UNION in first-appearance order (pure over [CollectionsStore]; a song in two crates counts once). */
internal fun mixCrateUnion(sources: List<MixSource>, collections: CollectionsStore): List<String> {
    val seen = LinkedHashSet<String>()
    for (src in sources) {
        val part = when (src) {
            is MixSource.Pocket -> collections.playableIdsForPocket(src.id)
            is MixSource.Playlist -> collections.playableIdsForPlaylist(src.id)
            is MixSource.Setlist -> collections.playableIdsForSetlist(src.id)
        }
        seen.addAll(part)
    }
    return seen.toList()
}

/** The result line for a started auto mix (iOS `StartAutoMixIntent`): "Auto-mixing X — N burned songs." */
fun autoMixLine(name: String, count: Int, shuffle: Boolean): String {
    val lead = if (shuffle) "Auto-mixing $name, shuffled" else "Auto-mixing $name"
    return "$lead — $count burned ${if (count == 1) "song" else "songs"}."
}

/** "Weekend wind-down, Potential" style caption: the dominant collection (when named) then the profile caption. */
fun pocketSpokenCaption(collectionName: String?, caption: String): String =
    listOfNotNull(collectionName?.takeIf { it.isNotBlank() }, caption.takeIf { it.isNotBlank() }).joinToString(", ")

/** The snackbar line for a started pocket run. */
fun pocketPlayingLine(caption: String): String = "Playing your pocket: $caption."

/** Run an out-of-UI action; its failure becomes a speakable toast, never a crash. */
private fun CoroutineScope.launchAction(postMessage: (String) -> Unit, fallback: String, body: suspend () -> String?): Job =
    launch {
        try {
            body()?.let(postMessage)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            postMessage((e as? ShellActionException)?.message ?: fallback)
        }
    }

/** The `pocketdj://add?...` seam: [ShellActions.addSongToCollection], result as a toast. [onLaunched] is a test hook. */
fun addLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    postMessage: (String) -> Unit,
    onLaunched: (Job) -> Unit = {},
): (String, String?) -> Unit = { collectionId, songId ->
    onLaunched(scope.launchAction(postMessage, "Couldn't add that.") { actions.addSongToCollection(songId, collectionId).dialog })
}

/** The `pocketdj://pocket/now` seam: [ShellActions.playPocketForNow], result (or the failure line) as a snackbar. */
fun pocketNowLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    postMessage: (String) -> Unit,
    onLaunched: (Job) -> Unit = {},
): () -> Unit = {
    onLaunched(scope.launchAction(postMessage, "Couldn't play your pocket.") { pocketPlayingLine(actions.playPocketForNow()) })
}

/** The `pocketdj://np/mixmode?on=` seam: the spoken sentence (or the failure line) as a snackbar. */
fun mixModeLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    postMessage: (String) -> Unit,
    onLaunched: (Job) -> Unit = {},
): (Boolean) -> Unit = { on ->
    onLaunched(scope.launchAction(postMessage, "Couldn't change Mix Mode.") { actions.setNowPlayingMixMode(on) })
}

/** The `pocketdj://np/stem/<name>?mute=` seam. Runs on the main thread (the DSP engage is main-thread state). */
fun stemLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    postMessage: (String) -> Unit,
    onLaunched: (Job) -> Unit = {},
): (StemPart, Boolean) -> Unit = { stem, muted ->
    onLaunched(scope.launchAction(postMessage, "Couldn't change that stem.") { actions.setStem(stem, muted) })
}

/** The `pocketdj://automix/...` seam (veto + ensureReady inside [ShellActions.startAutoMix]). */
fun autoMixLinkSeam(
    actions: ShellActions,
    scope: CoroutineScope,
    postMessage: (String) -> Unit,
    onLaunched: (Job) -> Unit = {},
): (MixSource, Boolean) -> Unit = { source, shuffle ->
    onLaunched(
        scope.launchAction(postMessage, "Couldn't start the auto-mix.") {
            val r = actions.startAutoMix(source, shuffle)
            autoMixLine(r.name, r.count, shuffle)
        },
    )
}
