package com.levi.pocketdj.di

import com.levi.pocketdj.data.applemusic.DefaultAppleMusicTokens
import com.levi.pocketdj.data.applemusic.PlaylistWriteBack
import com.levi.pocketdj.data.applemusic.WebApiPlaylistWriteBackTransport
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.favorites.FavoritesAccess
import com.levi.pocketdj.data.favorites.FavoritesStore
import com.levi.pocketdj.data.favorites.favoriteActivityRecorder
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import com.levi.pocketdj.data.collections.SourceSyncSettings

/**
 * Sidecar graph for the collections area (decision D3). Contributes the ON_STOP flush
 * barrier: both documents are written inline when dirty (superseding queued off-main writes; FlushOnStop in MainActivity drives it via ProcessLifecycleOwner) so a
 * process kill right after backgrounding cannot lose a batch add (D6).
 */
class CollectionsGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "collections"

    /**
     * Per-profile favorites (COL-10). Lazy — reads its doc on first touch. User toggles (and
     * only those) append one heart/unheart row to the activity log with live-catalog
     * title/artist snapshots.
     */
    val favorites: FavoritesStore by lazy {
        File(app.appContext.filesDir, FavoritesStore.FILE_NAME).let { f ->
            FavoritesStore(f, writer = VersionedJsonWriter(f, VersionedJsonWriter.backgroundExecutor("pdj-favorites-writer")))
        }.also { store ->
            store.onChanged = favoriteActivityRecorder(app.collectionActivity) { id ->
                app.catalogRepository.state.value.catalog?.songsById?.get(id)?.let { it.name to it.artist }
            }
        }
    }

    /**
     * The playback `FavoriteSeam` shape (isFavorite/toggle by songId): resolves the song's
     * Apple Music catalog id from the live catalog so the lock-screen ♥ queues a mirrorable entry.
     */
    val favoriteAccess: FavoritesAccess by lazy {
        object : FavoritesAccess {
            override fun isFavorite(songId: String) = favorites.isFavorite(songId)
            override fun toggle(songId: String, appleMusicId: String?): Boolean = favorites.toggle(
                songId,
                appleMusicId ?: app.catalogRepository.state.value.catalog?.songsById?.get(songId)?.appleMusicId,
            )
        }
    }

    /**
     * Nullable rec seam for the Add-to sheet's Suggested row / the context submenu: songId ->
     * collection suggestions. Unwired (null) ⇒ no Suggested section (a later rec package sets it).
     */
    @Volatile
    var collectionSuggestions: ((String) -> List<com.levi.pocketdj.screens.collections.CollectionSuggestion>)? = null

    /** Memoized virtual "Recently added" derivation (COL-12). */
    val recentlyAdded: com.levi.pocketdj.data.collections.RecentlyAddedBuilder by lazy { com.levi.pocketdj.data.collections.RecentlyAddedBuilder() }

    /** Window-scoped multi-select state shared by Browse and every collection detail (COL-5). */
    val rowSelection: com.levi.pocketdj.ui.selection.RowSelection by lazy { com.levi.pocketdj.ui.selection.RowSelection() }

    /**
     * The durable Apple Music write-back queue (COL-8). Lazy - decodes its own device-local document
     * on first touch. Transport = Apple Music Web API (dev token + Music-User-Token, SVC-15).
     */
    val writeBack: PlaylistWriteBack by lazy {
        val tokens = DefaultAppleMusicTokens(app.musicKitDevTokenClient, app.settings)
        PlaylistWriteBack(
            file = File(app.appContext.filesDir, PlaylistWriteBack.FILE_NAME),
            transport = WebApiPlaylistWriteBackTransport(app.appleMusicApi, tokens),
            scope = app.appScope,
        ).also { wb ->
            // Catalog seam for the playlist JOIN tie-break (kept out of the queue so it stays data-layer free).
            wb.appleMusicIdsForIndexPlaylist = { indexPlaylistId ->
                val catalog = app.catalogRepository.state.value.catalog
                catalog?.playlists?.firstOrNull { it.playlist.id == indexPlaylistId }
                    ?.playlist?.songIds.orEmpty().mapNotNull { catalog?.songsById?.get(it)?.appleMusicId }
            }
        }
    }

    /**
     * Wire the store's write-back seams (called once from AppGraph's `collections` initializer).
     * Unconditional like the iOS wiring (append-only + non-destructive), gated only on `canWriteBack`.
     * The queue itself is created lazily: nothing is read from disk until the first add/drain.
     */
    fun wireWriteBack(store: CollectionsStore) {
        store.enqueueSourceWriteBack = { item ->
            val wb = writeBack
            if (!wb.canWriteBack) {
                false
            } else {
                val job = wb.enqueue(
                    item.indexPlaylistId, item.playlistName, item.songId, item.appleMusicId,
                    item.title, item.artist, item.album, item.durationMs,
                )
                wb.runSoon()
                job != null
            }
        }
        store.enqueueSourceWriteBackBatch = { items ->
            val wb = writeBack
            if (!wb.canWriteBack) {
                0
            } else {
                val queued = wb.enqueueMany(items)
                if (queued > 0) wb.runSoon()
                queued
            }
        }
        store.canWriteBackUpstream = { writeBack.canWriteBack }
        store.cancelPendingWriteBacks = { indexPlaylistId, songIds -> writeBack.cancelPending(indexPlaylistId, songIds) }
    }

    override val settingsSections: List<com.levi.pocketdj.shell.SettingsSection> by lazy {
        listOf(
            com.levi.pocketdj.screens.settings.sections.collectionsSyncSection(),
            com.levi.pocketdj.screens.settings.appleMusicWriteBackSection(),
        )
    }

    override val flushables: List<Flushable> = listOf(
        Flushable {
            app.collections.flushNow()
            app.collectionActivity.flushNow()
            favorites.flushNow()
        },
    )

    init {
        // Warm the favorites doc off-main: the lazy constructor does a synchronous file read +
        // JSON decode that would otherwise land inside the first ♥ row's composition.
        app.appScope.launch(Dispatchers.IO) { favorites }
        // COL-8: drain any write-back queued in a previous session (or backed off after a failure) -
        // the queue has no internal timer, so launch is what re-arms it.
        app.appScope.launch(Dispatchers.IO) { runCatching { writeBack.runSoon() } }
        // Converted-collection source sync (COL-7, iOS onCatalogAssigned): every NEW catalog
        // snapshot (cache seed + refresh) reconciles source-linked pockets/playlists, gated by
        // the global Settings toggle (default ON). Same-instance re-emissions are skipped.
        app.appScope.launch(Dispatchers.IO) {
            app.catalogRepository.state
                .map { it.catalog }
                .distinctUntilChanged { a, b -> a === b }
                .collect { catalog ->
                    try {
                        val on = app.settings.get(SourceSyncSettings.SYNC_CONVERTED_POCKETS)
                        SourceSyncSettings.autoPass(on, catalog, app.collections)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        runCatching { android.util.Log.w("PocketDJ", "[source-sync] auto pass failed: $e") }
                    }
                }
        }
    }
}
