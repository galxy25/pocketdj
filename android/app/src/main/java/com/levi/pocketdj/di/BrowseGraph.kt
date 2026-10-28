package com.levi.pocketdj.di

import com.levi.pocketdj.data.search.SearchConfig
import com.levi.pocketdj.data.search.SearchService
import com.levi.pocketdj.data.search.SearchSettings
import com.levi.pocketdj.screens.browse.BrowseSessionFlushable
import com.levi.pocketdj.screens.settings.sections.editionSection
import com.levi.pocketdj.screens.settings.sections.forYouSection
import com.levi.pocketdj.screens.settings.sections.onlineSearchSection
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.Flushable
import com.levi.pocketdj.shell.SettingsSection
import com.levi.pocketdj.data.history.HistorySettings
import com.levi.pocketdj.screens.history.HistoryBrowseState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Sidecar graph for the browse area (decision D3). Packages in this area override the
 * FeatureModule members they contribute and add their own lazies here, never in AppGraph.
 */
@OptIn(FlowPreview::class)
class BrowseGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "browse"

    /**
     * History's own browse state (BRW-6): persisted filter/sort under `historySnapshotJson`
     * (never Browse's key), transient query + Hide-skips. Hydrated off-main on first touch; every
     * later change is written debounced, and a lifecycle flush writes it immediately — both
     * skipped until the restore ran so defaults never clobber the saved doc.
     */
    private val historyBrowseLazy: Lazy<HistoryBrowseState> = lazy {
        HistoryBrowseState(requireRestore = true).also { state ->
            app.appScope.launch(Dispatchers.IO) {
                runCatching { state.restore(HistorySettings.load(app.settings)) }
                if (!state.restored) state.markRestored()
                state.inputs
                    .map { state.toSnapshot() }
                    .distinctUntilChanged()
                    .drop(1) // the just-restored state — nothing new to write
                    .debounce(HISTORY_WRITE_DEBOUNCE_MS)
                    .collectLatest { runCatching { HistorySettings.save(app.settings, it) } }
            }
        }
    }

    internal val historyBrowse: HistoryBrowseState by historyBrowseLazy

    /** Durable For You feed (BRW-11). Reads its file on first touch: touch off Main. */
    private val forYouFeedLazy: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore> = lazy {
        com.levi.pocketdj.data.recs.ForYouFeedStore(
            java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.recs.ForYouFeedStore.FILE_NAME),
        )
    }
    val forYouFeedStore: com.levi.pocketdj.data.recs.ForYouFeedStore by forYouFeedLazy

    /** 👍/👎 decisions (BRW-11). Reads its file on first touch: touch off Main. */
    private val recFeedbackLazy: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore> = lazy {
        com.levi.pocketdj.data.recs.RecFeedbackStore(
            file = java.io.File(app.appContext.filesDir, REC_FEEDBACK_FILE),
            scope = app.appScope,
            identityFile = java.io.File(app.appContext.filesDir, "pocketdj-rec-feedback-install-id"),
        )
    }
    val recFeedbackStore: com.levi.pocketdj.data.recs.RecFeedbackStore by recFeedbackLazy

    /** Timbre corpus for the For You refresh (BRW-12): memoized fetch, never throws, empty when offline. */
    val timbreCatalog: com.levi.pocketdj.data.recs.TimbreCatalog by lazy {
        com.levi.pocketdj.data.recs.TimbreCatalog(app.catalogService) {
            "${com.levi.pocketdj.data.config.Endpoints.CATALOG_BASE}/timbre.json"
        }
    }

    override val flushables: List<Flushable> = listOf(
        BrowseSessionFlushable { app.settings.setBrowseSnapshot(it) },
        recsFlushable(recFeedbackLazy),
        object : Flushable {
            override suspend fun flush() {
                if (!historyBrowseLazy.isInitialized()) return
                val state = historyBrowseLazy.value
                if (!state.restored) return
                HistorySettings.save(app.settings, state.toSnapshot())
            }
        },
    )

    /** Online-search host resolution (user override -> search-config.json -> baked default). */
    val searchConfig: SearchConfig by lazy {
        SearchConfig(SearchConfig.httpFetcher(app.httpClient)).also { cfg ->
            // Seed the per-user host override from the persisted pref (off-main).
            app.appScope.launch(Dispatchers.IO) {
                runCatching { cfg.setUserHost(SearchSettings.endpoint(app.settings)) }
            }
        }
    }

    val searchService: SearchService by lazy { SearchService(app.httpClient, searchConfig) }

    /** On-demand lyrics (memory -> disk `filesDir/lyrics-cache` -> catalog CDN). */
    val lyricsStore: com.levi.pocketdj.data.lyrics.LyricsStore by lazy {
        com.levi.pocketdj.data.lyrics.LyricsStore(
            cacheDir = java.io.File(app.appContext.filesDir, com.levi.pocketdj.data.lyrics.LyricsStore.DIR_NAME),
            baseUrl = { com.levi.pocketdj.data.config.Endpoints.CATALOG_BASE },
            fetch = com.levi.pocketdj.data.lyrics.LyricsStore.httpFetcher(app.httpClient),
        )
    }

    override val syncEntries: List<com.levi.pocketdj.shell.SyncEntry> = recsSyncEntries(recFeedbackLazy, forYouFeedLazy)

    /** Account deletion / "Erase everything" (iOS AccountDeletionService clears both). */
    override val resetHooks: List<com.levi.pocketdj.shell.ResetHook> = recsResetHooks(recFeedbackLazy, forYouFeedLazy)

    override val settingsSections: List<SettingsSection> by lazy {
        listOf(editionSection(), onlineSearchSection(), forYouSection())
    }

    internal companion object {
        const val REC_FEEDBACK_SYNC_KEY = "rec-feedback"
        const val REC_FEEDBACK_FILE = "pocketdj-rec-feedback.json"
        const val FORYOU_FEED_SYNC_KEY = "foryou-feed"

        /** iOS cloudSync "rec-feedback" + "foryou-feed". The sync engine runs off-main, so touching the lazies is safe. */
        fun recsSyncEntries(
            fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>,
            feed: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore>,
        ) = listOf(
            com.levi.pocketdj.shell.SyncEntry(
                REC_FEEDBACK_SYNC_KEY, REC_FEEDBACK_FILE,
                onPulled = { fb.value.reloadFromDisk() },
                applyPayload = { fb.value.applyPulledPayload(it) },
            ),
            com.levi.pocketdj.shell.SyncEntry(
                FORYOU_FEED_SYNC_KEY, com.levi.pocketdj.data.recs.ForYouFeedStore.FILE_NAME,
                onPulled = { feed.value.reloadFromDisk() },
                applyPayload = { feed.value.applyPulledPayload(it) },
            ),
        )

        fun recsResetHooks(
            fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>,
            feed: Lazy<com.levi.pocketdj.data.recs.ForYouFeedStore>,
        ) = listOf(
            com.levi.pocketdj.shell.ResetHook { fb.value.clear() },
            com.levi.pocketdj.shell.ResetHook { feed.value.clear() },
        )

        /** ON_STOP flush for the debounced decisions write; no-op until first touched. */
        fun recsFlushable(fb: Lazy<com.levi.pocketdj.data.recs.RecFeedbackStore>) =
            Flushable { if (fb.isInitialized()) fb.value.flush() }
        const val HISTORY_WRITE_DEBOUNCE_MS = 400L
    }
}
