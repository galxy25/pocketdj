package com.levi.pocketdj.auto

import com.levi.pocketdj.assistant.MediaSearchResolver
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.QueueOutcome
import com.levi.pocketdj.screens.collections.AddToActions
import com.levi.pocketdj.screens.collections.AddToItem
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Production wiring of the Auto ports onto the app graph (device-verified through the DHU, not JVM-tested). */
class AppAutoData(private val app: AppGraph) : AutoLibraryData {
    /** Set by the service: the open lists must be re-read (sign-in flipped, held row changed, collections changed). */
    @Volatile var onLibraryChanged: () -> Unit = {}

    // Final review: never block the (main-thread) browse root on a settings read. Starts false; the collector below
    // delivers the stored value immediately and fires onLibraryChanged when it differs.
    @Volatile private var amSignedIn = false

    // Continue row: decoded off the main thread, throttled, then served from memory.
    @Volatile private var cachedHeld: AutoHeld? = null
    @Volatile private var heldRefreshedAt = 0L
    private val heldRefreshing = java.util.concurrent.atomic.AtomicBoolean(false)

    init {
        app.appScope.launch {
            app.settings.settings.collect {
                val now = it.musicUserToken.isNotBlank()
                if (now != amSignedIn) { amSignedIn = now; onLibraryChanged() }
            }
        }
        refreshHeld()
    }

    private fun refreshHeld() {
        heldRefreshedAt = System.currentTimeMillis()
        if (!heldRefreshing.compareAndSet(false, true)) return
        app.appScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val snap = runCatching { app.playbackGraph.sessionStore.load() }.getOrNull()
                val row = snap?.queue?.getOrNull(snap.index.coerceIn(0, (snap.queue.size - 1).coerceAtLeast(0)))
                val next = row?.let { AutoHeld(it.title, it.artist) }
                if (next != cachedHeld) { cachedHeld = next; onLibraryChanged() }
            } finally { heldRefreshing.set(false) }
        }
    }

    /** Playable rows only: ids that resolve in the catalog, same as the drill-in list (iOS resolvedCount). */
    private fun resolvedCount(ids: List<String>): Int {
        val c = catalog ?: return 0
        return ids.count { it in c.songsById }
    }

    private val catalog: MergedCatalog? get() = app.catalogRepository.state.value.catalog
    private val store: CollectionsStore get() = app.collections

    override val catalogReady: Boolean get() = catalog != null

    override fun playlists(): List<AutoCollectionInfo> =
        store.playlists.filter { it.id != NOW_PLAYING_PLAYLIST_ID }.map {
            AutoCollectionInfo(AutoCollectionRef(AutoCollectionKind.PLAYLIST, it.id), it.name, resolvedCount(store.playableIdsForPlaylist(it.id)))
        }

    override fun sourcePlaylists(): List<AutoCollectionInfo> {
        val c = catalog ?: return emptyList()
        return c.playlists.map { sp ->
            AutoCollectionInfo(
                AutoCollectionRef(AutoCollectionKind.SOURCE, sp.playlist.id, sp.sourceName),
                sp.playlist.name,
                sp.playlist.songIds.count { it in c.songsById },
                badge = sp.sourceName,
            )
        }
    }

    override fun pockets(): List<AutoCollectionInfo> =
        store.pockets.map {
            AutoCollectionInfo(AutoCollectionRef(AutoCollectionKind.POCKET, it.id), it.name, resolvedCount(store.playableIdsForPocket(it.id)))
        }

    override fun collection(ref: AutoCollectionRef): AutoCollectionInfo? = when (ref.kind) {
        AutoCollectionKind.PLAYLIST -> store.playlist(ref.id)?.takeIf { it.id != NOW_PLAYING_PLAYLIST_ID }
            ?.let { AutoCollectionInfo(ref, it.name, resolvedCount(store.playableIdsForPlaylist(it.id))) }
        AutoCollectionKind.POCKET -> store.pocket(ref.id)
            ?.let { AutoCollectionInfo(ref, it.name, resolvedCount(store.playableIdsForPocket(it.id))) }
        AutoCollectionKind.SOURCE -> catalog?.let { c ->
            c.playlists.firstOrNull { it.sourceName == ref.sourceName && it.playlist.id == ref.id }?.let { sp ->
                AutoCollectionInfo(ref, sp.playlist.name, sp.playlist.songIds.count { it in c.songsById }, badge = sp.sourceName)
            }
        }
    }

    override fun songIds(ref: AutoCollectionRef): List<String> = when (ref.kind) {
        AutoCollectionKind.PLAYLIST -> store.playableIdsForPlaylist(ref.id)
        AutoCollectionKind.POCKET -> store.playableIdsForPocket(ref.id)
        AutoCollectionKind.SOURCE -> catalog?.playlists
            ?.firstOrNull { it.sourceName == ref.sourceName && it.playlist.id == ref.id }?.playlist?.songIds.orEmpty()
    }

    override fun song(id: String): AutoSongInfo? {
        val c = catalog ?: return null
        val s = c.songsById[id] ?: return null
        val art = s.albumId?.let { c.albumsById[it] }?.let { AutoArtwork.pick(it.artCandidates()) }
        val playable = app.ripsRepository.isPlayable(id) || (s.appleMusicId != null && amSignedIn)
        return AutoSongInfo(id, s.name, s.artist, art, playable)
    }

    override fun searchSongs(query: String, limit: Int): List<AutoSongInfo> {
        val c = catalog ?: return emptyList()
        return c.songs.asSequence()
            .map { it to MediaSearchResolver.tier(query, it.name) }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
            .take(limit)
            .mapNotNull { song(it.first.id) }
            .toList()
    }

    override fun held(): AutoHeld? {
        if (System.currentTimeMillis() - heldRefreshedAt > 5_000) refreshHeld()
        val seq = app.playbackController.sequencer
        // iOS resumableSession(): a live or paused (not held) set hides Continue; idle + snapshot shows it.
        if (seq.isRunning && !seq.isHeldForResume) return null
        return cachedHeld
    }
}

