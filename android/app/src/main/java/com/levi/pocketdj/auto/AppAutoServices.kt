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
    @Volatile private var amSignedIn = false

    init {
        app.appScope.launch { app.settings.settings.collect { amSignedIn = it.musicUserToken.isNotBlank() } }
    }

    private val catalog: MergedCatalog? get() = app.catalogRepository.state.value.catalog
    private val store: CollectionsStore get() = app.collections

    override val catalogReady: Boolean get() = catalog != null

    override fun playlists(): List<AutoCollectionInfo> =
        store.playlists.filter { it.id != NOW_PLAYING_PLAYLIST_ID }.map {
            AutoCollectionInfo(AutoCollectionRef(AutoCollectionKind.PLAYLIST, it.id), it.name, store.playableIdsForPlaylist(it.id).size)
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
            AutoCollectionInfo(AutoCollectionRef(AutoCollectionKind.POCKET, it.id), it.name, store.playableIdsForPocket(it.id).size)
        }

    override fun collection(ref: AutoCollectionRef): AutoCollectionInfo? = when (ref.kind) {
        AutoCollectionKind.PLAYLIST -> store.playlist(ref.id)?.takeIf { it.id != NOW_PLAYING_PLAYLIST_ID }
            ?.let { AutoCollectionInfo(ref, it.name, store.playableIdsForPlaylist(it.id).size) }
        AutoCollectionKind.POCKET -> store.pocket(ref.id)
            ?.let { AutoCollectionInfo(ref, it.name, store.playableIdsForPocket(it.id).size) }
        AutoCollectionKind.SOURCE -> sourcePlaylists().firstOrNull { it.ref == ref }
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
        val snap = runCatching { app.playbackGraph.sessionStore.load() }.getOrNull() ?: return null
        val row = snap.queue.getOrNull(snap.index.coerceIn(0, (snap.queue.size - 1).coerceAtLeast(0))) ?: return null
        return AutoHeld(row.title, row.artist)
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
