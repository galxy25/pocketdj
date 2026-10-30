package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.ArtistUsage
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
    /** `filesDir/pocketdj-favorites.json` (COL-10, measured-only user content). */
    private val favoritesFile: File? = null,
    /** SVC-2: measured burned-media bytes (audio + sidecars + cuts + grids; owned files only). */
    private val burnsUsageBytes: (() -> Long)? = null,
    /** SVC-2: measured owned stem-file bytes (a separately clearable line). */
    private val stemsUsageBytes: (() -> Long)? = null,
    /** SVC-2: `BurnStore.removeAllBurns()` — the library/catalog/collections are never touched. */
    private val clearBurns: (() -> Unit)? = null,
    /** SVC-2: `BurnStore.removeAllStems(protecting=...)`; beat grids and burned audio stay. */
    private val clearStems: (() -> Unit)? = null,
    /** BRW-4: `filesDir/lyrics-cache/` - on-demand lyrics text, re-fetched when a song opens. */
    private val lyricsCacheDir: File? = null,
    /** BRW-4: `LyricsStore.clearDisk()` (also drops the in-memory tier). */
    private val clearLyrics: (() -> Unit)? = null,
    /** SVC-6: targeted burn/stem deletes + per-artist usage (wired to BurnStore). */
    private val burnOps: BurnStorageOps? = null,
    /** STU-7: per-family Studio usage + delete-all (wired to StudioStore). */
    private val studioOps: StudioStorageOps? = null,
    /** MIX-12: `filesDir/mix-sessions/` - recorded mix takes (user content; delete-all skips the live take). */
    private val mixSessionsDir: File? = null,
    /** MIX-12: deletes every take except the in-flight one. */
    private val clearMixSessions: (() -> Unit)? = null,
    /** ANS-STU-7: bytes of the "Pocket DJ" profile audio (originals + stems). */
    private val profileAudioBytes: (() -> Long)? = null,
    /** ANS-STU-7: delete every profile item (audio + records). */
    private val clearProfileAudio: (() -> Unit)? = null,
) {
    /**
     * The slice of StudioStore the Storage screen uses (a port for JVM tests). [deleteAll] is STRICT: it
     * keeps records whose root is unreachable and skips the recorder's in-flight take.
     */
    interface StudioStorageOps {
        fun usageBytes(family: com.levi.pocketdj.studio.store.StudioFamily): Long
        fun deleteAll(family: com.levi.pocketdj.studio.store.StudioFamily)
        /** Records of the family (iOS enables delete when count > 0 OR bytes > 0: a record with zero bytes is removable). */
        fun recordCount(family: com.levi.pocketdj.studio.store.StudioFamily): Int = 0
    }

    /** Studio record count for a STUDIO_* category (0 for others / unwired). Off-main callers only. */
    fun studioRecordCount(category: Category): Int =
        runCatching { category.studioFamily?.let { studioOps?.recordCount(it) } }.getOrNull() ?: 0

    /** The slice of BurnStore the Storage screen's targeted deletes use (a port for JVM tests). */
    interface BurnStorageOps {
        fun usageByArtist(): List<ArtistUsage>
        fun stemUsageByArtist(): List<ArtistUsage>
        fun approximateBytes(ids: List<String>): Long
        fun removeBurns(songIds: List<String>)
        fun removeStems(songIds: List<String>)
    }

    /** The five measured categories (specs/storage.md §2, ordered caches → docs). */
    enum class Category(val clearable: Boolean) {
        CATALOG_CACHE(clearable = true),
        ARTWORK(clearable = true),
        BURNS(clearable = true), // downloaded media only — songs stay in the library, re-burnable
        STEMS(clearable = true), // burned stem files; beat grids + audio stay
        COLLECTIONS(clearable = false), // user content — display-only (§2.3)
        PLAY_HISTORY(clearable = true),
        ACTIVITY(clearable = true),
        LYRICS(clearable = true), // re-fetchable text cache (BRW-4)
        FAVORITES(clearable = false), // per-profile ♥ + tombstones — display-only, user content
        STUDIO_SAMPLES(clearable = true), // the user's own recordings/cuts: delete-all is explicit + confirmed
        STUDIO_LOOPS(clearable = true),
        STUDIO_SEQUENCES(clearable = true),
        STUDIO_TAKES(clearable = true),
        STUDIO_INSTRUMENTS(clearable = true), // downloaded SoundFonts: re-downloadable
        MIX_SESSIONS(clearable = true), // recorded mix takes: explicit delete-all, skips the active take
        PROFILE_AUDIO(clearable = true), // the user's saved demuxes/samples in the "Pocket DJ" source: explicit + confirmed
        ;

        /** The Studio family a STUDIO_* category maps to, else null. */
        val studioFamily: com.levi.pocketdj.studio.store.StudioFamily?
            get() = when (this) {
                STUDIO_SAMPLES -> com.levi.pocketdj.studio.store.StudioFamily.SAMPLES
                STUDIO_LOOPS -> com.levi.pocketdj.studio.store.StudioFamily.LOOPS
                STUDIO_SEQUENCES -> com.levi.pocketdj.studio.store.StudioFamily.SEQUENCES
                STUDIO_TAKES -> com.levi.pocketdj.studio.store.StudioFamily.TAKES
                STUDIO_INSTRUMENTS -> com.levi.pocketdj.studio.store.StudioFamily.INSTRUMENTS
                else -> null
            }
    }

    /** Categories that expose a Clear action (everything but Collections). */
    val clearableCategories: Set<Category> = Category.entries.filter { it.clearable }.toSet()

    /** Bytes on disk for one category, off the main thread. Missing state → 0. */
    suspend fun measure(category: Category): Long = withContext(Dispatchers.Default) {
        when (category) {
            Category.CATALOG_CACHE -> dirSize(catalogCacheDir)
            Category.ARTWORK -> runCatching { artwork.diskSizeBytes() }.getOrDefault(0L)
            Category.BURNS -> burnsUsageBytes?.invoke() ?: 0L
            Category.STEMS -> stemsUsageBytes?.invoke() ?: 0L
            Category.COLLECTIONS -> fileSize(collectionsFile)
            Category.PLAY_HISTORY -> fileSize(playHistoryFile)
            Category.ACTIVITY -> fileSize(activityFile)
            Category.FAVORITES -> favoritesFile?.let(::fileSize) ?: 0L
            Category.LYRICS -> lyricsCacheDir?.let(::dirSize) ?: 0L
            Category.MIX_SESSIONS -> mixSessionsDir?.let(::dirSize) ?: 0L
            Category.PROFILE_AUDIO -> runCatching { profileAudioBytes?.invoke() }.getOrNull() ?: 0L
            Category.STUDIO_SAMPLES, Category.STUDIO_LOOPS, Category.STUDIO_SEQUENCES,
            Category.STUDIO_TAKES, Category.STUDIO_INSTRUMENTS ->
                runCatching { category.studioFamily?.let { studioOps?.usageBytes(it) } }.getOrNull() ?: 0L
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
            Category.BURNS -> runCatching { clearBurns?.invoke() }
            Category.STEMS -> runCatching { clearStems?.invoke() }
            Category.LYRICS -> runCatching {
                clearLyrics?.invoke() ?: lyricsCacheDir?.listFiles()?.forEach { it.delete() }
            }
            Category.MIX_SESSIONS -> runCatching { clearMixSessions?.invoke() }
            Category.PROFILE_AUDIO -> runCatching { clearProfileAudio?.invoke() }
            Category.STUDIO_SAMPLES, Category.STUDIO_LOOPS, Category.STUDIO_SEQUENCES,
            Category.STUDIO_TAKES, Category.STUDIO_INSTRUMENTS ->
                runCatching { category.studioFamily?.let { studioOps?.deleteAll(it) } }
            Category.COLLECTIONS, Category.FAVORITES -> Unit // unreachable — guarded above
        }
        measure(category)
    }

    /** Downloaded songs grouped by artist (unique audio files counted once). */
    suspend fun burnUsageByArtist(): List<ArtistUsage> =
        withContext(Dispatchers.Default) { burnOps?.usageByArtist().orEmpty() }

    suspend fun stemUsageByArtist(): List<ArtistUsage> =
        withContext(Dispatchers.Default) { burnOps?.stemUsageByArtist().orEmpty() }

    /** Bytes [songIds] would free if their downloads were deleted (collection delete preview). */
    suspend fun approximateBurnBytes(songIds: List<String>): Long =
        withContext(Dispatchers.Default) { burnOps?.approximateBytes(songIds) ?: 0L }

    /**
     * Delete the downloaded media of [songIds] (an artist's songs or a collection's members).
     * Media only: the library, collections and catalog are untouched. Returns the re-measured
     * [Category.BURNS] size.
     */
    suspend fun deleteBurns(songIds: List<String>): Long = withContext(Dispatchers.Default) {
        runCatching { burnOps?.removeBurns(songIds) }
        measure(Category.BURNS)
    }

    /**
     * iOS `removeAllBurns()`: every downloaded file (audio, cuts, stems, grids, sidecars), the whole ledger
     * (QUEUED/FAILED/stuck entries included), in-flight burns stopped, orphan stems swept. Returns the re-measured size.
     */
    suspend fun deleteAllBurns(): Long = clear(Category.BURNS)

    /** Delete only the stem files of [songIds]; burned audio and beat grids stay. */
    suspend fun deleteStems(songIds: List<String>): Long = withContext(Dispatchers.Default) {
        runCatching { burnOps?.removeStems(songIds) }
        measure(Category.STEMS)
    }

    private fun fileSize(file: File): Long = if (file.isFile) file.length() else 0L

    private fun dirSize(dir: File): Long {
        if (!dir.exists()) return 0L
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }
}