class AppAutoPlayer(private val app: AppGraph) : AutoPlayer {
    private suspend fun ready() {
        val onboarding = app.shellGraph.onboarding
        onboarding.awaitLoaded()
        if (!onboarding.isComplete) throw AutoPlayException("Finish setting up PocketDJ in the app first.")
        app.shellGraph.shellActions.ensureReady()
    }

    private fun setFor(ref: AutoCollectionRef, shuffle: Boolean): Pair<Setlist?, String> = when (ref.kind) {
        AutoCollectionKind.PLAYLIST ->
            app.collections.playNowPlaylist(ref.id, shuffle) to (app.collections.playlist(ref.id)?.name ?: "that playlist")
        AutoCollectionKind.POCKET ->
            app.collections.playNowPocket(ref.id, shuffle) to (app.collections.pocket(ref.id)?.name ?: "that pocket")
        AutoCollectionKind.SOURCE -> {
            val sp = app.catalogRepository.state.value.catalog?.playlists
                ?.firstOrNull { it.sourceName == ref.sourceName && it.playlist.id == ref.id }
            app.collections.playNow(
                songIds = sp?.playlist?.songIds.orEmpty(),
                name = sp?.playlist?.name ?: "Now Playing",
                shuffle = shuffle,
                sourceToken = PlayContext.SOURCE_PLAYLIST,
            ) to (sp?.playlist?.name ?: "that playlist")
        }
    }

    private suspend fun start(set: Setlist?, name: String, startIndex: Int) {
        if (set == null || set.tracks.isEmpty()) throw AutoPlayException("$name has no playable songs yet.")
        val ctx = app.collections.historyContext(NOW_PLAYING_SETLIST_ID)
        when (val o = app.playbackController.playSetlist(set, ctx, startIndex)) {
            is QueueOutcome.Started -> Unit
            is QueueOutcome.NothingPlayable -> throw AutoPlayException("None of the songs in $name are playable on this device yet.")
            is QueueOutcome.Failed -> throw AutoPlayException(o.message)
        }
    }

    override suspend fun playCollection(ref: AutoCollectionRef, shuffle: Boolean) {
        ready()
        val (set, name) = setFor(ref, shuffle)
        start(set, name, 0)
    }

    override suspend fun playSong(ref: AutoCollectionRef, songId: String) {
        ready()
        val (set, name) = setFor(ref, shuffle = false)
        val idx = set?.tracks?.indexOfFirst { it.songId == songId } ?: -1
        start(set, name, idx.coerceAtLeast(0))
    }

    override suspend fun playSolo(songId: String) {
        ready()
        val song = app.catalogRepository.state.value.catalog?.songsById?.get(songId)
            ?: throw AutoPlayException("I couldn't find that song in your PocketDJ sources.")
        val set = app.collections.playNow(listOf(songId), song.name, sourceToken = PlayContext.SOURCE_BROWSER)
        start(set, song.name, 0)
    }

    override suspend fun resumeHeld() {
        ready()
        app.playbackGraph.resumptionProvider.onPlaybackResumption()
        app.playbackController.resume()
    }
}

class AppAutoAddSink(private val store: CollectionsStore) : AutoAddSink {
    override fun pockets() = store.pockets.map { AutoTarget(AutoTargetKind.POCKET, it.id, it.name) }
    override fun playlists() = store.playlists.map { AutoTarget(AutoTargetKind.PLAYLIST, it.id, it.name) }
    override fun add(songId: String, kind: AutoTargetKind, targetId: String): Boolean {
        val exists = if (kind == AutoTargetKind.POCKET) store.pocket(targetId) != null else store.playlist(targetId) != null
        if (!exists) return false
        val target = AddTarget(if (kind == AutoTargetKind.POCKET) AddTarget.Kind.POCKET else AddTarget.Kind.PLAYLIST, targetId)
        AddToActions(AddToItem.Song(songId), store).add(target)
        return true
    }
}

