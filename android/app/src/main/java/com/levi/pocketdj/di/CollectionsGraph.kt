package com.levi.pocketdj.di

import com.levi.pocketdj.data.favorites.FavoritesAccess
import com.levi.pocketdj.data.favorites.FavoritesStore
import com.levi.pocketdj.data.favorites.favoriteActivityRecorder
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

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
    }
}
