package com.levi.pocketdj.data.storage

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Measures real on-disk usage per category and clears the re-derivable ones —
 * the data-layer core behind Settings ▸ Storage (specs/storage.md §2, §3). The
 * UI (StorageScreen) renders the byte counts and drives the clears; this class
 * owns the measurement + the wired store/cache calls.
 *
 * THE CLEAR CONTRACT (iron rules, specs/storage.md §3):
 * 1. No clear here EVER touches the settings DataStore
 *    (`pocketdj-settings.preferences_pb`) or the jukebox prefs — this class holds
 *    no reference to either, so it is structurally impossible.
 * 2. No clear regenerates the install id. The history/activity clears preserve
 *    `installId` by construction (`PlayHistoryStore.clear()` /
 *    `CollectionActivityStore.clear()`); nothing here mints a new one.
 * 3. The Collections document is DISPLAY-ONLY — measured, never cleared (it is
 *    irreplaceable user content, not a cache). [Category.COLLECTIONS] is absent
 *    from [clearableCategories] and [clear] rejects it.
 *
 * Testable on the JVM: dependencies are file handles + an [ArtworkCache] + clear
 * lambdas (wired to the real stores in `AppGraph`), so measurement and the
 * "clear leaves settings intact" invariant are plain unit tests.
 */
class StorageService(
    /** `filesDir/catalog-cache/` — the offline-first index cache (§2.1). */
    private val catalogCacheDir: File,
    /** `filesDir/pocketdj-collections.json` (§2.3, measured-only). */
    private val collectionsFile: File,
    /** `filesDir/pocketdj-play-history.json` (§2.4). */
    private val playHistoryFile: File,
    /** `filesDir/pocketdj-collection-activity.json` (§2.5). */
    private val activityFile: File,
    private val artwork: ArtworkCache,
    /** Wired to `CatalogService.clearCache()`. */
    private val clearCatalogCache: () -> Unit,
    /** Wired to `PlayHistoryStore.clear()` (keeps installId). */
    private val clearPlayHistory: () -> Unit,
    /** Wired to `CollectionActivityStore.clear()` (keeps installId). */
    private val clearActivity: () -> Unit,
) {
    /** The five measured categories (specs/storage.md §2, ordered caches → docs). */
    enum class Category(val clearable: Boolean) {
        CATALOG_CACHE(clearable = true),
        ARTWORK(clearable = true),
        COLLECTIONS(clearable = false), // user content — display-only (§2.3)
        PLAY_HISTORY(clearable = true),
        ACTIVITY(clearable = true),
    }

    /** Categories that expose a Clear action (everything but Collections). */
    val clearableCategories: Set<Category> = Category.entries.filter { it.clearable }.toSet()

    /** Bytes on disk for one category, off the main thread. Missing state → 0. */
    suspend fun measure(category: Category): Long = withContext(Dispatchers.Default) {
        when (category) {
            Category.CATALOG_CACHE -> dirSize(catalogCacheDir)
            Category.ARTWORK -> runCatching { artwork.diskSizeBytes() }.getOrDefault(0L)
            Category.COLLECTIONS -> fileSize(collectionsFile)
            Category.PLAY_HISTORY -> fileSize(playHistoryFile)
            Category.ACTIVITY -> fileSize(activityFile)
        }
    }

    /** Measure every category in one off-main pass (drives the screen on entry). */
    suspend fun measureAll(): Map<Category, Long> = withContext(Dispatchers.Default) {
        Category.entries.associateWith { measure(it) }
    }

    /**
     * Clear one category's on-disk state (off the main thread), then return its
     * re-measured size (the caller updates the row). Rejects the non-clearable
     * [Category.COLLECTIONS] (§3 rule 3) — user content is never wiped here.
     */
    suspend fun clear(category: Category): Long = withContext(Dispatchers.Default) {
        require(category.clearable) {
            "Category $category is display-only and has no clear action (specs/storage.md §2.3)"
        }
        when (category) {
            Category.CATALOG_CACHE -> runCatching { clearCatalogCache() }
            Category.ARTWORK -> runCatching { artwork.clear() }
            Category.PLAY_HISTORY -> runCatching { clearPlayHistory() }
            Category.ACTIVITY -> runCatching { clearActivity() }
            Category.COLLECTIONS -> Unit // unreachable — guarded above
        }
        measure(category)
    }

    private fun fileSize(file: File): Long = if (file.isFile) file.length() else 0L

    private fun dirSize(dir: File): Long {
        if (!dir.exists()) return 0L
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }
}