/**
 * SURF-9 production [AutoMixExtras] over the Mix engine, collections and the jukebox broker (device-verified
 * through the DHU, not JVM-tested). Nothing here builds the Mix engine unless the [facade] says a mix is
 * already running: a car connect must never materialize a parked mix.
 */
class AppAutoMixExtras(
    private val app: AppGraph,
    private val facade: com.levi.pocketdj.shell.MixFacade,
) : AutoMixExtras {
    private val main = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)

    override fun crates(): List<AutoCrate> {
        val s = app.collections
        return com.levi.pocketdj.screens.mix.MixCrateMenuState.entries(
            s.pockets, s.playlists.filter { it.id != NOW_PLAYING_PLAYLIST_ID }, s.setlists,
        ).map { e ->
            val g = when (e.section) {
                com.levi.pocketdj.screens.mix.MixCrateMenuState.POCKETS -> AutoCrateGroup.POCKETS
                com.levi.pocketdj.screens.mix.MixCrateMenuState.PLAYLISTS -> AutoCrateGroup.PLAYLISTS
                else -> AutoCrateGroup.SETLISTS
            }
            val src = when (val m = e.source) {
                is com.levi.pocketdj.mix.model.MixSource.Pocket -> com.levi.pocketdj.shell.MixSource.Pocket(m.value)
                is com.levi.pocketdj.mix.model.MixSource.Playlist -> com.levi.pocketdj.shell.MixSource.Playlist(m.value)
                is com.levi.pocketdj.mix.model.MixSource.Setlist -> com.levi.pocketdj.shell.MixSource.Setlist(m.value)
            }
            AutoCrate(src, e.name, g)
        }
    }

    override fun downloadState(): Pair<Int, Int>? =
        app.mixGraph.downloadStateIfBuilt()?.takeIf { it.isActive }?.let { it.downloadedCount to it.totalCount }

    override fun live(): AutoMixLive? {
        if (!facade.autoMixing) return null
        val dj = app.mixGraph.autoDj
        val ui = dj.ui.value
        val t = app.mixGraph.mixEngine.loaded(ui.liveDeck)
        return AutoMixLive(
            title = t?.title, artist = t?.artist,
            position = if (ui.queueSize > 0) (ui.livePos + 1).coerceAtMost(ui.queueSize) else null,
            count = ui.queueSize.takeIf { it > 0 },
            deck = if (ui.queueSize > 0) "Deck ${ui.liveDeck.name}" else null,
            buffering = app.mixGraph.mixEngine.streamHeld(ui.liveDeck),
        )
    }

    override fun materializePendingRestoreIfNeeded(trigger: String) {
        // Only when a restore is parked: a car connect with nothing parked must not build the engine.
        if (!app.mixGraph.hasLaunchRestore()) return
        main.launch { app.mixGraph.mixEngine.materializePendingRestoreIfNeeded(trigger) }
    }

    override val slowSkipSeconds: Double get() = if (facade.autoMixing) app.mixGraph.autoDj.skipFadeSeconds else 15.0
    override fun skipFast() { main.launch { app.mixGraph.autoDj.remoteSkip(AutoMixTab.FAST_SKIP_SECONDS) } }
    override fun skipSlow() { main.launch { val dj = app.mixGraph.autoDj; dj.remoteSkip(dj.skipFadeSeconds) } }
    override fun stop() { main.launch { if (facade.autoMixing) app.mixGraph.autoDj.stopAutoMix() } }

    /** Light 1.5 s poll while the auto scope lives (signature-filtered, never builds the engine). */
    override val changes: kotlinx.coroutines.flow.Flow<String> = kotlinx.coroutines.flow.flow {
        while (true) {
            val sig = if (facade.autoMixing) {
                val l = live()
                "1|${facade.autoPaused}|${l?.title}|${l?.position}|${l?.count}|${l?.deck}|${l?.buffering}"
            } else "0"
            emit(sig + "|dl=" + downloadState())
            // Idle (no mix, no pull): back off; the loop only has something to say when state is live.
            kotlinx.coroutines.delay(if (sig == "0" && downloadState() == null) 5000 else 1500)
        }
    }

    override suspend fun jukeboxSessions(): List<AutoJukeSession>? = try {
        com.levi.pocketdj.data.jukebox.JukeboxGraph.get(app.appContext).repository.listSessions().map {
            AutoJukeSession(it.jukeboxId, it.name, it.timeless == true, it.url)
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }
}
