package com.levi.pocketdj.di

import com.levi.pocketdj.assistant.MediaCandidate
import com.levi.pocketdj.assistant.MediaSearchHandler
import com.levi.pocketdj.assistant.MediaSearchIntentHandler
import com.levi.pocketdj.assistant.SearchPlayBridge
import com.levi.pocketdj.assistant.ShortcutCandidate
import com.levi.pocketdj.assistant.ShortcutManagerSink
import com.levi.pocketdj.assistant.ShortcutsPublisher
import com.levi.pocketdj.assistant.MediaSearchRequest
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.shell.NavRequestBus
import com.levi.pocketdj.shell.PlayKind
import com.levi.pocketdj.shell.ReadinessPort
import com.levi.pocketdj.shell.SetupGate
import com.levi.pocketdj.shell.ShellActionException
import com.levi.pocketdj.shell.ShellActions
import com.levi.pocketdj.shell.ShellCatalog
import com.levi.pocketdj.shell.ShellPlayer
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import com.levi.pocketdj.onboarding.DataStoreOnboardingMarkerStorage
import com.levi.pocketdj.onboarding.LinkDeviceProbe
import com.levi.pocketdj.onboarding.OnboardingStore
import com.levi.pocketdj.onboarding.StubLinkDeviceProbe
import com.levi.pocketdj.screens.settings.SettingsSections
import com.levi.pocketdj.shell.DeepLinkDispatcher
import com.levi.pocketdj.shell.DeepLinkHandler
import com.levi.pocketdj.shell.DeepLinkSeams
import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.OnboardingGate
import com.levi.pocketdj.shell.SettingsSection

/**
 * Sidecar graph for the shell area (decision D3). Empty today: packages in this area
 * override the FeatureModule members they contribute (nav entries, settings sections,
 * deep-link handlers, flushables, reset hooks, sync entries, row resolvers, play-outcome
 * listeners, periodic work) and add their own lazies here — never in AppGraph.
 */
class ShellGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "shell"

    /** The pre-existing Settings blocks (Data sources … About), in shipped order. */
    override val periodicWork = com.levi.pocketdj.work.ShellWork.specs

    override val settingsSections: List<SettingsSection> =
        SettingsSections.builtin() + com.levi.pocketdj.screens.settings.sections.jukeboxSection() +
            com.levi.pocketdj.screens.settings.sections.profileSection() +
            com.levi.pocketdj.screens.settings.sections.collectionsSection() +
            com.levi.pocketdj.screens.settings.sections.ripFromCloudSection()

    /** Stage-1 "Link a device" probe; SVC-9 swaps in the S3 cloud-doc implementation. */
    @Volatile var linkDeviceProbe: LinkDeviceProbe = StubLinkDeviceProbe

    /**
     * The zero-to-hero first-run state machine. The launch pipeline awaits
     * `onboarding.waitUntilComplete()`; mutating ShellActions calls run `vetoIfIncomplete()`.
     */
    val onboarding: OnboardingStore by lazy {
        OnboardingStore(
            storage = DataStoreOnboardingMarkerStorage(app.settings),
            hadPersistedSettings = app.hadPersistedSettingsAtLaunch,
            scope = app.appScope,
        ).also { store ->
            // Completing triggers the catalog load with the chosen sources.
            store.onComplete = {
                val repo = app.catalogRepository
                if (repo.state.value.catalog == null) repo.loadIfNeeded() else repo.refresh()
            }
        }
    }

    /** Later packages (SURF-5 ShellActions, JBX-2, SET-2, Games) assign these seams. */
    val deepLinkSeams = DeepLinkSeams()

    /** SURF-4: pocketdj:// links, jukebox/MwF App Links and collection file opens. */
    val deepLinks: DeepLinkDispatcher by lazy {
        DeepLinkDispatcher(
            scope = app.appScope,
            gate = object : OnboardingGate {
                override val isComplete: Boolean get() = onboarding.isComplete
                override suspend fun waitUntilComplete() = onboarding.waitUntilComplete()
            },
            seams = deepLinkSeams,
            displayName = DeepLinkDispatcher.contentDisplayName(app.appContext.contentResolver),
        )
    }

    /**
     * SURF-5: the one façade for every out-of-UI surface (Assistant, shortcuts, deep links).
     * `mixFacade` is assigned by the Mix area when its engine can be driven headlessly.
     */
    val shellActions: ShellActions by lazy {
        ShellActions(
            collections = app.collections,
            catalog = object : ShellCatalog {
                override fun song(id: String): IndexSong? = app.catalogRepository.state.value.catalog?.songsById?.get(id)
                override fun album(id: String): IndexAlbum? = app.catalogRepository.state.value.catalog?.albumsById?.get(id)
            },
            player = ShellPlayer { set, ctx -> app.playbackController.playSetlist(set, ctx) },
            setup = SetupGate {
                onboarding.awaitLoaded()
                !onboarding.isComplete
            },
            readiness = object : ReadinessPort {
                override fun kickManifestRefresh() {
                    app.appScope.launch { runCatching { app.ripsRepository.refresh() } }
                }

                override fun loadCatalog() = app.catalogRepository.loadIfNeeded()

                override suspend fun awaitCatalogSeeded() {
                    // Disk-cache seed only; a true first launch (nothing cached) is bounded, not awaited forever.
                    withTimeoutOrNull(SEED_WAIT_MS) {
                        app.catalogRepository.state.first {
                            it.catalog != null || it.phase == CatalogRepository.Phase.Failed
                        }
                    }
                }
            },
        ).also { it.mixFacade = app.mixGraph.mixFacade } // MIX-16: the Mix drives Auto-Mix actions
    }

    private fun mediaCandidates(kinds: Set<MediaCandidate.Kind>): List<MediaCandidate> {
        val out = ArrayList<MediaCandidate>()
        if (MediaCandidate.Kind.Playlist in kinds) {
            app.collections.playlists.filter { it.id != NOW_PLAYING_PLAYLIST_ID }.mapTo(out) {
                MediaCandidate(MediaCandidate.Kind.Playlist, it.id, it.name, it.lastPlayedAt)
            }
        }
        if (MediaCandidate.Kind.Pocket in kinds) {
            app.collections.pockets.mapTo(out) {
                MediaCandidate(MediaCandidate.Kind.Pocket, it.id, it.name, it.lastPlayedAt)
            }
        }
        val catalog = app.catalogRepository.state.value.catalog
        if (MediaCandidate.Kind.Album in kinds) {
            catalog?.albumsById?.values?.mapTo(out) { MediaCandidate(MediaCandidate.Kind.Album, it.id, it.name, artist = it.artist) }
        }
        if (MediaCandidate.Kind.Song in kinds) {
            catalog?.songsById?.values?.mapTo(out) { MediaCandidate(MediaCandidate.Kind.Song, it.id, it.name, artist = it.artist) }
        }
        return out
    }

    private val mediaSearch: MediaSearchHandler by lazy {
        MediaSearchHandler(
            actions = shellActions,
            candidates = ::mediaCandidates,
            openRoute = NavRequestBus::post,
            message = NavRequestBus::postMessage,
        )
    }

    /** Dynamic launcher shortcuts: most recently played playlists/pockets (iOS donations analogue). */
    private val shortcuts: ShortcutsPublisher by lazy {
        val history = PlayHistoryStore.get(app.appContext)
        ShortcutsPublisher(
            scope = app.appScope,
            source = merge(app.collections.state.map { }, history.state.map { }).map {
                val c = app.collections
                c.playlists.map { ShortcutCandidate(PlayKind.Playlist, it.id, it.name, it.lastPlayedAt) } +
                    c.pockets.map { ShortcutCandidate(PlayKind.Pocket, it.id, it.name, it.lastPlayedAt) }
            },
            sink = ShortcutManagerSink(app.appContext),
            cap = { ShortcutManagerSink.dynamicCap(app.appContext) },
        )
    }

    /** SURF-7: Now Playing widget snapshot sync + command executor + offline drain. */
    private val widgets: com.levi.pocketdj.widget.WidgetBridge by lazy {
        com.levi.pocketdj.widget.WidgetBridge(app, app.appContext)
    }

    override val deepLinkHandlers: List<DeepLinkHandler> by lazy {
        widgets.start()
        // Cheap and side-effect-light: runs on the main thread during cold start. Nothing heavy
        // (history decode, catalog/collections graphs) is forced here.
        // JBX-2: a tapped/parked jukebox link joins as a guest and opens the join panel.
        deepLinkSeams.joinJukebox = { id, guestBase ->
            com.levi.pocketdj.data.jukebox.JukeboxLink.forEntry(id, guestBase)?.let { link ->
                com.levi.pocketdj.data.jukebox.JukeboxGraph.joinedSessions(app.appContext).addJoined(link)
                NavRequestBus.post(ShellRoute.JukeboxJoin(id))
            }
        }
        deepLinkSeams.playItem = { kind, id, shuffle ->
            if (kind == PlayKind.Setlist) {
                NavRequestBus.post(ShellRoute.Setlist(id, autoplay = true))
            } else {
                app.appScope.launch {
                    try {
                        when (kind) {
                            PlayKind.Playlist -> shellActions.playPlaylist(id, shuffle)
                            PlayKind.Pocket -> shellActions.playPocket(id, shuffle)
                            else -> shellActions.playAlbum(id, shuffle)
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        NavRequestBus.postMessage(
                            (e as? ShellActionException)?.message ?: "Couldn't play that.",
                        )
                    }
                }
            }
            null
        }
        SearchPlayBridge.handler = { request ->
            app.appScope.launch { mediaSearch.handle(request) }
        }
        // Publisher construction reads the play-history log: build + start it off main.
        app.appScope.launch(Dispatchers.IO) { shortcuts.start() }
        listOf(deepLinks.intentHandler, MediaSearchIntentHandler(app.appScope, { mediaSearch }, NavRequestBus::post))
    }

    private companion object {
        const val SEED_WAIT_MS = 10_000L
    }
}
